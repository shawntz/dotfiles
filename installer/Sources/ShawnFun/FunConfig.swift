import Foundation
import ShawnCore

/// An sRGB color with alpha.
public struct RGBA: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional).
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
        } else {
            self.init(red: UInt8((value >> 24) & 0xFF), green: UInt8((value >> 16) & 0xFF), blue: UInt8((value >> 8) & 0xFF), alpha: UInt8(value & 0xFF))
        }
    }

    public var hex: String {
        let base = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 255 ? base : base + String(format: "%02X", alpha)
    }
}

/// One frame of pixel art: rows of optional colors (nil = transparent).
public struct SpriteFrame: Equatable, Sendable {
    public let pixels: [[RGBA?]]

    public init(pixels: [[RGBA?]]) {
        self.pixels = pixels
    }

    public var height: Int { pixels.count }
    public var width: Int { pixels.first?.count ?? 0 }
}

/// A character drawn as pixel art in YAML (`fun/sprites/<id>.yaml`), or a drop-in image file.
public struct Sprite: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let frames: [SpriteFrame]
    /// Seconds each frame is shown when animating.
    public let frameDuration: Double
    /// When set, the UI shows this image file instead of the pixel frames.
    public let imageURL: URL?

    public init(id: String, name: String, frames: [SpriteFrame], frameDuration: Double = 0.6, imageURL: URL? = nil) {
        self.id = id
        self.name = name
        self.frames = frames
        self.frameDuration = frameDuration
        self.imageURL = imageURL
    }

    public var width: Int { frames.map(\.width).max() ?? 0 }
    public var height: Int { frames.map(\.height).max() ?? 0 }
}

/// A short line from the show, with where it came from.
public struct ShowQuote: Equatable, Sendable {
    public let text: String
    public let episode: String?

    public init(text: String, episode: String? = nil) {
        self.text = text
        self.episode = episode
    }
}

/// Moments the installer has something to say about. Keys under `moments:` in `fun/quotes.yaml` and in each voice file.
public enum Moment: String, CaseIterable, Sendable {
    case launch
    case password
    /// A question from `ask:` is on screen.
    case question
    case idle
    case working
    case waiting
    case success
    case failure
    case skipped
    case dryRun = "dry_run"
    case finished
    case finishedWithFailures = "finished_with_failures"
    case cancelled
}

/// Everything under `fun/`: the ASCII header, the sprites and the things they say.
public struct FunConfig: Sendable {
    /// ASCII art banner (`fun/header.txt`).
    public var header: String
    public var sprites: [String: Sprite]
    /// Sprite id of the narrator, who speaks whenever a step's character has no line of its own.
    public var speaker: String
    public var showQuotes: [ShowQuote]
    /// The narrator's lines keyed by moment.
    public var moments: [Moment: [String]]
    /// The narrator's extra working lines keyed by step id (from `fun/quotes.yaml` `steps:`, plus each step file's
    /// `quips:` when its mascot has no voice).
    public var stepQuips: [String: [String]]
    /// Attribution line for the About text.
    public var about: String?
    /// Each character's own lines keyed by sprite id (`fun/voices/`). Never holds the narrator, whose lines are
    /// `moments` and `stepQuips`.
    public var voices: [String: Voice]

    public init(header: String, sprites: [String: Sprite], speaker: String, showQuotes: [ShowQuote],
                moments: [Moment: [String]], stepQuips: [String: [String]], about: String? = nil, voices: [String: Voice] = [:]) {
        self.header = header
        self.sprites = sprites
        self.speaker = speaker
        self.showQuotes = showQuotes
        self.moments = moments
        self.stepQuips = stepQuips
        self.about = about
        self.voices = voices
    }

    /// Used when the config has no `fun/` directory at all, so nothing ever has to handle "no fun".
    public static let fallback = FunConfig(
        header: "SHAWN'S DOTFILES",
        sprites: [:],
        speaker: "lsp",
        showQuotes: [],
        moments: [
            .launch: ["Oh my glob. Let's set up this Mac."],
            .question: ["One quick question first."],
            .working: ["Working on it. Don't rush me."],
            .success: ["Nailed it."],
            .failure: ["Ugh. That one didn't work."],
            .finished: ["Done! This Mac is officially fabulous."],
        ],
        stepQuips: [:]
    )

    /// Exactly the sprite for `id`, or the narrator's when `id` is nil. Never a stand-in, so a name shown with it
    /// belongs to the art.
    public func sprite(_ id: String?) -> Sprite? {
        sprites[id ?? speaker]
    }

