import Foundation
import ShawnCore
import ShawnFun
import XCTest
@testable import ShawnUI

final class SpriteLayoutTests: XCTestCase {
    private let pink = RGBA(red: 255, green: 0, blue: 255)
    private let blue = RGBA(red: 0, green: 0, blue: 255)

    func testWholeNumberScaleCenteredOnTheFloor() {
        let layout = SpriteLayout.fit(width: 24, height: 20, in: CGSize(width: 100, height: 90))
        XCTAssertEqual(layout.scale, 4, "min(100/24, 90/20) = 4.1 → 4")
        XCTAssertEqual(layout.drawnSize, CGSize(width: 96, height: 80))
        XCTAssertEqual(layout.origin, CGPoint(x: 2, y: 10), "centered horizontally, standing on the bottom edge")
    }

    func testMaximumSpriteSizeAndTinyBoxes() {
        let big = SpriteLayout.fit(width: 32, height: 32, in: CGSize(width: 96, height: 96))
        XCTAssertEqual(big.scale, 3)
        XCTAssertEqual(big.origin, .zero)

        let shrunk = SpriteLayout.fit(width: 32, height: 32, in: CGSize(width: 16, height: 16))
        XCTAssertEqual(shrunk.scale, 0.5, accuracy: 0.0001, "below 1× it shrinks smoothly rather than vanishing")

        XCTAssertEqual(SpriteLayout.fit(width: 0, height: 0, in: CGSize(width: 50, height: 50)).scale, 0, "an empty sprite draws nothing")
        XCTAssertEqual(SpriteLayout.fit(width: 16, height: 16, in: .zero).scale, 0)
    }

    func testSharedScaleCap() {
        let capped = SpriteLayout.fit(width: 14, height: 16, in: CGSize(width: 64, height: 64), maxScale: 2)
        XCTAssertEqual(capped.scale, 2, "a line-up draws everyone at the same pixel size")
        XCTAssertEqual(capped.origin, CGPoint(x: 18, y: 32))

        let sprites = [Sprite(id: "a", name: "A", frames: [SpriteFrame(pixels: Array(repeating: Array(repeating: pink, count: 32), count: 32))]),
                       Sprite(id: "b", name: "B", frames: [SpriteFrame(pixels: [[pink]])])]
        XCTAssertEqual(CharacterLineup.sharedScale(for: sprites, cell: 64), 2)
        XCTAssertEqual(CharacterLineup.sharedScale(for: [], cell: 64), 0)
    }

    func testRunsMergeNeighboringPixelsAndSkipTransparency() {
        let frame = SpriteFrame(pixels: [
            [nil, pink, pink, blue],
            [pink, nil, nil, pink],
            [nil, nil, nil, nil],
        ])
        let runs = SpriteLayout.runs(in: frame)
        XCTAssertEqual(runs, [
            .init(row: 0, column: 1, length: 2, color: pink),
            .init(row: 0, column: 3, length: 1, color: blue),
            .init(row: 1, column: 0, length: 1, color: pink),
            .init(row: 1, column: 3, length: 1, color: pink),
        ])
        let clear = RGBA(red: 1, green: 2, blue: 3, alpha: 0)
        XCTAssertTrue(SpriteLayout.runs(in: SpriteFrame(pixels: [[clear, clear]])).isEmpty, "fully transparent colors are skipped")
    }

    func testRunRectanglesAndSmallerFramesSitBottomCentered() {
        let layout = SpriteLayout.fit(width: 4, height: 4, in: CGSize(width: 40, height: 40))
        XCTAssertEqual(layout.scale, 10)
        let run = SpriteLayout.Run(row: 1, column: 2, length: 2, color: pink)
        XCTAssertEqual(layout.rect(for: run, frameWidth: 4, frameHeight: 4), CGRect(x: 20, y: 10, width: 20, height: 10))
        // A 2×2 frame inside the 4×4 sprite box: shifted right by 1 pixel and down by 2.
        let small = SpriteLayout.Run(row: 0, column: 0, length: 1, color: pink)
        XCTAssertEqual(layout.rect(for: small, frameWidth: 2, frameHeight: 2), CGRect(x: 10, y: 20, width: 10, height: 10))
    }
}

