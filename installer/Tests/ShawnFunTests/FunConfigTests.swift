import Foundation
import ShawnCore
import XCTest
@testable import ShawnFun

/// The real `config/fun/` shipped with the installer.
final class ShippedFunConfigTests: XCTestCase {
    /// Step ids from the build spec (section 5); every one needs its own quips.
    static let stepIDs = ["bootstrap", "dropbox", "packages", "apps", "ai", "git", "skills", "developer", "shell",
                          "keyboard", "terminal", "claude", "webapps", "cli", "macos", "dock", "finish"]

    private static let configRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("config")

    private func load() -> (fun: FunConfig, issues: [ConfigIssue]) {
        FunConfig.load(from: makeInstallerConfig(root: Self.configRoot, stepIDs: Self.stepIDs))
    }

    func testLoadsWithoutErrors() {
        let (_, issues) = load()
        XCTAssertEqual(issues.filter { $0.severity == .error }.map(\.description), [])
        let ownFiles: Set<String> = [FunConfig.quotesPath, FunConfig.headerPath]
        XCTAssertEqual(issues.filter { ownFiles.contains($0.source?.file ?? "") }.map(\.description), [])
    }

    func testSpeakerAndAttribution() {
        let fun = load().fun
        XCTAssertEqual(fun.speaker, "lsp")
        XCTAssertEqual(fun.about, "Fan-made and not affiliated with Cartoon Network. Adventure Time and its characters are © Cartoon Network.")
    }

    func testEveryMomentHasItsOwnLines() {
        let fun = load().fun
        for moment in Moment.allCases {
            // The built-in fallback has at most one line per moment, so six or more came from the file.
            XCTAssertGreaterThanOrEqual(fun.moments[moment]?.count ?? 0, 6, moment.rawValue)
        }
    }

    func testEveryStepHasQuipsAboutIt() {
        let fun = load().fun
        for id in Self.stepIDs {
            XCTAssertTrue((3...5).contains(fun.stepQuips[id]?.count ?? 0), "step '\(id)' has \(fun.stepQuips[id]?.count ?? 0) quips")
            XCTAssertNotEqual(fun.lines(for: .working, stepID: id).first, fun.moments[.working]?.first, id)
        }
    }

    func testQuipsAreShortUniqueAndHaveNoPlaceholders() {
        let fun = load().fun
        let quips = fun.moments.values.flatMap { $0 } + fun.stepQuips.values.flatMap { $0 }
        XCTAssertGreaterThan(quips.count, 120)
        for quip in quips {
            XCTAssertLessThan(quip.count, 90, quip)
            XCTAssertFalse(quip.contains("{") || quip.contains("}"), "nothing substitutes placeholders: \(quip)")
            XCTAssertEqual(quip, quip.trimmingCharacters(in: .whitespacesAndNewlines), quip)
        }
        let repeated = Dictionary(grouping: quips, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [])
    }

    func testShowQuotesAreFewShortAndSourced() {
        let quotes = load().fun.showQuotes
        XCTAssertTrue((8...12).contains(quotes.count), "\(quotes.count) show quotes")
        for quote in quotes {
            XCTAssertLessThanOrEqual(quote.text.split(separator: " ").count, 12, quote.text)
            XCTAssertFalse(quote.episode?.isEmpty ?? true, "\(quote.text) needs its episode")
        }
    }

    func testHeaderIsTwoAlignedWordsThatFit() {
        let header = load().fun.header
        XCTAssertNotEqual(header, FunConfig.fallback.header, "fun/header.txt was not loaded")
        XCTAssertFalse(header.contains("\t"))
        let words = header.components(separatedBy: "\n\n")
        XCTAssertEqual(words.count, 2, "SHAWN'S and DOTFILES, separated by one blank line")
        for word in words {
            let widths = word.split(separator: "\n", omittingEmptySubsequences: false).map { TerminalText.displayWidth(String($0)) }
            XCTAssertEqual(Set(widths).count, 1, "every line of a word must be equally wide: \(widths)")
            XCTAssertLessThanOrEqual(widths.max() ?? 0, 66)
        }
    }
}

/// Loader behavior on fixtures written to temporary directories.
final class FunConfigLoaderTests: XCTestCase {
    private var directory: TempDirectory!

