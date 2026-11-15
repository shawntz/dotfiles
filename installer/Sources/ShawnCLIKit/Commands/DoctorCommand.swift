import Foundation
import ShawnCore
import ShawnSync

struct DoctorCommand: BuiltinCommand {
    let name = "doctor"
    let section = BuiltinSection.setup
    let summary = "Read-only health check of this Mac against the config"
    let details: String? = """
    Runs every enabled item's check (it changes nothing) and a few environment checks: Homebrew, git identity, \
    GitHub CLI login, an SSH key, and ~/.local/bin on PATH. Exits 1 when anything is missing. Items that have \
    no way to tell whether they are done (opening an app, a reminder without a check:) are listed under \
    "Can't be checked" and never count as missing. So are items that need an answer this Mac has not given yet \
    (see 'shawn config answers'); doctor never asks.
    """

    struct Check: Equatable {
        var name: String
        var ok: Bool
        var detail: String
    }

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard parsed != nil else { return code }
        let style = context.style
        var missing = 0

        switch PlanLoader.local(context: context) {
        case .failure(let error):
            context.fail("shawn doctor: \(error)")
            missing += 1
        case .success(let resolved):
            context.out.line(style.heading("Config") + style.muted(" · \(resolved.config.source)"))
            missing += await scan(resolved.plan, context: context)
        }

