import Foundation

/// One line in the installer's log.
public struct LogLine: Equatable, Sendable {
    public enum Style: String, Sendable {
        /// A command about to run (`$ brew install eza`).
        case command
        case stdout
        case stderr
        /// Narration from the installer itself.
        case info
        case success
        case warning
        case error
    }

    public let text: String
    public let style: Style
    /// The item that produced it, if any.
    public let itemID: String?
    /// True for progress-bar frames: the next line from the same item should overwrite this one.
    public let isProgress: Bool

    public init(_ text: String, style: Style = .info, itemID: String? = nil, isProgress: Bool = false) {
        self.text = text
        self.style = style
        self.itemID = itemID
        self.isProgress = isProgress
    }
}

/// Where an item is in its life.
public enum ItemStatus: Equatable, Sendable {
    case pending
    /// Switched off by the user or by default.
    case disabled
    case checking
    case running
    /// Finished and changed something.
    case done(String?)
    /// Nothing to do: already in the desired state.
    case alreadyDone(String?)
    /// Not applicable here (prerequisite deliberately absent).
    case skipped(String)
    /// Did what it could; a person has to finish it.
    case needsAttention(String)
    case failed(String)
    /// The run was stopped while this item was in progress. Not a failure.
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .pending, .checking, .running: return false
        default: return true
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

public enum StepStatus: Equatable, Sendable {
    case pending
    case disabled
    case running
    case done
    /// Finished, but at least one item failed.
    case finishedWithFailures(Int)
    /// The run was stopped before every item of the step had its turn.
    case stopped
}

/// Something only a person can do, collected for the final checklist.
public struct FollowUp: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String?
    /// Opens the right place (settings pane, app, web page).
    public let url: URL?
    /// The step that raised it.
    public let stepID: String?

    public init(id: String, title: String, detail: String? = nil, url: URL? = nil, stepID: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.url = url
        self.stepID = stepID
    }
}

public struct InstallSummary: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let itemID: String
        public let title: String
        public let message: String

        public init(itemID: String, title: String, message: String) {
            self.itemID = itemID
            self.title = title
            self.message = message
        }
    }

    public var done = 0
    public var alreadyDone = 0
    public var skipped = 0
    public var needsAttention = 0
    public var failures: [Failure] = []
    public var followUps: [FollowUp] = []
    public var duration: TimeInterval = 0
    public var wasCancelled = false
    public var wasDryRun = false
    public var logFile: URL?

    public init() {}

    public var succeeded: Bool { failures.isEmpty && !wasCancelled }
    public var total: Int { done + alreadyDone + skipped + needsAttention + failures.count }
}

/// Everything the engine reports while it runs. Delivered in order, from a background context.
public enum InstallEvent: Sendable {
    case runStarted(totalItems: Int)
    case stepStatus(stepID: String, status: StepStatus)
    case itemStatus(itemID: String, status: ItemStatus)
    case log(LogLine)
    /// Set (or clear, with nil) the callout for an item that is waiting on the human.
    case attention(itemID: String, attention: Attention?)
    case followUp(FollowUp)
    case runFinished(InstallSummary)
}
