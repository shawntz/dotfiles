import AppKit
import Foundation
import ShawnCore
import XCTest
@testable import ShawnUI

/// Counts keep-awake begin/end calls instead of touching the Mac's power state.
@MainActor
private final class KeepAwakeRecorder {
    var reasons: [String] = []
    var ended = 0
    var held: Int { reasons.count - ended }

    var keepAwake: KeepAwake {
        KeepAwake(begin: { [unowned self] reason in
            reasons.append(reason)
            return NSObject()
        }, end: { [unowned self] _ in
            ended += 1
        })
    }
}

private let slowStep = ["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: quick\n  - slow: forever\n  - ok: never\n"]
private let cleanSteps = ["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: alpha\n  - present: beta\n  - manual: zeta\n"]
private let sixItems = ["01.yaml": "id: one\ntitle: One\nitems:\n" + ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"].map { "  - ok: \($0)\n" }.joined()]

/// What the engine did with the prompting test items, in order, with a signal for each kind of call.
final class ItemCalls: @unchecked Sendable {
    let checked = DispatchSemaphore(value: 0)
    let ran = DispatchSemaphore(value: 0)
    let answered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls: [String] = []

    func record(_ call: String, _ signal: DispatchSemaphore) {
        lock.withLock { calls.append(call) }
        signal.signal()
    }

    var all: [String] { lock.withLock { calls } }
}

/// Needs administrator rights (`sudo: always`, like Homebrew), might (`.maybe`, like a cask) or does not (`.never`).
/// Never runs sudo.
private struct AdminAction: Action {
    let title: String
    let sudo: SudoNeed
    let calls: ItemCalls

    func check(_ context: ActionContext) async -> CheckResult {
        calls.record("check \(title)", calls.checked)
        return .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        calls.record("run \(title)", calls.ran)
        return .done(nil)
    }
}

/// Asks a question (default "I'm signed in", like the App Store one) and records whether the run had already
/// been stopped when the answer came back.
private struct AskingAction: Action {
    static let question = Question(title: "Sign in to the App Store", message: "Then come back.",
                                   options: [Question.Option(id: "yes", label: "I'm signed in", isDefault: true),
                                             Question.Option(id: "skip", label: "Skip")])
    let title: String
    let calls: ItemCalls

    func check(_ context: ActionContext) async -> CheckResult {
        calls.record("check \(title)", calls.checked)
        return .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let answer = await context.interaction.ask(Self.question)
        calls.record("answer \(answer), stopped: \(Task.isCancelled)", calls.answered)
        try Task.checkCancellation()
        calls.record("install \(title)", calls.ran)
        return .done(nil)
    }
}

/// The fake kinds plus `admin-always`, `admin-maybe`, `asks` and `records` (needs nothing), all recording into `calls`.
func promptingRegistry(_ calls: ItemCalls) -> ActionRegistry {
    var registry = FakeAction.registry()
    registry.register(ActionDescriptor(kind: "records", summary: "records its calls", example: "- records: x") { parser in
        AdminAction(title: parser.primaryString(), sudo: .never, calls: calls)
    })
    registry.register(ActionDescriptor(kind: "admin-always", summary: "needs sudo", example: "- admin-always: x") { parser in
        AdminAction(title: parser.primaryString(), sudo: .always, calls: calls)
    })
    registry.register(ActionDescriptor(kind: "admin-maybe", summary: "might need sudo", example: "- admin-maybe: x") { parser in
        AdminAction(title: parser.primaryString(), sudo: .maybe, calls: calls)
    })
    registry.register(ActionDescriptor(kind: "asks", summary: "asks a question", example: "- asks: x") { parser in
        AskingAction(title: parser.primaryString(), calls: calls)
    })
    return registry
}

/// Holds `stop()` at the moment it answers `prompt` until the engine has acted on that answer (`acted` is
/// signaled) or half a second has passed. The hook runs inside `stop()`, on the main thread, so whatever the
/// engine does with the answer happens before `stop()` goes on: if the run were not cancelled by then, the
/// item would carry on as if nobody had pressed STOP. That is the race a real Stop & Quit loses only now and
/// then; here it is lost every time. (The hook takes the place of the model's own "take the sheet down"
/// callback, which `stop()` does not need: it clears the sheets itself.)
func holdStop(answering prompt: PendingPrompt, until acted: DispatchSemaphore) {
    let hold: @Sendable () -> Void = { _ = acted.wait(timeout: .now() + 0.5) }
    switch prompt.kind {
    case .password(_, let gate): gate.whenResolved(hold)
    case .question(_, let gate): gate.whenResolved(hold)
    case .text(_, let gate): gate.whenResolved(hold)
    }
}

// MARK: - Keeping the Mac awake (UI-2)

@MainActor
final class KeepAwakeTests: XCTestCase {
    func testARealRunKeepsTheMacAwakeUntilItFinishes() async throws {
        let recorder = KeepAwakeRecorder()
        let (model, _) = try makeModel()
        model.keepAwake = recorder.keepAwake
        XCTAssertFalse(model.isKeepingAwake)

        model.start()
        XCTAssertEqual(recorder.reasons.count, 1)
        XCTAssertTrue(recorder.reasons.first?.contains("Test Dotfiles") == true, "\(recorder.reasons)")
        XCTAssertTrue(model.isKeepingAwake)
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(recorder.ended, 1)
        XCTAssertEqual(recorder.held, 0)
        XCTAssertFalse(model.isKeepingAwake)
    }

    func testStoppingLetsTheMacSleepAgain() async throws {
        let recorder = KeepAwakeRecorder()
        let (model, _) = try makeModel(steps: slowStep)
        model.keepAwake = recorder.keepAwake
        model.start()
        try await waitUntil { model.currentItem?.title == "forever" && model.status(of: model.currentItem!) == .running }
        XCTAssertEqual(recorder.held, 1, "still held while the long item runs")

        model.stop()
        XCTAssertEqual(recorder.held, 1, "held until the engine has wound down")
        try await waitUntil(timeout: 5) { model.phase == .finished }
        XCTAssertEqual(recorder.reasons.count, 1)
        XCTAssertEqual(recorder.ended, 1)
    }

    func testEveryRunTakesItAgainAndGivesItBack() async throws {
        let recorder = KeepAwakeRecorder()
        let (model, _) = try makeModel()
        model.keepAwake = recorder.keepAwake
        model.start()
        try await waitUntil { model.phase == .finished }
        model.start()
        XCTAssertEqual(recorder.held, 1)
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(recorder.reasons.count, 2)
        XCTAssertEqual(recorder.ended, 2)
    }

    func testQuittingMidRunGivesItBack() async throws {
        let recorder = KeepAwakeRecorder()
        let (model, _) = try makeModel(steps: slowStep)
        model.keepAwake = recorder.keepAwake
        let controller = AppController(options: LaunchOptions(), registry: FakeAction.registry())
        controller.model = model
        model.start()
        try await waitUntil { model.currentItem?.title == "forever" }

        // The 15-second fallback can quit before the engine's final summary arrives.
        controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(recorder.ended, 1)
        XCTAssertFalse(model.isKeepingAwake)

        model.stop()
        try await waitUntil(timeout: 5) { model.phase == .finished }
        XCTAssertEqual(recorder.ended, 1, "given back once, not again when the run then ends")
    }

    func testDryRunsSimulationsAndSnapshotsNeverHoldIt() async throws {
        let dry = KeepAwakeRecorder()
        let (dryModel, _) = try makeModel(dryRun: true)
        dryModel.keepAwake = dry.keepAwake
        dryModel.start()
        try await waitUntil { dryModel.phase == .finished }
        XCTAssertTrue(dry.reasons.isEmpty, "a dry run changes nothing and finishes quickly")

        for mode in [RunMode.simulation, .snapshot] {
            let recorder = KeepAwakeRecorder()
            let (model, _) = try makeModel(mode: mode)
            model.keepAwake = recorder.keepAwake
            model.start()
            try await waitUntil { model.phase == .finished }
            XCTAssertTrue(recorder.reasons.isEmpty, "\(mode)")
        }
    }
}

// MARK: - Quitting after the run already ended (UI-3)

@MainActor
final class QuitDuringRunTests: XCTestCase {
    private func makeController(model: InstallerModel, replies: @escaping (Bool) -> Void) -> AppController {
        let controller = AppController(options: LaunchOptions(), registry: FakeAction.registry())
        controller.model = model
        controller.replyToTerminateRequest = replies
        return controller
    }

    func testStopAndQuitAfterTheRunEndedBehindTheAlertQuitsAtOnce() throws {
        let (model, _) = try makeModel()
        model.apply(.runStarted(totalItems: 5))
        var replies: [Bool] = []
        let controller = makeController(model: model) { replies.append($0) }
        controller.confirmQuit = {
            // The last item finishes while the "Stop the install and quit?" alert is open.
            model.apply(.runFinished(InstallSummary()))
            return true
        }

        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertNil(model.onRunFinished, "nothing waits for a summary that has already arrived")
        XCTAssertTrue(replies.isEmpty)
    }

    func testStopAndQuitMidRunWaitsForTheStopThenQuits() async throws {
        let (model, _) = try makeModel(steps: slowStep)
        var replies: [Bool] = []
        let controller = makeController(model: model) { replies.append($0) }
        controller.confirmQuit = { true }
        model.start()
        try await waitUntil { model.currentItem?.title == "forever" && model.status(of: model.currentItem!) == .running }

        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(model.isStopping)
        try await waitUntil(timeout: 5) { replies == [true] }
        XCTAssertEqual(model.outcome, .stopped)
    }

    /// ⌘Q → Stop & Quit while the password sheet is up (STOP itself is behind the sheet): the waiting item is
    /// stopped, not run, and the stop is not reported as a failure.
    func testStopAndQuitAtAPasswordSheetStopsTheWaitingItem() async throws {
        let calls = ItemCalls()
        let steps = ["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: first\n  - admin-maybe: cask\n  - ok: after\n"]
        let (model, _) = try makeModel(steps: steps, registry: promptingRegistry(calls))
        var replies: [Bool] = []
        let controller = makeController(model: model) { replies.append($0) }
        controller.confirmQuit = { true }
        model.start()
        try await waitUntil { model.activePrompt?.isPassword == true }
        holdStop(answering: try XCTUnwrap(model.activePrompt), until: calls.ran)

        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        try await waitUntil(timeout: 5) { replies == [true] }
        XCTAssertEqual(calls.all, ["check cask"], "the item waiting at the sheet must not run once the person chose to stop")
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("one/1"))), .cancelled)
        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertTrue(model.failures.isEmpty)
    }

    func testKeepRunningCancelsTheQuitAndIdleQuitsWithoutAsking() throws {
        let (model, _) = try makeModel()
        var asked = 0
        let controller = makeController(model: model) { _ in XCTFail("no reply expected") }
        controller.confirmQuit = {
            asked += 1
            return false
        }
        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateNow, "nothing running")
        XCTAssertEqual(asked, 0)

        model.apply(.runStarted(totalItems: 5))
        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.isStopping)
    }
}

