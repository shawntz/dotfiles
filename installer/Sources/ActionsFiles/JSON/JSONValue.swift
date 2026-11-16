import Foundation
import ShawnCore

/// A JSON number kept as the exact text it was written with, so `1.0` or `1e3` in someone's
/// settings file come back out unchanged. Equality is numeric (`1` equals `1.0`).
struct JSONNumber: Equatable, Sendable, CustomStringConvertible {
    let literal: String

    /// Accepts only RFC 8259 number syntax: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
    init?(literal: String) {
        guard JSONNumber.isValid(Array(literal.utf8)) else { return nil }
        self.literal = literal
    }

    init(_ value: Int) {
        literal = String(value)
    }

    /// Nil for infinities and NaN, which JSON cannot represent.
    init?(_ value: Double) {
        guard value.isFinite else { return nil }
        let text = value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        guard JSONNumber.isValid(Array(text.utf8)) else { return nil }
        literal = text
    }

    var description: String { literal }

    /// The exact value as significant digits × 10^exponent, with no leading or trailing zeros in `digits`
    /// (zero is `digits: []`). Two literals are the same number exactly when their values are equal, at any length:
    /// `Decimal` keeps only 38 digits, so longer numbers that differ further along would compare equal.
    private struct ExactValue: Equatable {
        let negative: Bool
        let digits: ArraySlice<UInt8>
        let exponent: Int
    }

    /// Nil only for an exponent too large for `Int`; such literals are compared as written.
    private var exactValue: ExactValue? {
        let bytes = Array(literal.utf8)
        var index = 0
        let negative = bytes.first == UInt8(ascii: "-")
        if negative { index += 1 }
        var digits: [UInt8] = []
        var fractionDigits = 0
        var inFraction = false
        while index < bytes.count, bytes[index] != UInt8(ascii: "e"), bytes[index] != UInt8(ascii: "E") {
            if bytes[index] == UInt8(ascii: ".") {
                inFraction = true
            } else {
                digits.append(bytes[index])
                if inFraction { fractionDigits += 1 }
            }
            index += 1
        }
        var exponent = 0
        if index < bytes.count {
            guard let written = Int(String(decoding: bytes[(index + 1)...], as: UTF8.self)) else { return nil }
            exponent = written
        }
        let (shifted, overflow) = exponent.subtractingReportingOverflow(fractionDigits)
        guard !overflow else { return nil }
        let leading = digits.firstIndex(where: { $0 != UInt8(ascii: "0") }) ?? digits.count
        var significant = digits[leading...]
        guard !significant.isEmpty else { return ExactValue(negative: false, digits: [], exponent: 0) }
        var trailingZeros = 0
        while significant.last == UInt8(ascii: "0") {
            significant.removeLast()
            trailingZeros += 1
        }
        let (scaled, overflowed) = shifted.addingReportingOverflow(trailingZeros)
        guard !overflowed else { return nil }
        return ExactValue(negative: negative, digits: significant, exponent: scaled)
    }

    static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        if lhs.literal == rhs.literal { return true }
        guard let left = lhs.exactValue, let right = rhs.exactValue else { return false }
        return left == right
    }

    static func isValid(_ bytes: [UInt8]) -> Bool {
        var index = 0
        func digit(_ at: Int) -> Bool { at < bytes.count && bytes[at] >= 0x30 && bytes[at] <= 0x39 }
        if index < bytes.count && bytes[index] == 0x2D { index += 1 }
        guard digit(index) else { return false }
        if bytes[index] == 0x30 {
            index += 1
        } else {
            while digit(index) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 0x2E {
            index += 1
            guard digit(index) else { return false }
            while digit(index) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }
            guard digit(index) else { return false }
            while digit(index) { index += 1 }
        }
        return index == bytes.count
    }
}

/// JSON compares text code point by code point. Swift's `==` on strings treats canonically equivalent text as equal
/// ("é" precomposed and "e" + combining accent), which would merge two distinct keys of a file into one.
private func sameText(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
}

/// A JSON object whose members keep the order they were written in.
struct JSONObject: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var key: String
        var value: JSONValue

        static func == (lhs: Member, rhs: Member) -> Bool {
            sameText(lhs.key, rhs.key) && lhs.value == rhs.value
        }
    }

    private(set) var members: [Member]

    init(_ members: [Member] = []) {
        self.members = members
    }

    init(_ pairs: KeyValuePairs<String, JSONValue>) {
        members = pairs.map { Member(key: $0.key, value: $0.value) }
    }

    var keys: [String] { members.map(\.key) }
    var isEmpty: Bool { members.isEmpty }

    /// Setting an existing key replaces its value in place; a new key goes at the end. Keys match code point by code point.
    subscript(key: String) -> JSONValue? {
        get { members.first(where: { sameText($0.key, key) })?.value }
        set {
            if let index = members.firstIndex(where: { sameText($0.key, key) }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }
}

/// A JSON document that round-trips: key order, number spelling and every key we do not
/// know about survive a read-modify-write.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    /// Exact, as written: member order counts, numbers compare by value, text code point by code point.
    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let left), .bool(let right)): return left == right
        case (.number(let left), .number(let right)): return left == right
        case (.string(let left), .string(let right)): return sameText(left, right)
        case (.array(let left), .array(let right)): return left == right
        case (.object(let left), .object(let right)): return left == right
        default: return false
        }
    }

    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    var object: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// Equality as JSON means it: objects compare as unordered maps, numbers by value.
    func sameJSON(as other: JSONValue) -> Bool {
        switch (self, other) {
        case (.object(let left), .object(let right)):
            guard left.members.count == right.members.count else { return false }
            for member in left.members {
                guard let match = right[member.key], member.value.sameJSON(as: match) else { return false }
            }
            return true
        case (.array(let left), .array(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { $0.sameJSON(as: $1) }
        default:
            return self == other
        }
    }

    /// Every string value inside, in document order (keys excluded).
    var allStrings: [String] {
        switch self {
        case .string(let text): return [text]
        case .array(let values): return values.flatMap(\.allStrings)
        case .object(let object): return object.members.flatMap(\.value.allStrings)
        default: return []
        }
    }

    /// The same value with `transform` applied to every string (not to keys).
    func mapStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let text): return .string(transform(text))
        case .array(let values): return .array(values.map { $0.mapStrings(transform) })
        case .object(let object):
            return .object(JSONObject(object.members.map { JSONObject.Member(key: $0.key, value: $0.value.mapStrings(transform)) }))
        default: return self
        }
    }
}

