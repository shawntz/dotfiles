import Darwin
import Foundation
import ShawnFun

/// What the CLI knows about where its output is going.
///
/// Everything that decides between "pretty" and "plain" output reads this one value, so tests
/// construct it directly instead of depending on whatever terminal happens to run them.
struct Terminal: Sendable, Equatable {
    var stdoutIsTTY: Bool
    var stderrIsTTY: Bool
    var stdinIsTTY: Bool
    /// Columns available on stdout.
    var width: Int
    /// Colour on stdout.
    var color: Bool
    /// Colour on stderr (notes, update lines).
    var stderrColor: Bool
    /// 24-bit colour escapes are understood (otherwise the 256-colour palette is used).
    var trueColor: Bool

    /// No TTY, no colour: what tests and log files see.
    static func plain(width: Int = 80) -> Terminal {
        Terminal(stdoutIsTTY: false, stderrIsTTY: false, stdinIsTTY: false, width: width, color: false, stderrColor: false, trueColor: false)
    }

    /// Looks at the real file descriptors and the environment.
    ///
    /// Colour follows the usual conventions: `NO_COLOR` (any non-empty value) or `--no-color` turn it off,
    /// `TERM=dumb` turns it off, `CLICOLOR_FORCE`/`FORCE_COLOR` turn it on even without a TTY, otherwise
    /// a stream gets colour only when it is a terminal.
    static func detect(environment: [String: String], noColorFlag: Bool) -> Terminal {
        let stdoutTTY = isatty(STDOUT_FILENO) == 1
        let stderrTTY = isatty(STDERR_FILENO) == 1
        let stdinTTY = isatty(STDIN_FILENO) == 1
        let policy = ColorPolicy(environment: environment, noColorFlag: noColorFlag)
        return Terminal(
            stdoutIsTTY: stdoutTTY,
            stderrIsTTY: stderrTTY,
            stdinIsTTY: stdinTTY,
            width: measureWidth(environment: environment, stdoutIsTTY: stdoutTTY, stderrIsTTY: stderrTTY),
            color: policy.allows(tty: stdoutTTY),
            stderrColor: policy.allows(tty: stderrTTY),
            trueColor: Self.supportsTrueColor(environment)
        )
    }

    static func supportsTrueColor(_ environment: [String: String]) -> Bool {
        let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
        if colorTerm == "truecolor" || colorTerm == "24bit" { return true }
        // Terminals that support 24-bit colour but do not always export COLORTERM.
        let program = environment["TERM_PROGRAM"] ?? ""
        return ["ghostty", "iTerm.app", "WezTerm", "vscode", "Herdr"].contains(program)
    }

    static func measureWidth(environment: [String: String], stdoutIsTTY: Bool, stderrIsTTY: Bool) -> Int {
        var size = winsize()
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] where (descriptor == STDOUT_FILENO ? stdoutIsTTY : stderrIsTTY) {
            if ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        }
        if let columns = environment["COLUMNS"].flatMap(Int.init), columns > 0 { return columns }
        return 80
    }

    /// The style used for stdout.
    var style: Style { Style(enabled: color, trueColor: trueColor) }
    /// The style used for stderr.
    var errorStyle: Style { Style(enabled: stderrColor, trueColor: trueColor) }
}

struct ColorPolicy: Equatable {
    var forcedOff: Bool
    var forcedOn: Bool

    init(environment: [String: String], noColorFlag: Bool) {
        let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
        let dumb = environment["TERM"] == "dumb"
        forcedOff = noColorFlag || noColor || dumb
        let force = environment["CLICOLOR_FORCE"] ?? environment["FORCE_COLOR"] ?? ""
        forcedOn = !force.isEmpty && force != "0"
    }

    func allows(tty: Bool) -> Bool {
        if forcedOff { return false }
        return forcedOn || tty
    }
}

/// The house colours: a CRT from a universe where Lumpy Space is real.
enum Palette {
    static let lavender = RGBA(red: 0xB5, green: 0x7E, blue: 0xDC)
    static let pink = RGBA(red: 0xFF, green: 0x8A, blue: 0xD8)
    static let star = RGBA(red: 0xFF, green: 0xE6, blue: 0x6D)
    static let mint = RGBA(red: 0x7C, green: 0xF2, blue: 0xB0)
    static let sky = RGBA(red: 0x7F, green: 0xD6, blue: 0xFF)
    static let orange = RGBA(red: 0xFF, green: 0xA6, blue: 0x5C)
    static let red = RGBA(red: 0xFF, green: 0x6B, blue: 0x6B)
    static let dim = RGBA(red: 0x8A, green: 0x82, blue: 0x99)
}

