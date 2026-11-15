import Foundation
import ShawnCore
import ShawnFun
import ShawnSync
import XCTest
@testable import ShawnUI

/// Answers prompts from a script, for driving the simulation through the real engine.
private struct ScriptedInteraction: UserInteraction {
    var passwords: [String?] = ["secret"]
    var answer: (@Sendable (Question) -> String)?

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
        attempt <= passwords.count ? passwords[attempt - 1] : nil
    }

    func ask(_ question: Question) async -> String {
        answer?(question) ?? question.defaultOptionID
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [InstallEvent] = []

    func add(_ event: InstallEvent) { lock.withLock { events.append(event) } }
    var all: [InstallEvent] { lock.withLock { events } }

    var finalStatuses: [String: ItemStatus] {
        var statuses: [String: ItemStatus] = [:]
        for case .itemStatus(let id, let status) in all { statuses[id] = status }
        return statuses
    }
}

final class SimulationTests: XCTestCase {
    private func loadSimulation(timeScale: Double = 1) throws -> (ResolvedConfig, SystemEnvironment, TempDirectory) {
        let directory = makeTempDirectory()
        let root = try SimulationConfig.write(into: directory.url)
        let environment = try Simulation.makeEnvironment(root: directory.url.appendingPathComponent("machine"))
        let resolved = try ConfigResolver.load(directory: root, source: .local(root.path),
                                               registry: Simulation.makeRegistry(timeScale: timeScale), environment: environment)
        return (resolved, environment, directory)
    }

    func testSimulationConfigLoadsAndPlansWithZeroIssues() throws {
        let (resolved, _, _) = try loadSimulation()
        XCTAssertEqual(resolved.plan.issues, [], resolved.plan.issues.map(\.description).joined(separator: "\n"))
        let fun = FunConfig.load(from: resolved.config)
        XCTAssertEqual(fun.issues, [], fun.issues.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(fun.fun.speaker, "lumpy")
        XCTAssertNotNil(fun.fun.sprites[fun.fun.speaker])
        for moment in Moment.allCases {
            XCTAssertNotNil(fun.fun.moments[moment], "simulation has a line for \(moment.rawValue)")
        }
        for step in resolved.config.steps {
            if let mascot = step.mascot { XCTAssertNotNil(fun.fun.sprites[mascot], "\(step.id) mascot \(mascot)") }
        }
    }

    func testSimulationExercisesEveryKindAndSelectionCase() throws {
        let (resolved, _, _) = try loadSimulation()
        let plan = resolved.plan
        XCTAssertEqual(Set(plan.allItems.map(\.config.kind)), Set(Simulation.makeRegistry().kinds), "every simulated kind is used")
        XCTAssertTrue(plan.steps.contains { !$0.config.enabledByDefault }, "a step that is off by default")
        XCTAssertTrue(plan.allItems.contains { $0.config.optional }, "an optional item")
        XCTAssertTrue(plan.allItems.contains { $0.config.note != nil }, "an item with a note")
        XCTAssertTrue(plan.steps.contains { $0.config.mascot == nil }, "a step without a mascot")
        XCTAssertGreaterThan(Selection.defaults(for: plan).enabledItems(in: plan).count, 10)
    }

    func testPlaceholderSpritesStayWithinThirtyTwoPixelsAndAnimate() throws {
        let (resolved, _, _) = try loadSimulation()
        let sprites = FunConfig.load(from: resolved.config).fun.sprites
        XCTAssertGreaterThanOrEqual(sprites.count, 5)
        for sprite in sprites.values {
            XCTAssertLessThanOrEqual(sprite.width, 32, sprite.id)
            XCTAssertLessThanOrEqual(sprite.height, 32, sprite.id)
            XCTAssertGreaterThanOrEqual(sprite.frames.count, 2, sprite.id)
            XCTAssertFalse(SpriteLayout.runs(in: sprite.frames[0]).isEmpty, "\(sprite.id) draws something")
        }
        XCTAssertTrue(sprites.values.contains { $0.width == 32 && $0.height == 32 }, "one sprite is the maximum size")
    }

    func testHeaderRowsAllHaveTheSameWidth() {
        let rows = SimulationConfig.header.split(separator: "\n").map(\.count)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(Set(rows).count, 1, "\(rows)")
        for (letter, glyph) in SimulationConfig.glyphs {
            XCTAssertEqual(glyph.count, 6, letter)
            XCTAssertEqual(Set(glyph.map(\.count)).count, 1, "glyph \(letter) rows differ in width")
        }
    }

    func testRunningTheSimulationThroughTheEngineProducesEveryOutcome() async throws {
        let (resolved, environment, _) = try loadSimulation(timeScale: 0)
        let plan = resolved.plan
        let engine = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: true),
                                   interaction: ScriptedInteraction())
        let log = EventLog()
        let summary = await engine.run(selection: .defaults(for: plan)) { log.add($0) }

