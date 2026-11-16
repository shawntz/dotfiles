import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

/// The Git identity is asked for, not written into the config. Until the email is answered, the items that need it
/// never reach the Mac with "{{email}}" where an address belongs: not in ~/.gitconfig, not in the key's comment, not
/// in allowed_signers. Real git and /usr/bin/ssh-keygen run against the sandbox home.
final class GitIdentityQuestionTests: XCTestCase {
    static let installer = """
    schema: 1
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

    private let items = """
      - git-config:
          user.name: "{{full_name}}"
          user.email: "{{email}}"
          init.defaultBranch: main
      - ssh-key: ~/.ssh/id_ed25519
      - git-signing: ~/.ssh/id_ed25519.pub
    """

    /// Answers text questions from a script (nil once it runs out).
    final class ScriptedAnswers: UserInteraction, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String?]
        private var asked: [String] = []

        init(_ replies: [String?]) {
            self.replies = replies
        }

        var questions: [String] { lock.withLock { asked } }

        func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? { nil }
        func ask(_ question: Question) async -> String { question.defaultOptionID }

        func askText(_ request: TextRequest) async -> String? {
            lock.withLock {
                asked.append(request.id)
                return replies.isEmpty ? nil : replies.removeFirst()
            }
        }
    }

    private func run(_ plan: InstallPlan, in sandbox: DevSandbox, interaction: any UserInteraction, dryRun: Bool = false) async -> InstallSummary {
        let events = sandbox.events
        return await InstallEngine(plan: plan, environment: sandbox.environment, options: RunOptions(dryRun: dryRun), interaction: interaction)
            .run(selection: .defaults(for: plan)) { events.add($0) }
    }

    func testTheKeyAndSigningNeedTheEmailAlthoughTheirYAMLDoesNotMentionIt() throws {
        let sandbox = DevSandbox()
        let plan = try sandbox.plan(items: items, installer: Self.installer)
        XCTAssertEqual(plan.errors, [])
        XCTAssertEqual(plan.allItems.map { plan.questions(for: $0).map(\.name) }, [["full_name", "email"], ["email"], ["email"]])

        let own = try sandbox.plan(items: "  - ssh-key: ~/.ssh/id_ed25519\n    comment: laptop key\n  - git-signing: ~/.ssh/id_ed25519.pub\n    email: fixed@example.com\n",
                                   installer: Self.installer)
        XCTAssertEqual(own.allItems.map { own.questions(for: $0).map(\.name) }, [[], []], "with their own text they need no answer")
    }

    func testNothingReachesTheMacWhileTheEmailIsUnanswered() async throws {
        let sandbox = DevSandbox()
        let plan = try sandbox.plan(items: items, installer: Self.installer)
        let answers = ScriptedAnswers(["Pat Example", nil])
        let summary = await run(plan, in: sandbox, interaction: answers)

        XCTAssertEqual(answers.questions, ["full_name", "email"])
        XCTAssertEqual(summary.failures.map(\.message), [])
        XCTAssertEqual(summary.needsAttention, 3, "git-config needs the email too, so all three wait")
        XCTAssertEqual(summary.done, 0)
        XCTAssertFalse(sandbox.existsInHome(".gitconfig"), "git config never ran")
        XCTAssertEqual(sandbox.globalGitConfig("user.email"), "")
        XCTAssertFalse(sandbox.existsInHome(".ssh/id_ed25519"), "ssh-keygen never ran")
        XCTAssertFalse(sandbox.existsInHome(".ssh/id_ed25519.pub"))
        XCTAssertFalse(sandbox.existsInHome(".config/git/allowed_signers"))
        XCTAssertFalse(sandbox.logLines.contains { $0.style == .command || $0.text.contains("{{") }, sandbox.logText)
        XCTAssertEqual(summary.followUps.map(\.id), ["answer-email"])
        XCTAssertEqual(AnswerStore(environment: sandbox.environment).saved, ["full_name": "Pat Example"])
    }

    func testTheAnswerIsWhatGitTheKeyAndAllowedSignersGet() async throws {
        let sandbox = DevSandbox()
        let plan = try sandbox.plan(items: items, installer: Self.installer)
        let summary = await run(plan, in: sandbox, interaction: ScriptedAnswers(["Pat Example", "pat@example.com"]))

        XCTAssertEqual(summary.failures.map(\.message), [])
        XCTAssertEqual(summary.done, 3)
        XCTAssertEqual(sandbox.globalGitConfig("user.name"), "Pat Example")
        XCTAssertEqual(sandbox.globalGitConfig("user.email"), "pat@example.com")
        let publicKey = sandbox.readHome(".ssh/id_ed25519.pub")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(publicKey.hasSuffix(" pat@example.com"), "the key's comment is the answer: \(publicKey)")
        XCTAssertTrue(sandbox.readHome(".config/git/allowed_signers")?.hasPrefix("pat@example.com namespaces=\"git\" ") == true)
        for file in [".gitconfig", ".ssh/id_ed25519.pub", ".config/git/allowed_signers"] {
            XCTAssertFalse(sandbox.readHome(file)?.contains("{{") ?? true, file)
        }

        // The answers are kept: the next run asks nothing and finds everything done.
        sandbox.newRun()
        let next = ScriptedAnswers([])
        let again = await run(plan, in: sandbox, interaction: next)
        XCTAssertEqual(next.questions, [])
        XCTAssertEqual(again.alreadyDone, 3)
    }

    /// The Left arrow key at the terminal prompt types ESC [ D into the name. That reply is asked again, so the escape
    /// code never reaches ~/.gitconfig and every commit after it.
    func testAnEscapeCodeInTheNameNeverReachesGit() async throws {
        let sandbox = DevSandbox()
        let plan = try sandbox.plan(items: "  - git-config:\n      user.name: \"{{full_name}}\"\n      user.email: \"{{email}}\"\n",
                                    installer: Self.installer)
        let answers = ScriptedAnswers(["Pat Exampel\u{1B}[D\u{1B}[Dle", "Pat Example", "pat@example.com"])
        let summary = await run(plan, in: sandbox, interaction: answers)

        XCTAssertEqual(answers.questions, ["full_name", "full_name", "email"])
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(sandbox.globalGitConfig("user.name"), "Pat Example")
        XCTAssertFalse(sandbox.readHome(".gitconfig")?.contains("\u{1B}") ?? true)
    }

    /// The key and GitHub items as config/steps/06-git.yaml has them.
    private let keyAndGitHub = """
      - ssh-key: ~/.ssh/id_ed25519
        hosts: [github.com]
      - github: github.com
        protocol: ssh
        key: ~/.ssh/id_ed25519.pub
        upload: [authentication, signing]
    """

    private func finalStatus(_ itemID: String, in sandbox: DevSandbox) -> ItemStatus? {
        sandbox.events.all.compactMap { event -> ItemStatus? in
            if case .itemStatus(itemID, let status) = event { return status }
            return nil
        }.last
    }

    /// On a new Mac, skipping the email holds the key back. The github item would upload that key, so it waits with
    /// it instead of signing in and then failing. The skipped question is the run's only problem, and nothing fails.
    func testOnANewMacTheGitHubItemWaitsForTheKeyThatWaitsForTheEmail() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeGh()
        sandbox.ghSignedIn()
        let plan = try sandbox.plan(items: keyAndGitHub, installer: Self.installer)
        XCTAssertEqual(plan.errors, [])
        let answers = ScriptedAnswers([nil])
        let summary = await run(plan, in: sandbox, interaction: answers)

        XCTAssertEqual(answers.questions, ["email"])
        XCTAssertEqual(summary.failures.map { "\($0.title): \($0.message)" }, [])
        XCTAssertEqual(summary.needsAttention, 2)
        let github = try XCTUnwrap(plan.allItems.last)
        XCTAssertEqual(finalStatus(github.id, in: sandbox), .needsAttention("waiting for an answer: Your email address for Git commits"))
        XCTAssertEqual(sandbox.calls("gh"), [], "gh never ran")
        XCTAssertEqual(summary.followUps.map(\.id), ["answer-email"])
        XCTAssertTrue(summary.followUps.first?.detail?.hasPrefix("2 items wait for it: ~/.ssh/id_ed25519, GitHub (github.com).") == true,
                      summary.followUps.first?.detail ?? "")
    }

    /// With the key already on this Mac, only the key item waits for the email. The github item uploads the key.
    func testTheGitHubItemRunsWhenTheKeyIsAlreadyThere() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeGh()
        sandbox.ghSignedIn()
        sandbox.generateKey()
        let plan = try sandbox.plan(items: keyAndGitHub, installer: Self.installer)
        let summary = await run(plan, in: sandbox, interaction: ScriptedAnswers([nil]))

        XCTAssertEqual(summary.failures.map { "\($0.title): \($0.message)" }, [])
        XCTAssertEqual(summary.needsAttention, 1, "only the key item waits")
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(sandbox.ghRegisteredKeys("authentication").count, 1)
        XCTAssertEqual(sandbox.ghRegisteredKeys("signing").count, 1)
    }

    /// A dry run narrates with a placeholder where the answer will go, and writes nothing, the placeholder included.
    func testADryRunShowsWhereTheAnswerGoesAndWritesNothing() async throws {
        let sandbox = DevSandbox()
        let plan = try sandbox.plan(items: items, installer: Self.installer)
        let answers = ScriptedAnswers(["never asked"])
        let summary = await run(plan, in: sandbox, interaction: answers, dryRun: true)

        XCTAssertEqual(answers.questions, [])
        XCTAssertEqual(summary.failures.map(\.message), [])
        XCTAssertTrue(sandbox.logText.contains("(your email, asked on a real run)"), sandbox.logText)
        XCTAssertFalse(sandbox.existsInHome(".gitconfig"))
        XCTAssertFalse(sandbox.existsInHome(".ssh"))
        XCTAssertFalse(sandbox.existsInHome(".shawn/answers.json"))
    }
}
