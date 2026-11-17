import AppKit
import ShawnFun
import SwiftUI

/// Where a sprite's pixels go inside a box: the largest whole-number scale that fits (so pixels stay
/// square and crisp), centered horizontally and standing on the bottom edge.
struct SpriteLayout: Equatable {
    let scale: CGFloat
    let origin: CGPoint
    let spriteWidth: Int
    let spriteHeight: Int

    /// `maxScale` caps the scale so several sprites can share one pixel size (a line-up).
    static func fit(width: Int, height: Int, in bounds: CGSize, maxScale: CGFloat? = nil) -> SpriteLayout {
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else {
            return SpriteLayout(scale: 0, origin: .zero, spriteWidth: width, spriteHeight: height)
        }
        let exact = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        // Below 1× there is no whole number that fits; shrink smoothly instead.
        var scale = exact >= 1 ? exact.rounded(.down) : exact
        if let maxScale, maxScale > 0 { scale = min(scale, maxScale) }
        let drawnWidth = CGFloat(width) * scale
        let drawnHeight = CGFloat(height) * scale
        let origin = CGPoint(x: ((bounds.width - drawnWidth) / 2).rounded(.down), y: (bounds.height - drawnHeight).rounded(.down))
        return SpriteLayout(scale: scale, origin: origin, spriteWidth: width, spriteHeight: height)
    }

    var drawnSize: CGSize { CGSize(width: CGFloat(spriteWidth) * scale, height: CGFloat(spriteHeight) * scale) }

    /// A horizontal run of same-colored pixels in one frame.
    struct Run: Equatable {
        let row: Int
        let column: Int
        let length: Int
        let color: RGBA
    }

    /// Merges neighboring pixels of one color so each run is a single rectangle (no hairline seams).
    static func runs(in frame: SpriteFrame) -> [Run] {
        var runs: [Run] = []
        for (row, pixels) in frame.pixels.enumerated() {
            var column = 0
            while column < pixels.count {
                guard let color = pixels[column], color.alpha > 0 else {
                    column += 1
                    continue
                }
                var end = column + 1
                while end < pixels.count, pixels[end] == color { end += 1 }
                runs.append(Run(row: row, column: column, length: end - column, color: color))
                column = end
            }
        }
        return runs
    }

    /// The rectangle for a run of `frame`, which is bottom-centered within the sprite's own box when smaller.
    func rect(for run: Run, frameWidth: Int, frameHeight: Int) -> CGRect {
        let offsetX = CGFloat((spriteWidth - frameWidth) / 2)
        let offsetY = CGFloat(spriteHeight - frameHeight)
        return CGRect(x: origin.x + (CGFloat(run.column) + offsetX) * scale,
                      y: origin.y + (CGFloat(run.row) + offsetY) * scale,
                      width: CGFloat(run.length) * scale,
                      height: scale)
    }
}

extension RGBA {
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: Double(alpha) / 255)
    }
}

/// A character: the sprite's own image when it has one, otherwise its pixel frames, animated.
struct SpriteView: View {
    @Environment(\.motionEnabled) private var motionEnabled
    @Environment(\.palette) private var palette
    let sprite: Sprite?
    /// Caps the pixel scale (used to draw a line-up at one shared scale).
    var maxScale: CGFloat?

    var body: some View {
        Group {
            if let sprite {
                if let url = sprite.imageURL, let image = SpriteImageCache.image(at: url) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                } else if !sprite.frames.isEmpty {
                    if motionEnabled && sprite.frames.count > 1 {
                        let duration = max(0.08, sprite.frameDuration)
                        TimelineView(.periodic(from: .now, by: duration)) { context in
                            let tick = Int(context.date.timeIntervalSinceReferenceDate / duration)
                            PixelCanvas(sprite: sprite, frameIndex: tick % sprite.frames.count, maxScale: maxScale)
                        }
                    } else {
                        PixelCanvas(sprite: sprite, frameIndex: 0, maxScale: maxScale)
                    }
                } else {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .accessibilityElement()
        .accessibilityLabel(sprite?.name ?? "")
        .accessibilityHidden(sprite == nil)
    }

    /// Shown when there is no art to draw, such as for a narrator with no file in `fun/sprites/`, or for a sprite whose
    /// image cannot be read and that has no frames.
    private var placeholder: some View {
        Text("(^_^)")
            .font(Theme.mono(Theme.Size.headline, .bold))
            .foregroundStyle(palette.dim.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct PixelCanvas: View {
    let sprite: Sprite
    let frameIndex: Int
    var maxScale: CGFloat?

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let layout = SpriteLayout.fit(width: sprite.width, height: sprite.height, in: size, maxScale: maxScale)
            guard layout.scale > 0, sprite.frames.indices.contains(frameIndex) else { return }
            let frame = sprite.frames[frameIndex]
            for run in SpriteLayout.runs(in: frame) {
                let rect = layout.rect(for: run, frameWidth: frame.width, frameHeight: frame.height)
                context.fill(Path(rect), with: .color(run.color.color), style: FillStyle(antialiased: false))
            }
        }
    }
}

/// Drop-in sprite images, decoded once.
@MainActor
enum SpriteImageCache {
    private static var images: [URL: NSImage] = [:]

    static func image(at url: URL) -> NSImage? {
        if let cached = images[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = image
        return image
    }
}

/// Everyone, side by side, with names: the celebration at the end.
struct CharacterLineup: View {
    @Environment(\.palette) private var palette
    let sprites: [Sprite]
    var cellHeight: CGFloat = 72

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(cell: cellHeight)
            row(cell: cellHeight * 0.75)
            row(cell: cellHeight * 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The whole gang: " + sprites.map(\.name).joined(separator: ", "))
    }

    /// The largest whole-number scale at which the biggest pixel sprite fits `cell`.
    static func sharedScale(for sprites: [Sprite], cell: CGFloat) -> CGFloat {
        let largest = sprites.filter { $0.imageURL == nil }.map { max($0.width, $0.height) }.max() ?? 0
        guard largest > 0 else { return 0 }
        return max(1, (cell / CGFloat(largest)).rounded(.down))
    }

    private func row(cell: CGFloat) -> some View {
        let scale = Self.sharedScale(for: sprites, cell: cell)
        let labelWidth = max(cell, 92)
        return HStack(alignment: .top, spacing: Theme.Space.s) {
            ForEach(sprites) { sprite in
                VStack(spacing: 6) {
                    SpriteView(sprite: sprite, maxScale: scale > 0 ? scale : nil)
                        .frame(width: cell, height: cell)
                    Text(sprite.name.uppercased())
                        .font(Theme.mono(8.5, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(palette.dim.color)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: labelWidth, alignment: .top)
                }
            }
        }
        .fixedSize()
    }
}
