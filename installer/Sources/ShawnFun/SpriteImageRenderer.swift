import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a sprite could not be turned into an image.
public struct SpriteImageError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Renders pixel art to bitmaps with hard pixel edges (nearest neighbor, never smoothed).
///
/// Pixels are written straight into an sRGB RGBA buffer, so every output pixel is exactly a palette
/// color: no interpolation, no anti-aliasing, no color management surprises. Used for snapshots,
/// tests and tooling such as the app icon.
public enum SpriteImageRenderer {
    /// Refuse anything bigger than this many output pixels (64 MB of RGBA) rather than exhaust memory.
    public static let maximumPixelCount = 16_777_216

    /// The frame as an image `(width + 2 × padding) × scale` pixels wide (likewise tall).
    /// `padding` is in sprite pixels. Transparent pixels stay transparent unless `background` is set,
    /// in which case everything is composited onto it.
    public static func cgImage(_ frame: SpriteFrame, scale: Int = 1, padding: Int = 0, background: RGBA? = nil) throws -> CGImage {
        guard frame.width > 0, frame.height > 0 else { throw SpriteImageError("cannot draw an empty sprite frame") }
        guard padding >= 0 else { throw SpriteImageError("padding must not be negative (got \(padding))") }
        let subject = "a \(frame.width)×\(frame.height) frame" + (padding > 0 ? " with padding \(padding)" : "")
        let size = try outputSize(columns: 1, rows: 1, cellWidth: frame.width, cellHeight: frame.height, gap: padding,
                                  scale: scale, subject: subject)
        let canvas = padding > 0
            ? compose([[frame]], cellWidth: frame.width, cellHeight: frame.height, gap: padding)
            : frame
        return try makeImage(canvas, size: size, scale: scale, background: background)
    }

    /// Frame `frame` of the sprite (wrapping around). Throws for an image-only sprite.
    public static func cgImage(_ sprite: Sprite, frame: Int = 0, scale: Int = 1, padding: Int = 0, background: RGBA? = nil) throws -> CGImage {
        guard !sprite.frames.isEmpty else {
            throw SpriteImageError("sprite '\(sprite.id)' has no pixel frames (it uses an image file)")
        }
        let index = TerminalSpriteRenderer.frameIndex(frame, count: sprite.frames.count)
        return try cgImage(sprite.frames[index], scale: scale, padding: padding, background: background)
    }

    /// PNG bytes of `cgImage(frame, scale:padding:background:)`.
    public static func pngData(_ frame: SpriteFrame, scale: Int = 1, padding: Int = 0, background: RGBA? = nil) throws -> Data {
        try pngData(cgImage(frame, scale: scale, padding: padding, background: background))
    }

