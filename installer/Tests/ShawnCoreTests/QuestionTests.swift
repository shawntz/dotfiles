import XCTest
@testable import ShawnCore

// MARK: - Test doubles

/// An item that records the text it would write, with every `{{variable}}` it knows filled in: `check:<text>` and
/// `run:<text>`. `implied:` is text it fills in although the item's YAML does not show it (like the ssh-key comment).
/// `makes:` and `uses:` name a file it makes or uses (like the ssh-key and github items).
private struct EchoAction: Action {
    let text: String
    let implied: String?
    var makes: String?
    var uses: String?
    let log: FakeAction.Log

    var title: String { text }

    func impliedText(_ context: ValidationContext) -> [String] { implied.map { [$0] } ?? [] }
    func madeFiles(_ context: ValidationContext) -> [String] { makes.map { [$0] } ?? [] }
    func usedFiles(_ context: ValidationContext) -> [String] { uses.map { [$0] } ?? [] }

    func written(_ context: ActionContext) -> String {
        ([text] + (implied.map { [$0] } ?? [])).map(context.expand).joined(separator: " | ")
    }

    func check(_ context: ActionContext) async -> CheckResult {
        log.add("check:" + written(context))
        return .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        log.add("run:" + written(context))
        return .done(nil)
    }
}

/// `echo` (records its text) and `root` (needs the administrator password), plus the usual fake kinds.
private func questionRegistry(log: FakeAction.Log) -> ActionRegistry {
    var registry = FakeAction.registry(log: log)
    registry.register(ActionDescriptor(kind: "echo", summary: "records its text", example: "- echo: text") { parser in
        EchoAction(text: parser.primaryString(), implied: parser.options.string("implied"), makes: parser.options.string("makes"),
                   uses: parser.options.string("uses"), log: log)
    })
    registry.register(ActionDescriptor(kind: "root", summary: "needs admin rights", example: "- root: thing") { parser in
        FakeAction(title: parser.primaryString(), sudo: .always, log: log)
    })
    return registry
}

