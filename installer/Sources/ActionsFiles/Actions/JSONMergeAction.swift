import Foundation
import ShawnCore

/// `json-merge: ~/.claude/settings.json` deep-merges values into a JSON file without disturbing anything else:
/// existing keys keep their order and spelling, unknown keys are untouched, new keys are appended.
struct JSONMergeAction: Action {
    /// The JSON file to change (may use `~` and `{{vars}}`).
    let path: String
    /// Inline `values:` (strings may hold `{{vars}}`).
    let values: JSONObject?
    /// `from:` is a YAML or JSON file under `config/files/`.
    let from: String?
    let arrays: JSONArrayMerge
    let create: Bool

    var title: String { path }

    var subtitle: String? {
        var parts: [String] = []
        if let from { parts.append("from files/\(from)") }
        if let values { parts.append(counted(values.members.count, "value")) }
        if arrays == .union { parts.append("arrays: union") }
        return parts.joined(separator: " + ")
    }

    static let descriptor = ActionDescriptor(
        kind: "json-merge",
        summary: "Deep-merge settings into a JSON file, keeping its key order and every key it does not mention.",
        example: """
        - json-merge: ~/.claude/settings.json
          from: claude/settings.yaml       # YAML or JSON under config/files/, merged first
          values:                          # inline values, merged after 'from'
            theme: dark
            permissions: {allow: ["Bash(git diff:*)"]}
          arrays: union                    # replace (default) | union: append missing elements
          create: true                     # create the file if it is missing (default)
        """,
        make: { try make($0) }
    )

    private static func make(_ parser: ItemParser) throws -> any Action {
        let path = parser.primaryString()
        let options = parser.options
        let from = options.string("from")
        if let from, from.isEmpty { options.error("'from' must not be empty", key: "from") }

        var values: JSONObject?
        if let raw = options.value("values") {
            if raw.map != nil, let converted = JSONValue.fromYAML(raw, path: "values", report: { options.error($0, key: "values") }) {
                values = converted.object
            } else if raw.map == nil {
                options.error("'values' must be a mapping of keys to merge", key: "values")
            }
        }
        if from == nil && values == nil && !options.has("values") {
            options.error("needs 'values:' (inline settings) and/or 'from:' (a file under config/files/)")
        }
        let arrays = JSONArrayMerge(rawValue: options.oneOf("arrays", JSONArrayMerge.allCases.map(\.rawValue), default: "replace")) ?? .replace
        let create = options.bool("create", default: true)
        return JSONMergeAction(path: path, values: values, from: from, arrays: arrays, create: create)
    }

    func validate(_ context: ValidationContext) -> [String] {
        var problems = Validation.unknownVariables(context, [("json-merge", path), ("from", from)])
        if let values {
            problems += JSONValue.object(values).allStrings.flatMap { context.unknownVariableMessages(in: $0, field: "values") }
        }
        if let from {
            let relative = "files/" + context.vars.expand(from)
            if !context.configPathExists(relative) {
                problems.append("'from' file \(relative) does not exist in the config")
            } else {
                do {
                    let patch = try Self.loadPatch(context.config.url(relative))
                    problems += JSONValue.object(patch).allStrings.flatMap { context.unknownVariableMessages(in: $0, field: "files/\(from)") }
                } catch {
                    problems.append(InstallEngine.describe(error))
                }
            }
        }
        return problems
    }

    // MARK: Loading

