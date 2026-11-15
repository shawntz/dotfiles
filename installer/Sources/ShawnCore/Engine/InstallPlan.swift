import Foundation

/// One item ready to run.
public struct PlannedItem: Sendable, Identifiable {
    public let config: ItemConfig
    public let action: any Action
    /// What to call it in the UI, with `{{vars}}` filled in (a clone item's title is its repository).
    public let title: String
    public let subtitle: String?
    /// Every `{{name}}` the item's text mentions (see `InstallPlan.mentionedVariables`). The engine holds an item back
    /// while one of these is a question without an answer.
    public let variables: Set<String>
    /// Absolute paths of the files the item makes and of those it uses (`Action.madeFiles`, `Action.usedFiles`).
    /// See `InstallPlan.waitingQuestions`.
    public let madeFiles: Set<String>
    public let usedFiles: Set<String>

    /// Without `variables`, they are worked out from the item's own YAML.
    public init(config: ItemConfig, action: any Action, vars: TemplateVars = TemplateVars(), variables: Set<String>? = nil,
                madeFiles: Set<String> = [], usedFiles: Set<String> = []) {
        self.config = config
        self.action = action
        self.title = vars.expand(config.name ?? action.title)
        self.subtitle = action.subtitle.map(vars.expand)
        self.variables = variables ?? InstallPlan.mentionedVariables(item: config, impliedText: [], configVars: [:])
        self.madeFiles = madeFiles
        self.usedFiles = usedFiles
    }

    public var id: String { config.id }
    /// Optional items start switched off.
    public var enabledByDefault: Bool { !config.optional }
}

public struct PlannedStep: Sendable, Identifiable {
    public let config: StepConfig
    public let items: [PlannedItem]

    public var id: String { config.id }
}

/// The config turned into actions, plus everything that was wrong with it.
public struct InstallPlan: Sendable {
    public let config: InstallerConfig
    public let steps: [PlannedStep]
    public let issues: [ConfigIssue]

    public var errors: [ConfigIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ConfigIssue] { issues.filter { $0.severity == .warning } }
    public var hasErrors: Bool { !errors.isEmpty }
    public var allItems: [PlannedItem] { steps.flatMap(\.items) }

    public func step(_ id: String) -> PlannedStep? {
        steps.first { $0.id == id }
    }

    public func item(_ id: String) -> PlannedItem? {
        allItems.first { $0.id == id }
    }

    /// The config's questions that `item` needs, in the order the config asks them.
    public func questions(for item: PlannedItem) -> [VariableQuestion] {
        config.meta.ask.filter { item.variables.contains($0.name) }
    }

    /// The config's questions that any of `items` needs, in the order the config asks them.
    public func questions(for items: [PlannedItem]) -> [VariableQuestion] {
        let needed = items.reduce(into: Set<String>()) { $0.formUnion($1.variables) }
        return config.meta.ask.filter { needed.contains($0.name) }
    }

    /// The questions in `unanswered` that hold each of `items` back, by item ID, in config order. `items` are the
    /// items a run takes, in run order. An item waits for the questions it needs itself. It also waits for those of
    /// an earlier waiting item that would make a file it uses (the `github` item uploads the key `ssh-key` makes),
    /// unless that file is already on this Mac or an earlier item that does not wait makes it too.
    public func waitingQuestions(for items: [PlannedItem], unanswered: Set<String>) -> [String: [VariableQuestion]] {
        var waiting: [String: [VariableQuestion]] = [:]
        var madeByRunningItems: Set<String> = []
        var madeByWaitingItems: [String: Set<String>] = [:]
        for item in items {
            var names = item.variables.intersection(unanswered)
            for file in item.usedFiles where !madeByRunningItems.contains(file) && !FileManager.default.fileExists(atPath: file) {
                names.formUnion(madeByWaitingItems[file] ?? [])
            }
            if names.isEmpty {
                madeByRunningItems.formUnion(item.madeFiles)
                continue
            }
            for file in item.madeFiles { madeByWaitingItems[file, default: []].formUnion(names) }
            waiting[item.id] = config.meta.ask.filter { names.contains($0.name) }
        }
        return waiting
    }

