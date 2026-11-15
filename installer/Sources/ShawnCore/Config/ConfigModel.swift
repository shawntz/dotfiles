import Foundation

// MARK: - Source locations & issues

/// Where something in the config came from (path relative to the config root).
public struct SourceRef: Equatable, Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int?

    public init(file: String, line: Int? = nil) {
        self.file = file
        self.line = line
    }

    public var description: String {
        if let line { return "\(file):\(line)" }
        return file
    }
}

/// A problem found while loading or validating the config.
public struct ConfigIssue: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    public let source: SourceRef?
    public let message: String

    public init(_ severity: Severity, _ message: String, at source: SourceRef? = nil) {
        self.severity = severity
        self.source = source
        self.message = message
    }

    public static func error(_ message: String, at source: SourceRef? = nil) -> ConfigIssue {
        ConfigIssue(.error, message, at: source)
    }

    public static func warning(_ message: String, at source: SourceRef? = nil) -> ConfigIssue {
        ConfigIssue(.warning, message, at: source)
    }

    public var description: String {
        let location = source.map { "\($0): " } ?? ""
        return "\(location)\(severity.rawValue): \(message)"
    }
}

/// Thrown when one or more blocking config issues were found.
public struct ConfigError: Error, Sendable, CustomStringConvertible {
    public let issues: [ConfigIssue]

    public init(_ issues: [ConfigIssue]) {
        self.issues = issues
    }

    public var description: String {
        issues.map(\.description).joined(separator: "\n")
    }
}

// MARK: - Top-level config

/// Where the installer's GitHub home is, used for remote config sync and self-update.
public struct RemoteConfigRef: Equatable, Sendable {
    /// `owner/name`, e.g. `shawntz/dotfiles`.
    public var repo: String
    public var branch: String
    /// Path of the config directory inside the repo, e.g. `installer/config`.
    public var path: String

    public init(repo: String, branch: String, path: String) {
        self.repo = repo
        self.branch = branch
        self.path = path
    }
}

/// Where the loaded config came from.
public enum ConfigSource: Equatable, Sendable, CustomStringConvertible {
    /// Shipped inside the app bundle.
    case bundled
    /// A directory on disk (repo checkout, `--config`, tests).
    case local(String)
    /// Downloaded from GitHub at a specific commit.
    case remote(repo: String, ref: String, commit: String)

    public var description: String {
        switch self {
        case .bundled: return "bundled"
        case .local(let path): return "local (\(path))"
        case .remote(let repo, let ref, let commit): return "\(repo)@\(ref) (\(commit.prefix(7)))"
        }
    }
}

/// Contents of `installer.yaml`.
public struct ConfigMeta: Equatable, Sendable {
    public var schema: Int
    public var name: String
    public var tagline: String?
    public var remote: RemoteConfigRef?
    /// User-defined template variables (`{{name}}`), in declaration order.
    public var vars: [String: String]
    /// Variables the installer asks the person for (`ask:`), in the order they are asked.
    public var ask: [VariableQuestion]

    public init(schema: Int, name: String, tagline: String? = nil, remote: RemoteConfigRef? = nil, vars: [String: String] = [:],
                ask: [VariableQuestion] = []) {
        self.schema = schema
        self.name = name
        self.tagline = tagline
        self.remote = remote
        self.vars = vars
        self.ask = ask
    }
}

/// How an answer to a question must look (`format:` of an `ask:` entry).
public enum AnswerFormat: String, CaseIterable, Equatable, Sendable {
    /// Any text that is not empty once trimmed.
    case text
    /// One address: something, an `@`, then something with a dot in it, and none of the characters that would make
    /// it a list, a pattern or a quoted name (`, ; * < > ( ) [ ] " ' \`). The answer goes into git's allowed-signers
    /// file, where a comma starts another signer and `*` matches every address.
    case email

    /// Why `answer` is not acceptable, or nil when it is. Every format wants one line of printable text. An arrow key
    /// at the terminal prompt types an escape code into the line, and that must not reach ~/.gitconfig.
    public func problem(with answer: String) -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "This needs an answer." }
        if trimmed.contains(where: \.isNewline) { return "Use one line." }
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "Use only printable characters, with no tabs or escape codes. At the terminal prompt, fix a typo with Backspace, not the arrow keys."
        }
        switch self {
        case .text:
            return nil
        case .email:
            let part = #"[^@\s,;*<>()\[\]"'\\]+"#
            let looksLikeAddress = trimmed.range(of: "^\(part)@\(part)\\.\(part)$", options: .regularExpression) != nil
            return looksLikeAddress ? nil : "That does not look like an email address, such as name@example.com."
        }
    }
}

