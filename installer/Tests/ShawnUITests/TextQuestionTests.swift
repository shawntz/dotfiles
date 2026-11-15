import AppKit
import Foundation
import ShawnCore
import XCTest
@testable import ShawnUI

/// `installer.yaml` with two questions, in the order a run asks them: a name with a default, then an email without one.
private let askMeta = """
name: Test Dotfiles
ask:
  - var: full_name
    prompt: Your name for Git
    default: Test Person
  - var: email
    prompt: Your email address for Git
    format: email
"""

/// One item that needs the email and one that needs nothing (it records when the engine checks or runs it).
private let emailSteps = ["01.yaml": "id: git\ntitle: Git\nitems:\n  - ok: \"commit as {{email}}\"\n  - records: plain\n"]
/// One item that needs both answers.
private let identitySteps = ["01.yaml": "id: git\ntitle: Git\nitems:\n  - ok: \"{{full_name}} <{{email}}>\"\n"]

private let emailPrompt = "Your email address for Git"
private let emailProblem = "That does not look like an email address, such as name@example.com."

/// The text sheet in a real run: the model drives the real engine, and the test answers the sheet the way a person would.
@MainActor
final class TextQuestionTests: XCTestCase {
    /// Waits for the text sheet and returns its request. `attempt` waits for a sheet that asks again.
    private func textSheet(_ model: InstallerModel, attempt: Int = 1, file: StaticString = #filePath,
                           line: UInt = #line) async throws -> TextRequest {
        try await waitUntil(file: file, line: line) { model.activePrompt?.textRequest?.attempt == attempt }
        XCTAssertEqual(model.prompts.count, 1, "one sheet at a time", file: file, line: line)
        return try XCTUnwrap(model.activePrompt?.textRequest, file: file, line: line)
    }

    private func savedAnswers(_ model: InstallerModel) -> AnswerStore.Contents {
        AnswerStore(environment: model.environment).load()
    }

    private func logTexts(_ model: InstallerModel) -> [String] {
        model.log.entries.map(\.text)
    }

    func testAnAnswerReachesTheEngineWhichSavesItAndRunsTheItem() async throws {
        let calls = ItemCalls()
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(calls), meta: askMeta)
        model.start()

        let request = try await textSheet(model)
        XCTAssertEqual(request, TextRequest(id: "email", prompt: emailPrompt, defaultValue: nil, format: .email))
        XCTAssertEqual(model.quipMoment, .question)
        XCTAssertEqual(calls.all, [], "the questions come before any item")
        XCTAssertEqual(model.answersFileDisplayPath, "~/.shawn/answers.json")

        model.submitText("  ann@example.com ")
        XCTAssertNil(model.activePrompt, "the sheet goes away at once")
        try await waitUntil { model.phase == .finished }