        let statuses = log.finalStatuses
        func status(_ title: String) -> ItemStatus? {
            plan.allItems.first { $0.title == title }.flatMap { statuses[$0.id] }
        }
        XCTAssertEqual(status("Xcode Command Line Tools"), .alreadyDone("already installed"))
        XCTAssertEqual(status("Package manager"), .done(nil), "the simulated password check accepts any password")
        XCTAssertEqual(status("Intel helper"), .skipped("not needed on Apple silicon"))
        XCTAssertEqual(status("neovim"), .disabled, "optional items stay off")
        XCTAssertEqual(status("Screen saver"), .disabled, "the step that is off by default")
        XCTAssertEqual(status("Sign in to GitHub"), .done("signed in"))
        if case .needsAttention? = status("Allow Accessibility for Hammerspoon") {} else { XCTFail("manual item needs attention") }
        guard case .failed(let message)? = status("Lumpy Space Radio") else { return XCTFail("the failing item failed") }
        XCTAssertTrue(message.contains("No Cask with this name exists"), message)
        XCTAssertTrue(message.contains("brew search lumpy"), "the hint is part of the message: \(message)")

        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.followUps.count, 2)
        XCTAssertTrue(summary.wasDryRun)
        XCTAssertNil(summary.logFile, "a sandboxed dry run writes no log file")

        let lines = log.all.compactMap { event -> LogLine? in
            if case .log(let line) = event { return line }
            return nil
        }
        XCTAssertTrue(lines.contains { $0.isProgress && $0.text.contains("%") }, "progress frames stream through")
        XCTAssertTrue(lines.contains { $0.style == .stderr && $0.text.hasPrefix("Warning:") }, "stderr streams through")
        XCTAssertTrue(lines.contains { $0.style == .command && $0.text == "$ brew install --formula ripgrep" })
        XCTAssertTrue(lines.contains { $0.style == .stdout && $0.text.contains("Pouring fd") })
        let codes = log.all.compactMap { event -> String? in
            if case .attention(_, let attention?) = event { return attention.code }
            return nil
        }
        XCTAssertEqual(codes, ["LUMP-5PCE"])
    }

    func testSimulatedAdminRetriesAfterAWrongPasswordAndFailsWhenDeclined() async throws {
        let (resolved, environment, _) = try loadSimulation(timeScale: 0)
        let plan = resolved.plan
        let selection = Selection.only(steps: ["bootstrap"], in: plan)

        let retry = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: true),
                                  interaction: ScriptedInteraction(passwords: ["", "second try"]))
        let retried = EventLog()
        _ = await retry.run(selection: selection) { retried.add($0) }
        let admin = try XCTUnwrap(plan.allItems.first { $0.title == "Package manager" })
        XCTAssertEqual(retried.finalStatuses[admin.id], .done(nil))

        let decline = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: true),
                                    interaction: ScriptedInteraction(passwords: [nil]))
        let declined = EventLog()
        _ = await decline.run(selection: selection) { declined.add($0) }
        guard case .failed(let message)? = declined.finalStatuses[admin.id] else { return XCTFail("declining fails the item") }
        XCTAssertTrue(message.contains("administrator password was not provided"), message)
    }

    func testAnsweringTheQuestionWithTheOtherOptionSkips() async throws {
        let (resolved, environment, _) = try loadSimulation(timeScale: 0)
        let plan = resolved.plan
        let selection = Selection.only(steps: ["apps"], in: plan)
        let engine = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: true),
                                   interaction: ScriptedInteraction(answer: { $0.options[1].id }))
        let log = EventLog()
        _ = await engine.run(selection: selection) { log.add($0) }
        let item = try XCTUnwrap(plan.allItems.first { $0.title == "Amphetamine" })
        guard case .skipped(let reason)? = log.finalStatuses[item.id] else { return XCTFail("expected skipped") }
        XCTAssertTrue(reason.contains("Skip App Store apps"), reason)
    }

    /// `--simulate` end to end: the model drives the real engine over the simulated kinds, and the test
    /// answers the password and question sheets the way a person would.
    @MainActor
    func testSimulateModeRunsToTheEndThroughTheModel() async throws {
        let directory = makeTempDirectory()
        let recorder = DesktopRecorder()
        let model = try SnapshotCommand.makeSimulationModel(options: LaunchOptions(), scratch: directory.url, mode: .simulation,
                                                            timeScale: 0.001)
        model.desktop = recorder.actions
        XCTAssertFalse(model.dryRun, "the DRY RUN toggle is the person's choice, even in the simulation")
        model.start()
        XCTAssertFalse(model.runIsDryRun)

        var answered: [String] = []
        let deadline = Date().addingTimeInterval(30)
        while model.phase != .finished, Date() < deadline {
            if let prompt = model.activePrompt {
                switch prompt.kind {
                case .password:
                    answered.append("password")
                    model.submitPassword("anything at all")
                case .question(let question, _):
                    answered.append("question")
                    model.answer(optionID: question.defaultOptionID)
                }
            }
            if model.attention != nil { answered.append("attention") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.outcome, .failures(1))
        XCTAssertEqual(model.failures.map(\.item.title), ["Lumpy Space Radio"])
        XCTAssertTrue(answered.contains("password") && answered.contains("question"), "\(answered)")
        XCTAssertEqual(model.followUps.count, 2)
        XCTAssertTrue(recorder.copied.isEmpty && recorder.opened.isEmpty, "the simulation never copies or opens by itself")
        XCTAssertTrue(model.log.entries.contains { $0.isProgress == false && $0.text.contains("100.0%") }, "progress frames ended in a final line")
        XCTAssertTrue(model.notes.first?.hasPrefix("Simulation:") == true)
    }

    @MainActor
    func testSnapshotScriptPutsTheModelInEveryState() throws {
        let options = LaunchOptions()
        for state in SnapshotState.allCases {
            let directory = makeTempDirectory()
            let model = try SnapshotCommand.makeSimulationModel(options: options, scratch: directory.url, mode: .snapshot,
                                                                configureNow: state != .loading)
            SnapshotScript.apply(state, to: model)
            switch state {
            case .loading: XCTAssertEqual(model.phase, .loading)
            case .welcome: XCTAssertEqual(model.phase, .welcome)
            case .customize: XCTAssertEqual(model.phase, .customize)
            case .running:
                XCTAssertEqual(model.phase, .running)
                XCTAssertNotNil(model.currentItem)
                XCTAssertTrue(model.log.entries.contains { $0.isProgress })
                XCTAssertEqual(model.elapsed(at: model.now()), 192, accuracy: 0.5, "a fixed clock keeps snapshots stable")
            case .password: XCTAssertEqual(model.activePrompt?.isPassword, true)
            case .question: XCTAssertEqual(model.activePrompt?.isPassword, false)
            case .attention: XCTAssertEqual(model.attention?.attention.code, SnapshotScript.sampleAttention.code)
            case .finished: XCTAssertEqual(model.outcome, .success)
            case .failed:
                XCTAssertEqual(model.outcome, .failures(2))
                XCTAssertEqual(model.summary?.failures.count, 2, "the summary and the item rows agree")
            case .stopped:
                XCTAssertEqual(model.outcome, .stopped)
                XCTAssertTrue(model.failures.isEmpty)
                XCTAssertEqual(model.itemStatuses.values.filter { $0 == .cancelled }.count, 1, "one item was interrupted")
                XCTAssertEqual(model.stepStatuses.values.filter { $0 == .stopped }.count, 1, "its step was closed as stopped")
                XCTAssertFalse(model.steps.contains { model.look(of: $0).tone == .red }, "nothing failed, so nothing is red")
                XCTAssertTrue(model.steps.contains { model.look(of: $0) == .notStarted }, "the steps after the stop were never reached")
                XCTAssertGreaterThan(model.unfinishedItemCount, 0)
            case .dryRunFinished:
                XCTAssertEqual(model.outcome, .success)
                XCTAssertTrue(model.runIsDryRun)
                XCTAssertNil(model.summary?.logFile, "a dry run writes no log file")
                XCTAssertTrue(model.showsLogOnFinishedScreen, "a finished dry run opens on its log")
                XCTAssertTrue(model.log.entries.contains { $0.text.hasPrefix("[dry-run] $ ") })
            case .configError:
                XCTAssertEqual(model.phase, .configError)
                XCTAssertFalse(model.loadFailure?.issues.isEmpty ?? true)
            }
            if model.phase == .finished {
                let needingYou = model.itemStatuses.values.filter { if case .needsAttention = $0 { return true } else { return false } }
                XCTAssertEqual(model.summary?.needsAttention, needingYou.count, "\(state): the banner's count matches the rows")
            }
        }
    }

    /// The STOPPED snapshot replays the engine's events; this pins what the real engine sends when STOP
    /// lands while an item runs, so the script cannot drift from it unnoticed.
    @MainActor
    func testStopMidItemEndsWithTheEventsTheStoppedSnapshotUses() async throws {
        let (resolved, environment, _) = try loadSimulation(timeScale: 0.01)
        let plan = resolved.plan
        let engine = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: true),
                                   interaction: ScriptedInteraction())
        let log = EventLog()
        let runs = RunningCount()
        let task = Task.detached {
            await engine.run(selection: .defaults(for: plan)) { event in
                log.add(event)
                // STOP while the third item runs: cancelled before its command starts, as a real STOP mid-command is.
                if case .itemStatus(_, .running) = event, runs.increment() == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let summary = await task.value
        XCTAssertTrue(summary.wasCancelled)
        XCTAssertTrue(summary.failures.isEmpty)

        let statuses = log.all.compactMap { event -> String? in
            switch event {
            case .itemStatus(_, let status): return "item \(status)"
            case .stepStatus(_, let status): return "step \(status)"
            case .runFinished: return "finished"
            default: return nil
            }
        }
        XCTAssertEqual(Array(statuses.suffix(4)), ["item running", "item cancelled", "step stopped", "finished"])
        XCTAssertFalse(statuses.contains { $0.hasPrefix("item failed") }, "a STOP is never reported as a failure")

        // The same events through the model give the STOPPED screen the snapshot shows.
        let directory = makeTempDirectory()
        let model = try SnapshotCommand.makeSimulationModel(options: LaunchOptions(), scratch: directory.url, mode: .snapshot)
        model.apply(log.all)
        XCTAssertEqual(model.outcome, .stopped)
        XCTAssertFalse(model.steps.contains { model.look(of: $0).tone == .red })
        let stoppedStep = try XCTUnwrap(model.steps.first { model.status(of: $0) == .stopped })
        XCTAssertEqual(model.look(of: stoppedStep).label, "stopped part-way")
        XCTAssertEqual(model.finishedItemCount, summary.total, "the screen counts what the engine counted, not the interrupted item")
        XCTAssertEqual(model.unfinishedItemCount, model.totalItems - summary.total)
    }
}

private final class RunningCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int { lock.withLock { count += 1; return count } }
}
