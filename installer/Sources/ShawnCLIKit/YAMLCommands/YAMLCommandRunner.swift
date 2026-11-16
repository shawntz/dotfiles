import Darwin
import Foundation
import ShawnCore

/// Runs a command defined in `cli.yaml`.
///
/// `exec` commands become the tool (execve), so it owns the real terminal, signals and exit status.
/// Before that, the command's `update:` runs with its output captured, bounded by a timeout, and is
/// summarized in one line on stderr; a failed or slow update still launches the tool. Ctrl-C during the
/// update stops it (its whole process group) and shawn, and launches nothing.
/// `run` commands replace shawn with `bash -c <script>` for the same reasons.
enum YAMLCommandRunner {
    /// The `--config` directory shawn was started with, for a script that runs shawn again; unset when none was given.
    static let configArgumentVariable = "SHAWN_CONFIG_EXPLICIT"

    static func run(_ command: CLIConfig.Command, arguments: [String], context: CLIContext) async -> Int32 {
        var arguments = arguments
        if case .run = command.action, let first = arguments.first, first == "-h" || first == "--help" {
            HelpCommand.printUsage(of: command, context: context)
            return ExitCode.ok
        }
        var skipUpdate = context.globals.noUpdate
        while arguments.first == "--no-update" {
            arguments.removeFirst()
            skipUpdate = true
        }

        let vars = context.templateVars()
        // A question without an answer would reach the command line as "{{name}}": refuse instead.
        if let pending = pendingVariables(of: command, vars: vars, configVars: context.lightConfig()?.meta.vars ?? [:]).first {
            let name = pending.question
            let prompt = context.lightConfig()?.question(name)?.prompt ?? name
            let uses = pending.written == name ? "{{\(name)}}" : "{{\(pending.written)}}, which uses {{\(name)}}"
            context.fail("shawn \(command.name): this command uses \(uses), and \"\(prompt)\" has no answer on this Mac yet")
            let file = context.display(AnswerStore(environment: context.environment).url)
            if context.questionsInstallAsks()?.contains(name) == true {
                context.err.line("Set \"\(name)\" in \(file), or answer it in 'shawn install --ask'. Then try again.")
            } else {
                context.err.line("'shawn install' does not ask it, because nothing it runs by default uses it. Set \"\(name)\" in \(file). Then try again.")
            }
            return ExitCode.failure
        }
        var overrides = Dictionary(command.environment.map { ($0.name, vars.expand($0.value)) }, uniquingKeysWith: { _, last in last })
        overrides["SHAWN_COMMAND"] = command.name
        // PATH below gets shawn's fallback directories appended; scripts that report on PATH want the original.
        overrides["SHAWN_USER_PATH"] = context.environment.baseEnvironment["PATH"] ?? ""
        if let root = context.configLocation()?.url { overrides["SHAWN_CONFIG"] = root.path }
        var environment = context.childEnvironment(overrides)
        // Only a config somebody named (--config) is handed on as one: a shawn started with --config takes that
        // directory as it is, whereas one left to find its own config skips a snapshot that does not load.
        if let named = context.globals.configPath {
            environment[configArgumentVariable] = named.standardizedFileURL.path
        } else {
            environment.removeValue(forKey: configArgumentVariable)
        }

        let request: ExecRequest
        switch command.action {
        case .exec(let parts):
            let argv = execArguments(parts, userArguments: arguments, vars: vars)
            guard let program = argv.first, let path = ToolLocator.find(program, environment: context.environment, excluding: context.shawnBinary) else {
                let program = argv.first ?? command.name
                context.fail("shawn \(command.name): \(program) is not installed (not found on PATH).")
                context.err.line("It is part of the setup. Run 'shawn install' (or install it by hand), then try again.")
                return ExitCode.notFound
            }
            if let update = command.update, !skipUpdate {
                guard await runUpdate(vars.expand(update), command: command, environment: environment, context: context) else {
                    return ExitCode.interrupted
                }
            }
            request = ExecRequest(path: path, argv: argv, environment: environment)
        case .run(let script):
            if let update = command.update, !skipUpdate {
                guard await runUpdate(vars.expand(update), command: command, environment: environment, context: context) else {
                    return ExitCode.interrupted
                }
            }
            request = ExecRequest(path: "/bin/bash", argv: ["bash", "-c", script, "shawn \(command.name)"] + arguments, environment: environment)
        }

        switch context.services.replacer.replace(request) {
        case .replaced:
            return ExitCode.ok
        case .failed(let code):
            context.fail("shawn \(command.name): could not start \(request.path): \(String(cString: strerror(code)))")
            return ExitCode.cannotExecute
        }
    }