// MARK: - STOP while a sheet is up

/// STOP answers the open sheet for the person ("no password", the question's default). The run must already
/// be cancelled when the engine gets that answer, or it acts on it as if nobody had pressed STOP.
@MainActor
final class StopAtAPromptTests: XCTestCase {
    func testStopAtTheUpFrontPasswordSheetStartsNoItem() async throws {
        let calls = ItemCalls()
        let steps = ["01.yaml": "id: one\ntitle: One\nitems:\n  - admin-always: brew\n  - ok: after\n"]
        let (model, _) = try makeModel(steps: steps, registry: promptingRegistry(calls))
        model.start()
        try await waitUntil { model.activePrompt?.isPassword == true }
        holdStop(answering: try XCTUnwrap(model.activePrompt), until: calls.checked)
        model.stop()
        try await waitUntil(timeout: 5) { model.phase == .finished }

        XCTAssertEqual(calls.all, [], "no item is started after STOP")
        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertTrue(model.failures.isEmpty, "the declined password is the stop's doing, not a failure: \(model.failures)")
        XCTAssertEqual(model.summary?.failures.count, 0)
        XCTAssertNotEqual(model.look(of: model.steps[0]).tone, .red)
    }

    func testStopAtAQuestionStopsTheItemInsteadOfTakingTheDefaultAnswer() async throws {
        let calls = ItemCalls()
        let steps = ["01.yaml": "id: one\ntitle: One\nitems:\n  - asks: App Store\n  - ok: after\n"]
        let (model, _) = try makeModel(steps: steps, registry: promptingRegistry(calls))
        model.start()
        try await waitUntil { model.activePrompt.map { !$0.isPassword } == true }
        holdStop(answering: try XCTUnwrap(model.activePrompt), until: calls.answered)
        model.stop()
        try await waitUntil(timeout: 5) { model.phase == .finished }

        XCTAssertEqual(calls.all, ["check App Store", "answer yes, stopped: true"],
                       "the default answer ('I'm signed in') reaches the item only once the run is stopped")
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("one/0"))), .cancelled)
        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertTrue(model.failures.isEmpty)
    }
}

