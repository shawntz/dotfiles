import Foundation
import ShawnCore

/// Draws pixel art in a terminal with Unicode half blocks.
///
/// Each text cell shows two pixels stacked vertically: `▀` painted with the upper pixel as the
/// foreground color and the lower pixel as the background. Terminal cells are about twice as tall as
/// they are wide, so one column per pixel keeps the art square: a 16×16 sprite is 16 columns × 8 rows.
///
/// Every function is pure and returns lines without newlines. A line assumes the terminal's default
/// colors when it starts and resets them (`ESC[0m`) at its end if it changed them, so lines can be
/// printed one by one or placed next to other text safely.
public struct TerminalSpriteRenderer: Sendable {
    public enum ColorMode: String, Sendable, CaseIterable {
        /// 24-bit color escapes (`ESC[38;2;r;g;bm`).
        case trueColor = "truecolor"
        /// The xterm 256-color palette (`ESC[38;5;nm`), for terminals without 24-bit color.
        case ansi256 = "256"
        /// No escape sequences: the silhouette in half blocks, for pipes, log files and `NO_COLOR`.
        case plain

        /// Picks a mode for a terminal: `plain` when output is not a terminal, `NO_COLOR` is set to
        /// anything but the empty string (https://no-color.org) or `TERM` is `dumb`; `trueColor` when
        /// the terminal says it supports it (`COLORTERM=truecolor|24bit`, a `*-direct` `TERM`, or a
        /// terminal known to support it); otherwise `ansi256`.
        public static func detect(environment: [String: String], isTerminal: Bool) -> ColorMode {
            guard isTerminal else { return .plain }
            if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return .plain }
            let term = environment["TERM"]?.lowercased() ?? ""
            if term == "dumb" { return .plain }
            let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
            if colorTerm == "truecolor" || colorTerm == "24bit" { return .trueColor }
            if term.hasSuffix("-direct") || term.hasSuffix("-truecolor") { return .trueColor }
            // Herdr's terminals present themselves as ghostty (and set COLORTERM=truecolor).
            let trueColorTerminals: Set<String> = ["iterm.app", "wezterm", "ghostty", "vscode"]
            if trueColorTerminals.contains(environment["TERM_PROGRAM"]?.lowercased() ?? "") { return .trueColor }
            return .ansi256
        }
    }

    /// Where shorter blocks sit when blocks of different heights are placed side by side.
    public enum Alignment: Sendable {
        case top
        case center
        case bottom
    }

    /// Pixels with less alpha than this are drawn as transparent (the terminal's own background shows).
    /// Everything else is drawn at full strength, because a terminal cannot blend.
    public static let opaqueAlphaThreshold: UInt8 = 128

    public var colorMode: ColorMode
    /// Each sprite pixel becomes `scale`×`scale` pixels, so the art grows without changing shape.
    public var scale: Int

    public init(colorMode: ColorMode = .trueColor, scale: Int = 1) {
        self.colorMode = colorMode
        self.scale = max(1, scale)
    }

    // MARK: Sprites

    /// The frame as text lines, `width × scale` columns wide and `ceil(height × scale / 2)` lines tall.
    ///
    /// An odd number of pixel rows gets a transparent row added at the TOP, so the art always stands
    /// on the bottom edge of its last line and sprites of any height line up when bottom-aligned.
    public func render(_ frame: SpriteFrame) -> [String] {
        let source = scale > 1 ? frame.scaled(by: scale) : frame
        let width = source.width
        guard width > 0, source.height > 0 else { return [] }

        var rows: [[TerminalColor?]] = source.pixels.map { row in
            (0..<width).map { column in column < row.count ? paint(row[column]) : nil }
        }
        if rows.count % 2 == 1 {
            rows.insert([TerminalColor?](repeating: nil, count: width), at: 0)
        }
        return stride(from: 0, to: rows.count, by: 2).map { line(upper: rows[$0], lower: rows[$0 + 1]) }
    }

    /// Frame `frame` of the sprite (wrapping around, so an ever-increasing tick counter animates it).
    /// Empty for a sprite that only has an image file: a terminal cannot show that.
    public func render(_ sprite: Sprite, frame: Int = 0) -> [String] {
        guard !sprite.frames.isEmpty else { return [] }
        return render(sprite.frames[Self.frameIndex(frame, count: sprite.frames.count)])
    }

    /// Several sprites in a row, bottom-aligned, `gap` columns apart, optionally with each name
    /// centered underneath.
    public func renderRow(_ sprites: [Sprite], frame: Int = 0, gap: Int = 2, captions: Bool = false) -> [String] {
        let blocks = sprites.map { sprite -> [String] in
            let lines = render(sprite, frame: frame)
            return captions ? Self.captioned(lines, sprite.name) : lines
        }
        return Self.sideBySide(blocks, gap: gap)
    }

    // MARK: Speech

    /// `spriteLines` with a speech bubble saying `text` to its right, the bubble's tail pointing at the
    /// sprite and both centered on each other vertically. `bubbleColor` tints the bubble and its text
    /// (ignored in `plain` mode). With no sprite lines, just the bubble without a tail.
    public func speaking(_ spriteLines: [String], says text: String, maxTextWidth: Int = 36, gap: Int = 1,
                         bubbleColor: RGBA? = nil) -> [String] {
        let bubble = SpeechBubble.render(text, maxTextWidth: maxTextWidth, tail: spriteLines.isEmpty ? .none : .left)
        let tinted = bubbleColor.map { color in bubble.map { colored($0, color) } } ?? bubble
        guard !spriteLines.isEmpty else { return tinted }
        return Self.sideBySide([spriteLines, tinted], gap: gap, alignment: .center)
    }

    /// The sprite (frame `frame`) saying `text`. Without a sprite, or for an image-only sprite,
    /// just the bubble.
    public func speaking(_ sprite: Sprite?, frame: Int = 0, says text: String, maxTextWidth: Int = 36, gap: Int = 1,
                         bubbleColor: RGBA? = nil) -> [String] {
        let lines = sprite.map { render($0, frame: frame) } ?? []
        return speaking(lines, says: text, maxTextWidth: maxTextWidth, gap: gap, bubbleColor: bubbleColor)
    }

    /// `text` in the given foreground color (unchanged in `plain` mode), reset at the end.
    public func colored(_ text: String, _ color: RGBA) -> String {
        guard colorMode != .plain, let code = paint(RGBA(red: color.red, green: color.green, blue: color.blue))?.foregroundCode else {
            return text
        }
        return "\u{1B}[\(code)m" + text + "\u{1B}[0m"
    }

    // MARK: Layout

    /// Places blocks of lines next to each other, `gap` columns apart. Every block is padded to its
    /// widest line (measured without escape sequences) and shorter blocks get blank lines per
    /// `alignment`, so every output line has the same display width.
    public static func sideBySide(_ blocks: [[String]], gap: Int = 2, alignment: Alignment = .bottom) -> [String] {
        let blocks = blocks.filter { !$0.isEmpty }
        guard let height = blocks.map(\.count).max() else { return [] }
        let separator = String(repeating: " ", count: max(0, gap))
        let columns = blocks.map { block -> [String] in
            let width = block.map(TerminalText.displayWidth).max() ?? 0
            let blank = String(repeating: " ", count: width)
            let missing = height - block.count
            let above: Int
            switch alignment {
            case .top: above = 0
            case .center: above = missing / 2
            case .bottom: above = missing
            }
            return Array(repeating: blank, count: above)
                + block.map { TerminalText.pad($0, toWidth: width) }
                + Array(repeating: blank, count: missing - above)
        }
        return (0..<height).map { row in columns.map { $0[row] }.joined(separator: separator) }
    }

    /// The block with `caption` centered on a new line underneath. When the caption is wider than
    /// the block, the block is centered over the caption instead.
    public static func captioned(_ block: [String], _ caption: String) -> [String] {
        let blockWidth = block.map(TerminalText.displayWidth).max() ?? 0
        let captionWidth = TerminalText.displayWidth(caption)
        let width = max(blockWidth, captionWidth)
        let indent = String(repeating: " ", count: (width - blockWidth) / 2)
        let lines = block.map { TerminalText.pad(indent + $0, toWidth: width) }
        let captionLine = String(repeating: " ", count: (width - captionWidth) / 2) + caption
        return lines + [TerminalText.pad(captionLine, toWidth: width)]
    }

    // MARK: Colors

    /// Nearest color in the xterm 256-color palette (the 6×6×6 cube or the 24-step gray ramp).
    public static func ansi256Index(for color: RGBA) -> Int {
        let levels = [0, 95, 135, 175, 215, 255]
        func cubeStep(_ value: UInt8) -> Int {
            let value = Int(value)
            if value < 48 { return 0 }
            if value < 115 { return 1 }
            return (value - 35) / 40
        }
        let red = cubeStep(color.red), green = cubeStep(color.green), blue = cubeStep(color.blue)
        let cube = (levels[red], levels[green], levels[blue])

        let average = (Int(color.red) + Int(color.green) + Int(color.blue)) / 3
        let grayStep = min(23, max(0, (average - 3) / 10))
        let gray = 8 + grayStep * 10

        func distance(_ other: (Int, Int, Int)) -> Int {
            let dr = Int(color.red) - other.0, dg = Int(color.green) - other.1, db = Int(color.blue) - other.2
            return dr * dr + dg * dg + db * db
        }
        if distance((gray, gray, gray)) < distance(cube) { return 232 + grayStep }
        return 16 + 36 * red + 6 * green + blue
    }

    static func frameIndex(_ frame: Int, count: Int) -> Int {
        ((frame % count) + count) % count
    }

    /// The color a pixel is drawn with in this mode, or nil when it is transparent here.
    private func paint(_ pixel: RGBA?) -> TerminalColor? {
        guard let pixel, pixel.alpha >= Self.opaqueAlphaThreshold else { return nil }
        switch colorMode {
        case .trueColor: return .rgb(pixel.red, pixel.green, pixel.blue)
        case .ansi256: return .indexed(Self.ansi256Index(for: pixel))
        case .plain: return .plain
        }
    }

    /// One text line from two pixel rows. Color codes are only emitted when they change.
    private func line(upper: [TerminalColor?], lower: [TerminalColor?]) -> String {
        if colorMode == .plain {
            return String(zip(upper, lower).map { top, bottom -> Character in
                switch (top != nil, bottom != nil) {
                case (false, false): return " "
                case (true, false): return "▀"
                case (false, true): return "▄"
                case (true, true): return "█"
                }
            })
        }

        var text = ""
        var foreground: TerminalColor?
        var background: TerminalColor?
        var changedAttributes = false
        for (top, bottom) in zip(upper, lower) {
            // nil = this cell does not care; .some(nil) = the terminal's default background.
            let glyph: Character
            let wantForeground: TerminalColor?
            let wantBackground: TerminalColor??
            switch (top, bottom) {
            case (nil, nil):
                (glyph, wantForeground, wantBackground) = (" ", nil, .some(nil))
            case let (top?, nil):
                (glyph, wantForeground, wantBackground) = ("▀", top, .some(nil))
            case let (nil, bottom?):
                (glyph, wantForeground, wantBackground) = ("▄", bottom, .some(nil))
            case let (top?, bottom?) where top == bottom:
                // A space on a colored background fills the whole cell; no glyph edges, no contrast tweaks.
                (glyph, wantForeground, wantBackground) = (" ", nil, .some(top))
            case let (top?, bottom?):
                (glyph, wantForeground, wantBackground) = ("▀", top, .some(bottom))
            }

            var codes: [String] = []
            if let wantForeground, wantForeground != foreground {
                codes.append(wantForeground.foregroundCode)
                foreground = wantForeground
            }
            if let wantBackground, wantBackground != background {
                codes.append(wantBackground?.backgroundCode ?? "49")
                background = wantBackground
            }
            if !codes.isEmpty {
                text += "\u{1B}[" + codes.joined(separator: ";") + "m"
                changedAttributes = true
            }
            text.append(glyph)
        }
        if changedAttributes { text += "\u{1B}[0m" }
        return text
    }
}