        XCTAssertEqual(savedAnswers(model), .answers(["email": "ann@example.com"]), "the engine trims and saves the reply")
        XCTAssertTrue(AnswerStore(environment: model.environment).url.path.hasPrefix(model.environment.home.path),
                      "the answers stay inside the test sandbox")
        XCTAssertTrue(logTexts(model).contains("Saved your email in ~/.shawn/answers.json."), "\(logTexts(model))")
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("git/0"))), .done(nil))
        XCTAssertEqual(model.outcome, .success)
    }

    func testSkipLeavesTheQuestionUnansweredAndItsItemsWait() async throws {
        let calls = ItemCalls()
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(calls), meta: askMeta)
        model.start()
        _ = try await textSheet(model)

        model.skipText()
        try await waitUntil { model.phase == .finished }

        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("git/0"))), .needsAttention("waiting for an answer: \(emailPrompt)"))
        XCTAssertEqual(calls.all, ["check plain", "run plain"], "everything else runs")
        XCTAssertEqual(model.outcome, .success, "a waiting item is not a failure")
        XCTAssertEqual(model.summary?.needsAttention, 1)
        XCTAssertEqual(model.followUps.map(\.id), ["answer-email"])
        XCTAssertEqual(model.followUps.first?.title, "Answer \"\(emailPrompt)\"")
        XCTAssertTrue(logTexts(model).contains("No answer to \"\(emailPrompt)\". The items that need it wait for the next run."))
        XCTAssertEqual(savedAnswers(model), .missing, "nothing is saved")
    }

    func testARejectedReplyComesBackWithTheReasonThenAnAcceptedOneIsSaved() async throws {
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(ItemCalls()), meta: askMeta)
        model.start()
        let first = try await textSheet(model)
        XCTAssertNil(first.lastError)

        model.submitText("ann at example dot com")
        let second = try await textSheet(model, attempt: 2)
        XCTAssertEqual(second, TextRequest(id: "email", prompt: emailPrompt, defaultValue: nil, format: .email,
                                           attempt: 2, lastError: emailProblem))
        XCTAssertEqual(savedAnswers(model), .missing, "a rejected reply is not saved")

        model.submitText("ann@example.com")
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(savedAnswers(model), .answers(["email": "ann@example.com"]))
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("git/0"))), .done(nil))
    }

    func testTwoQuestionsComeOneAfterTheOtherInConfigOrder() async throws {
        let (model, _) = try makeModel(steps: identitySteps, meta: askMeta)
        model.start()

        let name = try await textSheet(model)
        XCTAssertEqual(name, TextRequest(id: "full_name", prompt: "Your name for Git", defaultValue: "Test Person"))
        model.submitText("")

        try await waitUntil { model.activePrompt?.textRequest?.id == "email" }
        let email = try await textSheet(model)
        XCTAssertEqual(email.attempt, 1)
        XCTAssertEqual(savedAnswers(model), .answers(["full_name": "Test Person"]),
                       "an empty reply takes the offered answer, saved before the next question")
        model.submitText("ann@example.com")

        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(savedAnswers(model), .answers(["email": "ann@example.com", "full_name": "Test Person"]))
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("git/0"))), .done(nil))
    }

    /// STOP sits behind the sheet's dimmed window, but ⌘. or a STOP pressed as the sheet appears still lands. The
    /// run must be cancelled before the sheet's "no answer" reaches the engine. Otherwise the engine logs a skipped
    /// question and goes on to check the next item, and the hold below waits for exactly that check.
    func testStopWhileTheSheetIsUpStopsTheRunAndNothingIsSaved() async throws {
        let calls = ItemCalls()
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(calls), meta: askMeta)
        model.start()
        _ = try await textSheet(model)
        holdStop(answering: try XCTUnwrap(model.activePrompt), until: calls.checked)

        model.stop()
        XCTAssertNil(model.activePrompt)
        try await waitUntil(timeout: 5) { model.phase == .finished }

        XCTAssertEqual(calls.all, [], "no item is checked or run after STOP")
        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertEqual(savedAnswers(model), .missing)
        XCTAssertFalse(logTexts(model).contains { $0.hasPrefix("No answer to") }, "a stop is not a skipped question")
        XCTAssertFalse(model.followUps.contains { $0.id == "answer-email" })
    }

    /// ⌘Q, then Stop & Quit, while the sheet is up.
    func testStopAndQuitAtTheSheetStopsTheRunAndQuits() async throws {
        let calls = ItemCalls()
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(calls), meta: askMeta)
        let controller = AppController(options: LaunchOptions(), registry: FakeAction.registry())
        controller.model = model
        var replies: [Bool] = []
        controller.replyToTerminateRequest = { replies.append($0) }
        controller.confirmQuit = { true }
        model.start()
        _ = try await textSheet(model)

        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertNil(model.activePrompt)
        try await waitUntil(timeout: 5) { replies == [true] }
        XCTAssertEqual(calls.all, [])
        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertEqual(savedAnswers(model), .missing)
    }

    func testWithoutAskASavedAnswerIsUsedWithoutTheSheet() async throws {
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(ItemCalls()), meta: askMeta)
        _ = try AnswerStore(environment: model.environment).save("old@example.com", for: "email")
        model.start()
        // A sheet would hold the run open until the wait gives up.
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("git/0"))), .done(nil))
        XCTAssertEqual(savedAnswers(model), .answers(["email": "old@example.com"]))
    }

    /// `--ask` asks again in the first real run, offering the saved answer. A dry run before it only says so, and
    /// a run after it (RETRY FAILED, RESUME) does not ask a third time.
    func testAskAsksAgainInTheFirstRealRunOnly() async throws {
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(ItemCalls()), meta: askMeta,
                                       dryRun: true, askAgain: true)
        _ = try AnswerStore(environment: model.environment).save("old@example.com", for: "email")

        model.start()
        try await waitUntil { model.phase == .finished }
        XCTAssertTrue(logTexts(model).contains("Would ask \"\(emailPrompt)\" again, offering the saved answer."), "\(logTexts(model))")

        model.setUpRealRun()
        model.start()
        let request = try await textSheet(model)
        XCTAssertEqual(request.defaultValue, "old@example.com", "the saved answer is offered")
        model.submitText("new@example.com")
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(savedAnswers(model), .answers(["email": "new@example.com"]))

        model.start()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.runCount, 3)
        XCTAssertEqual(savedAnswers(model), .answers(["email": "new@example.com"]))
    }

    /// Waits until a text sheet is up or the run has finished, and returns the sheet's request, if any.
    private func sheetOrFinish(_ model: InstallerModel) async throws -> TextRequest? {
        try await waitUntil { model.activePrompt?.textRequest != nil || model.phase == .finished }
        return model.activePrompt?.textRequest
    }

    /// STOP at the `--ask` sheet answers nothing, so RESUME asks again instead of keeping the old answer.
    func testAskIsNotUsedUpByARunStoppedAtItsSheet() async throws {
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(ItemCalls()), meta: askMeta, askAgain: true)
        _ = try AnswerStore(environment: model.environment).save("old@example.com", for: "email")

        model.start()
        let first = try await textSheet(model)
        XCTAssertEqual(first.defaultValue, "old@example.com")
        model.stop()
        try await waitUntil(timeout: 5) { model.phase == .finished }
        XCTAssertEqual(model.outcome, .stopped)

        model.start()  // RESUME
        let again = try await sheetOrFinish(model)
        XCTAssertEqual(again?.defaultValue, "old@example.com", "RESUME asks again")
        model.submitText("new@example.com")
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(savedAnswers(model), .answers(["email": "new@example.com"]))
    }

    /// A first real run without the step that needs the answer asks nothing. `--ask` waits for the run that has it.
    func testAskIsNotUsedUpByARunThatAskedNothing() async throws {
        let steps = emailSteps.merging(["02.yaml": "id: other\ntitle: Other\nitems:\n  - ok: plain\n"]) { first, _ in first }
        let (model, _) = try makeModel(steps: steps, registry: promptingRegistry(ItemCalls()), meta: askMeta, askAgain: true)
        _ = try AnswerStore(environment: model.environment).save("old@example.com", for: "email")
        let git = try XCTUnwrap(model.steps.first { $0.id == "git" })

        model.setStep(git, enabled: false)
        model.start()
        let none = try await sheetOrFinish(model)
        XCTAssertNil(none, "nothing in this run needs the answer")
        try await waitUntil { model.phase == .finished }

        model.setStep(git, enabled: true)
        model.start()
        let asked = try await sheetOrFinish(model)
        XCTAssertEqual(asked?.defaultValue, "old@example.com", "the first run that needs the answer asks again")
        model.skipText()
        try await waitUntil { model.phase == .finished }
    }

    func testContinueNeedsTextOrAnOfferedAnswer() {
        let bare = TextRequest(id: "email", prompt: emailPrompt, format: .email)
        let offered = TextRequest(id: "email", prompt: emailPrompt, defaultValue: "ann@example.com", format: .email)
        XCTAssertFalse(TextPanel.canContinue(with: "", request: bare))
        XCTAssertFalse(TextPanel.canContinue(with: "   ", request: bare))
        XCTAssertTrue(TextPanel.canContinue(with: "a", request: bare), "the engine checks the format, not the sheet")
        XCTAssertTrue(TextPanel.canContinue(with: "", request: offered), "an empty reply takes the offered answer")

        XCTAssertEqual(TextPanel.placeholder(for: offered), "ann@example.com")
        XCTAssertEqual(TextPanel.placeholder(for: bare), "name@example.com")
        XCTAssertEqual(TextPanel.placeholder(for: TextRequest(id: "full_name", prompt: "Your name")), "your answer")
        XCTAssertEqual(TextPanel.note(for: bare, answersFile: "~/.shawn/answers.json", isSimulation: false),
                       "The app saves it on this Mac in ~/.shawn/answers.json, so later runs do not ask again. "
                       + "SKIP leaves it unanswered, and the items that need it wait for the next run.")
        XCTAssertTrue(TextPanel.note(for: bare, answersFile: "~/.shawn/answers.json", isSimulation: true).contains("nothing is saved"))
        XCTAssertEqual(TextPanel.skipHelp(for: offered), "Leave it unanswered. The items that need it wait for the next run.",
                       "an offered default is not a saved answer")
    }

    /// Under `--ask`, SKIP keeps the saved answer and the item runs with it. The sheet, its SKIP tooltip and the
    /// run's log say so, instead of saying the items wait.
    func testSkipAfterAskKeepsTheSavedAnswer() async throws {
        let (model, _) = try makeModel(steps: emailSteps, registry: promptingRegistry(ItemCalls()), meta: askMeta, askAgain: true)
        _ = try AnswerStore(environment: model.environment).save("old@example.com", for: "email")
        model.start()
        let request = try await textSheet(model)
        XCTAssertTrue(request.defaultIsSaved)
        XCTAssertEqual(TextPanel.note(for: request, answersFile: model.answersFileDisplayPath, isSimulation: false),
                       "The app saves it on this Mac in ~/.shawn/answers.json, so later runs do not ask again. SKIP keeps the saved answer.")
        XCTAssertEqual(TextPanel.skipHelp(for: request), "Keep the saved answer.")
        model.skipText()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("git/0"))), .done(nil), "the item uses the saved answer")
        XCTAssertEqual(savedAnswers(model), .answers(["email": "old@example.com"]))
        XCTAssertTrue(logTexts(model).contains("Kept the saved answer to \"\(emailPrompt)\"."), "\(logTexts(model))")
        XCTAssertFalse(logTexts(model).contains { $0.contains("wait for the next run") }, "\(logTexts(model))")
    }
}