/// Answers text questions from a script (nil once the script runs out) and records every call, in order.
private final class ScriptedAnswers: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String?]
    private var recordedRequests: [TextRequest] = []
    private var recordedCalls: [String] = []
    /// Runs as each text question is asked (to look at the answers file at that moment).
    var onAsk: (@Sendable (TextRequest) -> Void)?

    init(_ replies: [String?] = []) {
        self.replies = replies
    }

    var requests: [TextRequest] { lock.withLock { recordedRequests } }
    var calls: [String] { lock.withLock { recordedCalls } }

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
        lock.withLock { recordedCalls.append("password") }
        return nil
    }

    func ask(_ question: Question) async -> String { question.defaultOptionID }

    func askText(_ request: TextRequest) async -> String? {
        onAsk?(request)
        return lock.withLock {
            recordedRequests.append(request)
            recordedCalls.append("text:\(request.id)")
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
}

/// Waits until the run is stopped, then answers nothing, as a prompt withdrawn by STOP does.
private final class WaitingAnswers: UserInteraction, @unchecked Sendable {
    let asked = Recorder<String>()

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? { nil }
    func ask(_ question: Question) async -> String { question.defaultOptionID }

    func askText(_ request: TextRequest) async -> String? {
        asked.add(request.id)
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
        return nil
    }
}

private let identityQuestions = """
name: Test Dotfiles
vars:
  editor: nvim
ask:
  - var: full_name
    prompt: Your name for commits
    default: Pat Example
  - var: email
    prompt: Your email address for Git commits
    format: email

"""

// MARK: - Config

final class QuestionConfigTests: XCTestCase {
    private func load(_ meta: String, steps: [String: String] = ["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: a\n"]) throws -> InstallerConfig {
        let directory = TempDirectory()
        return try ConfigLoader.load(from: makeConfig(in: directory, meta: meta, steps: steps)).config
    }

    private func problems(_ meta: String) -> String {
        do {
            _ = try load(meta)
            return ""
        } catch let error as ConfigError {
            return error.description
        } catch {
            return "\(error)"
        }
    }

    func testQuestionsLoadInTheOrderTheyAreAsked() throws {
        let config = try load("""
        name: Test
        ask:
          - var: full_name
            prompt: Your name
            default_command: git config --global --get user.name || id -F
          - var: email
            prompt: Your email
            default: someone@example.com
            format: email
        """)
        XCTAssertEqual(config.meta.ask.map(\.name), ["full_name", "email"])
        XCTAssertEqual(config.meta.ask[0], VariableQuestion(name: "full_name", prompt: "Your name",
                                                            defaultCommand: "git config --global --get user.name || id -F",
                                                            source: SourceRef(file: "installer.yaml", line: 3)))
        XCTAssertEqual(config.meta.ask[1].defaultValue, "someone@example.com")
        XCTAssertEqual(config.meta.ask[1].format, .email)
        XCTAssertEqual(config.question("email")?.prompt, "Your email")
        XCTAssertTrue(try load("name: Test\n").meta.ask.isEmpty)
    }

    func testEveryMistakeInAQuestionIsReported() {
        let text = problems("""
        name: Test
        vars:
          email: fixed@example.com
        ask:
          - var: email
            prompt: Asked although it is a var
          - var: home
            prompt: A built-in
          - var: "has space"
            prompt: Not a name
          - var: nickname
            promt: typo
          - var: nickname
            prompt: Asked twice
          - var: nickname
            prompt: Asked a third time
          - var: colour
            prompt: Pick one
            format: colour
          - var: motto
            prompt: "two\\nlines"
            default_command: "  "
          - prompt: No var
          - var: blank
            prompt: "   "
        """)
        XCTAssertTrue(text.contains("ask[1]: 'email' is also declared under vars:"), text)
        XCTAssertTrue(text.contains("ask[2]: 'home' is a built-in variable"), text)
        XCTAssertTrue(text.contains("ask[3]: 'var' must be a variable name"), text)
        XCTAssertTrue(text.contains("ask[4]: unknown key 'promt'. Did you mean 'prompt'?"), text)
        XCTAssertTrue(text.contains("ask[4]: missing required key 'prompt'"), text)
        XCTAssertTrue(text.contains("ask[6]: 'nickname' is already asked by ask[4]"), text)
        XCTAssertTrue(text.contains("ask[7]: 'format' must be one of: text, email (got 'colour')"), text)
        XCTAssertTrue(text.contains("ask[8]: 'prompt' must be one line"), text)
        XCTAssertTrue(text.contains("ask[8]: 'default_command' must not be empty"), text)
        XCTAssertTrue(text.contains("ask[9]: missing required key 'var'"), text)
        XCTAssertTrue(text.contains("ask[10]: 'prompt' must not be empty"), "only spaces would show an empty prompt: \(text)")
        XCTAssertTrue(text.contains("installer.yaml:"), "each problem names the file and line: \(text)")
        XCTAssertTrue(problems("name: Test\nask:\n  var: email\n").contains("'ask' must be a list"))
    }

    func testAQuestionWithoutAnAnswerIsAKnownVariable() throws {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, meta: identityQuestions + "  - var: motto\n    prompt: A motto\n    default: \"{{nobody}} says hi\"\n", steps: [
            "01.yaml": "id: one\ntitle: One\nitems:\n  - echo: \"{{email}} and {{full_name}}\"\n  - echo: \"{{nobody}}\"\n",
        ])
        let config = try ConfigLoader.load(from: root).config
        let plan = InstallPlan.build(config: config, registry: questionRegistry(log: .init()), environment: .testSandbox(directory))
        let text = plan.errors.map(\.description).joined(separator: "\n")
        XCTAssertFalse(text.contains("{{email}}") || text.contains("{{full_name}}"), "an unanswered question is not unknown: \(text)")
        XCTAssertTrue(text.contains("ask 'motto': 'default' uses unknown variable {{nobody}}"), text)
        XCTAssertEqual(plan.errors.count, 1, "the item that uses {{nobody}} is checked by its kind, not here: \(text)")
    }

    func testFormats() {
        XCTAssertNil(AnswerFormat.text.problem(with: "  Pat Example "))
        XCTAssertEqual(AnswerFormat.text.problem(with: "   "), "This needs an answer.")
        XCTAssertEqual(AnswerFormat.text.problem(with: "two\nlines"), "Use one line.")
        XCTAssertNil(AnswerFormat.email.problem(with: "pat@example.com"))
        XCTAssertNil(AnswerFormat.email.problem(with: "pat.example+git@mail.example.co.uk"))
        // One address only: a comma would add a second signer to allowed_signers, and "*" would match everyone.
        let lists = ["pat@example.com,*", "pat@example.com,sam@example.com", "*@example.com", "pat@example.com;x@example.com",
                     "Pat <pat@example.com>", "\"pat\"@example.com", "pat@example.com'", "pat@[example.com]", "pat\\@example.com"]
        for bad in ["pat", "pat@example", "@example.com", "pat@.com", "pat example@example.com", "pat@exa@mple.com"] + lists {
            XCTAssertEqual(AnswerFormat.email.problem(with: bad), "That does not look like an email address, such as name@example.com.", bad)
        }
    }

    /// The Left arrow key at the terminal prompt types ESC [ D into the line. No answer may hold a control character.
    func testNoFormatTakesAControlCharacter() {
        let printable = "Use only printable characters, with no tabs or escape codes. At the terminal prompt, fix a typo with Backspace, not the arrow keys."
        XCTAssertEqual(AnswerFormat.text.problem(with: "Pat Exampel\u{1B}[D\u{1B}[Dle"), printable)
        XCTAssertEqual(AnswerFormat.email.problem(with: "pat@exam\u{1B}[Dple.com"), printable)
        XCTAssertEqual(AnswerFormat.text.problem(with: "Pat\u{0}Example"), printable)
        XCTAssertEqual(AnswerFormat.text.problem(with: "Pat\tExample"), printable)
        XCTAssertEqual(AnswerFormat.text.problem(with: "Pat\u{7F}"), printable)
        XCTAssertNil(AnswerFormat.text.problem(with: "Zoë Ångström-Øster"), "letters from any language are fine")
    }

    func testPendingVariablesStayAsWrittenAndAreNotUnknown() {
        var vars = TemplateVars(["home": "/Users/pat"], pending: ["email"])
        XCTAssertEqual(vars.expand("{{email}} at {{home}}"), "{{email}} at /Users/pat")
        XCTAssertEqual(vars.unknownVariables(in: "{{email}} {{nobody}}"), ["nobody"])
        XCTAssertEqual(vars.pendingVariables(in: "{{ email }} {{home}}"), ["email"])
        vars["email"] = "pat@example.com"
        XCTAssertEqual(vars.pending, [])
        XCTAssertEqual(vars.expand("{{email}}"), "pat@example.com")
        XCTAssertEqual(TemplateVars.names(in: "{{a}} {{ b }} {{a}} {{unclosed"), ["a", "b"])
    }

    /// The names a question may not take are the ones the installer fills in itself.
    func testBuiltinNamesCoverEveryMachineVariable() {
        let directory = TempDirectory()
        let machine = Set(SystemEnvironment.testSandbox(directory).templateVariables.keys).union(["config_dir", "shawn_bin"])
        XCTAssertEqual(TemplateVars.builtinNames, machine)
    }

    /// Answers fill in `vars:` that use them, and a question the config does not ask is ignored.
    func testAnswersReachVarsAndOnlyAskedNamesCount() throws {
        let directory = TempDirectory()
        let config = try ConfigLoader.load(from: makeConfig(in: directory, meta: identityQuestions + "  - var: unused\n    prompt: Unused\n",
                                                            steps: ["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: a\n"])).config
        var withSignature = config
        withSignature.meta.vars["signature"] = "{{full_name}} on {{hostname}}"
        let vars = ActionContext.makeVars(config: withSignature, environment: .testSandbox(directory),
                                          answers: ["full_name": "Pat Example", "stranger": "nope"])
        XCTAssertEqual(vars["signature"], "Pat Example on Sandbox Mac")
        XCTAssertNil(vars["stranger"])
        XCTAssertEqual(vars.pending, ["email", "unused"])
    }
}

