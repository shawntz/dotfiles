import Foundation
import ShawnCore

/// `git-config:` sets global git config keys from a mapping of keys to values.
struct GitConfigAction: Action {
    struct Entry: Equatable, Sendable {
        let key: String
        /// As written (may contain `{{vars}}`).
        let value: String
        /// YAML booleans are compared the way git reads them (`yes`, `on`, `1` all mean true).
        let isBool: Bool
    }

    let entries: [Entry]

    var title: String { "Git identity & settings" }

    var subtitle: String? {
        let keys = entries.map(\.key)
        let shown = keys.prefix(3).joined(separator: ", ")
        return keys.count > 3 ? "\(shown) +\(keys.count - 3) more" : shown
    }

    static let descriptor = ActionDescriptor(
        kind: "git-config",
        summary: "Sets global git config values (`git config --global`); already done when every value matches. "
            + "Nothing already there is lost: list keys (url.*.insteadOf, credential.helper, safe.directory, ...) get the value added, "
            + "a key someone set several times gets it added after the others, and an include (include.path, includeIf.*.path) "
            + "is kept at the very end of the file so the included file can override everything above it.",
        example: """
        - git-config:
            user.name: "{{full_name}}"
            user.email: "{{email}}"
            init.defaultBranch: main
            pull.rebase: true
        - git-config:
            include.path: ~/.gitconfig.local   # last, so this file overrides the settings above
        """
    ) { parser in
        guard let map = parser.primary.map, !map.isEmpty else {
            parser.fail("'git-config' must be a mapping of git keys to values, e.g. 'user.name: \"{{full_name}}\"'")
            return GitConfigAction(entries: [])
        }
        var entries: [Entry] = []
        for entry in map.entries {
            guard isValidKey(entry.key) else {
                parser.fail("'\(entry.key)' is not a git config key (expected section.name or section.subsection.name, e.g. user.email)")
                continue
            }
            guard let text = entry.value.string else {
                parser.fail("'\(entry.key)' must be a single value (text, number or true/false), not a \(entry.value.typeName)")
                continue
            }
            entries.append(Entry(key: entry.key, value: text, isBool: entry.value.bool != nil))
        }
        return GitConfigAction(entries: entries)
    }

    /// `section[.subsection].variable`: section and variable are alphanumeric/dash and start with a letter.
    static func isValidKey(_ key: String) -> Bool {
        guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: ".") else { return false }
        let section = key[key.startIndex..<firstDot]
        let variable = key[key.index(after: lastDot)...]
        func isName(_ part: Substring) -> Bool {
            guard let first = part.first, first.isASCII, first.isLetter else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return isName(section) && isName(variable)
    }

    func validate(_ context: ValidationContext) -> [String] {
        entries.flatMap { context.unknownVariableMessages(in: $0.value, field: $0.key) }
    }

    private static func normalizedBool(_ text: String) -> String {
        ["true", "yes", "on", "1"].contains(text.lowercased()) ? "true" : "false"
    }

    private func wantedValue(_ entry: Entry, _ context: ActionContext) -> String {
        entry.isBool ? Self.normalizedBool(entry.value) : context.expand(entry.value)
    }

    /// A setting (anything but an include) that does not read as wanted yet.
    private enum SettingChange {
        /// A single-valued key; `current` is every value it has now.
        case set(Entry, value: String, current: [String?])
        /// A list-valued key that lacks the value.
        case add(Entry, value: String)

        var entry: Entry {
            switch self {
            case .set(let entry, _, _), .add(let entry, _): return entry
            }
        }
    }

    /// An include that is missing, or has settings after it that it cannot override.
    private struct IncludeChange {
        let entry: Entry
        let path: String
        /// How the same file is already spelled under this key, earlier in the config.
        let earlier: [String]
    }

    private var includeEntries: [Entry] { entries.filter { GitGlobalConfig.isInclude($0.key) } }

    private func settingChanges(_ config: GitGlobalConfig, git: String, context: ActionContext) async -> [SettingChange] {
        var changes: [SettingChange] = []
        for entry in entries where !GitGlobalConfig.isInclude(entry.key) {
            let wanted = wantedValue(entry, context)
            let current = config.values(entry.key)
            if GitGlobalConfig.isList(entry.key) {
                if !current.contains(wanted) { changes.append(.add(entry, value: wanted)) }
                continue
            }
            // git reads the last value; booleans are compared the way git reads them (`yes` is true).
            let reads = entry.isBool && !current.isEmpty
                ? await GitTool.globalValue(entry.key, typed: "bool", git: git, context: context)
                : current.last ?? nil
            if reads != wanted { changes.append(.set(entry, value: wanted, current: current)) }
        }
        return changes
    }

    private func includeChanges(_ config: GitGlobalConfig, context: ActionContext) -> [IncludeChange] {
        let home = context.environment.home
        return includeEntries.compactMap { entry in
            let path = context.expand(entry.value)
            if config.includeIsLast(entry.key, path: path, home: home) { return nil }
            return IncludeChange(entry: entry, path: path, earlier: config.spellings(of: path, under: entry.key, home: home))
        }
    }

    func check(_ context: ActionContext) async -> CheckResult {
        guard let git = GitTool.locate(context.environment) else { return .needed("git is not installed yet") }
        let pending: [String]
        do {
            let config = try await GitGlobalConfig.read(git: git, context: context)
            pending = await settingChanges(config, git: git, context: context).map(\.entry.key)
                + includeChanges(config, context: context).map(\.entry.key)
        } catch {
            return .needed(InstallEngine.describe(error))
        }
        if pending.isEmpty { return .satisfied(entries.count == 1 ? "the value is already set" : "all \(entries.count) values already set") }
        return .needed("\(pending.count) of \(entries.count) to set: \(pending.joined(separator: ", "))")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        guard let git = GitTool.locate(context.environment) else {
            if let outcome = DryRun.whenMissing("git", would: "set the global git config", context) { return outcome }
            throw GitTool.missingError(for: "git config")
        }
        var changed: [String] = []
        for change in try await settingChanges(GitGlobalConfig.read(git: git, context: context), git: git, context: context) {
            switch change {
            case .set(let entry, let value, let current):
                try await GitGlobalConfig.set(entry.key, to: value, current: current, git: git, context: context)
            case .add(let entry, let value):
                try await GitGlobalConfig.add(entry.key, value, git: git, context: context)
            }
            changed.append(change.entry.key)
        }
        if !includeEntries.isEmpty {
            // Read again: a setting written just now may have opened a new section after an include.
            let file = context.display(GitGlobalConfig.writeTarget(context.environment, files: context.files))
            for change in try await includeChanges(GitGlobalConfig.read(git: git, context: context), context: context) {
                context.info(change.earlier.isEmpty
                    ? "adding \(change.entry.key) \(change.path) at the end of \(file)"
                    : "moving \(change.entry.key) \(change.path) to the end of \(file), so it overrides the settings written after it")
                try await GitGlobalConfig.moveIncludeToEnd(change.entry.key, path: change.path, earlier: change.earlier, git: git, context: context)
                changed.append(change.entry.key)
            }
        }
        return .done(changed.isEmpty ? "already set" : "set \(changed.joined(separator: ", "))")
    }
}
