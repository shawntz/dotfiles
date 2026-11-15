import Darwin
import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

/// Answers text questions from a script (nil once it runs out) and records each request.
final class ScriptedTextInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String?]
    private var recorded: [TextRequest] = []

    init(_ replies: [String?] = []) {
        self.replies = replies
    }

    var requests: [TextRequest] { lock.withLock { recorded } }

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? { nil }
    func ask(_ question: Question) async -> String { question.defaultOptionID }

    func askText(_ request: TextRequest) async -> String? {
        lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
}

private let questionsMeta = """
name: Test Dotfiles
vars:
  github_user: tester
ask:
  - var: full_name
    prompt: Your name, as Git should record it on your commits
  - var: email
    prompt: Your email address for Git commits
    format: email

"""

// MARK: - The terminal prompt

final class TerminalTextQuestionTests: XCTestCase {
    /// Lines to hand back, and the prompts that were shown.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String?]
        private var shown: [String] = []

        init(_ lines: [String?]) {
            self.lines = lines
        }

        var prompts: [String] { lock.withLock { shown } }

        func read(_ prompt: String, _ secret: Bool) -> String? {
            lock.withLock {
                shown.append(prompt + (secret ? " (secret)" : ""))
                return lines.isEmpty ? nil : lines.removeFirst()
            }
        }
    }

    private func interaction(_ script: Script, options: TerminalInteraction.Options = .init()) -> TerminalInteraction {
        TerminalInteraction(options: options, style: .off, textReader: { prompt, secret, _ in script.read(prompt, secret) })
    }

    func testThePromptShowsTheDefaultInBracketsAndReturnTakesIt() async {
        let script = Script(["", "  pat@example.com  ", "", "Pat"])
        let terminal = interaction(script)
        let request = TextRequest(id: "email", prompt: "Your email address for Git commits", defaultValue: "old@example.com", format: .email)
        let empty = await terminal.askText(request)
        let typed = await terminal.askText(request)
        let skipped = await terminal.askText(TextRequest(id: "full_name", prompt: "Your name"))
        let retried = await terminal.askText(TextRequest(id: "full_name", prompt: "Your name", attempt: 2, lastError: "This needs an answer."))

        XCTAssertEqual(empty, "old@example.com", "Return takes the default")
        XCTAssertEqual(typed, "pat@example.com")
        XCTAssertNil(skipped, "Return with no default skips the question")
        XCTAssertEqual(retried, "Pat")
        XCTAssertEqual(script.prompts, [
            "\r\u{1B}[2K? Your email address for Git commits [old@example.com]: ",
            "\r\u{1B}[2K? Your email address for Git commits [old@example.com]: ",
            "\r\u{1B}[2K? Your name (Enter to skip): ",
            "\r\u{1B}[2K✗ This needs an answer.\n? Your name (Enter to skip): ",
        ], "echo stays on: the answer is not a secret")
    }

    func testWithYesOrWithoutATerminalTheDefaultIsTakenWithoutAsking() async {
        let script = Script(["typed"])
        let request = TextRequest(id: "email", prompt: "Email", defaultValue: "pat@example.com")
        let yes = await interaction(script, options: .init(assumeYes: true, allowPrompts: true)).askText(request)
        let headless = await interaction(script, options: .init(assumeYes: false, allowPrompts: false)).askText(request)
        let none = await interaction(script, options: .init(assumeYes: true, allowPrompts: true)).askText(TextRequest(id: "email", prompt: "Email"))
        XCTAssertEqual(yes, "pat@example.com")
        XCTAssertEqual(headless, "pat@example.com")
        XCTAssertNil(none, "no default: no answer")
        XCTAssertEqual(script.prompts, [], "nothing was shown")
    }

    /// The first Ctrl-C withdraws an open text prompt like the other prompts: the read ends, unanswered.
    func testTheFirstCtrlCWithdrawsAnOpenTextPrompt() async throws {
        var pipeEnds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(pipeEnds[0]); close(pipeEnds[1]); close(devNull) }
        let input = pipeEnds[0]
        let terminal = TerminalInteraction(options: .init(), style: .off, textReader: { prompt, secret, cancellation in
            TTY.readLine(prompt: prompt, secret: secret, input: input, output: devNull, cancellation: cancellation)
        })

        let scope = PromptScope()
        let run = Task {
            await PromptScope.$current.withValue(scope) {
                await terminal.askText(TextRequest(id: "email", prompt: "Email", defaultValue: "pat@example.com"))
            }
        }
        for _ in 0..<400 where !TTY.isPrompting { usleep(5_000) }
        XCTAssertTrue(TTY.isPrompting)
        let pressed = Date()
        InterruptHandler(err: BufferOutput(), style: .off, prompts: scope, cancel: { run.cancel() }, quit: { _ in }).handle()
        for _ in 0..<600 where TTY.isPrompting { usleep(5_000) }
        let stillOpen = TTY.isPrompting
        if stillOpen { _ = "\n".withCString { write(pipeEnds[1], $0, 1) } }
        let answer = await run.value
        XCTAssertFalse(stillOpen, "withdrawn without anybody pressing Return")
        XCTAssertNil(answer, "a withdrawn prompt has no answer, not even the default")
        XCTAssertLessThan(Date().timeIntervalSince(pressed), 3)
    }
}