// MARK: - Answers file

final class AnswerStoreTests: XCTestCase {
    func testAnswersArePrettySortedPrivateAndKeepEveryOtherValue() throws {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let store = AnswerStore(environment: environment)
        XCTAssertEqual(store.url.path, environment.stateDirectory.appendingPathComponent("answers.json").path)
        XCTAssertEqual(store.load(), .missing)
        XCTAssertEqual(store.saved, [:])

        try FileManager.default.createDirectory(at: environment.stateDirectory, withIntermediateDirectories: true)
        try Data(#"{"zebra": "kept/as it is"}"#.utf8).write(to: store.url)
        XCTAssertNil(try store.save("pat@example.com", for: "email"))
        XCTAssertNil(try store.save("Pat Example", for: "full_name"))
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), """
        {
          "email" : "pat@example.com",
          "full_name" : "Pat Example",
          "zebra" : "kept/as it is"
        }

        """)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(store.load(), .answers(["email": "pat@example.com", "full_name": "Pat Example", "zebra": "kept/as it is"]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: environment.stateDirectory.path).filter { $0 != "answers.json" }
        XCTAssertEqual(leftovers, [], "the temporary file is renamed into place")
    }

    func testAFileThatIsNotAnObjectOfTextCountsAsNoAnswersAndIsBackedUpWhenAnAnswerIsSaved() throws {
        for broken in ["not json", #"["pat@example.com"]"#, #"{"email": 42}"#, ""] {
            let directory = TempDirectory()
            var environment = SystemEnvironment.testSandbox(directory)
            environment.runID = "broken-run"
            let store = AnswerStore(environment: environment)
            try FileManager.default.createDirectory(at: environment.stateDirectory, withIntermediateDirectories: true)
            try Data(broken.utf8).write(to: store.url)

            XCTAssertEqual(store.load(), .unreadable, broken)
            XCTAssertEqual(store.answers(for: [VariableQuestion(name: "email", prompt: "Email", format: .email)]), [:])
            XCTAssertEqual(try Data(contentsOf: store.url), Data(broken.utf8), "reading leaves it alone")

            let backup = try XCTUnwrap(store.save("pat@example.com", for: "email"))
            XCTAssertEqual(backup.path, environment.backupDirectory.appendingPathComponent(".shawn/answers.json").path)
            XCTAssertEqual(try Data(contentsOf: backup), Data(broken.utf8), "the old file is kept in the run's backups")
            XCTAssertEqual(store.load(), .answers(["email": "pat@example.com"]))
        }
    }

