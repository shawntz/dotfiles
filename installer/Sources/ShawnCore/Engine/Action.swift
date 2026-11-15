import Foundation

/// Whether an action needs administrator rights.
public enum SudoNeed: Sendable {
    case never
    /// Might (e.g. a cask whose installer is a .pkg). The run continues without them if the user declines.
    case maybe
    /// Cannot work without them.
    case always
}

/// Result of asking "is this already done?".
public enum CheckResult: Equatable, Sendable {
    /// Already in the desired state; `run` will be skipped. The text says why ("already installed").
    case satisfied(String? = nil)
    /// Work to do.
    case needed(String? = nil)

    public var isSatisfied: Bool {
        if case .satisfied = self { return true }
        return false
    }
}

/// Result of doing the work.
public enum ActionOutcome: Equatable, Sendable {
    case done(String? = nil)
    /// Not applicable on this machine.
    case skipped(String)
    /// Finished what could be automated; a person has to do the rest.
    case needsAttention(String)
}

/// A failure with a message fit to show the user.
public struct ActionError: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// What the user can do about it.
    public let hint: String?

    public init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    public var description: String {
        guard let hint, !hint.isEmpty else { return Self.withoutDanglingEnd(message) }
        return Self.sentences(message, hint)
    }

    /// The message, then the hint as a sentence of its own: "kaboom. Try again later".
    public static func sentences(_ message: String, _ hint: String) -> String {
        let hint = hint.prefix(1).uppercased() + hint.dropFirst()
        let message = withoutDanglingEnd(message)
        guard let last = message.last else { return hint }
        return message + (".!?…".contains(last) ? " " : ". ") + hint
    }

    /// `message` without trailing spaces or a trailing ":", ";" or ",". A message built as "<label>: <tool output>"
    /// ends in ": " when the tool printed nothing, which would otherwise read "failed: . Try again".
    static func withoutDanglingEnd(_ message: String) -> String {
        var end = message.endIndex
        while end > message.startIndex {
            let previous = message.index(before: end)
            guard message[previous].isWhitespace || ":;,".contains(message[previous]) else { break }
            end = previous
        }
        return String(message[..<end])
    }

    /// `text` with a period at the end, unless it already ends a sentence ("Did you mean 'app'?").
    public static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?…".contains(last) else { return text }
        return text + "."
    }
}

/// Read-only view of the config for static validation (no machine access).
public struct ValidationContext: Sendable {
    public let config: InstallerConfig
    public let item: ItemConfig
    /// Variables known at validation time (config vars plus the machine built-ins).
    public let vars: TemplateVars

    public init(config: InstallerConfig, item: ItemConfig, vars: TemplateVars) {
        self.config = config
        self.item = item
        self.vars = vars
    }

    /// True when a path relative to the config root exists.
    public func configPathExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: config.url(relativePath).path)
    }

    public func configPathIsDirectory(_ relativePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: config.url(relativePath).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Messages for any `{{name}}` in `text` that has no value.
    public func unknownVariableMessages(in text: String, field: String) -> [String] {
        vars.unknownVariables(in: text).map { "'\(field)' uses unknown variable {{\($0)}}" }
    }
}

/// One thing the installer can do. Each YAML item kind (`brew`, `cask`, `copy`, ...) is an `Action`.
///
/// Contract:
/// - `check` is read-only and reasonably quick; it answers "is the desired state already in place?".
/// - `run` makes it so. It must be safe to run again after a partial failure, must go through
///   `context.commands` / `context.files` for anything that changes the machine (so dry runs stay dry),
///   and must throw `ActionError` (or let a `CommandError` propagate) with a message a person can act on.
public protocol Action: Sendable {
    /// Short name shown in the item list: `eza`, `Homebrew`, `~/.zshrc`.
    var title: String { get }
    /// Optional second line: the source, destination or command.
    var subtitle: String? { get }
    var sudo: SudoNeed { get }
    /// False for kinds whose `check` can never say "already done" (opening an app, a reminder with no test).
    /// Health checks such as `shawn doctor` leave those out instead of reporting them as missing forever.
    var isCheckable: Bool { get }
    /// Static problems (missing payload files, unknown variables). No machine access.
    func validate(_ context: ValidationContext) -> [String]
    /// Text this action fills `{{variables}}` into that the item's YAML may not show: an option's default (the
    /// `ssh-key` comment is `{{email}}` unless the item sets one) or a payload file it templates. The plan reads it,
    /// with the item's own text, to learn which of the config's questions the item needs. No machine access.
    func impliedText(_ context: ValidationContext) -> [String]
    /// Files this action makes, as written (`ssh-key` makes the key and its `.pub`). While this item waits for an
    /// answer, a later item that uses one of them waits too, until the file exists. No machine access.
    func madeFiles(_ context: ValidationContext) -> [String]
    /// Files this action needs that an earlier item may make (`github` uploads the public key). No machine access.
    func usedFiles(_ context: ValidationContext) -> [String]
    func check(_ context: ActionContext) async -> CheckResult
    func run(_ context: ActionContext) async throws -> ActionOutcome
}

