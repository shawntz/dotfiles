import Foundation
import ShawnCore

/// Measuring, padding and wrapping text for fixed-width (terminal or monospaced) output.
public enum TerminalText {
    /// How many terminal columns `text` occupies. Escape sequences take none, East Asian wide
    /// characters and emoji take two, everything else (including box drawing and block elements) one.
    public static func displayWidth(_ text: String) -> Int {
        ANSI.strip(text).reduce(0) { $0 + width(of: $1) }
    }

    /// `text` followed by enough spaces to fill `width` columns (unchanged when it is already that wide).
    public static func pad(_ text: String, toWidth width: Int) -> String {
        let missing = width - displayWidth(text)
        return missing > 0 ? text + String(repeating: " ", count: missing) : text
    }

    /// Greedy word wrap to at most `width` columns per line.
    ///
    /// Runs of spaces collapse to one, line breaks in `text` start a new line (blank lines are kept),
    /// and a word is only ever split when it is longer than a whole line on its own. Always returns
    /// at least one line. Meant for plain text: escape sequences are not kept intact.
    public static func wrap(_ text: String, width: Int) -> [String] {
        let width = max(1, width)
        var lines: [String] = []
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        for paragraph in paragraphs {
            var line = ""
            var lineWidth = 0
            for word in paragraph.split(whereSeparator: \.isWhitespace).map(String.init) {
                let wordWidth = displayWidth(word)
                if lineWidth > 0, lineWidth + 1 + wordWidth <= width {
                    line += " " + word
                    lineWidth += 1 + wordWidth
                    continue
                }
                if lineWidth > 0 {
                    lines.append(line)
                    line = ""
                    lineWidth = 0
                }
                if wordWidth <= width {
                    line = word
                    lineWidth = wordWidth
                    continue
                }
                for character in word {
                    let characterWidth = self.width(of: character)
                    if lineWidth > 0, lineWidth + characterWidth > width {
                        lines.append(line)
                        line = ""
                        lineWidth = 0
                    }
                    line.append(character)
                    lineWidth += characterWidth
                }
            }
            lines.append(line)
        }
        return lines
    }

    static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        switch first.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark:
            if scalars.count == 1 { return 0 }
        default:
            break
        }
        if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        if first.properties.isEmojiPresentation { return 2 }
        return isEastAsianWide(first.value) ? 2 : 1
    }

    private static func isEastAsianWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

/// A speech bubble drawn with rounded box-drawing characters:
///
///      ╭──────────────────╮
///     ─┤ Oh my glob, it's │
///      │ setup day!       │
///      ╰──────────────────╯
public enum SpeechBubble {
    /// Which side the tail sticks out of. `.left` points at a speaker standing to the left of the bubble.
    public enum Tail: Sendable {
        case none
        case left
        case right
    }

    /// The bubble's lines, all the same display width. Text is wrapped to `maxTextWidth` columns and
    /// the bubble shrinks to fit short text. A tail adds one column on its side; it sits on the middle
    /// text line (see `tailLine(textLineCount:)`). Plain text: color it afterward if needed.
    public static func render(_ text: String, maxTextWidth: Int = 36, tail: Tail = .left) -> [String] {
        let rows = TerminalText.wrap(text, width: maxTextWidth)
        let innerWidth = max(1, rows.map(TerminalText.displayWidth).max() ?? 0)
        let rule = String(repeating: "─", count: innerWidth + 2)
        let tailIndex = tailLine(textLineCount: rows.count)

        var lines = ["╭" + rule + "╮"]
        for (offset, row) in rows.enumerated() {
            let hasTail = offset + 1 == tailIndex
            let left = hasTail && tail == .left ? "┤" : "│"
            let right = hasTail && tail == .right ? "├" : "│"
            lines.append(left + " " + TerminalText.pad(row, toWidth: innerWidth) + " " + right)
        }
        lines.append("╰" + rule + "╯")

        switch tail {
        case .none:
            return lines
        case .left:
            return lines.enumerated().map { ($0.offset == tailIndex ? "─" : " ") + $0.element }
        case .right:
            return lines.enumerated().map { $0.element + ($0.offset == tailIndex ? "─" : " ") }
        }
    }

    /// Index (in the rendered lines, top border = 0) of the line that carries the tail.
    public static func tailLine(textLineCount: Int) -> Int {
        1 + (max(1, textLineCount) - 1) / 2
    }
}
