import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ActionsWebApp

final class IconRendererTests: XCTestCase {
    // MARK: Decoding

    func testDecodePicksTheLargestImageInAMultiImageFile() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 2, nil))
        for size in [48, 160] {
            CGImageDestinationAddImage(destination, TestImages.image(width: size, height: size) { $0.setFillColor(CGColor(gray: 0, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: size, height: size)) }, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(try IconRenderer.decode(data as Data).width, 160)
    }

    func testDecodeRejectsSVGAndGarbageClearly() {
        XCTAssertThrowsError(try IconRenderer.decode(Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8))) { error in
            XCTAssertTrue("\(error)".contains("SVG images are not supported"), "\(error)")
        }
        XCTAssertThrowsError(try IconRenderer.decode(Data("hello".utf8))) { error in
            XCTAssertTrue("\(error)".contains("not an image macOS can read"), "\(error)")
        }
    }

    // MARK: Analysis

    func testOpaqueSquareIsFullBleed() throws {
        let image = try IconRenderer.decode(TestImages.solidPNG(size: 180))
        let analysis = try IconRenderer.analyse(image)
        XCTAssertEqual(analysis.shape, .fullBleed)
        XCTAssertEqual(analysis.contentRect, CGRect(x: 0, y: 0, width: 180, height: 180))
        XCTAssertFalse(analysis.isLight)
    }

    func testSquareWithTransparentMarginIsCroppedAndStillFullBleed() throws {
        // Opaque 60×60 square in the top-left quarter area of a 200 px transparent canvas.
        let image = TestImages.image(width: 200, height: 200) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 20, y: 120, width: 60, height: 60))   // CG origin is bottom left: this is near the top
        }
        let analysis = try IconRenderer.analyse(image)
        XCTAssertEqual(analysis.shape, .fullBleed)
        XCTAssertEqual(analysis.contentRect, CGRect(x: 20, y: 20, width: 60, height: 60))
    }

    func testRoundedSquareWithTransparentCornersIsAlreadyShaped() throws {
        let image = TestImages.image(width: 512, height: 512) { context in
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 512, height: 512), cornerWidth: 100, cornerHeight: 100, transform: nil))
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1))
            context.fillPath()
        }
        XCTAssertEqual(try IconRenderer.analyse(image).shape, .shaped)
    }

    func testCircleAndThinLogoAreGlyphsAndWhiteLogosAreLight() throws {
        let circle = TestImages.image(width: 256, height: 256) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
            context.fillEllipse(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        XCTAssertEqual(try IconRenderer.analyse(circle).shape, .glyph)

        let whiteCross = TestImages.image(width: 256, height: 256) { context in
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(24)
            context.move(to: CGPoint(x: 40, y: 40)); context.addLine(to: CGPoint(x: 216, y: 216))
            context.move(to: CGPoint(x: 40, y: 216)); context.addLine(to: CGPoint(x: 216, y: 40))
            context.strokePath()
        }
        let analysis = try IconRenderer.analyse(whiteCross)
        XCTAssertEqual(analysis.shape, .glyph)
        XCTAssertTrue(analysis.isLight)
    }

    func testFullyTransparentImageIsRejected() {
        let empty = TestImages.image(width: 64, height: 64) { _ in }
        XCTAssertThrowsError(try IconRenderer.normalise(empty)) { error in
            XCTAssertTrue("\(error)".contains("completely transparent"), "\(error)")
        }
    }

    // MARK: Normalising

    func testFullBleedArtworkIsMaskedToTheRoundedSquareWithAMargin() throws {
        let icon = try IconRenderer.normalise(IconRenderer.decode(TestImages.solidPNG(size: 300)))
        XCTAssertEqual(icon.width, 1024)
        XCTAssertEqual(icon.height, 1024)
        XCTAssertEqual(TestImages.pixel(icon, x: 4, y: 4).alpha, 0, "the margin stays transparent")
        let centre = TestImages.pixel(icon, x: 512, y: 512)
        XCTAssertEqual(centre.alpha, 255)
        XCTAssertGreaterThan(centre.red, 200)
        // 40 px in from the body's corner lies outside a 185 px corner radius: masked away (at most faint shadow).
        let corner = TestImages.pixel(icon, x: 140, y: 140)
        XCTAssertLessThan(corner.alpha, 128)
        XCTAssertLessThan(corner.red, 100)
    }

    func testShapedArtworkIsNotRoundedTwice() throws {
        // A gently rounded tile (radius 10 %): its corner pixels survive normalisation even though they fall
        // outside the standard 22.5 % corner, because already-shaped artwork is never masked again.
        let tile = TestImages.image(width: 500, height: 500) { context in
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 500, height: 500), cornerWidth: 50, cornerHeight: 50, transform: nil))
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
            context.fillPath()
        }
        let icon = try IconRenderer.normalise(tile)
        XCTAssertEqual(icon.width, 1024)
        XCTAssertEqual(TestImages.pixel(icon, x: 140, y: 140).alpha, 255)
        XCTAssertEqual(TestImages.pixel(icon, x: 95, y: 512).alpha, 0, "scaled to the 824 px body, with the margin kept")
        XCTAssertEqual(TestImages.pixel(icon, x: 105, y: 512).alpha, 255)
    }

    func testGlyphIsPlacedOnATile() throws {
        let dot = TestImages.image(width: 128, height: 128) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fillEllipse(in: CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        let icon = try IconRenderer.normalise(dot)
        let centre = TestImages.pixel(icon, x: 512, y: 512)
        XCTAssertEqual(centre.red, 255)
        XCTAssertEqual(centre.green, 0)
        // Inside the body but outside the glyph's box: the white tile.
        let tile = TestImages.pixel(icon, x: 512, y: 140)
        XCTAssertEqual(tile.alpha, 255)
        XCTAssertGreaterThan(tile.green, 240)
    }

    // MARK: Letter tile

    func testLetterTileIsDeterministicAndUsesTheInitial() throws {
        XCTAssertEqual(IconRenderer.initial(of: "X"), "X")
        XCTAssertEqual(IconRenderer.initial(of: "carbon"), "C")
        XCTAssertEqual(IconRenderer.initial(of: "  42 things"), "4")
        XCTAssertEqual(IconRenderer.initial(of: "🚀 Rocket"), "R")
        XCTAssertEqual(IconRenderer.initial(of: "ßeta"), "S")

        XCTAssertTrue(IconRenderer.tileColor(for: "Carbon") == IconRenderer.tileColor(for: " carbon "))
        let colours = Set(["X", "Carbon", "Gmail", "Calendar", "Linear", "Notion", "Figma", "Slack", "Drive", "Meet"]
            .map { "\(IconRenderer.tileColor(for: $0))" })
        XCTAssertGreaterThan(colours.count, 3, "names spread over the palette")

        let first = try IconRenderer.letterTile(for: "X")
        let second = try IconRenderer.letterTile(for: "X")
        XCTAssertEqual(first.width, 1024)
        XCTAssertEqual(TestImages.png(first), TestImages.png(second))
        XCTAssertEqual(TestImages.pixel(first, x: 4, y: 4).alpha, 0)
        // The X's strokes cross in the middle: white.
        let centre = TestImages.pixel(first, x: 512, y: 512)
        XCTAssertEqual(centre.alpha, 255)
        XCTAssertGreaterThan(min(centre.red, centre.green, centre.blue), 240)
        // Near the top of the body, off the letter: the tile colour.
        let background = TestImages.pixel(first, x: 512, y: 130)
        XCTAssertEqual(background.alpha, 255)
        XCTAssertLessThan(min(background.red, background.green, background.blue), 200)
    }

    // MARK: Iconset

    func testIconsetHasEverySizeAndIconutilAcceptsIt() throws {
        let directory = TempDirectory()
        let iconset = directory.url.appendingPathComponent("AppIcon.iconset")
        try IconRenderer.writeIconset(IconRenderer.letterTile(for: "Carbon"), to: iconset)

        for entry in IconRenderer.iconsetEntries {
            XCTAssertEqual(TestImages.pixelWidths(of: iconset.appendingPathComponent(entry.name)), [entry.pixels], entry.name)
        }
        let icns = directory.url.appendingPathComponent("AppIcon.icns")
        let result = try runProcess("/usr/bin/iconutil", ["-c", "icns", "-o", icns.path, iconset.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(TestImages.pixelWidths(of: icns).max(), 1024)
        XCTAssertTrue(TestImages.pixelWidths(of: icns).contains(16))
    }
}
