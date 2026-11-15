import Foundation
import ShawnCore

/// Fetching the config directory from GitHub.
///
/// How a fetch works:
/// 1. Resolve the branch, tag or abbreviated commit to a full commit SHA: one small API call per fetch (a
///    full commit SHA needs none). The call is conditional when this Mac has asked before, but that only shrinks an
///    unchanged answer to an empty 304: GitHub counts unauthenticated 304s against its limit of 60
///    requests an hour per network like any other request.
/// 2. If `<cacheDirectory>/config/<commit>/` exists, use it: no further requests.
/// 3. Otherwise list the repo tree at that commit (one more API call), download every file under the
///    config path from raw.githubusercontent.com pinned to the commit (8 at a time; these do not use
///    the API limit), check each one against its git blob SHA, restore executable bits, and rename the
///    finished directory into place.
///
/// So a fetch uses one API request, or two when the ref has moved. Once the limit is used up, GitHub
/// refuses until it resets; the fetch then fails like any other and the note says when it resets.
///
/// Everything is bounded by `ConfigResolveOptions.remoteTimeout`. Any failure leaves the cache as it was
/// and hands back the local config with a note that says why.
public enum RemoteConfig {
    /// The transport used when none is passed: `URLSessionTransport` with its defaults.
    public static let liveTransport: any HTTPTransport = URLSessionTransport()

    static let maxConcurrentDownloads = 8
    static let cachedCommitsToKeep = 3

    // MARK: Upgrade

    /// Returns the remote config when it can be fetched, loads and plans cleanly; otherwise `local` with a note explaining why.
    public static func upgrade(local: ResolvedConfig, remote: RemoteConfigRef, options: ConfigResolveOptions,
                               registry: ActionRegistry, environment: SystemEnvironment) async -> ResolvedConfig {
        await upgrade(local: local, remote: remote, options: options, registry: registry, environment: environment,
                      transport: liveTransport)
    }

    /// `upgrade` with an explicit transport (tests pass an in-memory fake).
    public static func upgrade(local: ResolvedConfig, remote: RemoteConfigRef, options: ConfigResolveOptions,
                               registry: ActionRegistry, environment: SystemEnvironment,
                               transport: any HTTPTransport) async -> ResolvedConfig {
        switch await latest(remote: remote, options: options, registry: registry, environment: environment,
                            transport: transport, notes: local.notes) {
        case .success(let resolved):
            return resolved
        case .failure(let unusable):
            return fallback(local, note: unusable.note(using: localLabel(local, environment: environment)))
        }
    }

    /// Why GitHub's config cannot be used.
    enum Unusable: Error, Equatable {
        /// It could not be fetched.
        case unreachable(repo: String, ref: String, reason: RemoteConfigError)
        /// It was fetched, but this build cannot use it; the text says why and what to do about it.
        case incompatible(String)

        /// The note shown when the config described by `label` is used instead.
        func note(using label: String) -> String {
            switch self {
            case .unreachable(let repo, let ref, let reason):
                return "Using \(label). The latest config from GitHub (\(repo)@\(ref)) did not arrive: \(reason)."
            case .incompatible(let text):
                return "\(text) Using \(label) for now."
            }
        }

        /// The same on its own, for when there is no other config to use.
        var explanation: String {
            switch self {
            case .unreachable(let repo, let ref, let reason):
                return "The latest config could not be fetched from GitHub (\(repo)@\(ref)) instead: \(reason)."
            case .incompatible(let text):
                return text
            }
        }
    }

    /// GitHub's config for `remote` (at `options.remoteRef`, or the configured branch), loaded and planned
    /// with this build and carrying `notes` first, or why it cannot be used.
    static func latest(remote: RemoteConfigRef, options: ConfigResolveOptions, registry: ActionRegistry,
                       environment: SystemEnvironment, transport: any HTTPTransport,
                       notes: [String]) async -> Result<ResolvedConfig, Unusable> {
        let ref = requestedRef(remote: remote, override: options.remoteRef)
        let timeout = options.remoteTimeout
        let fetched: Fetched
        do {
            fetched = try await withDeadline(seconds: timeout) {
                try await fetch(remote: remote, ref: ref, environment: environment, transport: transport,
                                deadline: Deadline(seconds: timeout))
            }
        } catch {
            return .failure(.unreachable(repo: remote.repo, ref: ref, reason: reason(for: error, timeout: timeout)))
        }
        return load(fetched, remote: remote, ref: ref, registry: registry, environment: environment, notes: notes)
    }