/// A color as the terminal will show it, so pixels that map to the same palette entry compare equal.
private enum TerminalColor: Equatable {
    case rgb(UInt8, UInt8, UInt8)
    case indexed(Int)
    case plain

    var foregroundCode: String {
        switch self {
        case let .rgb(red, green, blue): return "38;2;\(red);\(green);\(blue)"
        case let .indexed(index): return "38;5;\(index)"
        case .plain: return "39"
        }
    }

    var backgroundCode: String {
        switch self {
        case let .rgb(red, green, blue): return "48;2;\(red);\(green);\(blue)"
        case let .indexed(index): return "48;5;\(index)"
        case .plain: return "49"
        }
    }
}

extension SpriteFrame {
    /// Every pixel repeated `factor` times across and down (nearest neighbor). Short rows are
    /// padded with transparent pixels to the frame's width.
    public func scaled(by factor: Int) -> SpriteFrame {
        let factor = max(1, factor)
        let width = self.width
        var rows: [[RGBA?]] = []
        rows.reserveCapacity(height * factor)
        for row in pixels {
            var wide: [RGBA?] = []
            wide.reserveCapacity(width * factor)
            for column in 0..<width {
                let pixel = column < row.count ? row[column] : nil
                wide.append(contentsOf: repeatElement(pixel, count: factor))
            }
            rows.append(contentsOf: repeatElement(wide, count: factor))
        }
        return SpriteFrame(pixels: rows)
    }
}
