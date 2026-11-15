import Foundation
import ShawnFun

extension Style {
    /// The shared sprite renderer's colour mode for output in this style: no colour (a pipe, `NO_COLOR`,
    /// `--no-color`) draws the silhouette in plain half blocks; otherwise 24-bit colour when the terminal
    /// has it, the 256-colour palette when not.
    var spriteColorMode: TerminalSpriteRenderer.ColorMode {
        guard enabled else { return .plain }
        return trueColor ? .trueColor : .ansi256
    }

    var spriteRenderer: TerminalSpriteRenderer { TerminalSpriteRenderer(colorMode: spriteColorMode) }
}

/// Banner, speech bubbles and line-ups, drawn with ShawnFun's sprite renderer and speech bubble in the
/// CLI's colours.
enum Painter {
    /// The ASCII header, shaded lavender → pink, or a one-line title when the terminal is too narrow.
    static func banner(_ header: String, style: Style, width: Int, tagline: String? = nil) -> [String] {
        let rows = header.components(separatedBy: "\n")
        let headerWidth = rows.map(TextWidth.of).max() ?? 0
        var lines: [String]
        if headerWidth > width {
            lines = [style.heading("✦ SHAWN'S DOTFILES ✦")]
        } else {
            lines = rows.enumerated().map { index, row in
                style.bold(style.fg(gradient(Palette.lavender, Palette.pink, step: index, of: rows.count), row))
            }
        }
        if let tagline, !tagline.isEmpty {
            lines.append(style.muted("  " + tagline))
        }
        return lines
    }

    static func gradient(_ from: RGBA, _ to: RGBA, step: Int, of count: Int) -> RGBA {
        guard count > 1 else { return from }
        let t = Double(step) / Double(count - 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(a) + (Double(b) - Double(a)) * t) }
        return RGBA(red: mix(from.red, to.red), green: mix(from.green, to.green), blue: mix(from.blue, to.blue))
    }

    /// A rounded speech bubble around `text` (wrapped to `maxWidth` columns): lavender frame, yellow words.
    static func bubble(_ text: String, maxWidth: Int, style: Style, tail: SpeechBubble.Tail = .none) -> [String] {
        let lines = SpeechBubble.render(text, maxTextWidth: max(12, maxWidth), tail: tail)
        // Rows are `[tail]╭──╮`, `[tail]│ words │` and `[tail]╰──╯`; only the words get the text colour.
        let frame = tail == .left ? 2 : 1
        return lines.enumerated().map { index, line in
            let characters = Array(line)
            guard index > 0, index < lines.count - 1, characters.count > frame + 1 else { return style.accent(line) }
            return style.accent(String(characters[..<frame])) + style.fg(Palette.star, String(characters[frame..<(characters.count - 1)]))
                + style.accent(String(characters[characters.count - 1]))
        }
    }

    /// A character with something to say: sprite on the left, bubble (tail pointing at it) on the right.
    static func speaking(_ sprite: Sprite?, says text: String, style: Style, width: Int) -> [String] {
        let art = sprite.map { style.spriteRenderer.render($0) } ?? []
        let artWidth = art.map(TerminalText.displayWidth).max() ?? 0
        let maxWidth = min(44, max(16, width - artWidth - 8))
        guard !art.isEmpty else { return bubble(text, maxWidth: maxWidth, style: style) }
        let lines = TerminalSpriteRenderer.sideBySide([art.map { "  " + $0 }, bubble(text, maxWidth: maxWidth, style: style, tail: .left)],
                                                      gap: 1, alignment: .center)
        return lines.map(trimTrailingSpaces)
    }

    /// Every sprite in a row (wrapping to the terminal width), names centred underneath on one baseline.
    static func lineUp(_ sprites: [Sprite], style: Style, width: Int, gap: Int = 3) -> [String] {
        let renderer = style.spriteRenderer
        let tiles: [[String]] = sprites.compactMap { sprite in
            let art = renderer.render(sprite)
            guard !art.isEmpty else { return nil }
            let artWidth = art.map(TerminalText.displayWidth).max() ?? 0
            return TerminalSpriteRenderer.captioned(art, style.accent(TextWidth.truncate(sprite.name, to: max(artWidth, 32))))
        }
        var output: [String] = []
        var row: [[String]] = []
        var used = 0
        func flush() {
            guard !row.isEmpty else { return }
            output += TerminalSpriteRenderer.sideBySide(row, gap: gap, alignment: .bottom).map { trimTrailingSpaces("  " + $0) }
            output.append("")
            row = []
            used = 0
        }
        for tile in tiles {
            let tileWidth = tile.map(TerminalText.displayWidth).max() ?? 0
            if !row.isEmpty, used + gap + tileWidth > width - 2 { flush() }
            used += (row.isEmpty ? 0 : gap) + tileWidth
            row.append(tile)
        }
        flush()
        return output
    }

    private static func trimTrailingSpaces(_ line: String) -> String {
        line.replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }
}
