import Foundation
import ShawnCore

/// `- script: Claude Code` is the escape hatch: a shell script, made idempotent by `check:` and/or `creates:`.
///
/// When both are given, the item counts as done only when both say so (the path exists AND the check exits 0).
struct ScriptAction: Action {
    enum Shell: String, CaseIterable {
        case bash, zsh, sh
    }

    /// Stops at the first failing command (or failing stage of a pipe) instead of carrying on regardless.
    static let strictPrelude = "set -euo pipefail\n"
    /// Upper bound for a `check:` probe: checks are supposed to be quick.
    static let checkTimeout: TimeInterval = 60

    let name: String
    let script: String
    let checkScript: String?
    let creates: String?
    let shell: Shell
    let asRoot: Bool
    let environment: [(key: String, value: String)]
    let cwd: String?
    let timeout: TimeInterval?
    let system: MacSystem

    var title: String { name }
    var subtitle: String? { Common.firstLine(of: script) }
    var sudo: SudoNeed { asRoot ? .always : .never }
    /// With neither `check:` nor `creates:` it always runs, so a health check has nothing to ask it.
    var isCheckable: Bool { checkScript != nil || creates != nil }

    static func parse(_ parser: ItemParser, system: MacSystem) -> ScriptAction {
        let name = parser.primaryString()
        let options = parser.options
        let script = options.requiredString("run")
        let checkScript = options.string("check")
        let creates = options.string("creates")
        let shell = Shell(rawValue: options.oneOf("shell", Shell.allCases.map(\.rawValue), default: Shell.bash.rawValue)) ?? .bash
        let asRoot = options.bool("sudo", default: false)
        let environment = options.stringPairs("env")
        for pair in environment where pair.key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
            options.error("'env' key '\(pair.key)' is not a valid environment variable name", key: "env")
        }
        let cwd = options.string("cwd")
        let timeout = options.double("timeout")
        if let timeout, timeout <= 0 {
            options.error("'timeout' must be a number of seconds greater than 0", key: "timeout")
        }
        if checkScript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            options.error("'check' must not be empty", key: "check")
        }
        return ScriptAction(name: name, script: script, checkScript: checkScript, creates: creates, shell: shell, asRoot: asRoot,
                            environment: environment, cwd: cwd, timeout: timeout, system: system)
    }

    func validate(_ context: ValidationContext) -> [String] {
        Common.unknownVariables(context, [("run", script), ("check", checkScript), ("creates", creates), ("cwd", cwd)]
            + environment.map { ("env.\($0.key)", $0.value) })
    }

    private var shellPath: String {
        switch shell {
        case .bash: return system.bash
        case .zsh: return system.zsh
        case .sh: return system.sh
        }
    }

    private func command(_ body: String, prelude: String, _ context: ActionContext) -> Command {
        let expanded = context.expand(body)
        var values: [String: String] = [:]
        for pair in environment { values[pair.key] = context.expand(pair.value) }
        return Command(shellPath, ["-c", prelude + expanded])
            .env(values)
            .cwd(cwd.map { context.path($0) })
            .labeled(Common.firstLine(of: expanded))
    }

    // MARK: Check

    func check(_ context: ActionContext) async -> CheckResult {
        if checkScript == nil && creates == nil { return .needed(nil) }
        if let creates {
            let path = context.path(creates)
            guard context.files.exists(path) else { return .needed("\(context.display(path)) does not exist yet") }
        }
        if let checkScript {
            switch await runCheck(checkScript, context) {
            case .success(true): break
            case .success(false): return .needed(nil)
            case .failure(let failure): return .needed(failure.message)
            }
        }
        if let creates { return .satisfied("\(context.display(context.path(creates))) exists") }
        return .satisfied("its check passes")
    }

    /// Runs `check:` as a read-only probe (so also in dry runs), never as root.
    private func runCheck(_ body: String, _ context: ActionContext) async -> Result<Bool, CheckFailure> {
        if let cwd, !context.files.isDirectory(context.path(cwd)) {
            return .failure(CheckFailure("its working directory \(context.display(context.path(cwd))) does not exist"))
        }
        let probe = command(body, prelude: "", context).readOnly().timeout(min(timeout ?? Self.checkTimeout, Self.checkTimeout))
        do {
            return .success(try await context.run(probe).succeeded)
        } catch {
            return .failure(CheckFailure("its check could not run: \(Common.describe(error))"))
        }
    }

    struct CheckFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: Run

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        if let cwd, !context.dryRun, !context.files.isDirectory(context.path(cwd)) {
            throw ActionError("The working directory \(context.display(context.path(cwd))) does not exist",
                              hint: "create it in an earlier item, or fix 'cwd:'")
        }
        let prelude = shell == .sh ? "" : Self.strictPrelude
        var command = command(script, prelude: prelude, context).asRoot(asRoot)
        if let timeout { command = command.timeout(timeout) }
        try await context.runChecked(command)
        guard !context.dryRun else { return .done(nil) }

        if let creates {
            let path = context.path(creates)
            guard context.files.exists(path) else {
                throw ActionError("The script finished but \(context.display(path)) does not exist",
                                  hint: "check the script's output above, or fix 'creates:' to name what it really makes")
            }
        }
        if let checkScript, case .success(false) = await runCheck(checkScript, context) {
            context.warn("The script finished, but its check still fails; it will run again next time.")
        }
        return .done(nil)
    }
}
