import Foundation
import ShawnCore
import ShawnSync

/// What is installed on this Mac, per package manager.
struct InstalledPackages: Equatable, Sendable {
    struct App: Equatable, Sendable {
        var id: String
        var name: String
    }

    /// `brew leaves`: formulae nobody depends on (what a person chose to install).
    var formulaLeaves: [String] = []
    /// Every installed formula (a declared formula may be installed as a dependency).
    var formulae: [String] = []
    var casks: [String] = []
    var taps: [String] = []
    var appStore: [App] = []
    var npm: [String] = []
    /// Managers that could be asked (a missing `mas` or `npm` is not "nothing installed").
    var available: Set<PackageRef.Manager> = []
}

protocol Inventory: Sendable {
    func installed() async -> InstalledPackages
}

/// Asks Homebrew, mas and npm (read-only).
struct BrewInventory: Inventory {
    let launcher: any ProcessLaunching
    let environment: SystemEnvironment

    func installed() async -> InstalledPackages {
        var result = InstalledPackages()
        let brewEnvironment = environment.processEnvironment(overrides: [
            "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1",
        ])
        let brew = environment.brewExecutable
        if FileManager.default.isExecutableFile(atPath: brew) {
            func list(_ arguments: [String]) async -> [String]? {
                let output = await launcher.capture(ProcessRequest(brew, arguments, environment: brewEnvironment, timeout: 60))
                return output.succeeded ? output.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : nil
            }
            if let leaves = await list(["leaves"]), let formulae = await list(["list", "--formula", "--full-name", "-1"]) {
                result.formulaLeaves = leaves
                result.formulae = formulae
                result.available.insert(.formula)
            }
            if let casks = await list(["list", "--cask", "--full-name", "-1"]) {
                result.casks = casks
                result.available.insert(.cask)
            }
            if let taps = await list(["tap"]) {
                // Homebrew's own taps come with Homebrew; nobody declares them.
                result.taps = taps.filter { !$0.hasPrefix("homebrew/") }
                result.available.insert(.tap)
            }
        }
        if let mas = ToolLocator.find("mas", environment: environment) {
            let output = await launcher.capture(ProcessRequest(mas, ["list"], environment: environment.processEnvironment(), timeout: 30))
            if output.succeeded {
                result.appStore = Self.parseMASList(output.stdout)
                result.available.insert(.mas)
            }
        }
        if let npm = ToolLocator.find("npm", environment: environment) {
            let output = await launcher.capture(ProcessRequest(npm, ["ls", "-g", "--depth=0", "--json"], environment: environment.processEnvironment(), timeout: 30))
            if let data = output.stdout.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dependencies = object["dependencies"] as? [String: Any] {
                result.npm = dependencies.keys.filter { $0 != "npm" && $0 != "corepack" }.sorted()
                result.available.insert(.npm)
            }
        }
        return result
    }

    /// `mas list`: `937984704  Amphetamine  (5.3.2)`.
    static func parseMASList(_ text: String) -> [InstalledPackages.App] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { return nil }
            let id = String(trimmed[..<space])
            guard Int(id) != nil else { return nil }
            var name = trimmed[space...].trimmingCharacters(in: .whitespaces)
            if let version = name.range(of: "\\s+\\([^)]*\\)$", options: .regularExpression) { name.removeSubrange(version) }
            return InstalledPackages.App(id: id, name: name)
        }
    }
}

/// Which item kind declares packages of which manager. Learned from the plan and the registry, so
/// no kind name is spelled out here.
enum PackageKinds {
    static func discover(plan: InstallPlan?, registry: ActionRegistry, preferred: [String]) -> [PackageRef.Manager: String] {
        var kinds: [PackageRef.Manager: String] = [:]
        for item in plan?.allItems ?? [] {
            if let provider = item.action as? any PackageProviding, kinds[provider.packageRef.manager] == nil {
                kinds[provider.packageRef.manager] = item.config.kind
            }
        }
        let candidates = preferred + registry.kinds.filter { !preferred.contains($0) }
        for kind in candidates where registry.descriptor(for: kind) != nil {
            if let manager = probe(kind, registry: registry), kinds[manager] == nil {
                kinds[manager] = kind
            }
        }
        return kinds
    }