    // MARK: Latest commit

    /// The commit `ref` (default: the configured branch) currently points at, for an occasional "is there
    /// something newer?" check. Each call uses one of the 60 unauthenticated GitHub API requests an hour
    /// this network gets, even when nothing changed; a check on every command should use `git ls-remote`
    /// instead (as the CLI's self-updater does), which does not count against that limit. Throws
    /// `RemoteConfigError` (its description is fit to show).
    public static func latestCommit(for remote: RemoteConfigRef, ref: String? = nil, timeout: TimeInterval) async throws -> String {
        try await latestCommit(for: remote, ref: ref, timeout: timeout, environment: nil, transport: liveTransport)
    }

    /// `latestCommit` that, given an `environment`, remembers GitHub's ETag in the cache directory and asks
    /// conditionally, so an unchanged ref is answered with an empty 304. The 304 still counts against the
    /// unauthenticated rate limit; it only saves the response body.
    public static func latestCommit(for remote: RemoteConfigRef, ref: String? = nil, timeout: TimeInterval,
                                    environment: SystemEnvironment?,
                                    transport: any HTTPTransport = liveTransport) async throws -> String {
        let ref = requestedRef(remote: remote, override: ref)
        do {
            return try await withDeadline(seconds: timeout) {
                let github = GitHubAPI(repo: try validatedRepo(remote.repo), transport: transport, deadline: Deadline(seconds: timeout))
                return try await resolveCommit(ref: ref, github: github, cache: environment.map { ConfigCache(environment: $0) })
            }
        } catch {
            throw reason(for: error, timeout: timeout)
        }
    }

    // MARK: Cache access

    /// `<cacheDirectory>/config`: one subdirectory per downloaded commit.
    public static func cacheRoot(environment: SystemEnvironment) -> URL {
        ConfigCache(environment: environment).root
    }

    /// The downloaded config for `commit`, if this Mac already has it (no network).
    public static func cachedConfigDirectory(commit: String, environment: SystemEnvironment) -> URL? {
        let commit = commit.lowercased()
        guard GitHubAPI.isCommitSHA(commit) else { return nil }
        return ConfigCache(environment: environment).existingDirectory(commit: commit)
    }

    // MARK: Fetching

    struct Fetched: Sendable {
        let directory: URL
        let commit: String
        /// Things left out of the download, for the user.
        let notes: [String]
    }

    static func fetch(remote: RemoteConfigRef, ref: String, environment: SystemEnvironment,
                      transport: any HTTPTransport, deadline: Deadline) async throws -> Fetched {
        let repo = try validatedRepo(remote.repo)
        let configPath = try validatedConfigPath(remote.path)
        let cache = ConfigCache(environment: environment)
        let github = GitHubAPI(repo: repo, transport: transport, deadline: deadline)

        let commit = try await resolveCommit(ref: ref, github: github, cache: cache)
        if let cached = cache.existingDirectory(commit: commit) {
            cache.markUsed(commit: commit)
            cache.prune(keeping: cachedCommitsToKeep, protecting: commit)
            return Fetched(directory: cached, commit: commit, notes: [])
        }

        let tree = try await github.tree(commit: commit)
        if tree.truncated == true { throw RemoteConfigError.treeTruncated(repo: repo) }
        let plan = try FetchPlan.make(tree: tree, configPath: configPath, repo: repo, commit: commit)

        let staging = try cache.makeStaging(commit: commit)
        defer { cache.discard(staging) }
        try createDirectories(for: plan, in: staging)
        // Every file is now present and matches its blob SHA. Even if the caller's deadline has passed,
        // installing it is safe and spares the next run the download.
        try await download(plan.files, commit: commit, into: staging, github: github)

        let directory = try cache.install(staging, commit: commit)
        cache.prune(keeping: cachedCommitsToKeep, protecting: commit)
        return Fetched(directory: directory, commit: commit, notes: plan.notes)
    }