        context.out.line("")
        context.out.line(style.heading("This Mac"))
        for check in await Self.environmentChecks(context: context) {
            context.out.line("  " + (check.ok ? style.ok("✓") : style.bad("✗")) + " " + TextWidth.pad(check.name, to: 16) + style.muted(check.detail))
            if !check.ok { missing += 1 }
        }
        context.out.line("")
        if missing == 0 {
            context.out.line(style.ok("All good.") + " " + style.fg(Palette.star, "\"\(context.fun.line(for: .success, seed: Int.random(in: 0..<1000)))\""))
            return ExitCode.ok
        }
        context.out.line(style.warn("\(missing) thing\(missing == 1 ? "" : "s") to fix.") + style.muted(" 'shawn install' takes care of the config items."))
        return ExitCode.failure
    }

    /// Checks every enabled item; prints one line per step and the items still to do, then the items no
    /// check can confirm under their own heading. Returns how many items are missing (never counting those).
    /// An item that needs a question with no saved answer is not checked: its text is not complete yet. Neither is
    /// an item that needs a file only such an item would make (`InstallPlan.waitingQuestions`).
    func scan(_ plan: InstallPlan, context: CLIContext) async -> Int {
        let style = context.style
        let defaults = Selection.defaults(for: plan)
        let engine = InstallEngine(plan: plan, environment: context.environment, options: RunOptions(dryRun: true))
        let answers = AnswerStore(environment: context.environment).answers(for: plan.config.meta.ask)
        let waiting = plan.waitingQuestions(for: defaults.enabledItems(in: plan), unanswered: InstallEngine.unanswered(plan.config, answers))
            .mapValues(InstallEngine.waitingMessage)
        let canCheck: (PlannedItem) -> Bool = { $0.action.isCheckable && waiting[$0.id] == nil }
        // Only items that can say "already done" are worth a check.
        var selection = defaults
        for item in plan.allItems where !canCheck(item) { selection.itemOverrides[item.id] = false }
        let results = ResultBox()
        await engine.scan(selection: selection) { id, result in results.set(id, result) }
        var missing = 0
        var uncheckable: [(step: String, item: PlannedItem)] = []
        for step in plan.steps where defaults.isEnabled(step: step) {
            let items = step.items.filter { defaults.isEnabled(item: $0) }
            guard !items.isEmpty else { continue }
            let checkable = items.filter(canCheck)
            let unknown = items.filter { !canCheck($0) }
            uncheckable += unknown.map { (step.config.title, $0) }
            let unknownNote = unknown.isEmpty ? "" : " · \(unknown.count) can't be checked"
            guard !checkable.isEmpty else {
                context.out.line("  \(style.muted("·")) " + TextWidth.pad(step.config.title, to: 28) + style.muted("\(unknown.count) can't be checked"))
                continue
            }
            let stillToDo = checkable.filter { results.get($0.id)?.isSatisfied != true }
            let mark = stillToDo.isEmpty ? style.ok("✓") : style.bad("✗")
            context.out.line("  \(mark) " + TextWidth.pad(step.config.title, to: 28) + style.muted("\(checkable.count - stillToDo.count)/\(checkable.count)" + unknownNote))
            for item in stillToDo {
                var reason = ""
                if case .needed(let why?)? = results.get(item.id) { reason = ": \(why)" }
                context.out.line("      " + style.bad("·") + " \(item.title)" + style.muted(" (\(item.config.kind))\(reason)"))
            }
            missing += stillToDo.count
        }
        if !uncheckable.isEmpty {
            context.out.line("")
            context.out.line(style.heading("Can't be checked (\(uncheckable.count))") + style.muted(" · nothing can tell whether these are done, so they never count as missing"))
            for entry in uncheckable {
                let reason = waiting[entry.item.id].map { " · \($0)" } ?? ""
                context.out.line("  " + style.muted("·") + " \(entry.item.title)" + style.muted(" (\(entry.item.config.kind)) · \(entry.step)\(reason)"))
            }
        }
        return missing
    }

    static func environmentChecks(context: CLIContext) async -> [Check] {
        let environment = context.environment
        var checks: [Check] = []

        let brew = environment.brewExecutable
        checks.append(FileManager.default.isExecutableFile(atPath: brew)
            ? Check(name: "Homebrew", ok: true, detail: context.display(URL(fileURLWithPath: brew)))
            : Check(name: "Homebrew", ok: false, detail: "not installed at \(brew)"))

        let name = await context.git.run(["config", "--global", "--get", "user.name"], in: nil, timeout: 10)
        let email = await context.git.run(["config", "--global", "--get", "user.email"], in: nil, timeout: 10)
        if name.succeeded && email.succeeded && !name.output.isEmpty && !email.output.isEmpty {
            checks.append(Check(name: "git identity", ok: true, detail: "\(name.output) <\(email.output)>"))
        } else {
            checks.append(Check(name: "git identity", ok: false, detail: "user.name / user.email are not set (git config --global)"))
        }

        if ToolLocator.find("gh", environment: environment) == nil {
            checks.append(Check(name: "GitHub CLI", ok: false, detail: "gh is not installed"))
        } else {
            let status = await context.capture("gh", ["auth", "status", "--hostname", "github.com"], timeout: 15)
            checks.append(status.succeeded
                ? Check(name: "GitHub CLI", ok: true, detail: "logged in to github.com")
                : Check(name: "GitHub CLI", ok: false, detail: "not logged in (gh auth login)"))
        }

        let ssh = environment.home.appendingPathComponent(".ssh")
        let keys = ((try? FileManager.default.contentsOfDirectory(atPath: ssh.path)) ?? []).filter { $0.hasSuffix(".pub") }.sorted()
        checks.append(keys.isEmpty
            ? Check(name: "SSH key", ok: false, detail: "no public key in ~/.ssh")
            : Check(name: "SSH key", ok: true, detail: keys.map { "~/.ssh/\($0)" }.joined(separator: ", ")))

        let localBin = environment.localBin.standardizedFileURL.path
        let path = (environment.baseEnvironment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: PathExpansion.expandTilde(String($0).replacingOccurrences(of: "$HOME", with: environment.home.path), home: environment.home)).standardizedFileURL.path
        }
        checks.append(path.contains(localBin)
            ? Check(name: "PATH", ok: true, detail: "includes ~/.local/bin")
            : Check(name: "PATH", ok: false, detail: "~/.local/bin is missing (add it in ~/.zprofile)"))
        return checks
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: CheckResult] = [:]

    func set(_ id: String, _ result: CheckResult) { lock.withLock { results[id] = result } }
    func get(_ id: String) -> CheckResult? { lock.withLock { results[id] } }
}
