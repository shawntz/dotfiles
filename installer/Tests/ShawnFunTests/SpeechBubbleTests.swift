import XCTest
@testable import ShawnFun

final class TextWrapTests: XCTestCase {
    func testGreedyWrapKeepsWordsWhole() {
        XCTAssertEqual(TerminalText.wrap("the quick brown fox jumps", width: 10), ["the quick", "brown fox", "jumps"])
        XCTAssertEqual(TerminalText.wrap("abcd efgh", width: 4), ["abcd", "efgh"])
        XCTAssertEqual(TerminalText.wrap("ab cd", width: 5), ["ab cd"])
        XCTAssertEqual(TerminalText.wrap("Oh my glob, it's setup day!", width: 16), ["Oh my glob, it's", "setup day!"])
    }

    func testOnlyWordsLongerThanALineAreSplit() {
        XCTAssertEqual(TerminalText.wrap("a abcdefghij b", width: 4), ["a", "abcd", "efgh", "ij b"])
        XCTAssertEqual(TerminalText.wrap("lumpy space princess", width: 6), ["lumpy", "space", "prince", "ss"])
        XCTAssertEqual(TerminalText.wrap("ab", width: 0), ["a", "b"])
    }

    func testWhitespaceAndLineBreaks() {
        XCTAssertEqual(TerminalText.wrap("  spaced   out  ", width: 20), ["spaced out"])
        XCTAssertEqual(TerminalText.wrap("one\n\ntwo three", width: 20), ["one", "", "two three"])
        XCTAssertEqual(TerminalText.wrap("one\r\ntwo", width: 20), ["one", "two"])
        XCTAssertEqual(TerminalText.wrap("", width: 10), [""])
    }

    func testWideCharactersCountAsTwoColumns() {
        XCTAssertEqual(TerminalText.wrap("日本語 ok", width: 4), ["日本", "語", "ok"])
        XCTAssertEqual(TerminalText.wrap("🎉🎉 yay", width: 4), ["🎉🎉", "yay"])
    }

    func testDisplayWidth() {
        XCTAssertEqual(TerminalText.displayWidth("abc"), 3)
        XCTAssertEqual(TerminalText.displayWidth("\u{1B}[38;2;1;2;3mab\u{1B}[0m"), 2)
        XCTAssertEqual(TerminalText.displayWidth("▀▄█╭─╮│"), 7)
        XCTAssertEqual(TerminalText.displayWidth("日本"), 4)
        XCTAssertEqual(TerminalText.displayWidth("🎉"), 2)
        XCTAssertEqual(TerminalText.displayWidth("e\u{301}"), 1)
        XCTAssertEqual(TerminalText.displayWidth("\u{200B}"), 0)
        XCTAssertEqual(TerminalText.pad("ab", toWidth: 4), "ab  ")
        XCTAssertEqual(TerminalText.pad("abcdef", toWidth: 4), "abcdef")
    }
}

final class SpeechBubbleTests: XCTestCase {
    func testBubbleWithLeftTail() {
        XCTAssertEqual(SpeechBubble.render("Oh my glob, it's setup day!", maxTextWidth: 16, tail: .left), [
            " ╭──────────────────╮",
            "─┤ Oh my glob, it's │",
            " │ setup day!       │",
            " ╰──────────────────╯",
        ])
    }

    func testBubbleWithRightTailAndWithout() {
        XCTAssertEqual(SpeechBubble.render("one two three", maxTextWidth: 5, tail: .right), [
            "╭───────╮ ",
            "│ one   │ ",
            "│ two   ├─",
            "│ three │ ",
            "╰───────╯ ",
        ])
        XCTAssertEqual(SpeechBubble.render("Lump!", tail: .none), ["╭───────╮", "│ Lump! │", "╰───────╯"])
    }

    func testBubbleShrinksToShortTextAndHandlesEmptyText() {
        XCTAssertEqual(SpeechBubble.render("Hi", maxTextWidth: 40, tail: .none), ["╭────╮", "│ Hi │", "╰────╯"])
        XCTAssertEqual(SpeechBubble.render("", tail: .none), ["╭───╮", "│   │", "╰───╯"])
    }

    func testEveryBubbleLineHasTheSameWidth() {
        for tail in [SpeechBubble.Tail.none, .left, .right] {
            let lines = SpeechBubble.render("Royalty needs the keys to the castle. Admin password, please. Obvi.", maxTextWidth: 18, tail: tail)
            XCTAssertEqual(Set(lines.map(TerminalText.displayWidth)).count, 1, "\(tail)")
            XCTAssertTrue(lines.dropFirst().dropLast().allSatisfy { TerminalText.displayWidth($0) <= 18 + 4 + 1 })
        }
    }

    func testTailLine() {
        XCTAssertEqual(SpeechBubble.tailLine(textLineCount: 1), 1)
        XCTAssertEqual(SpeechBubble.tailLine(textLineCount: 2), 1)
        XCTAssertEqual(SpeechBubble.tailLine(textLineCount: 3), 2)
        XCTAssertEqual(SpeechBubble.tailLine(textLineCount: 0), 1)
    }
}
