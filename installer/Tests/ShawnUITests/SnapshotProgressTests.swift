import AppKit
import ShawnCore
import XCTest
@testable import ShawnUI

/// `--snapshot-progress`: the running screen at any point of a run with no failures, which
/// scripts/make-media.sh plays as a time-lapse.
@MainActor
final class SnapshotProgressTests: XCTestCase {
    private let fractions = [0, 0.01, 0.1, 0.25, 1.0 / 3, 0.5, 0.62, 0.75, 0.9, 0.99, 1]

    private func simulationModel() throws -> InstallerModel {
        try SnapshotCommand.makeSimulationModel(options: LaunchOptions(), scratch: makeTempDirectory().url, mode: .snapshot)
    }

    private func model(at fraction: Double) throws -> InstallerModel {
        let model = try simulationModel()
        SnapshotProgress.play(fraction, on: model)
        return model
    }

    /// The selected items of the run on screen, in plan order.
    private func runItems(_ model: InstallerModel) -> [PlannedItem] {
        model.steps.filter { model.isEnabled($0) }.flatMap(\.items).filter { model.status(of: $0) != .disabled }
    }

    private func runSteps(_ model: InstallerModel) -> [PlannedStep] {
        model.steps.filter { model.status(of: $0) != .disabled }
    }

    func testCountsAddUpAtEveryFraction() throws {
        for fraction in fractions {
            let model = try model(at: fraction)
            let label = "at \(fraction)"
            XCTAssertEqual(model.phase, .running, label)
            let statuses = runItems(model).map { model.status(of: $0) }
            XCTAssertEqual(statuses.count, model.totalItems, label)
            XCTAssertEqual(model.totalItems, model.enabledItemCount, label)

            var done = 0, alreadyDone = 0, needsYou = 0, inProgress = 0, waiting = 0
            for status in statuses {
                switch status {
                case .done: done += 1
                case .alreadyDone: alreadyDone += 1
                case .needsAttention: needsYou += 1
                case .checking, .running: inProgress += 1
                case .pending: waiting += 1
                default: XCTFail("\(label): a clean run has no \(status) item")
                }
            }
            XCTAssertEqual(done + alreadyDone + needsYou + inProgress + waiting, model.totalItems, label)
            XCTAssertEqual(model.finishedItemCount, done + alreadyDone + needsYou, label)
            XCTAssertEqual(runSteps(model).map { model.progress(of: $0).finished }.reduce(0, +), model.finishedItemCount,
                           "\(label): the steps' counts add up to the STEPS panel's")
            XCTAssertEqual(inProgress, fraction < 1 ? 1 : 0, "\(label): one item at a time")
            XCTAssertEqual(model.progressFraction, Double(model.finishedItemCount) / Double(model.totalItems), accuracy: 1e-9, label)
            XCTAssertTrue(model.failures.isEmpty, label)
        }
    }

    func testZeroIsTheFirstItemStartingAndOneIsEveryItemThrough() throws {
        let start = try model(at: 0)
        let items = runItems(start)
        XCTAssertEqual(start.finishedItemCount, 0)
        XCTAssertEqual(start.currentItemID, items.first?.id)
        XCTAssertEqual(start.status(of: try XCTUnwrap(items.first)), .running)
        XCTAssertEqual(start.elapsed(at: start.now()), 0)
        XCTAssertEqual(runSteps(start).map { start.status(of: $0) }.filter { $0 == .running }.count, 1)

        let end = try model(at: 1)
        XCTAssertEqual(end.phase, .running, "the moment before the finished screen")
        XCTAssertEqual(end.finishedItemCount, end.totalItems)
        XCTAssertEqual(end.progressFraction, 1)
        XCTAssertTrue(runSteps(end).allSatisfy { end.status(of: $0) == .done })
        XCTAssertEqual(end.elapsed(at: end.now()), SnapshotProgress.runDuration)
    }

    func testTheSameFractionGivesTheSameModel() throws {
        for fraction in [0, 0.42, 1] {
            let first = try model(at: fraction), second = try model(at: fraction)
            XCTAssertEqual(first.itemStatuses, second.itemStatuses)
            XCTAssertEqual(first.stepStatuses, second.stepStatuses)
            XCTAssertEqual(first.log, second.log)
            XCTAssertEqual(first.currentItemID, second.currentItemID)
            XCTAssertEqual(first.quip, second.quip)
            XCTAssertEqual(first.saying.speakerID, second.saying.speakerID)
            XCTAssertEqual(first.elapsed(at: first.now()), second.elapsed(at: second.now()))
        }
    }

