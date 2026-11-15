import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconError: Error, Sendable, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Turns any artwork into a macOS-style app icon and writes the `.iconset` that `iconutil` packs.
///
/// Geometry follows Apple's macOS icon grid: a 1024 px canvas with an 824 px rounded-square body
/// centred in it (a 100 px margin that holds the drop shadow).
enum IconRenderer {
    static let canvasSize = 1024
    static let bodySize: CGFloat = 824
    static let cornerRadius: CGFloat = 185.4
    static var bodyRect: CGRect {
        let inset = (CGFloat(canvasSize) - bodySize) / 2
        return CGRect(x: inset, y: inset, width: bodySize, height: bodySize)
    }

    /// File names and pixel sizes of a complete macOS iconset.
    static let iconsetEntries: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    // MARK: Decoding

    /// The largest image in PNG, JPEG, GIF, WebP, ICO or ICNS data.
    static func decode(_ data: Data) throws -> CGImage {
        let prefix = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        if prefix.contains("<svg") || prefix.hasPrefix("<?xml") {
            throw IconError("SVG images are not supported; use a PNG, JPEG or ICNS file")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw IconError("not an image macOS can read (expected PNG, JPEG or ICNS)")
        }
        var best: (index: Int, pixels: Int) = (0, -1)
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let pixels = (properties?[kCGImagePropertyPixelWidth] as? Int ?? 0) * (properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if pixels > best.pixels { best = (index, pixels) }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, best.index, nil) else {
            throw IconError("the image data is damaged")
        }
        return image
    }

    // MARK: Analysis

    enum Shape: Equatable {
        /// Fills its square edge to edge (a touch icon, a photo): gets masked to the rounded square.
        case fullBleed
        /// Already a rounded square with transparent corners: used as drawn, never rounded twice.
        case shaped
        /// A logo on transparency: placed on a tile.
        case glyph
    }

    struct Analysis: Equatable {
        let shape: Shape
        /// The visible part of the image, in its pixel coordinates (origin top left).
        let contentRect: CGRect
        /// True when the visible pixels are mostly white (such a logo needs a dark tile).
        let isLight: Bool
    }

