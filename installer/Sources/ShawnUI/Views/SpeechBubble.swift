import ShawnFun
import SwiftUI

/// A comic speech bubble whose tail points left, at the character beside it.
struct SpeechBubble: View {
    @Environment(\.palette) private var palette
    let speaker: String?
    let text: String
    var size: CGFloat = Theme.Size.body
    /// Off, the bubble is as wide as its text needs and no wider.
    var fillsWidth = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let speaker, !speaker.isEmpty {
                Text(speaker.uppercased())
                    .captionStyle(palette.pink.color, size: 9)
                    .lineLimit(1)
            }
            TypewriterText(text: "\"\(text)\"")
                .font(Theme.mono(size))
                .foregroundStyle(palette.text.color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .background(BubbleShape().fill(palette.panel.color))
        .overlay(BubbleShape().stroke(palette.pink.color.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Rounded rectangle with a small tail on the left edge, near the bottom.
struct BubbleShape: Shape {
    var radius: CGFloat = 8
    var tailWidth: CGFloat = 9
    var tailHeight: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: 0, dy: 0)
        var path = Path()
        let tailBottom = max(body.minY + radius + tailHeight, body.maxY - 14)
        let tailTop = tailBottom - tailHeight
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY), radius: radius)
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: body.minX, y: tailBottom))
        path.addLine(to: CGPoint(x: body.minX - tailWidth, y: tailBottom + 2))
        path.addLine(to: CGPoint(x: body.minX, y: tailTop))
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + radius, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// A character with something to say.
struct MascotCard: View {
    let sprite: Sprite?
    let speaker: String?
    let quip: String
    var spriteSize: CGFloat = 96

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.l + 4) {
            SpriteView(sprite: sprite)
                .frame(width: spriteSize, height: spriteSize)
            SpeechBubble(speaker: speaker, text: quip)
                .padding(.bottom, spriteSize * 0.25)
        }
    }
}
