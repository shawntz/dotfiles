import Foundation
import ShawnCore
import ShawnSync

/// Wires `SelfUpdater` to a CLI invocation.
enum SelfUpdateRunner {
    /// Set in the environment of a process re-executed after an update; it never updates again (loop guard).
    static let reexecMarker = "SHAWN_SELF_UPDATED"

    enum AutomaticOutcome: Equatable {
        case `continue`
        case configChanged
        case restart(URL)
    }

    static func updater(context: CLIContext, verbose: Bool, timeouts: SelfUpdater.Timeouts = SelfUpdater.Timeouts()) -> SelfUpdater {
        let prefix = verbose ? "" : "shawn: "
        return SelfUpdater(
            git: context.git,
            builder: context.builder,
            releases: context.releases,
            remoteConfig: context.remoteConfig,
            clock: context.services.clock,
            store: context.stateStore,
            launcher: context.launcher,
            timeouts: timeouts,
            note: { context.note(prefix + $0) },
            detail: { text in if verbose { context.err.line(context.errorStyle.muted("  " + text)) } }
        )
    }

    static func request(context: CLIContext, force: Bool, checkOnly: Bool) -> SelfUpdater.Request {
        let settings = context.settings
        // `installer/config` → `installer`: the Swift package sits next to its config.
        let package = (settings.configPath as NSString).deletingLastPathComponent
        return SelfUpdater.Request(
            checkout: context.checkout,
            packagePath: package,
            // git reads a relative path from the checkout, and takes an absolute one inside it. It does not expand `~`.
            configPath: PathExpansion.expandTilde(settings.configPath, home: context.environment.home),
            remote: context.lightConfig()?.meta.remote,
            installedBinary: context.shawnBinary,
            currentVersion: ShawnCore.version,
            home: context.environment.home,
            temporaryDirectory: context.environment.temporaryDirectory,
            mode: context.cli.selfUpdate.mode,
            force: force,
            checkOnly: checkOnly
        )
    }

    /// The check that runs before every command.
    static func automatic(context: CLIContext) async -> AutomaticOutcome {
        var request = request(context: context, force: false, checkOnly: false)
        request.appliesSetup = appliesSetup(context.arguments, environment: context.environment.baseEnvironment)
        let report = await updater(context: context, verbose: false).run(request)
        if let binary = report.restartWith { return .restart(binary) }
        return report.configChanged ? .configChanged : .continue
    }

    /// True when `arguments` run `shawn sync` (or `shawn install`) over the whole config: no dry run, no help, no
    /// --only, --skip or --config. Right after a pull that command applies what the pull brought.
    static func appliesSetup(_ arguments: [String], environment: [String: String]) -> Bool {
        let install = InstallCommand()
        guard let invocation = try? Dispatcher.parseGlobals(arguments, environment: environment),
              !invocation.printHelp, invocation.options.configPath == nil,
              let command = invocation.command, command == install.name || install.aliases.contains(command),
              let parsed = try? ArgumentParser.parse(invocation.arguments, options: install.options) else { return false }
        return !parsed.has("dry-run") && !parsed.has("help") && parsed.values.isEmpty && parsed.positionals.isEmpty
    }

    /// Re-executes the updated binary with the same arguments and the loop-guard marker.
    static func restartRequest(binary: URL, arguments: [String], context: CLIContext) -> ExecRequest {
        var environment = context.environment.baseEnvironment
        environment[reexecMarker] = "1"
        return ExecRequest(path: binary.path, argv: [binary.path] + arguments, environment: environment)
    }
}

struct UpdateCommand: BuiltinCommand {
    let name = "update"
    let section = BuiltinSection.config
    let summary = "Pull the latest shawn and config from GitHub right now"
    let usage = "[--check] [--rebuild]"
    let details: String? = """
    Does what happens quietly before every command, but always and out loud. With a checkout, it fast-forwards \
    the checkout when it is clean and on its branch, and rebuilds shawn when its Swift sources changed or when \
    nothing records which sources it was built from. It only builds from sources the remote has, so push any \
    commits that change the Swift sources first. Without a checkout, it refreshes the config from GitHub and \
    installs a newer shawn-v* release after checking its sha256. --rebuild rebuilds from the checkout even when \
    the record says shawn is current (for a binary copied in by hand). The exit status is 0 only when everything \
    is current afterwards, or, with --check, when the update could go ahead as things stand. \
    Set self_update.mode in cli.yaml to always, daily or off for the automatic check.
    """
    let options = [
        OptionSpec("check", "Only report what would change"),
        OptionSpec("rebuild", "Rebuild shawn from the checkout even if it looks current"),
    ]

    /// The line `shawn update` ends on.
    struct Summary: Equatable {
        enum Mark: Equatable {
            case done
            case available
            case warning
            case failed
        }