    /// Resolves every item against the registry and runs each action's static validation.
    /// Items that fail to resolve are left out of `steps` and reported in `issues`.
    /// Titles use the answers saved on this Mac; a question without one stays as written.
    public static func build(config: InstallerConfig, registry: ActionRegistry,
                             environment: SystemEnvironment = .live(), extraIssues: [ConfigIssue] = []) -> InstallPlan {
        var issues = extraIssues
        var steps: [PlannedStep] = []
        let vars = ActionContext.makeVars(config: config, environment: environment,
                                          answers: AnswerStore(environment: environment).answers(for: config.meta.ask))

        for question in config.meta.ask {
            for name in vars.unknownVariables(in: question.defaultValue ?? "") {
                issues.append(.error("installer → ask '\(question.name)': 'default' uses unknown variable {{\(name)}}", at: question.source))
            }
        }

        for step in config.steps {
            var items: [PlannedItem] = []
            for (index, raw) in step.rawItems.enumerated() {
                switch registry.resolve(raw, stepID: step.id, index: index) {
                case .failure(let error):
                    issues.append(contentsOf: error.issues)
                case .success(let resolved):
                    let context = ValidationContext(config: config, item: resolved.item, vars: vars)
                    for message in resolved.action.validate(context) {
                        issues.append(.error("item \(index + 1) (\(resolved.item.kind)): \(message)", at: raw.source))
                    }
                    let variables = mentionedVariables(item: resolved.item, impliedText: resolved.action.impliedText(context), configVars: config.meta.vars)
                    let files = { (paths: [String]) in
                        Set(paths.map { ActionContext.path($0, vars: vars, home: environment.home).standardizedFileURL.path })
                    }
                    items.append(PlannedItem(config: resolved.item, action: resolved.action, vars: vars, variables: variables,
                                             madeFiles: files(resolved.action.madeFiles(context)),
                                             usedFiles: files(resolved.action.usedFiles(context))))
                }
            }
            steps.append(PlannedStep(config: step, items: items))
        }
        return InstallPlan(config: config, steps: steps, issues: issues)
    }

    /// Every `{{name}}` an item mentions: in its kind value, its options (keys and values, nested ones included),
    /// `name:` and `note:`, in `impliedText` (what its action fills in by default), and in turn in the `vars:` named
    /// there, which may use an answer.
    public static func mentionedVariables(item: ItemConfig, impliedText: [String], configVars: [String: String]) -> Set<String> {
        var texts = impliedText
        if let name = item.name { texts.append(name) }
        if let note = item.note { texts.append(note) }
        collectText(item.value, into: &texts)
        collectText(.map(item.options), into: &texts)
        var names = Set(texts.flatMap(TemplateVars.names(in:)))
        for name in names {
            if let value = configVars[name] { names.formUnion(TemplateVars.names(in: value)) }
        }
        return names
    }

    private static func collectText(_ value: YAMLValue, into texts: inout [String]) {
        switch value {
        case .scalar:
            if let text = value.string { texts.append(text) }
        case .list(let values):
            for element in values { collectText(element, into: &texts) }
        case .map(let map):
            for entry in map.entries {
                texts.append(entry.key)
                collectText(entry.value, into: &texts)
            }
        }
    }
}

/// Which steps and items the user wants to run.
public struct Selection: Equatable, Sendable {
    /// Steps switched off.
    public var disabledSteps: Set<String>
    /// Explicit per-item choices; items not listed follow their default (`optional` items are off).
    public var itemOverrides: [String: Bool]

    public init(disabledSteps: Set<String> = [], itemOverrides: [String: Bool] = [:]) {
        self.disabledSteps = disabledSteps
        self.itemOverrides = itemOverrides
    }

    /// Everything on except steps marked `enabled: false` and items marked `optional: true`.
    public static func defaults(for plan: InstallPlan) -> Selection {
        Selection(disabledSteps: Set(plan.steps.filter { !$0.config.enabledByDefault }.map(\.id)))
    }

    /// Only the named steps.
    public static func only(steps: [String], in plan: InstallPlan) -> Selection {
        Selection(disabledSteps: Set(plan.steps.map(\.id)).subtracting(steps))
    }

    public func isEnabled(step: PlannedStep) -> Bool {
        !disabledSteps.contains(step.id)
    }

    public func isEnabled(item: PlannedItem) -> Bool {
        itemOverrides[item.id] ?? item.enabledByDefault
    }

    public mutating func setStep(_ id: String, enabled: Bool) {
        if enabled {
            disabledSteps.remove(id)
        } else {
            disabledSteps.insert(id)
        }
    }

    public mutating func setItem(_ item: PlannedItem, enabled: Bool) {
        if enabled == item.enabledByDefault {
            itemOverrides.removeValue(forKey: item.id)
        } else {
            itemOverrides[item.id] = enabled
        }
    }

    /// Items that will actually run, in order.
    public func enabledItems(in plan: InstallPlan) -> [PlannedItem] {
        plan.steps.filter { isEnabled(step: $0) }.flatMap { $0.items.filter { isEnabled(item: $0) } }
    }
}