    /// The narrator's lines for `moment`, plus her lines for the step at `.working` when a step is given. They are one
    /// pool that the seed picks from. Never empty. During a step, `lines(for:stepID:mascot:)` gives the lines of
    /// whoever speaks.
    public func lines(for moment: Moment, stepID: String? = nil) -> [String] {
        var candidates: [String] = []
        if let stepID, moment == .working, let quips = stepQuips[stepID] { candidates += quips }
        candidates += moments[moment] ?? []
        if candidates.isEmpty, moment == .idle || moment == .working { candidates = showQuotes.map(\.text) }
        if candidates.isEmpty { candidates = FunConfig.fallback.moments[moment] ?? ["Oh my glob."] }
        return candidates
    }

    /// One of the narrator's lines for `moment`. Pass a changing `seed` (a counter, a random number) to rotate through them.
    public func line(for moment: Moment, stepID: String? = nil, seed: Int) -> String {
        let candidates = lines(for: moment, stepID: stepID)
        return candidates[abs(seed) % candidates.count]
    }

    // MARK: Loading

    public static let headerPath = "fun/header.txt"
    public static let quotesPath = "fun/quotes.yaml"
    public static let spritesDirectory = "fun/sprites"

    /// Loads `fun/` from the config directory. Problems are returned as issues; the result is always usable.
    public static func load(from config: InstallerConfig) -> (fun: FunConfig, issues: [ConfigIssue]) {
        var fun = FunConfig.fallback
        let collector = IssueCollector()

        if let header = try? String(contentsOf: config.url(headerPath), encoding: .utf8) {
            let trimmed = header.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { fun.header = trimmed }
        }

        loadQuotes(config: config, into: &fun, collector: collector)
        loadSprites(config: config, into: &fun, collector: collector)
        let voiceFiles = loadVoices(config: config, into: &fun, collector: collector)
        // A step file's quips belong to whoever speaks during that step.
        for step in config.steps where !step.quips.isEmpty {
            if let mascot = step.mascot, fun.hasVoice(mascot) {
                fun.voices[mascot]?.steps[step.id, default: []].insert(contentsOf: step.quips, at: 0)
            } else {
                fun.stepQuips[step.id, default: []].insert(contentsOf: step.quips, at: 0)
            }
        }

        for step in config.steps {
            if let mascot = step.mascot, fun.sprites[mascot] == nil, !fun.sprites.isEmpty {
                collector.add(.warning("mascot '\(mascot)' has no sprite in \(spritesDirectory)/ (known: \(fun.sprites.keys.sorted().joined(separator: ", ")))",
                                       at: SourceRef(file: step.file)))
            }
        }
        if !fun.sprites.isEmpty, fun.sprites[fun.speaker] == nil, FileManager.default.fileExists(atPath: config.url(quotesPath).path) {
            collector.add(.warning("speaker '\(fun.speaker)' has no sprite in \(spritesDirectory)/ (known: \(fun.sprites.keys.sorted().joined(separator: ", ")))",
                                   at: SourceRef(file: quotesPath)))
        }
        warnAboutVoices(config: config, fun: fun, files: voiceFiles, collector: collector)
        return (fun, collector.issues)
    }

    private static func loadQuotes(config: InstallerConfig, into fun: inout FunConfig, collector: IssueCollector) {
        let value: YAMLValue?
        do {
            value = try config.loadYAML(quotesPath)
        } catch let error as YAMLParseError {
            collector.add(.error(error.message, at: SourceRef(file: error.file, line: error.line)))
            return
        } catch {
            collector.add(.error(String(describing: error), at: SourceRef(file: quotesPath)))
            return
        }
        guard let map = value?.map else { return }
        let reader = MapReader(map: map, source: SourceRef(file: quotesPath), context: "quotes", collector: collector)

        if let speaker = reader.string("speaker") { fun.speaker = speaker }
        fun.about = reader.string("about")

        var quotes: [ShowQuote] = []
        for (index, element) in reader.list("show_quotes").enumerated() {
            if let text = element.string {
                quotes.append(ShowQuote(text: text))
            } else if let quoteMap = element.map {
                let quoteReader = MapReader(map: quoteMap, source: SourceRef(file: quotesPath), context: "show_quotes[\(index + 1)]", collector: collector)
                let text = quoteReader.requiredString("text")
                let episode = quoteReader.string("episode")
                quoteReader.allow("source", "note")
                quoteReader.finish()
                if !text.isEmpty { quotes.append(ShowQuote(text: text, episode: episode)) }
            } else {
                reader.error("show_quotes entry \(index + 1) must be a string or a mapping with 'text'", key: "show_quotes")
            }
        }
        fun.showQuotes = quotes

        if let moments = reader.reader("moments") {
            var loaded: [Moment: [String]] = [:]
            for moment in Moment.allCases {
                let lines = moments.stringList(moment.rawValue)
                if !lines.isEmpty { loaded[moment] = lines }
            }
            moments.finish()
            fun.moments = FunConfig.fallback.moments.merging(loaded) { _, new in new }
        }

        if let steps = reader.reader("steps") {
            for key in steps.map.keys {
                let lines = steps.stringList(key)
                if !lines.isEmpty { fun.stepQuips[key] = lines }
                if config.step(key) == nil {
                    steps.warning("quips for unknown step '\(key)'", key: key)
                }
            }
        }
        reader.finish()
    }