        var mark: Mark
        var text: String
        var exitCode: Int32
    }

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        var request = SelfUpdateRunner.request(context: context, force: true, checkOnly: parsed.has("check"))
        request.rebuild = parsed.has("rebuild")
        let style = context.style
        if let checkout = request.checkout {
            context.out.line(style.heading("shawn \(ShawnCore.version)") + style.muted(" · checkout \(context.display(checkout))"))
        } else if request.rebuild {
            context.fail("shawn update --rebuild: there is no dotfiles checkout to build from "
                         + "(set dotfiles_repo in \(context.display(ShawnSettings.fileURL(environment: context.environment))))")
            return ExitCode.usage
        } else {
            context.out.line(style.heading("shawn \(ShawnCore.version)") + style.muted(" · no checkout; using releases from \(request.remote?.repo ?? "GitHub")"))
        }
        let report = await SelfUpdateRunner.updater(context: context, verbose: true).run(request)
        let summary = Self.summary(of: report)
        let mark: String
        switch summary.mark {
        case .done: mark = style.ok("✓")
        case .available: mark = style.warn("↑")
        case .warning: mark = style.warn("!")
        case .failed: mark = style.bad("✗")
        }
        context.out.line(mark + " " + summary.text)
        return summary.exitCode
    }

    /// What `shawn update` says last, and its exit status, for every outcome: success only when shawn and the
    /// config are current afterwards (or, with `--check`, when the check itself worked).
    static func summary(of report: SelfUpdater.Report) -> Summary {
        let pulled = report.pulledCommits > 0 ? "pulled \(report.pulledCommits) commit\(report.pulledCommits == 1 ? "" : "s")" : nil
        func afterPull(_ text: String, joiner: String = ", but ") -> String { pulled.map { $0 + joiner + text } ?? text }
        switch report.outcome {
        case .upToDate:
            return Summary(mark: .done, text: "up to date", exitCode: ExitCode.ok)
        case .pulled(let commits):
            return Summary(mark: .done, text: "pulled \(commits) commit\(commits == 1 ? "" : "s"); shawn itself did not change", exitCode: ExitCode.ok)
        case .rebuilt:
            return Summary(mark: .done, text: pulled.map { "\($0) and rebuilt shawn from the new sources" } ?? "rebuilt shawn from the sources in the checkout",
                           exitCode: ExitCode.ok)
        case .releaseInstalled(let version):
            return Summary(mark: .done, text: "installed shawn \(version)", exitCode: ExitCode.ok)
        case .updateAvailable(let what):
            return Summary(mark: .available, text: "update available: \(what). Run 'shawn update' to get it", exitCode: ExitCode.ok)
        case .disabled:
            return Summary(mark: .warning, text: "self-update is off (self_update.mode: off in cli.yaml)", exitCode: ExitCode.ok)
        case .notDue:
            return Summary(mark: .done, text: "checked less than a day ago (self_update.mode: daily)", exitCode: ExitCode.ok)
        case .nothingToCheck:
            return Summary(mark: .warning, text: "nothing to check: there is no dotfiles checkout and installer.yaml has no 'remote:'", exitCode: ExitCode.failure)
        case .offline(let reason):
            return Summary(mark: .warning, text: "could not reach the remote (\(reason)); nothing changed. Try again when you are online", exitCode: ExitCode.unavailable)
        case .checkFailed(let reason):
            return Summary(mark: .failed, text: reason, exitCode: ExitCode.failure)
        case .fetchFailed(let reason):
            return Summary(mark: .failed, text: "could not fetch the new commits (\(reason)); nothing changed", exitCode: ExitCode.failure)
        case .skipped(let reason):
            return Summary(mark: .warning, text: pulled.map { "\($0), but skipped rebuilding shawn: \(reason)" } ?? "skipped: \(reason)", exitCode: ExitCode.failure)
        case .buildFailed(let reason):
            return Summary(mark: .failed, text: afterPull("the rebuild failed (\(reason)); the current shawn is still installed"), exitCode: ExitCode.failure)
        case .notReplaced(let reason):
            return Summary(mark: .warning, text: afterPull(reason, joiner: "; "), exitCode: ExitCode.failure)
        case .installFailed(let reason):
            return Summary(mark: .failed, text: afterPull("couldn't put the new shawn in place (\(reason)); the current one is still installed"), exitCode: ExitCode.failure)
        case .releaseRejected(let reason):
            return Summary(mark: .failed, text: "rejected the download: \(reason); the current shawn is still installed", exitCode: ExitCode.failure)
        case .downloadFailed(let reason):
            return Summary(mark: .failed, text: "couldn't download the new shawn (\(reason)); the current one is still installed", exitCode: ExitCode.failure)
        }
    }
}

struct VersionCommand: BuiltinCommand {
    let name = "version"
    let section = BuiltinSection.config
    let summary = "Version, where the config comes from, last update check"

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard parsed != nil else { return code }
        let style = context.style
        let state = context.stateStore.load()
        var rows: [(String, String)] = []
        if let place = context.configLocation() {
            rows.append(("config", "\(context.display(place.url))" + (place.source == .bundled ? " (bundled)" : "")))
        } else {
            rows.append(("config", "none found"))
        }
        rows.append(("checkout", context.checkout.map(context.display) ?? "none (updates come from releases)"))
        rows.append(("binary", context.display(context.shawnBinary)))
        rows.append(("self-update", context.cli.selfUpdate.mode.rawValue))
        if let last = state.lastCheck {
            rows.append(("last check", Self.relative(last, now: context.services.clock.now()) + (state.lastResult.map { " · \($0)" } ?? "")))
        } else {
            rows.append(("last check", "never"))
        }
        if let tag = state.latestTag { rows.append(("latest release", tag)) }
        context.out.line(style.heading("shawn \(ShawnCore.version)"))
        let width = (rows.map { $0.0.count }.max() ?? 0) + 2
        for (key, value) in rows {
            context.out.line("  " + style.muted(TextWidth.pad(key, to: width)) + value)
        }
        return ExitCode.ok
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86_400) days ago"
    }
}