// MARK: - shawn install, doctor, config answers, YAML commands

final class AskCommandTests: XCTestCase {
    private let steps = [
        "01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - ok: identity\n    note: commits as {{full_name}} <{{email}}>\n  - ok: other\n",
        "02-b.yaml": "id: b\ntitle: Beta\nitems:\n  - ok: unrelated\n",
    ]

    private func harness(_ sandbox: Sandbox = Sandbox(), interaction: ScriptedTextInteraction, log: FakeAction.Log = .init()) -> Harness {
        let config = makeConfig(in: sandbox.directory, meta: questionsMeta, steps: steps)
        return Harness(sandbox: sandbox, registry: FakeKinds.registry(log: log), config: config) { $0.interaction = { _ in interaction } }
    }

    private func store(_ sandbox: Sandbox) -> AnswerStore { AnswerStore(environment: sandbox.environment) }

    func testInstallAsksSavesAndThenRunsTheItemsThatNeedTheAnswers() async {
        let sandbox = Sandbox()
        let log = FakeAction.Log()
        let answers = ScriptedTextInteraction(["Pat Example", "pat@example.com"])
        let harness = harness(sandbox, interaction: answers, log: log)
        let code = await harness.run(["--no-update", "install", "--yes"])
        XCTAssertEqual(code, 0, harness.err.plain + harness.out.plain)
        XCTAssertEqual(answers.requests.map(\.id), ["full_name", "email"])
        XCTAssertEqual(store(sandbox).saved, ["email": "pat@example.com", "full_name": "Pat Example"])
        XCTAssertEqual(log.all, ["run:identity:dryRun=false", "run:other:dryRun=false", "run:unrelated:dryRun=false"])
        XCTAssertTrue(harness.out.plain.contains("✦ Saved your email in ~/.shawn/answers.json.\n"), harness.out.plain)

        let next = ScriptedTextInteraction()
        _ = await self.harness(sandbox, interaction: next).run(["--no-update", "install", "--yes"])
        XCTAssertEqual(next.requests, [], "saved answers are not asked again")

        let again = ScriptedTextInteraction(["", "new@example.com"])
        _ = await self.harness(sandbox, interaction: again).run(["--no-update", "install", "--yes", "--ask"])
        XCTAssertEqual(again.requests.map(\.defaultValue), ["Pat Example", "pat@example.com"], "--ask offers the saved answers")
        XCTAssertEqual(store(sandbox).saved, ["email": "new@example.com", "full_name": "Pat Example"])

        let only = ScriptedTextInteraction()
        _ = await self.harness(sandbox, interaction: only).run(["--no-update", "install", "--yes", "--ask", "--only", "b"])
        XCTAssertEqual(only.requests, [], "nothing in step b needs an answer, so nothing is asked")
    }