public extension Action {
    var subtitle: String? { nil }
    var sudo: SudoNeed { .never }
    var isCheckable: Bool { true }
    func validate(_ context: ValidationContext) -> [String] { [] }
    func impliedText(_ context: ValidationContext) -> [String] { [] }
    func madeFiles(_ context: ValidationContext) -> [String] { [] }
    func usedFiles(_ context: ValidationContext) -> [String] { [] }
}

/// Describes one item kind: how to recognize it in YAML and how to build its action.
public struct ActionDescriptor: Sendable {
    /// The YAML key, e.g. `brew`.
    public let kind: String
    /// One-line description for `shawn config kinds` and the docs.
    public let summary: String
    /// A YAML example of one item.
    public let example: String
    /// Builds the action. Read every option through the parser; unknown keys are reported automatically afterward.
    public let make: @Sendable (ItemParser) throws -> any Action

    public init(kind: String, summary: String, example: String, make: @escaping @Sendable (ItemParser) throws -> any Action) {
        self.kind = kind
        self.summary = summary
        self.example = example
        self.make = make
    }
}

/// The set of item kinds the installer understands.
public struct ActionRegistry: Sendable {
    public private(set) var descriptors: [String: ActionDescriptor] = [:]

    public init() {}

    public mutating func register(_ descriptor: ActionDescriptor) {
        precondition(descriptors[descriptor.kind] == nil, "item kind '\(descriptor.kind)' registered twice")
        precondition(!ItemConfig.commonKeys.contains(descriptor.kind), "'\(descriptor.kind)' is reserved")
        descriptors[descriptor.kind] = descriptor
    }

    public mutating func register(_ descriptors: [ActionDescriptor]) {
        for descriptor in descriptors { register(descriptor) }
    }

    public var kinds: [String] { descriptors.keys.sorted() }

    public func descriptor(for kind: String) -> ActionDescriptor? { descriptors[kind] }

    /// Resolves a raw YAML item: its FIRST key names the kind, every other key is an option.
    public func resolve(_ raw: RawItem, stepID: String, index: Int) -> Result<(item: ItemConfig, action: any Action), ConfigError> {
        guard let first = raw.map.entries.first else {
            return .failure(ConfigError([.error("item \(index + 1) is empty", at: raw.source)]))
        }
        guard let descriptor = descriptors[first.key] else {
            // Kind key present but not first? Say so; otherwise suggest the nearest kind.
            if let misplaced = raw.map.keys.dropFirst().first(where: { descriptors[$0] != nil }) {
                return .failure(ConfigError([.error("item \(index + 1): the first key must be the item's kind; put '\(misplaced):' first (found '\(first.key):')", at: raw.source)]))
            }
            let suggestion = MapReader.closestMatch(to: first.key, in: Set(descriptors.keys)).map { ". Did you mean '\($0)'?" } ?? ""
            return .failure(ConfigError([.error("item \(index + 1): unknown item kind '\(first.key)'\(suggestion) (known kinds: \(kinds.joined(separator: ", ")))", at: raw.source)]))
        }

        let collector = IssueCollector()
        let commonReader = MapReader(map: raw.map, source: raw.source, context: "item \(index + 1) (\(descriptor.kind))", collector: collector)
        let name = commonReader.string("name")
        let optional = commonReader.bool("optional", default: false)
        let note = commonReader.string("note")

        let item = ItemConfig(
            stepID: stepID,
            index: index,
            kind: descriptor.kind,
            value: first.value,
            options: raw.map.removing(ItemConfig.commonKeys.union([first.key])),
            name: name,
            optional: optional,
            note: note,
            source: raw.source
        )

        let parser = ItemParser(item: item, collector: collector)
        do {
            let action = try descriptor.make(parser)
            try parser.finish()
            return .success((item, action))
        } catch let error as ConfigError {
            // Prefer the accumulated list (it includes everything the thrown error has, and more).
            let errors = collector.errors
            return .failure(errors.isEmpty ? error : ConfigError(errors))
        } catch {
            return .failure(ConfigError(collector.errors + [.error("item \(index + 1) (\(descriptor.kind)): \(error)", at: raw.source)]))
        }
    }
}
