import Foundation

/// Why a document is not valid JSON, with a 1-based position.
struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    let message: String
    let line: Int
    let column: Int

    var description: String { "line \(line), column \(column): \(message)" }
}

/// A strict RFC 8259 parser that keeps object member order and number spelling.
/// No comments, no trailing commas, no single quotes: exactly what Claude Code itself accepts.
struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private static let maxDepth = 512

    private init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func parse(_ data: Data) throws -> JSONValue {
        var bytes = [UInt8](data)
        // A UTF-8 byte-order mark is not JSON, but some editors add one; it carries no content.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw JSONParseError(message: "the file is not UTF-8 text", line: 1, column: 1)
        }
        var parser = JSONParser(bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw parser.error("unexpected text after the end of the document")
        }
        return value
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    // MARK: Values

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < Self.maxDepth else { throw error("nested too deeply") }
        guard let byte = peek() else { throw error("unexpected end of file, expected a value") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectWord("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectWord("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectWord("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        case UInt8(ascii: "/"): throw error("comments are not allowed in JSON")
        case UInt8(ascii: "'"): throw error("strings must use double quotes")
        default: throw error("unexpected character '\(Self.printable(byte))'")
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                if peek() == UInt8(ascii: "}") { throw error("trailing comma before '}'") }
                throw error(peek() == nil ? "unexpected end of file inside an object" : "expected a key in double quotes")
            }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw error("expected ':' after key \"\(key)\"") }
            index += 1
            skipWhitespace()
            // A repeated key keeps its first position and takes the last value, as JSON.parse does.
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard let next = peek() else { throw error("unexpected end of file inside an object") }
            if next == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if next == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            if peek() == UInt8(ascii: "]") { throw error("trailing comma before ']'") }
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard let next = peek() else { throw error("unexpected end of file inside an array") }
            if next == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if next == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func parseNumber() throws -> JSONNumber {
        let start = index
        while let byte = peek(), Self.isNumberByte(byte) { index += 1 }
        let slice = Array(bytes[start..<index])
        guard JSONNumber.isValid(slice), let number = JSONNumber(literal: String(decoding: slice, as: UTF8.self)) else {
            index = start
            throw error("invalid number")
        }
        return number
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard let byte = peek() else { throw error("unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let text = String(bytes: buffer, encoding: .utf8) else { throw error("invalid UTF-8 in string") }
                return text
            case UInt8(ascii: "\\"):
                index += 1
                guard let escape = peek() else { throw error("unterminated string") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    let scalar = try parseUnicodeEscape()
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    index -= 1
                    throw error("invalid escape '\\\(Self.printable(escape))'")
                }
            default:
                if byte < 0x20 { throw error("control character inside a string (use \\n, \\t, …)") }
                buffer.append(byte)
                index += 1
            }
        }
    }

    /// Reads the four hex digits after `\u` (and a following low surrogate when needed).
    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
        let first = try readHex4()
        if (0xD800...0xDBFF).contains(first) {
            guard peek() == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else {
                throw error("unpaired surrogate \\u\(String(first, radix: 16)); this file cannot be rewritten without changing it")
            }
            index += 2
            let second = try readHex4()
            guard (0xDC00...0xDFFF).contains(second) else { throw error("invalid surrogate pair") }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else { throw error("invalid surrogate pair") }
            return scalar
        }
        guard !(0xDC00...0xDFFF).contains(first), let scalar = Unicode.Scalar(first) else {
            throw error("unpaired surrogate \\u\(String(first, radix: 16)); this file cannot be rewritten without changing it")
        }
        return scalar
    }

    private mutating func readHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("incomplete \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid \\u escape")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func expectWord(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw error("unexpected text, expected '\(word)'")
        }
        index += expected.count
    }

    // MARK: Helpers

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x65 || byte == 0x45
    }

    private static func printable(_ byte: UInt8) -> String {
        byte >= 0x20 && byte < 0x7F ? String(UnicodeScalar(byte)) : String(format: "\\x%02X", byte)
    }

    private func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        for byte in bytes[0..<min(index, bytes.count)] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return JSONParseError(message: message, line: line, column: column)
    }
}
