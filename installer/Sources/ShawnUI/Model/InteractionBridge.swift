import Foundation
import ShawnCore

/// Hands one answer to a suspended engine call, exactly once, whoever gets there first:
/// the person (a button on the sheet), STOP, or the engine task being canceled.
final class PromptGate<Answer: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Answer, Never>?
    private var answer: Answer?
    private var resolved = false
    private var onResolve: (@Sendable () -> Void)?

    var isResolved: Bool { lock.withLock { resolved } }

    /// Called once, after the answer has been delivered (used to take the prompt off screen).
    func whenResolved(_ action: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if resolved { return true }
            onResolve = action
            return false
        }
        if runNow { action() }
    }

    func install(_ continuation: CheckedContinuation<Answer, Never>) {
        let early: Answer? = lock.withLock {
            if resolved { return answer }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    /// Delivers `value` unless an answer was already given. Returns whether this call won.
    @discardableResult
    func resolve(_ value: Answer) -> Bool {
        let (waiting, callback, won): (CheckedContinuation<Answer, Never>?, (@Sendable () -> Void)?, Bool) = lock.withLock {
            guard !resolved else { return (nil, nil, false) }
            resolved = true
            answer = value
            let waiting = continuation
            continuation = nil
            let callback = onResolve
            onResolve = nil
            return (waiting, callback, true)
        }
        waiting?.resume(returning: value)
        callback?()
        return won
    }
}

/// What the password sheet shows.
struct PasswordRequest: Equatable, Sendable {
    let reason: String
    let attempt: Int
    let lastError: String?
    let maxAttempts: Int
}

/// A prompt waiting on screen (or in the queue behind another one).
struct PendingPrompt: Identifiable {
    enum Kind {
        case password(PasswordRequest, PromptGate<String?>)
        case question(Question, PromptGate<String>)
        /// One line of text for a question from `ask:` in `installer.yaml`. Nil means no answer.
        case text(TextRequest, PromptGate<String?>)
    }

    let id: Int
    let kind: Kind

    var isPassword: Bool {
        if case .password = kind { return true }
        return false
    }

    /// The request when this is the text sheet.
    var textRequest: TextRequest? {
        if case .text(let request, _) = kind { return request }
        return nil
    }

    /// Gives the engine its "nobody answered" value: no password, the question's default option, or no text.
    /// No text saves nothing. A question asked again keeps its saved answer, and any other stays unanswered.
    func resolveWithDefault() {
        switch kind {
        case .password(_, let gate): gate.resolve(nil)
        case .question(let question, let gate): gate.resolve(question.defaultOptionID)
        case .text(_, let gate): gate.resolve(nil)
        }
    }
}

/// The engine's `UserInteraction`: suspends the calling item until the person answers a sheet in the window.
///
/// Every prompt resolves exactly once: with the answer, with nil or the default when the person cancels or
/// presses STOP, or when the engine task is canceled. So the engine can never hang on a dismissed sheet.
final class InteractionBridge: UserInteraction, @unchecked Sendable {
    /// Receives prompts on the main actor. Set once, right after the model is created.
    @MainActor weak var presenter: InstallerModel?

    init() {}

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
        let request = PasswordRequest(reason: reason, attempt: attempt, lastError: lastError, maxAttempts: SudoSession.maxAttempts)
        let gate = PromptGate<String?>()
        return await suspend(on: gate, cancelValue: nil) { presenter in
            presenter.enqueue(.password(request, gate))
        }
    }

    func ask(_ question: Question) async -> String {
        let gate = PromptGate<String>()
        return await suspend(on: gate, cancelValue: question.defaultOptionID) { presenter in
            presenter.enqueue(.question(question, gate))
        }
    }

    /// The text sheet. Nil when the person presses SKIP, when STOP or quitting takes the sheet down, when the
    /// engine task is canceled, and when no run is on screen to show it. The engine saves an accepted answer;
    /// the app never does.
    func askText(_ request: TextRequest) async -> String? {
        let gate = PromptGate<String?>()
        return await suspend(on: gate, cancelValue: nil) { presenter in
            presenter.enqueue(.text(request, gate))
        }
    }

    private func suspend<Answer: Sendable>(on gate: PromptGate<Answer>, cancelValue: Answer,
                                           present: @escaping @MainActor (InstallerModel) -> Void) async -> Answer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                Task { @MainActor [weak self] in
                    guard !gate.isResolved else { return }
                    guard let presenter = self?.presenter, presenter.acceptsPrompts else {
                        gate.resolve(cancelValue)
                        return
                    }
                    present(presenter)
                }
            }
        } onCancel: {
            gate.resolve(cancelValue)
        }
    }
}
