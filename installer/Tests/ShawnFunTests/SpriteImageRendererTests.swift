import CoreGraphics
import ImageIO
import XCTest
@testable import ShawnFun

final class SpriteImageRendererTests: XCTestCase {
    private let red = TestColors.red, green = TestColors.green, blue = TestColors.blue
    private let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)

    private var fixture: SpriteFrame {
        SpriteFrame(["R.B",
                     "GGR"], ["R": red, "G": green, "B": blue])
    }

    /// What `fixture` looks like at `scale`, pixel by pixel.
    private func expected(scale: Int) -> [[RGBA]] {
        fixture.pixels.flatMap { row in
            Array(repeating: row.flatMap { Array(repeating: $0 ?? clear, count: scale) }, count: scale)
        }
    }

    func testImageIsScaledWithHardPixelEdges() throws {
        let image = try SpriteImageRenderer.cgImage(fixture, scale: 4)
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 8)
        XCTAssertEqual(readPixels(image), expected(scale: 4))
    }

    func testPNGRoundTripIsPixelExact() throws {
        let png = try SpriteImageRenderer.pngData(fixture, scale: 3)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 9)
        XCTAssertEqual(decoded.height, 6)
        XCTAssertEqual(readPixels(decoded), expected(scale: 3))
    }

    func testPaddingAndBackground() throws {
        let white = RGBA(red: 255, green: 255, blue: 255)
        let frame = SpriteFrame(pixels: [[red]])
        let image = try SpriteImageRenderer.cgImage(frame, scale: 2, padding: 1, background: white)
        XCTAssertEqual(image.width, 6)
        XCTAssertEqual(image.height, 6)
        let pixels = readPixels(image)
        XCTAssertEqual(pixels[0][0], white)
        XCTAssertEqual(pixels[2][2], red)
        XCTAssertEqual(pixels[3][3], red)
        XCTAssertEqual(pixels[4][4], white)
        XCTAssertEqual(pixels.flatMap { $0 }.filter { $0 == red }.count, 4)
    }

    func testCompositingOntoABackground() {
        let white = RGBA(red: 255, green: 255, blue: 255)
        let halfRed = RGBA(red: 255, green: 0, blue: 0, alpha: 128)
        XCTAssertEqual(SpriteImageRenderer.composite(halfRed, over: white), RGBA(red: 255, green: 127, blue: 127))
        XCTAssertEqual(SpriteImageRenderer.composite(nil, over: white), white)
        XCTAssertEqual(SpriteImageRenderer.composite(halfRed, over: nil), halfRed)
        XCTAssertEqual(SpriteImageRenderer.composite(RGBA(red: 9, green: 9, blue: 9, alpha: 0), over: nil), clear)
        XCTAssertEqual(SpriteImageRenderer.composite(red, over: blue), red)
    }

    func testContactSheetLaysOutEveryFrame() throws {
        let tall = Sprite(id: "a", name: "A", frames: [SpriteFrame(["RR", "RR"], ["R": red]), SpriteFrame(["GG", "GG"], ["G": green])])
        let wide = Sprite(id: "b", name: "B", frames: [SpriteFrame(["BBB"], ["B": blue])])
        let picture = Sprite(id: "c", name: "C", frames: [], imageURL: URL(fileURLWithPath: "/tmp/c.png"))

        let sheet = try SpriteImageRenderer.contactSheet([tall, wide, picture], allFrames: true, scale: 1, gap: 1)
        // Cells are 3×2 (the largest frame); 2 columns and 2 rows with 1-pixel gaps all around.
        XCTAssertEqual(sheet.width, 2 * 3 + 3)
        XCTAssertEqual(sheet.height, 2 * 2 + 3)
        let pixels = readPixels(sheet)
        XCTAssertEqual(pixels[1][1], red)
        XCTAssertEqual(pixels[2][2], red)
        XCTAssertEqual(pixels[1][3], clear, "a 2-wide frame sits centered-left in a 3-wide cell")
        XCTAssertEqual(pixels[1][5], green)
        XCTAssertEqual(pixels[5][1], blue, "a 1-tall frame sits on the bottom of its cell")
        XCTAssertEqual(pixels[4][1], clear)
        XCTAssertEqual(pixels[5][5], clear, "the second sprite has no second frame")

        let firstFrames = try SpriteImageRenderer.contactSheet([tall, wide], allFrames: false, scale: 2, gap: 0)
        XCTAssertEqual(firstFrames.width, 2 * 3 * 2)
        XCTAssertEqual(firstFrames.height, 2 * 2)
    }

    func testSpriteFrameSelectionWraps() throws {
        let sprite = Sprite(id: "a", name: "A", frames: [SpriteFrame(pixels: [[red]]), SpriteFrame(pixels: [[blue]])])
        XCTAssertEqual(readPixels(try SpriteImageRenderer.cgImage(sprite, frame: 3)), [[blue]])
    }

    func testErrorsSayWhatIsWrong() {
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(SpriteFrame(pixels: []))) { error in
            XCTAssertEqual((error as? SpriteImageError)?.message, "cannot draw an empty sprite frame")
        }
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(fixture, scale: 0)) { error in
            XCTAssertEqual((error as? SpriteImageError)?.message, "scale must be at least 1 (got 0)")
        }
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(fixture, scale: 100_000))
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(fixture, padding: -1))
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(Sprite(id: "pic", name: "Pic", frames: [], imageURL: nil))) { error in
            XCTAssertTrue(String(describing: error).contains("'pic' has no pixel frames"))
        }
        XCTAssertThrowsError(try SpriteImageRenderer.contactSheet([]))
    }

    func testOversizedRequestsThrowInsteadOfTrapping() {
        let big = SpriteFrame(pixels: [[RGBA?]](repeating: [RGBA?](repeating: red, count: 256), count: 256))
        // 256 × 2^24 on each side: every factor is small, but width × height overflows a 64-bit Int.
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(big, scale: 16_777_216)) { error in
            XCTAssertEqual((error as? SpriteImageError)?.message,
                           "a 256×256 frame at scale 16777216 would be too large (more than 16777216 pixels)")
        }
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(fixture, scale: Int.max)) { error in
            XCTAssertEqual((error as? SpriteImageError)?.message,
                           "a 3×2 frame at scale \(Int.max) would be too large (more than 16777216 pixels)")
        }
        // Padding is laid out before scaling, so it is checked before any canvas is allocated.
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(fixture, padding: Int.max / 2)) { error in
            XCTAssertEqual((error as? SpriteImageError)?.message,
                           "a 3×2 frame with padding \(Int.max / 2) at scale 1 would be too large (more than 16777216 pixels)")
        }
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(fixture, padding: 100_000))
        let sprite = Sprite(id: "a", name: "A", frames: [fixture])
        XCTAssertThrowsError(try SpriteImageRenderer.contactSheet([sprite], scale: 1, gap: Int.max / 3)) { error in
            XCTAssertEqual((error as? SpriteImageError)?.message,
                           "a contact sheet of 1×1 cells of 3×2 with gap \(Int.max / 3) at scale 1 would be too large (more than 16777216 pixels)")
        }
        XCTAssertThrowsError(try SpriteImageRenderer.contactSheet([sprite], scale: Int.max, gap: 1))
    }

    func testTheLargestAllowedImageIsStillDrawn() throws {
        // 4096 × 4096 = maximumPixelCount exactly.
        let image = try SpriteImageRenderer.cgImage(SpriteFrame(pixels: [[red]]), scale: 4096)
        XCTAssertEqual(image.width * image.height, SpriteImageRenderer.maximumPixelCount)
        let padded = try SpriteImageRenderer.cgImage(SpriteFrame(pixels: [[red]]), scale: 1024, padding: 1)
        XCTAssertEqual(padded.width, 3 * 1024)
        XCTAssertThrowsError(try SpriteImageRenderer.cgImage(SpriteFrame(pixels: [[red, red]]), scale: 4096))
    }
}
