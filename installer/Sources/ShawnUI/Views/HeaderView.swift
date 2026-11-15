import AppKit
import CoreText
import SwiftUI

/// Measurements for drawing ASCII art so rows of block and box-drawing characters touch.
///
/// The font's own line height leaves a gap between rows (`█` is 1 em tall but lines are ~1.18 em
/// apart), so the art is drawn with CoreText at a row pitch equal to the full-block glyph's height,
/// with each baseline placed so the block fills its row exactly.
struct ASCIIArtMetrics: Equatable {
    let lines: [String]
    let columns: Int

    /// Height of `█` and the distance from its top to the baseline, as fractions of the point size.
    static let blockCell: (height: CGFloat, ascent: CGFloat) = {
        let font = Theme.nsMono(100) as CTFont
        var characters = Array("█".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        if CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) {
            var bounds = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &bounds, 1)
            if bounds.height > 50 { return (bounds.height / 100, bounds.maxY / 100) }
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        return ((ascent + descent) / 100, ascent / 100)
    }()

    init(text: String) {
        let raw = text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        var lines = raw
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        self.lines = lines.isEmpty ? [""] : lines
        columns = max(1, self.lines.map(\.count).max() ?? 1)
    }

    var rows: Int { lines.count }

    /// A one-line header with no block or box-drawing art (the built-in fallback): drawn bold and
    /// twice as large, since it has no art to fill the space.
    var isPlainTitle: Bool {
        rows == 1 && !lines[0].unicodeScalars.contains { (0x2500...0x259F).contains($0.value) }
    }

    /// The largest point size that fits `width` × `maxHeight`, capped at `maxFontSize`.
    func fontSize(width: CGFloat, maxHeight: CGFloat, maxFontSize: CGFloat) -> CGFloat {
        let byWidth = width / (CGFloat(columns) * Theme.monoAdvance)
        let byHeight = maxHeight / (CGFloat(rows) * Self.blockCell.height)
        return max(3, min(maxFontSize, byWidth, byHeight))
    }

    func height(fontSize: CGFloat) -> CGFloat {
        CGFloat(rows) * fontSize * Self.blockCell.height
    }
}

/// The ASCII banner from `fun/header.txt`, scaled to the width it is given, in a sunset phosphor gradient.
struct ASCIIHeaderView: View {
    @Environment(\.palette) private var palette
    let text: String
    let accessibilityTitle: String
    var maxHeight: CGFloat = 96
    var maxFontSize: CGFloat = 15

    var body: some View {
        let metrics = ASCIIArtMetrics(text: text)
        let maxFontSize = metrics.isPlainTitle ? self.maxFontSize * 2 : self.maxFontSize
        let layout = HeightForWidthLayout { [maxHeight] width in
            metrics.height(fontSize: metrics.fontSize(width: width, maxHeight: maxHeight, maxFontSize: maxFontSize))
        }
        layout {
            Canvas(rendersAsynchronously: false) { context, size in
                draw(metrics, in: context, size: size, maxFontSize: maxFontSize)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(.isHeader)
    }

    private func draw(_ metrics: ASCIIArtMetrics, in context: GraphicsContext, size: CGSize, maxFontSize: CGFloat) {
        let fontSize = metrics.fontSize(width: size.width, maxHeight: max(size.height, 1), maxFontSize: maxFontSize)
        let font = Theme.nsMono(fontSize, metrics.isPlainTitle ? .heavy : .regular)
        let pitch = fontSize * ASCIIArtMetrics.blockCell.height
        let artWidth = CGFloat(metrics.columns) * fontSize * Theme.monoAdvance
        let originX = ((size.width - artWidth) / 2).rounded()
        let originY = ((size.height - metrics.height(fontSize: fontSize)) / 2).rounded()
        let stops = [palette.yellow.nsColor, palette.pink.nsColor, ThemeColor(0xB98BFF).nsColor]

        context.withCGContext { cg in
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            if palette.glow > 0 {
                cg.setShadow(offset: .zero, blur: max(3, fontSize * 0.7), color: palette.pink.nsColor.withAlphaComponent(0.55).cgColor)
            }
            for (row, line) in metrics.lines.enumerated() {
                let position = metrics.rows > 1 ? CGFloat(row) / CGFloat(metrics.rows - 1) : 0.5
                let colour = Self.blend(stops, at: position)
                let attributed = Self.attributed(line, font: font, colour: colour, shadowAlpha: palette.glow > 0 ? 0.5 : 0.85)
                let ctLine = CTLineCreateWithAttributedString(attributed)
                let baseline = originY + CGFloat(row) * pitch + fontSize * ASCIIArtMetrics.blockCell.ascent
                cg.textPosition = CGPoint(x: originX, y: baseline)
                CTLineDraw(ctLine, cg)
            }
        }
    }

    /// Solid blocks at full strength, the box-drawing "shadow" strokes dimmer, which gives the lettering depth.
    static func attributed(_ line: String, font: NSFont, colour: NSColor, shadowAlpha: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let solid: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let shade: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour.withAlphaComponent(shadowAlpha)]
        for character in line {
            let isBoxDrawing = character.unicodeScalars.first.map { (0x2500...0x257F).contains($0.value) } ?? false
            result.append(NSAttributedString(string: String(character), attributes: isBoxDrawing ? shade : solid))
        }
        return result
    }

    static func blend(_ stops: [NSColor], at position: CGFloat) -> NSColor {
        guard stops.count > 1 else { return stops.first ?? .white }
        let scaled = min(1, max(0, position)) * CGFloat(stops.count - 1)
        let index = min(stops.count - 2, Int(scaled))
        let fraction = scaled - CGFloat(index)
        return stops[index].blended(withFraction: fraction, of: stops[index + 1]) ?? stops[index]
    }
}

/// A one-child layout whose height depends on the width it is offered (like an aspect ratio, but exact).
struct HeightForWidthLayout: Layout {
    let height: (CGFloat) -> CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        return CGSize(width: width, height: height(width).rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
