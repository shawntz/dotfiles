import Foundation

/// Switches for one run of the engine.
public struct RunOptions: Equatable, Sendable {
    /// Narrate what would happen without changing anything.
    public var dryRun: Bool
    /// Treat every item as not yet done (demos, screenshots, tests).
    public var assumeFresh: Bool
    /// Pause after each simulated command so a dry run is watchable.
    public var dryRunDelay: TimeInterval
    /// Ask every question the enabled items need again, offering the saved answer as the default
    /// (`shawn install --ask`). A dry run never asks.
    public var askAgain: Bool

    public init(dryRun: Bool = false, assumeFresh: Bool = false, dryRunDelay: TimeInterval = 0, askAgain: Bool = false) {
        self.dryRun = dryRun
        self.assumeFresh = assumeFresh
        self.dryRunDelay = dryRunDelay
        self.askAgain = askAgain
    }
}

/// State shared by every action in a run: caches of slow probes and handles to background work.
public actor SharedState {
    private var cache: [String: any Sendable] = [:]
    private var background: [String: Task<ActionOutcome, Error>] = [:]

    public init() {}

    public func value<T: Sendable>(_ key: String, as type: T.Type = T.self) -> T? {
        cache[key] as? T
    }

    public func set(_ key: String, _ value: any Sendable) {
        cache[key] = value
    }

    /// Drops one cached value (call after changing whatever it describes).
    public func invalidate(_ key: String) {
        cache.removeValue(forKey: key)
    }

    public func invalidate(prefix: String) {
        for key in cache.keys where key.hasPrefix(prefix) { cache.removeValue(forKey: key) }
    }

    /// Returns the cached value for `key`, computing and storing it on first use.
    public func cached<T: Sendable>(_ key: String, _ compute: @Sendable () async -> T) async -> T {
        if let existing = cache[key] as? T { return existing }
        let value = await compute()
        cache[key] = value
        return value
    }

    /// Registers long-running work started by one item so a later item can wait for it.
    public func startBackground(_ id: String, _ task: Task<ActionOutcome, Error>) {
        background[id] = task
    }

    public func backgroundTask(_ id: String) -> Task<ActionOutcome, Error>? {
        background[id]
    }

    public func cancelBackgroundWork() {
        for task in background.values { task.cancel() }
        background.removeAll()
    }
}

/// Everything an action needs while it checks or runs.
public final class ActionContext: @unchecked Sendable {
    public let config: InstallerConfig
    public let environment: SystemEnvironment
    public let options: RunOptions
    public let step: StepConfig
    public let item: ItemConfig
    /// Config `vars:`, the answers to the config's questions, and machine built-ins (`home`, `user`, `hostname`,
    /// `arch`, `brew_prefix`, ...). A question without an answer is pending: `expand` leaves it as written.
    public let vars: TemplateVars
    /// Runs commands (dry-run aware, output goes to this item's log).
    public let commands: CommandRunner
    /// Changes files (dry-run aware, with backups).
    public let files: FileOps
    public let interaction: any UserInteraction
    public let shared: SharedState
    private let emit: @Sendable (InstallEvent) -> Void

    /// `vars` are the run's variables; without them, the context uses the answers saved on this Mac.
    public init(config: InstallerConfig, environment: SystemEnvironment, options: RunOptions, step: StepConfig, item: ItemConfig,
                sudo: (any SudoProviding)?, interaction: any UserInteraction, shared: SharedState,
                vars: TemplateVars? = nil, emit: @escaping @Sendable (InstallEvent) -> Void) {
        self.config = config
        self.environment = environment
        self.options = options
        self.step = step
        self.item = item
        self.vars = vars ?? Self.makeVars(config: config, environment: environment,
                                          answers: AnswerStore(environment: environment).answers(for: config.meta.ask))
        self.interaction = interaction
        self.shared = shared
        self.emit = emit
        let itemID = item.id
        let sink: @Sendable (LogLine) -> Void = { line in
            emit(.log(LogLine(line.text, style: line.style, itemID: line.itemID ?? itemID, isProgress: line.isProgress)))
        }
        self.commands = CommandRunner(environment: environment, dryRun: options.dryRun, dryRunDelay: options.dryRunDelay,
                                      sudo: sudo, itemID: itemID, sink: sink)
        self.files = FileOps(environment: environment, dryRun: options.dryRun, log: sink)
    }

