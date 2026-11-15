import Foundation

/// One item ready to run.
public struct PlannedItem: Sendable, Identifiable {
    public let config: ItemConfig
    public let action: any Action
    /// What to call it in the UI, with `{{vars}}` filled in (a clone item's title is its repository).
    public let title: String
    public let subtitle: String?

    public init(config: ItemConfig, action: any Action, vars: TemplateVars = TemplateVars()) {
        self.config = config
        self.action = action
        self.title = vars.expand(config.name ?? action.title)
        self.subtitle = action.subtitle.map(vars.expand)
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

    /// Resolves every item against the registry and runs each action's static validation.
    /// Items that fail to resolve are left out of `steps` and reported in `issues`.
    public static func build(config: InstallerConfig, registry: ActionRegistry,
                             environment: SystemEnvironment = .live(), extraIssues: [ConfigIssue] = []) -> InstallPlan {
        var issues = extraIssues
        var steps: [PlannedStep] = []
        let vars = ActionContext.makeVars(config: config, environment: environment)

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
                    items.append(PlannedItem(config: resolved.item, action: resolved.action, vars: vars))
                }
            }
            steps.append(PlannedStep(config: step, items: items))
        }
        return InstallPlan(config: config, steps: steps, issues: issues)
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