// MARK: - After a dry run (UI-4)

@MainActor
final class FinishedDryRunTests: XCTestCase {
    func testAFinishedDryRunKeepsItsNarrationOnScreenAndCopiesIt() async throws {
        let recorder = DesktopRecorder()
        let (model, _) = try makeModel(steps: cleanSteps, dryRun: true, desktop: recorder.actions)
        model.start()
        try await waitUntil { model.phase == .finished }

        XCTAssertEqual(model.outcome, .success)
        XCTAssertTrue(model.runIsDryRun)
        XCTAssertNil(model.summary?.logFile, "the engine writes no log file for a dry run")
        XCTAssertTrue(model.showsLogOnFinishedScreen, "the finished dry run opens on its log")
        XCTAssertTrue(model.log.entries.contains { $0.text == "Dry run: nothing on this Mac will be changed." })
        XCTAssertTrue(model.log.entries.contains { $0.text == "working on alpha" })

        model.copyLog()
        XCTAssertEqual(recorder.copied.count, 1)
        XCTAssertTrue(recorder.copied.first?.contains("working on alpha") == true, "\(recorder.copied)")

        XCTAssertEqual(model.missingLogFileNote, "a dry run writes no log file")
        XCTAssertFalse(model.missingLogFileNote.contains("sandbox"), "every dry run skips the file, sandboxed or not")
        XCTAssertEqual(model.quipMoment, .dryRun, "no 'we did it!' for a rehearsal")
    }