    func testTheRunOnlyMovesForward() throws {
        var previous: InstallerModel?
        for step in 0...60 {
            let model = try model(at: Double(step) / 60)
            if let previous {
                XCTAssertGreaterThanOrEqual(model.finishedItemCount, previous.finishedItemCount, "frame \(step)")
                XCTAssertGreaterThan(model.elapsed(at: model.now()), previous.elapsed(at: previous.now()), "frame \(step)")
                for item in runItems(previous) where previous.status(of: item).isComplete {
                    XCTAssertEqual(model.status(of: item), previous.status(of: item), "frame \(step): \(item.title) stays as it ended")
                }
            }
            previous = model
        }
    }

    func testItemsEndAsTheyDoOnTheFinishedScreen() throws {
        let finished = try simulationModel()
        SnapshotScript.apply(.finished, to: finished)
        XCTAssertEqual(finished.summary?.duration, SnapshotProgress.runDuration, "the clock stops where the summary says")
        for fraction in [0.5, 1] {
            let model = try model(at: fraction)
            for item in runItems(model) where model.status(of: item).isComplete {
                XCTAssertEqual(model.status(of: item), finished.status(of: item), "\(item.title) at \(fraction)")
            }
        }
        let end = try model(at: 1)
        XCTAssertEqual(end.finishedItemCount, finished.finishedItemCount)
    }

    /// 2 × steps + 1 evenly spaced frames put every step on screen, with its own character and line.
    func testEvenlySpacedFramesShowEveryStep() throws {
        let steps = runSteps(try model(at: 0))
        let frames = 2 * steps.count + 1
        var shown = Set<String>()
        for index in 0..<(frames - 1) {
            let model = try model(at: Double(index) / Double(frames - 1))
            let step = try XCTUnwrap(model.currentStep)
            shown.insert(step.id)
            let mascot = step.config.mascot
            XCTAssertEqual(model.saying.speakerID, model.fun.speakerID(for: .working, stepID: step.id, mascot: mascot), step.id)
            XCTAssertEqual(model.saying.speakerID, mascot ?? model.fun.speaker, "\(step.id): its own character speaks")
            XCTAssertEqual(model.saying.sprite?.id, model.saying.speakerID, "\(step.id): and is drawn")
            let own = model.fun.stepLines(step.id, mascot: mascot)
            if !own.isEmpty {
                XCTAssertEqual(model.quip, own[0], "\(step.id): the step's own line")
            }
        }
        XCTAssertEqual(shown, Set(steps.map(\.id)))
    }

    func testWorksWithAnyConfig() throws {
        let (start, _) = try makeModel()
        SnapshotProgress.play(0.1, on: start)
        XCTAssertEqual(start.currentStepID, "base")
        XCTAssertEqual(start.quip, "Base quip", "the step's own line")
        let off = try XCTUnwrap(start.steps.first { $0.id == "off" })
        XCTAssertEqual(start.status(of: off), .disabled, "a step that is off stays out of the run")

        let (end, _) = try makeModel()
        SnapshotProgress.play(1, on: end)
        XCTAssertEqual(end.totalItems, 5, "the optional item and the step that is off are not counted")
        XCTAssertEqual(end.finishedItemCount, end.totalItems)
    }

    func testTheItemInProgressShowsItsOutput() throws {
        // A frame whose item is running rather than being checked.
        var running: InstallerModel?
        for fraction in fractions where fraction < 1 {
            let candidate = try model(at: fraction)
            if let item = candidate.currentItem, candidate.status(of: item) == .running {
                running = candidate
                break
            }
        }
        let model = try XCTUnwrap(running, "some frame has an item running")
        let item = try XCTUnwrap(model.currentItem)
        let lines = model.log.entries.filter { $0.itemID == item.id && $0.kind != .header }.map(\.text)
        let expected = SnapshotOutput.start(item, model: model).compactMap { event -> String? in
            if case .log(let line) = event { return line.text }
            return nil
        }
        XCTAssertEqual(Array(lines.prefix(expected.count)), expected, "the lines its kind prints")

        let dry = try simulationModel()
        dry.dryRun = true
        SnapshotProgress.play(0.5, on: dry)
        XCTAssertTrue(dry.runIsDryRun)
        let dryLines = dry.log.entries.filter { $0.itemID == dry.currentItemID && $0.kind != .header }
        XCTAssertFalse(dryLines.contains { $0.isProgress }, "a dry run downloads nothing")
    }

