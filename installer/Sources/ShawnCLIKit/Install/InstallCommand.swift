import Darwin
import Foundation
import ShawnCore
import ShawnFun
import ShawnSync

struct InstallCommand: BuiltinCommand {
    let name = "install"
    let aliases = ["sync"]
    let section = BuiltinSection.setup
    let summary = "Set this Mac up from the config (safe to re-run)"
    let usage = "[--dry-run] [--only step,…] [--skip step,…] [--yes] [--fresh] [--config DIR] [--no-remote]"
    let details: String? = """
    Runs every step of the config, the same engine as the app. Items that are already in place are skipped, so it \
    is safe to run again after a failure. It asks for the administrator password itself (echo off) only when an \
    item needs it; --dry-run changes nothing and asks nothing.
    """
    let options = [
        OptionSpec("dry-run", short: "n", "Show what would happen; change nothing"),
        OptionSpec("only", value: "STEPS", "Run only these steps (comma-separated ids)"),
        OptionSpec("skip", value: "STEPS", "Leave these steps out"),
        OptionSpec("yes", short: "y", "Do not ask for confirmation; questions take their default answer"),
        OptionSpec("fresh", "Treat every item as not done yet (demos)"),
        OptionSpec("config", value: "DIR", "Use this config directory"),
        OptionSpec("no-remote", "Do not fetch the latest config from GitHub"),
    ]

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        if !parsed.positionals.isEmpty {
            context.fail("shawn install: unexpected argument '\(parsed.positionals[0])' (steps go in --only)")
            return ExitCode.usage
        }
        let dryRun = parsed.has("dry-run")
        let explicit = parsed.value("config").map { URL(fileURLWithPath: $0) } ?? context.globals.configPath
        let resolved: ResolvedConfig
        do {
            let options = ConfigResolveOptions(explicitPath: explicit, allowRemote: !parsed.has("no-remote"))
            resolved = try await ConfigResolver.resolve(options: options, registry: context.registry, environment: context.environment, bundle: context.bundle)
        } catch {
            context.fail("shawn install: \(error)")
            return ExitCode.failure
        }
        for note in resolved.notes { context.note(note) }
        for warning in resolved.plan.warnings { context.warn(warning.description) }

        guard let selection = Self.selection(for: resolved.plan, only: parsed.list("only"), skip: parsed.list("skip"), context: context) else {
            return ExitCode.usage
        }
        let items = selection.enabledItems(in: resolved.plan)
        if items.isEmpty {
            context.note("nothing to do: no items are switched on")
            return ExitCode.ok
        }

        let interactive = context.terminal.stdinIsTTY || context.terminal.stderrIsTTY
        if !dryRun && !parsed.has("yes") {
            guard interactive else {
                context.fail("shawn install: not running in a terminal, so I can't ask before changing this Mac. Add --yes to go ahead")
                return ExitCode.usage
            }
            let steps = resolved.plan.steps.filter { selection.isEnabled(step: $0) }.count
            guard TTY.confirm("Set up this Mac: \(items.count) items in \(steps) steps from \(resolved.config.source)?") else {
                context.note("ok, nothing changed")
                return ExitCode.ok
            }
        }

        let interaction = context.interaction(TerminalInteraction.Options(assumeYes: parsed.has("yes"), allowPrompts: interactive && !dryRun))
        let engine = InstallEngine(plan: resolved.plan, environment: context.environment,
                                   options: RunOptions(dryRun: dryRun, assumeFresh: parsed.has("fresh")), interaction: interaction)
        let desktop: (any DesktopActions)? = interactive && !context.environment.isSandbox && !dryRun ? context.services.desktop : nil
        let renderer = InstallRenderer(plan: resolved.plan, selection: selection, fun: FunConfig.load(from: resolved.config).fun,
                                       terminal: context.terminal, out: context.out, desktop: desktop)
        let summary = await Self.run(engine: engine, selection: selection, renderer: renderer, catchInterrupts: interactive, context: context)
        if summary.wasCancelled { return ExitCode.interrupted }
        return summary.failures.isEmpty ? ExitCode.ok : ExitCode.failure
    }

    /// Runs the engine, turning the first Ctrl-C into a clean stop (the item in progress is cancelled, its
    /// command terminated, an open question or password prompt withdrawn, and the summary still printed)
    /// and a second one into an immediate exit.
    static func run(engine: InstallEngine, selection: Selection, renderer: InstallRenderer, catchInterrupts: Bool, context: CLIContext) async -> InstallSummary {
        let prompts = PromptScope()
        let task = Task {
            await PromptScope.$current.withValue(prompts) {
                await engine.run(selection: selection, onEvent: { renderer.handle($0) })
            }
        }
        var source: (any DispatchSourceSignal)?
        if catchInterrupts {
            signal(SIGINT, SIG_IGN)
            let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
            let handler = InterruptHandler(err: context.err, style: context.errorStyle, prompts: prompts, cancel: { task.cancel() }, quit: { exit($0) })
            interrupts.setEventHandler { handler.handle() }
            interrupts.resume()
            source = interrupts
        }
        let summary = await task.value
        if let source {
            source.cancel()
            signal(SIGINT, SIG_DFL)
        }
        return summary
    }

    /// `--only` / `--skip` applied to the defaults, with unknown step ids reported.
    static func selection(for plan: InstallPlan, only: [String], skip: [String], context: CLIContext) -> Selection? {
        let ids = plan.steps.map(\.id)
        for id in only + skip where !ids.contains(id) {
            let hint = Suggest.closest(to: id, in: ids).map { ". Did you mean '\($0)'?" } ?? ""
            context.fail("shawn: there is no step '\(id)'\(hint) (steps: \(ids.joined(separator: ", ")))")
            return nil
        }
        var selection = Selection.defaults(for: plan)
        if !only.isEmpty {
            selection = Selection.only(steps: only, in: plan)
        }
        for id in skip { selection.setStep(id, enabled: false) }
        return selection
    }
}

