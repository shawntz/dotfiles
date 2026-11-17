import Foundation
import ShawnCore

/// One character's own lines (`fun/voices/<id>.yaml`). The narrator has no voice file, because her lines are in `fun/quotes.yaml`.
public struct Voice: Equatable, Sendable {
    /// Sprite id of the character who says these lines.
    public let id: String
    /// Lines keyed by moment. The loader keeps only step moments, because the narrator speaks at every other moment.
    public var moments: [Moment: [String]]
    /// Extra working lines keyed by step id, said only while that step runs.
    public var steps: [String: [String]]

    public init(id: String, moments: [Moment: [String]] = [:], steps: [String: [String]] = [:]) {
        self.id = id
        self.moments = moments
        self.steps = steps
    }

    /// The lines for `moment`, plus the step's own lines at `.working`. They are one pool that `FunConfig.say` picks
    /// from by seed, so neither kind shows first. The step's lines lead the list, so the snapshots can show one.
    /// May be empty.
    public func lines(for moment: Moment, stepID: String?) -> [String] {
        var candidates: [String] = []
        if let stepID, moment == .working { candidates += steps[stepID] ?? [] }
        candidates += moments[moment] ?? []
        return candidates
    }
}

/// A line together with who says it and the sprite drawn next to it, so the name and the art always belong to the speaker.
public struct SpokenLine: Equatable, Sendable {
    /// Sprite id of whoever says the line.
    public let speakerID: String
    /// Exactly the sprite for `speakerID`, or nil when that character has none. Never another character's sprite.
    public let sprite: Sprite?
    public let text: String

    public init(speakerID: String, sprite: Sprite?, text: String) {
        self.speakerID = speakerID
        self.sprite = sprite
        self.text = text
    }

    /// The name to show next to the line, or nil when there is no sprite to show.
    public var name: String? { sprite?.name }
}

extension Moment {
    /// The moments a step's character can speak at, which are the ones `InstallerModel.quipMoment` can return while a
    /// run is on screen. The narrator alone speaks at launch, idle, finished and finished_with_failures.
    ///
    /// `.question` is here because an item can ask during a step, and the simulation's does. A real run asks its `ask:`
    /// questions before the first step, so the narrator says those lines, and `warnAboutVoices` does not ask a voice
    /// for question lines.
    public static let stepMoments: [Moment] = [.working, .success, .failure, .skipped, .waiting, .question, .password, .cancelled, .dryRun]
}

extension FunConfig {
    public static let voicesDirectory = "fun/voices"

    /// True when `id` has a voice and a sprite and is not the narrator, so it can speak for itself.
    func hasVoice(_ id: String) -> Bool {
        id != speaker && sprites[id] != nil && voices[id] != nil
    }

    /// Who says the line for `moment` during a step whose mascot is `mascot`. The mascot speaks when it has a sprite,
    /// a voice and lines for the moment; otherwise the narrator (`speaker`) does.
    public func speakerID(for moment: Moment, stepID: String? = nil, mascot: String?) -> String {
        guard Moment.stepMoments.contains(moment), let mascot, hasVoice(mascot),
              let voice = voices[mascot], !voice.lines(for: moment, stepID: stepID).isEmpty else { return speaker }
        return mascot
    }

    /// The lines of whoever speaks at `moment`, the mascot's own or the narrator's. Never empty.
    public func lines(for moment: Moment, stepID: String? = nil, mascot: String?) -> [String] {
        let talker = speakerID(for: moment, stepID: stepID, mascot: mascot)
        if talker != speaker, let voice = voices[talker] { return voice.lines(for: moment, stepID: stepID) }
        return lines(for: moment, stepID: stepID)
    }

    /// The working lines written for step `stepID` alone, from whoever speaks while it works. May be empty.
    public func stepLines(_ stepID: String, mascot: String?) -> [String] {
        let talker = speakerID(for: .working, stepID: stepID, mascot: mascot)
        if talker != speaker { return voices[talker]?.steps[stepID] ?? [] }
        return stepQuips[stepID] ?? []
    }

    /// One line for `moment`, with who says it and their sprite. Pass a changing `seed` to rotate through the lines.
    public func say(_ moment: Moment, stepID: String? = nil, mascot: String?, seed: Int) -> SpokenLine {
        let talker = speakerID(for: moment, stepID: stepID, mascot: mascot)
        let candidates = lines(for: moment, stepID: stepID, mascot: mascot)
        return SpokenLine(speakerID: talker, sprite: sprites[talker], text: candidates[abs(seed) % candidates.count])
    }

    // MARK: Loading