    /// Reads the `from:` file: JSON when it ends in `.json`, YAML otherwise. Its top level must be a mapping.
    static func loadPatch(_ url: URL) throws -> JSONObject {
        let name = "files/" + url.lastPathComponent
        if url.pathExtension.lowercased() == "json" {
            guard let data = FileManager.default.contents(atPath: url.path) else {
                throw ActionError("cannot read \(name)")
            }
            let value: JSONValue
            do {
                value = try JSONParser.parse(data)
            } catch let error as JSONParseError {
                throw ActionError("\(name) is not valid JSON (\(error))", hint: "fix the file in the config")
            }
            guard let object = value.object else {
                throw ActionError("\(name) must contain a JSON object at the top level, not a \(value.typeName)")
            }
            return object
        }
        let yaml: YAMLValue?
        do {
            yaml = try YAML.parseFile(url, displayName: name)
        } catch {
            throw ActionError("\(error)", hint: "fix the file in the config")
        }
        guard let yaml, yaml.map != nil else {
            throw ActionError("\(name) must contain a mapping at the top level")
        }
        var problems: [String] = []
        let converted = JSONValue.fromYAML(yaml, path: "", report: { problems.append($0) })
        guard problems.isEmpty, let object = converted?.object else {
            throw ActionError("\(name): \(problems.joined(separator: "; "))")
        }
        return object
    }

    /// Everything to merge, with `{{vars}}` expanded: the `from` file first, then the inline values.
    func patch(_ context: ActionContext) throws -> JSONValue {
        var patch = JSONValue.object(JSONObject())
        if let from {
            let url = context.config.filesDirectory.appendingPathComponent(context.expand(from))
            guard context.files.exists(url) else {
                throw ActionError("files/\(from) is missing from the config", hint: "add it under config/files/ or fix 'from:'")
            }
            patch = patch.merging(.object(try Self.loadPatch(url)), arrays: arrays)
        }
        if let values {
            patch = patch.merging(.object(values), arrays: arrays)
        }
        return patch.mapStrings(context.expand)
    }

    struct Plan {
        /// The file actually written (a symlink is followed to its target).
        let target: URL
        let existed: Bool
        let existing: JSONValue
        let merged: JSONValue

        var changes: Bool { !existed || merged != existing }
    }

    /// Reads the current file and merges. Nil when the file is missing and `create` is false.
    func plan(_ context: ActionContext) throws -> Plan? {
        var target = context.path(path)
        if context.files.isSymlink(target), context.files.exists(target.resolvingSymlinksInPath()) {
            target = target.resolvingSymlinksInPath()
        }
        let patch = try patch(context)

        guard context.files.exists(target) else {
            guard create else { return nil }
            let created = JSONValue.object(JSONObject()).merging(patch, arrays: arrays)
            return Plan(target: target, existed: false, existing: .object(JSONObject()), merged: created)
        }
        guard !context.files.isDirectory(target), let data = FileManager.default.contents(atPath: target.path) else {
            throw ActionError("cannot read \(context.display(target))", hint: "it must be a readable JSON file")
        }
        let existing: JSONValue
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            existing = .object(JSONObject())
        } else {
            do {
                existing = try JSONParser.parse(data)
            } catch let error as JSONParseError {
                throw ActionError("\(context.display(target)) is not valid JSON (\(error)); it was left untouched",
                                  hint: "fix the file (or move it aside) and run this step again")
            }
        }
        guard existing.object != nil else {
            throw ActionError("\(context.display(target)) holds a JSON \(existing.typeName), not an object; it was left untouched",
                              hint: "settings files must be a JSON object ({ … })")
        }
        return Plan(target: target, existed: true, existing: existing, merged: existing.merging(patch, arrays: arrays))
    }

    // MARK: Check & run

    func check(_ context: ActionContext) async -> CheckResult {
        do {
            guard let plan = try plan(context) else {
                return .satisfied("\(path) does not exist and 'create' is false")
            }
            return plan.changes ? .needed(plan.existed ? "has settings to merge" : "file does not exist yet") : .satisfied("already merged")
        } catch {
            return .needed(InstallEngine.describe(error))
        }
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        guard let plan = try plan(context) else {
            return .skipped("\(path) does not exist and 'create' is false")
        }
        guard plan.changes else { return .done("already merged") }
        let permissions = plan.existed ? context.files.permissions(of: plan.target) : nil
        let change: FileChange
        do {
            change = try context.files.write(Data(plan.merged.rendered().utf8), to: plan.target, permissions: permissions, backup: true)
        } catch {
            throw context.fileError(error, doing: "write \(context.display(plan.target))")
        }
        return .done(context.describe(change, plan.target))
    }
}
