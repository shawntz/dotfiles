import Foundation
import ShawnCore

/// `config/cli.yaml`: the CLI's own settings and the commands defined in YAML.
///
///     self_update: { mode: always|daily|off, skip: [command, ...] }
///     add:         { <kind>: steps/NN-file.yaml, ... }      # where `shawn add <kind>` writes
///     upgrade:     [ { name, run, if }, ... ]               # what `shawn upgrade` runs
///     statusline:  { quips: [...] }                          # short lines for `shawn statusline`
///     commands:    { <name>: { section, summary, usage, help, update, update_timeout, env, exec | run } }
struct CLIConfig: Sendable {
    static let fileName = "cli.yaml"

    enum SelfUpdateMode: String, Sendable, CaseIterable {
        case always
        case daily
        case off
    }

    struct SelfUpdate: Sendable, Equatable {
        var mode: SelfUpdateMode = .always
        /// Commands that never trigger the self-update check (on top of `Dispatcher.neverSelfUpdate`).
        var skip: [String] = []
    }

    struct AddTarget: Sendable, Equatable {
        var kind: String
        /// Step file relative to the config root.
        var file: String
        var source: SourceRef
    }

    struct UpgradeStep: Sendable, Equatable {
        var name: String
        /// Bash script.
        var run: String
        /// Bash condition; the step is skipped unless it exits 0 (e.g. `command -v mas`).
        var condition: String?
    }

    enum ExecPart: Sendable, Equatable {
        case text(String)
        /// A mapping (or any value) passed to the tool as ONE argument of compact JSON.
        case json(YAMLValue)
    }

    enum Action: Sendable, Equatable {
        /// Replace the shawn process with this command line (the user's arguments are appended).
        case exec([ExecPart])
        /// A bash script; the user's arguments are `"$@"`.
        case run(String)
    }

    struct EnvironmentEntry: Sendable, Equatable {
        var name: String
        var value: String
    }

    struct Command: Sendable, Equatable {
        var name: String
        var section: String
        var summary: String
        /// Argument synopsis shown after the name, e.g. `<port>`.
        var usage: String?
        /// Longer description for `shawn help <name>` and `-h`.
        var help: String?
        /// Shell command run before `exec` (unless `--no-update` / `SHAWN_NO_UPDATE=1`).
        var update: String?
        var updateTimeout: TimeInterval
        var environment: [EnvironmentEntry]
        var action: Action
        var source: SourceRef
    }

    static let defaultSection = "Commands"
    static let defaultUpdateTimeout: TimeInterval = 45

    var selfUpdate = SelfUpdate()
    var add: [AddTarget] = []
    var upgrade: [UpgradeStep] = []
    var statuslineQuips: [String] = []
    var commands: [Command] = []

    init() {}

    func command(named name: String) -> Command? {
        commands.first { $0.name == name }
    }

    func addTarget(for kind: String) -> AddTarget? {
        add.first { $0.kind == kind }
    }

    // MARK: Loading

    /// Loads `cli.yaml` from the config directory. A missing file is an empty config, not a problem.
    static func load(from config: InstallerConfig) -> (config: CLIConfig, issues: [ConfigIssue]) {
        do {
            return parse(try config.loadYAML(fileName), file: fileName)
        } catch let error as YAMLParseError {
            return (CLIConfig(), [.error(error.message, at: SourceRef(file: error.file, line: error.line))])
        } catch {
            return (CLIConfig(), [.error(String(describing: error), at: SourceRef(file: fileName))])
        }
    }

    static func parse(_ value: YAMLValue?, file: String) -> (config: CLIConfig, issues: [ConfigIssue]) {
        var result = CLIConfig()
        guard let value else { return (result, []) }
        let collector = IssueCollector()
        guard let map = value.map else {
            collector.add(.error("cli.yaml must be a mapping with 'commands' (and optionally self_update, add, upgrade, statusline)", at: SourceRef(file: file)))
            return (result, collector.issues)
        }
        let reader = MapReader(map: map, source: SourceRef(file: file), context: "cli", collector: collector)

        if let selfUpdate = reader.reader("self_update") {
            let mode = selfUpdate.oneOf("mode", SelfUpdateMode.allCases.map(\.rawValue), default: SelfUpdateMode.always.rawValue)
            result.selfUpdate.mode = SelfUpdateMode(rawValue: mode) ?? .always
            result.selfUpdate.skip = selfUpdate.stringList("skip")
            selfUpdate.finish()
        }

        for pair in reader.stringPairs("add") {
            let line = map["add"]?.map?.line(of: pair.key) ?? map.line(of: "add")
            result.add.append(AddTarget(kind: pair.key, file: pair.value, source: SourceRef(file: file, line: line)))
        }

        for step in reader.readers("upgrade") {
            let name = step.requiredString("name")
            let run = step.requiredString("run")
            let condition = step.string("if")
            step.finish()
            if !name.isEmpty, !run.isEmpty {
                result.upgrade.append(UpgradeStep(name: name, run: run, condition: condition))
            }
        }

        if let statusline = reader.reader("statusline") {
            result.statuslineQuips = statusline.stringList("quips")
            statusline.finish()
        }

        if let commands = reader.value("commands") {
            if let commandMap = commands.map {
                for entry in commandMap.entries {
                    if let command = parseCommand(entry, file: file, collector: collector) {
                        result.commands.append(command)
                    }
                }
            } else if !commands.isNull {
                reader.error("'commands' must be a mapping of command name → definition, not a \(commands.typeName)", key: "commands")
            }
        }
        reader.finish()
        return (result, collector.issues)
    }

