import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

/// A payload file whose `{{variables}}` are filled in on the way needs the questions it mentions, like item text does.
final class TemplateQuestionTests: XCTestCase {
    private let meta = """
    name: Test Dotfiles
    ask:
      - var: email
        prompt: Your email address for Git commits
        format: email

    """

    private func harness() -> Harness {
        let harness = Harness()
        harness.meta = meta
        harness.payload("git/config", "[user]\n  email = {{email}}\n")
        harness.payload("folder/plain.txt", "nothing to fill in\n")
        harness.payload("folder/nested/signed.txt", "signed by {{email}}\n")
        harness.payload("claude/settings.yaml", "owner: \"{{email}}\"\n")
        return harness
    }

    private let items = """
    - copy: git/config
      to: ~/.gitconfig-copy
      template: true
    - copy: git/config
      to: ~/.gitconfig-raw
    - copy: folder
      to: ~/folder
      template: true
    - json-merge: ~/settings.json
      from: claude/settings.yaml
    """

    func testATemplatedPayloadNeedsTheQuestionsItMentions() throws {
        let harness = harness()
        let plan = try harness.plan(items)
        XCTAssertEqual(plan.errors.map(\.description), [])
        XCTAssertEqual(plan.allItems.map { plan.questions(for: $0).map(\.name) }, [["email"], [], ["email"], ["email"]],
                       "a copy without template: true writes the braces as they are, so it needs no answer")
    }

    func testATemplatedFileWaitsForItsAnswer() async throws {
        let harness = harness()
        let plan = try harness.plan(items)
        let first = await InstallEngine(plan: plan, environment: harness.environment).run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(first.failures.map(\.message), [])
        XCTAssertEqual(first.needsAttention, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url("home/.gitconfig-copy").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url("home/folder").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url("home/settings.json").path))
        XCTAssertEqual(harness.directory.read("home/.gitconfig-raw"), "[user]\n  email = {{email}}\n", "the plain copy is written as it is")

        try AnswerStore(environment: harness.environment).save("pat@example.com", for: "email")
        let second = await InstallEngine(plan: plan, environment: harness.environment).run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(second.failures.map(\.message), [])
        XCTAssertEqual(harness.directory.read("home/.gitconfig-copy"), "[user]\n  email = pat@example.com\n")
        XCTAssertEqual(harness.directory.read("home/folder/nested/signed.txt"), "signed by pat@example.com\n")
        XCTAssertTrue(harness.directory.read("home/settings.json")?.contains("\"owner\": \"pat@example.com\"") == true,
                      harness.directory.read("home/settings.json") ?? "")
    }
}
