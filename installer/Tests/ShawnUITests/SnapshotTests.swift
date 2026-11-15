import AppKit
import ShawnCore
import ShawnFun
import XCTest
@testable import ShawnUI

/// Renders real screens in-process (offscreen, nothing is shown) and checks the PNGs are real images.
@MainActor
final class SnapshotTests: XCTestCase {
    private func render(_ state: SnapshotState, size: CGSize = CGSize(width: 1100, height: 760), scale: Int = 2) throws -> Data {
        let directory = makeTempDirectory()
        let model = try SnapshotCommand.makeSimulationModel(options: LaunchOptions(), scratch: directory.url, mode: .snapshot,
                                                            configureNow: state != .loading)
        SnapshotScript.apply(state, to: model)
        return try SnapshotRenderer.png(of: RootView(model: model, isSnapshot: true), size: size, scale: scale)
    }

    private func assertImage(_ data: Data, size: CGSize, scale: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature", file: file, line: line)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), file: file, line: line)
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width) * scale, file: file, line: line)
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height) * scale, file: file, line: line)
        // A blank or single-colour image compresses to almost nothing; a real screen does not.
        XCTAssertGreaterThan(data.count, 40_000, "the image has real content", file: file, line: line)
        // The background must be the CRT purple-black, not white or transparent.
        let corner = try XCTUnwrap(bitmap.colorAt(x: 4, y: bitmap.pixelsHigh - 4)?.usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertLessThan(corner.brightnessComponent, 0.2, file: file, line: line)
        XCTAssertEqual(corner.alphaComponent, 1, accuracy: 0.01, file: file, line: line)
    }

    func testWelcomeRendersToAPNG() throws {
        let data = try render(.welcome)
        try assertImage(data, size: CGSize(width: 1100, height: 760), scale: 2)
    }

    func testRunningRendersToAPNG() throws {
        let data = try render(.running)
        try assertImage(data, size: CGSize(width: 1100, height: 760), scale: 2)
    }

    func testEveryStateRendersAtTheMinimumWindowSize() throws {
        for state in SnapshotState.allCases {
            let data = try render(state, size: Theme.minimumWindowSize, scale: 1)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), state.rawValue)
            XCTAssertEqual(bitmap.pixelsWide, Int(Theme.minimumWindowSize.width), state.rawValue)
            XCTAssertGreaterThan(data.count, 10_000, state.rawValue)
        }
    }

    func testAModelWithNoSpritesAndAPlainHeaderStillRenders() throws {
        let (model, _) = try makeModel()
        XCTAssertTrue(model.fun.sprites.isEmpty)
        let welcome = try SnapshotRenderer.png(of: RootView(model: model, isSnapshot: true), size: CGSize(width: 1000, height: 700), scale: 1)
        XCTAssertNotNil(NSBitmapImageRep(data: welcome))
        model.apply(.runStarted(totalItems: 5))
        model.apply(.stepStatus(stepID: "base", status: .running))
        model.apply(.runFinished(InstallSummary()))
        let finished = try SnapshotRenderer.png(of: RootView(model: model, isSnapshot: true), size: CGSize(width: 1000, height: 700), scale: 1)
        XCTAssertNotNil(NSBitmapImageRep(data: finished))
    }

    func testIncreasedContrastPaletteRenders() throws {
        let directory = makeTempDirectory()
        let model = try SnapshotCommand.makeSimulationModel(options: LaunchOptions(), scratch: directory.url, mode: .snapshot)
        let data = try SnapshotRenderer.png(of: RootView(model: model, isSnapshot: true, forcedPalette: .highContrast),
                                            size: CGSize(width: 1100, height: 760), scale: 1)
        XCTAssertNotNil(NSBitmapImageRep(data: data))
        XCTAssertEqual(Palette.highContrast.scanlines, 0, "no scanlines over text with Increase Contrast")
        XCTAssertEqual(Palette.highContrast.glow, 0)
    }
}