    private static func parseCommand(_ entry: YAMLMap.Entry, file: String, collector: IssueCollector) -> Command? {
        let source = SourceRef(file: file, line: entry.line)
        let name = entry.key
        guard let map = entry.value.map else {
            collector.add(.error("command '\(name)' must be a mapping with 'summary' and 'exec' or 'run', not a \(entry.value.typeName)", at: source))
            return nil
        }
        let reader = MapReader(map: map, source: source, context: "command '\(name)'", collector: collector)
        if name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) == nil {
            collector.add(.error("command name '\(name)' may only contain lowercase letters, digits and dashes", at: source))
        }
        let section = reader.string("section", default: defaultSection)
        let summary = reader.requiredString("summary")
        let usage = reader.string("usage")
        let help = reader.string("help")
        let update = reader.string("update")
        var updateTimeout = defaultUpdateTimeout
        if let seconds = reader.int("update_timeout") {
            if seconds > 0 {
                updateTimeout = TimeInterval(seconds)
            } else {
                reader.error("'update_timeout' must be a positive number of seconds", key: "update_timeout")
            }
        }
        let environment = reader.stringPairs("env").map { EnvironmentEntry(name: $0.key, value: $0.value) }

        var action: Action?
        let hasExec = map.contains("exec"), hasRun = map.contains("run")
        if hasExec && hasRun {
            reader.error("use either 'exec' or 'run', not both", key: "run")
        }
        if hasExec {
            action = parseExec(reader: reader, map: map)
        } else if hasRun {
            let script = reader.requiredString("run")
            if !script.isEmpty { action = .run(script) }
        } else {
            reader.error("needs 'exec' (a command line to launch) or 'run' (a bash script)")
        }
        reader.finish()
        guard let action, !summary.isEmpty else { return nil }
        return Command(name: name, section: section, summary: summary, usage: usage, help: help, update: update,
                       updateTimeout: updateTimeout, environment: environment, action: action, source: source)
    }

    private static func parseExec(reader: MapReader, map: YAMLMap) -> Action? {
        let elements: [YAMLValue]
        if let single = map["exec"]?.string {
            // `exec: htop` is a fine shorthand for a one-element list.
            _ = reader.value("exec")
            elements = [.string(single)]
        } else {
            elements = reader.list("exec")
        }
        guard !elements.isEmpty else {
            if map["exec"]?.list != nil { reader.error("'exec' must not be empty", key: "exec") }
            return nil
        }
        var parts: [ExecPart] = []
        for (index, element) in elements.enumerated() {
            if let text = element.string {
                parts.append(.text(text))
            } else if let nested = element.map, nested.count == 1, let json = nested["json"] {
                if index == 0 {
                    reader.error("the first element of 'exec' must be the program to run, not a json value", key: "exec")
                }
                parts.append(.json(json))
            } else {
                reader.error("'exec' element \(index + 1) must be a string or a single-key mapping 'json: <value>', not a \(element.typeName)", key: "exec")
            }
        }
        guard case .text(let program)? = parts.first, !program.isEmpty else { return nil }
        return .exec(parts)
    }

    // MARK: Validation against the rest of the config

    /// Problems that need the whole config and the item kinds to see: `add:` kinds and files, commands
    /// hidden behind built-ins, unknown `{{variables}}`.
    func validate(config: InstallerConfig, registry: ActionRegistry, builtinNames: Set<String>, vars: TemplateVars) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        for target in add {
            if registry.descriptor(for: target.kind) == nil {
                issues.append(.error("add: '\(target.kind)' is not an item kind (known kinds: \(registry.kinds.joined(separator: ", ")))", at: target.source))
            }
            if !FileManager.default.fileExists(atPath: config.url(target.file).path) {
                issues.append(.error("add: \(target.kind) → \(target.file) does not exist", at: target.source))
            }
        }
        var known = vars
        known["shawn_bin"] = "shawn"
        for command in commands {
            if builtinNames.contains(command.name) {
                issues.append(.warning("command '\(command.name)' is hidden by the built-in command of the same name", at: command.source))
            }
            var texts: [String] = []
            if let update = command.update { texts.append(update) }
            if case .exec(let parts) = command.action {
                for part in parts {
                    if case .text(let text) = part { texts.append(text) } else if case .json(let value) = part { texts.append(JSONText.encode(value)) }
                }
            }
            for name in Set(texts.flatMap { known.unknownVariables(in: $0) }).sorted() {
                issues.append(.error("command '\(command.name)' uses unknown variable {{\(name)}}", at: command.source))
            }
        }
        return issues
    }
}

/// Compact JSON for YAML values, keeping the author's key order (so the argument is stable and readable).
enum JSONText {
    static func encode(_ value: YAMLValue, vars: TemplateVars? = nil) -> String {
        var output = ""
        write(value, vars: vars, into: &output)
        return output
    }

    private static func write(_ value: YAMLValue, vars: TemplateVars?, into output: inout String) {
        switch value {
        case .scalar(let scalar):
            switch scalar.kind {
            case .null: output += "null"
            case .bool(let flag): output += flag ? "true" : "false"
            case .int(let number): output += String(number)
            case .double(let number):
                output += number.isFinite ? (number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)) : "null"
            case .string: output += quote(vars?.expand(scalar.raw) ?? scalar.raw)
            }
        case .list(let values):
            output += "["
            for (index, element) in values.enumerated() {
                if index > 0 { output += "," }
                write(element, vars: vars, into: &output)
            }
            output += "]"
        case .map(let map):
            output += "{"
            for (index, entry) in map.entries.enumerated() {
                if index > 0 { output += "," }
                output += quote(entry.key)
                output += ":"
                write(entry.value, vars: vars, into: &output)
            }
            output += "}"
        }
    }

    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
