import Foundation
import Yams

// MARK: - Scalars

/// A YAML scalar that remembers its exact source text.
///
/// Keeping `raw` around means `mode: 0644`, `version: 1.10` and `brew: 7zip`
/// can always be read back as the text the author typed, regardless of how
/// YAML's implicit typing resolved them.
public struct YAMLScalar: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string
    }

    public let raw: String
    public let kind: Kind

    public init(raw: String, kind: Kind) {
        self.raw = raw
        self.kind = kind
    }

    public static func string(_ value: String) -> YAMLScalar { .init(raw: value, kind: .string) }
    public static func bool(_ value: Bool) -> YAMLScalar { .init(raw: value ? "true" : "false", kind: .bool(value)) }
    public static func int(_ value: Int) -> YAMLScalar { .init(raw: String(value), kind: .int(value)) }
    public static func double(_ value: Double) -> YAMLScalar { .init(raw: String(value), kind: .double(value)) }
    public static let null = YAMLScalar(raw: "", kind: .null)

    public var description: String { raw }
}

// MARK: - Maps

/// An ordered string-keyed map (YAML mapping). Key order is preserved because
/// it is meaningful to people editing the files (and to things like `git config`).
public struct YAMLMap: Equatable, Sendable {
    public struct Entry: Sendable {
        public let key: String
        public var value: YAMLValue
        /// 1-based line of the key in the source file, when known.
        public let line: Int?

        public init(key: String, value: YAMLValue, line: Int? = nil) {
            self.key = key
            self.value = value
            self.line = line
        }
    }

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public init(_ pairs: [(String, YAMLValue)]) {
        self.entries = pairs.map { Entry(key: $0.0, value: $0.1) }
    }

    public var keys: [String] { entries.map(\.key) }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public subscript(key: String) -> YAMLValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    entries[index].value = newValue
                } else {
                    entries.remove(at: index)
                }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }

    public func contains(_ key: String) -> Bool { entries.contains { $0.key == key } }

    public func line(of key: String) -> Int? { entries.first(where: { $0.key == key })?.line }

    /// A copy without the given keys.
    public func removing(_ keys: Set<String>) -> YAMLMap {
        YAMLMap(entries.filter { !keys.contains($0.key) })
    }

    /// Value equality ignores source line numbers.
    public static func == (lhs: YAMLMap, rhs: YAMLMap) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for (left, right) in zip(lhs.entries, rhs.entries) where left.key != right.key || left.value != right.value {
            return false
        }
        return true
    }
}

// MARK: - Values

public enum YAMLValue: Equatable, Sendable {
    case scalar(YAMLScalar)
    case list([YAMLValue])
    case map(YAMLMap)

    public static let null: YAMLValue = .scalar(.null)
    public static func string(_ value: String) -> YAMLValue { .scalar(.string(value)) }
    public static func bool(_ value: Bool) -> YAMLValue { .scalar(.bool(value)) }
    public static func int(_ value: Int) -> YAMLValue { .scalar(.int(value)) }
    public static func double(_ value: Double) -> YAMLValue { .scalar(.double(value)) }

    public var isNull: Bool {
        if case .scalar(let scalar) = self, case .null = scalar.kind { return true }
        return false
    }

    /// The source text of any non-null scalar (numbers and booleans included).
    public var string: String? {
        guard case .scalar(let scalar) = self else { return nil }
        if case .null = scalar.kind { return nil }
        return scalar.raw
    }

    public var bool: Bool? {
        if case .scalar(let scalar) = self, case .bool(let value) = scalar.kind { return value }
        return nil
    }

    public var int: Int? {
        if case .scalar(let scalar) = self, case .int(let value) = scalar.kind { return value }
        return nil
    }

