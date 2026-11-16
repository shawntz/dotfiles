import Foundation
import ShawnCore

/// `defaults: com.apple.finder` sets preference keys with exact types, then restarts whatever needs it.
struct DefaultsAction: Action {
    /// The domain as written (may hold `{{vars}}` or `~` when it is a path).
    let domain: String
    let currentHost: Bool
    /// Wanted values in YAML order; strings may hold `{{vars}}`.
    let values: [(key: String, value: PlistValue)]
    let restart: [String]
    let useSudo: Bool

    var title: String { currentHost ? "\(domain) (this Mac)" : domain }

    var subtitle: String? {
        let keys = values.map(\.key)
        let shown = keys.prefix(4).joined(separator: ", ")
        return keys.count > 4 ? "\(shown) +\(keys.count - 4) more" : shown
    }

    var sudo: SudoNeed { useSudo ? .always : .never }

    static let descriptor = ActionDescriptor(
        kind: "defaults",
        summary: "Set macOS preferences with exact types (bool/int/float/string/list/map) and restart the apps that read them.",
        example: """
        - defaults: com.apple.dock
          set:
            autohide: true
            tilesize: {type: float, value: 128}   # force a type: bool, int, float or string
            mineffect: scale
          restart: [Dock]
        - defaults: NSGlobalDomain
          set: {KeyRepeat: 1, InitialKeyRepeat: 10}
        - defaults: com.apple.controlcenter
          current_host: true                       # ~/Library/Preferences/ByHost
          set: {Battery: 18}
        """,
        make: { try make($0) }
    )

    private static func make(_ parser: ItemParser) throws -> any Action {
        let domain = parser.primaryString()
        let options = parser.options
        let currentHost = options.bool("current_host", default: false)
        let restart = options.stringList("restart")
        let useSudo = options.bool("sudo", default: false)
        for name in restart where name.isEmpty || name.contains("/") {
            options.error("'restart' takes process names such as Dock or Finder (got '\(name)')", key: "restart")
        }

        let values = preferenceValues(options, key: "set", domain: PreferenceDomain.normalized(domain), required: true)
        return DefaultsAction(domain: domain, currentHost: currentHost, values: values, restart: restart, useSudo: useSudo)
    }

    /// Reads a mapping of preference keys to values (shared with `dock: settings:`).
    static func preferenceValues(_ reader: MapReader, key: String, domain: String, required: Bool) -> [(key: String, value: PlistValue)] {
        guard let raw = reader.value(key) else {
            if required { reader.error("missing required key '\(key)' (the preferences to write, e.g. '\(key): {autohide: true}')") }
            return []
        }
        guard let map = raw.map, !map.isEmpty else {
            reader.error("'\(key)' must be a mapping of preference keys to values, e.g. '\(key): {autohide: true}'", key: key)
            return []
        }
        var values: [(key: String, value: PlistValue)] = []
        for entry in map.entries {
            guard let converted = PlistYAML.value(entry.value, path: "\(key).\(entry.key)", report: { reader.error($0, key: key) }) else { continue }
            values.append((entry.key, PlistYAML.applyingTypeHint(converted, domain: domain, key: entry.key, yaml: entry.value)))
        }
        return values
    }

    func validate(_ context: ValidationContext) -> [String] {
        Validation.unknownVariables(context, [("defaults", domain)])
            + values.flatMap { entry in
                entry.value.allStrings.flatMap { context.unknownVariableMessages(in: $0, field: "set.\(entry.key)") }
            }
    }

    /// The domain with variables and `~` expanded.
    func resolvedDomain(_ context: ActionContext) -> PreferenceDomain {
        let expanded = context.expand(domain)
        let name = Naming.looksLikePath(expanded) ? context.path(expanded).path : expanded
        return PreferenceDomain(name, currentHost: currentHost)
    }

    func wanted(_ context: ActionContext) -> [(key: String, value: PlistValue)] {
        values.map { ($0.key, $0.value.mapStrings(context.expand)) }
    }

    func check(_ context: ActionContext) async -> CheckResult {
        let domain = resolvedDomain(context)
        let current: [String: PlistValue]
        do {
            current = try await Preferences.store(for: context).read(domain)
        } catch {
            return .needed("could not read \(domain): \(InstallEngine.describe(error))")
        }
        let changes = Preferences.differences(current: current, wanted: wanted(context))
        if changes.isEmpty { return .satisfied(values.count == 1 ? "the value is set" : "all \(values.count) set") }
        return .needed("\(changes.count) of \(values.count) to change: \(changes.map(\.key).joined(separator: ", "))")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        let domain = resolvedDomain(context)
        let store = Preferences.store(for: context)
        let current = try await store.read(domain)
        let changes = Preferences.differences(current: current, wanted: wanted(context))
        guard !changes.isEmpty else { return .done("already set") }

        for change in changes {
            let before = current[change.key].map(\.description) ?? "unset"
            context.info("\(domain) \(change.key): \(before) → \(change.value)")
        }
        try await store.write(changes, to: domain, asRoot: useSudo)
        await ProcessRestarter().restart(restart, context: context)
        let verb = context.dryRun ? "would set" : "set"
        return .done("\(verb) \(counted(changes.count, "key")) in \(domain.name)")
    }
}