/// What `shawn install` does on Ctrl-C.
final class InterruptHandler: @unchecked Sendable {
    enum Action: Equatable {
        /// Cancel the run: the engine stops the current item and prints its summary.
        case cancelRun
        /// Exit 130 now.
        case quit
    }

    private let err: any OutputSink
    private let style: Style
    private let prompts: PromptScope
    private let cancel: @Sendable () -> Void
    private let quit: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var presses = 0

    /// `prompts` is the scope the run's prompts are asked in; `cancel` cancels the run's task.
    init(err: any OutputSink, style: Style, prompts: PromptScope, cancel: @escaping @Sendable () -> Void, quit: @escaping @Sendable (Int32) -> Void) {
        self.err = err
        self.style = style
        self.prompts = prompts
        self.cancel = cancel
        self.quit = quit
    }

    /// The first Ctrl-C stops the run cleanly, the second quits. A question or password prompt that is open
    /// is no obstacle: withdrawing the run's prompts ends its read within a moment (`PromptScope`).
    static func action(press: Int) -> Action {
        press == 1 ? .cancelRun : .quit
    }

    func handle() {
        let press = lock.withLock { () -> Int in
            presses += 1
            return presses
        }
        switch Self.action(press: press) {
        case .cancelRun:
            err.write("\r\u{1B}[2K" + style.warn("■") + " stopping: cancelling the item in progress, then the summary… (Ctrl-C again to quit now)\n")
            // The run first, so that a withdrawn password prompt (no answer) finds the run already stopping.
            cancel()
            // Echo stays as it is: a password prompt keeps it off until its read has ended, and then puts it back.
            prompts.withdraw()
        case .quit:
            // A password prompt may still have echo off: put it back before exiting.
            TTY.restore()
            err.write("\n")
            quit(ExitCode.interrupted)
        }
    }
}

/// Loading the full config (every step and item) for the commands that need the plan.
enum PlanLoader {
    /// From disk only, never the network.
    ///
    /// A config somebody named (`directory`, `--config`) is used as it is, problems and all. Otherwise the
    /// config the CLI is using is loaded; when that one is a snapshot that does not load with this build
    /// (the copy a previous install left in `~/.shawn/config`, or one fetched from GitHub), the search goes
    /// on to the next config on disk and a note says which one was skipped. A working copy the user edits
    /// is never skipped: its problems are reported.
    static func local(context: CLIContext, directory: URL? = nil) -> Result<ResolvedConfig, ConfigResolveError> {
        if let named = directory ?? context.globals.configPath {
            return load(explicit: named, context: context)
        }
        guard let location = context.configLocation() else { return load(explicit: nil, context: context) }
        let first = load(explicit: location.url, context: context)
        guard case .failure(let problem) = first else { return first }

        // `ConfigResolver` skips snapshots that do not load and stops at a working copy that does not.
        let searched = load(explicit: nil, context: context)
        guard case .success(let other) = searched else {
            // Nothing else loads. Its error names the snapshot and how to replace it; keep the first error
            // when that config (fetched from GitHub) is one the resolver never looks at.
            return isInstalledOrBundled(location, context: context) ? searched : first
        }
        if other.notes.isEmpty {
            let reason = problem.issues.first.map(\.description) ?? problem.message
            context.note(ActionError.sentences(
                "Skipped the config at \(context.display(location.url)). It does not load with this shawn (\(ShawnCore.version)): \(reason)",
                "using \(context.display(other.config.root)) instead."))
        }
        for note in other.notes { context.note(note) }
        return .success(other)
    }

    private static func load(explicit: URL?, context: CLIContext) -> Result<ResolvedConfig, ConfigResolveError> {
        do {
            let options = ConfigResolveOptions(explicitPath: explicit, allowRemote: false)
            return .success(try ConfigResolver.resolveLocal(options: options, registry: context.registry, environment: context.environment, bundle: context.bundle))
        } catch let error as ConfigResolveError {
            return .failure(error)
        } catch {
            return .failure(ConfigResolveError(String(describing: error)))
        }
    }

    /// True for the two snapshots `ConfigResolver` knows how to skip and describe.
    private static func isInstalledOrBundled(_ location: ConfigPlace, context: CLIContext) -> Bool {
        let path = location.url.standardizedFileURL.path
        if path == ConfigLocator.installedConfigDirectory(environment: context.environment).standardizedFileURL.path { return true }
        return path == ConfigLocator.bundledConfigDirectory(bundle: context.bundle)?.standardizedFileURL.path
    }
}
