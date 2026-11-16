import Foundation
import ShawnCore

/// A property-list value with its exact type, so `true`, `1` and `1.0` stay different things.
/// Preferences are compared with these, never as text.
enum PlistValue: Equatable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case real(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dict([String: PlistValue])

    /// Converts what `PropertyListSerialization` returns. Booleans are told apart from numbers by their CF type.
    init?(foundation value: Any) {
        switch value {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let date as Date:
            self = .date(date)
        case let data as Data:
            self = .data(data)
        case let array as [Any]:
            var result: [PlistValue] = []
            for element in array {
                guard let converted = PlistValue(foundation: element) else { return nil }
                result.append(converted)
            }
            self = .array(result)
        case let dictionary as [String: Any]:
            var result: [String: PlistValue] = [:]
            for (key, element) in dictionary {
                guard let converted = PlistValue(foundation: element) else { return nil }
                result[key] = converted
            }
            self = .dict(result)
        default:
            return nil
        }
    }

    /// The Foundation object `PropertyListSerialization` writes with the same type (a bool becomes `<true/>`, a real `<real>`).
    var foundationObject: Any {
        switch self {
        case .bool(let flag): return NSNumber(value: flag)
        case .int(let number): return NSNumber(value: number)
        case .real(let number): return NSNumber(value: number)
        case .string(let text): return text
        case .date(let date): return date
        case .data(let data): return data
        case .array(let values): return values.map(\.foundationObject)
        case .dict(let values): return values.mapValues(\.foundationObject)
        }
    }

    var dict: [String: PlistValue]? {
        if case .dict(let values) = self { return values }
        return nil
    }

    var array: [PlistValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var int: Int? {
        if case .int(let number) = self { return number }
        return nil
    }

    /// Every string inside the value, depth first.
    var allStrings: [String] {
        switch self {
        case .string(let text): return [text]
        case .array(let values): return values.flatMap(\.allStrings)
        case .dict(let values): return values.keys.sorted().flatMap { values[$0]?.allStrings ?? [] }
        default: return []
        }
    }

    /// The same value with `transform` applied to every string (for `{{vars}}`).
    func mapStrings(_ transform: (String) -> String) -> PlistValue {
        switch self {
        case .string(let text): return .string(transform(text))
        case .array(let values): return .array(values.map { $0.mapStrings(transform) })
        case .dict(let values): return .dict(values.mapValues { $0.mapStrings(transform) })
        default: return self
        }
    }

    /// Short text for log lines: `true`, `128.0 (float)`, `"scale"`, `[6 items]`.
    var description: String {
        switch self {
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .real(let number): return "\(PlistValue.format(number)) (float)"
        case .string(let text): return "\"\(text)\""
        case .date(let date): return ISO8601DateFormatter().string(from: date)
        case .data(let data): return "<\(data.count) bytes>"
        case .array(let values): return "[\(counted(values.count, "item"))]"
        case .dict(let values): return "{\(counted(values.count, "key"))}"
        }
    }

    /// True when this value, read from a Mac, already is the wanted `value`: equal with its type, except for a real
    /// left by `defaults write -float` or by an app that stores a Float. Those keep only 32 bits (0.15 reads back as
    /// 0.15000000596046448); asking for the exact double would rewrite the key, and restart whatever reads it, on
    /// every run. So a real that is exactly a Float counts as the wanted one when both round to the same Float. Any
    /// other double was written at full precision, so it is compared exactly.
    func satisfies(_ value: PlistValue) -> Bool {
        switch (self, value) {
        case (.real(let current), .real(let wanted)):
            if current == wanted { return true }
            let single = Float(current)
            // Beyond Float's range both sides become infinity; such values are compared exactly.
            return single.isFinite && Double(single) == current && single == Float(wanted)
        case (.array(let current), .array(let wanted)):
            return current.count == wanted.count && zip(current, wanted).allSatisfy { $0.satisfies($1) }
        case (.dict(let current), .dict(let wanted)):
            return current.count == wanted.count && wanted.allSatisfy { key, value in current[key]?.satisfies(value) == true }
        default:
            return self == value
        }
    }

    /// `128.0` → `128`, `0.15` → `0.15`: the shortest spelling that reads back as the same double.
    static func format(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }

    /// Serializes a dictionary as a property list.
    static func encode(_ values: [String: PlistValue], format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values.mapValues(\.foundationObject), format: format, options: 0)
    }

    /// Parses a property list whose top level is a dictionary.
    static func decodeDictionary(_ data: Data) throws -> [String: PlistValue] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let converted = PlistValue(foundation: object), case .dict(let values) = converted else {
            throw ActionError("the preferences data is not a dictionary")
        }
        return values
    }
}

