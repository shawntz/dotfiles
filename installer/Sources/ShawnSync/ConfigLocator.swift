import Foundation
import ShawnCore

/// Small settings file the installer leaves for the CLI: `~/.config/shawn/config.yaml`.
public struct ShawnSettings: Equatable, Sendable {
    /// Checkout of the dotfiles repo on this Mac (e.g. `~/Developer/dotfiles`), if there is one.
    public var dotfilesRepo: String?
    /// Path of the config directory inside the repo.
    public var configPath: String

    public init(dotfilesRepo: String? = nil, configPath: String = "installer/config") {
        self.dotfilesRepo = dotfilesRepo
        self.configPath = configPath
    }

    public static func fileURL(environment: SystemEnvironment) -> URL {
        environment.home.appendingPathComponent(".config/shawn/config.yaml")
    }

    /// The settings, or the defaults when the file is missing or unreadable (see `loadReportingProblem`).
    public static func load(environment: SystemEnvironment) -> ShawnSettings {
        loadReportingProblem(environment: environment).settings
    }

    /// Like `load`, plus a sentence describing why the file was ignored, if it was (for `shawn doctor`).
    public static func loadReportingProblem(environment: SystemEnvironment) -> (settings: ShawnSettings, problem: String?) {
        var settings = ShawnSettings()
        let url = fileURL(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else { return (settings, nil) }
        let shown = PathExpansion.abbreviate(url.path, home: environment.home)
        let value: YAMLValue?
        do {
            value = try YAML.parseFile(url, displayName: shown)
        } catch {
            return (settings, "\(shown) could not be read and was ignored: \(error)")
        }
        guard let map = value?.map else {
            if value == nil { return (settings, nil) }
            return (settings, "\(shown) should be a mapping with dotfiles_repo and config_path; it was ignored")
        }
        if let repo = map["dotfiles_repo"]?.string, !repo.isEmpty { settings.dotfilesRepo = repo }
        if let path = map["config_path"]?.string, !path.isEmpty { settings.configPath = path }
        return (settings, nil)
    }

    public var yaml: String {
        var lines = ["# Written by Shawn's Dotfiles. Tells the `shawn` CLI where things live."]
        if let dotfilesRepo { lines.append("dotfiles_repo: \(Self.yamlScalar(dotfilesRepo))") }
        lines.append("config_path: \(Self.yamlScalar(configPath))")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Absolute URL of the repo checkout, if configured.
    public func repoURL(environment: SystemEnvironment) -> URL? {
        guard let dotfilesRepo else { return nil }
        return URL(fileURLWithPath: PathExpansion.expandTilde(dotfilesRepo, home: environment.home))
    }

    /// The config directory inside the checkout (`config_path` may also be absolute or start with `~`).
    public func configDirectoryURL(environment: SystemEnvironment) -> URL? {
        guard let repo = repoURL(environment: environment) else { return nil }
        if configPath.hasPrefix("/") || configPath == "~" || configPath.hasPrefix("~/") {
            return URL(fileURLWithPath: PathExpansion.expandTilde(configPath, home: environment.home)).standardizedFileURL
        }
        return repo.appendingPathComponent(configPath).standardizedFileURL
    }

    /// A path written so YAML reads back exactly the same string: plain when that is unambiguous,
    /// double-quoted otherwise (`#`, `: `, a lone `~` or `null`, leading/trailing spaces, quotes...).
    static func yamlScalar(_ value: String) -> String {
        let plain = value.range(of: #"^[A-Za-z0-9_./~][A-Za-z0-9_./~+@%()' -]*$"#, options: .regularExpression) != nil
        let nullLike: Set<String> = ["~", "null", "Null", "NULL"]
        if plain, !value.hasSuffix(" "), !nullLike.contains(value) { return value }
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }
}

/// Finds a config directory on disk.
public enum ConfigLocator {
    public struct Location: Equatable, Sendable {
        /// Which rule of the search order produced a location.
        public enum Origin: Equatable, Sendable {
            /// A `--config` argument.
            case explicit
            /// `$SHAWN_CONFIG_DIR`.
            case environmentVariable
            /// The checkout named in `~/.config/shawn/config.yaml`.
            case checkout
            /// A checkout found above the current directory or the executable.
            case development
            /// `~/.shawn/config`, the snapshot the installer leaves behind.
            case installed
            /// `Contents/Resources/config` in the app bundle.
            case bundled

            /// A directory the user edits (as opposed to a snapshot that GitHub may have superseded).
            public var isWorkingCopy: Bool {
                switch self {
                case .explicit, .environmentVariable, .checkout, .development: return true
                case .installed, .bundled: return false
                }
            }
        }

        public let url: URL
        public let source: ConfigSource
        public let origin: Origin

        public init(url: URL, source: ConfigSource, origin: Origin) {
            self.url = url
            self.source = source
            self.origin = origin
        }
    }

    public static let environmentVariable = "SHAWN_CONFIG_DIR"

    /// Search order:
    /// 1. `explicit` (a `--config` argument). When given, it is the only candidate, so a mistyped path
    ///    is reported instead of silently replaced by some other config
    /// 2. `$SHAWN_CONFIG_DIR`
    /// 3. the repo checkout named in `~/.config/shawn/config.yaml`
    /// 4. a checkout found by walking up from the current directory or the executable (development; not in a sandbox)
    /// 5. `~/.shawn/config` (the copy the installer leaves behind)
    /// 6. `Contents/Resources/config` in the app bundle
    public static func locate(explicit: URL? = nil, environment: SystemEnvironment, bundle: Bundle = .main,
                              currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> Location? {
        candidates(explicit: explicit, environment: environment, bundle: bundle, currentDirectory: currentDirectory)
            .first { ConfigLoader.isConfigDirectory($0.url) }
    }

    /// Every place `locate` would look, in order (whether or not it exists). Useful for diagnostics.
    public static func candidates(explicit: URL? = nil, environment: SystemEnvironment, bundle: Bundle = .main,
                                  currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> [Location] {
        if let explicit {
            let url = explicit.standardizedFileURL
            return [Location(url: url, source: .local(url.path), origin: .explicit)]
        }
        var result: [Location] = []
        if let fromEnvironment = environment.baseEnvironment[environmentVariable], !fromEnvironment.isEmpty {
            let url = URL(fileURLWithPath: PathExpansion.expandTilde(fromEnvironment, home: environment.home)).standardizedFileURL
            result.append(Location(url: url, source: .local(url.path), origin: .environmentVariable))
        }
        if let url = ShawnSettings.load(environment: environment).configDirectoryURL(environment: environment) {
            result.append(Location(url: url, source: .local(url.path), origin: .checkout))
        }
        if !environment.isSandbox {
            var starts = [currentDirectory]
            if let executable = bundle.executableURL { starts.append(executable.deletingLastPathComponent()) }
            for start in starts {
                if let url = walkUp(from: start), !result.contains(where: { $0.url.path == url.path }) {
                    result.append(Location(url: url, source: .local(url.path), origin: .development))
                }
            }
        }
        let installed = installedConfigDirectory(environment: environment)
        result.append(Location(url: installed, source: .local(installed.path), origin: .installed))
        if let bundled = bundledConfigDirectory(bundle: bundle) {
            result.append(Location(url: bundled, source: .bundled, origin: .bundled))
        }
        return result
    }

    /// `~/.shawn/config`: the snapshot of the config the installer copies for the CLI.
    public static func installedConfigDirectory(environment: SystemEnvironment) -> URL {
        environment.stateDirectory.appendingPathComponent("config")
    }

    /// `Contents/Resources/config` when running from the app bundle (also checked next to a helper in `Contents/Helpers`).
    public static func bundledConfigDirectory(bundle: Bundle = .main) -> URL? {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL { candidates.append(resources.appendingPathComponent("config")) }
        if let executable = bundle.executableURL {
            // …/Contents/Helpers/shawn → …/Contents/Resources/config
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/config"))
        }
        return candidates.first { ConfigLoader.isConfigDirectory($0) }
    }

    /// Looks for `config/installer.yaml` or `installer/config/installer.yaml` in `start` and its ancestors.
    static func walkUp(from start: URL, maxDepth: Int = 8) -> URL? {
        var directory = start.standardizedFileURL
        for _ in 0..<maxDepth {
            for relative in ["config", "installer/config"] {
                let candidate = directory.appendingPathComponent(relative)
                if ConfigLoader.isConfigDirectory(candidate) { return candidate.standardizedFileURL }
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