    func testASavedAnswerThatNoLongerPassesItsFormatIsNotAnAnswer() throws {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let store = AnswerStore(environment: environment)
        try store.save("not an address", for: "email")
        try store.save("  Pat Example  ", for: "full_name")
        let questions = [VariableQuestion(name: "full_name", prompt: "Name"), VariableQuestion(name: "email", prompt: "Email", format: .email)]
        XCTAssertEqual(store.answers(for: questions), ["full_name": "Pat Example"])
    }
}

// MARK: - Plan

final class QuestionPlanTests: XCTestCase {
    func testItemsKnowWhichQuestionsTheirTextNeeds() throws {
        let directory = TempDirectory()
        let meta = identityQuestions + "  - var: city\n    prompt: Your city\n" + "vars:\n  signature: \"{{full_name}} <{{email}}>\"\n"
        let root = makeConfig(in: directory, meta: meta.replacingOccurrences(of: "vars:\n  editor: nvim\n", with: ""), steps: [
            "01.yaml": """
            id: one
            title: One
            items:
              - echo: plain
              - echo: "{{email}}"
              - ok: thing
                flavor: "{{city}}"
              - ok: named
                name: Commit as {{full_name}}
              - ok: noted
                note: for {{city}}
              - echo: no text of its own
                implied: "{{email}}"
              - echo: "{{signature}}"
            """,
        ])
        let config = try ConfigLoader.load(from: root).config
        let plan = InstallPlan.build(config: config, registry: questionRegistry(log: .init()), environment: .testSandbox(directory))
        XCTAssertFalse(plan.hasErrors, "\(plan.issues)")
        let needed = plan.allItems.map { plan.questions(for: $0).map(\.name) }
        XCTAssertEqual(needed, [[], ["email"], ["city"], ["full_name"], ["city"], ["email"], ["full_name", "email"]])
        XCTAssertEqual(plan.questions(for: plan.allItems).map(\.name), ["full_name", "email", "city"], "config order")
        XCTAssertEqual(plan.questions(for: [plan.allItems[2]]).map(\.name), ["city"])
    }

    /// An item that uses a file only a waiting item before it would make waits with it. It does not wait when the
    /// file is already there, or when an earlier item that runs makes it too.
    func testAnItemThatUsesAFileAWaitingItemWouldMakeWaitsWithIt() throws {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let root = makeConfig(in: directory, meta: identityQuestions, steps: [
            "01.yaml": """
            id: one
            title: One
            items:
              - echo: "key for {{email}}"
                makes: ~/key
              - echo: uploads the key
                uses: "{{home}}/key"
              - echo: makes it anyway
                makes: ~/shared
              - echo: "also for {{email}}"
                makes: ~/shared
              - echo: uses the shared one
                uses: ~/shared
            """,
        ])
        let config = try ConfigLoader.load(from: root).config
        let plan = InstallPlan.build(config: config, registry: questionRegistry(log: .init()), environment: environment)
        XCTAssertFalse(plan.hasErrors, "\(plan.issues)")
        let items = plan.allItems
        func waiting(_ items: [PlannedItem], _ unanswered: Set<String>) -> [String: [String]] {
            plan.waitingQuestions(for: items, unanswered: unanswered).mapValues { $0.map(\.name) }
        }
        XCTAssertEqual(waiting(items, ["email"]), ["one/0": ["email"], "one/1": ["email"], "one/3": ["email"]])
        XCTAssertEqual(waiting(items, []), [:])
        XCTAssertEqual(waiting(Array(items.dropFirst()), ["email"]), ["one/3": ["email"]], "nothing in the run makes ~/key")

        try FileManager.default.createDirectory(at: environment.home, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: environment.home.appendingPathComponent("key").path, contents: Data()))
        XCTAssertEqual(waiting(items, ["email"]), ["one/0": ["email"], "one/3": ["email"]], "the key is already there")
    }

    func testTitlesUseTheSavedAnswer() throws {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let root = makeConfig(in: directory, meta: identityQuestions, steps: [
            "01.yaml": "id: one\ntitle: One\nitems:\n  - ok: thing\n    name: Commit as {{full_name}}\n",
        ])
        let config = try ConfigLoader.load(from: root).config
        XCTAssertEqual(InstallPlan.build(config: config, registry: questionRegistry(log: .init()), environment: environment).allItems[0].title,
                       "Commit as {{full_name}}", "without an answer the title shows the variable")
        try AnswerStore(environment: environment).save("Pat Example", for: "full_name")
        XCTAssertEqual(InstallPlan.build(config: config, registry: questionRegistry(log: .init()), environment: environment).allItems[0].title,
                       "Commit as Pat Example")
    }
}

// MARK: - Engine

final class QuestionEngineTests: XCTestCase {
    private struct Harness {
        let plan: InstallPlan
        let log: FakeAction.Log
        let directory: TempDirectory
        let environment: SystemEnvironment

        var store: AnswerStore { AnswerStore(environment: environment) }