/// Wraps text in ANSI escapes, or returns it untouched when colour is off.
struct Style: Sendable, Equatable {
    var enabled: Bool
    var trueColor: Bool

    static let off = Style(enabled: false, trueColor: false)

    func fg(_ color: RGBA, _ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        return "\(Self.foreground(color, trueColor: trueColor))\(text)\u{1B}[39m"
    }

    func bold(_ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        return "\u{1B}[1m\(text)\u{1B}[22m"
    }

    func italic(_ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        return "\u{1B}[3m\(text)\u{1B}[23m"
    }

    // Semantic shorthands used across commands.
    func accent(_ text: String) -> String { fg(Palette.lavender, text) }
    func ok(_ text: String) -> String { fg(Palette.mint, text) }
    func warn(_ text: String) -> String { fg(Palette.star, text) }
    func bad(_ text: String) -> String { fg(Palette.red, text) }
    func muted(_ text: String) -> String { fg(Palette.dim, text) }
    func heading(_ text: String) -> String { bold(fg(Palette.pink, text)) }

    static func foreground(_ color: RGBA, trueColor: Bool) -> String {
        if trueColor { return "\u{1B}[38;2;\(color.red);\(color.green);\(color.blue)m" }
        return "\u{1B}[38;5;\(xterm256(color))m"
    }

    static func background(_ color: RGBA, trueColor: Bool) -> String {
        if trueColor { return "\u{1B}[48;2;\(color.red);\(color.green);\(color.blue)m" }
        return "\u{1B}[48;5;\(xterm256(color))m"
    }

    /// Nearest entry of the xterm 6×6×6 colour cube (or the grey ramp for greys).
    static func xterm256(_ color: RGBA) -> Int {
        let r = Int(color.red), g = Int(color.green), b = Int(color.blue)
        if abs(r - g) < 10 && abs(g - b) < 10 {
            let grey = (r + g + b) / 3
            if grey < 8 { return 16 }
            if grey > 238 { return 231 }
            return 232 + (grey - 8) * 24 / 231
        }
        func level(_ value: Int) -> Int { value < 48 ? 0 : value < 115 ? 1 : (value - 35) / 40 }
        return 16 + 36 * level(r) + 6 * level(g) + level(b)
    }
}

/// Measuring and fitting text that may contain ANSI escapes.
enum TextWidth {
    /// Columns `text` occupies on screen (escapes ignored, wide characters count twice).
    static func of(_ text: String) -> Int {
        var width = 0
        for character in ANSIText.strip(text) {
            width += columns(of: character)
        }
        return width
    }

    static func columns(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark || $0.value == 0xFE0F || $0.value == 0x200D }) { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            return 2
        default:
            return 1
        }
    }

    static func pad(_ text: String, to width: Int) -> String {
        let current = of(text)
        return current >= width ? text : text + String(repeating: " ", count: width - current)
    }

    /// Cuts plain text to `width` columns, ending with an ellipsis when something was cut.
    static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if of(text) <= width { return text }
        var result = ""
        var used = 0
        for character in text {
            let columns = columns(of: character)
            if used + columns > width - 1 { break }
            result.append(character)
            used += columns
        }
        return result + "…"
    }

    /// Greedy word wrap of plain text.
    static func wrap(_ text: String, width: Int) -> [String] {
        let limit = max(8, width)
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                if line.isEmpty {
                    line = word
                } else if of(line) + 1 + of(word) <= limit {
                    line += " " + word
                } else {
                    lines.append(line)
                    line = word
                }
                while of(line) > limit {
                    let head = String(line.prefix(limit))
                    lines.append(head)
                    line = String(line.dropFirst(limit))
                }
            }
            lines.append(line)
        }
        return lines
    }
}

/// ANSI stripping that also understands the 38;2 / 48;2 sequences this module emits.
enum ANSIText {
    private static let pattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)")

    static func strip(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
