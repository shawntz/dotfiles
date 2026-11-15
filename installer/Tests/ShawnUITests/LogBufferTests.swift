import ShawnCore
import XCTest
@testable import ShawnUI

final class LogBufferTests: XCTestCase {
    func testProgressFramesOverwriteOnlyTheirOwnItem() {
        var buffer = LogBuffer()
        buffer.append(LogLine("10%", itemID: "a", isProgress: true), itemTitle: "A")
        buffer.append(LogLine("20%", itemID: "a", isProgress: true), itemTitle: "A")
        XCTAssertEqual(buffer.entries.map(\.text), ["A", "20%"])

        // Another item's line never replaces A's frame…
        buffer.append(LogLine("b says hi", itemID: "b"), itemTitle: "B")
        XCTAssertEqual(buffer.entries.map(\.text), ["A", "20%", "B", "b says hi"])
        // …and A's next line still finds its own progress frame to finish it.
        buffer.append(LogLine("100% done", itemID: "a"), itemTitle: "A")
        XCTAssertEqual(buffer.entries.map(\.text), ["A", "100% done", "B", "b says hi"])
        XCTAssertFalse(buffer.entries[1].isProgress)

        // A normal line is never overwritten.
        buffer.append(LogLine("next", itemID: "a"), itemTitle: "A")
        XCTAssertEqual(buffer.entries.suffix(2).map(\.text), ["A", "next"], "switching back to A adds a divider")
    }

    func testLinesWithoutAnItemAreNeverReplaced() {
        var buffer = LogBuffer()
        buffer.append(LogLine("frame", isProgress: true))
        buffer.append(LogLine("frame 2", isProgress: true))
        XCTAssertEqual(buffer.entries.map(\.text), ["frame", "frame 2"])
    }

    func testCapDropsOldestLinesAndCountsThem() {
        var buffer = LogBuffer(capacity: 100)
        for index in 0..<1000 {
            buffer.append(LogLine("line \(index)", style: .stdout))
        }
        XCTAssertLessThanOrEqual(buffer.count, 100)
        XCTAssertEqual(buffer.count + buffer.droppedCount, 1000)
        XCTAssertEqual(buffer.entries.last?.text, "line 999")
        let ids = buffer.entries.map(\.id)
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique and increasing even after trimming")
        XCTAssertEqual(ids.last.map { $0 - ids.first! + 1 }, ids.count, "ids are consecutive")
    }

    func testDefaultCapIsAFewThousandLines() {
        XCTAssertEqual(LogBuffer().capacity, 3000)
    }

    func testVeryLongLinesAreClipped() {
        var buffer = LogBuffer()
        buffer.append(LogLine(String(repeating: "x", count: 10_000)))
        XCTAssertLessThanOrEqual(buffer.entries[0].text.count, LogBuffer.maxLineLength + 2)
        XCTAssertTrue(buffer.entries[0].text.hasSuffix("…"))
    }

    func testRevisionChangesOnEveryMutationAndNotesResetDividers() {
        var buffer = LogBuffer()
        let start = buffer.revision
        buffer.append(LogLine("one", itemID: "a"), itemTitle: "A")
        buffer.append(LogLine("p", itemID: "a", isProgress: true), itemTitle: "A")
        buffer.append(LogLine("q", itemID: "a", isProgress: true), itemTitle: "A")
        XCTAssertEqual(buffer.revision, start + 3)
        buffer.note("──── run 2 ────")
        buffer.append(LogLine("again", itemID: "a"), itemTitle: "A")
        XCTAssertEqual(buffer.entries.map(\.text), ["A", "one", "q", "──── run 2 ────", "A", "again"])
        XCTAssertEqual(buffer.plainText.components(separatedBy: "\n").first, "── A ──")
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
    }
}