    private static func loadSprites(config: InstallerConfig, into fun: inout FunConfig, collector: IssueCollector) {
        let directory = config.url(spritesDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var sprites: [String: Sprite] = [:]
        for name in names.sorted() where name.hasSuffix(".yaml") || name.hasSuffix(".yml") {
            let relative = "\(spritesDirectory)/\(name)"
            do {
                guard let map = try config.loadYAML(relative)?.map else {
                    collector.add(.error("a sprite file must be a mapping with 'id', 'palette' and 'frames'", at: SourceRef(file: relative)))
                    continue
                }
                if let sprite = parseSprite(map, file: relative, config: config, collector: collector) {
                    if sprites[sprite.id] != nil {
                        collector.add(.error("sprite id '\(sprite.id)' is defined twice", at: SourceRef(file: relative)))
                    }
                    sprites[sprite.id] = sprite
                }
            } catch let error as YAMLParseError {
                collector.add(.error(error.message, at: SourceRef(file: error.file, line: error.line)))
            } catch {
                collector.add(.error(String(describing: error), at: SourceRef(file: relative)))
            }
        }
        fun.sprites = sprites
    }

    /// Parses one sprite mapping. Exposed for tools and tests.
    public static func parseSprite(_ map: YAMLMap, file: String, config: InstallerConfig?, collector: IssueCollector) -> Sprite? {
        let reader = MapReader(map: map, source: SourceRef(file: file), context: "sprite", collector: collector)
        let id = reader.requiredString("id")
        let name = reader.string("name", default: id)
        var frameMilliseconds = reader.int("frame_ms") ?? 600
        if frameMilliseconds <= 0 {
            reader.error("'frame_ms' must be a positive number of milliseconds (got \(frameMilliseconds))", key: "frame_ms")
            frameMilliseconds = 600
        }
        let imagePath = reader.string("image")

        var palette: [Character: RGBA?] = [".": nil, " ": nil]
        for pair in reader.stringPairs("palette") {
            guard pair.key.count == 1, let symbol = pair.key.first else {
                reader.error("palette keys must be single characters (got '\(pair.key)')", key: "palette")
                continue
            }
            if pair.value.lowercased() == "transparent" || pair.value.lowercased() == "none" {
                palette[symbol] = RGBA?.none
            } else if let color = RGBA(hex: pair.value) {
                palette[symbol] = color
            } else {
                reader.error("palette color for '\(pair.key)' is not a hex color like \"#B57EDC\" (got '\(pair.value)')", key: "palette")
            }
        }

        var frames: [SpriteFrame] = []
        for (index, frameText) in reader.stringList("frames").enumerated() {
            let rows = frameText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let width = rows.map(\.count).max(), width > 0 else {
                reader.error("frame \(index + 1) is empty", key: "frames")
                continue
            }
            var pixels: [[RGBA?]] = []
            for (rowIndex, row) in rows.enumerated() {
                if row.count != width {
                    reader.error("frame \(index + 1), row \(rowIndex + 1) is \(row.count) wide but the frame is \(width) wide", key: "frames")
                }
                var line: [RGBA?] = []
                for symbol in row {
                    if let color = palette[symbol] {
                        line.append(color)
                    } else {
                        reader.error("frame \(index + 1), row \(rowIndex + 1) uses '\(symbol)', which is not in the palette", key: "frames")
                        line.append(nil)
                    }
                }
                line += [RGBA?](repeating: nil, count: max(0, width - line.count))
                pixels.append(line)
            }
            frames.append(SpriteFrame(pixels: pixels))
        }
        // Animation swaps frames in place, so a frame of another size would make the character jump.
        if let first = frames.first {
            for (index, frame) in frames.enumerated().dropFirst()
            where frame.width != first.width || frame.height != first.height {
                reader.error("frame \(index + 1) is \(frame.width)×\(frame.height) but frame 1 is \(first.width)×\(first.height); every frame of a sprite must be the same size", key: "frames")
            }
        }
        reader.finish()

        var imageURL: URL?
        if let imagePath, let config {
            let candidate = config.url("fun/\(imagePath)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                imageURL = candidate
            } else {
                collector.add(.warning("sprite '\(id)': image fun/\(imagePath) not found; using the pixel frames", at: SourceRef(file: file)))
            }
        }

        guard !id.isEmpty else { return nil }
        if frames.isEmpty && imageURL == nil {
            collector.add(.error("sprite '\(id)' has no frames and no image", at: SourceRef(file: file)))
            return nil
        }
        return Sprite(id: id, name: name, frames: frames, frameDuration: Double(frameMilliseconds) / 1000, imageURL: imageURL)
    }
}