    static func resolveCommit(ref: String, github: GitHubAPI, cache: ConfigCache?) async throws -> String {
        let lowered = ref.lowercased()
        if GitHubAPI.isCommitSHA(lowered) { return lowered }
        guard isPlausibleRef(ref) else { throw RemoteConfigError.invalidRef(ref) }
        let known = cache?.knownRef(repo: github.repo, ref: ref)
        switch try await github.resolveCommit(ref: ref, ifNoneMatch: known?.etag) {
        case .notModified:
            guard let known else { throw RemoteConfigError.unexpectedResponse(what: "the commit of '\(ref)'") }
            return known.commit
        case .commit(let commit, let etag):
            if let etag, let cache { cache.remember(repo: github.repo, ref: ref, etag: etag, commit: commit) }
            return commit
        }
    }

    static func createDirectories(for plan: FetchPlan, in staging: URL) throws {
        var directories = Set(plan.directories)
        for file in plan.files {
            let parent = (file.relativePath as NSString).deletingLastPathComponent
            if !parent.isEmpty { directories.insert(parent) }
        }
        for directory in directories.sorted() {
            try FileManager.default.createDirectory(at: destination(of: directory, in: staging), withIntermediateDirectories: true)
        }
    }

    /// Where `relativePath` goes inside `staging`. `FetchPlan.make` has already refused unsafe paths; this
    /// second, independent check (Foundation's own reading of the path) guarantees that nothing is ever
    /// written outside the staging directory, whatever the plan contains.
    ///
    /// Both sides are read lexically (`standardized`: `.` and `..` resolved, nothing looked up on disk).
    /// `standardizedFileURL` would also drop a leading `/private`, but only from a path that exists, so in a
    /// cache under /private (a `--sandbox` folder under /tmp, say) the existing staging folder and a file
    /// not yet written in it would never match.
    static func destination(of relativePath: String, in staging: URL) throws -> URL {
        let base = staging.standardized
        let destination = base.appendingPathComponent(relativePath)
        let inside = Array(base.path.utf8) + [UInt8(ascii: "/")]
        guard FetchPlan.isSafeRelativePath(relativePath), Array(destination.standardized.path.utf8).starts(with: inside) else {
            throw RemoteConfigError.unsafePath(relativePath)
        }
        return destination
    }

