import Foundation
import ShawnCore
import ShawnFun

/// Where `--snapshot-progress` and `--snapshot-at-kind` put the run.
public enum SnapshotPoint: Equatable, Sendable {
    /// This far through the run, 0 to 1.
    case fraction(Double)
    /// The first item of this kind (`brew`, `github`, …) that the run does not find already done, just started:
    /// its commands are out, its download has not begun. That is when a sign-in or a code comes up.
    case kind(String)
}

/// The running screen at any point of a run with no failures, so a row of snapshots plays as a time-lapse
/// (`scripts/make-media.sh` makes the README's animations from them). Every screen built on the running
/// screen (`SnapshotScript.playRunning`) shows the run at that point, with its sheet or callout on top.
///
/// Like `SnapshotScript`, everything comes from the plan by position, so it works with any config. Each item
/// ends as it ends on the finished screen (`SnapshotScript.playFinished` with no failures), so the last frame
/// leads into that screen. Half of the run's time goes to items and half is split evenly between the steps,
/// so even a one-item step stays on screen as long as several items. Evenly spaced fractions, 2 × steps + 1
/// of them, show every step at least once.
@MainActor
enum SnapshotProgress {
    /// How long the whole run takes. The finished screen says the same: "in 4m 12s".
    static let runDuration: TimeInterval = 4 * 60 + 12

    /// The fraction `SnapshotScript.playRunning` plays the run to while `apply` renders a point.
    private static var pending: Double?

    /// The pending fraction, once: `SnapshotScript.playRunning` plays the run to it instead of its fixed point.
    static func takePending() -> Double? {
        defer { pending = nil }
        return pending
    }

    /// What `--snapshot` puts on screen: `SnapshotScript`'s state, at the point of the run the options name.
    /// Then `report` gets one line: `progress <fraction> <step id> <item kind> <item title>`.
    static func apply(_ options: LaunchOptions, to model: InstallerModel, report: (String) -> Void = { print($0) }) throws {
        guard let point = options.snapshotPoint else { return SnapshotScript.apply(options.snapshotState, to: model) }
        let fraction = try resolve(point, model: model)
        pending = fraction
        defer { pending = nil }
        SnapshotScript.apply(options.snapshotState, to: model)
        guard pending == nil else {
            throw SnapshotError(description: "the \(options.snapshotState.rawValue) screen shows no run, so --snapshot-progress and --snapshot-at-kind cannot move it")
        }
        model.now = { clock(at: fraction) }
        let item = model.currentItem
        report("progress \(String(format: "%.6f", fraction)) \(model.currentStepID ?? "-") \(item?.config.kind ?? "-") \(item?.title ?? "-")")
    }

    /// The fraction of the run a point names.
    static func resolve(_ point: SnapshotPoint, model: InstallerModel) throws -> Double {
        switch point {
        case .fraction(let fraction):
            return fraction.isFinite ? min(1, max(0, fraction)) : 0
        case .kind(let kind):
            let timeline = Timeline(model)
            let candidates = timeline.items.enumerated().filter { $0.element.config.kind == kind }
            guard let first = candidates.first else {
                throw SnapshotError(description: "--snapshot-at-kind: no item of kind '\(kind)' runs with this config")
            }
            let chosen = candidates.first { !SnapshotOutput.endsAlreadyDone($0.element, index: $0.offset) } ?? first
            // A hair past its start, so rounding cannot land it at the end of the item before.
            return timeline.fraction(atItem: chosen.offset, progress: 0.01)
        }
    }

    /// The clock `fraction` of the way through the run.
    static func clock(at fraction: Double) -> Date {
        SnapshotScript.fixedRunStart.addingTimeInterval((fraction * runDuration).rounded())
    }

    /// How long the run had taken when it was half way through item `position` (the stopped screen's duration).
    static func elapsed(atItem position: Int, model: InstallerModel) -> TimeInterval {
        let timeline = Timeline(model)
        guard !timeline.items.isEmpty else { return 0 }
        return (timeline.fraction(atItem: min(position, timeline.items.count - 1), progress: 0.5) * runDuration).rounded()
    }

