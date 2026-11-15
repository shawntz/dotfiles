import XCTest
@testable import ShawnFun

final class TerminalSpriteRendererTests: XCTestCase {
    private let esc = "\u{1B}["
    private let red = TestColors.red, green = TestColors.green, blue = TestColors.blue

    /// 3×4 pixels: a same-color cell, a two-color cell, transparent cells, and upper-only / lower-only cells.
    private var fixture: SpriteFrame {
        SpriteFrame(["RR.",
                     "RB.",
                     ".GG",
                     "..G"], ["R": red, "B": blue, "G": green])
    }

    // MARK: Exact output

    func testTrueColorOutput() {
        let lines = TerminalSpriteRenderer(colorMode: .trueColor).render(fixture)
        XCTAssertEqual(lines, [
            "\(esc)48;2;255;0;0m \(esc)38;2;255;0;0;48;2;0;0;255m▀\(esc)49m \(esc)0m",
            " \(esc)38;2;0;255;0m▀\(esc)48;2;0;255;0m \(esc)0m",
        ])
    }

    func testAnsi256Output() {
        let lines = TerminalSpriteRenderer(colorMode: .ansi256).render(fixture)
        XCTAssertEqual(lines, [
            "\(esc)48;5;196m \(esc)38;5;196;48;5;21m▀\(esc)49m \(esc)0m",
            " \(esc)38;5;46m▀\(esc)48;5;46m \(esc)0m",
        ])
    }

    func testPlainOutputIsTheSilhouette() {
        let lines = TerminalSpriteRenderer(colorMode: .plain).render(fixture)
        XCTAssertEqual(lines, ["██ ", " ▀█"])
        XCTAssertFalse(lines.joined().contains("\u{1B}"))
    }

    func testColorCodesAreOnlyEmittedWhenTheyChange() {
        let frame = SpriteFrame(["RRRR", "BBBB"], ["R": red, "B": blue])
        let lines = TerminalSpriteRenderer(colorMode: .trueColor).render(frame)
        XCTAssertEqual(lines, ["\(esc)38;2;255;0;0;48;2;0;0;255m▀▀▀▀\(esc)0m"])
    }

