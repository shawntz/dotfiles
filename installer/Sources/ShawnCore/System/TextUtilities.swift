import Foundation

public enum Shell {
    /// Quotes one argument for display or for embedding in a `/bin/sh` command line.
    public static func quote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+=:,./@%~")
        if argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}

public enum ANSI {
    // CSI sequences (colors, cursor movement), OSC sequences (titles, hyperlinks) and stray two-byte escapes.
    private static let pattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]",
        options: []
    )

    /// Removes terminal escape sequences so output can be shown as plain text.
    public static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}

/// Splits a byte stream into lines, treating a bare carriage return as a
/// progress update that the next line should overwrite.
public struct LineBuffer: Sendable {
    public struct Line: Equatable, Sendable {
        public let text: String
        /// True when the line ended with a bare `\r` (a progress bar frame).
        public let isProgress: Bool

        public init(text: String, isProgress: Bool) {
            self.text = text
            self.isProgress = isProgress
        }
    }

    private var pending: [UInt8] = []
    private var sawCarriageReturn = false

    public init() {}

    public mutating func append(_ data: Data) -> [Line] {
        var lines: [Line] = []
        for byte in data {
            if sawCarriageReturn {
                sawCarriageReturn = false
                if byte == 0x0A {
                    lines.append(makeLine(isProgress: false))
                    continue
                }
                lines.append(makeLine(isProgress: true))
            }
            switch byte {
            case 0x0A:
                lines.append(makeLine(isProgress: false))
            case 0x0D:
                sawCarriageReturn = true
            default:
                pending.append(byte)
            }
        }
        return lines
    }

    /// Emits whatever is left once the stream has ended.
    public mutating func flush() -> [Line] {
        let hadCarriageReturn = sawCarriageReturn
        sawCarriageReturn = false
        if pending.isEmpty { return [] }
        return [makeLine(isProgress: hadCarriageReturn)]
    }

    private mutating func makeLine(isProgress: Bool) -> Line {
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return Line(text: text, isProgress: isProgress)
    }
}
