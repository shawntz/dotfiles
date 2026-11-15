import Foundation
import ShawnCore
import XCTest
@testable import ShawnUI

@MainActor
final class InteractionBridgeTests: XCTestCase {
    private let question = Question(title: "Sign in to the App Store", message: "Then come back.",
                                    options: [Question.Option(id: "yes", label: "I'm signed in", isDefault: true),
                                              Question.Option(id: "skip", label: "Skip")])

    private func runningModel() throws -> (InstallerModel, TempDirectory) {
        let (model, directory) = try makeModel()
        model.apply(.runStarted(totalItems: 5))
        return (model, directory)
    }

    func testPasswordIsHandedBackToTheEngine() async throws {
        let (model, _) = try runningModel()
        let bridge = model.interaction
        let answer = Task.detached { await bridge.requestAdminPassword(reason: "Homebrew", attempt: 2, lastError: "nope") }
        try await waitUntil { model.activePrompt != nil }
        guard case .password(let request, _)? = model.activePrompt?.kind else { return XCTFail("expected a password prompt") }
        XCTAssertEqual(request, PasswordRequest(reason: "Homebrew", attempt: 2, lastError: "nope", maxAttempts: SudoSession.maxAttempts))
        XCTAssertEqual(model.quipMoment, .password)

        model.submitPassword("hunter2")
        let password = await answer.value
        XCTAssertEqual(password, "hunter2")
        XCTAssertNil(model.activePrompt)
    }

    func testCancellingThePasswordSheetDeclines() async throws {
        let (model, _) = try runningModel()
        let bridge = model.interaction
        let answer = Task.detached { await bridge.requestAdminPassword(reason: "r", attempt: 1, lastError: nil) }
        try await waitUntil { model.activePrompt != nil }
        model.cancelPassword()
        let password = await answer.value
        XCTAssertNil(password)
        XCTAssertNil(model.activePrompt)
    }

    func testQuestionReturnsTheChosenOption() async throws {
        let (model, _) = try runningModel()
        let bridge = model.interaction
        let question = self.question
        let answer = Task.detached { await bridge.ask(question) }
        try await waitUntil { model.activePrompt != nil }
        XCTAssertEqual(model.quipMoment, .waiting)
        model.answer(optionID: "skip")
        let chosen = await answer.value
        XCTAssertEqual(chosen, "skip")
    }

    func testStopWhileAPromptIsOpenResumesTheEngineWithNoAnswer() async throws {
        let (model, _) = try runningModel()
        let bridge = model.interaction
        let question = self.question
        let password = Task.detached { await bridge.requestAdminPassword(reason: "r", attempt: 1, lastError: nil) }
        try await waitUntil { model.prompts.count == 1 }
        let answer = Task.detached { await bridge.ask(question) }
        try await waitUntil { model.prompts.count == 2 }
        XCTAssertTrue(model.activePrompt?.isPassword == true, "prompts queue in order; the first is on screen")

        model.stop()
        let declined = await password.value
        let defaulted = await answer.value
        XCTAssertNil(declined)
        XCTAssertEqual(defaulted, "yes", "a question resolves to its default option")
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func testCancellingTheEngineTaskTakesThePromptDown() async throws {
        let (model, _) = try runningModel()
        let bridge = model.interaction
        let waiting = Task.detached { await bridge.requestAdminPassword(reason: "r", attempt: 1, lastError: nil) }
        try await waitUntil { model.activePrompt != nil }
        waiting.cancel()
        let password = await waiting.value
        XCTAssertNil(password)
        try await waitUntil { model.activePrompt == nil }
    }

    func testPromptsOutsideARunAreAnsweredWithTheDefaultImmediately() async throws {
        let (model, _) = try makeModel()
        XCTAssertEqual(model.phase, .welcome)
        let bridge = model.interaction
        let question = self.question
        let password = await Task.detached { await bridge.requestAdminPassword(reason: "r", attempt: 1, lastError: nil) }.value
        let answer = await Task.detached { await bridge.ask(question) }.value
        XCTAssertNil(password)
        XCTAssertEqual(answer, "yes")
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func testPromptGateResolvesExactlyOnce() async {
        let gate = PromptGate<String>()
        let callbacks = Counter()
        gate.whenResolved { callbacks.increment() }
        XCTAssertTrue(gate.resolve("first"))
        XCTAssertFalse(gate.resolve("second"))
        let value = await withCheckedContinuation { gate.install($0) }
        XCTAssertEqual(value, "first", "a continuation installed after the answer gets it immediately")
        XCTAssertEqual(callbacks.value, 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
