import Foundation
import ShawnCore

/// `--simulate`: a self-contained config plus item kinds that pretend to install things, so every screen
/// of the installer can be seen (and tested) without touching the Mac.
///
/// The simulated kinds only ever run `/bin/sh` to print canned output (so the log shows real stdout,
/// stderr and `\r` progress frames through the real `CommandRunner`), and they ask their questions, text and
/// password through `context.interaction` like real actions do. The engine runs them with dry-run on,
/// so `SudoSession` never invokes `sudo`.
enum Simulation {
    /// The simulation's item kinds. `timeScale` shrinks every delay (tests use a tiny value).
    static func makeRegistry(timeScale: Double = 1) -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(descriptor(kind: "sim-install", summary: "pretends to install something, streaming output",
                                     example: "- sim-install: ripgrep\n  progress: true", timeScale: timeScale) { parser in
            .install(output: parser.options.stringList("output"), warnings: parser.options.stringList("warnings"),
                     progress: parser.options.bool("progress", default: false))
        })
        registry.register(descriptor(kind: "sim-present", summary: "is already done", example: "- sim-present: git",
                                     timeScale: timeScale) { parser in
            .present(reason: parser.options.string("reason", default: "already installed"))
        })
        registry.register(descriptor(kind: "sim-skip", summary: "does not apply on this Mac",
                                     example: "- sim-skip: Rosetta\n  reason: not needed here", timeScale: timeScale) { parser in
            .skip(reason: parser.options.requiredString("reason"))
        })
        registry.register(descriptor(kind: "sim-fail", summary: "fails with a realistic error",
                                     example: "- sim-fail: nope\n  error: \"Error: no such cask\"", timeScale: timeScale) { parser in
            .fail(output: parser.options.stringList("output"), error: parser.options.requiredString("error"),
                  hint: parser.options.string("hint"))
        })
        registry.register(descriptor(kind: "sim-manual", summary: "needs a person; adds a follow-up",
                                     example: "- sim-manual: Allow Accessibility\n  url: https://example.com", timeScale: timeScale) { parser in
            .manual(detail: parser.options.string("detail"), url: url(parser, "url"))
        })
        registry.register(descriptor(kind: "sim-sign-in", summary: "shows a device code and waits",
                                     example: "- sim-sign-in: GitHub\n  code: ABCD-1234", timeScale: timeScale) { parser in
            .signIn(code: parser.options.requiredString("code"), url: url(parser, "url"),
                    message: parser.options.string("message", default: "Enter this code in your browser."))
        })
        registry.register(descriptor(kind: "sim-question", summary: "asks a question (first option is the default)",
                                     example: "- sim-question: App Store\n  question: Signed in?\n  options: [Yes, Skip]", timeScale: timeScale) { parser in
            let options = parser.options.stringList("options")
            if options.count < 2 { parser.fail("'options' needs at least two answers") }
            let question = Question(
                title: parser.options.requiredString("question"),
                message: parser.options.string("message", default: ""),
                options: options.enumerated().map { Question.Option(id: "option-\($0.offset)", label: $0.element, isDefault: $0.offset == 0) },
                url: url(parser, "url")
            )
            return .question(question, output: parser.options.stringList("output"))
        })
        registry.register(descriptor(kind: "sim-ask", summary: "asks for one line of text, like a question from ask: (nothing is saved)",
                                     example: "- sim-ask: Git email\n  prompt: Your email address for Git commits\n  format: email",
                                     timeScale: timeScale) { parser in
            let format = AnswerFormat(rawValue: parser.options.oneOf("format", AnswerFormat.allCases.map(\.rawValue), default: "text")) ?? .text
            return .text(prompt: parser.options.requiredString("prompt"), offered: parser.options.string("default"), format: format)
        })
        registry.register(descriptor(kind: "sim-admin", summary: "asks for the administrator password (any non-empty one works)",
                                     example: "- sim-admin: Package manager", timeScale: timeScale) { parser in
            .admin(reason: parser.options.string("reason", default: "This step needs administrator rights."),
                   output: parser.options.stringList("output"))
        })
        return registry
    }

    private static func descriptor(kind: String, summary: String, example: String, timeScale: Double,
                                   behavior: @escaping @Sendable (ItemParser) -> SimulatedAction.Behavior) -> ActionDescriptor {
        ActionDescriptor(kind: kind, summary: summary, example: example) { parser in
            let title = parser.primaryString()
            let seconds = parser.options.double("seconds") ?? 1.5
            let command = parser.options.string("command")
            let subtitle = parser.options.string("subtitle")
            return SimulatedAction(title: title, subtitle: subtitle, command: command, seconds: max(0, seconds),
                                   timeScale: timeScale, behavior: behavior(parser))
        }
    }

    private static func url(_ parser: ItemParser, _ key: String) -> URL? {
        guard let text = parser.options.string(key) else { return nil }
        guard let url = URL(string: text), url.scheme != nil else {
            parser.fail("'\(key)' is not a URL: \(text)")
            return nil
        }
        return url
    }

    /// A sandbox machine for the simulation, rooted at `root` (created if needed).
    static func makeEnvironment(root: URL) throws -> SystemEnvironment {
        var environment = SystemEnvironment.sandbox(root: root)
        for directory in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment.helpersDirectory = nil
        return environment
    }

    /// A fresh scratch directory for one simulation session (removed with `cleanUp`).
    static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShawnsDotfiles-simulation-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanUp(_ scratch: URL) {
        // Best effort: a leftover temp directory is harmless and the OS clears it eventually.
        try? FileManager.default.removeItem(at: scratch)
    }
}