    func testAnUnansweredQuestionHoldsItsItemBackAndGoesOnTheChecklist() async {
        let sandbox = Sandbox()
        let log = FakeAction.Log()
        let harness = harness(sandbox, interaction: ScriptedTextInteraction(["Pat Example", nil]), log: log)
        let code = await harness.run(["--no-update", "install", "--yes"])
        let text = harness.out.plain
        XCTAssertEqual(code, 0, "an item waiting for an answer is not a failure: \(text)")
        XCTAssertEqual(log.all, ["run:other:dryRun=false", "run:unrelated:dryRun=false"])
        XCTAssertTrue(text.contains("  ! identity: waiting for an answer: Your email address for Git commits\n"), text)
        XCTAssertTrue(text.contains("2 done · 0 already done · 1 needs you · 0 failed"), text)
        XCTAssertTrue(text.contains("  ☐ Answer \"Your email address for Git commits\"\n    1 item waits for it: identity. "
                                    + "Run the installer again and answer it, run 'shawn install --ask', or set \"email\" in ~/.shawn/answers.json.\n"), text)
        XCTAssertEqual(store(sandbox).saved, ["full_name": "Pat Example"])
    }

    func testADryRunAsksNothingAndSavesNothing() async {
        let sandbox = Sandbox()
        let answers = ScriptedTextInteraction(["Pat Example", "pat@example.com"])
        let harness = harness(sandbox, interaction: answers)
        let code = await harness.run(["--no-update", "install", "--dry-run", "--ask"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(answers.requests, [])
        XCTAssertEqual(store(sandbox).load(), .missing)
        XCTAssertTrue(harness.out.plain.contains("✦ Would ask \"Your email address for Git commits\". It has no default, "
                                                 + "so this dry run shows (your email, asked on a real run).\n"), harness.out.plain)
    }

    func testInstallHelpListsAsk() async {
        let harness = harness(interaction: ScriptedTextInteraction())
        _ = await harness.run(["help", "install"])
        XCTAssertTrue(harness.out.plain.contains("--ask"), harness.out.plain)
        XCTAssertTrue(harness.out.plain.contains("Ask the config's questions again, offering the saved answers"), harness.out.plain)
    }

    func testConfigAnswersListsEachQuestionAndChangesNothing() async throws {
        let sandbox = Sandbox()
        try store(sandbox).save("Pat Example", for: "full_name")
        try store(sandbox).save("not-an-address", for: "email")
        let before = try Data(contentsOf: store(sandbox).url)
        let answers = ScriptedTextInteraction(["never asked"])
        let harness = harness(sandbox, interaction: answers)
        let code = await harness.run(["--no-update", "config", "answers"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.out.plain, """
        Answers · ~/.shawn/answers.json
          full_name  Pat Example       Your name, as Git should record it on your commits
          email      not answered yet  Your email address for Git commits
                     The saved answer, "not-an-address", does not count. That does not look like an email address, such as name@example.com.
        Ask again with 'shawn install --ask', or edit the file.

        """)
        XCTAssertEqual(answers.requests, [], "it never asks")
        XCTAssertEqual(try Data(contentsOf: store(sandbox).url), before, "it never writes")

        try Data("not json".utf8).write(to: store(sandbox).url)
        let broken = self.harness(sandbox, interaction: ScriptedTextInteraction())
        _ = await broken.run(["--no-update", "config", "answers"])
        XCTAssertTrue(broken.err.plain.contains("~/.shawn/answers.json is not a JSON object of text values, so it counts as empty."), broken.err.plain)
        XCTAssertTrue(broken.out.plain.contains("  email      not answered yet"), broken.out.plain)

        let plain = Sandbox()
        let none = Harness(sandbox: plain, config: makeConfig(in: plain.directory, steps: steps))
        _ = await none.run(["--no-update", "config", "answers"])
        XCTAssertTrue(none.out.plain.contains("  This config asks no questions.\n"), none.out.plain)
    }

    /// A question whose prompt is only spaces is a config error ('shawn config validate' says so). The CLI's lenient
    /// reading of installer.yaml leaves it out, so it never shows an empty prompt.
    func testAQuestionWithABlankPromptIsLeftOut() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, meta: "name: Test Dotfiles\nask:\n  - var: team\n    prompt: \"   \"\n", steps: steps)
        let harness = Harness(sandbox: sandbox, config: config)
        _ = await harness.run(["--no-update", "config", "answers"])
        XCTAssertTrue(harness.out.plain.contains("  This config asks no questions.\n"), harness.out.plain)
    }

    /// A saved answer with an escape code in it (edited by hand) does not count, and the listing shows the code as
    /// text instead of sending it to the terminal.
    func testConfigAnswersShowsAnEscapeCodeAsText() async throws {
        let sandbox = Sandbox()
        try store(sandbox).save("Pat\u{1B}[2J", for: "full_name")
        let harness = harness(sandbox, interaction: ScriptedTextInteraction())
        _ = await harness.run(["--no-update", "config", "answers"])
        XCTAssertTrue(harness.out.text.contains("  full_name  not answered yet  Your name, as Git should record it on your commits\n"), harness.out.text)
        XCTAssertTrue(harness.out.text.contains(#"The saved answer, "Pat\u{1B}[2J", does not count. Use only printable characters"#), harness.out.text)
        XCTAssertFalse(harness.out.text.contains("\u{1B}"), "no escape code reaches the terminal")
    }

    /// doctor never asks, and never checks an item whose text is not complete yet: it lists it with the reason.
    func testDoctorListsItemsWaitingForAnAnswerAsUncheckable() async throws {
        var sandbox = Sandbox()
        sandbox.environment.baseEnvironment["PATH"] = "\(sandbox.bin.path):$HOME/.local/bin:/usr/bin:/bin"
        let config = makeConfig(in: sandbox.directory, meta: questionsMeta, steps: [
            "01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - present: done-thing\n  - present: identity\n    note: \"{{email}}\"\n",
        ])
        let brew = sandbox.environment.brewPrefix.appendingPathComponent("bin/brew")
        try FileManager.default.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        sandbox.shim("gh", #"[ "$1 $2" = "auth status" ] && exit 0; exit 1"#)
        sandbox.directory.write("home/.gitconfig", "[user]\n  name = Pat Example\n  email = pat@example.com\n")
        sandbox.directory.write("home/.ssh/id_ed25519.pub", "ssh-ed25519 AAAA pat@example.com\n")
        let answers = ScriptedTextInteraction(["pat@example.com"])
        let doctor = { () -> Harness in
            let harness = Harness(sandbox: sandbox, config: config) {
                $0.git = SystemGitClient(launcher: SystemProcessLauncher(), environment: sandbox.environment)
                $0.interaction = { _ in answers }
            }
            harness.context.services.launcher = SystemProcessLauncher()
            return harness
        }

        let waiting = doctor()
        let code = await waiting.run(["--no-update", "doctor"])
        let text = waiting.out.plain
        XCTAssertEqual(code, 0, text)
        XCTAssertTrue(text.contains("  ✓ Alpha                       1/1 · 1 can't be checked\n"), text)
        XCTAssertTrue(text.contains("Can't be checked (1) · nothing can tell whether these are done, so they never count as missing\n"
                                    + "  · identity (present) · Alpha · waiting for an answer: Your email address for Git commits\n"), text)
        XCTAssertEqual(answers.requests, [], "doctor never asks")

        try AnswerStore(environment: sandbox.environment).save("pat@example.com", for: "email")
        let answered = doctor()
        _ = await answered.run(["--no-update", "doctor"])
        XCTAssertTrue(answered.out.plain.contains("  ✓ Alpha                       2/2\n"), answered.out.plain)
        XCTAssertFalse(answered.out.plain.contains("Can't be checked"), answered.out.plain)
    }

    /// A YAML command never runs with "{{email}}" on its command line: it says how to answer instead.
    func testAYAMLCommandThatUsesAnUnansweredQuestionDoesNotRun() async throws {
        let sandbox = Sandbox()
        sandbox.shim("greet", "exit 0")
        let cli = "commands:\n  hello:\n    summary: Says hello\n    env:\n      WHO: \"{{full_name}}\"\n    exec: [greet, \"{{email}}\"]\n"
        // A step that 'shawn install' runs uses both questions, so install would ask them.
        let config = makeConfig(in: sandbox.directory, meta: questionsMeta, steps: steps, cli: cli)

        let refused = Harness(sandbox: sandbox, config: config)
        let code = await refused.run(["--no-update", "hello"])
        XCTAssertEqual(code, 1)
        XCTAssertNil(refused.replacer.last, "nothing was started")
        XCTAssertEqual(refused.err.plain, """
        ✗ shawn hello: this command uses {{full_name}}, and "Your name, as Git should record it on your commits" has no answer on this Mac yet
        Set "full_name" in ~/.shawn/answers.json, or answer it in 'shawn install --ask'. Then try again.

        """)

        try store(sandbox).save("Pat Example", for: "full_name")
        try store(sandbox).save("pat@example.com", for: "email")
        let allowed = Harness(sandbox: sandbox, config: config)
        let allowedCode = await allowed.run(["--no-update", "hello"])
        XCTAssertEqual(allowedCode, 0, allowed.err.plain)
        XCTAssertEqual(allowed.replacer.last?.argv, ["greet", "pat@example.com"])
        XCTAssertEqual(allowed.replacer.last?.environment["WHO"], "Pat Example")
    }

    /// A `vars:` entry may be built from answers. A command that uses it refuses too, instead of running with
    /// "{{full_name}} <{{email}}>" on its command line.
    func testAYAMLCommandThatUsesAVarBuiltFromAnUnansweredQuestionDoesNotRun() async throws {
        let sandbox = Sandbox()
        sandbox.shim("greet", "exit 0")
        let meta = questionsMeta.replacingOccurrences(of: "vars:\n", with: "vars:\n  author: \"{{full_name}} <{{email}}>\"\n")
        let cli = "commands:\n  hello:\n    summary: Says hello\n    exec: [greet, \"{{author}}\"]\n"
        let config = makeConfig(in: sandbox.directory, meta: meta, steps: steps, cli: cli)

        let refused = Harness(sandbox: sandbox, config: config)
        let code = await refused.run(["--no-update", "hello"])
        XCTAssertEqual(code, 1)
        XCTAssertNil(refused.replacer.last, "nothing was started")
        XCTAssertEqual(refused.err.plain, """
        ✗ shawn hello: this command uses {{author}}, which uses {{full_name}}, and "Your name, as Git should record it on your commits" has no answer on this Mac yet
        Set "full_name" in ~/.shawn/answers.json, or answer it in 'shawn install --ask'. Then try again.

        """)

        try store(sandbox).save("Pat Example", for: "full_name")
        let half = Harness(sandbox: sandbox, config: config)
        _ = await half.run(["--no-update", "hello"])
        XCTAssertTrue(half.err.plain.contains("this command uses {{author}}, which uses {{email}}, and \"Your email address for Git commits\""), half.err.plain)

        try store(sandbox).save("pat@example.com", for: "email")
        let allowed = Harness(sandbox: sandbox, config: config)
        let allowedCode = await allowed.run(["--no-update", "hello"])
        XCTAssertEqual(allowedCode, 0, allowed.err.plain)
        XCTAssertEqual(allowed.replacer.last?.argv, ["greet", "Pat Example <pat@example.com>"])
    }

    /// 'shawn install --ask' asks only what an item it runs needs, so it never asks a question only cli.yaml uses.
    /// The refusal and 'shawn config answers' point to the answers file alone for such a question, and that works.
    func testAQuestionOnlyACommandUsesIsSetInTheAnswersFile() async throws {
        let sandbox = Sandbox()
        sandbox.shim("greet", "exit 0")
        let meta = questionsMeta + "  - var: team\n    prompt: Your team name\n"
        let cli = "commands:\n  hello:\n    summary: Says hello\n    exec: [greet, \"{{team}}\"]\n"
        let config = makeConfig(in: sandbox.directory, meta: meta, steps: steps, cli: cli)

        let refused = Harness(sandbox: sandbox, config: config)
        let code = await refused.run(["--no-update", "hello"])
        XCTAssertEqual(code, 1)
        XCTAssertEqual(refused.err.plain, """
        ✗ shawn hello: this command uses {{team}}, and "Your team name" has no answer on this Mac yet
        'shawn install' does not ask it, because nothing it runs by default uses it. Set "team" in ~/.shawn/answers.json. Then try again.

        """)

        let answers = ScriptedTextInteraction(["Pat Example", "pat@example.com", "Platform"])
        let install = Harness(sandbox: sandbox, config: config) { $0.interaction = { _ in answers } }
        _ = await install.run(["--no-update", "install", "--yes", "--ask"])
        XCTAssertEqual(answers.requests.map(\.id), ["full_name", "email"], "install asks only what its items need")

        let listed = Harness(sandbox: sandbox, config: config)
        _ = await listed.run(["--no-update", "config", "answers"])
        XCTAssertTrue(listed.out.plain.contains("""
          team       not answered yet  Your team name
                     'shawn install' does not ask it, because nothing it runs by default uses it.
        Ask again with 'shawn install --ask', or edit the file.

        """), listed.out.plain)

        try store(sandbox).save("Platform", for: "team")
        let allowed = Harness(sandbox: sandbox, config: config)
        let allowedCode = await allowed.run(["--no-update", "hello"])
        XCTAssertEqual(allowedCode, 0, allowed.err.plain)
        XCTAssertEqual(allowed.replacer.last?.argv, ["greet", "Platform"])

        let onlyCommands = Sandbox()
        let commandsOnly = makeConfig(in: onlyCommands.directory, meta: "name: Test Dotfiles\nask:\n  - var: team\n    prompt: Your team name\n",
                                      steps: steps.filter { $0.key == "02-b.yaml" }, cli: cli)
        let none = Harness(sandbox: onlyCommands, config: commandsOnly)
        _ = await none.run(["--no-update", "config", "answers"])
        XCTAssertTrue(none.out.plain.hasSuffix("Edit the file to change an answer.\n"), none.out.plain)
    }

    /// `shawn config validate` knows an asked variable, answered or not, in cli.yaml as in the steps.
    func testValidationKnowsQuestionsInTheStepsAndInCliYAML() async {
        let sandbox = Sandbox()
        let cli = "commands:\n  hello:\n    summary: Says hello\n    exec: [greet, \"{{email}}\", \"{{nobody}}\"]\n"
        let config = makeConfig(in: sandbox.directory, meta: questionsMeta, steps: steps, cli: cli)
        let harness = Harness(sandbox: sandbox, config: config)
        let code = await harness.run(["--no-update", "config", "validate"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(harness.out.plain.contains("command 'hello' uses unknown variable {{nobody}}"), harness.out.plain)
        XCTAssertFalse(harness.out.plain.contains("{{email}}"), harness.out.plain)
        XCTAssertTrue(harness.out.plain.contains("1 problem"), harness.out.plain)
    }
}