    func testColorsThatShareAPaletteEntryMergeIn256Mode() {
        let nearlyRed = RGBA(red: 250, green: 0, blue: 0)
        let frame = SpriteFrame(pixels: [[red], [nearlyRed]])
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .ansi256).render(frame), ["\(esc)48;5;196m \(esc)0m"])
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .trueColor).render(frame),
                       ["\(esc)38;2;255;0;0;48;2;250;0;0m▀\(esc)0m"])
    }

    /// Decoding the escapes back into pixels must give the original picture, for a realistic sprite.
    func testTrueColorOutputDecodesBackToTheSprite() {
        let palette: [Character: RGBA] = ["o": RGBA(hex: "#4E2F72")!, "P": RGBA(hex: "#A97BD0")!, "d": RGBA(hex: "#8257B3")!,
                                          "s": TestColors.star, "w": RGBA(hex: "#FFFFFF")!, "k": RGBA(hex: "#1E1A24")!]
        let frame = SpriteFrame(["......oooo......",
                                 "....ooPPPPoo....",
                                 "..ooPPPPsPPPoo..",
                                 ".oPPPPPsssPPPPo.",
                                 "oPPPPPPPsPPPPPPo",
                                 "oPPPwwPPPPwwPPPo",
                                 "oPPPwkPPPPwkPPPo",
                                 ".oPPPPPPPPPPPPo.",
                                 "oPPPPPkkkkPPPPPo",
                                 "oPdPPPPPPPPPPdPo",
                                 ".oddPPPPPPPPddo.",
                                 "..oodddddddoo...",
                                 "....ooooooo....."], palette)
        let blankRow = [RGBA?](repeating: nil, count: frame.width)

        let lines = TerminalSpriteRenderer(colorMode: .trueColor).render(frame)
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(Set(lines.map(TerminalText.displayWidth)), [16])
        XCTAssertEqual(decodeTrueColor(lines), [blankRow] + frame.pixels)

        let doubled = frame.scaled(by: 2)
        XCTAssertEqual(decodeTrueColor(TerminalSpriteRenderer(colorMode: .trueColor, scale: 2).render(frame)), doubled.pixels)
    }

    /// Reads half-block lines back into two pixel rows each (nil = the terminal's own background).
    private func decodeTrueColor(_ lines: [String]) -> [[RGBA?]] {
        var pixels: [[RGBA?]] = []
        for line in lines {
            var foreground: RGBA?, background: RGBA?
            var upper: [RGBA?] = [], lower: [RGBA?] = []
            var rest = Substring(line)
            while let character = rest.first {
                if rest.hasPrefix(esc), let end = rest.firstIndex(of: "m") {
                    var codes = rest[rest.index(rest.startIndex, offsetBy: 2)..<end].split(separator: ";").compactMap { Int($0) }[...]
                    while let code = codes.popFirst() {
                        switch code {
                        case 0: (foreground, background) = (nil, nil)
                        case 49: background = nil
                        case 38, 48:
                            XCTAssertEqual(codes.popFirst(), 2)
                            let rgb = [codes.popFirst(), codes.popFirst(), codes.popFirst()].compactMap { $0 }.map(UInt8.init)
                            let color = RGBA(red: rgb[0], green: rgb[1], blue: rgb[2])
                            if code == 38 { foreground = color } else { background = color }
                        default: XCTFail("unexpected SGR code \(code)")
                        }
                    }
                    rest = rest[rest.index(after: end)...]
                    continue
                }
                switch character {
                case " ": upper.append(background); lower.append(background)
                case "▀": upper.append(foreground); lower.append(background)
                case "▄": upper.append(background); lower.append(foreground)
                default: XCTFail("unexpected glyph \(character)")
                }
                rest = rest.dropFirst()
            }
            XCTAssertTrue(line.hasSuffix("\(esc)0m") || !line.contains("\u{1B}"), "a line that sets colors must reset them")
            pixels += [upper, lower]
        }
        return pixels
    }

    // MARK: Transparency and shape

    func testTransparentPixelsLeaveTheTerminalBackground() {
        let faint = RGBA(red: 255, green: 0, blue: 0, alpha: 100)
        let solidEnough = RGBA(red: 0, green: 0, blue: 255, alpha: 200)
        let frame = SpriteFrame(pixels: [[faint, nil], [red, solidEnough]])
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .trueColor).render(frame),
                       ["\(esc)38;2;255;0;0m▄\(esc)38;2;0;0;255m▄\(esc)0m"])
    }

    func testFullyTransparentFrameIsPlainSpaces() {
        let frame = SpriteFrame(pixels: [[nil, nil, nil], [nil, nil, nil]])
        for mode in TerminalSpriteRenderer.ColorMode.allCases {
            XCTAssertEqual(TerminalSpriteRenderer(colorMode: mode).render(frame), ["   "], "\(mode)")
        }
    }

    func testOddRowCountIsPaddedAtTheTopSoTheArtStandsOnTheBottomEdge() {
        let frame = SpriteFrame(["R", "B", "G"], ["R": red, "B": blue, "G": green])
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .trueColor).render(frame), [
            "\(esc)38;2;255;0;0m▄\(esc)0m",
            "\(esc)38;2;0;0;255;48;2;0;255;0m▀\(esc)0m",
        ])
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .plain).render(SpriteFrame(pixels: [[red]])), ["▄"])
    }

    func testShortRowsArePaddedWithTransparency() {
        let frame = SpriteFrame(pixels: [[red, red], [red]])
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .plain).render(frame), ["█▀"])
    }

    func testEmptyFrameRendersNothing() {
        XCTAssertEqual(TerminalSpriteRenderer().render(SpriteFrame(pixels: [])), [])
    }

    func testScaleKeepsTheShape() {
        let frame = SpriteFrame(["R.", ".B"], ["R": red, "B": blue])
        let renderer = TerminalSpriteRenderer(colorMode: .plain, scale: 2)
        XCTAssertEqual(renderer.render(frame), ["██  ", "  ██"])
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .trueColor, scale: 2).render(SpriteFrame(pixels: [[red]])),
                       ["\(esc)48;2;255;0;0m  \(esc)0m"])
        XCTAssertEqual(frame.scaled(by: 3).width, 6)
        XCTAssertEqual(frame.scaled(by: 3).height, 6)
        XCTAssertEqual(TerminalSpriteRenderer(scale: 0).scale, 1)
    }

    func testSpriteFramesWrapAround() {
        let one = SpriteFrame(pixels: [[red], [red]])
        let two = SpriteFrame(pixels: [[blue], [blue]])
        let sprite = Sprite(id: "blink", name: "Blink", frames: [one, two])
        let renderer = TerminalSpriteRenderer(colorMode: .ansi256)
        XCTAssertEqual(renderer.render(sprite, frame: 0), renderer.render(one))
        XCTAssertEqual(renderer.render(sprite, frame: 3), renderer.render(two))
        XCTAssertEqual(renderer.render(sprite, frame: -1), renderer.render(two))
        XCTAssertEqual(renderer.render(Sprite(id: "pic", name: "Picture", frames: [], imageURL: URL(fileURLWithPath: "/tmp/x.png"))), [])
    }

    // MARK: Color detection and palette

    func testColorModeDetection() {
        typealias Mode = TerminalSpriteRenderer.ColorMode
        XCTAssertEqual(Mode.detect(environment: ["COLORTERM": "truecolor"], isTerminal: false), .plain)
        XCTAssertEqual(Mode.detect(environment: ["COLORTERM": "truecolor", "NO_COLOR": "1"], isTerminal: true), .plain)
        XCTAssertEqual(Mode.detect(environment: ["COLORTERM": "truecolor", "NO_COLOR": ""], isTerminal: true), .trueColor)
        XCTAssertEqual(Mode.detect(environment: ["TERM": "dumb"], isTerminal: true), .plain)
        XCTAssertEqual(Mode.detect(environment: ["TERM": "xterm-256color", "COLORTERM": "24bit"], isTerminal: true), .trueColor)
        XCTAssertEqual(Mode.detect(environment: ["TERM": "xterm-direct"], isTerminal: true), .trueColor)
        XCTAssertEqual(Mode.detect(environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "ghostty"], isTerminal: true), .trueColor)
        XCTAssertEqual(Mode.detect(environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "Apple_Terminal"], isTerminal: true), .ansi256)
        XCTAssertEqual(Mode.detect(environment: [:], isTerminal: true), .ansi256)
    }

    func testAnsi256PaletteMapping() {
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: RGBA(red: 0, green: 0, blue: 0)), 16)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: RGBA(red: 255, green: 255, blue: 255)), 231)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: red), 196)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: green), 46)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: blue), 21)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: TestColors.lavender), 140)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: RGBA(hex: "#808080")!), 244)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: RGBA(hex: "#080808")!), 232)
        XCTAssertEqual(TerminalSpriteRenderer.ansi256Index(for: RGBA(hex: "#EEEEEE")!), 255)
    }

    func testColoredText() {
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .trueColor).colored("hi", TestColors.lavender), "\(esc)38;2;181;126;220mhi\(esc)0m")
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .ansi256).colored("hi", TestColors.lavender), "\(esc)38;5;140mhi\(esc)0m")
        XCTAssertEqual(TerminalSpriteRenderer(colorMode: .plain).colored("hi", TestColors.lavender), "hi")
    }

    // MARK: Layout

    func testSideBySideBottomAlignsAndPadsEveryLineToTheSameWidth() {
        let tall = ["ab", "cd", "ef"]
        let short = ["\(esc)31mx\(esc)0m"]
        let lines = TerminalSpriteRenderer.sideBySide([tall, short], gap: 2)
        XCTAssertEqual(lines, ["ab   ", "cd   ", "ef  \(esc)31mx\(esc)0m"])
        XCTAssertEqual(Set(lines.map(TerminalText.displayWidth)), [5])
    }

    func testSideBySideAlignments() {
        let tall = ["a", "b", "c", "d"]
        let short = ["x"]
        XCTAssertEqual(TerminalSpriteRenderer.sideBySide([tall, short], gap: 1, alignment: .top), ["a x", "b  ", "c  ", "d  "])
        XCTAssertEqual(TerminalSpriteRenderer.sideBySide([tall, short], gap: 1, alignment: .center), ["a  ", "b x", "c  ", "d  "])
        XCTAssertEqual(TerminalSpriteRenderer.sideBySide([tall, short], gap: 0, alignment: .bottom), ["a ", "b ", "c ", "dx"])
        XCTAssertEqual(TerminalSpriteRenderer.sideBySide([tall, [], short], gap: 1), ["a  ", "b  ", "c  ", "d x"])
        XCTAssertEqual(TerminalSpriteRenderer.sideBySide([]), [])
    }

    func testRowOfSpritesIsBottomAlignedWithCaptions() {
        let short = Sprite(id: "gunter", name: "Gunter", frames: [SpriteFrame(["BB", "BB"], ["B": blue])])
        let tall = Sprite(id: "lsp", name: "LSP", frames: [SpriteFrame(["RRR", "RRR", "RRR", "RRR"], ["R": red])])
        let renderer = TerminalSpriteRenderer(colorMode: .plain)

        XCTAssertEqual(renderer.renderRow([short, tall], gap: 1), ["   ███", "██ ███"])
        XCTAssertEqual(renderer.renderRow([short, tall], gap: 1, captions: true), [
            "       ███",
            "  ██   ███",
            "Gunter LSP",
        ])
    }

    func testCaptionedCentersWhicheverIsNarrower() {
        XCTAssertEqual(TerminalSpriteRenderer.captioned(["██"], "Jake"), [" ██ ", "Jake"])
        XCTAssertEqual(TerminalSpriteRenderer.captioned(["█████"], "BMO"), ["█████", " BMO "])
    }

    func testSpeakingPutsTheBubbleBesideTheSpriteWithTheTailOnTheMiddleLine() {
        let sprite = ["AA", "AA", "AA"]
        let lines = TerminalSpriteRenderer(colorMode: .plain).speaking(sprite, says: "Hi there", maxTextWidth: 20)
        XCTAssertEqual(lines, [
            "AA  ╭──────────╮",
            "AA ─┤ Hi there │",
            "AA  ╰──────────╯",
        ])
    }

    func testSpeakingCentersAShortSpriteOnATallBubble() {
        let lines = TerminalSpriteRenderer(colorMode: .plain)
            .speaking(["@@"], says: "one two three four five", maxTextWidth: 5, gap: 2)
        XCTAssertEqual(lines, [
            "     ╭───────╮",
            "     │ one   │",
            "     │ two   │",
            "@@  ─┤ three │",
            "     │ four  │",
            "     │ five  │",
            "     ╰───────╯",
        ])
    }

    func testSpeakingWithoutASpriteIsJustTheBubble() {
        let renderer = TerminalSpriteRenderer(colorMode: .plain)
        XCTAssertEqual(renderer.speaking(nil as Sprite?, says: "Lump!"), ["╭───────╮", "│ Lump! │", "╰───────╯"])
    }

    func testBubbleColorTintsOnlyTheBubble() {
        let renderer = TerminalSpriteRenderer(colorMode: .trueColor)
        let sprite = Sprite(id: "dot", name: "Dot", frames: [SpriteFrame(pixels: [[red], [red]])])
        let lines = renderer.speaking(sprite, says: "Hi", bubbleColor: TestColors.lavender)
        let tint = "\(esc)38;2;181;126;220m"
        XCTAssertEqual(lines, [
            "  \(tint) ╭────╮\(esc)0m",
            "\(esc)48;2;255;0;0m \(esc)0m \(tint)─┤ Hi │\(esc)0m",
            "  \(tint) ╰────╯\(esc)0m",
        ])
        XCTAssertEqual(Set(lines.map(TerminalText.displayWidth)), [9])
    }
}
