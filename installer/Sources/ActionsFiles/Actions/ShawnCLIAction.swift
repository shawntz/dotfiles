import Foundation
import ShawnCore

/// `shawn-cli: install` puts the `shawn` command on this Mac with everything it needs to run on its own:
/// the binary, the web-app shell, a copy of the config, its settings file, zsh completions and an install record.
struct ShawnCLIAction: Action {
    /// Where the `shawn` binary goes (default `~/.local/bin`).
    let to: String
    /// The dotfiles checkout to record for the CLI (default `~/Developer/dotfiles`).
    let repo: String

    var title: String { "shawn CLI" }
    var subtitle: String? { "→ \(to.hasSuffix("/") ? to : to + "/")shawn" }

    static let descriptor = ActionDescriptor(
        kind: "shawn-cli",
        summary: "Install the shawn command: binary, WebAppShell, a copy of the config, settings, zsh completions.",
        example: """
        - shawn-cli: install
          to: ~/.local/bin              # default
          repo: ~/Developer/dotfiles    # the checkout the CLI updates itself from (default)
        """,
        make: { try make($0) }
    )

    private static func make(_ parser: ItemParser) throws -> any Action {
        let value = parser.primaryString()
        if value != "install" && !value.isEmpty {
            parser.fail("the only value 'shawn-cli' takes is 'install' (got '\(value)')")
        }
        let to = parser.options.string("to", default: "~/.local/bin")
        let repo = parser.options.string("repo", default: "~/Developer/dotfiles")
        if to.isEmpty { parser.options.error("'to' must not be empty", key: "to") }
        if repo.isEmpty { parser.options.error("'repo' must not be empty", key: "repo") }
        return ShawnCLIAction(to: to, repo: repo)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, [("to", to), ("repo", repo)])
    }

    // MARK: Locations

    struct Locations {
        let helpers: URL?
        let bundledShawn: URL?
        let bundledShell: URL?
        let installedShawn: URL
        let installedShell: URL
        let configMirror: URL
        let settings: URL
        let completions: URL
        let state: URL
    }

    /// Bundled helpers live in `environment.helpersDirectory` (the app's `Contents/Helpers`), or next to the
    /// running executable when run from a build directory or from the CLI itself.
    static func helpersDirectory(_ environment: SystemEnvironment) -> URL? {
        environment.helpersDirectory ?? Bundle.main.executableURL?.deletingLastPathComponent()
    }

    func locations(_ context: ActionContext) -> Locations {
        let environment = context.environment
        let helpers = Self.helpersDirectory(environment)
        let fileManager = FileManager.default
        let shawn = helpers?.appendingPathComponent("shawn")
        let shell = helpers?.appendingPathComponent("WebAppShell")
        return Locations(
            helpers: helpers,
            bundledShawn: shawn.flatMap { fileManager.isExecutableFile(atPath: $0.path) ? $0 : nil },
            bundledShell: shell.flatMap { fileManager.isExecutableFile(atPath: $0.path) ? $0 : nil },
            installedShawn: context.path(to).appendingPathComponent("shawn"),
            installedShell: environment.stateDirectory.appendingPathComponent("bin/WebAppShell"),
            configMirror: environment.stateDirectory.appendingPathComponent("config"),
            settings: environment.home.appendingPathComponent(".config/shawn/config.yaml"),
            completions: environment.home.appendingPathComponent(".local/share/zsh/site-functions/_shawn"),
            state: environment.stateDirectory.appendingPathComponent("state/cli.json")
        )
    }

    /// `~/.config/shawn/config.yaml`, in the same shape `ShawnSettings` (ShawnSync) writes and reads.
    func settingsText(_ context: ActionContext) -> String {
        let repoPath = context.path(repo).path
        let configPath = context.config.meta.remote?.path ?? "installer/config"
        return """
        # Written by Shawn's Dotfiles. Tells the `shawn` CLI where things live.
        dotfiles_repo: \(YAMLText.scalar(repoPath))
        config_path: \(YAMLText.scalar(configPath))

        """
    }

    func mirrorIsCurrent(_ context: ActionContext, _ locations: Locations) -> Bool {
        let root = context.config.root.standardizedFileURL
        if root.path == locations.configMirror.standardizedFileURL.path { return true }
        return context.files.directoryMatches(source: root, destination: locations.configMirror, exact: true)
    }

    // MARK: Check & run

    func check(_ context: ActionContext) async -> CheckResult {
        let locations = locations(context)
        let files = context.files
        guard let bundledShawn = locations.bundledShawn else {
            return .needed("no bundled shawn binary in \(locations.helpers.map(context.display) ?? "the app")")
        }
        var stale: [String] = []
        if !files.fileMatches(source: bundledShawn, destination: locations.installedShawn, permissions: 0o755) { stale.append("binary") }
        if let shell = locations.bundledShell, !files.fileMatches(source: shell, destination: locations.installedShell, permissions: 0o755) {
            stale.append("WebAppShell")
        }
        if !mirrorIsCurrent(context, locations) { stale.append("config copy") }
        if !files.fileMatches(Data(settingsText(context).utf8), at: locations.settings) { stale.append("settings") }
        if stale.isEmpty { return .satisfied("shawn is installed and current") }
        return .needed("to update: \(stale.joined(separator: ", "))")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let locations = locations(context)
        let files = context.files
        guard let bundledShawn = locations.bundledShawn else {
            let place = locations.helpers.map(context.display) ?? "next to the installer"
            if context.dryRun {
                context.info("[dry-run] would install the shawn CLI to \(context.display(locations.installedShawn)) (no bundled binary in \(place) to copy from here)")
                return .done("would be installed")
            }
            throw ActionError("the shawn binary was not found in \(place)",
                              hint: "run the installer app (it carries the CLI), or build it with 'swift build -c release --product shawn' and run from the build folder")
        }

        let binaryChanged: Bool
        do {
            // Binaries are rebuilt artefacts, so the old copy is replaced rather than backed up. The write is
            // atomic (a new file), which leaves a running `shawn` process undisturbed.
            binaryChanged = try files.installFile(from: bundledShawn, to: locations.installedShawn, permissions: 0o755, backup: false).didChange
        } catch {
            throw context.fileError(error, doing: "install the shawn CLI")
        }
        // cli.json describes the installed binary, and the self-updater trusts it. It is written when the binary
        // changes, and when there is no usable record; a record for an unchanged binary is left as it is, provenance
        // (sourceTree, commit) included. So it is written right after the binary, before anything below can fail:
        // after a run stopped part-way, the next run finds the binary unchanged and keeps whatever record is there.
        if binaryChanged || existingRecord(locations) == nil {
            try recordInstall(context, locations, source: bundledShawn)
        }

        var changed: [String] = binaryChanged ? [context.display(locations.installedShawn)] : []
        do {
            if let shell = locations.bundledShell {
                if try files.installFile(from: shell, to: locations.installedShell, permissions: 0o755, backup: false).didChange {
                    changed.append("WebAppShell")
                }
            } else if !FileManager.default.isExecutableFile(atPath: locations.installedShell.path) {
                // Run from the CLI, the helpers folder is ~/.local/bin, which never holds WebAppShell; the copy an
                // earlier install put in ~/.shawn/bin is the one `shawn add webapp` uses, so only its absence matters.
                context.warn("WebAppShell was not found next to the installer; 'shawn add webapp' will need it later")
            }
            if !mirrorIsCurrent(context, locations) {
                let count = try files.installDirectory(from: context.config.root, to: locations.configMirror, replace: true, backup: false)
                changed.append("config copy (\(counted(count, "file")))")
            }
            if try files.write(Data(settingsText(context).utf8), to: locations.settings, permissions: 0o644, backup: true).didChange {
                changed.append(context.display(locations.settings))
            }
        } catch {
            throw context.fileError(error, doing: "install the shawn CLI")
        }

        await installCompletions(context, locations)

        let verb = context.dryRun ? "would install" : "installed"
        if changed.isEmpty { return .done("shawn \(ShawnCore.version) already installed") }
        return .done("\(verb) shawn \(ShawnCore.version): \(changed.joined(separator: ", "))")
    }

    /// Asks the installed binary for its zsh completion script. A failure here only costs tab completion.
    func installCompletions(_ context: ActionContext, _ locations: Locations) async {
        var command = Command(locations.installedShawn.path, ["completions", "zsh"])
            .env(["SHAWN_NO_UPDATE": "1", "NO_COLOR": "1"])
            .timeout(30)
            .labeled("\(context.display(locations.installedShawn)) completions zsh")
        command.quiet = true
        let result: CommandResult
        do {
            result = try await context.run(command)
        } catch {
            context.warn("could not generate zsh completions: \(InstallEngine.describe(error))")
            return
        }
        if result.wasDryRun { return }
        guard result.succeeded, !result.output.isEmpty else {
            let reason = result.succeeded ? "it printed nothing" : result.tail(3)
            context.warn("could not generate zsh completions (\(reason)); run 'shawn completions zsh > \(context.display(locations.completions))' later")
            return
        }
        do {
            try context.files.write(Data(result.stdout.utf8), to: locations.completions, permissions: 0o644, backup: false)
        } catch {
            context.warn("could not write \(context.display(locations.completions)): \(InstallEngine.describe(error))")
        }
    }

    /// The current `cli.json`, or nil when it is missing or not a JSON object.
    func existingRecord(_ locations: Locations) -> JSONObject? {
        guard let data = FileManager.default.contents(atPath: locations.state.path) else { return nil }
        return (try? JSONParser.parse(data))?.object
    }

    /// Which sources a bundled binary was built from, as `scripts/build-app.sh` records them in
    /// `Contents/Resources/build-info.json` (next to `Contents/Helpers`).
    struct BuildInfo {
        /// The content id of the package's Sources, Package.swift and Package.resolved; the CLI's self-update
        /// compares it with the checkout to decide whether to rebuild.
        let sourceTree: String
        let commit: String?
    }

    /// The build info for binaries in `helpers`. Nil when the build's sources are unknown: no file (a build folder,
    /// or the CLI's own `~/.local/bin`), or an empty `sourceTree` (built from uncommitted sources or outside git).
    static func buildInfo(helpers: URL?, context: ActionContext) -> BuildInfo? {
        guard let helpers else { return nil }
        let url = helpers.deletingLastPathComponent().appendingPathComponent("Resources/build-info.json")
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let object = (try? JSONParser.parse(data))?.object, case .string(let sourceTree)? = object["sourceTree"] else {
            context.warn("\(context.display(url)) is not a valid build record, so cli.json will not say which sources this shawn "
                + "was built from (building the app again with scripts/build-app.sh writes a new one)")
            return nil
        }
        guard !sourceTree.isEmpty else { return nil }
        if case .string(let commit)? = object["commit"], !commit.isEmpty {
            return BuildInfo(sourceTree: sourceTree, commit: commit)
        }
        return BuildInfo(sourceTree: sourceTree, commit: nil)
    }

    /// `~/.shawn/state/cli.json`: what was installed, when, from where, and, when the build recorded it, which
    /// sources it was built from. A fresh record on purpose: anything a previous self-update stored about the
    /// source tree it built from does not describe the binary installed now.
    func recordInstall(_ context: ActionContext, _ locations: Locations, source: URL) throws {
        var record = JSONObject([
            "version": .string(ShawnCore.version),
            "installedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "source": .string(source.path),
        ])
        if let build = Self.buildInfo(helpers: locations.helpers, context: context) {
            record["sourceTree"] = .string(build.sourceTree)
            if let commit = build.commit { record["commit"] = .string(commit) }
        }
        do {
            try context.files.write(Data(JSONValue.object(record).rendered().utf8), to: locations.state, permissions: 0o644, backup: false)
        } catch {
            throw context.fileError(error, doing: "record the install in \(context.display(locations.state))")
        }
    }
}