/// One simulated item.
struct SimulatedAction: Action {
    enum Behavior: Sendable {
        case install(output: [String], warnings: [String], progress: Bool)
        case present(reason: String)
        case skip(reason: String)
        case fail(output: [String], error: String, hint: String?)
        case manual(detail: String?, url: URL?)
        case signIn(code: String, url: URL?, message: String)
        case question(Question, output: [String])
        case text(prompt: String, offered: String?, format: AnswerFormat)
        case admin(reason: String, output: [String])
    }

    let title: String
    let subtitle: String?
    let command: String?
    let seconds: Double
    let timeScale: Double
    let behavior: Behavior

    func check(_ context: ActionContext) async -> CheckResult {
        if case .present(let reason) = behavior { return .satisfied(reason) }
        return .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        switch behavior {
        case .present(let reason):
            return .done(reason)

        case .install(let output, let warnings, let progress):
            try await stream(output, warnings: warnings, progress: progress, context: context)
            return .done(nil)

        case .skip(let reason):
            try await pause(seconds / 3)
            return .skipped(reason)

        case .fail(let output, let error, let hint):
            do {
                try await stream(output, warnings: [], progress: false, failure: error, context: context)
            } catch let failure as CommandError {
                throw ActionError(failure.description, hint: hint)
            }
            return .done(nil)

        case .manual(let detail, let url):
            try await pause(seconds / 3)
            context.followUp(title, detail: detail, url: url)
            // As `manual:` ends in the engine: with its own title, which the row shows as "on your checklist".
            return .needsAttention(title)

        case .signIn(let code, let url, let message):
            context.info("Waiting for you to approve the sign-in in your browser…")
            context.attention(Attention(title: title, message: message, code: code, url: url))
            try await pause(max(seconds, 4))
            context.attention(nil)
            context.success("✓ Logged in (simulated)")
            return .done("signed in")

        case .question(let question, let output):
            let answer = await context.interaction.ask(question)
            let label = question.options.first { $0.id == answer }?.label ?? answer
            context.info("Answer: \(label)")
            if answer != question.defaultOptionID { return .skipped("you chose \"\(label)\"") }
            try await stream(output, warnings: [], progress: false, context: context)
            return .done(nil)

        case .text(let prompt, let offered, let format):
            // The engine asks the config's questions only in real runs, and the simulation always runs dry, so this
            // item puts up the same sheet itself. Like the engine, it checks the reply and asks again with the
            // reason. Unlike the engine, it saves nothing.
            var lastError: String?
            for attempt in 1...InstallEngine.maxAnswerAttempts {
                let request = TextRequest(id: "simulated", prompt: prompt, defaultValue: offered, format: format,
                                          attempt: attempt, lastError: lastError)
                let reply = await context.interaction.askText(request)
                try Task.checkCancellation()
                guard let reply else { break }
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                let answer = trimmed.isEmpty ? (offered ?? "") : trimmed
                if let problem = format.problem(with: answer) {
                    lastError = problem
                    continue
                }
                context.info("Answer: \(answer) (simulated: not saved)")
                return .done(nil)
            }
            return .needsAttention("waiting for an answer: \(prompt)")

        case .admin(let reason, let output):
            var lastError: String?
            for attempt in 1...SudoSession.maxAttempts {
                guard let password = await context.interaction.requestAdminPassword(reason: reason, attempt: attempt, lastError: lastError) else {
                    throw ActionError("the administrator password was not provided",
                                      hint: "Run it again and enter the password you use to log in to this Mac.")
                }
                if !password.isEmpty {
                    context.success("Password accepted (simulated: sudo was never called).")
                    try await stream(output, warnings: [], progress: true, context: context)
                    return .done(nil)
                }
                lastError = "That password was not accepted."
            }
            throw ActionError("the administrator password was wrong too many times")
        }
    }

