import Foundation
import ShawnCore

/// How the config should be chosen.
public struct ConfigResolveOptions: Equatable, Sendable {
    /// A `--config <dir>` argument: use exactly this directory.
    public var explicitPath: URL?
    /// Try the latest config from GitHub first (falls back to what is on disk).
    public var allowRemote: Bool
    /// Fetch this branch, tag or commit instead of the configured branch (`--config-ref`).
    public var remoteRef: String?
    /// Give up on GitHub after this many seconds.
    public var remoteTimeout: TimeInterval

    public init(explicitPath: URL? = nil, allowRemote: Bool = true, remoteRef: String? = nil, remoteTimeout: TimeInterval = 20) {
        self.explicitPath = explicitPath
        self.allowRemote = allowRemote
        self.remoteRef = remoteRef
        self.remoteTimeout = remoteTimeout
    }
}

/// A config that loaded and planned without blocking errors.
public struct ResolvedConfig: Sendable {
    public let config: InstallerConfig
    public let plan: InstallPlan
    /// What happened on the way ("using the bundled config: GitHub was unreachable"). For display.
    public let notes: [String]

    public init(config: InstallerConfig, plan: InstallPlan, notes: [String] = []) {
        self.config = config
        self.plan = plan
        self.notes = notes
    }
}

public struct ConfigResolveError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let issues: [ConfigIssue]

    public init(_ message: String, issues: [ConfigIssue] = []) {
        self.message = message
        self.issues = issues
    }

    public var description: String {
        issues.isEmpty ? message : message + "\n" + issues.map(\.description).joined(separator: "\n")
    }

    /// The first issue and how many more there are: enough for a one-line note.
    var summary: String {
        let first = issues.first.map(\.description) ?? message
        return issues.count > 1 ? "\(first) (and \(issues.count - 1) more)" : first
    }
}

/// Picks and loads the config the installer or CLI should use.
///
/// Policy: an explicit path always wins, and so does any other working copy the user edits
/// (`$SHAWN_CONFIG_DIR`, the dotfiles checkout, a development checkout). Replacing those with GitHub's
/// copy would silently ignore local, unpushed changes. A working copy that is found but invalid is an
/// error, never silently replaced by another config.
///
/// The snapshots (the copy in `~/.shawn/config` a previous install left for the CLI, and the one in the
/// app bundle) are different: nobody edits them, and a snapshot written by another version of the
/// installer may not load with this one. Such a snapshot is skipped with a note, and the search goes on
/// to the next one. When the config found is a snapshot, or a specific `remoteRef` was asked for, and
/// remote config is allowed, the latest config from the repo named in its `remote:` block is fetched and
/// used, unless it cannot be fetched, does not load, or needs a newer build, in which case the on-disk
/// config is used and a note says why. When no snapshot loads at all, GitHub's copy (found through a
/// snapshot's `remote:` block, read on its own) is the last config tried before giving up.
public enum ConfigResolver {
    /// Loads a config directory and builds its plan, failing on any blocking issue.
    public static func load(directory: URL, source: ConfigSource, registry: ActionRegistry,
                            environment: SystemEnvironment, notes: [String] = []) throws -> ResolvedConfig {
        let loaded: ConfigLoader.Result
        do {
            loaded = try ConfigLoader.load(from: directory, source: source)
        } catch let error as ConfigError {
            throw ConfigResolveError("The config at \(directory.path) has problems.", issues: error.issues)
        }
        let plan = InstallPlan.build(config: loaded.config, registry: registry, environment: environment, extraIssues: loaded.warnings)
        if plan.hasErrors {
            throw ConfigResolveError("The config at \(directory.path) has problems.", issues: plan.errors)
        }
        return ResolvedConfig(config: loaded.config, plan: plan, notes: notes)
    }

    /// Resolves from disk only (no network).
    public static func resolveLocal(options: ConfigResolveOptions, registry: ActionRegistry, environment: SystemEnvironment,
                                    bundle: Bundle = .main) throws -> ResolvedConfig {
        switch try searchDisk(options: options, registry: registry, environment: environment, bundle: bundle) {
        case .found(let local, _):
            return local
        case .brokenSnapshots(let skipped):
            throw nothingLoads(skipped, remoteProblem: nil)
        }
    }

    /// Resolves the config, preferring the latest from GitHub when allowed (see the policy above).
    public static func resolve(options: ConfigResolveOptions, registry: ActionRegistry, environment: SystemEnvironment,
                               bundle: Bundle = .main) async throws -> ResolvedConfig {
        try await resolve(options: options, registry: registry, environment: environment, bundle: bundle,
                          transport: RemoteConfig.liveTransport)
    }

    /// `resolve` with an explicit transport for the GitHub requests (tests pass an in-memory fake).
    public static func resolve(options: ConfigResolveOptions, registry: ActionRegistry, environment: SystemEnvironment,
                               bundle: Bundle = .main, transport: any HTTPTransport) async throws -> ResolvedConfig {
        let local: ResolvedConfig
        let origin: ConfigLocator.Location.Origin
        switch try searchDisk(options: options, registry: registry, environment: environment, bundle: bundle) {
        case .found(let config, let foundOrigin):
            local = config
            origin = foundOrigin
        case .brokenSnapshots(let skipped):
            // Nothing on disk loads, so GitHub's copy is the one config left that may work with this build.
            guard options.allowRemote, let remote = declaredRemote(of: skipped) else {
                throw nothingLoads(skipped, remoteProblem: nil)
            }
            switch await RemoteConfig.latest(remote: remote, options: options, registry: registry, environment: environment,
                                             transport: transport, notes: skipNotes(skipped, environment: environment)) {
            case .success(let resolved):
                return resolved
            case .failure(let unusable):
                throw nothingLoads(skipped, remoteProblem: unusable.explanation)
            }
        }
        let ref = requestedRef(options)
        guard options.allowRemote, let remote = local.config.meta.remote, !origin.isWorkingCopy || ref != nil else {
            return noteUnfetchedRef(ref, local: local, environment: environment)
        }
        return await RemoteConfig.upgrade(local: local, remote: remote, options: options, registry: registry,
                                          environment: environment, transport: transport)
    }