    /// Builds a throwaway item of `kind` to see whether it declares a package.
    static func probe(_ kind: String, registry: ActionRegistry) -> PackageRef.Manager? {
        let values: [YAMLValue] = [.string("probe"), .string("probe/probe"), .int(1)]
        for value in values {
            for withName in [false, true] {
                var entries = [YAMLMap.Entry(key: kind, value: value)]
                if withName { entries.append(YAMLMap.Entry(key: "name", value: .string("Probe"))) }
                let raw = RawItem(map: YAMLMap(entries), source: SourceRef(file: "probe"))
                if case .success(let resolved) = registry.resolve(raw, stepID: "probe", index: 0),
                   let provider = resolved.action as? any PackageProviding {
                    return provider.packageRef.manager
                }
            }
        }
        return nil
    }
}

struct DriftReport: Equatable, Sendable {
    /// Installed on this Mac, not declared in the config.
    struct Extra: Equatable, Sendable {
        var manager: PackageRef.Manager
        var name: String
        var label: String?
        /// The item kind to declare it with (nil when no kind handles this manager).
        var kind: String?
    }

    /// Declared, not installed.
    struct Missing: Equatable, Sendable {
        var ref: PackageRef
        var source: SourceRef
        var optional: Bool
        /// The plan item that declares it.
        var itemID: String = ""
    }

    var extras: [Extra] = []
    var missing: [Missing] = []
    /// Declared and not known to the package manager, but the item's own check says it is in place
    /// (a cask whose `app:` was installed by hand or by IT). Neither drift nor missing.
    var installedElsewhere: [Missing] = []
    /// Managers that could not be asked, so nothing is claimed about them.
    var unchecked: [PackageRef.Manager] = []

    var isEmpty: Bool { extras.isEmpty && missing.isEmpty }
}

enum Drift {
    static func compare(plan: InstallPlan, installed: InstalledPackages, kinds: [PackageRef.Manager: String]) -> DriftReport {
        var report = DriftReport()
        var declared: [PackageRef.Manager: Set<String>] = [:]
        var declaredItems: [(ref: PackageRef, item: PlannedItem)] = []
        for item in plan.allItems {
            guard let provider = item.action as? any PackageProviding else { continue }
            let ref = provider.packageRef
            declared[ref.manager, default: []].insert(key(ref.manager, ref.name))
            declaredItems.append((ref, item))
        }

        func have(_ manager: PackageRef.Manager) -> Set<String> {
            switch manager {
            case .formula: return Set(installed.formulae.map { key(.formula, $0) })
            case .cask: return Set(installed.casks.map { key(.cask, $0) })
            case .tap: return Set(installed.taps.map { key(.tap, $0) })
            case .mas: return Set(installed.appStore.map(\.id))
            case .npm: return Set(installed.npm.map { key(.npm, $0) })
            }
        }

        for manager in PackageRef.Manager.allCases {
            guard installed.available.contains(manager) else {
                if declared[manager] != nil { report.unchecked.append(manager) }
                continue
            }
            let known = declared[manager] ?? []
            switch manager {
            case .formula:
                for name in installed.formulaLeaves where !known.contains(key(.formula, name)) {
                    report.extras.append(.init(manager: .formula, name: name, label: nil, kind: kinds[.formula]))
                }
            case .cask:
                for name in installed.casks where !known.contains(key(.cask, name)) {
                    report.extras.append(.init(manager: .cask, name: name, label: nil, kind: kinds[.cask]))
                }
            case .tap:
                for name in installed.taps where !known.contains(key(.tap, name)) {
                    report.extras.append(.init(manager: .tap, name: name, label: nil, kind: kinds[.tap]))
                }
            case .mas:
                for app in installed.appStore where !known.contains(app.id) {
                    report.extras.append(.init(manager: .mas, name: app.id, label: app.name, kind: kinds[.mas]))
                }
            case .npm:
                for name in installed.npm where !known.contains(key(.npm, name)) {
                    report.extras.append(.init(manager: .npm, name: name, label: nil, kind: kinds[.npm]))
                }
            }
            let present = have(manager)
            for entry in declaredItems where entry.ref.manager == manager && !present.contains(key(manager, entry.ref.name)) {
                report.missing.append(.init(ref: entry.ref, source: entry.item.config.source, optional: entry.item.config.optional, itemID: entry.item.id))
            }
        }
        return report
    }

