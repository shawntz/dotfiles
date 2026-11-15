import Foundation
import ShawnCore

/// Carries engine events from the background run to the main actor in order, coalescing bursts
/// (a chatty `brew install` prints hundreds of lines a second) into one main-actor hop per batch.
final class EventPump: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [InstallEvent] = []
    private var drainScheduled = false
    private let deliver: @MainActor ([InstallEvent]) -> Void

    init(deliver: @escaping @MainActor ([InstallEvent]) -> Void) {
        self.deliver = deliver
    }

    func push(_ event: InstallEvent) {
        let schedule: Bool = lock.withLock {
            pending.append(event)
            if drainScheduled { return false }
            drainScheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor in
            self.drain()
        }
    }

    /// Delivers everything queued so far. Each drain takes the whole queue, so order is kept
    /// even if two drains were scheduled.
    @MainActor
    func drain() {
        let batch: [InstallEvent] = lock.withLock {
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            drainScheduled = false
            return batch
        }
        if !batch.isEmpty { deliver(batch) }
    }
}