        func engine(_ interaction: any UserInteraction = NonInteractive(), options: RunOptions = RunOptions()) -> InstallEngine {
            InstallEngine(plan: plan, environment: environment, options: options, interaction: interaction)
        }

        func run(_ interaction: any UserInteraction = NonInteractive(), options: RunOptions = RunOptions(),
                 selection: Selection? = nil) async -> (InstallSummary, [InstallEvent]) {
            let events = Recorder<InstallEvent>()
            let summary = await engine(interaction, options: options).run(selection: selection ?? .defaults(for: plan)) { events.add($0) }
            return (summary, events.all)
        }
    }

    private func harness(meta: String = identityQuestions, _ items: String) throws -> Harness {
        let directory = TempDirectory()
        let log = FakeAction.Log()
        let root = makeConfig(in: directory, meta: meta, steps: ["01.yaml": "id: one\ntitle: One\nitems:\n\(items)\n"])
        let config = try ConfigLoader.load(from: root).config
        let environment = SystemEnvironment.testSandbox(directory)
        let plan = InstallPlan.build(config: config, registry: questionRegistry(log: log), environment: environment)
        XCTAssertFalse(plan.hasErrors, "\(plan.issues)")
        return Harness(plan: plan, log: log, directory: directory, environment: environment)
    }

    private func statuses(_ events: [InstallEvent], _ itemID: String) -> [ItemStatus] {
        events.compactMap { if case .itemStatus(itemID, let status) = $0 { return status } else { return nil } }
    }

    private func logText(_ events: [InstallEvent]) -> String {
        events.compactMap { if case .log(let line) = $0 { return line.text } else { return nil } }.joined(separator: "\n")
    }

    func testQuestionsComeBeforeThePasswordInConfigOrderAndEachAnswerIsSavedAtOnce() async throws {
        let harness = try harness("""
          - root: needs the password
          - echo: "{{email}}"
          - echo: "{{full_name}}"
        """)
        let answers = ScriptedAnswers(["", "pat@example.com"])
        let store = harness.store
        let savedWhenAsked = Recorder<[String: String]>()
        answers.onAsk = { _ in savedWhenAsked.add(store.saved) }
        let (summary, events) = await harness.run(answers)

        XCTAssertEqual(answers.calls, ["text:full_name", "text:email", "password"], "a declined password is not asked again")
        XCTAssertEqual(answers.requests.map(\.defaultValue), ["Pat Example", nil])
        XCTAssertEqual(answers.requests.map(\.prompt), ["Your name for commits", "Your email address for Git commits"])
        XCTAssertEqual(answers.requests.map(\.format), [.text, .email])
        XCTAssertEqual(answers.requests.map(\.attempt), [1, 1])
        XCTAssertEqual(savedWhenAsked.all, [[:], ["full_name": "Pat Example"]], "the name was saved before the email was asked")
        XCTAssertEqual(harness.store.saved, ["email": "pat@example.com", "full_name": "Pat Example"])
        XCTAssertTrue(harness.log.all.contains("run:pat@example.com"), "\(harness.log.all)")
        XCTAssertTrue(harness.log.all.contains("run:Pat Example"), "an empty reply takes the default: \(harness.log.all)")
        XCTAssertTrue(logText(events).contains("Saved your email in ~/.shawn/answers.json."), logText(events))
        XCTAssertEqual(summary.followUps, [])

        // The next run uses what was saved and asks nothing.
        let again = ScriptedAnswers()
        _ = await harness.run(again)
        XCTAssertEqual(again.calls.filter { $0.hasPrefix("text:") }, [])
    }

