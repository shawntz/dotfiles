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

/// How the engine talks to whoever is running it: the GUI, the terminal, or nobody.
public protocol UserInteraction: Sendable {
    /// Asks for the administrator password. `attempt` starts at 1; `lastError` says why the previous try failed.
    /// Return nil when the user declines.
    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String?

    /// Asks a question and returns the chosen option's id.
    func ask(_ question: Question) async -> String
}

/// For headless runs and tests: never prompts, optionally supplies a known password.
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