    /// Looks at the alpha channel to decide how the artwork should be treated.
    static func analyse(_ image: CGImage) throws -> Analysis {
        let scale = min(1, 256 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let context = try makeContext(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { throw IconError("could not read the image's pixels") }
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        // Bitmap memory runs top row first, matching CGImage cropping coordinates.
        func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[y * rowBytes + x * 4 + 3]) }

        var minX = width, maxX = -1, minY = height, maxY = -1
        var visible = 0
        var luminance: CGFloat = 0
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) >= 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                visible += 1
                let offset = y * rowBytes + x * 4
                let a = CGFloat(pixels[offset + 3])
                luminance += (0.2126 * CGFloat(pixels[offset]) + 0.7152 * CGFloat(pixels[offset + 1]) + 0.0722 * CGFloat(pixels[offset + 2])) / a
            }
        }
        guard visible > 0 else { throw IconError("the image is completely transparent") }

        let boxWidth = maxX - minX + 1
        let boxHeight = maxY - minY + 1
        let inset = min(boxWidth, boxHeight) >= 8 ? 1 : 0
        let corners = [(minX + inset, minY + inset), (maxX - inset, minY + inset), (minX + inset, maxY - inset), (maxX - inset, maxY - inset)]
        let cornersOpaque = corners.allSatisfy { alpha($0.0, $0.1) >= 230 }
        let fill = CGFloat(visible) / CGFloat(boxWidth * boxHeight)
        let aspect = CGFloat(boxWidth) / CGFloat(boxHeight)

        let shape: Shape
        if cornersOpaque {
            shape = .fullBleed
        } else if (0.9...1.11).contains(aspect) && fill >= 0.9 {
            // A rounded square fills ≥ 90 % of its box; circles (78 %) and logos fill less and get a tile.
            shape = .shaped
        } else {
            shape = .glyph
        }
        let contentRect = CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                                 width: CGFloat(boxWidth) / scale, height: CGFloat(boxHeight) / scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Analysis(shape: shape, contentRect: contentRect, isLight: luminance / CGFloat(visible) > 0.85)
    }

    // MARK: Normalising

    /// A 1024 px macOS-style icon made from arbitrary artwork.
    static func normalise(_ image: CGImage) throws -> CGImage {
        let analysis = try analyse(image)
        let artwork = image.cropping(to: analysis.contentRect) ?? image
        let size = CGSize(width: artwork.width, height: artwork.height)
        let body = bodyRect

        switch analysis.shape {
        case .shaped:
            return try render { context in
                context.draw(artwork, in: fit(size, in: body))
            }
        case .fullBleed:
            return try withShadow(render { context in
                context.addPath(bodyPath())
                context.clip()
                context.draw(artwork, in: fill(size, in: body))
            })
        case .glyph:
            let background: CGColor = analysis.isLight ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1)
            return try withShadow(render { context in
                context.addPath(bodyPath())
                context.setFillColor(background)
                context.fillPath()
                let box = body.insetBy(dx: body.width * 0.18, dy: body.height * 0.18)
                context.draw(artwork, in: fit(size, in: box))
            })
        }
    }

    // MARK: Letter tile

    /// Tile colours: saturated enough to tell apps apart, dark enough for white type.
    static let palette: [(red: Int, green: Int, blue: Int)] = [
        (99, 102, 241), (124, 58, 237), (192, 38, 211), (219, 39, 119), (225, 29, 72), (234, 88, 12),
        (217, 119, 6), (5, 150, 105), (13, 148, 136), (8, 145, 178), (2, 132, 199), (37, 99, 235),
    ]

    /// The same name always gets the same colour (FNV-1a, not Swift's per-process randomised hashing).
    static func tileColor(for name: String) -> (red: Int, green: Int, blue: Int) {
        var hash: UInt32 = 2_166_136_261
        for byte in name.trimmingCharacters(in: .whitespaces).lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    /// The first letter or digit of the name, upper-cased.
    static func initial(of name: String) -> String {
        let character = name.first { $0.isLetter || $0.isNumber } ?? name.first(where: { !$0.isWhitespace }) ?? "?"
        return String(String(character).uppercased().prefix(1))
    }

    /// A rounded square in the name's colour with its initial, for sites without a usable icon.
    static func letterTile(for name: String) throws -> CGImage {
        let color = tileColor(for: name)
        func component(_ value: Int, lightened amount: CGFloat) -> CGFloat {
            let base = CGFloat(value) / 255
            return base + (1 - base) * amount
        }
        let top = CGColor(srgbRed: component(color.red, lightened: 0.22), green: component(color.green, lightened: 0.22),
                          blue: component(color.blue, lightened: 0.22), alpha: 1)
        let bottom = CGColor(srgbRed: component(color.red, lightened: 0), green: component(color.green, lightened: 0),
                             blue: component(color.blue, lightened: 0), alpha: 1)
        let body = bodyRect

        return try withShadow(render { context in
            context.addPath(bodyPath())
            context.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
            } else {
                context.setFillColor(bottom)
                context.fill(body)
            }

            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 500, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 500, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: initial(of: name), attributes: attributes))
            let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: body.midX - glyphBounds.midX, y: body.midY - glyphBounds.midY)
            CTLineDraw(line, context)
        })
    }

    // MARK: Iconset

    /// Writes every size of `icon` (a 1024 px image) as PNGs into `directory` (an `.iconset` folder).
    static func writeIconset(_ icon: CGImage, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in iconsetEntries {
            let image = entry.pixels == icon.width ? icon : try scaled(icon, to: entry.pixels)
            try writePNG(image, to: directory.appendingPathComponent(entry.name))
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw IconError("cannot create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw IconError("cannot write \(url.lastPathComponent)") }
    }

    static func scaled(_ image: CGImage, to pixels: Int) throws -> CGImage {
        let context = try makeContext(width: pixels, height: pixels)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let result = context.makeImage() else { throw IconError("could not scale the icon to \(pixels) px") }
        return result
    }

    // MARK: Drawing helpers

    static func bodyPath() -> CGPath {
        CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IconError("could not create a \(width)×\(height) drawing surface")
        }
        return context
    }

    /// Draws on a transparent 1024 px canvas.
    private static func render(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try makeContext(width: canvasSize, height: canvasSize)
        context.interpolationQuality = .high
        draw(context)
        guard let image = context.makeImage() else { throw IconError("could not render the icon") }
        return image
    }

    /// Adds the soft drop shadow macOS icons sit on; it stays inside the canvas margin.
    private static func withShadow(_ body: CGImage) throws -> CGImage {
        try render { context in
            context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
            context.draw(body, in: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        }
    }

    /// Largest rect with `size`'s aspect ratio inside `box`, centred.
    static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        let scale = min(box.width / size.width, box.height / size.height)
        return centred(CGSize(width: size.width * scale, height: size.height * scale), in: box)
    }

    /// Smallest rect with `size`'s aspect ratio covering `box`, centred.
    static func fill(_ size: CGSize, in box: CGRect) -> CGRect {
        let scale = max(box.width / size.width, box.height / size.height)
        return centred(CGSize(width: size.width * scale, height: size.height * scale), in: box)
    }

    private static func centred(_ size: CGSize, in box: CGRect) -> CGRect {
        CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }
}