    private func pause(_ duration: Double) async throws {
        let scaled = duration * timeScale
        guard scaled > 0.0005 else { return }
        try await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
    }

    /// Prints canned output through a real (read-only) child process so it flows through the same
    /// pipeline as real tools: stdout, stderr and `\r` progress frames.
    private func stream(_ output: [String], warnings: [String], progress: Bool, failure: String? = nil,
                        context: ActionContext) async throws {
        let frames = progress ? Self.progressFrames : []
        let steps = max(1, output.count + warnings.count + frames.count + (failure == nil ? 0 : 1))
        let interval = seconds * timeScale / Double(steps)
        let sleep = interval > 0.0005 ? String(format: "sleep %.3f\n", interval) : ""

        var script = ""
        for (index, line) in output.enumerated() {
            script += "printf '%s\\n' \(Shell.quote(line))\n" + sleep
            if index == output.count / 2 {
                for warning in warnings { script += "printf '%s\\n' \(Shell.quote(warning)) >&2\n" + sleep }
            }
        }
        if output.isEmpty {
            for warning in warnings { script += "printf '%s\\n' \(Shell.quote(warning)) >&2\n" + sleep }
        }
        for (index, frame) in frames.enumerated() {
            let terminator = index == frames.count - 1 ? "\\n" : "\\r"
            script += "printf '%s\(terminator)' \(Shell.quote(frame))\n" + sleep
        }
        if let failure {
            script += "printf '%s\\n' \(Shell.quote(failure)) >&2\nexit 1\n"
        }
        guard !script.isEmpty else {
            try await pause(seconds)
            return
        }

        var command = Command("/bin/sh", ["-c", script])
        // Prints canned text and nothing else, so it may run even though the engine is in dry-run mode.
        command.mutates = false
        command.label = self.command ?? "simulate \(title)"
        try await context.runChecked(command)
    }

    static let progressFrames: [String] = [3.1, 12.4, 27.9, 41.0, 58.6, 73.2, 88.8, 100.0].map { percent in
        let width = 40
        let filled = Int((percent / 100 * Double(width)).rounded())
        let bar = String(repeating: "#", count: filled) + String(repeating: " ", count: width - filled)
        return bar + String(format: " %5.1f%%", percent)
    }
}