    override func setUp() {
        directory = TempDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func load(stepIDs: [String] = []) -> (fun: FunConfig, issues: [ConfigIssue]) {
        FunConfig.load(from: makeInstallerConfig(root: directory.url, stepIDs: stepIDs))
    }

    private func errors(_ issues: [ConfigIssue]) -> [String] {
        issues.filter { $0.severity == .error }.map(\.description)
    }

    private func sprite(id: String = "blob", palette: String = "  P: \"#B57EDC\"\n  s: \"#FFD93B\"", frames: [String], extra: String = "") -> String {
        var text = "id: \(id)\nname: Blob\nframe_ms: 250\n\(extra)palette:\n  \".\": transparent\n\(palette)\nframes:\n"
        for frame in frames {
            text += "  - |\n" + frame.split(separator: "\n").map { "    \($0)\n" }.joined()
        }
        return text
    }

    func testValidSpriteParses() throws {
        directory.write("fun/sprites/blob.yaml", sprite(frames: [".PP.\nPsPP", ".PP.\nPPPP"]))
        let (fun, issues) = load()
        XCTAssertEqual(issues, [])
        let blob = try XCTUnwrap(fun.sprites["blob"])
        XCTAssertEqual(blob.name, "Blob")
        XCTAssertEqual(blob.frameDuration, 0.25)
        XCTAssertEqual(blob.frames.count, 2)
        XCTAssertEqual(blob.frames[0], SpriteFrame([".PP.", "PsPP"], ["P": TestColors.lavender, "s": TestColors.star]))
        XCTAssertEqual(fun.sprite("missing")?.id, "blob", "falls back to any sprite")
    }

    func testEmptyDirectoryGivesTheFallback() {
        let (fun, issues) = load()
        XCTAssertEqual(issues, [])
        XCTAssertEqual(fun.header, FunConfig.fallback.header)
        XCTAssertEqual(fun.line(for: .launch, seed: 0), FunConfig.fallback.moments[.launch]?.first)
        XCTAssertFalse(fun.lines(for: .cancelled).isEmpty)
    }

    func testBadPaletteColor() {
        directory.write("fun/sprites/blob.yaml", sprite(palette: "  P: \"#GGG\"", frames: ["P."]))
        let messages = errors(load().issues)
        XCTAssertEqual(messages.count, 2, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("palette color for 'P' is not a hex color") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("uses 'P', which is not in the palette") }, "\(messages)")
    }

    func testPaletteKeysMustBeSingleCharacters() {
        directory.write("fun/sprites/blob.yaml", sprite(palette: "  PP: \"#B57EDC\"", frames: ["..."]))
        XCTAssertTrue(errors(load().issues).contains { $0.contains("palette keys must be single characters (got 'PP')") })
    }

    func testRaggedRows() {
        directory.write("fun/sprites/blob.yaml", sprite(frames: ["PPPP\nPPP\nPPPP"]))
        let (fun, issues) = load()
        XCTAssertEqual(errors(issues).count, 1)
        XCTAssertTrue(errors(issues)[0].contains("frame 1, row 2 is 3 wide but the frame is 4 wide"), "\(issues)")
        XCTAssertTrue(errors(issues)[0].hasPrefix("fun/sprites/blob.yaml:"), "errors carry the file and line")
        XCTAssertEqual(fun.sprites["blob"]?.frames[0].pixels[1].count, 4, "short rows are padded")
    }