// MARK: - From YAML

enum PlistYAML {
    static let forcedTypes = ["bool", "int", "float", "string"]

    /// Converts a YAML value from the config: booleans, integers, floats, strings, lists and maps map to
    /// their plist types; `{type: float, value: 128}` forces one of bool/int/float/string.
    /// Problems go to `report`, phrased with `path` (e.g. `set.tilesize`).
    static func value(_ yaml: YAMLValue, path: String, report: (String) -> Void) -> PlistValue? {
        switch yaml {
        case .scalar(let scalar):
            switch scalar.kind {
            case .null:
                report("'\(path)' has no value (preferences cannot store null)")
                return nil
            case .bool(let flag): return .bool(flag)
            case .int(let number): return .int(number)
            case .double(let number): return .real(number)
            case .string: return .string(scalar.raw)
            }
        case .list(let values):
            var result: [PlistValue] = []
            var ok = true
            for (index, element) in values.enumerated() {
                if let converted = value(element, path: "\(path)[\(index)]", report: report) { result.append(converted) } else { ok = false }
            }
            return ok ? .array(result) : nil
        case .map(let map):
            if Set(map.keys) == ["type", "value"] {
                return forced(map, path: path, report: report)
            }
            var result: [String: PlistValue] = [:]
            var ok = true
            for entry in map.entries {
                if let converted = value(entry.value, path: "\(path).\(entry.key)", report: report) { result[entry.key] = converted } else { ok = false }
            }
            return ok ? .dict(result) : nil
        }
    }

    private static func forced(_ map: YAMLMap, path: String, report: (String) -> Void) -> PlistValue? {
        guard let type = map["type"]?.string, forcedTypes.contains(type) else {
            report("'\(path).type' must be one of \(forcedTypes.joined(separator: ", "))")
            return nil
        }
        guard let raw = map["value"], let text = raw.string else {
            report("'\(path).value' must be a single value")
            return nil
        }
        switch type {
        case "bool":
            if let flag = raw.bool { return .bool(flag) }
            switch text.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: break
            }
        case "int":
            if let number = raw.int ?? Int(text) { return .int(number) }
        case "float":
            if let number = raw.double ?? Double(text), number.isFinite { return .real(number) }
        default:
            return .string(text)
        }
        report("'\(path).value' (\(text)) is not a valid \(type)")
        return nil
    }

    /// Keys macOS stores as floats. Written as a plain integer in YAML (`tilesize: 128`) they become reals,
    /// so the value matches what the system writes and the item stays satisfied.
    static let floatKeys: [String: Set<String>] = [
        "com.apple.dock": ["tilesize", "largesize", "autohide-delay", "autohide-time-modifier", "expose-animation-duration"],
        "NSGlobalDomain": ["com.apple.sound.beep.volume", "com.apple.springing.delay", "com.apple.trackpad.scaling",
                           "com.apple.mouse.scaling", "com.apple.scrollwheel.scaling", "NSWindowResizeTime"],
        "com.apple.screensaver": ["askForPasswordDelay"],
    ]

    /// Applies `floatKeys` to a value parsed from a plain YAML integer.
    static func applyingTypeHint(_ value: PlistValue, domain: String, key: String, yaml: YAMLValue) -> PlistValue {
        guard yaml.int != nil, case .int(let number) = value, floatKeys[domain]?.contains(key) == true else { return value }
        return .real(Double(number))
    }
}