    /// Downloads with at most `maxConcurrentDownloads` requests in flight; the first failure cancels the rest.
    static func download(_ files: [FetchPlan.File], commit: String, into staging: URL, github: GitHubAPI) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var remaining = files.makeIterator()
            for _ in 0..<maxConcurrentDownloads {
                guard let file = remaining.next() else { break }
                group.addTask { try await save(file, commit: commit, into: staging, github: github) }
            }
            while try await group.next() != nil {
                if let file = remaining.next() {
                    group.addTask { try await save(file, commit: commit, into: staging, github: github) }
                }
            }
        }
    }

    static func save(_ file: FetchPlan.File, commit: String, into staging: URL, github: GitHubAPI) async throws {
        let destination = try destination(of: file.relativePath, in: staging)
        let data = try await github.blob(commit: commit, path: file.repoPath, sha: file.sha)
        try data.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: destination.path)
    }

    // MARK: Loading

    static let updateAdvice = "A newer installer is needed. Run `shawn update` or download the latest Shawn's Dotfiles release."

    /// Loads the fetched directory, or explains why this build cannot use it.
    static func load(_ fetched: Fetched, remote: RemoteConfigRef, ref: String, registry: ActionRegistry,
                     environment: SystemEnvironment, notes: [String]) -> Result<ResolvedConfig, Unusable> {
        let label = "\(remote.repo)@\(ref), \(fetched.commit.prefix(7))"

        if let schema = declaredSchema(in: fetched.directory), schema > ShawnCore.schemaVersion {
            return .failure(.incompatible("The latest config on GitHub (\(label)) is config schema \(schema), and this "
                + "installer (\(ShawnCore.version)) only understands schema \(ShawnCore.schemaVersion). \(updateAdvice)"))
        }
        do {
            return .success(try ConfigResolver.load(directory: fetched.directory,
                                                    source: .remote(repo: remote.repo, ref: ref, commit: fetched.commit),
                                                    registry: registry, environment: environment, notes: notes + fetched.notes))
        } catch {
            let unknown = unknownKinds(in: fetched.directory, registry: registry)
            if !unknown.isEmpty {
                return .failure(.incompatible("The latest config on GitHub (\(label)) uses item kinds this installer "
                    + "(\(ShawnCore.version)) does not know: \(unknown.joined(separator: ", ")). \(updateAdvice)"))
            }
            let problem = (error as? ConfigResolveError)?.summary ?? String(describing: error)
            return .failure(.incompatible("The latest config on GitHub (\(label)) does not load with this installer "
                + "(\(ShawnCore.version)): \(problem). If it was written for a newer installer, run `shawn update` or "
                + "download the latest Shawn's Dotfiles release; otherwise the config on GitHub needs fixing."))
        }
    }

    /// `schema:` from installer.yaml, read on its own so "too new" is told apart from "broken".
    static func declaredSchema(in directory: URL) -> Int? {
        metaMap(in: directory)?["schema"]?.int
    }

    /// The `remote:` block of installer.yaml, read on its own (with the loader's defaults), so a config
    /// that no longer loads can still say where newer config comes from.
    static func declaredRemote(in directory: URL) -> RemoteConfigRef? {
        guard let remote = metaMap(in: directory)?["remote"]?.map,
              let repo = remote["repo"]?.string, !repo.isEmpty else { return nil }
        return RemoteConfigRef(repo: repo, branch: remote["branch"]?.string ?? "main",
                               path: remote["path"]?.string ?? "installer/config")
    }

    /// installer.yaml as a plain mapping; nil when it is missing or unreadable (its loader reports why).
    private static func metaMap(in directory: URL) -> YAMLMap? {
        let value: YAMLValue?
        do {
            value = try YAML.parseFile(directory.appendingPathComponent(ConfigLoader.metaFileName))
        } catch {
            return nil
        }
        return value?.map
    }

    /// Item kinds the config uses that `registry` does not know (a config written for a newer build).
    static func unknownKinds(in directory: URL, registry: ActionRegistry) -> [String] {
        let loaded: ConfigLoader.Result
        do {
            loaded = try ConfigLoader.load(from: directory)
        } catch {
            // Not loadable at all; the caller reports that error itself.
            return []
        }
        let known = Set(registry.kinds)
        var unknown = Set<String>()
        for item in loaded.config.steps.flatMap(\.rawItems) {
            guard let first = item.map.keys.first, !known.contains(first) else { continue }
            // A known kind that is merely not first is a mistake in the config, not a newer kind.
            if item.map.keys.contains(where: known.contains) || ItemConfig.commonKeys.contains(first) { continue }
            unknown.insert(first)
        }
        return unknown.sorted()
    }

    // MARK: Helpers

    static func requestedRef(remote: RemoteConfigRef, override: String?) -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty { return override }
        return remote.branch
    }

    static func validatedRepo(_ repo: String) throws -> String {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              repo.unicodeScalars.allSatisfy({ $0 == "/" || allowed.contains($0) }) else {
            throw RemoteConfigError.invalidRepo(repo)
        }
        return repo
    }

    /// The parts of git's ref-name rules that matter for building a URL: no `..`, no leading or trailing
    /// slash, no whitespace or control characters, none of `~^:?*[\`.
    static func isPlausibleRef(_ ref: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "~^:?*[\\").union(.whitespacesAndNewlines).union(.controlCharacters)
        return !ref.isEmpty && !ref.contains("..") && !ref.hasPrefix("/") && !ref.hasSuffix("/")
            && ref.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// `installer/config` style: trailing and leading slashes are tolerated, anything that could escape is not.
    static func validatedConfigPath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmed.isEmpty || FetchPlan.isSafeRelativePath(trimmed) else { throw RemoteConfigError.invalidConfigPath(path) }
        return trimmed
    }

    static func reason(for error: Error, timeout: TimeInterval) -> RemoteConfigError {
        let reason = RemoteConfigError.classify(error)
        if case .timedOut = reason { return .timedOut(seconds: timeout) }
        return reason
    }

    static func localLabel(_ local: ResolvedConfig, environment: SystemEnvironment) -> String {
        label(for: local.config.source, environment: environment)
    }

    /// "the config bundled with this installer", "the config at ~/.shawn/config", ...
    static func label(for source: ConfigSource, environment: SystemEnvironment) -> String {
        switch source {
        case .bundled:
            return "the config bundled with this installer"
        case .local(let path):
            return "the config at \(PathExpansion.abbreviate(path, home: environment.home))"
        case .remote(_, _, let commit):
            return "the previously downloaded config (\(commit.prefix(7)))"
        }
    }

    static func fallback(_ local: ResolvedConfig, note: String) -> ResolvedConfig {
        ResolvedConfig(config: local.config, plan: local.plan, notes: local.notes + [note])
    }
}
