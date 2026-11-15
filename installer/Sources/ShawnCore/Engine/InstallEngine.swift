import Foundation

/// Runs an `InstallPlan`: for each enabled item, check → (maybe) run → report.
///
/// One failing item never stops the run; it is recorded and the engine moves
/// on. Because every action checks before it acts, running the same plan again
/// simply picks up whatever is still missing.
public final class InstallEngine: @unchecked Sendable {
    public let plan: InstallPlan
    public let environment: SystemEnvironment
    public let options: RunOptions
    public let interaction: any UserInteraction
    public let sudo: SudoSession
    public let shared = SharedState()

    public init(plan: InstallPlan, environment: SystemEnvironment = .live(), options: RunOptions = RunOptions(),
                interaction: any UserInteraction = NonInteractive()) {
        self.plan = plan
        self.environment = environment
        self.options = options
        self.interaction = interaction
        self.sudo = SudoSession(environment: environment, interaction: interaction, dryRun: options.dryRun)
    }

    private func makeContext(step: PlannedStep, item: PlannedItem, emit: @escaping @Sendable (InstallEvent) -> Void) -> ActionContext {
        ActionContext(config: plan.config, environment: environment, options: options, step: step.config, item: item.config,
                      sudo: sudo, interaction: interaction, shared: shared, emit: emit)
    }

    // MARK: Scan

    /// Read-only pass over the enabled items: which are already done? Changes nothing.
    public func scan(selection: Selection, onResult: @escaping @Sendable (String, CheckResult) -> Void) async {
        for step in plan.steps where selection.isEnabled(step: step) {
            for item in step.items where selection.isEnabled(item: item) {
                if Task.isCancelled { return }
                let context = makeContext(step: step, item: item, emit: { _ in })
                let result = options.assumeFresh ? CheckResult.needed(nil) : await item.action.check(context)
                onResult(item.id, result)
            }
        }
    }

    // MARK: Run

    /// Runs the enabled items in order, reporting through `onEvent` (called from background contexts, in order per source).
    @discardableResult
    public func run(selection: Selection, onEvent: @escaping @Sendable (InstallEvent) -> Void) async -> InstallSummary {
        let started = Date()
        // A dry run promises to change nothing on this Mac, and that includes leaving a log file behind.
        let logFile = LogFile(directory: environment.logsDirectory, runID: environment.runID, enabled: !options.dryRun)
        let emit: @Sendable (InstallEvent) -> Void = { event in
            logFile.record(event)
            onEvent(event)
        }

        var summary = InstallSummary()
        summary.wasDryRun = options.dryRun
        summary.logFile = logFile.url
        let followUps = FollowUpCollector()
        let emitCollecting: @Sendable (InstallEvent) -> Void = { event in
            if case .followUp(let followUp) = event { followUps.add(followUp) }
            emit(event)
        }

        let enabledItems = selection.enabledItems(in: plan)
        emit(.runStarted(totalItems: enabledItems.count))
        if options.dryRun {
            emit(.log(LogLine("Dry run: nothing on this Mac will be changed.", style: .info)))
        }

        // Ask for the password up front rather than twenty minutes in.
        if !options.dryRun, enabledItems.contains(where: { $0.action.sudo == .always }) {
            do {
                try await sudo.ensureReady(reason: "Some steps need administrator rights (Homebrew, system installers).")
            } catch {
                // A prompt that ended because the run was stopped is not a missing password: the run is about to end.
                if !Task.isCancelled {
                    emit(.log(LogLine("Continuing without administrator rights: \(Self.describe(error)). Steps that need them will fail.", style: .warning)))
                }
            }
        }

        runLoop: for step in plan.steps {
            guard selection.isEnabled(step: step) else {
                emit(.stepStatus(stepID: step.id, status: .disabled))
                for item in step.items { emit(.itemStatus(itemID: item.id, status: .disabled)) }
                continue
            }
            emit(.stepStatus(stepID: step.id, status: .running))
            var failuresInStep = 0

            for (position, item) in step.items.enumerated() {
                if Task.isCancelled {
                    summary.wasCancelled = true
                    // Only call the step finished if nothing in it was still waiting for its turn.
                    let stillWaiting = step.items[position...].contains { selection.isEnabled(item: $0) }
                    if stillWaiting {
                        emit(.stepStatus(stepID: step.id, status: .stopped))
                    } else {
                        emit(.stepStatus(stepID: step.id, status: failuresInStep == 0 ? .done : .finishedWithFailures(failuresInStep)))
                    }
                    break runLoop
                }
                guard selection.isEnabled(item: item) else {
                    emit(.itemStatus(itemID: item.id, status: .disabled))
                    continue
                }

                let context = makeContext(step: step, item: item, emit: emitCollecting)
                emit(.itemStatus(itemID: item.id, status: .checking))
                let check = options.assumeFresh ? CheckResult.needed(nil) : await item.action.check(context)
                if case .satisfied(let reason) = check {
                    summary.alreadyDone += 1
                    emit(.itemStatus(itemID: item.id, status: .alreadyDone(reason)))
                    continue
                }

                emit(.itemStatus(itemID: item.id, status: .running))
                do {
                    if !options.dryRun && item.action.sudo != .never {
                        do {
                            try await sudo.ensureReady(reason: item.title)
                        } catch {
                            if item.action.sudo == .always { throw error }
                        }
                    }
                    try Task.checkCancellation()
                    let outcome = try await item.action.run(context)
                    switch outcome {
                    case .done(let message):
                        summary.done += 1
                        emit(.itemStatus(itemID: item.id, status: .done(message)))
                    case .skipped(let reason):
                        summary.skipped += 1
                        emit(.itemStatus(itemID: item.id, status: .skipped(reason)))
                    case .needsAttention(let message):
                        summary.needsAttention += 1
                        emit(.itemStatus(itemID: item.id, status: .needsAttention(message)))
                    }
                } catch where error is CancellationError || Task.isCancelled {
                    // Stopping is not a failure, including when it surfaces as some other error
                    // (a prompt dismissed by the stop, a command killed mid-flight).
                    summary.wasCancelled = true
                    emit(.attention(itemID: item.id, attention: nil))
                    emit(.itemStatus(itemID: item.id, status: .cancelled))
                    emit(.stepStatus(stepID: step.id, status: .stopped))
                    break runLoop
                } catch {
                    let message = Self.describe(error)
                    failuresInStep += 1
                    summary.failures.append(.init(itemID: item.id, title: item.title, message: message))
                    emit(.log(LogLine("✗ \(item.title): \(message)", style: .error, itemID: item.id)))
                    emit(.itemStatus(itemID: item.id, status: .failed(message)))
                }
                emit(.attention(itemID: item.id, attention: nil))
            }

            emit(.stepStatus(stepID: step.id, status: failuresInStep == 0 ? .done : .finishedWithFailures(failuresInStep)))
        }

        if summary.wasCancelled {
            await shared.cancelBackgroundWork()
        }
        sudo.invalidate()

        summary.followUps = followUps.all
        summary.duration = Date().timeIntervalSince(started)
        emit(.runFinished(summary))
        logFile.close()
        return summary
    }