    /// Encodes any image as PNG with ImageIO.
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw SpriteImageError("ImageIO cannot create a PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SpriteImageError("ImageIO failed to encode a \(image.width)×\(image.height) PNG")
        }
        return data as Data
    }

    /// A sheet for reviewing sprites side by side. With `allFrames`, one row per sprite and one column
    /// per frame (so animations can be checked); otherwise one row with the first frame of each.
    /// Every cell is as big as the largest frame; frames sit centered and on the cell's bottom edge.
    /// `gap` (in sprite pixels) separates cells and surrounds the sheet. Image-only sprites are left out.
    public static func contactSheet(_ sprites: [Sprite], allFrames: Bool = true, scale: Int = 4, gap: Int = 2,
                                    background: RGBA? = nil) throws -> CGImage {
        let drawable = sprites.filter { !$0.frames.isEmpty }
        guard !drawable.isEmpty else { throw SpriteImageError("no sprites with pixel frames to put on a contact sheet") }
        guard gap >= 0 else { throw SpriteImageError("gap must not be negative (got \(gap))") }
        let grid: [[SpriteFrame]] = allFrames ? drawable.map(\.frames) : [drawable.map { $0.frames[0] }]
        let frames = grid.flatMap { $0 }
        let cellWidth = frames.map(\.width).max() ?? 0
        let cellHeight = frames.map(\.height).max() ?? 0
        guard cellWidth > 0, cellHeight > 0 else { throw SpriteImageError("every sprite frame is empty") }
        let columns = grid.map(\.count).max() ?? 0
        let size = try outputSize(columns: columns, rows: grid.count, cellWidth: cellWidth, cellHeight: cellHeight, gap: gap, scale: scale,
                                  subject: "a contact sheet of \(columns)×\(grid.count) cells of \(cellWidth)×\(cellHeight) with gap \(gap)")
        let sheet = compose(grid, cellWidth: cellWidth, cellHeight: cellHeight, gap: gap)
        return try makeImage(sheet, size: size, scale: scale, background: background)
    }

    /// Pixel size of a `columns × rows` grid of `cellWidth × cellHeight` cells with `gap` sprite pixels
    /// around and between them, drawn at `scale`. It is worked out before anything is allocated, with
    /// overflow-checked arithmetic, so an absurd request throws `SpriteImageError` instead of trapping or
    /// exhausting memory (each factor may be small while their product still overflows an `Int`).
    static func outputSize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int, gap: Int, scale: Int,
                           subject: String) throws -> (width: Int, height: Int) {
        guard scale >= 1 else { throw SpriteImageError("scale must be at least 1 (got \(scale))") }
        func checked(_ result: (partialValue: Int, overflow: Bool)) -> Int? {
            result.overflow ? nil : result.partialValue
        }
        func span(_ count: Int, _ cell: Int) -> Int? {
            guard let cells = checked(count.multipliedReportingOverflow(by: cell)),
                  let gaps = checked((count + 1).multipliedReportingOverflow(by: gap)),
                  let unscaled = checked(cells.addingReportingOverflow(gaps)) else { return nil }
            return checked(unscaled.multipliedReportingOverflow(by: scale))
        }
        guard let width = span(columns, cellWidth), let height = span(rows, cellHeight),
              let pixels = checked(width.multipliedReportingOverflow(by: height)), pixels <= maximumPixelCount else {
            throw SpriteImageError("\(subject) at scale \(scale) would be too large (more than \(maximumPixelCount) pixels)")
        }
        return (width, height)
    }

    /// Lays frames out in a grid of equal cells (in sprite pixels), each frame horizontally centered and
    /// bottom-aligned in its cell, with `gap` transparent pixels between and around the cells.
    static func compose(_ grid: [[SpriteFrame]], cellWidth: Int, cellHeight: Int, gap: Int) -> SpriteFrame {
        let columns = grid.map(\.count).max() ?? 0
        let width = columns * cellWidth + (columns + 1) * gap
        let height = grid.count * cellHeight + (grid.count + 1) * gap
        var pixels = [[RGBA?]](repeating: [RGBA?](repeating: nil, count: width), count: height)
        for (row, frames) in grid.enumerated() {
            for (column, frame) in frames.enumerated() {
                let left = gap + column * (cellWidth + gap) + (cellWidth - frame.width) / 2
                let top = gap + row * (cellHeight + gap) + (cellHeight - frame.height)
                for (y, line) in frame.pixels.enumerated() {
                    for (x, pixel) in line.prefix(frame.width).enumerated() where pixel != nil {
                        pixels[top + y][left + x] = pixel
                    }
                }
            }
        }
        return SpriteFrame(pixels: pixels)
    }

    /// Draws `frame` at `scale`; `size` is `frame`'s size at that scale, as checked by `outputSize`, which
    /// keeps every index and byte count below 4 × `maximumPixelCount`.
    private static func makeImage(_ frame: SpriteFrame, size: (width: Int, height: Int), scale: Int, background: RGBA?) throws -> CGImage {
        let (width, height) = size
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for (y, row) in frame.pixels.enumerated() {
            for x in 0..<frame.width {
                let color = composite(x < row.count ? row[x] : nil, over: background)
                guard color.alpha > 0 else { continue }
                for dy in 0..<scale {
                    var offset = (y * scale + dy) * bytesPerRow + x * scale * 4
                    for _ in 0..<scale {
                        bytes[offset] = color.red
                        bytes[offset + 1] = color.green
                        bytes[offset + 2] = color.blue
                        bytes[offset + 3] = color.alpha
                        offset += 4
                    }
                }
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw SpriteImageError("CoreGraphics could not create a \(width)×\(height) image")
        }
        return image
    }

    /// Straight (non-premultiplied) source-over compositing; fully transparent results are all zero.
    static func composite(_ pixel: RGBA?, over background: RGBA?) -> RGBA {
        let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        guard let pixel, pixel.alpha > 0 else { return background ?? clear }
        guard let background, background.alpha > 0, pixel.alpha < 255 else { return pixel }

        let sourceAlpha = Double(pixel.alpha) / 255
        let backdropAlpha = Double(background.alpha) / 255 * (1 - sourceAlpha)
        let alpha = sourceAlpha + backdropAlpha
        func channel(_ source: UInt8, _ backdrop: UInt8) -> UInt8 {
            UInt8(((Double(source) * sourceAlpha + Double(backdrop) * backdropAlpha) / alpha).rounded())
        }
        return RGBA(red: channel(pixel.red, background.red), green: channel(pixel.green, background.green),
                    blue: channel(pixel.blue, background.blue), alpha: UInt8((alpha * 255).rounded()))
    }
}