    /// Doubles, and integers widened to a double.
    public var double: Double? {
        guard case .scalar(let scalar) = self else { return nil }
        switch scalar.kind {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var list: [YAMLValue]? {
        if case .list(let values) = self { return values }
        return nil
    }

    public var map: YAMLMap? {
        if case .map(let map) = self { return map }
        return nil
    }

    /// A list of scalars, or a single scalar promoted to a one-element list.
    public var stringList: [String]? {
        switch self {
        case .scalar:
            if isNull { return [] }
            return string.map { [$0] }
        case .list(let values):
            var result: [String] = []
            for value in values {
                guard let text = value.string else { return nil }
                result.append(text)
            }
            return result
        case .map:
            return nil
        }
    }

    /// Human-readable type name for error messages.
    public var typeName: String {
        switch self {
        case .scalar(let scalar):
            switch scalar.kind {
            case .null: return "null"
            case .bool: return "boolean"
            case .int: return "integer"
            case .double: return "number"
            case .string: return "string"
            }
        case .list: return "list"
        case .map: return "mapping"
        }
    }

    /// Converts to Foundation objects suitable for `JSONSerialization` / property lists.
    /// Booleans become `NSNumber(value: Bool)` so they serialize as true/false.
    public func foundationObject() -> Any {
        switch self {
        case .scalar(let scalar):
            switch scalar.kind {
            case .null: return NSNull()
            case .bool(let value): return NSNumber(value: value)
            case .int(let value): return NSNumber(value: value)
            case .double(let value): return NSNumber(value: value)
            case .string: return scalar.raw
            }
        case .list(let values):
            return values.map { $0.foundationObject() }
        case .map(let map):
            var dictionary: [String: Any] = [:]
            for entry in map.entries { dictionary[entry.key] = entry.value.foundationObject() }
            return dictionary
        }
    }
}

// MARK: - Parsing

public struct YAMLParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int?
    public let message: String

    public init(file: String, line: Int?, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }

    public var description: String {
        if let line { return "\(file):\(line): \(message)" }
        return "\(file): \(message)"
    }
}

public enum YAML {
    /// Parses a single YAML document. Returns nil for an empty document.
    public static func parse(_ text: String, file: String = "<yaml>") throws -> YAMLValue? {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch let error as YamlError {
            throw YAMLParseError(file: file, line: line(of: error), message: describe(error))
        } catch {
            throw YAMLParseError(file: file, line: nil, message: String(describing: error))
        }
        guard let node else { return nil }
        return try convert(node, file: file)
    }

    public static func parseFile(_ url: URL, displayName: String? = nil) throws -> YAMLValue? {
        let name = displayName ?? url.lastPathComponent
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw YAMLParseError(file: name, line: nil, message: "cannot read file: \(error.localizedDescription)")
        }
        return try parse(text, file: name)
    }

    private static func convert(_ node: Node, file: String) throws -> YAMLValue {
        switch node {
        case .scalar(let scalar):
            return .scalar(convert(scalar, tag: Resolver.default.resolveTag(of: node)))
        case .sequence(let sequence):
            return .list(try sequence.map { try convert($0, file: file) })
        case .mapping(let mapping):
            var entries: [YAMLMap.Entry] = []
            var seen = Set<String>()
            entries.reserveCapacity(mapping.count)
            for (keyNode, valueNode) in mapping {
                guard case .scalar(let keyScalar) = keyNode else {
                    throw YAMLParseError(file: file, line: keyNode.mark?.line, message: "mapping keys must be plain strings")
                }
                let key = keyScalar.string
                guard seen.insert(key).inserted else {
                    throw YAMLParseError(file: file, line: keyNode.mark?.line, message: "duplicate key '\(key)'")
                }
                entries.append(.init(key: key, value: try convert(valueNode, file: file), line: keyNode.mark?.line))
            }
            return .map(YAMLMap(entries))
        case .alias:
            throw YAMLParseError(file: file, line: node.mark?.line, message: "YAML aliases are not supported here")
        }
    }

    private static func convert(_ scalar: Node.Scalar, tag: Tag.Name) -> YAMLScalar {
        // Only plain (unquoted) scalars get implicit typing; anything quoted or
        // written as a block scalar is a string, period.
        guard scalar.style == .plain || scalar.style == .any else {
            return .string(scalar.string)
        }
        switch tag {
        case .null:
            return YAMLScalar(raw: scalar.string, kind: .null)
        case .bool:
            if let value = Bool.construct(from: scalar) { return YAMLScalar(raw: scalar.string, kind: .bool(value)) }
        case .int:
            if let value = Int.construct(from: scalar) { return YAMLScalar(raw: scalar.string, kind: .int(value)) }
        case .float:
            if let value = Double.construct(from: scalar) { return YAMLScalar(raw: scalar.string, kind: .double(value)) }
        default:
            break
        }
        return .string(scalar.string)
    }

    private static func line(of error: YamlError) -> Int? {
        switch error {
        case .scanner(_, _, let mark, _), .parser(_, _, let mark, _), .composer(_, _, let mark, _):
            return mark.line
        case .duplicatedKeysInMapping(_, let context):
            return context.mark.line
        default:
            return nil
        }
    }

    private static func describe(_ error: YamlError) -> String {
        switch error {
        case .scanner(let context, let problem, _, _),
             .parser(let context, let problem, _, _),
             .composer(let context, let problem, _, _):
            if let context { return "\(problem) (\(context.text))" }
            return problem
        case .duplicatedKeysInMapping(let duplicates, _):
            return "duplicate key(s): \(duplicates.joined(separator: ", "))"
        default:
            return String(describing: error)
        }
    }
}