/// One entry of `ask:` in `installer.yaml`: a variable the installer asks the person for, once per Mac.
/// The answer is kept in `~/.shawn/answers.json` and steps use it like any other `{{variable}}`.
public struct VariableQuestion: Equatable, Sendable {
    /// The variable's name (`var:`), as steps write it inside `{{ }}`.
    public var name: String
    /// One line shown to the person (`prompt:`).
    public var prompt: String
    /// A literal default (`default:`); it may use `{{vars}}`.
    public var defaultValue: String?
    /// A `/bin/sh` one-liner whose first line of output is the default (`default_command:`). It wins over `default:`
    /// when that line passes `format`.
    public var defaultCommand: String?
    public var format: AnswerFormat
    public var source: SourceRef?

    public init(name: String, prompt: String, defaultValue: String? = nil, defaultCommand: String? = nil,
                format: AnswerFormat = .text, source: SourceRef? = nil) {
        self.name = name
        self.prompt = prompt
        self.defaultValue = defaultValue
        self.defaultCommand = defaultCommand
        self.format = format
        self.source = source
    }

    /// The variable in words, for messages: `your full name` for `full_name`.
    public var spokenName: String {
        "your " + name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    /// What a dry run puts in place of an answer it does not have, so its narration still reads sensibly.
    public var dryRunPlaceholder: String {
        "(\(spokenName), asked on a real run)"
    }
}

/// One entry of a step's `items:` list, before its kind has been resolved.
public struct RawItem: Equatable, Sendable {
    public let map: YAMLMap
    public let source: SourceRef

    public init(map: YAMLMap, source: SourceRef) {
        self.map = map
        self.source = source
    }
}

/// One file under `steps/`: a titled group of items shown as one installer step.
public struct StepConfig: Equatable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String?
    /// Sprite id (from `fun/sprites.yaml`) shown while this step runs.
    public var mascot: String?
    /// Whether the step is switched on by default.
    public var enabledByDefault: Bool
    /// Step-specific quips shown in the speech bubble while it runs.
    public var quips: [String]
    public var rawItems: [RawItem]
    /// Path relative to the config root, e.g. `steps/03-packages.yaml`.
    public let file: String

    public init(id: String, title: String, subtitle: String? = nil, mascot: String? = nil, enabledByDefault: Bool = true,
                quips: [String] = [], rawItems: [RawItem] = [], file: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.mascot = mascot
        self.enabledByDefault = enabledByDefault
        self.quips = quips
        self.rawItems = rawItems
        self.file = file
    }
}

/// The whole config directory, loaded.
public struct InstallerConfig: Sendable {
    /// The config directory (contains `installer.yaml`, `steps/`, `files/`, ...).
    public let root: URL
    public var meta: ConfigMeta
    public var steps: [StepConfig]
    public var source: ConfigSource

    public init(root: URL, meta: ConfigMeta, steps: [StepConfig], source: ConfigSource) {
        self.root = root
        self.meta = meta
        self.steps = steps
        self.source = source
    }

    /// URL of a path relative to the config root.
    public func url(_ relativePath: String) -> URL {
        relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
    }

    /// Payload files referenced by `copy:` items live under `files/`.
    public var filesDirectory: URL { url("files") }

    /// Loads another YAML document from the config directory (e.g. `cli.yaml`, `fun/quotes.yaml`).
    /// Returns nil when the file does not exist or is empty.
    public func loadYAML(_ relativePath: String) throws -> YAMLValue? {
        let fileURL = url(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try YAML.parseFile(fileURL, displayName: relativePath)
    }

    public func step(_ id: String) -> StepConfig? {
        steps.first { $0.id == id }
    }

    /// The question that asks for `variable`, if any.
    public func question(_ variable: String) -> VariableQuestion? {
        meta.ask.first { $0.name == variable }
    }
}

// MARK: - Items

/// A step item whose kind has been resolved against the action registry.
public struct ItemConfig: Equatable, Sendable, Identifiable {
    public let stepID: String
    /// Position within the step's `items:` list (0-based).
    public let index: Int
    /// The YAML key that selected the action, e.g. `brew`, `cask`, `copy`.
    public let kind: String
    /// The value of the kind key (`eza` in `- brew: eza`).
    public let value: YAMLValue
    /// Every other key on the item except the common ones below.
    public let options: YAMLMap
    /// Common: display name override.
    public let name: String?
    /// Common: when true the item is off unless the user switches it on.
    public let optional: Bool
    /// Common: a note shown next to the item.
    public let note: String?
    public let source: SourceRef

    public init(stepID: String, index: Int, kind: String, value: YAMLValue, options: YAMLMap,
                name: String? = nil, optional: Bool = false, note: String? = nil, source: SourceRef) {
        self.stepID = stepID
        self.index = index
        self.kind = kind
        self.value = value
        self.options = options
        self.name = name
        self.optional = optional
        self.note = note
        self.source = source
    }

    /// Stable within one loaded config: `<step id>/<index>`.
    public var id: String { "\(stepID)/\(index)" }

    /// Keys every item may carry regardless of kind.
    public static let commonKeys: Set<String> = ["name", "optional", "note"]
}
