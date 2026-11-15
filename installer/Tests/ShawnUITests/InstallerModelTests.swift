import Foundation
import ShawnCore
import ShawnFun
import ShawnSync
import XCTest
@testable import ShawnUI

@MainActor
final class InstallerModelStateTests: XCTestCase {
    // MARK: Loading & selection

    func testConfigureShowsWelcomeWithDefaultSelection() throws {
        let (model, _) = try makeModel()
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertEqual(model.appName, "Test Dotfiles")
        XCTAssertEqual(model.tagline, "testing, testing")
        XCTAssertEqual(model.steps.map(\.id), ["base", "extras", "off"])
        // base: 3, extras: delta + zeta (epsilon is optional), off: switched off.
        XCTAssertEqual(model.enabledItemCount, 5)
        XCTAssertTrue(model.canStart)
        XCTAssertEqual(model.status(of: model.steps[2]), .disabled)
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("extras/1"))), .disabled, "optional items start off")
        XCTAssertTrue(model.configSourceLine.hasPrefix("config: "), model.configSourceLine)
    }

    func testSelectionTogglingOptionalItemsAndDisabledSteps() throws {
        let (model, _) = try makeModel()
        let optional = try XCTUnwrap(model.item("extras/1"))
        let extras = model.steps[1]
        let off = model.steps[2]

        model.setItem(optional, enabled: true)
        XCTAssertEqual(model.enabledItemCount, 6)
        XCTAssertEqual(model.selectedItemCount(in: extras), 3)

        model.setStep(off, enabled: true)
        XCTAssertEqual(model.enabledItemCount, 7)

        model.setStep(extras, enabled: false)
        XCTAssertEqual(model.enabledItemCount, 4, "a step that is off runs none of its items")
        XCTAssertEqual(model.selectedItemCount(in: extras), 3, "check marks inside a switched-off step are remembered")
        XCTAssertEqual(model.status(of: optional), .disabled)

        for step in model.steps { model.setStep(step, enabled: false) }
        XCTAssertEqual(model.enabledItemCount, 0)
        XCTAssertFalse(model.canStart, "START is disabled when nothing is selected")

        model.setStep(extras, enabled: true)
        model.setItem(optional, enabled: false)
        XCTAssertEqual(model.enabledItemCount, 2)
        XCTAssertTrue(model.canStart)
    }

    func testCustomizeNavigationAndSelectionLockDuringRun() throws {
        let (model, _) = try makeModel()
        model.showCustomize()
        XCTAssertEqual(model.phase, .customize)
        XCTAssertTrue(model.canStart)
        model.closeCustomize()
        XCTAssertEqual(model.phase, .welcome)

        model.apply(.runStarted(totalItems: 5))
        XCTAssertEqual(model.phase, .running)
        XCTAssertFalse(model.canStart)
        model.setStep(model.steps[0], enabled: false)
        XCTAssertTrue(model.isEnabled(model.steps[0]), "the selection cannot change mid-run")
        model.showCustomize()
        XCTAssertEqual(model.phase, .running)
    }

    func testStartIsDisabledWhileLoading() {
        let directory = makeTempDirectory()
        let model = InstallerModel(registry: FakeAction.registry(), environment: .testSandbox(directory))
        XCTAssertEqual(model.phase, .loading)
        XCTAssertFalse(model.canStart)
        model.start()
        XCTAssertEqual(model.phase, .loading)
    }

    func testLoadConfigResolvesOffMainThenShowsWelcome() async throws {
        let directory = makeTempDirectory()
        let root = makeConfig(in: directory, steps: standardSteps)
        let model = InstallerModel(registry: FakeAction.registry(), environment: .testSandbox(directory),
                                   resolveOptions: ConfigResolveOptions(explicitPath: root, allowRemote: false))
        model.loadConfig()
        XCTAssertEqual(model.phase, .loading)
        try await waitUntil { model.phase != .loading }
        XCTAssertEqual(model.phase, .welcome)
        XCTAssertEqual(model.enabledItemCount, 5)
    }

    func testBrokenConfigShowsErrorScreenWithIssues() async throws {
        let directory = makeTempDirectory()
        let root = makeConfig(in: directory, steps: ["01.yaml": "id: one\ntitle: One\nitems:\n  - okk: typo\n  - ok: fine\n    flavour: x\n"])
        let model = InstallerModel(registry: FakeAction.registry(), environment: .testSandbox(directory),
                                   resolveOptions: ConfigResolveOptions(explicitPath: root, allowRemote: false))
        model.loadConfig()
        try await waitUntil { model.phase != .loading }
        XCTAssertEqual(model.phase, .configError)
        let failure = try XCTUnwrap(model.loadFailure)
        XCTAssertTrue(failure.message.contains("has problems"), failure.message)
        let text = failure.issues.map(\.description).joined(separator: "\n")
        XCTAssertTrue(text.contains("steps/01.yaml:4") && text.contains("unknown item kind 'okk'"), text)
        XCTAssertTrue(text.contains("Did you mean 'ok'"), text)
        XCTAssertFalse(model.canStart)
        XCTAssertTrue(ConfigErrorView.report(failure).contains("unknown item kind"))
    }

    func testMissingConfigIsAReadableErrorNotACrash() async throws {
        let directory = makeTempDirectory()
        let model = InstallerModel(registry: FakeAction.registry(), environment: .testSandbox(directory),
                                   resolveOptions: ConfigResolveOptions(explicitPath: directory.url.appendingPathComponent("nope"), allowRemote: false))
        model.loadConfig()
        try await waitUntil { model.phase != .loading }
        XCTAssertEqual(model.phase, .configError)
        XCTAssertFalse(model.loadFailure?.message.isEmpty ?? true)
    }

    // MARK: Events

    func testEventsDriveStepAndItemStatusesAndProgress() throws {
        let (model, _) = try makeModel()
        model.apply(.runStarted(totalItems: 5))
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.totalItems, 5)
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("base/0"))), .pending)
        XCTAssertEqual(model.status(of: model.steps[2]), .disabled)

        model.apply([
            .stepStatus(stepID: "base", status: .running),
            .itemStatus(itemID: "base/0", status: .checking),
        ])
        XCTAssertEqual(model.currentStepID, "base")
        XCTAssertEqual(model.currentItemID, "base/0")
        model.apply([
            .itemStatus(itemID: "base/0", status: .running),
            .itemStatus(itemID: "base/0", status: .done(nil)),
            .itemStatus(itemID: "base/1", status: .checking),
            .itemStatus(itemID: "base/1", status: .alreadyDone("already there")),
            .itemStatus(itemID: "base/2", status: .running),
            .itemStatus(itemID: "base/2", status: .failed("kaboom")),
            .stepStatus(stepID: "base", status: .finishedWithFailures(1)),
        ])
        XCTAssertEqual(model.finishedItemCount, 3)
        XCTAssertEqual(model.progressFraction, 3.0 / 5.0, accuracy: 0.0001)
        XCTAssertEqual(model.progress(of: model.steps[0]).finished, 3)
        XCTAssertEqual(model.progress(of: model.steps[0]).total, 3)
        XCTAssertEqual(model.status(of: model.steps[0]), .finishedWithFailures(1))
        XCTAssertEqual(model.failures.map(\.item.id), ["base/2"])
        XCTAssertEqual(model.failures.first?.message, "kaboom")

        // A new item in the next step moves "current" along with it.
        model.apply(.itemStatus(itemID: "extras/0", status: .checking))
        XCTAssertEqual(model.currentStepID, "extras")
        XCTAssertEqual(model.currentItem?.title, "delta")
    }

    func testLogLinesGetItemDividersAndProgressOverwrites() throws {
        let (model, _) = try makeModel()
        model.apply(.runStarted(totalItems: 5))
        model.apply([
            .log(LogLine("Dry run: nothing changes", style: .info)),
            .log(LogLine("$ brew install alpha", style: .command, itemID: "base/0")),
            .log(LogLine("##   10%", style: .stdout, itemID: "base/0", isProgress: true)),
            .log(LogLine("####   40%", style: .stdout, itemID: "base/0", isProgress: true)),
            .log(LogLine("######## 100%", style: .stdout, itemID: "base/0")),
            .log(LogLine("Warning: something", style: .stderr, itemID: "base/0")),
            .log(LogLine("$ next", style: .command, itemID: "base/1")),
        ])
        let entries = model.log.entries
        XCTAssertEqual(entries.map(\.text), ["Dry run: nothing changes", "alpha", "$ brew install alpha", "######## 100%",
                                             "Warning: something", "beta", "$ next"])
        XCTAssertEqual(entries[1].kind, .header)
        XCTAssertEqual(entries[3].kind, .line(.stdout))
        XCTAssertFalse(entries[3].isProgress, "the final line replaced the progress frame")
        XCTAssertEqual(entries[3].version, 2, "rewritten twice in place")
    }

    func testAttentionSideEffectsHappenOncePerAttentionInLiveMode() throws {
        let recorder = DesktopRecorder()
        let (model, _) = try makeModel(desktop: recorder.actions)
        model.apply(.runStarted(totalItems: 5))
        let url = try XCTUnwrap(URL(string: "https://github.com/login/device"))
        let attention = Attention(title: "Sign in", message: "Enter the code", code: "ABCD-1234", url: url)

        model.apply(.attention(itemID: "base/0", attention: attention))
        XCTAssertEqual(model.attention?.attention, attention)
        XCTAssertEqual(recorder.copied, ["ABCD-1234"])
        XCTAssertEqual(recorder.opened, [url])
        XCTAssertTrue(model.attentionCodeCopied)
        XCTAssertEqual(model.quipMoment, .waiting)

        model.apply(.attention(itemID: "base/0", attention: attention))
        XCTAssertEqual(recorder.copied.count, 1, "the same callout again is not acted on twice")
        XCTAssertEqual(recorder.opened.count, 1)

        model.apply(.attention(itemID: "base/1", attention: nil))
        XCTAssertNotNil(model.attention, "clearing another item's callout leaves this one")
        model.apply(.attention(itemID: "base/0", attention: nil))
        XCTAssertNil(model.attention)
        XCTAssertFalse(model.attentionCodeCopied)

        let second = Attention(title: "Open the App Store", message: "Click Get", url: URL(string: "macappstore://x"))
        model.apply(.attention(itemID: "base/1", attention: second))
        XCTAssertEqual(recorder.copied.count, 1, "no code, nothing copied")
        XCTAssertEqual(recorder.opened.count, 2)

        model.openAttentionURL()
        XCTAssertEqual(recorder.opened.count, 3, "the Open button opens it again on request")
    }

    func testNoAutomaticDesktopActionsInSimulationOrSnapshot() throws {
        for mode in [RunMode.simulation, .snapshot] {
            let recorder = DesktopRecorder()
            let (model, _) = try makeModel(mode: mode, desktop: recorder.actions)
            model.apply(.runStarted(totalItems: 5))
            model.apply(.attention(itemID: "base/0", attention: Attention(title: "t", message: "m", code: "C0DE", url: URL(string: "https://example.com"))))
            XCTAssertNotNil(model.attention, "the callout is still shown")
            XCTAssertTrue(recorder.copied.isEmpty && recorder.opened.isEmpty, "\(mode) must not copy or open by itself")
            XCTAssertFalse(model.attentionCodeCopied)
        }
    }

    func testAReminderRowSaysWhereItWentInsteadOfRepeatingItsTitle() throws {
        let (model, _) = try makeModel()
        let item = try XCTUnwrap(model.item("base/0"))
        // The engine ends a reminder with its own title as the message.
        model.apply(.itemStatus(itemID: item.id, status: .needsAttention(item.title)))
        XCTAssertEqual(model.look(of: item), StatusLook("!", .yellow, "needs you", detail: "on your checklist"))
        // Any other message shows as it is.
        model.apply(.itemStatus(itemID: item.id, status: .needsAttention("click the button")))
        XCTAssertEqual(model.look(of: item).detail, "click the button")
    }

    func testFollowUpsAreDeduplicatedAndMergedWithTheSummary() throws {
        let recorder = DesktopRecorder()
        let (model, _) = try makeModel(desktop: recorder.actions)
        model.apply(.runStarted(totalItems: 5))
        let first = FollowUp(id: "a", title: "Do A", url: URL(string: "https://example.com/a"))
        let second = FollowUp(id: "b", title: "Do B")
        model.apply([.followUp(first), .followUp(first)])
        XCTAssertEqual(model.followUps.map(\.id), ["a"])

        var summary = InstallSummary()
        summary.followUps = [first, second]
        summary.logFile = model.environment.logsDirectory.appendingPathComponent("install-x.log")
        model.apply(.runFinished(summary))
        XCTAssertEqual(model.followUps.map(\.id), ["a", "b"])

        model.open(try XCTUnwrap(first.url))
        model.revealLogFile()
        XCTAssertEqual(recorder.opened, [first.url!])
        XCTAssertEqual(recorder.revealed, [summary.logFile!])
    }

    func testRunFinishedOutcomes() throws {
        let (model, _) = try makeModel()
        model.apply(.runStarted(totalItems: 5))
        model.apply(.attention(itemID: "base/0", attention: Attention(title: "t", message: "m")))
        model.apply(.runFinished(InstallSummary()))
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.outcome, .success)
        XCTAssertNil(model.attention, "callouts end with the run")
        XCTAssertNil(model.currentItemID)
        XCTAssertTrue(model.canStart, "a finished run can be run again")

        let (failing, _) = try makeModel()
        failing.apply(.runStarted(totalItems: 5))
        failing.apply(.itemStatus(itemID: "base/2", status: .failed("kaboom")))
        failing.apply(.runFinished(InstallSummary()))
        XCTAssertEqual(failing.outcome, .failures(1))

        // Exactly what InstallEngine sends when STOP lands while an item is running.
        let (stopped, _) = try makeModel()
        stopped.apply(.runStarted(totalItems: 5))
        stopped.apply([
            .stepStatus(stepID: "base", status: .running),
            .itemStatus(itemID: "base/0", status: .checking),
            .itemStatus(itemID: "base/0", status: .running),
            .itemStatus(itemID: "base/0", status: .done(nil)),
            .itemStatus(itemID: "base/1", status: .checking),
            .itemStatus(itemID: "base/1", status: .running),
            .attention(itemID: "base/1", attention: nil),
            .itemStatus(itemID: "base/1", status: .cancelled),
            .stepStatus(stepID: "base", status: .stopped),
        ])
        var summary = InstallSummary()
        summary.done = 1
        summary.wasCancelled = true
        stopped.apply(.runFinished(summary))
        XCTAssertEqual(stopped.outcome, .stopped)
        XCTAssertTrue(stopped.failures.isEmpty, "the item interrupted by STOP is not a failure")
        let base = stopped.steps[0]
        XCTAssertEqual(stopped.look(of: base), StatusLook("■", .pink, "stopped part-way"))
        XCTAssertEqual(stopped.progress(of: base).finished, 1, "the interrupted item did not finish")
        XCTAssertEqual(stopped.progress(of: base).total, 3)
        XCTAssertEqual(stopped.finishedItemCount, 1)
        XCTAssertEqual(stopped.look(of: stopped.steps[1]).label, "not started", "a step the run never reached is not 'waiting'")
        XCTAssertEqual(stopped.quipMoment, .cancelled)
    }

    // MARK: Speech bubble & characters

    func testQuipMomentsFollowTheRun() throws {
        let quotes = """
        speaker: blob
        moments:
          launch: ["hello"]
          idle: ["still here"]
          working: ["working"]
          failure: ["ugh"]
          dry_run: ["pretend"]
          password: ["password please"]
          finished: ["done"]
          finished_with_failures: ["mostly"]
          cancelled: ["fine"]
        """
        let (model, _) = try makeModel(extraFiles: ["fun/quotes.yaml": quotes])
        XCTAssertEqual(model.quipMoment, .launch)
        XCTAssertEqual(model.quip, "hello")
        model.advanceQuip()
        XCTAssertEqual(model.quipMoment, .idle)
        model.dryRun = true
        XCTAssertEqual(model.quipMoment, .dryRun)
        model.dryRun = false

        model.apply(.runStarted(totalItems: 5))
        model.apply(.stepStatus(stepID: "base", status: .running))
        XCTAssertEqual(model.quipMoment, .working)
        XCTAssertTrue(["Base quip", "working"].contains(model.quip), "step quips come first: \(model.quip)")
        model.apply(.itemStatus(itemID: "base/2", status: .failed("kaboom")))
        XCTAssertEqual(model.quip, "ugh")
        model.advanceQuip()
        XCTAssertEqual(model.quipMoment, .working, "a reaction lasts one rotation")

        model.enqueue(.password(PasswordRequest(reason: "r", attempt: 1, lastError: nil, maxAttempts: 3), PromptGate<String?>()))
        XCTAssertEqual(model.quipMoment, .password)
        model.cancelPassword()

        // A question from ask: has lines of its own. The waiting lines complain about a wait that has not happened.
        model.enqueue(.text(TextRequest(id: "email", prompt: "Your email"), PromptGate<String?>()))
        XCTAssertEqual(model.quipMoment, .question)
        model.skipText()

        model.apply(.itemStatus(itemID: "base/0", status: .failed("kaboom")))
        model.apply(.runFinished(InstallSummary()))
        XCTAssertEqual(model.quip, "mostly")
    }

    func testQuipRotationIsDeterministicForASeed() throws {
        let quotes = "speaker: blob\nmoments:\n  launch: [a]\n  idle: [one, two, three, four]\n"
        func sequence(seed: Int) throws -> [String] {
            let (model, _) = try makeModel(quipSeed: seed, extraFiles: ["fun/quotes.yaml": quotes])
            var lines: [String] = []
            for _ in 0..<6 {
                model.advanceQuip()
                lines.append(model.quip)
            }
            return lines
        }
        let first = try sequence(seed: 7)
        XCTAssertEqual(first, try sequence(seed: 7))
        XCTAssertEqual(first, ["one", "two", "three", "four", "one", "two"])
        XCTAssertNotEqual(first, try sequence(seed: 8))
    }

    func testMascotFallsBackToTheSpeakerAndCopesWithNoSprites() throws {
        let sprite = { (id: String) in "id: \(id)\nname: \(id.capitalized)\npalette:\n  X: \"#FF00FF\"\nframes:\n  - |\n    XX\n    XX\n" }
        let (model, _) = try makeModel(extraFiles: [
            "fun/quotes.yaml": "speaker: talker\n",
            "fun/sprites/talker.yaml": sprite("talker"),
            "fun/sprites/zed.yaml": sprite("zed"),
        ])
        XCTAssertEqual(model.speaker?.id, "talker")
        XCTAssertEqual(model.mascot?.id, "talker")
        model.apply(.runStarted(totalItems: 5))
        model.apply(.stepStatus(stepID: "base", status: .running))
        XCTAssertEqual(model.mascot?.id, "talker", "mascot 'blob' has no sprite, so the speaker stands in")
        XCTAssertEqual(model.lineup.map(\.id), ["talker", "zed"])
        XCTAssertTrue(model.notes.contains { $0.contains("mascot 'blob'") }, "the missing sprite is reported as a note: \(model.notes)")

        let (bare, _) = try makeModel()
        XCTAssertNil(bare.speaker)
        XCTAssertNil(bare.mascot)
        XCTAssertTrue(bare.lineup.isEmpty)
        XCTAssertFalse(bare.quip.isEmpty, "FunConfig's fallback lines are used")
    }

    // MARK: Running the real engine

    func testStartRunsTheEngineToTheFinishedScreen() async throws {
        let (model, _) = try makeModel()
        model.start()
        XCTAssertEqual(model.phase, .running)
        XCTAssertFalse(model.canStart)
        try await waitUntil { model.phase == .finished }

        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.done, 2)
        XCTAssertEqual(summary.alreadyDone, 1)
        XCTAssertEqual(summary.needsAttention, 1)
        XCTAssertEqual(model.outcome, .failures(1))
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("base/1"))), .alreadyDone("already there"))
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("extras/1"))), .disabled)
        XCTAssertEqual(model.status(of: model.steps[2]), .disabled)
        XCTAssertEqual(model.followUps.map(\.title), ["Sign in to delta"])
        XCTAssertTrue(model.log.entries.contains { $0.text == "working on alpha" })
        XCTAssertTrue(model.log.entries.contains { $0.text.contains("kaboom") && $0.kind == .line(.error) })
        XCTAssertEqual(model.finishedItemCount, 5)
        XCTAssertEqual(model.progressFraction, 1)
        XCTAssertNotNil(summary.logFile, "the sandbox run writes its log inside the sandbox")
    }

    func testRetryRerunsTheSameSelection() async throws {
        let (model, _) = try makeModel()
        model.start()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.outcome, .failures(1))

        model.start()
        XCTAssertEqual(model.runCount, 2)
        XCTAssertNil(model.summary, "the previous summary is cleared")
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.summary?.done, 2)
        XCTAssertTrue(model.log.entries.contains { $0.text.contains("run 2") }, "the log marks the second run")
    }

    func testStopCancelsTheEngineAndEndsStopped() async throws {
        let steps = ["01.yaml": "id: one\ntitle: One\nitems:\n  - ok: quick\n  - slow: forever\n  - ok: never\n"]
        let (model, _) = try makeModel(steps: steps)
        var finishedCallbacks = 0
        model.onRunFinished = { finishedCallbacks += 1 }
        model.start()
        try await waitUntil { model.currentItem?.title == "forever" && model.status(of: model.currentItem!) == .running }
        let started = Date()
        model.stop()
        XCTAssertTrue(model.isStopping)
        XCTAssertEqual(model.quipMoment, .cancelled)
        try await waitUntil(timeout: 5) { model.phase == .finished }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the slow item is interrupted, not waited for")
        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertFalse(model.isStopping)
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("one/2"))), .pending, "nothing after the stop ran")
        XCTAssertEqual(finishedCallbacks, 1)
        XCTAssertTrue(model.canStart, "RESUME is possible")

        // The STOPPED screen tells the truth: nothing failed, the step stopped part-way, 1 of 3 finished.
        let step = model.steps[0]
        let interrupted = try XCTUnwrap(model.item("one/1"))
        XCTAssertEqual(model.status(of: interrupted), .cancelled)
        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertEqual(model.summary?.failures.count, 0)
        XCTAssertEqual(model.status(of: step), .stopped)
        XCTAssertEqual(model.look(of: step).label, "stopped part-way")
        XCTAssertNotEqual(model.look(of: step).tone, .red)
        XCTAssertEqual(model.progress(of: step).finished, 1)
        XCTAssertEqual(model.progress(of: step).total, 3)
        XCTAssertEqual(model.finishedItemCount, 1)
    }

    /// One real failure, then STOP mid-item: the failure is counted once and the stop is not a second one.
    func testAFailureBeforeTheStopIsCountedOnce() async throws {
        let steps = ["01.yaml": "id: one\ntitle: One\nitems:\n  - boom: first\n  - slow: forever\n  - ok: never\n"]
        let (model, _) = try makeModel(steps: steps)
        model.start()
        try await waitUntil { model.currentItem?.title == "forever" && model.status(of: model.currentItem!) == .running }
        model.stop()
        try await waitUntil(timeout: 5) { model.phase == .finished }

        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertEqual(model.failures.map(\.item.title), ["first"])
        let look = model.look(of: model.steps[0])
        XCTAssertEqual(look.label, "1 failed, stopped part-way")
        XCTAssertEqual(look.tone, .red, "a step with a real failure stays red")
        XCTAssertEqual(model.progress(of: model.steps[0]).finished, 1)
    }

    /// STOP while an item that ignores cancellation is running: the item finishes, and the engine notices
    /// the stop at the top of its loop and closes the step as stopped with the rest not started.
    func testStopBetweenItemsLeavesTheRestNotStarted() async throws {
        let gate = HoldGate()
        let steps = [
            "01.yaml": "id: one\ntitle: One\nitems:\n  - hold: first\n  - ok: second\n",
            "02.yaml": "id: two\ntitle: Two\nitems:\n  - ok: third\n",
        ]
        let (model, _) = try makeModel(steps: steps, registry: FakeAction.registry(gate: gate))
        model.start()
        try await waitUntil { model.currentItem?.title == "first" && model.status(of: model.currentItem!) == .running }
        model.stop()
        gate.release()
        try await waitUntil(timeout: 5) { model.phase == .finished }

        XCTAssertEqual(model.outcome, .stopped)
        let one = model.steps[0], two = model.steps[1]
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("one/0"))), .done(nil))
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("one/1"))), .pending)
        XCTAssertEqual(model.status(of: one), .stopped)
        XCTAssertEqual(model.look(of: one), StatusLook("■", .pink, "stopped part-way"))
        XCTAssertEqual(model.progress(of: one).finished, 1)
        XCTAssertEqual(model.progress(of: one).total, 2)
        XCTAssertEqual(model.look(of: two), StatusLook("·", .faint, "not started"))
        XCTAssertEqual(model.finishedItemCount, 1)
    }

    /// `--fresh` treats every item as not done on the first run only; RETRY then skips what worked, as promised.
    func testFreshAppliesToTheFirstRunOnly() async throws {
        let counter = RunCounter()
        let steps = ["01.yaml": "id: one\ntitle: One\nitems:\n  - counted: good\n  - counted-boom: bad\n"]
        let (model, _) = try makeModel(steps: steps, registry: FakeAction.registry(counter: counter), assumeFresh: true)
        model.start()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(model.outcome, .failures(1))
        XCTAssertEqual(counter.count("good"), 1)

        model.start()
        try await waitUntil { model.phase == .finished }
        XCTAssertEqual(counter.count("good"), 1, "RETRY FAILED skips the item that worked")
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.item("one/0"))), .alreadyDone("done by an earlier run"))
        XCTAssertEqual(counter.count("bad"), 2, "the failed item is retried")
        XCTAssertEqual(model.outcome, .failures(1))
    }

    func testAChattyInstallStaysFastAndBounded() throws {
        let (model, _) = try makeModel()
        model.apply(.runStarted(totalItems: 5))
        let started = Date()
        for index in 0..<30_000 {
            model.apply(.log(LogLine("line \(index)", style: .stdout, itemID: "base/0", isProgress: index % 10 == 9)))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "applying log lines must not copy the whole buffer each time")
        XCTAssertLessThanOrEqual(model.log.count, LogBuffer.defaultCapacity)
        XCTAssertGreaterThan(model.log.droppedCount, 20_000)
        XCTAssertEqual(model.log.entries.last?.text, "line 29999")
    }

    func testEventPumpDeliversBurstsInOrder() async throws {
        var received: [Int] = []
        let pump = EventPump { events in
            for event in events {
                if case .runStarted(let total) = event { received.append(total) }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<2000 { pump.push(.runStarted(totalItems: index)) }
            }
        }
        try await waitUntil { received.count == 2000 }
        XCTAssertEqual(received, Array(0..<2000))
    }
}
