import Foundation

/// Screens `--snapshot` can render.
public enum SnapshotState: String, CaseIterable, Sendable {
    case loading
    case welcome
    case customize
    case running
    /// The sheet for a question from `ask:` on its first try, with an offered answer.
    case ask
    /// The same sheet after a reply was turned down, with the reason under the prompt.
    case askAgain = "ask-again"
    /// The administrator password sheet on its first try.
    case password
    /// The same sheet after a wrong password, with the reason under the prompt.
    case passwordAgain = "password-again"
    case question
    case attention
    case finished
    case failed
    case stopped
    /// A finished dry run: its log on screen and the way to the real run.
    case dryRunFinished = "dry-run-finished"
    case configError = "config-error"
}

/// The installer app's command line.
public struct LaunchOptions: Equatable, Sendable {
    /// Narrate instead of changing anything (the DRY RUN toggle starts on).
    public var dryRun = false
    /// Treat every item as not yet done.
    public var assumeFresh = false
    /// Ask the config's questions again on the first real run, offering the saved answers.
    public var askAgain = false
    public var configPath: String?
    public var allowRemote = true
    public var configRef: String?
    /// Run against `SystemEnvironment.sandbox(root:)` instead of this Mac.
    public var sandboxRoot: String?
    /// Dry run + fresh + start straight away, slowed down so it can be watched.
    public var demo = false
    /// Swap in the built-in simulation config and kinds (design review, UI tests).
    public var simulate = false
    public var snapshotPath: String?
    public var snapshotState: SnapshotState = .welcome
    public var snapshotSize = CGSize(width: 1100, height: 760)
    /// Pixels per point in the snapshot PNG.
    public var snapshotScale = 2
    /// Render the snapshot with the Increase Contrast palette.
    public var snapshotHighContrast = false
    /// Where in a run the screens built on the running screen show it (see `SnapshotProgress`).
    public var snapshotPoint: SnapshotPoint?
    public var showHelp = false

    public init() {}

    public var autoStart: Bool { demo }
    public var startsInDryRun: Bool { dryRun || demo }
    public var startsFresh: Bool { assumeFresh || demo }

    public static let usage = """
    Shawn's Dotfiles sets up this Mac from YAML.

    USAGE: ShawnsDotfiles [options]

      --dry-run               start with DRY RUN on (nothing on this Mac is changed)
      --fresh                 treat every item as not done yet (first run only)
      --ask                   ask the config's questions again, once, in the first real run that needs them
      --config DIR            use the config in DIR (no GitHub fetch unless --config-ref is given)
      --no-remote             do not fetch the latest config from GitHub
      --config-ref REF        fetch this branch, tag or commit of the config
      --sandbox DIR           run against a throwaway home/Applications tree under DIR
      --demo                  dry run + fresh + start immediately, paced for watching
      --simulate              built-in simulation config that exercises every screen
      --snapshot PATH         render the window to a PNG and exit (no window is shown)
      --snapshot-state STATE  \(SnapshotState.allCases.map(\.rawValue).joined(separator: ", "))
      --snapshot-size WxH     window size for the snapshot (default 1100x760)
      --snapshot-scale N      pixels per point, 1-3 (default 2)
      --snapshot-contrast C   standard or high (the Increase Contrast look)
      --snapshot-progress F   show the run F of the way through, 0 to 1 (screens that show a run)
      --snapshot-at-kind K    show the run as the first item of kind K starts (e.g. github)
      -h, --help              show this help
    """

    /// Parses the arguments after the executable name.
    public static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var remaining = arguments[...]

        func value(for flag: String, inline: String?) throws -> String {
            if let inline { return inline }
            guard let next = remaining.first, !next.hasPrefix("--") else { throw LaunchOptionsError.missingValue(flag) }
            remaining = remaining.dropFirst()
            return next
        }