final class FormatAndStatusTests: XCTestCase {
    func testProgressBarUsesEighthBlocks() {
        XCTAssertEqual(Format.progressBar(fraction: 0, cells: 4).filled, "")
        XCTAssertEqual(Format.progressBar(fraction: 0, cells: 4).empty, "░░░░")
        XCTAssertEqual(Format.progressBar(fraction: 1, cells: 4).filled, "████")
        XCTAssertEqual(Format.progressBar(fraction: 1, cells: 4).empty, "")
        let half = Format.progressBar(fraction: 0.5, cells: 5)
        XCTAssertEqual(half.filled, "██▌")
        XCTAssertEqual(half.empty, "░░")
        for fraction in stride(from: 0.0, through: 1.0, by: 0.037) {
            let bar = Format.progressBar(fraction: fraction, cells: 17)
            XCTAssertEqual(bar.filled.count + bar.empty.count, 17, "the bar never changes width (\(fraction))")
        }
        XCTAssertEqual(Format.progressBar(fraction: .nan, cells: 3).empty, "░░░")
        XCTAssertEqual(Format.progressBar(fraction: 7, cells: 3).filled, "███")
    }

    func testClockAndDuration() {
        XCTAssertEqual(Format.clock(0), "00:00")
        XCTAssertEqual(Format.clock(192.9), "03:12")
        XCTAssertEqual(Format.clock(3 * 3600 + 5), "3:00:05")
        XCTAssertEqual(Format.duration(38), "38s")
        XCTAssertEqual(Format.duration(252), "4m 12s")
        XCTAssertEqual(Format.duration(3780), "1h 03m")
        XCTAssertEqual(Format.count(1, "item"), "1 item")
        XCTAssertEqual(Format.count(3, "item"), "3 items")
    }

    func testEveryStatusHasAOneCharacterGlyphAndALabel() {
        let statuses: [ItemStatus] = [.pending, .disabled, .checking, .running, .done("x"), .alreadyDone(nil), .skipped("y"),
                                      .needsAttention("z"), .failed("w")]
        for status in statuses {
            XCTAssertEqual(status.look.glyph.count, 1, "\(status)")
            XCTAssertFalse(status.look.label.isEmpty)
        }
        XCTAssertTrue(ItemStatus.running.look.spins)
        XCTAssertEqual(ItemStatus.failed("boom").look.detail, "boom")
        XCTAssertNil(ItemStatus.done("").look.detail, "empty details are dropped")
        XCTAssertEqual(StepStatus.finishedWithFailures(2).look.label, "2 failed")
        XCTAssertTrue(StatusLook.spinnerFrames.allSatisfy { $0.count == 1 })
    }
}

final class HeaderMetricsTests: XCTestCase {
    func testRowsColumnsAndTrimming() {
        let metrics = ASCIIArtMetrics(text: "\n\n██╗  ██╗\n██║  ██║\n╚═╝  ╚═╝   \n\n")
        XCTAssertEqual(metrics.rows, 3)
        XCTAssertEqual(metrics.columns, 11, "trailing spaces count toward the width only where they are")
        XCTAssertFalse(metrics.isPlainTitle)
        XCTAssertTrue(ASCIIArtMetrics(text: "SHAWN'S DOTFILES").isPlainTitle)
        XCTAssertEqual(ASCIIArtMetrics(text: "").rows, 1)
    }

    func testFontSizeFitsWidthAndHeightAndRowsTouch() {
        let metrics = ASCIIArtMetrics(text: SimulationConfig.header)
        let size = metrics.fontSize(width: 1000, maxHeight: 96, maxFontSize: 15)
        XCTAssertLessThanOrEqual(CGFloat(metrics.columns) * size * Theme.monoAdvance, 1000.5)
        XCTAssertLessThanOrEqual(metrics.height(fontSize: size), 96.5)
        XCTAssertLessThanOrEqual(size, 15)
        // Rows are one full-block tall, so block characters on neighboring rows touch.
        XCTAssertEqual(ASCIIArtMetrics.blockCell.height, 1, accuracy: 0.05)
        XCTAssertGreaterThan(ASCIIArtMetrics.blockCell.ascent, 0.5)
        XCTAssertEqual(metrics.height(fontSize: 10), CGFloat(metrics.rows) * 10 * ASCIIArtMetrics.blockCell.height, accuracy: 0.001)
    }

    func testBoxDrawingStrokesAreDimmerThanBlocks() {
        let attributed = ASCIIHeaderView.attributed("█╗", font: Theme.nsMono(10), color: .white, shadowAlpha: 0.5)
        let block = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let stroke = attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(block?.alphaComponent, 1)
        XCTAssertEqual(stroke?.alphaComponent ?? 0, 0.5, accuracy: 0.01)
    }
}