    func testWithoutAPointTheStateIsUnchanged() throws {
        var options = LaunchOptions()
        options.snapshotState = .running
        let fixed = try simulationModel()
        try SnapshotProgress.apply(options, to: fixed) { _ in XCTFail("no point, nothing to report") }
        XCTAssertEqual(fixed.elapsed(at: fixed.now()), 192, "no flag: the usual running screen")

        options.snapshotPoint = .fraction(0.5)
        let halfway = try simulationModel()
        var reported: [String] = []
        try SnapshotProgress.apply(options, to: halfway) { reported.append($0) }
        XCTAssertEqual(halfway.elapsed(at: halfway.now()), (SnapshotProgress.runDuration / 2).rounded())
        XCTAssertTrue(halfway.failures.isEmpty)
        let item = try XCTUnwrap(halfway.currentItem)
        XCTAssertEqual(reported, ["progress 0.500000 \(halfway.currentStepID ?? "") \(item.config.kind) \(item.title)"])
    }

    /// The screens built on the running screen show the run at the point, with their sheet or callout on top.
    func testEveryScreenOnTheRunningScreenMoves() throws {
        for state in [SnapshotState.running, .question, .attention] {
            var options = LaunchOptions()
            options.snapshotState = state
            options.snapshotPoint = .fraction(0.25)
            let model = try simulationModel()
            try SnapshotProgress.apply(options, to: model) { _ in }
            XCTAssertEqual(model.elapsed(at: model.now()), (0.25 * SnapshotProgress.runDuration).rounded(), state.rawValue)
            switch state {
            case .question: XCTAssertEqual(model.activePrompt?.isPassword, false)
            case .attention: XCTAssertEqual(model.attention?.itemID, model.currentItemID)
            default: XCTAssertNil(model.activePrompt)
            }
        }
    }

    /// A run asks for the password before its first step, so that sheet has no point of a run to move to.
    func testThePasswordSheetShowsNoRunToMove() throws {
        for state in [SnapshotState.password, .passwordAgain] {
            var options = LaunchOptions()
            options.snapshotState = state
            options.snapshotPoint = .fraction(0.25)
            let model = try simulationModel()
            XCTAssertThrowsError(try SnapshotProgress.apply(options, to: model) { _ in }, state.rawValue)
        }
    }

    func testAtKindPutsTheRunOnTheFirstItemOfThatKind() throws {
        var options = LaunchOptions()
        options.snapshotState = .attention
        options.snapshotPoint = .kind("sim-install")
        let model = try simulationModel()
        var reported = ""
        try SnapshotProgress.apply(options, to: model) { reported = $0 }
        let item = try XCTUnwrap(model.currentItem)
        XCTAssertEqual(item.config.kind, "sim-install")
        XCTAssertEqual(model.status(of: item), .running, "the first one the run does not find already done")
        XCTAssertEqual(model.attention?.itemID, item.id, "the callout belongs to it")
        let fraction = try XCTUnwrap(Double(reported.split(separator: " ")[1]))
        XCTAssertEqual(fraction, try SnapshotProgress.resolve(.kind("sim-install"), model: try simulationModel()), accuracy: 1e-6)
        XCTAssertEqual(model.elapsed(at: model.now()), (fraction * SnapshotProgress.runDuration).rounded())
    }

    /// A GitHub sign-in at the third position, where the snapshots would otherwise find an item already done.
    func testTheGitHubCalloutBelongsToTheRunningGitHubItem() throws {
        var registry = ActionRegistry()
        for kind in ["brew", "github", "manual"] {
            registry.register(ActionDescriptor(kind: kind, summary: kind, example: "- \(kind): x") { parser in
                FakeAction(title: parser.primaryString())
            })
        }
        let (model, _) = try makeModel(steps: ["01-a.yaml": """
            id: a
            title: A
            items:
              - brew: bat
              - brew: fd
              - github: github.com
              - manual: Check your email
            """], registry: registry, mode: .snapshot)
        var options = LaunchOptions()
        options.snapshotState = .attention
        options.snapshotPoint = .kind("github")
        try SnapshotProgress.apply(options, to: model) { _ in }
        let item = try XCTUnwrap(model.currentItem)
        XCTAssertEqual(item.config.kind, "github")
        XCTAssertEqual(model.status(of: item), .running)
        XCTAssertEqual(model.attention?.itemID, item.id)
    }