    /// The running screen `fraction` of the way through a run: 0 is the first item starting, 1 is every
    /// item finished, the moment before the finished screen.
    static func play(_ fraction: Double, on model: InstallerModel) {
        let fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        // The run starts at SnapshotScript.fixedRunStart; the clock then shows its share of runDuration.
        model.now = { SnapshotScript.fixedRunStart }
        defer { model.now = { clock(at: fraction) } }

        let timeline = Timeline(model)
        guard !timeline.steps.isEmpty else { return }
        model.apply(.runStarted(totalItems: model.enabledItemCount))

        var clock = fraction * timeline.total
        var position = 0
        for (stepIndex, step) in timeline.steps.enumerated() {
            let items = timeline.itemsByStep[stepIndex]
            let weight = timeline.weights[stepIndex]
            model.apply(.stepStatus(stepID: step.id, status: .running))
            let reached = fraction >= 1 ? Double(items.count) : max(0, clock) / weight * Double(items.count)
            clock -= weight
            let finished = min(items.count, Int(reached))
            for item in items.prefix(finished) {
                SnapshotScript.finish(item, index: position, failing: false, in: step, model: model)
                position += 1
            }
            guard finished == items.count else {
                startItem(items[finished], position: position, progress: reached - Double(finished), model: model)
                showStepLine(stepIndex: stepIndex, model: model)
                return
            }
            model.apply(.stepStatus(stepID: step.id, status: .done))
        }
        // Every item is through. The engine sends `.runFinished` next.
        showStepLine(stepIndex: timeline.steps.count - 1, model: model)
    }

    /// The run's time, in item-sized units: each step takes its own items plus an even share of the same size again.
    @MainActor private struct Timeline {
        let steps: [PlannedStep]
        let itemsByStep: [[PlannedItem]]
        let weights: [Double]
        var items: [PlannedItem] { itemsByStep.flatMap { $0 } }
        var total: Double { weights.reduce(0, +) }

        init(_ model: InstallerModel) {
            steps = SnapshotScript.enabledSteps(model)
            itemsByStep = steps.map { SnapshotScript.enabledItems(model, in: $0) }
            let count = itemsByStep.reduce(0) { $0 + $1.count }
            let evenShare = steps.isEmpty ? 0 : Double(count) / Double(steps.count)
            weights = itemsByStep.map { Double($0.count) + evenShare }
        }

        /// The fraction of the run at which item `position` is `progress` (0 to 1) of the way through.
        func fraction(atItem position: Int, progress: Double) -> Double {
            var before = 0.0, first = 0
            for (stepIndex, items) in itemsByStep.enumerated() {
                if position < first + items.count {
                    let within = (Double(position - first) + progress) / Double(items.count) * weights[stepIndex]
                    return (before + within) / total
                }
                before += weights[stepIndex]
                first += items.count
            }
            return 1
        }
    }

    /// The item the run is on. `progress` (0 to 1) is how far it has gotten.
    private static func startItem(_ item: PlannedItem, position: Int, progress: Double, model: InstallerModel) {
        model.apply(.itemStatus(itemID: item.id, status: .checking))
        // An item the run finds already done gets no further than its check.
        guard !SnapshotOutput.endsAlreadyDone(item, index: position) else { return }
        model.apply(.itemStatus(itemID: item.id, status: .running))
        model.apply(SnapshotOutput.inProgress(item, progress: progress, model: model))
    }

    /// Puts the running step's first line of its own in the speech bubble (a general working line when it has
    /// none), so the bubble holds still while the step is on screen. The lines are those of whoever speaks while
    /// the step works, its mascot or the narrator, as in `InstallerModel.saying`. The model picks a line by a seed
    /// that only moves forward, so this moves the seed on to that line.
    private static func showStepLine(stepIndex: Int, model: InstallerModel) {
        let stepID = model.currentStepID
        let mascot = model.currentStep?.config.mascot
        let lines = model.fun.lines(for: .working, stepID: stepID, mascot: mascot)
        let hasOwnLines = stepID.map { !model.fun.stepLines($0, mascot: mascot).isEmpty } ?? false
        let target = hasOwnLines ? 0 : stepIndex % lines.count
        repeat { model.advanceQuip() } while abs(model.quipSeed) % lines.count != target
    }
}

extension LaunchOptions {
    /// The value of `--snapshot-progress`: a number from 0 to 1.
    static func parseProgress(_ text: String) throws -> Double {
        guard let value = Double(text), value.isFinite, (0...1).contains(value) else {
            throw LaunchOptionsError.invalidValue(flag: "--snapshot-progress", value: text, expected: "a number from 0 to 1, e.g. 0.25")
        }
        return value
    }
}
