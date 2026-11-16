import Foundation

/// Runs `operation` but returns no later than `seconds` from now, throwing `RemoteConfigError.timedOut`.
///
/// A task group would wait for a child that ignores cancellation (a request stuck in a transport), so the
/// operation runs in its own task and races a timer; whichever finishes first resumes the caller and
/// cancels the other. Abandoned work keeps unwinding in the background after its cancellation.
func withDeadline<T: Sendable>(seconds: TimeInterval,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
            race.track(Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            })
            race.track(Task {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds(seconds))
                } catch {
                    // Cancelled because the operation already finished.
                    return
                }
                race.finish(.failure(RemoteConfigError.timedOut(seconds: seconds)))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// `seconds` as a sleep duration: negative or NaN is "now", anything beyond a year (or infinite) is a year,
/// which keeps the conversion to `UInt64` from trapping.
func sleepNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    let year: TimeInterval = 365 * 86_400
    guard seconds > 0 else { return 0 }
    return UInt64(min(seconds, year) * 1_000_000_000)
}

/// Resumes one continuation exactly once, with whichever result arrives first.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    /// A result that arrived before `begin` (the caller was cancelled before it started waiting).
    private var early: Result<T, Error>?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    func begin(_ continuation: CheckedContinuation<T, Error>) {
        let pending: Result<T, Error>? = lock.withLock {
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func track(_ task: Task<Void, Never>) {
        let alreadyFinished = lock.withLock {
            if !finished { tasks.append(task) }
            return finished
        }
        if alreadyFinished { task.cancel() }
    }

    func finish(_ result: Result<T, Error>) {
        let (waiting, losers): (CheckedContinuation<T, Error>?, [Task<Void, Never>]) = lock.withLock {
            guard !finished else { return (nil, []) }
            finished = true
            let waiting = continuation
            continuation = nil
            if waiting == nil { early = result }
            let losers = tasks
            tasks = []
            return (waiting, losers)
        }
        waiting?.resume(with: result)
        for task in losers { task.cancel() }
    }
}