    /// Reads every `.yaml` and `.yml` file in `fun/voices/` into `fun.voices`. It needs the speaker and the sprites,
    /// so it runs after both. Returns the file each voice came from, for the warnings in `warnAboutVoices`.
    @discardableResult
    static func loadVoices(config: InstallerConfig, into fun: inout FunConfig, collector: IssueCollector) -> [String: String] {
        let directory = config.url(voicesDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var voices: [String: Voice] = [:]
        var files: [String: String] = [:]
        for name in names.sorted() where name.hasSuffix(".yaml") || name.hasSuffix(".yml") {
            let relative = "\(voicesDirectory)/\(name)"
            do {
                guard let map = try config.loadYAML(relative)?.map else {
                    collector.add(.error("a voice file must be a mapping with 'id', 'moments' and 'steps'", at: SourceRef(file: relative)))
                    continue
                }
                if let voice = parseVoice(map, file: relative, config: config, fun: fun, collector: collector) {
                    if voices[voice.id] != nil {
                        collector.add(.error("voice '\(voice.id)' is defined twice", at: SourceRef(file: relative)))
                    }
                    voices[voice.id] = voice
                    files[voice.id] = relative
                }
            } catch let error as YAMLParseError {
                collector.add(.error(error.message, at: SourceRef(file: error.file, line: error.line)))
            } catch {
                collector.add(.error(String(describing: error), at: SourceRef(file: relative)))
            }
        }
        fun.voices = voices
        return files
    }

    /// Parses one voice mapping. Returns nil, after reporting why, for a voice that could never speak: one with no id,
    /// the narrator's id or no sprite. Such a voice gets no warnings, only its errors.
    private static func parseVoice(_ map: YAMLMap, file: String, config: InstallerConfig, fun: FunConfig,
                                   collector: IssueCollector) -> Voice? {
        let reader = MapReader(map: map, source: SourceRef(file: file), context: "voice", collector: collector)
        let id = reader.requiredString("id")
        let idSource = SourceRef(file: file, line: map.line(of: "id"))
        var speaks = !id.isEmpty
        if speaks, id == fun.speaker {
            collector.add(.error("'\(id)' is the narrator; the narrator's lines belong in \(quotesPath)", at: idSource))
            speaks = false
        } else if speaks, fun.sprites[id] == nil {
            let others = Set(fun.sprites.keys).subtracting([fun.speaker])
            var hint = ""
            if let match = MapReader.closestMatch(to: id, in: others) {
                hint = ". Did you mean '\(match)'?"
            } else if !others.isEmpty {
                hint = " (known: \(others.sorted().joined(separator: ", ")))"
            }
            collector.add(.error("voice '\(id)' has no sprite in \(spritesDirectory)/\(hint)", at: idSource))
            speaks = false
        }

        var moments: [Moment: [String]] = [:]
        if let momentsReader = reader.reader("moments") {
            for moment in Moment.allCases {
                // Read every moment, present or not, so that finish() can suggest any of them for a typo.
                let lines = momentsReader.stringList(moment.rawValue)
                guard momentsReader.has(moment.rawValue) else { continue }
                if Moment.stepMoments.contains(moment) {
                    if !lines.isEmpty { moments[moment] = lines }
                } else if speaks {
                    collector.add(.warning("\(id) never speaks at '\(moment.rawValue)'; the narrator does",
                                           at: SourceRef(file: file, line: momentsReader.map.line(of: moment.rawValue))))
                }
            }
            momentsReader.finish()
        }

        var steps: [String: [String]] = [:]
        if let stepsReader = reader.reader("steps") {
            for key in stepsReader.map.keys {
                let lines = stepsReader.stringList(key)
                if !lines.isEmpty { steps[key] = lines }
                guard speaks else { continue }
                let source = SourceRef(file: file, line: stepsReader.map.line(of: key))
                if let step = config.step(key) {
                    guard step.mascot != id else { continue }
                    let host = step.mascot.map { "has mascot '\($0)'" } ?? "has no mascot"
                    collector.add(.warning("\(id) never says these lines, because step '\(key)' \(host)", at: source))
                } else {
                    collector.add(.warning("lines for unknown step '\(key)'", at: source))
                }
            }
        }
        reader.finish()

        guard speaks else { return nil }
        return Voice(id: id, moments: moments, steps: steps)
    }

    /// Warnings about who ends up speaking, once the step files' `quips:` are in place. It reports each gap in a voice
    /// once: a step moment other than question that it has no lines for in any of its steps, or a single step without
    /// working lines. A voice with no question lines gets no warning, because a real run asks its questions before
    /// the first step. It names a step whose mascot has no voice only when some voice exists, so a config without
    /// voices stays quiet.
    static func warnAboutVoices(config: InstallerConfig, fun: FunConfig, files: [String: String], collector: IssueCollector) {
        guard !fun.voices.isEmpty else { return }
        for (id, voice) in fun.voices.sorted(by: { $0.key < $1.key }) {
            let source = SourceRef(file: files[id] ?? "\(voicesDirectory)/\(id).yaml")
            let hosted = config.steps.filter { $0.mascot == id }.map(\.id)
            guard !hosted.isEmpty else {
                collector.add(.warning("\(id) is not the mascot of any step, so these lines never show", at: source))
                continue
            }
            let silent = Moment.stepMoments.filter { moment in
                moment != .question && hosted.allSatisfy { voice.lines(for: moment, stepID: $0).isEmpty }
            }
            if !silent.isEmpty {
                let moments = silent.map(\.rawValue).joined(separator: ", ")
                collector.add(.warning("\(id) has no lines for \(moments), so the narrator speaks then during \(hosted.joined(separator: ", "))",
                                       at: source))
            }
            if !silent.contains(.working) {
                for stepID in hosted where voice.lines(for: .working, stepID: stepID).isEmpty {
                    collector.add(.warning("\(id) has no 'working' lines for step '\(stepID)', so the narrator speaks then", at: source))
                }
            }
        }
        for step in config.steps {
            guard let mascot = step.mascot, mascot != fun.speaker, fun.sprites[mascot] != nil, fun.voices[mascot] == nil else { continue }
            collector.add(.warning("mascot '\(mascot)' has no voice in \(voicesDirectory)/, so the narrator speaks during this step",
                                   at: SourceRef(file: step.file)))
        }
    }
}