    /// Questions without an answer that the command's expanded text mentions: `env:`, `exec:` and `update:`
    /// (a `run:` script is passed to bash as written). A `vars:` entry the text names counts with the questions its
    /// value uses, as installer.yaml writes it in `configVars`. Each question comes with the name the text wrote.
    static func pendingVariables(of command: CLIConfig.Command, vars: TemplateVars,
                                 configVars: [String: String]) -> [(question: String, written: String)] {
        var texts = command.environment.map(\.value)
        if let update = command.update { texts.append(update) }
        if case .exec(let parts) = command.action {
            for part in parts {
                switch part {
                case .text(let text): texts.append(text)
                case .json(let value): texts.append(JSONText.encode(value))
                }
            }
        }
        var pending: [(question: String, written: String)] = []
        for written in texts.flatMap(TemplateVars.names(in:)) {
            for name in [written] + TemplateVars.names(in: configVars[written] ?? "")
            where vars[name] == nil && vars.pending.contains(name) && !pending.contains(where: { $0.question == name }) {
                pending.append((name, written))
            }
        }
        return pending
    }

    /// The tool's argv: `exec` with `{{variables}}` expanded, `json:` elements as one compact-JSON
    /// argument each, then whatever the user typed.
    static func execArguments(_ parts: [CLIConfig.ExecPart], userArguments: [String], vars: TemplateVars) -> [String] {
        parts.map { part in
            switch part {
            case .text(let text): return vars.expand(text)
            case .json(let value): return JSONText.encode(value, vars: vars)
            }
        } + userArguments
    }

    /// Runs `update:` and prints one tidy line about it. False when Ctrl-C stopped it: the update runs in a
    /// session of its own, so the terminal's Ctrl-C reaches only shawn, which must take the update down with
    /// it rather than leave it running (and holding Homebrew's lock) in the background.
    static func runUpdate(_ script: String, command: CLIConfig.Command, environment: [String: String], context: CLIContext) async -> Bool {
        let style = context.errorStyle
        let animate = context.terminal.stderrIsTTY
        let label = "checking \(command.name) for updates"
        let spinner: Task<Void, Never>? = animate ? Task {
            let frames = ["✦", "✧", "⋆", "✧"]
            var frame = 0
            while !Task.isCancelled {
                context.err.write("\r\u{1B}[2K" + style.accent(frames[frame % frames.count]) + " " + style.muted(label + "…"))
                frame += 1
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        } : nil

        // Catch Ctrl-C before the update starts, so there is no moment in which it would kill shawn alone.
        let stop = UpdateStop()
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        var previous = sigaction()
        sigaction(SIGINT, &ignore, &previous)
        let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        interrupts.setEventHandler { stop.interrupt() }
        interrupts.resume()
        let launcher = context.launcher
        let update = Task {
            await launcher.capture(ProcessRequest("/bin/bash", ["-c", script], environment: environment, timeout: command.updateTimeout))
        }
        stop.watch(update)
        let result = await update.value
        interrupts.cancel()
        sigaction(SIGINT, &previous, nil)
        spinner?.cancel()
        await spinner?.value

        let clear = animate ? "\r\u{1B}[2K" : ""
        if stop.interrupted {
            context.err.write(clear + style.warn("■") + " \(command.name): update stopped, nothing launched"
                              + style.muted(" (shawn \(command.name) --no-update skips the update)") + "\n")
            return false
        }
        context.err.write(clear + summary(of: result, command: command, width: context.terminal.width, style: style) + "\n")
        return true
    }

    static func summary(of result: ProcessResult, command: CLIConfig.Command, width: Int, style: Style) -> String {
        let name = command.name
        let fallback = "; launching the version you have"
        if result.timedOut {
            return style.warn("!") + " \(name): the update took longer than \(Int(command.updateTimeout))s, skipped it" + fallback
        }
        if let launchError = result.launchError {
            return style.warn("!") + " \(name): could not run the update (\(launchError))" + fallback
        }
        if !result.succeeded {
            let tail = result.tail(1)
            return style.warn("!") + " \(name): update failed (exit \(result.exitCode)\(tail.isEmpty ? "" : ": " + TextWidth.truncate(tail, to: 60)))" + fallback
        }
        let said = lastMeaningfulLine(result.stdout) ?? lastMeaningfulLine(result.stderr) ?? "up to date"
        return style.ok("✓") + " \(name): " + TextWidth.truncate(said, to: max(20, width - name.count - 6))
    }

    /// The last line of output that says something (progress noise and blank lines skipped).
    static func lastMeaningfulLine(_ text: String) -> String? {
        let lines = ANSI.strip(text)
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && line.rangeOfCharacter(from: .letters) != nil && !line.hasSuffix("...") && !line.hasSuffix("…")
            }
        return lines.last
    }
}

/// Ctrl-C during an update: canceling the capture terminates the update's process group (SIGTERM, then
/// SIGKILL). A Ctrl-C that comes before the capture task exists cancels it as soon as it does.
private final class UpdateStop: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ProcessResult, Never>?
    private var stopped = false

    func watch(_ task: Task<ProcessResult, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return stopped
        }
        if cancelNow { task.cancel() }
    }

    func interrupt() {
        let task = lock.withLock { () -> Task<ProcessResult, Never>? in
            stopped = true
            return self.task
        }
        task?.cancel()
    }

    var interrupted: Bool { lock.withLock { stopped } }
}