    /// Runs the read-only checks of the items the package managers do not list, and moves the ones that
    /// are in place anyway (an app in /Applications that its cask item names with `app:`) out of `missing`.
    /// The item kinds decide what "in place" means, exactly as `shawn install` and `shawn doctor` do.
    static func confirmMissing(_ report: DriftReport, plan: InstallPlan, environment: SystemEnvironment) async -> DriftReport {
        guard !report.missing.isEmpty else { return report }
        let ids = Set(report.missing.map(\.itemID))
        var overrides: [String: Bool] = [:]
        for item in plan.allItems { overrides[item.id] = ids.contains(item.id) }
        let engine = InstallEngine(plan: plan, environment: environment, options: RunOptions(dryRun: true))
        let satisfied = SatisfiedItems()
        await engine.scan(selection: Selection(itemOverrides: overrides)) { id, result in
            if result.isSatisfied { satisfied.insert(id) }
        }
        var confirmed = report
        confirmed.missing = report.missing.filter { !satisfied.contains($0.itemID) }
        confirmed.installedElsewhere = report.missing.filter { satisfied.contains($0.itemID) }
        return confirmed
    }

    /// Third-party names are compared by their short name: Homebrew lists `user/tap/name` for some
    /// commands and `name` for others.
    static func key(_ manager: PackageRef.Manager, _ name: String) -> String {
        let lowered = name.lowercased()
        switch manager {
        case .tap, .mas, .npm: return lowered
        case .formula, .cask: return lowered.split(separator: "/").last.map(String.init) ?? lowered
        }
    }
}

struct DriftCommand: BuiltinCommand {
    let name = "drift"
    let section = BuiltinSection.setup
    let summary = "What's installed but not in the config (and the reverse)"
    let usage = "[--write] [--repo PATH]"
    let details: String? = """
    Compares the packages the config declares with what Homebrew, the App Store and npm have on this Mac. \
    Prints the YAML lines that would declare the extras; --write adds them to the step files named under add: \
    in cli.yaml (in the checkout), keeping comments and formatting.
    """
    let options = [
        OptionSpec("write", "Add the missing lines to the config in the checkout"),
        OptionSpec("repo", value: "PATH", "Use this checkout instead of the one in ~/.config/shawn/config.yaml"),
    ]

    func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let (parsed, code) = parse(arguments, context: context)
        guard let parsed else { return code }
        let style = context.style
        let checkout = parsed.value("repo").map { URL(fileURLWithPath: PathExpansion.expandTilde($0, home: context.environment.home)) } ?? context.checkout
        let configRoot = checkout.map { $0.appendingPathComponent(context.settings.configPath) }
        if parsed.has("write") && configRoot == nil {
            context.fail("shawn drift --write: needs a checkout of the dotfiles (set one up with 'shawn install', or pass --repo PATH)")
            return ExitCode.usage
        }
        let resolved: ResolvedConfig
        switch PlanLoader.local(context: context, directory: configRoot) {
        case .failure(let error):
            context.fail("shawn drift: \(error)")
            return ExitCode.failure
        case .success(let config):
            resolved = config
        }
        let cli = CLIConfig.load(from: resolved.config).config
        let kinds = PackageKinds.discover(plan: resolved.plan, registry: context.registry, preferred: cli.add.map(\.kind))
        let installed = await context.inventory.installed()
        let report = await Drift.confirmMissing(Drift.compare(plan: resolved.plan, installed: installed, kinds: kinds),
                                                plan: resolved.plan, environment: context.environment)