    func testScreensWithoutARunAndUnknownKindsAreErrors() throws {
        for state in [SnapshotState.welcome, .customize, .finished, .configError] {
            var options = LaunchOptions()
            options.snapshotState = state
            options.snapshotPoint = .fraction(0.5)
            XCTAssertThrowsError(try SnapshotProgress.apply(options, to: try simulationModel()) { _ in }, state.rawValue) { error in
                XCTAssertTrue("\(error)".contains("shows no run"), "\(error)")
            }
        }
        var options = LaunchOptions()
        options.snapshotState = .running
        options.snapshotPoint = .kind("no-such-kind")
        XCTAssertThrowsError(try SnapshotProgress.apply(options, to: try simulationModel()) { _ in }) { error in
            XCTAssertTrue("\(error)".contains("no item of kind 'no-such-kind'"), "\(error)")
        }
    }

    func testTheStoppedScreenSaysWhenTheRunStopped() throws {
        let stopped = try simulationModel()
        SnapshotScript.apply(.stopped, to: stopped)
        let items = runItems(stopped).count
        let duration = try XCTUnwrap(stopped.summary?.duration)
        XCTAssertEqual(duration, SnapshotProgress.elapsed(atItem: items / 2, model: try simulationModel()))
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThan(duration, SnapshotProgress.runDuration, "it stopped part-way")
    }

    func testAProgressFrameRendersToAPNG() throws {
        let model = try model(at: 0.5)
        let data = try SnapshotRenderer.png(of: RootView(model: model, isSnapshot: true), size: Theme.minimumWindowSize, scale: 1)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, Int(Theme.minimumWindowSize.width))
        XCTAssertGreaterThan(data.count, 10_000)
    }

    // MARK: The flags

    func testTheFlagsParse() throws {
        XCTAssertNil(try LaunchOptions.parse([]).snapshotPoint)
        XCTAssertEqual(try LaunchOptions.parse(["--snapshot-state", "running", "--snapshot-progress", "0.25"]).snapshotPoint, .fraction(0.25))
        XCTAssertEqual(try LaunchOptions.parse(["--snapshot-progress=0"]).snapshotPoint, .fraction(0))
        XCTAssertEqual(try LaunchOptions.parse(["--snapshot-progress", "1"]).snapshotPoint, .fraction(1))
        XCTAssertEqual(try LaunchOptions.parse(["--snapshot-at-kind", "github"]).snapshotPoint, .kind("github"))
        XCTAssertEqual(try LaunchOptions.parse(["--snapshot-at-kind=mas", "--snapshot-progress", "0.5"]).snapshotPoint, .fraction(0.5),
                       "the last one wins")
        XCTAssertTrue(LaunchOptions.usage.contains("--snapshot-progress"))
        XCTAssertTrue(LaunchOptions.usage.contains("--snapshot-at-kind"))
    }

    func testBadProgressValuesAreUsageErrors() {
        for text in ["1.5", "-0.1", "half", "nan", "inf", ""] {
            XCTAssertThrowsError(try LaunchOptions.parse(["--snapshot-state", "running", "--snapshot-progress", text]), text) { error in
                guard case .invalidValue(let flag, let value, _)? = error as? LaunchOptionsError else {
                    return XCTFail("\(text): \(error)")
                }
                XCTAssertEqual(flag, "--snapshot-progress")
                XCTAssertEqual(value, text)
                XCTAssertTrue("\(error)".contains("0 to 1"), "\(error)")
            }
        }
        for flag in ["--snapshot-progress", "--snapshot-at-kind"] {
            XCTAssertThrowsError(try LaunchOptions.parse([flag])) { error in
                XCTAssertEqual(error as? LaunchOptionsError, .missingValue(flag))
            }
            XCTAssertThrowsError(try LaunchOptions.parse([flag, "--dry-run"])) { error in
                XCTAssertEqual(error as? LaunchOptionsError, .missingValue(flag))
            }
        }
    }
}