    /// Runs on a background task and exposes the events as a stream. Cancelling the consumer cancels the run.
    public func events(selection: Selection) -> AsyncStream<InstallEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(selection: selection) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A message fit for the item list, whatever was thrown.
    public static func describe(_ error: Error) -> String {
        switch error {
        case let error as ActionError: return error.description
        case let error as CommandError: return error.description
        case let error as SudoError: return error.description
        case let error as FileOpsError: return error.description
        case let error as ConfigError: return error.description
        case let error as ProcessRunnerError: return error.description
        case is CancellationError: return "cancelled"
        default:
            let described = String(describing: error)
            let localized = error.localizedDescription
            return localized.contains("The operation couldn’t be completed") ? described : localized
        }
    }
}

private final class FollowUpCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FollowUp] = []

    func add(_ followUp: FollowUp) {
        lock.withLock {
            if !items.contains(where: { $0.id == followUp.id }) { items.append(followUp) }
        }
    }

    var all: [FollowUp] { lock.withLock { items } }
}

/// Plain-text transcript of a run, for when something goes wrong: `~/Library/Logs/ShawnsDotfiles/install-<run>.log`.
final class LogFile: @unchecked Sendable {
    let url: URL?
    private let lock = NSLock()
    private var handle: FileHandle?
    private let formatter: DateFormatter

    init(directory: URL, runID: String, enabled: Bool) {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        guard enabled else {
            url = nil
            return
        }
        let fileURL = directory.appendingPathComponent("install-\(runID).log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            self.handle = handle
            url = fileURL
        } catch {
            url = nil
        }
    }

    func record(_ event: InstallEvent) {
        let text: String
        switch event {
        case .runStarted(let total):
            text = "=== run started: \(total) items ==="
        case .stepStatus(let stepID, let status):
            text = "--- step \(stepID): \(status) ---"
        case .itemStatus(let itemID, let status):
            if case .checking = status { return }
            text = "[\(itemID)] \(status)"
        case .log(let line):
            if line.isProgress { return }
            text = "[\(line.itemID ?? "-")] \(line.style.rawValue): \(line.text)"
        case .attention(let itemID, let attention):
            guard let attention else { return }
            text = "[\(itemID)] waiting on user (\(attention.title)): \(attention.message)"
        case .followUp(let followUp):
            text = "follow-up: \(followUp.title)"
        case .runFinished(let summary):
            text = "=== run finished: \(summary.done) done, \(summary.alreadyDone) already done, \(summary.skipped) skipped, \(summary.needsAttention) need attention, \(summary.failures.count) failed ==="
        }
        lock.withLock {
            guard let handle else { return }
            let stamp = formatter.string(from: Date())
            do {
                try handle.write(contentsOf: Data("\(stamp) \(text)\n".utf8))
            } catch {
                // A full disk must not take the run down with it: stop logging to the file and carry on.
                try? handle.close()
                self.handle = nil
            }
        }
    }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}