        if report.isEmpty {
            context.out.line(style.ok("✓") + " no drift: the config and this Mac agree")
        }
        if !report.extras.isEmpty {
            context.out.line(style.heading("Installed but not in the config (\(report.extras.count))"))
            for extra in report.extras {
                let line = extra.kind.map { Self.display(kind: $0, extra: extra) } ?? "(no item kind declares \(extra.manager.rawValue) packages)"
                let target = extra.kind.flatMap { cli.addTarget(for: $0)?.file } ?? "no add: entry"
                context.out.line("  " + TextWidth.pad(extra.manager.rawValue, to: 8) + TextWidth.pad(extra.name + (extra.label.map { " (\($0))" } ?? ""), to: 32)
                                 + style.accent(line) + style.muted("  → \(target)"))
            }
        }
        if !report.missing.isEmpty {
            context.out.line(style.heading("In the config but not installed (\(report.missing.count))"))
            for entry in report.missing {
                context.out.line("  " + TextWidth.pad(entry.ref.manager.rawValue, to: 8) + TextWidth.pad(entry.ref.name + (entry.ref.label.map { " (\($0))" } ?? ""), to: 32)
                                 + style.muted("\(entry.source)" + (entry.optional ? " · optional" : "")))
            }
        }
        if !report.installedElsewhere.isEmpty {
            let count = report.installedElsewhere.count
            context.out.line(style.heading("Installed without Homebrew (\(count))") + style.muted(" · in place, but 'brew upgrade' does not update them"))
            for manager in PackageRef.Manager.allCases {
                let names = report.installedElsewhere.filter { $0.ref.manager == manager }.map(\.ref.name)
                guard !names.isEmpty else { continue }
                for (index, line) in TextWidth.wrap(names.joined(separator: ", "), width: max(20, context.terminal.width - 12)).enumerated() {
                    context.out.line("  " + TextWidth.pad(index == 0 ? manager.rawValue : "", to: 8) + style.muted(line))
                }
            }
        }
        if !report.unchecked.isEmpty {
            context.out.line(style.muted("Not checked (tool not available): " + report.unchecked.map(\.rawValue).joined(separator: ", ")))
        }

        guard parsed.has("write"), let configRoot, !report.extras.isEmpty else { return ExitCode.ok }
        context.out.line("")
        var failed = false
        // Casks go in with the app they install when the step file's casks name theirs (see 04-apps.yaml).
        let caskApps = await CaskApps.lookup(report.extras.filter { $0.manager == .cask }.map(\.name), context: context)
        for extra in report.extras {
            guard let kind = extra.kind, let target = cli.addTarget(for: kind) else {
                context.warn("not written: \(extra.name), because cli.yaml has no add: entry for its kind")
                continue
            }
            let file = configRoot.appendingPathComponent(target.file)
            do {
                var options = Self.options(for: extra)
                if extra.manager == .cask, let app = caskApps[extra.name],
                   CaskApps.wanted(kind: kind, entries: [YAMLMap.Entry(key: kind, value: .string(extra.name))], registry: context.registry),
                   CaskApps.fileUsesApps(kind: kind, text: (try? String(contentsOf: file, encoding: .utf8)) ?? "") {
                    options.append((key: CaskApps.optionKey, value: .string(app)))
                }
                switch try ConfigEditor.insert(kind: kind, value: extra.name, options: options, file: file) {
                case .inserted(let line):
                    context.out.line(style.ok("✓") + " \(target.file):\(line)  " + Self.display(kind: kind, value: extra.name, options: options))
                case .alreadyPresent(let line):
                    context.out.line(style.muted("· \(target.file):\(line) already has \(extra.name)"))
                }
            } catch {
                context.fail("\(target.file): \(error)")
                failed = true
            }
        }
        context.out.line(style.muted("Review with git diff, then 'shawn pr' to send it."))
        return failed ? ExitCode.failure : ExitCode.ok
    }

    /// The YAML for one extra on a single line: `- mas: 1289583905, name: Pixelmator Pro`.
    static func display(kind: String, extra: DriftReport.Extra) -> String {
        display(kind: kind, value: extra.name, options: options(for: extra))
    }

    static func display(kind: String, value: String, options: [ConfigEditor.Option]) -> String {
        ConfigEditor.itemLines(kind: kind, value: value, options: options, indent: "")
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
    }

    /// An App Store app is declared with its name next to its id.
    static func options(for extra: DriftReport.Extra) -> [ConfigEditor.Option] {
        extra.label.map { [(key: "name", value: YAMLValue.string($0))] } ?? []
    }
}

private final class SatisfiedItems: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
}