    func testAFailedDryRunOpensOnTheFailuresAndARealRunWithoutAFileSaysSo() async throws {
        let (model, _) = try makeModel(dryRun: true)
        model.start()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.outcome, .failures(1))
        XCTAssertFalse(model.showsLogOnFinishedScreen, "what failed is shown first")

        let (live, _) = try makeModel()
        live.apply(.runStarted(totalItems: 5))
        live.apply(.runFinished(InstallSummary()))
        XCTAssertFalse(live.showsLogOnFinishedScreen)
        XCTAssertEqual(live.missingLogFileNote, "no log file was written")
    }

    func testRunForRealGoesBackToStartWithTheSamePlanAndSelection() async throws {
        let (model, _) = try makeModel(dryRun: true)
        let optional = try XCTUnwrap(model.item("extras/1"))
        model.setItem(optional, enabled: true)
        let stepIDs = model.steps.map(\.id)
        let selected = model.enabledItemCount

        model.setUpRealRun()
        XCTAssertEqual(model.phase, .welcome, "only a finished run can be turned into a real one")
        XCTAssertTrue(model.dryRun)

        model.start()
        model.setUpRealRun()
        XCTAssertEqual(model.phase, .running, "not while the dry run is still going")
        try await waitUntil { model.phase == .finished }
        XCTAssertTrue(model.runIsDryRun)

        model.setUpRealRun()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertFalse(model.dryRun, "DRY RUN is switched off")
        XCTAssertEqual(model.steps.map(\.id), stepIDs, "the same plan, not fetched again")
        XCTAssertEqual(model.enabledItemCount, selected, "the same selection")
        XCTAssertTrue(model.isEnabled(optional))
        XCTAssertTrue(model.canStart)

        model.start()
        XCTAssertFalse(model.runIsDryRun, "START now runs for real")
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.summary?.wasDryRun, false)
        XCTAssertNotNil(model.summary?.logFile, "the real run writes its log (inside the test sandbox)")
        XCTAssertTrue(model.log.entries.contains { $0.text == "Dry run: nothing on this Mac will be changed." },
                      "the dry run's narration is still there above the real run")
    }

    /// The LOG panel keeps the dry run's lines above the real run that follows it, and no file holds them: once
    /// the oldest lines are trimmed, the panel must not say they are in the log file.
    func testAfterRunForRealTheLogPanelDoesNotSayTheDryRunsLinesAreInTheLogFile() async throws {
        let (model, _) = try makeModel(steps: sixItems, dryRun: true, logCapacity: 10)
        model.start()
        try await waitUntil { model.phase == .finished }
        let droppedInDryRun = model.log.droppedCount
        XCTAssertGreaterThan(droppedInDryRun, 0)
        XCTAssertEqual(model.droppedLinesNote, "… \(droppedInDryRun) earlier lines are no longer shown (a dry run writes no log file)")

        model.setUpRealRun()
        model.start()
        try await waitUntil { model.phase == .finished }
        let dropped = model.log.droppedCount
        XCTAssertGreaterThan(dropped, droppedInDryRun, "the real run trims more, starting with the dry run's lines")
        XCTAssertEqual(model.droppedLinesNote, "… \(dropped) earlier lines are no longer shown (this run's lines are also in the log file)")

        let file = try String(contentsOf: try XCTUnwrap(model.summary?.logFile), encoding: .utf8)
        XCTAssertTrue(file.contains("working on alpha"), "the real run's lines are in its log file:\n\(file)")
        XCTAssertFalse(file.contains("Dry run: nothing on this Mac will be changed."), "the dry run's are in no file")

        // RETRY / RESUME after that: the dry run's lines may still be among the trimmed ones.
        model.start()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.droppedLinesNote, "… \(model.log.droppedCount) earlier lines are no longer shown (this run's lines are also in the log file)")
    }

    /// Without a dry run, the trimmed lines are in the log file, as the panel says; a run that turned out to
    /// have no log file says so instead.
    func testTheLogPanelPromisesTheLogFileOnlyWhenItHoldsTheTrimmedLines() async throws {
        let (model, _) = try makeModel(steps: sixItems, logCapacity: 10)
        XCTAssertNil(model.droppedLinesNote)
        model.start()
        try await waitUntil { model.phase == .finished }
        let dropped = model.log.droppedCount
        XCTAssertGreaterThan(dropped, 0)
        XCTAssertEqual(model.droppedLinesNote, "… \(dropped) earlier lines are in the log file")
        XCTAssertFalse(model.log.entries.contains { $0.text == "working on alpha" }, "the first item's lines were trimmed")
        let file = try String(contentsOf: try XCTUnwrap(model.summary?.logFile), encoding: .utf8)
        XCTAssertTrue(file.contains("working on alpha"), "and they are in the log file:\n\(file)")

        let (unfiled, _) = try makeModel(logCapacity: 10)
        unfiled.apply(.runStarted(totalItems: 5))
        for index in 0..<30 { unfiled.apply(.log(LogLine("line \(index)", style: .stdout, itemID: "base/0"))) }
        unfiled.apply(.runFinished(InstallSummary()))
        XCTAssertNil(unfiled.summary?.logFile, "the log file could not be written")
        XCTAssertEqual(unfiled.droppedLinesNote, "… \(unfiled.log.droppedCount) earlier lines are no longer shown (no log file was written)")
    }
}