    // MARK: Searching the disk

    /// A snapshot that was found but does not load.
    struct Skipped {
        let location: ConfigLocator.Location
        let error: ConfigResolveError
    }

    enum DiskSearch {
        /// The first config that loads; any snapshots skipped on the way are named in its notes.
        case found(ResolvedConfig, origin: ConfigLocator.Location.Origin)
        /// Every config found is a snapshot that does not load (never empty; in search order).
        case brokenSnapshots([Skipped])
    }

    /// Loads the first config in `ConfigLocator`'s search order that loads, skipping snapshots that do
    /// not (see the policy above). Throws when nothing is found or a working copy does not load.
    static func searchDisk(options: ConfigResolveOptions, registry: ActionRegistry, environment: SystemEnvironment,
                           bundle: Bundle) throws -> DiskSearch {
        let candidates = ConfigLocator.candidates(explicit: options.explicitPath, environment: environment, bundle: bundle)
        let found = candidates.filter { ConfigLoader.isConfigDirectory($0.url) }
        guard !found.isEmpty else {
            if let explicit = options.explicitPath {
                throw ConfigResolveError("There is no config at \(explicit.standardizedFileURL.path) "
                    + "(a config directory contains \(ConfigLoader.metaFileName) and a steps/ folder).")
            }
            throw ConfigResolveError("No config found. Looked in:\n  " + candidates.map(\.url.path).joined(separator: "\n  "))
        }
        var skipped: [Skipped] = []
        for location in found {
            do {
                let config = try load(directory: location.url, source: location.source, registry: registry, environment: environment,
                                      notes: skipNotes(skipped, environment: environment))
                return .found(config, origin: location.origin)
            } catch let error as ConfigResolveError where !location.origin.isWorkingCopy {
                skipped.append(Skipped(location: location, error: error))
            }
        }
        // Every candidate either loaded, threw (a working copy) or was skipped, so `skipped` is not empty.
        return .brokenSnapshots(skipped)
    }

    /// One note per skipped snapshot, saying what it is and why it was not used.
    static func skipNotes(_ skipped: [Skipped], environment: SystemEnvironment) -> [String] {
        skipped.map { skip in
            let label = RemoteConfig.label(for: skip.location.source, environment: environment)
            let what = skip.location.origin == .installed
                ? " (the copy a previous install left for the `shawn` CLI; the next install replaces it)" : ""
            return ActionError.sentence("Skipped \(label)\(what). It does not load with this installer (\(ShawnCore.version)): \(skip.error.summary)")
        }
    }

    /// Where newer config comes from, according to the snapshots that do not load: the bundled one first,
    /// as it was written for this build.
    static func declaredRemote(of skipped: [Skipped]) -> RemoteConfigRef? {
        skipped.reversed().lazy.compactMap { RemoteConfig.declaredRemote(in: $0.location.url) }.first
    }

    /// The error when no config loads: the first snapshot's problems, what that snapshot is, why nothing
    /// else could stand in for it, and what to do.
    static func nothingLoads(_ skipped: [Skipped], remoteProblem: String?) -> ConfigResolveError {
        let first = skipped[0]
        let installed = first.location.origin == .installed
        var message = first.error.message + (installed
            ? " It is the copy a previous install left for the `shawn` CLI, probably written by a different version of the installer."
            : " It is the config bundled with this installer.")
        for other in skipped.dropFirst() {
            let label = other.location.origin == .bundled ? "The config bundled with this installer" : "The config at \(other.location.url.path)"
            message += " \(label) does not load either: \(other.error.summary)."
        }
        if let remoteProblem { message += " " + remoteProblem }
        message += installed
            ? " Run the latest Shawn's Dotfiles installer to replace it, or pass --config with a working config directory."
            : " Download the latest Shawn's Dotfiles release, or pass --config with a working config directory."
        return ConfigResolveError(message, issues: first.error.issues)
    }

    // MARK: Remote ref

    /// `options.remoteRef`, unless it is blank (a blank ref means the configured branch, which must not
    /// override a working copy).
    static func requestedRef(_ options: ConfigResolveOptions) -> String? {
        guard let ref = options.remoteRef?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return nil }
        return ref
    }

    /// A ref that was asked for but cannot be fetched is reported rather than dropped without a word.
    static func noteUnfetchedRef(_ ref: String?, local: ResolvedConfig, environment: SystemEnvironment) -> ResolvedConfig {
        guard let ref else { return local }
        let label = RemoteConfig.localLabel(local, environment: environment)
        let why = local.config.meta.remote == nil
            ? "\(label) has no `remote:` block naming a GitHub repo to fetch it from"
            : "fetching config from GitHub is turned off, so \(label) is used"
        return RemoteConfig.fallback(local, note: "Ignored the requested config ref '\(ref)': \(why).")
    }
}
