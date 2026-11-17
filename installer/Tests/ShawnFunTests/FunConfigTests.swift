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

    /// Gunter only says wenk, so his short lines may repeat from one list to another.
    private static let gunter = "gunter"

    /// Characters the text rules keep out of every line: en and em dashes, and curly single and double quotes.
    private static let forbidden = CharacterSet(charactersIn: "\u{2013}\u{2014}\u{2018}\u{2019}\u{201C}\u{201D}")

    /// The real config with its steps, so the mascots, the voices and the step files' `quips:` meet as they do in the app.
    private func loadConfig() throws -> InstallerConfig {
        try ConfigLoader.load(from: Self.configRoot).config
    }

    private func load() throws -> (fun: FunConfig, issues: [ConfigIssue]) {
        FunConfig.load(from: try loadConfig())
    }

    /// The words of `text` in lower case, with apostrophes dropped and other punctuation turned into spaces.
    /// "Oh, my Glob!" and "oh my glob" give the same words.
    private static func words(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where scalar != "'" && scalar != "\u{2019}" {
            scalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    func testLoadsWithoutErrors() throws {
        XCTAssertEqual(try load().issues.map(\.description), [])
    }

    func testSpeakerAndAttribution() throws {
        let fun = try load().fun
        XCTAssertEqual(fun.speaker, "lsp")
        XCTAssertEqual(fun.about, "Fan-made and not affiliated with Cartoon Network. Adventure Time and its characters are © Cartoon Network.")
    }

    func testEveryMomentHasItsOwnLines() throws {
        let fun = try load().fun
        for moment in Moment.allCases {
            // The built-in fallback has at most one line per moment, so six or more came from the file.
            XCTAssertGreaterThanOrEqual(fun.moments[moment]?.count ?? 0, 6, moment.rawValue)
        }
    }

    func testEveryStepHasQuipsAboutIt() throws {
        let fun = try load().fun
        for id in Self.stepIDs {
            XCTAssertTrue((3...5).contains(fun.stepQuips[id]?.count ?? 0), "step '\(id)' has \(fun.stepQuips[id]?.count ?? 0) quips")
            XCTAssertNotEqual(fun.lines(for: .working, stepID: id).first, fun.moments[.working]?.first, id)
        }
    }

    func testQuipsAreShortUniqueAndHaveNoPlaceholders() throws {
        let fun = try load().fun
        let quips = fun.moments.values.flatMap { $0 } + fun.stepQuips.values.flatMap { $0 }
        XCTAssertGreaterThan(quips.count, 120)
        for quip in quips {
            XCTAssertLessThan(quip.count, 90, quip)
            XCTAssertFalse(quip.contains("{") || quip.contains("}"), "nothing substitutes placeholders: \(quip)")
            XCTAssertEqual(quip, quip.trimmingCharacters(in: .whitespacesAndNewlines), quip)
            XCTAssertNil(quip.rangeOfCharacter(from: Self.forbidden), "no dashes or curly quotes: \(quip)")
        }
        let repeated = Dictionary(grouping: quips, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [])
    }

    /// Each character's line is short and plain, no one else says it, and it does not repeat a `show_quotes` text.
    func testVoicesFollowTheRules() throws {
        let fun = try load().fun
        XCTAssertNotNil(fun.voices[Self.gunter], "fun/voices/gunter.yaml did not load")
        let wenk = try Regex("^(?i)wenk([ ,.!?]+wenk)*[.!?]*$")
        let quotes = fun.showQuotes.map { Self.words($0.text) }
        var shared = fun.moments.values.flatMap { $0 } + fun.stepQuips.values.flatMap { $0 }
        for (id, voice) in fun.voices.sorted(by: { $0.key < $1.key }) {
            let lists: [(label: String, lines: [String])] = Moment.stepMoments.compactMap { moment in voice.moments[moment].map { ("\(id) \(moment.rawValue)", $0) } }
                + voice.steps.sorted(by: { $0.key < $1.key }).map { ("\(id) step \($0.key)", $0.value) }
            for (label, lines) in lists {
                for line in lines {
                    XCTAssertLessThan(line.count, 90, "\(label): \(line)")
                    XCTAssertEqual(line, line.trimmingCharacters(in: .whitespacesAndNewlines), "\(label): \(line)")
                    XCTAssertFalse(line.contains("{") || line.contains("}"), "nothing substitutes placeholders: \(line)")
                    XCTAssertNil(line.rangeOfCharacter(from: Self.forbidden), "\(label) has a dash or a curly quote: \(line)")
                    let lineWords = " \(Self.words(line)) "
                    for quote in quotes {
                        XCTAssertFalse(lineWords.contains(" \(quote) "), "\(label) repeats a show quote: \(line)")
                    }
                    if id == Self.gunter {
                        XCTAssertNotNil(line.wholeMatch(of: wenk), "Gunter only says wenk: \(line)")
                    }
                }
                if id == Self.gunter {
                    XCTAssertEqual(Set(lines).count, lines.count, "\(label) repeats a line: \(lines)")
                } else {
                    shared += lines
                }
            }
        }
        let repeated = Dictionary(grouping: shared, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [], "two characters, or two lists, share these lines")
    }

    /// Each character has lines for every step moment and for each step it hosts, and none for another character's step.
    func testEveryVoiceCoversItsSteps() throws {
        let config = try loadConfig()
        let fun = FunConfig.load(from: config).fun
        XCTAssertFalse(fun.voices.isEmpty, "no voices in fun/voices/")
        for (id, voice) in fun.voices.sorted(by: { $0.key < $1.key }) {
            let hosted = config.steps.filter { $0.mascot == id }.map(\.id)
            XCTAssertFalse(hosted.isEmpty, "\(id) is not the mascot of any step")
            XCTAssertTrue(Set(voice.steps.keys).isSubset(of: hosted),
                          "\(id) has steps lines for \(voice.steps.keys.sorted()) but hosts only \(hosted)")
            for moment in Moment.stepMoments {
                let count = voice.moments[moment]?.count ?? 0
                if id == Self.gunter {
                    XCTAssertEqual(count, 2, "\(id) has \(count) lines for \(moment.rawValue)")
                } else {
                    XCTAssertGreaterThanOrEqual(count, moment == .working ? 4 : 2, "\(id) has \(count) lines for \(moment.rawValue)")
                }
            }
            if id == Self.gunter {
                XCTAssertEqual(voice.steps, [:], "\(id) has no steps lines")
                continue
            }
            for stepID in hosted {
                let count = voice.steps[stepID]?.count ?? 0
                XCTAssertTrue((3...5).contains(count), "\(id) has \(count) lines for step '\(stepID)'")
            }
        }
    }

    func testShowQuotesAreFewShortAndSourced() throws {
        let quotes = try load().fun.showQuotes
        XCTAssertTrue((8...12).contains(quotes.count), "\(quotes.count) show quotes")
        for quote in quotes {
            XCTAssertLessThanOrEqual(quote.text.split(separator: " ").count, 12, quote.text)
            XCTAssertFalse(quote.episode?.isEmpty ?? true, "\(quote.text) needs its episode")
        }
    }

    func testHeaderIsTwoAlignedWordsThatFit() throws {
        let header = try load().fun.header
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

    private func load(stepIDs: [String] = [], mascots: [String: String] = [:], quips: [String: [String]] = [:]) -> (fun: FunConfig, issues: [ConfigIssue]) {
        FunConfig.load(from: makeInstallerConfig(root: directory.url, stepIDs: stepIDs, mascots: mascots, quips: quips))
    }

    private func errors(_ issues: [ConfigIssue]) -> [String] {
        issues.filter { $0.severity == .error }.map(\.description)
    }

    private func sprite(id: String = "blob", name: String = "Blob", palette: String = "  P: \"#B57EDC\"\n  s: \"#FFD93B\"", frames: [String],
                        extra: String = "") -> String {
        var text = "id: \(id)\nname: \(name)\nframe_ms: 250\n\(extra)palette:\n  \".\": transparent\n\(palette)\nframes:\n"
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
        XCTAssertNil(fun.sprite("missing"))
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

    // MARK: Voices

    /// Steps of the voice fixtures and their mascots. The extras step has no mascot, and lsp is the narrator.
    private static let castSteps = ["bootstrap", "packages", "ai", "extras", "claude"]
    private static let castMascots = ["bootstrap": "finn", "packages": "jake", "ai": "bmo", "claude": "lsp"]
    /// Every cast step, and no step at all.
    private static let castStepsAndNone: [String?] = [nil] + castSteps.map { $0 }

    private static let finnVoice = """
        id: finn
        moments:
          working: ["Finn works."]
          success: ["Finn cheers."]
        steps:
          bootstrap: ["Finn on bootstrap."]
        """

    /// The narrator's lines in fun/quotes.yaml, and a sprite named after each of `ids`.
    private func writeCast(_ ids: [String] = ["lsp", "finn", "jake", "bmo"]) {
        directory.write("fun/quotes.yaml", """
            speaker: lsp
            show_quotes:
              - "Oh my glob."
            moments:
              launch: ["Narrator launch."]
              working: ["Narrator works."]
              success: ["Narrator cheers."]
              password: ["Narrator wants the password."]
            steps:
              bootstrap: ["Narrator on bootstrap."]
              claude: ["Narrator on claude."]
            """)
        for id in ids {
            directory.write("fun/sprites/\(id).yaml", sprite(id: id, name: id.capitalized, frames: ["PP"]))
        }
    }

    private func loadCast(quips: [String: [String]] = [:]) -> (fun: FunConfig, issues: [ConfigIssue]) {
        load(stepIDs: Self.castSteps, mascots: Self.castMascots, quips: quips)
    }

    func testVoiceSpeaksItsOwnLinesForItsStep() {
        writeCast()
        directory.write("fun/voices/finn.yaml", Self.finnVoice)
        let (fun, issues) = loadCast()
        XCTAssertEqual(errors(issues), [])
        XCTAssertEqual(fun.voices["finn"], Voice(id: "finn", moments: [.working: ["Finn works."], .success: ["Finn cheers."]],
                                                 steps: ["bootstrap": ["Finn on bootstrap."]]))
        XCTAssertEqual(fun.lines(for: .working, stepID: "bootstrap", mascot: "finn"), ["Finn on bootstrap.", "Finn works."])
        XCTAssertEqual(fun.stepLines("bootstrap", mascot: "finn"), ["Finn on bootstrap."])

        let working = fun.say(.working, stepID: "bootstrap", mascot: "finn", seed: 0)
        XCTAssertEqual(working, SpokenLine(speakerID: "finn", sprite: fun.sprites["finn"], text: "Finn on bootstrap."))
        XCTAssertEqual(working.name, "Finn")
        XCTAssertEqual(fun.say(.working, stepID: "bootstrap", mascot: "finn", seed: 1).text, "Finn works.")
        XCTAssertEqual(fun.say(.success, stepID: "bootstrap", mascot: "finn", seed: 0).text, "Finn cheers.")
    }

    func testNarratorSpeaksForAMomentTheVoiceLacks() {
        writeCast()
        directory.write("fun/voices/finn.yaml", Self.finnVoice)
        let fun = loadCast().fun
        let narrator = fun.sprites["lsp"]

        XCTAssertEqual(fun.say(.password, stepID: "bootstrap", mascot: "finn", seed: 0),
                       SpokenLine(speakerID: "lsp", sprite: narrator, text: "Narrator wants the password."))
        XCTAssertEqual(fun.lines(for: .password, stepID: "bootstrap", mascot: "finn"), fun.lines(for: .password, stepID: "bootstrap"))
        XCTAssertEqual(fun.stepLines("bootstrap", mascot: "finn"), ["Finn on bootstrap."], "finn has working lines, so the step part is his")
        XCTAssertEqual(fun.say(.launch, mascot: "finn", seed: 0), SpokenLine(speakerID: "lsp", sprite: narrator, text: "Narrator launch."),
                       "only the narrator speaks outside the step moments")

        for mascot in ["jake", "ghost", nil] as [String?] {
            XCTAssertEqual(fun.say(.working, stepID: "packages", mascot: mascot, seed: 0),
                           SpokenLine(speakerID: "lsp", sprite: narrator, text: "Narrator works."), mascot ?? "no mascot")
        }

        var spriteless = fun
        spriteless.voices["ghost"] = Voice(id: "ghost", moments: [.working: ["Boo."]])
        XCTAssertEqual(spriteless.speakerID(for: .working, mascot: "ghost"), "lsp", "a voice with no sprite to draw never speaks")
    }

    func testNoVoicesMeansTheNarratorSpeaks() {
        writeCast()
        let (fun, issues) = loadCast()
        XCTAssertEqual(issues, [])
        XCTAssertEqual(fun.voices, [:])
        for (stepID, mascot) in Self.castMascots {
            for moment in Moment.allCases {
                let said = fun.say(moment, stepID: stepID, mascot: mascot, seed: 0)
                XCTAssertEqual(said.speakerID, "lsp", "\(moment.rawValue) in \(stepID)")
                XCTAssertEqual(said.text, fun.line(for: moment, stepID: stepID, seed: 0), "\(moment.rawValue) in \(stepID)")
            }
        }
        XCTAssertEqual(fun.stepLines("bootstrap", mascot: "finn"), ["Narrator on bootstrap."])

        let bare = FunConfig.fallback.say(.working, stepID: "bootstrap", mascot: "finn", seed: 0)
        XCTAssertEqual(bare.speakerID, "lsp")
        XCTAssertNil(bare.sprite)
        XCTAssertNil(bare.name)
        XCTAssertEqual(bare.text, FunConfig.fallback.moments[.working]?.first)
    }

    func testMascotThatIsTheNarratorUsesQuotes() {
        writeCast()
        directory.write("fun/voices/finn.yaml", Self.finnVoice)
        let fun = loadCast().fun
        XCTAssertEqual(fun.say(.working, stepID: "claude", mascot: "lsp", seed: 0),
                       SpokenLine(speakerID: "lsp", sprite: fun.sprites["lsp"], text: "Narrator on claude."))
        XCTAssertEqual(fun.lines(for: .working, stepID: "claude", mascot: "lsp"), ["Narrator on claude.", "Narrator works."])
        XCTAssertEqual(fun.stepLines("claude", mascot: "lsp"), ["Narrator on claude."])
    }

    func testStepFileQuipsGoToWhoeverSpeaks() {
        writeCast()
        directory.write("fun/voices/finn.yaml", Self.finnVoice)
        directory.write("fun/voices/bmo.yaml", "id: bmo\nmoments:\n  success: [\"BMO cheers.\"]\n")
        let (fun, issues) = loadCast(quips: [
            "bootstrap": ["Finn's step file line."],
            "packages": ["Jake has no voice, so the narrator says this."],
            "ai": ["BMO's step file line."],
            "extras": ["Nobody's step."],
            "claude": ["The narrator's own step."],
        ])
        XCTAssertEqual(errors(issues), [])
        XCTAssertEqual(fun.voices["finn"]?.steps["bootstrap"], ["Finn's step file line.", "Finn on bootstrap."])
        XCTAssertEqual(fun.voices["bmo"]?.steps["ai"], ["BMO's step file line."])
        XCTAssertEqual(fun.stepQuips, [
            "bootstrap": ["Narrator on bootstrap."],
            "packages": ["Jake has no voice, so the narrator says this."],
            "extras": ["Nobody's step."],
            "claude": ["The narrator's own step.", "Narrator on claude."],
        ])

        XCTAssertEqual(fun.say(.working, stepID: "bootstrap", mascot: "finn", seed: 0),
                       SpokenLine(speakerID: "finn", sprite: fun.sprites["finn"], text: "Finn's step file line."))
        XCTAssertEqual(fun.say(.working, stepID: "ai", mascot: "bmo", seed: 0),
                       SpokenLine(speakerID: "bmo", sprite: fun.sprites["bmo"], text: "BMO's step file line."),
                       "a step file line gives a voice its working line for that step")
        XCTAssertEqual(fun.say(.working, stepID: "packages", mascot: "jake", seed: 0),
                       SpokenLine(speakerID: "lsp", sprite: fun.sprites["lsp"], text: "Jake has no voice, so the narrator says this."))
        XCTAssertEqual(fun.stepLines("packages", mascot: "jake"), ["Jake has no voice, so the narrator says this."])
    }

    func testVoiceErrors() throws {
        writeCast()
        directory.write("fun/voices/broken.yaml", "id: [unclosed\n")
        // fin, lsp and noid are dropped. Each has a line for a moment only the narrator speaks at and lines for a step
        // it does not host, which would each give a warning in a voice the installer keeps.
        directory.write("fun/voices/fin.yaml", """
            id: fin
            moments:
              launch: ["Fin says hi."]
            steps:
              packages: ["Fin on packages."]
              nowhere: ["Fin is lost."]
            """)
        directory.write("fun/voices/finn.yaml", Self.finnVoice)
        directory.write("fun/voices/finn2.yaml", "id: finn\nmoments:\n  working: [\"The second Finn works.\"]\n")
        directory.write("fun/voices/list.yaml", "- id: finn\n")
        directory.write("fun/voices/lsp.yaml", """
            id: lsp
            moments:
              working: ["Me."]
              launch: ["Me again."]
            steps:
              packages: ["Me on packages."]
              nowhere: ["Me, lost."]
            """)
        directory.write("fun/voices/noid.yaml", """
            moments:
              working: ["Who am I?"]
              launch: ["Hello?"]
            steps:
              packages: ["Nobody on packages."]
              nowhere: ["Nobody, lost."]
            """)
        directory.write("fun/voices/notes.md", "Not a voice file, so nobody reads it.\n")
        directory.write("fun/voices/typos.yaml", "id: jake\nmoment: {}\nmoments:\n  working:\n    nested: map\n  succes: [\"Hmm.\"]\n")
        directory.write("fun/voices/zlist.yaml", "id: bmo\nmoments:\n  - working\n")
        directory.write("fun/voices/zzz.yml", "id: xyz\n")
        let (fun, issues) = loadCast()

        let messages = errors(issues)
        let parseError = try XCTUnwrap(issues.first)
        XCTAssertEqual(parseError.severity, .error)
        XCTAssertEqual(parseError.source?.file, "fun/voices/broken.yaml")
        XCTAssertNotNil(parseError.source?.line, "a parse error names its line")
        XCTAssertEqual(Array(messages.dropFirst()), [
            "fun/voices/fin.yaml:1: error: voice 'fin' has no sprite in fun/sprites/. Did you mean 'finn'?",
            "fun/voices/finn2.yaml: error: voice 'finn' is defined twice",
            "fun/voices/list.yaml: error: a voice file must be a mapping with 'id', 'moments' and 'steps'",
            "fun/voices/lsp.yaml:1: error: 'lsp' is the narrator; the narrator's lines belong in fun/quotes.yaml",
            "fun/voices/noid.yaml: error: voice: missing required key 'id'",
            "fun/voices/typos.yaml:4: error: voice → moments: 'working' must be a list of strings",
            "fun/voices/typos.yaml:6: error: voice → moments: unknown key 'succes'. Did you mean 'success'?",
            "fun/voices/typos.yaml:2: error: voice: unknown key 'moment'. Did you mean 'moments'?",
            "fun/voices/zlist.yaml:2: error: voice: 'moments' must be a mapping, not a list",
            "fun/voices/zzz.yml:1: error: voice 'xyz' has no sprite in fun/sprites/ (known: bmo, finn, jake)",
        ])

        XCTAssertEqual(fun.voices.keys.sorted(), ["bmo", "finn", "jake"], "voices with a problem in their lines still load")
        XCTAssertEqual(fun.voices["finn"], Voice(id: "finn", moments: [.working: ["The second Finn works."]]), "the later file wins")

        let dropped = ["fun/voices/fin.yaml", "fun/voices/lsp.yaml", "fun/voices/noid.yaml"]
        let droppedWarnings = issues.filter { $0.severity == .warning && dropped.contains($0.source?.file ?? "") }
        XCTAssertEqual(droppedWarnings.map(\.description), [], "a voice the installer drops gets its errors and no warnings")
    }

    func testVoiceWarnings() {
        writeCast(["lsp", "finn", "jake", "bmo", "gunter"])
        directory.write("fun/voices/bmo.yaml", "id: bmo\nmoments:\n  working: [\"BMO works.\"]\n")
        directory.write("fun/voices/finn.yaml", """
            id: finn
            moments:
              launch: ["Hi, everybody."]
              finished: ["We did it."]
              success: ["Finn cheers."]
              failure: ["Finn frowns."]
              skipped: ["Finn shrugs."]
              waiting: ["Finn waits."]
              dry_run: ["Finn pretends."]
            steps:
              bootstrap: ["Finn on bootstrap."]
              dock: ["Finn on the dock."]
              extras: ["Finn on extras."]
              nowhere: ["Finn is lost."]
            """)
        let (fun, issues) = load(stepIDs: ["bootstrap", "skills", "packages", "dock", "extras", "claude", "ghosted"],
                                 mascots: ["bootstrap": "finn", "skills": "finn", "packages": "jake", "dock": "gunter",
                                           "claude": "lsp", "ghosted": "ghost"])
        // Finn has no question lines and gets no warning for it, because a real run asks its questions before the first step.
        XCTAssertEqual(issues.map(\.description), [
            "fun/voices/finn.yaml:3: warning: finn never speaks at 'launch'; the narrator does",
            "fun/voices/finn.yaml:4: warning: finn never speaks at 'finished'; the narrator does",
            "fun/voices/finn.yaml:12: warning: finn never says these lines, because step 'dock' has mascot 'gunter'",
            "fun/voices/finn.yaml:13: warning: finn never says these lines, because step 'extras' has no mascot",
            "fun/voices/finn.yaml:14: warning: lines for unknown step 'nowhere'",
            "steps/ghosted.yaml: warning: mascot 'ghost' has no sprite in fun/sprites/ (known: bmo, finn, gunter, jake, lsp)",
            "fun/voices/bmo.yaml: warning: bmo is not the mascot of any step, so these lines never show",
            "fun/voices/finn.yaml: warning: finn has no lines for password, cancelled, so the narrator speaks then during bootstrap, skills",
            "fun/voices/finn.yaml: warning: finn has no 'working' lines for step 'skills', so the narrator speaks then",
            "steps/packages.yaml: warning: mascot 'jake' has no voice in fun/voices/, so the narrator speaks during this step",
            "steps/dock.yaml: warning: mascot 'gunter' has no voice in fun/voices/, so the narrator speaks during this step",
        ])
        XCTAssertFalse(issues.contains { $0.description.contains("question") }, "question lines are optional")
        XCTAssertNil(fun.voices["finn"]?.moments[.launch], "lines for a moment only the narrator speaks at are not kept")
        XCTAssertNil(fun.voices["finn"]?.moments[.finished])
    }

    func testNarratorLinesAreUnchangedByVoices() {
        writeCast()
        let before = loadCast().fun
        directory.write("fun/voices/finn.yaml", Self.finnVoice)
        directory.write("fun/voices/jake.yaml", "id: jake\nmoments:\n  working: [\"Jake works.\"]\n")
        let after = loadCast().fun
        XCTAssertEqual(after.voices.keys.sorted(), ["finn", "jake"])
        XCTAssertEqual(after.speaker, before.speaker)
        XCTAssertEqual(after.moments, before.moments)
        XCTAssertEqual(after.stepQuips, before.stepQuips)
        XCTAssertEqual(after.showQuotes, before.showQuotes)
        for moment in Moment.allCases {
            for stepID in Self.castStepsAndNone {
                XCTAssertEqual(after.lines(for: moment, stepID: stepID), before.lines(for: moment, stepID: stepID),
                               "\(moment.rawValue) in \(stepID ?? "no step")")
            }
        }
    }

    /// The name and the line always belong to the sprite drawn, whatever the moment, the step, the mascot and the seed.
    func testSpokenLineAlwaysMatchesItsSprite() {
        writeCast()
        directory.write("fun/voices/finn.yaml", Self.finnVoice)
        directory.write("fun/voices/bmo.yaml", "id: bmo\nmoments:\n  success: [\"BMO cheers.\"]\n  password: [\"BMO needs the password.\"]\n")
        let loaded = loadCast(quips: ["ai": ["BMO's step file line."]]).fun
        var spriteless = loaded
        spriteless.voices["ghost"] = Voice(id: "ghost", moments: [.working: ["Boo."]])

        for fun in [loaded, spriteless, FunConfig.fallback] {
            let mascots: [String?] = [nil, fun.speaker] + fun.sprites.keys.sorted().map { $0 } + ["missing", "ghost"]
            for moment in Moment.allCases {
                for stepID in Self.castStepsAndNone {
                    for mascot in mascots {
                        for seed in 0..<5 {
                            let said = fun.say(moment, stepID: stepID, mascot: mascot, seed: seed)
                            let context = "\(moment.rawValue), \(stepID ?? "no step"), \(mascot ?? "no mascot"), seed \(seed)"
                            XCTAssertEqual(said.sprite, fun.sprites[said.speakerID], context)
                            XCTAssertEqual(said.name, fun.sprites[said.speakerID]?.name, context)
                            XCTAssertTrue(said.speakerID == fun.speaker || said.speakerID == mascot, context)
                            XCTAssertTrue(fun.lines(for: moment, stepID: stepID, mascot: mascot).contains(said.text), context)
                            let ownLines = said.speakerID == fun.speaker
                                ? fun.lines(for: moment, stepID: stepID)
                                : fun.voices[said.speakerID]?.lines(for: moment, stepID: stepID) ?? []
                            XCTAssertTrue(ownLines.contains(said.text), "the line is not the speaker's own: \(context)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(loaded.say(.working, stepID: "ai", mascot: "bmo", seed: 0).speakerID, "bmo", "the fixture has a voiced step")
    }
}