        while let argument = remaining.first {
            remaining = remaining.dropFirst()

            // macOS adds its own arguments when launching from Finder or Xcode: `-psn_0_123`, `-NSDocumentRevisionsDebugMode YES`.
            if argument.hasPrefix("-psn_") { continue }
            if isCocoaDefaultsArgument(argument) {
                if let next = remaining.first, !next.hasPrefix("-") { remaining = remaining.dropFirst() }
                continue
            }

            var flag = argument
            var inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                flag = String(argument[..<equals])
                inline = String(argument[argument.index(after: equals)...])
            }

            switch flag {
            case "--dry-run": options.dryRun = true
            case "--fresh": options.assumeFresh = true
            case "--ask": options.askAgain = true
            case "--no-remote": options.allowRemote = false
            case "--demo": options.demo = true
            case "--simulate": options.simulate = true
            case "-h", "--help": options.showHelp = true
            case "--config": options.configPath = try value(for: flag, inline: inline)
            case "--config-ref": options.configRef = try value(for: flag, inline: inline)
            case "--sandbox": options.sandboxRoot = try value(for: flag, inline: inline)
            case "--snapshot": options.snapshotPath = try value(for: flag, inline: inline)
            case "--snapshot-state":
                let text = try value(for: flag, inline: inline)
                guard let state = SnapshotState(rawValue: text) else {
                    throw LaunchOptionsError.invalidValue(flag: flag, value: text,
                                                          expected: SnapshotState.allCases.map(\.rawValue).joined(separator: ", "))
                }
                options.snapshotState = state
            case "--snapshot-size":
                let text = try value(for: flag, inline: inline)
                guard let size = parseSize(text) else {
                    throw LaunchOptionsError.invalidValue(flag: flag, value: text, expected: "WIDTHxHEIGHT, e.g. 1100x760 (each 320-4000)")
                }
                options.snapshotSize = size
            case "--snapshot-contrast":
                let text = try value(for: flag, inline: inline)
                guard text == "standard" || text == "high" else {
                    throw LaunchOptionsError.invalidValue(flag: flag, value: text, expected: "standard or high")
                }
                options.snapshotHighContrast = text == "high"
            case "--snapshot-scale":
                let text = try value(for: flag, inline: inline)
                guard let scale = Int(text), (1...3).contains(scale) else {
                    throw LaunchOptionsError.invalidValue(flag: flag, value: text, expected: "1, 2 or 3")
                }
                options.snapshotScale = scale
            case "--snapshot-progress": options.snapshotPoint = try .fraction(parseProgress(value(for: flag, inline: inline)))
            case "--snapshot-at-kind": options.snapshotPoint = try .kind(value(for: flag, inline: inline))
            default:
                throw LaunchOptionsError.unknownArgument(argument)
            }

            if inline != nil, ["--dry-run", "--fresh", "--ask", "--no-remote", "--demo", "--simulate", "--help"].contains(flag) {
                throw LaunchOptionsError.unexpectedValue(flag)
            }
        }
        return options
    }

    static func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              (320...4000).contains(width), (320...4000).contains(height) else { return nil }
        return CGSize(width: width, height: height)
    }

    /// `-NSFoo value` / `-AppleFoo value` pairs that AppKit reads into the argument defaults domain.
    private static func isCocoaDefaultsArgument(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 else { return false }
        return argument.hasPrefix("-NS") || argument.hasPrefix("-Apple")
    }
}

public enum LaunchOptionsError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case unexpectedValue(String)
    case unknownArgument(String)
    case invalidValue(flag: String, value: String, expected: String)

    public var description: String {
        switch self {
        case .missingValue(let flag): return "\(flag) needs a value"
        case .unexpectedValue(let flag): return "\(flag) does not take a value"
        case .unknownArgument(let argument): return "unknown argument '\(argument)'"
        case .invalidValue(let flag, let value, let expected): return "\(flag): '\(value)' is not valid (expected \(expected))"
        }
    }
}
