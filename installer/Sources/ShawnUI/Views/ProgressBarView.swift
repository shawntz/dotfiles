import SwiftUI

/// `██████████▌░░░░░░░░░`: as many cells as fit the width, with eighth-block precision.
struct BlockProgressBar: View {
    @Environment(\.palette) private var palette
    let fraction: Double
    var tone: Tone = .pink
    var fontSize: CGFloat = 13

    var body: some View {
        HeightForWidthLayout(height: { _ in fontSize * 1.25 }).callAsFunction {
            GeometryReader { geometry in
                let cells = max(4, Int(geometry.size.width / (fontSize * Theme.monoAdvance)))
                let bar = Format.progressBar(fraction: fraction, cells: cells)
                HStack(spacing: 0) {
                    Text(bar.filled)
                        .foregroundStyle(palette.color(tone))
                        .glow(palette.color(tone), radius: 5, strength: 0.45, palette: palette)
                    Text(bar.empty)
                        .foregroundStyle(palette.faint.color.opacity(0.8))
                }
                .font(Theme.mono(fontSize))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
