import Foundation

/// A blocking question for the person at the keyboard.
public struct Question: Sendable {
    public struct Option: Sendable, Identifiable {
        public let id: String
        public let label: String
        public let isDefault: Bool

        public init(id: String, label: String, isDefault: Bool = false) {
            self.id = id
            self.label = label
            self.isDefault = isDefault
        }
    }

    public let title: String
    public let message: String
    public let options: [Option]
    /// Something worth opening while the question is on screen (App Store page, settings pane).
    public let url: URL?

    public init(title: String, message: String, options: [Option], url: URL? = nil) {
        self.title = title
        self.message = message
        self.options = options
        self.url = url
    }

    /// The id returned when nobody can answer (headless runs).
    public var defaultOptionID: String {
        (options.first(where: \.isDefault) ?? options.first)?.id ?? ""
    }
}

/// A non-blocking callout shown while an item is running and waiting on the human
/// ("enter this code on github.com", "click Get in the App Store").
public struct Attention: Equatable, Sendable {
    public let title: String
    public let message: String
    /// A short code to display prominently (and copy to the clipboard).
    public let code: String?
    public let url: URL?

    public init(title: String, message: String, code: String? = nil, url: URL? = nil) {
        self.title = title
        self.message = message
        self.code = code
        self.url = url
    }
}

/// A request for one line of text: the answer to a question from `ask:` in `installer.yaml`.
public struct TextRequest: Equatable, Sendable {
    /// The variable being asked for (`email`). The same on every attempt.
    public let id: String
    /// One line to show the person.
    public let prompt: String
    /// What an empty reply means: the saved answer, or the config's default. Nil when there is none.
    public let defaultValue: String?
    /// How the answer must look. The engine checks the reply; a front end may check it too.
    public let format: AnswerFormat
    /// 1 for the first ask. 2 and 3 follow a reply that did not pass `format`.
    public let attempt: Int
    /// Why the previous reply was not accepted, as a sentence. Nil on the first attempt.
    public let lastError: String?
    /// True when `defaultValue` is the answer saved on this Mac, asked again (`RunOptions.askAgain`). Declining then
    /// keeps that answer, and the items that need it run with it. False when declining leaves the question unanswered.
    public let defaultIsSaved: Bool

    public init(id: String, prompt: String, defaultValue: String? = nil, format: AnswerFormat = .text, attempt: Int = 1, lastError: String? = nil,
                defaultIsSaved: Bool = false) {
        self.id = id
        self.prompt = prompt
        self.defaultValue = defaultValue
        self.format = format
        self.attempt = attempt
        self.lastError = lastError
        self.defaultIsSaved = defaultIsSaved
    }
}

/// How the engine talks to whoever is running it: the GUI, the terminal, or nobody.
public protocol UserInteraction: Sendable {
    /// Asks for the administrator password. `attempt` starts at 1; `lastError` says why the previous try failed.
    /// Return nil when the user declines.
    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String?

    /// Asks a question and returns the chosen option's id.
    func ask(_ question: Question) async -> String

    /// Asks for one line of text. Returns nil when the person declines or nobody can be asked.
    /// An empty reply takes `request.defaultValue`. The default implementation answers with the default without asking.
    func askText(_ request: TextRequest) async -> String?
}

public extension UserInteraction {
    func askText(_ request: TextRequest) async -> String? {
        request.defaultValue
    }
}

/// For headless runs and tests: never prompts, optionally supplies a known password. Questions take their
/// default answer, text included (nil when a text question has no default).
public struct NonInteractive: UserInteraction {
    public let password: String?

    public init(password: String? = nil) {
        self.password = password
    }

    public func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
        attempt == 1 ? password : nil
    }

    public func ask(_ question: Question) async -> String {
        question.defaultOptionID
    }
}
