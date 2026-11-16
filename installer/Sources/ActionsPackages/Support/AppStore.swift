import Foundation
import ShawnCore

/// Mac App Store installs through `mas`.
///
/// mas cannot sign in or tell whether anyone is signed in (those commands were removed in mas 5),
/// so the person is asked once per run, before the first App Store install.
enum AppStore {
    static let signedInOption = "signed-in"
    static let skipOption = "skip"
    /// Where the run's `SignIn` decision is kept in `SharedState`.
    static let signInKey = "pkg.appstore.sign-in"

    /// What the sign-in question settled for this run.
    enum SignIn: Sendable, Equatable {
        case confirmed
        /// The person chose to skip App Store apps.
        case skipped
        /// Nobody answered in time (an unattended run), so App Store apps are skipped as well.
        case unanswered

        /// Why an App Store item was skipped (for `.skipped` and `.unanswered`).
        var skipReason: String {
            self == .unanswered
                ? "nobody answered the App Store question, so App Store apps are skipped for this run"
                : "App Store apps are skipped for this run"
        }

        /// The checklist detail for an app that was skipped (for `.skipped` and `.unanswered`).
        var followUpDetail: String {
            self == .unanswered
                ? "Nobody answered the App Store sign-in question, so App Store apps were skipped in this run. "
                    + "Sign in to the App Store, then install it there or run the installer again."
                : "App Store apps were skipped in this run."
        }
    }

    /// The app's page in App Store.app (an https link would open the browser instead).
    static func pageURL(id: String) -> URL {
        URL(string: "macappstore://apps.apple.com/app/id\(id)")!
    }

    static func signInQuestion(url: URL, timeout: TimeInterval) -> Question {
        Question(
            title: "Sign in to the App Store",
            message: "App Store apps are installed with mas, which only works while you are signed in to the App Store. "
                + "Open the App Store, sign in with your Apple Account, then come back and choose \"I'm signed in\". "
                + "Nothing can check this for you, and macOS may still ask for your password or Touch ID per app. "
                + "If nobody answers within \(Common.duration(timeout)), App Store apps are skipped for this run and left on your checklist.",
            options: [
                Question.Option(id: signedInOption, label: "I'm signed in", isDefault: true),
                Question.Option(id: skipOption, label: "Skip App Store apps"),
            ],
            url: url
        )
    }

    /// Asks the sign-in question the first time it matters in a run; later calls reuse the decision.
    /// When nobody answers within `timeout` seconds the decision is `.unanswered`, so an unattended run carries
    /// on without App Store apps instead of waiting at step 1. Throws `CancellationError` if the run is stopped
    /// while the question is up (and then decides nothing).
    static func confirmSignIn(_ context: ActionContext, url: URL, timeout: TimeInterval) async throws -> SignIn {
        if let decided = await context.shared.value(signInKey, as: SignIn.self) { return decided }
        let decision: SignIn
        if let answer = try await ask(signInQuestion(url: url, timeout: timeout), timeout: timeout, context) {
            decision = answer == skipOption ? .skipped : .confirmed
        } else {
            decision = .unanswered
        }
        await context.shared.set(signInKey, decision)
        switch decision {
        case .confirmed:
            break
        case .skipped:
            context.info("Skipping App Store apps for this run.")
        case .unanswered:
            context.warn("Nobody answered the App Store question within \(Common.duration(timeout)); skipping App Store apps for this run. They are on the checklist at the end.")
        }
        return decision
    }

    /// True once App Store apps are skipped in this run (by choice or because nobody answered).
    static func wasSkipped(_ context: ActionContext) async -> Bool {
        guard let decided = await context.shared.value(signInKey, as: SignIn.self) else { return false }
        return decided != .confirmed
    }

    /// Asks `question`, but stops waiting after `timeout` seconds and returns nil.
    ///
    /// The question is then withdrawn by cancelling the task that asked it (the app takes its sheet off screen),
    /// and whatever answer still comes is ignored. Nothing waits for that task, so even an interaction that
    /// cannot be interrupted (a blocking terminal read) never holds up the run. The answer a withdrawn sheet
    /// reports (its default option) is never taken for a real one.
    static func ask(_ question: Question, timeout: TimeInterval, _ context: ActionContext) async throws -> String? {
        try Task.checkCancellation()
        let interaction = context.interaction
        let first = FirstOutcome()
        let asking = Task { await interaction.ask(question) }
        Task { first.deliver(.answered(await asking.value)) }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            first.deliver(.timedOut)
        }
        let outcome = await withTaskCancellationHandler {
            await first.value()
        } onCancel: {
            first.deliver(.stopped)
        }
        timer.cancel()
        asking.cancel()
        switch outcome {
        case .answered(let id): return id
        case .timedOut: return nil
        case .stopped: throw CancellationError()
        }
    }

    static func masPath(_ context: ActionContext) -> String? {
        context.environment.resolveExecutable("mas")
    }

    /// Where mas will be once Homebrew has installed it (for dry-run narration).
    static func expectedMasPath(_ context: ActionContext) -> String {
        masPath(context) ?? context.environment.brewPrefix.appendingPathComponent("bin/mas").path
    }

    /// Makes sure mas is available, installing it with Homebrew if needed. Nil when there is no way to get it.
    static func ensureMas(_ context: ActionContext) async throws -> String? {
        if let path = masPath(context) { return path }
        guard Brew.isInstalled(context) else { return nil }
        context.info("App Store installs need mas; installing it with Homebrew first.")
        try await Brew.run(["install", "--formula", "mas"], context)
        await Brew.invalidateInstalledState(context)
        return masPath(context)
    }

    /// `sudo mas install <id>` (mas 7 needs root since macOS 26.1), falling back to `sudo mas get <id>`
    /// for free apps the account has never downloaded.
    ///
    /// Each command is stopped after `timeout` seconds: mas can hang (mas-cli #1222), and it waits silently while
    /// the App Store wants a password or Touch ID that nobody gives. A timed-out install throws at once rather
    /// than trying `get`, which would wait just as long.
    static func install(id: String, name: String, mas: String, timeout: TimeInterval, _ context: ActionContext) async throws {
        let install = try await context.run(Command(mas, ["install", id]).asRoot().timeout(timeout))
        if install.succeeded { return }
        context.warn("mas install \(id) did not work (\(install.tail(2))); trying mas get.")
        let get = try await context.run(Command(mas, ["get", id]).asRoot().timeout(timeout))
        if get.succeeded { return }
        throw ActionError("mas could not install \(name): \(get.tail())",
                          hint: "check that you are signed in to the App Store and that \(name) is available there, then try again, or install it from the App Store yourself")
    }

    /// Why an App Store install did not work, for the log and the checklist.
    static func explain(_ error: Error) -> String {
        if let error = error as? CommandError, error.isTimeout {
            return "\(error.description), so it was stopped (the App Store may have been waiting for your Apple Account password or Touch ID, or the download stalled)"
        }
        return Common.describe(error)
    }
}

/// Hands the first of several racing outcomes to the one caller waiting for it; later ones are dropped.
private final class FirstOutcome: @unchecked Sendable {
    enum Outcome: Sendable {
        case answered(String)
        case timedOut
        case stopped
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiting: CheckedContinuation<Outcome, Never>?

    func deliver(_ candidate: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = candidate
            let continuation = waiting
            waiting = nil
            return continuation
        }
        continuation?.resume(returning: candidate)
    }

    func value() async -> Outcome {
        await withCheckedContinuation { continuation in
            let ready: Outcome? = lock.withLock {
                if let outcome { return outcome }
                waiting = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