    func testUnknownSymbol() {
        directory.write("fun/sprites/blob.yaml", sprite(frames: ["PxP"]))
        let messages = errors(load().issues)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("frame 1, row 1 uses 'x', which is not in the palette"), "\(messages)")
    }

    func testDuplicateSpriteID() {
        directory.write("fun/sprites/a.yaml", sprite(id: "lsp", frames: ["PP"]))
        directory.write("fun/sprites/b.yaml", sprite(id: "lsp", frames: ["ss"]))
        let messages = errors(load().issues)
        XCTAssertEqual(messages, ["fun/sprites/b.yaml: error: sprite id 'lsp' is defined twice"])
    }

    func testFramesMustShareOneSize() {
        directory.write("fun/sprites/blob.yaml", sprite(frames: ["PP\nPP", "PPP\nPPP"]))
        let messages = errors(load().issues)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("frame 2 is 3×2 but frame 1 is 2×2; every frame of a sprite must be the same size"), "\(messages)")
    }

    func testFrameDurationMustBePositive() {
        directory.write("fun/sprites/blob.yaml", sprite(frames: ["PP"]).replacingOccurrences(of: "frame_ms: 250", with: "frame_ms: 0"))
        let (fun, issues) = load()
        XCTAssertTrue(errors(issues).contains { $0.contains("'frame_ms' must be a positive number of milliseconds (got 0)") })
        XCTAssertEqual(fun.sprites["blob"]?.frameDuration, 0.6)
    }

    func testMissingFramesAndUnknownKeys() {
        directory.write("fun/sprites/blob.yaml", "id: blob\npalette:\n  P: \"#fff\"\nframez: []\n")
        let messages = errors(load().issues)
        XCTAssertTrue(messages.contains { $0.contains("unknown key 'framez'. Did you mean 'frames'?") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("sprite 'blob' has no frames and no image") }, "\(messages)")
    }

    func testImageReplacesTheNeedForFrames() throws {
        directory.write("fun/images/blob.png", "not really a png")
        directory.write("fun/sprites/blob.yaml", "id: blob\nimage: images/blob.png\n")
        directory.write("fun/sprites/ghost.yaml", sprite(id: "ghost", frames: ["PP"], extra: "image: images/ghost.png\n"))
        let (fun, issues) = load()
        XCTAssertEqual(errors(issues), [])
        XCTAssertEqual(fun.sprites["blob"]?.imageURL?.lastPathComponent, "blob.png")
        XCTAssertNil(fun.sprites["ghost"]?.imageURL)
        XCTAssertEqual(issues.map(\.description), ["fun/sprites/ghost.yaml: warning: sprite 'ghost': image fun/images/ghost.png not found; using the pixel frames"])
    }

    func testMalformedYAMLIsReportedWithItsFile() {
        directory.write("fun/sprites/blob.yaml", "id: [unclosed\n")
        let messages = errors(load().issues)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasPrefix("fun/sprites/blob.yaml"), "\(messages)")
    }

    func testQuotesFile() {
        directory.write("fun/quotes.yaml", """
        speaker: blob
        about: Fan art.
        show_quotes:
          - "Just text"
          - text: "Oh, my Glob, you guys, drama bomb!"
            episode: It Came from the Nightosphere
            source: quotes page
        moments:
          launch: ["Hello!", "Hi!"]
          dry_run: Pretend mode.
        steps:
          packages: ["Brewing."]
          nowhere: ["Lost."]
        """)
        directory.write("fun/sprites/blob.yaml", sprite(frames: ["PP"]))
        let (fun, issues) = load(stepIDs: ["packages"])
        XCTAssertEqual(errors(issues), [])
        XCTAssertEqual(issues.map(\.message), ["quotes → steps: quips for unknown step 'nowhere'"])
        XCTAssertEqual(fun.speaker, "blob")
        XCTAssertEqual(fun.about, "Fan art.")
        XCTAssertEqual(fun.showQuotes, [ShowQuote(text: "Just text"),
                                         ShowQuote(text: "Oh, my Glob, you guys, drama bomb!", episode: "It Came from the Nightosphere")])
        XCTAssertEqual(fun.moments[.launch], ["Hello!", "Hi!"])
        XCTAssertEqual(fun.moments[.dryRun], ["Pretend mode."])
        XCTAssertEqual(fun.moments[.success], FunConfig.fallback.moments[.success], "moments not in the file keep the fallback")
        XCTAssertEqual(fun.lines(for: .working, stepID: "packages").first, "Brewing.")
    }

    func testQuotesTyposAreErrors() {
        directory.write("fun/quotes.yaml", "moments:\n  dryrun: [\"Pretend.\"]\nshow_quotes:\n  - episode: Nope\n")
        let messages = errors(load().issues)
        XCTAssertTrue(messages.contains { $0.contains("unknown key 'dryrun'. Did you mean 'dry_run'?") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("show_quotes[1]: missing required key 'text'") }, "\(messages)")
    }

    func testSpeakerWithoutASpriteIsAWarning() {
        directory.write("fun/quotes.yaml", "speaker: nobody\n")
        directory.write("fun/sprites/blob.yaml", sprite(frames: ["PP"]))
        let issues = load().issues
        XCTAssertEqual(issues.map(\.description), ["fun/quotes.yaml: warning: speaker 'nobody' has no sprite in fun/sprites/ (known: blob)"])
    }

    func testHeaderTrailingWhitespaceAndBlankEdgesAreTrimmed() {
        directory.write("fun/header.txt", "\n\n  ██╗   \n  ╚═╝\t\n\n")
        XCTAssertEqual(load().fun.header, "  ██╗\n  ╚═╝")
    }
}
