import Foundation
import ShawnCore

/// An sRGB colour with alpha.
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

/// One frame of pixel art: rows of optional colours (nil = transparent).
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

/// Moments the installer has something to say about. Keys under `moments:` in `fun/quotes.yaml`.
public enum Moment: String, CaseIterable, Sendable {
    case launch
    case password
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
    /// Sprite id of whoever does the talking.
    public var speaker: String
    public var showQuotes: [ShowQuote]
    /// Original quips keyed by moment.
    public var moments: [Moment: [String]]
    /// Quips keyed by step id (from `fun/quotes.yaml` `steps:` and each step file's `quips:`).
    public var stepQuips: [String: [String]]
    /// Attribution line for the About text.
    public var about: String?

    public init(header: String, sprites: [String: Sprite], speaker: String, showQuotes: [ShowQuote],
                moments: [Moment: [String]], stepQuips: [String: [String]], about: String? = nil) {
        self.header = header
        self.sprites = sprites
        self.speaker = speaker
        self.showQuotes = showQuotes
        self.moments = moments
        self.stepQuips = stepQuips
        self.about = about
    }

    /// Used when the config has no `fun/` directory at all, so nothing ever has to handle "no fun".
    public static let fallback = FunConfig(
        header: "SHAWN'S DOTFILES",
        sprites: [:],
        speaker: "lsp",
        showQuotes: [],
        moments: [
            .launch: ["Oh my glob. Let's set up this Mac."],
            .working: ["Working on it. Don't rush me."],
            .success: ["Nailed it."],
            .failure: ["Ugh. That one didn't work."],
            .finished: ["Done! This Mac is officially fabulous."],
        ],
        stepQuips: [:]
    )

    /// The sprite for `id`, falling back to the speaker, then to any sprite at all.
    public func sprite(_ id: String?) -> Sprite? {
        if let id, let sprite = sprites[id] { return sprite }
        if let sprite = sprites[speaker] { return sprite }
        return sprites.sorted { $0.key < $1.key }.first?.value
    }

    /// Lines that fit `moment` (step-specific ones first when a step is given). Never empty.
    public func lines(for moment: Moment, stepID: String? = nil) -> [String] {
        var candidates: [String] = []
        if let stepID, moment == .working, let quips = stepQuips[stepID] { candidates += quips }
        candidates += moments[moment] ?? []
        if candidates.isEmpty, moment == .idle || moment == .working { candidates = showQuotes.map(\.text) }
        if candidates.isEmpty { candidates = FunConfig.fallback.moments[moment] ?? ["Oh my glob."] }
        return candidates
    }

    /// One line for `moment`. Pass a changing `seed` (a counter, a random number) to rotate through them.
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
        for step in config.steps where !step.quips.isEmpty {
            fun.stepQuips[step.id, default: []].insert(contentsOf: step.quips, at: 0)
        }
        loadSprites(config: config, into: &fun, collector: collector)

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
            } else if let colour = RGBA(hex: pair.value) {
                palette[symbol] = colour
            } else {
                reader.error("palette colour for '\(pair.key)' is not a hex colour like \"#B57EDC\" (got '\(pair.value)')", key: "palette")
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
                    if let colour = palette[symbol] {
                        line.append(colour)
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