    func testAReplyThatFailsItsFormatIsAskedAgainWithTheReasonUpToThreeTimes() async throws {
        let harness = try harness("  - echo: \"{{email}}\"")
        let corrected = ScriptedAnswers(["pat at example", "  pat@example.com  "])
        _ = await harness.run(corrected)
        XCTAssertEqual(corrected.requests.map(\.attempt), [1, 2])
        XCTAssertEqual(corrected.requests.map(\.lastError), [nil, "That does not look like an email address, such as name@example.com."])
        XCTAssertEqual(harness.store.saved, ["email": "pat@example.com"], "the answer is trimmed")

        let stubborn = try self.harness("  - echo: \"{{email}}\"")
        let answers = ScriptedAnswers(["nope", "", "still nope", "never asked"])
        let (summary, events) = await stubborn.run(answers)
        XCTAssertEqual(answers.requests.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(answers.requests.map(\.lastError), [nil, "That does not look like an email address, such as name@example.com.", "This needs an answer."])
        XCTAssertEqual(stubborn.store.load(), .missing, "nothing is saved")
        XCTAssertEqual(stubborn.log.all, [], "the item that needs it neither checks nor runs")
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertTrue(logText(events).contains("No answer to \"Your email address for Git commits\" after 3 tries."), logText(events))
    }

    /// A reply with an escape code in it is asked again with the reason, and only the clean reply is saved and used.
    func testAReplyWithAnEscapeCodeIsAskedAgainAndNeverSaved() async throws {
        let harness = try harness("  - echo: \"{{email}}\"")
        let answers = ScriptedAnswers(["pat@exam\u{1B}[Dple.com", "pat@example.com"])
        _ = await harness.run(answers)
        XCTAssertEqual(answers.requests.map(\.attempt), [1, 2])
        XCTAssertEqual(answers.requests.last?.lastError?.hasPrefix("Use only printable characters"), true)
        XCTAssertEqual(harness.store.saved, ["email": "pat@example.com"])
        XCTAssertEqual(harness.log.all, ["check:pat@example.com", "run:pat@example.com"])
    }

    /// The safety promise: in a real run, an item whose text needs an unanswered question is neither checked nor run,
    /// so "{{email}}" (or a dry-run placeholder) never reaches the Mac. Everything else runs, and nothing fails.
    func testAnItemWaitingForAnAnswerIsHeldBackAndNothingElseIs() async throws {
        let harness = try harness("""
          - echo: "user.email={{email}}"
          - echo: no text of its own
            implied: "comment={{email}}"
          - echo: "user.name={{full_name}}"
          - ok: unrelated
        """)
        let answers = ScriptedAnswers(["", nil])
        let (summary, events) = await harness.run(answers)

        XCTAssertEqual(harness.log.all, ["check:user.name=Pat Example", "run:user.name=Pat Example", "check:unrelated", "run:unrelated:dryRun=false"])
        for entry in harness.log.all {
            XCTAssertFalse(entry.contains("{{") || entry.contains("asked on a real run"), entry)
        }
        let waiting = ItemStatus.needsAttention("waiting for an answer: Your email address for Git commits")
        XCTAssertEqual(statuses(events, "one/0"), [waiting])
        XCTAssertEqual(statuses(events, "one/1"), [waiting])
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertTrue(summary.succeeded, "items held back are not failures")
        XCTAssertEqual(summary.needsAttention, 2)
        XCTAssertEqual(summary.done, 2)
        XCTAssertTrue(logText(events).contains("No answer to \"Your email address for Git commits\". The items that need it wait for the next run."))

        XCTAssertEqual(summary.followUps.count, 1, "one checklist entry per unanswered question")
        let followUp = try XCTUnwrap(summary.followUps.first)
        XCTAssertEqual(followUp.id, "answer-email")
        XCTAssertEqual(followUp.title, "Answer \"Your email address for Git commits\"")
        XCTAssertEqual(followUp.detail, "2 items wait for it: user.email={{email}}, no text of its own. Run the installer again and answer it, "
                       + "run 'shawn install --ask', or set \"email\" in ~/.shawn/answers.json.")
        XCTAssertEqual(followUp.stepID, "one")
        XCTAssertEqual(harness.store.saved, ["full_name": "Pat Example"])
    }

    /// Headless runs (and the app until it can ask) answer with the default; with no default there is no answer.
    func testWithNobodyToAskTheDefaultIsTakenAndTheRestWaits() async throws {
        let harness = try harness("""
          - echo: "{{full_name}}"
          - echo: "{{email}}"
          - root: needs the password
        """)
        let (summary, events) = await harness.run(NonInteractive())
        XCTAssertEqual(harness.store.saved, ["full_name": "Pat Example"])
        XCTAssertEqual(harness.log.all.filter { $0.hasPrefix("run:") }.first, "run:Pat Example")
        XCTAssertFalse(harness.log.all.contains { $0.contains("{{") }, "\(harness.log.all)")
        XCTAssertEqual(statuses(events, "one/1"), [.needsAttention("waiting for an answer: Your email address for Git commits")])
        XCTAssertEqual(summary.followUps.map(\.id), ["answer-email"])
    }

    func testTheItemsThatWaitDoNotAskForThePassword() async throws {
        let harness = try harness("  - root: \"needs the password and {{email}}\"\n  - ok: plain")
        let answers = ScriptedAnswers([nil])
        _ = await harness.run(answers)
        XCTAssertEqual(answers.calls, ["text:email"], "the only item that needs the password is waiting, so the password is not asked")
    }

    func testADryRunNeverAsksOrSavesAndShowsTheSavedAnswerTheDefaultOrAPlaceholder() async throws {
        let meta = identityQuestions + "  - var: city\n    prompt: Your city\n"
        let harness = try harness(meta: meta, """
          - echo: "{{full_name}}"
          - echo: "{{email}}"
          - echo: "{{city}}"
        """)
        try harness.store.save("Lumpy Town", for: "city")
        let before = try Data(contentsOf: harness.store.url)
        let answers = ScriptedAnswers(["never used"])
        let (summary, events) = await harness.run(answers, options: RunOptions(dryRun: true))

        XCTAssertEqual(answers.calls, [], "a dry run asks nothing, the password included")
        XCTAssertEqual(try Data(contentsOf: harness.store.url), before, "a dry run saves nothing")
        XCTAssertEqual(harness.log.all.filter { $0.hasPrefix("run:") },
                       ["run:Pat Example", "run:(your email, asked on a real run)", "run:Lumpy Town"])
        XCTAssertEqual(summary.followUps, [], "nothing is held back in a dry run")
        let text = logText(events)
        XCTAssertTrue(text.contains("Would ask \"Your name for commits\". This dry run uses the default, Pat Example."), text)
        XCTAssertTrue(text.contains("Would ask \"Your email address for Git commits\". It has no default, so this dry run shows (your email, asked on a real run)."), text)
        XCTAssertFalse(text.contains("Your city"), "a saved answer needs no note: \(text)")

        let again = ScriptedAnswers()
        let (_, askAgainEvents) = await harness.run(again, options: RunOptions(dryRun: true, askAgain: true))
        XCTAssertEqual(again.calls, [])
        XCTAssertTrue(logText(askAgainEvents).contains("Would ask \"Your city\" again, offering the saved answer."))
    }

    func testAskAgainOffersTheSavedAnswerAsTheDefault() async throws {
        let harness = try harness("  - echo: \"{{email}}\"\n  - echo: \"{{full_name}}\"")
        try harness.store.save("old@example.com", for: "email")
        try harness.store.save("Pat Example", for: "full_name")

        let plain = ScriptedAnswers()
        _ = await harness.run(plain)
        XCTAssertEqual(plain.requests, [], "saved answers are not asked again by default")

        let again = ScriptedAnswers(["", "new@example.com"])
        _ = await harness.run(again, options: RunOptions(askAgain: true))
        XCTAssertEqual(again.requests.map(\.id), ["full_name", "email"])
        XCTAssertEqual(again.requests.map(\.defaultValue), ["Pat Example", "old@example.com"])
        XCTAssertEqual(harness.store.saved, ["email": "new@example.com", "full_name": "Pat Example"], "an empty reply keeps the saved answer")

        let declined = ScriptedAnswers([nil, nil])
        let before = harness.log.all.count
        let (summary, events) = await harness.run(declined, options: RunOptions(askAgain: true))
        XCTAssertEqual(declined.requests.map(\.defaultIsSaved), [true, true], "the front end can say SKIP keeps the saved answer")
        XCTAssertEqual(summary.followUps, [], "declining to change a saved answer keeps it")
        XCTAssertEqual(summary.needsAttention, 0)
        XCTAssertEqual(Array(harness.log.all.dropFirst(before)), ["check:new@example.com", "run:new@example.com", "check:Pat Example", "run:Pat Example"],
                       "the items run with the saved answers")
        XCTAssertTrue(logText(events).contains("Kept the saved answer to \"Your email address for Git commits\"."), logText(events))
        XCTAssertFalse(logText(events).contains("wait for the next run"), "nothing waits: \(logText(events))")

        let rejected = ScriptedAnswers(["", "nope", "nope", "nope"])
        let (_, rejectedEvents) = await harness.run(rejected, options: RunOptions(askAgain: true))
        XCTAssertEqual(harness.store.saved, ["email": "new@example.com", "full_name": "Pat Example"])
        XCTAssertTrue(logText(rejectedEvents).contains("No new answer to \"Your email address for Git commits\" after 3 tries. "
                                                       + "That does not look like an email address, such as name@example.com. Kept the saved answer."),
                      logText(rejectedEvents))
        XCTAssertFalse(logText(rejectedEvents).contains("wait for the next run"), logText(rejectedEvents))

        let unsaved = try self.harness("  - echo: \"{{email}}\"")
        let fresh = ScriptedAnswers([nil])
        _ = await unsaved.run(fresh, options: RunOptions(askAgain: true))
        XCTAssertEqual(fresh.requests.map(\.defaultIsSaved), [false], "with nothing saved, declining leaves it unanswered")
    }

    func testNothingIsAskedWhenNoEnabledItemNeedsTheAnswer() async throws {
        let harness = try harness("""
          - echo: "{{email}}"
            optional: true
          - ok: plain
        """)
        let answers = ScriptedAnswers(["pat@example.com"])
        _ = await harness.run(answers)
        XCTAssertEqual(answers.calls, [])

        var selection = Selection.defaults(for: harness.plan)
        selection.setStep("one", enabled: false)
        let off = ScriptedAnswers(["pat@example.com"])
        _ = await harness.run(off, selection: selection)
        XCTAssertEqual(off.calls, [])
    }

    func testDefaultCommandWinsAndAnyFailureMeansNoDefault() async throws {
        let markerDirectory = TempDirectory()
        let marker = markerDirectory.url.appendingPathComponent("ran")
        func offered(_ ask: String) async throws -> String? {
            let meta = "name: Test\nask:\n  - var: answer\n    prompt: Answer\n\(ask)  - var: other\n    prompt: Other\n"
            let harness = try harness(meta: meta, "  - echo: \"{{answer}}\"")
            let answers = ScriptedAnswers([nil])
            _ = await harness.run(answers)
            return answers.requests.first?.defaultValue
        }
        let first = try await offered("    default_command: printf '  first line  \\nsecond\\n'\n    default: literal\n")
        XCTAssertEqual(first, "first line", "trimmed, first line only, and it wins over default:")
        let failed = try await offered("    default_command: echo printed; exit 3\n    default: literal\n")
        XCTAssertEqual(failed, "literal", "a failed command gives no default")
        let silent = try await offered("    default_command: \"true\"\n    default: \"{{user}} at home\"\n")
        XCTAssertEqual(silent, "\(NSUserName()) at home", "empty output gives no default; default: may use variables")
        let none = try await offered("    default_command: exit 1\n")
        XCTAssertNil(none)
        let unfinished = try await offered("    default: \"{{other}}\"\n")
        XCTAssertNil(unfinished, "a default that needs an unanswered question is not offered")

        let started = Date()
        let slow = try await offered("    default_command: sleep 30\n")
        XCTAssertNil(slow, "a command that runs out of time gives no default")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)

        // It runs in dry runs too (it must only read), as the user, with the installer's environment.
        let meta = "name: Test\nask:\n  - var: answer\n    prompt: Answer\n    default_command: echo \"$HOME\" > '\(marker.path)'; id -u\n"
        let dryRun = try self.harness(meta: meta, "  - echo: \"{{answer}}\"")
        let (_, events) = await dryRun.run(ScriptedAnswers(), options: RunOptions(dryRun: true))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), dryRun.environment.home.path + "\n")
        XCTAssertTrue(logText(events).contains("This dry run uses the default, \(getuid())."), logText(events))
    }

    func testADefaultThatFailsItsFormatIsNotOffered() async throws {
        let meta = "name: Test\nask:\n  - var: email\n    prompt: Email\n    format: email\n    default_command: echo not-an-address\n"
        let harness = try harness(meta: meta, "  - echo: \"{{email}}\"")
        let answers = ScriptedAnswers([nil])
        _ = await harness.run(answers)
        XCTAssertEqual(answers.requests.map(\.defaultValue), [nil])

        // The command's line does not pass the format, so the default: that does is offered instead.
        let fallback = try self.harness(meta: meta + "    default: pat@example.com\n", "  - echo: \"{{email}}\"")
        let offered = ScriptedAnswers([nil])
        _ = await fallback.run(offered)
        XCTAssertEqual(offered.requests.map(\.defaultValue), ["pat@example.com"])
    }

    func testStoppingWhileAQuestionIsOpenRunsAndSavesNothing() async throws {
        let harness = try harness("  - echo: \"{{email}}\"\n  - ok: plain")
        let waiting = WaitingAnswers()
        let engine = harness.engine(waiting)
        let task = Task { await engine.run(selection: .defaults(for: harness.plan)) { _ in } }
        for _ in 0..<200 where waiting.asked.all.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(waiting.asked.all, ["email"])
        task.cancel()
        let summary = await task.value
        XCTAssertTrue(summary.wasCancelled)
        XCTAssertEqual(harness.log.all, [], "nothing runs after a stop")
        XCTAssertEqual(harness.store.load(), .missing)
        XCTAssertEqual(summary.followUps, [])
    }

    func testScanDoesNotCheckAnItemWaitingForAnAnswer() async throws {
        let harness = try harness("  - echo: \"{{email}}\"\n  - echo: \"{{full_name}}\"")
        try harness.store.save("Pat Example", for: "full_name")
        let results = Recorder<(String, CheckResult)>()
        let answers = ScriptedAnswers(["pat@example.com"])
        await harness.engine(answers).scan(selection: .defaults(for: harness.plan)) { results.add(($0, $1)) }
        XCTAssertEqual(results.all.map(\.0), ["one/0", "one/1"])
        XCTAssertEqual(results.all.first?.1, .needed("waiting for an answer: Your email address for Git commits"))
        XCTAssertEqual(harness.log.all, ["check:Pat Example"], "the waiting item is not checked")
        XCTAssertEqual(answers.calls, [], "a scan never asks")
    }

    func testTheWaitingMessageNamesEveryQuestion() {
        let questions = [VariableQuestion(name: "a", prompt: "First"), VariableQuestion(name: "b", prompt: "Second")]
        XCTAssertEqual(InstallEngine.waitingMessage([questions[0]]), "waiting for an answer: First")
        XCTAssertEqual(InstallEngine.waitingMessage(questions), "waiting for 2 answers: First; Second")
    }

    /// The default implementation answers with the default, so every front end that cannot ask yet still works.
    func testTheDefaultImplementationAnswersWithTheDefault() async {
        let interaction: any UserInteraction = NonInteractive()
        let withDefault = await interaction.askText(TextRequest(id: "email", prompt: "Email", defaultValue: "pat@example.com", format: .email))
        let without = await interaction.askText(TextRequest(id: "email", prompt: "Email"))
        XCTAssertEqual(withDefault, "pat@example.com")
        XCTAssertNil(without)
    }
}