// MARK: - Merging

/// How `json-merge` treats an array that exists on both sides.
enum JSONArrayMerge: String, Sendable, CaseIterable {
    /// The new array replaces the old one.
    case replace
    /// Elements not already present are appended, in order; nothing is removed.
    case union
}

extension JSONValue {
    /// Deep-merges `patch` into `self`. Existing keys keep their position, new keys are appended,
    /// and a value that is already equal (as JSON) is left exactly as it was written.
    func merging(_ patch: JSONValue, arrays: JSONArrayMerge) -> JSONValue {
        switch (self, patch) {
        case (.object(let existing), .object(let incoming)):
            var result = existing
            for member in incoming.members {
                if let current = result[member.key] {
                    result[member.key] = current.merging(member.value, arrays: arrays)
                } else {
                    result[member.key] = member.value
                }
            }
            return .object(result)
        case (.array(let existing), .array(let incoming)) where arrays == .union:
            var result = existing
            for element in incoming where !result.contains(where: { $0.sameJSON(as: element) }) {
                result.append(element)
            }
            return .array(result)
        default:
            return sameJSON(as: patch) ? self : patch
        }
    }
}

// MARK: - From YAML

extension JSONValue {
    /// Converts YAML (from the config) to JSON. YAML numbers keep their spelling when it is valid JSON.
    /// Problems are passed to `report` with a path such as `permissions.allow[2]`.
    static func fromYAML(_ yaml: YAMLValue, path: String, report: (String) -> Void) -> JSONValue? {
        switch yaml {
        case .scalar(let scalar):
            switch scalar.kind {
            case .null: return .null
            case .bool(let flag): return .bool(flag)
            case .int(let number): return .number(JSONNumber(literal: scalar.raw) ?? JSONNumber(number))
            case .double(let number):
                if let literal = JSONNumber(literal: scalar.raw) { return .number(literal) }
                guard let converted = JSONNumber(number) else {
                    report("'\(path)' is \(scalar.raw), which JSON cannot represent")
                    return nil
                }
                return .number(converted)
            case .string: return .string(scalar.raw)
            }
        case .list(let values):
            var result: [JSONValue] = []
            var ok = true
            for (index, value) in values.enumerated() {
                if let converted = fromYAML(value, path: "\(path)[\(index)]", report: report) { result.append(converted) } else { ok = false }
            }
            return ok ? .array(result) : nil
        case .map(let map):
            var object = JSONObject()
            var ok = true
            for entry in map.entries {
                let childPath = path.isEmpty ? entry.key : "\(path).\(entry.key)"
                if let converted = fromYAML(entry.value, path: childPath, report: report) { object[entry.key] = converted } else { ok = false }
            }
            return ok ? .object(object) : nil
        }
    }
}

// MARK: - Printing

extension JSONValue {
    /// Pretty-printed like `JSON.stringify(value, null, 2)` plus a final newline: two-space indent,
    /// `"key": value`, forward slashes and non-ASCII text left as they are.
    func rendered() -> String {
        var output = ""
        write(to: &output, indent: 0)
        output.append("\n")
        return output
    }

    private func write(to output: inout String, indent: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let number): output += number.literal
        case .string(let text): JSONValue.writeString(text, to: &output)
        case .array(let values):
            guard !values.isEmpty else { output += "[]"; return }
            let inner = String(repeating: " ", count: indent + 2)
            output += "[\n"
            for (index, value) in values.enumerated() {
                output += inner
                value.write(to: &output, indent: indent + 2)
                output += index == values.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: " ", count: indent) + "]"
        case .object(let object):
            guard !object.isEmpty else { output += "{}"; return }
            let inner = String(repeating: " ", count: indent + 2)
            output += "{\n"
            for (index, member) in object.members.enumerated() {
                output += inner
                JSONValue.writeString(member.key, to: &output)
                output += ": "
                member.value.write(to: &output, indent: indent + 2)
                output += index == object.members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: " ", count: indent) + "}"
        }
    }

    private static func writeString(_ text: String, to output: inout String) {
        output.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append("\"")
    }
}
