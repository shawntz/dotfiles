import AppKit
import ShawnCore
import ShawnFun
import XCTest
@testable import ShawnUI

/// The disk image's Finder window: the picture the app draws, and the two files in `Resources/dmg/` that
/// `scripts/make-dmg-art.sh` makes from it. The build scripts cannot read `DiskImageLayout`, so this compares them.
@MainActor
final class DiskImageArtTests: XCTestCase {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func layoutFile() throws -> Data {
        try Data(contentsOf: package.appendingPathComponent("Resources/dmg/DS_Store"))
    }

    /// The picture's file name in the image, which only `scripts/common.sh` knows.
    private func pictureName() throws -> String {
        let common = try String(contentsOf: package.appendingPathComponent("scripts/common.sh"), encoding: .utf8)
        let line = try XCTUnwrap(common.split(separator: "\n").first { $0.hasPrefix("DMG_PICTURE_NAME=\"") }, "scripts/common.sh names no picture")
        return String(line.dropFirst("DMG_PICTURE_NAME=\"".count).dropLast())
    }

    /// One record's data. Finder's layout file stores a record as the length of a file name, the name in
    /// UTF-16, a four-letter code, the data's type and the data. A `blob` has its length in front.
    private func blob(_ code: String, of name: String, in data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        var marker = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { marker.append(contentsOf: $0) } }
        append(UInt32(name.utf16.count))
        name.utf16.forEach { append($0) }
        marker.append(contentsOf: Array((code + "blob").utf8))
        let found = try XCTUnwrap(data.range(of: marker), "the layout file has no \(code) record for \(name)", file: file, line: line)
        let start = found.upperBound
        let length = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        return data.subdata(in: start + 4..<start + 4 + length)
    }

    private func iconPosition(of name: String, in data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> CGPoint {
        let record = try blob("Iloc", of: name, in: data, file: file, line: line)
        XCTAssertEqual(record.count, 16, file: file, line: line)
        func number(at offset: Int) -> Int { record[record.startIndex + offset..<record.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return CGPoint(x: number(at: 0), y: number(at: 4))
    }

    private func plist(_ code: String, in data: Data) throws -> [String: Any] {
        let record = try blob(code, of: ".", in: data)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any])
    }

    // MARK: The layout file

    func testTheLayoutFilePutsEachIconOnItsCard() throws {
        let data = try layoutFile()
        XCTAssertEqual(try iconPosition(of: "\(ShawnCore.appName).app", in: data), DiskImageLayout.app,
                       "run scripts/make-dmg-art.sh after changing the app's name or the layout")
        XCTAssertEqual(try iconPosition(of: "Applications", in: data), DiskImageLayout.applications)
        // Two more icons show only with hidden files on: the picture, and the folder macOS keeps a log of
        // changes in. They go under the window, where they cover nothing, and not on top of each other.
        let picture = try iconPosition(of: pictureName(), in: data)
        let changeLog = try iconPosition(of: ".fseventsd", in: data)
        for hidden in [picture, changeLog] {
            XCTAssertGreaterThan(hidden.y, DiskImageLayout.window.height + DiskImageLayout.iconSize)
        }
        XCTAssertGreaterThan(abs(picture.x - changeLog.x), DiskImageLayout.iconSize)
    }

    func testTheLayoutFileHoldsTheWindowTheIconSizeAndThePicture() throws {
        let data = try layoutFile()

        let window = try plist("bwsp", in: data)
        let bounds = NSRectFromString(try XCTUnwrap(window["WindowBounds"] as? String))
        XCTAssertEqual(bounds.size, CGSize(width: DiskImageLayout.window.width,
                                           height: DiskImageLayout.window.height + DiskImageLayout.titleBarHeight))
        for bar in ["ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"] {
            XCTAssertEqual(window[bar] as? Bool, false, bar)
        }

        let icons = try plist("icvp", in: data)
        XCTAssertEqual(icons["iconSize"] as? Double, Double(DiskImageLayout.iconSize))
        XCTAssertEqual(icons["textSize"] as? Double, Double(DiskImageLayout.textSize))
        XCTAssertEqual(icons["labelOnBottom"] as? Bool, true)
        XCTAssertEqual(icons["arrangeBy"] as? String, "none", "Finder must leave the icons where the layout puts them")
        XCTAssertEqual(icons["backgroundType"] as? Int, 2, "2 is a picture")

        // The color behind the picture is the window's own background.
        let background = Palette.standard.background
        XCTAssertEqual(try XCTUnwrap(icons["backgroundColorRed"] as? Double), background.red, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(icons["backgroundColorGreen"] as? Double), background.green, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(icons["backgroundColorBlue"] as? Double), background.blue, accuracy: 0.001)

        // Finder finds the picture by the volume's name, which make-dmg.sh sets to the app's, and the file's name.
        let alias = try XCTUnwrap(icons["backgroundImageAlias"] as? Data)
        let picture = try pictureName()
        XCTAssertTrue(picture.hasPrefix("."), "Finder hides a name that starts with a period")
        XCTAssertNotNil(alias.range(of: Data("\(ShawnCore.appName):\(picture)".utf8)), "the alias names another volume or file")
        XCTAssertNotNil(alias.range(of: Data("/Volumes/\(ShawnCore.appName)".utf8)))
    }

    func testTheBackgroundColorInTheLayoutLineIsTheWindowsBackground() {
        let hex = String(format: "%02X%02X%02X", Int((Palette.standard.background.red * 255).rounded()),
                         Int((Palette.standard.background.green * 255).rounded()), Int((Palette.standard.background.blue * 255).rounded()))
        XCTAssertEqual(DiskImageBackground.backgroundHex, hex)
        XCTAssertEqual(DiskImageLayout.summary,
                       "layout window=680x460 title-bar=32 icon=128 text=12 app=180,218 applications=500,218 background=110A1C")
    }

    // MARK: The picture

    func testThePictureFileHoldsTheCanvasAtBothSizes() throws {
        let image = try XCTUnwrap(NSImage(contentsOf: package.appendingPathComponent("Resources/dmg/background.tiff")))
        let pixelWidths = image.representations.map(\.pixelsWide).sorted()
        XCTAssertEqual(pixelWidths, [Int(DiskImageLayout.canvas.width), Int(DiskImageLayout.canvas.width) * 2])
        for representation in image.representations {
            XCTAssertEqual(representation.size, DiskImageLayout.canvas, "each size is the same picture in points")
            XCTAssertEqual(representation.pixelsHigh * Int(DiskImageLayout.canvas.width),
                           representation.pixelsWide * Int(DiskImageLayout.canvas.height))
        }
    }

    func testTheCanvasIsLargerThanTheWindowAndTheCardsFitInside() {
        XCTAssertGreaterThan(DiskImageLayout.canvas.width, DiskImageLayout.window.width)
        XCTAssertGreaterThan(DiskImageLayout.canvas.height, DiskImageLayout.window.height)
        for center in [DiskImageLayout.app, DiskImageLayout.applications] {
            XCTAssertGreaterThan(center.x - DiskImageLayout.iconSize / 2, 0)
            XCTAssertLessThan(center.x + DiskImageLayout.iconSize / 2, DiskImageLayout.window.width)
            XCTAssertLessThan(center.y + DiskImageLayout.nameBand.upperBound, DiskImageLayout.window.height)
        }
        XCTAssertEqual(DiskImageLayout.app.y, DiskImageLayout.applications.y, "the arrow between them is level")
    }

    private func render(_ fun: FunConfig) throws -> NSBitmapImageRep {
        let data = try SnapshotRenderer.png(of: DiskImageBackground(fun: fun, title: "Test"), size: DiskImageLayout.canvas, scale: 1)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, Int(DiskImageLayout.canvas.width))
        XCTAssertEqual(bitmap.pixelsHigh, Int(DiskImageLayout.canvas.height))
        return bitmap
    }

    /// The numbers stored for a pixel of the picture, as they are. (The picture is tagged sRGB, and converting
    /// what `colorAt` returns to sRGB would shift them.) Every third row from the top is a scanline, so this
    /// reads the row after one.
    private func pixel(in bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var row = Int(y)
        while row % 3 != 1 { row += 1 }
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(x), y: row))
        XCTAssertEqual(color.numberOfComponents, 4)
        var components = [CGFloat](repeating: 0, count: 4)
        color.getComponents(&components)
        return (Double(components[0]), Double(components[1]), Double(components[2]), Double(components[3]))
    }

    private func assertDark(_ pixel: (red: Double, green: Double, blue: Double, alpha: Double), _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(max(pixel.red, pixel.green, pixel.blue), 0.2, what, file: file, line: line)
        XCTAssertEqual(pixel.alpha, 1, accuracy: 0.01, what, file: file, line: line)
    }

    func testEachIconHasACardAndItsNameHasABandBothTextColorsReadOn() throws {
        let bitmap = try render(.fallback)
        let band = DiskImageLayout.nameBand
        for center in [DiskImageLayout.app, DiskImageLayout.applications] {
            // Finder draws the name under the icon. The band is centered on it and has room above and below.
            XCTAssertEqual((band.lowerBound + band.upperBound) / 2, DiskImageLayout.nameCenter)
            XCTAssertGreaterThanOrEqual(band.upperBound - band.lowerBound, 2 * DiskImageLayout.textSize)
            XCTAssertGreaterThanOrEqual(band.lowerBound, DiskImageLayout.iconSize / 2, "the band starts under the icon")
            for offset in [band.lowerBound + 3, (band.lowerBound + band.upperBound) / 2, band.upperBound - 5] {
                let found = try pixel(in: bitmap, x: center.x, y: center.y + offset)
                XCTAssertEqual(found.red, DiskImageBackground.nameBand.red, accuracy: 0.03, "\(offset)")
                XCTAssertEqual(found.green, DiskImageBackground.nameBand.green, accuracy: 0.03, "\(offset)")
                XCTAssertEqual(found.blue, DiskImageBackground.nameBand.blue, accuracy: 0.03, "\(offset)")
            }
            // Behind the icon the card is the dark panel.
            let panel = try pixel(in: bitmap, x: center.x, y: center.y)
            XCTAssertEqual(panel.red, Palette.standard.panel.red, accuracy: 0.03)
            XCTAssertEqual(panel.blue, Palette.standard.panel.blue, accuracy: 0.03)
            XCTAssertEqual(panel.alpha, 1, accuracy: 0.01)
        }
        // Past the window's edge the canvas carries on dark, so a larger window shows no white.
        assertDark(try pixel(in: bitmap, x: DiskImageLayout.canvas.width - 6, y: DiskImageLayout.canvas.height - 9), "the far corner")
        // And the top row is drawn too: the offscreen window's title bar pushes nothing down.
        assertDark(try pixel(in: bitmap, x: 6, y: 0), "the top row")
    }

    /// Finder on macOS 27 draws the names in black over a picture. Another version may pick white, so both
    /// need about 4.5 to 1 against the band.
    func testWhiteAndBlackTextBothReadOnTheNameBand() {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let band = DiskImageBackground.nameBand
        let luminance = 0.2126 * linear(band.red) + 0.7152 * linear(band.green) + 0.0722 * linear(band.blue)
        XCTAssertGreaterThan(1.05 / (luminance + 0.05), 4.3, "white on the band")
        XCTAssertGreaterThan((luminance + 0.05) / 0.05, 4.3, "black on the band")
    }

    func testAConfigWithABannerAndCharactersDrawsMoreThanTheFallback() throws {
        let directory = makeTempDirectory()
        let model = try SnapshotCommand.makeSimulationModel(options: LaunchOptions(), scratch: directory.url, mode: .snapshot)
        XCTAssertFalse(model.fun.sprites.isEmpty)
        let plain = try SnapshotRenderer.png(of: DiskImageBackground(fun: .fallback, title: "Test"), size: DiskImageLayout.canvas, scale: 1)
        let drawn = try SnapshotRenderer.png(of: DiskImageBackground(fun: model.fun, title: "Test"), size: DiskImageLayout.canvas, scale: 1)
        XCTAssertNotEqual(plain, drawn)
        XCTAssertGreaterThan(drawn.count, 20_000, "the picture has real content")
    }
}