    /// Machine built-ins, `config_dir`, `answers` to the config's questions, then `vars:`, which may use the others.
    /// A question with no entry in `answers` is pending: validation knows it, and `expand` leaves it as written.
    /// Answers to names the config does not ask for are ignored.
    public static func makeVars(config: InstallerConfig, environment: SystemEnvironment, answers: [String: String] = [:]) -> TemplateVars {
        var values = environment.templateVariables
        values["config_dir"] = config.root.path
        var pending: Set<String> = []
        for question in config.meta.ask where values[question.name] == nil {
            if let answer = answers[question.name] {
                values[question.name] = answer
            } else {
                pending.insert(question.name)
            }
        }
        // Config vars may reference the built-ins and the answers (not each other: one pass, in no particular order).
        let known = TemplateVars(values, pending: pending)
        for (key, value) in config.meta.vars { values[key] = known.expand(value) }
        return TemplateVars(values, pending: pending)
    }

    public var dryRun: Bool { options.dryRun }

    // MARK: Narration

    public func info(_ text: String) {
        emit(.log(LogLine(text, style: .info, itemID: item.id)))
    }

    public func success(_ text: String) {
        emit(.log(LogLine(text, style: .success, itemID: item.id)))
    }

    public func warn(_ text: String) {
        emit(.log(LogLine(text, style: .warning, itemID: item.id)))
    }

    /// Shows (or clears, with nil) a callout telling the user what the item is waiting on.
    public func attention(_ attention: Attention?) {
        emit(.attention(itemID: item.id, attention: attention))
    }

    /// Adds an entry to the "things only you can do" checklist shown at the end.
    public func followUp(_ title: String, detail: String? = nil, url: URL? = nil) {
        let slug = title.lowercased().filter { $0.isLetter || $0.isNumber }
        emit(.followUp(FollowUp(id: "\(item.id)-\(slug.prefix(40))", title: title, detail: detail, url: url, stepID: step.id)))
    }

    // MARK: Paths & templates

    /// Expands `{{variables}}`.
    public func expand(_ text: String) -> String {
        vars.expand(text)
    }

    /// Expands `{{variables}}` and a leading `~`, returning an absolute file URL.
    public func path(_ text: String) -> URL {
        Self.path(text, vars: vars, home: environment.home)
    }

    /// `path(_:)` without a context. A relative path starts in `home`.
    public static func path(_ text: String, vars: TemplateVars, home: URL) -> URL {
        let expanded = PathExpansion.expandTilde(vars.expand(text), home: home)
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return home.appendingPathComponent(expanded)
    }

    /// `~`-abbreviated path for messages.
    public func display(_ url: URL) -> String {
        PathExpansion.abbreviate(url.path, home: environment.home)
    }

    /// A path inside the config directory (payload files, bundled skills, icons).
    public func configURL(_ relativePath: String) -> URL {
        config.url(vars.expand(relativePath))
    }

    // MARK: Command shorthands

    @discardableResult
    public func run(_ command: Command) async throws -> CommandResult {
        try await commands.run(command)
    }

    @discardableResult
    public func runChecked(_ command: Command) async throws -> CommandResult {
        try await commands.runChecked(command)
    }

    /// Trimmed stdout of a read-only probe, or nil if it fails or the tool is missing.
    public func capture(_ executable: String, _ arguments: [String] = []) async -> String? {
        await commands.capture(executable, arguments)
    }

    public func toolExists(_ name: String) -> Bool {
        commands.toolExists(name)
    }
}
