import Foundation
import ShawnCore
import ShawnFun
import ShawnSync

/// Flags that apply to every command.
struct GlobalOptions: Sendable, Equatable {
    /// `--no-update` (or `SHAWN_NO_UPDATE=1`): no tool update before a wrapper, no self-update.
    var noUpdate = false
    var noColor = false
    /// `--config DIR`.
    var configPath: URL?
}

/// The replaceable parts of the outside world. `ShawnCLI.run` uses the real ones; tests swap in fakes.
struct CLIServices: Sendable {
    var launcher: any ProcessLaunching = SystemProcessLauncher()
    var replacer: any ProcessReplacing = SystemProcessReplacer()
    var readStdin: @Sendable () -> Data = { FileHandle.standardInput.readDataToEndOfFile() }
    var clock: any Clock = SystemClock()
    var desktop: any DesktopActions = SystemDesktop()
    /// nil → the real implementation for the context's environment.
    var inventory: (any Inventory)?
    var git: (any GitClient)?
    var builder: (any Builder)?
    var releases: (any ReleaseSource)?
    var remoteConfig: (any RemoteConfigRefreshing)?
    var statusGit: (any StatusGitProbing)?
    /// How the install runner talks to the person (password, questions). nil → the terminal.
    var interaction: (@Sendable (TerminalInteraction.Options) -> any UserInteraction)?

    init() {}
}

/// Everything one invocation of `shawn` works with.
final class CLIContext: @unchecked Sendable {
    var environment: SystemEnvironment
    let registry: ActionRegistry
    var terminal: Terminal
    let out: any OutputSink
    let err: any OutputSink
    var services: CLIServices
    /// The running binary (for `{{shawn_bin}}`, self-update and re-exec).
    let shawnBinary: URL
    let currentDirectory: URL
    let bundle: Bundle
    /// The arguments this invocation was started with (re-exec passes them on unchanged).
    var arguments: [String]
    var globals = GlobalOptions()

    private var cachedLocation: ConfigPlace??
    private var cachedLight: InstallerConfig??
    private var cachedFun: FunConfig?
    private var cachedCLI: (config: CLIConfig, issues: [ConfigIssue])?

    init(environment: SystemEnvironment, registry: ActionRegistry, terminal: Terminal, out: any OutputSink, err: any OutputSink,
         services: CLIServices = CLIServices(), shawnBinary: URL, currentDirectory: URL, bundle: Bundle = .main, arguments: [String] = []) {
        self.environment = environment
        self.registry = registry
        self.terminal = terminal
        self.out = out
        self.err = err
        self.services = services
        self.shawnBinary = shawnBinary
        self.currentDirectory = currentDirectory
        self.bundle = bundle
        self.arguments = arguments
    }

    var style: Style { terminal.style }
    var errorStyle: Style { terminal.errorStyle }

    // MARK: Messages

    /// A line on stderr in the house style: `✦ shawn: …`.
    func note(_ text: String) {
        err.line(errorStyle.accent("✦") + " " + text)
    }

    func warn(_ text: String) {
        err.line(errorStyle.warn("!") + " " + text)
    }

    func fail(_ text: String) {
        err.line(errorStyle.bad("✗") + " " + text)
    }

    // MARK: Where things are

    var settings: ShawnSettings { ShawnSettings.load(environment: environment) }

    /// The dotfiles checkout named in `~/.config/shawn/config.yaml`, when it exists and is a git repo.
    var checkout: URL? {
        guard let url = settings.repoURL(environment: environment) else { return nil }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) ? url : nil
    }

    /// `~/Developer` (or `$SHAWN_DEVELOPER_DIR`).
    var developerDirectory: URL {
        if let custom = environment.baseEnvironment["SHAWN_DEVELOPER_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: PathExpansion.expandTilde(custom, home: environment.home)).standardizedFileURL
        }
        return environment.home.appendingPathComponent("Developer")
    }

    var stateStore: FileStateStore { FileStateStore(directory: environment.stateDirectory.appendingPathComponent("state")) }

    func display(_ url: URL) -> String {
        PathExpansion.abbreviate(url.path, home: environment.home)
    }

    // MARK: Config

    /// The config directory the CLI uses for its YAML commands, quips and sprites.
    ///
    /// Same order as `ConfigLocator` (explicit, `$SHAWN_CONFIG_DIR`, checkout, development checkout,
    /// `~/.shawn/config`, app bundle), except that a config the self-updater fetched from GitHub
    /// (no checkout on this Mac) is preferred over the installed snapshot.
    func configLocation() -> ConfigPlace? {
        if let cachedLocation { return cachedLocation }
        var candidates = ConfigLocator.candidates(explicit: globals.configPath, environment: environment, bundle: bundle, currentDirectory: currentDirectory)
            .map { ConfigPlace(url: $0.url, source: $0.source) }
        if let fetched = stateStore.load().remoteConfigRoot {
            let url = URL(fileURLWithPath: fetched)
            let installed = ConfigLocator.installedConfigDirectory(environment: environment).standardizedFileURL.path
            let position = candidates.firstIndex { $0.url.standardizedFileURL.path == installed } ?? candidates.count
            candidates.insert(ConfigPlace(url: url, source: .local(url.path)), at: position)
        }
        let location = candidates.first { ConfigLoader.isConfigDirectory($0.url) }
        cachedLocation = .some(location)
        return location
    }

    /// `installer.yaml` only (name, vars, remote). That is enough for YAML commands and the fun, and it is fast.
    func lightConfig() -> InstallerConfig? {
        if let cachedLight { return cachedLight }
        let config = configLocation().map { LightConfig.load($0) }
        cachedLight = .some(config)
        return config
    }

    var fun: FunConfig {
        if let cachedFun { return cachedFun }
        let fun = lightConfig().map { FunConfig.load(from: $0).fun } ?? .fallback
        cachedFun = fun
        return fun
    }

    var cli: CLIConfig { cliWithIssues.config }

    var cliWithIssues: (config: CLIConfig, issues: [ConfigIssue]) {
        if let cachedCLI { return cachedCLI }
        let loaded = lightConfig().map { CLIConfig.load(from: $0) } ?? (CLIConfig(), [])
        cachedCLI = loaded
        return loaded
    }

    /// Forget everything loaded from the config (after the self-updater pulled new commits).
    func invalidateConfig() {
        cachedLocation = nil
        cachedLight = nil
        cachedFun = nil
        cachedCLI = nil
    }

    /// `{{variables}}` for YAML commands: machine built-ins, config `vars:`, and `{{shawn_bin}}`.
    func templateVars() -> TemplateVars {
        var vars = lightConfig().map { ActionContext.makeVars(config: $0, environment: environment) } ?? TemplateVars(environment.templateVariables)
        vars["shawn_bin"] = shawnBinary.path
        return vars
    }

    /// Environment for programs the user runs through shawn: their own environment (not the installer's
    /// scrubbed one), with the installer's tool directories appended to PATH so a bare login still
    /// finds `claude`, `grok` and Homebrew, and without the self-update loop marker.
    func childEnvironment(_ overrides: [String: String] = [:]) -> [String: String] {
        var variables = environment.baseEnvironment
        variables.removeValue(forKey: SelfUpdateRunner.reexecMarker)
        var path = (variables["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in environment.searchPath where !path.contains(directory) { path.append(directory) }
        variables["PATH"] = path.joined(separator: ":")
        variables["SHAWN_BIN"] = shawnBinary.path
        for (key, value) in overrides { variables[key] = value }
        return variables
    }

    // MARK: Services with environment-dependent defaults

    var launcher: any ProcessLaunching { services.launcher }

    var git: any GitClient {
        services.git ?? SystemGitClient(launcher: services.launcher, environment: environment)
    }

    var inventory: any Inventory {
        services.inventory ?? BrewInventory(launcher: services.launcher, environment: environment)
    }

    var builder: any Builder {
        services.builder ?? SwiftBuilder(launcher: services.launcher, environment: environment)
    }

    var releases: any ReleaseSource {
        services.releases ?? GitHubReleaseSource()
    }

    var remoteConfig: any RemoteConfigRefreshing {
        services.remoteConfig ?? ResolverRemoteConfig(registry: registry, environment: environment, bundle: bundle)
    }

    var statusGit: any StatusGitProbing {
        services.statusGit ?? SystemStatusGit(environment: environment)
    }

    func interaction(_ options: TerminalInteraction.Options) -> any UserInteraction {
        services.interaction?(options) ?? TerminalInteraction(options: options, style: errorStyle)
    }

    /// Runs a tool found on the user's PATH and captures its output.
    func capture(_ tool: String, _ arguments: [String], in directory: URL? = nil, timeout: TimeInterval? = 60) async -> ProcessResult {
        guard let path = ToolLocator.find(tool, environment: environment) else {
            return ProcessResult(exitCode: ExitCode.notFound, stdout: "", stderr: "", launchError: "\(tool) is not installed")
        }
        return await launcher.capture(ProcessRequest(path, arguments, environment: childEnvironment(), currentDirectory: directory, timeout: timeout))
    }
}

/// A config directory and how it was found.
struct ConfigPlace: Sendable, Equatable {
    let url: URL
    let source: ConfigSource
}

/// Reads only `installer.yaml` (leniently): the CLI needs the name, vars and remote, not the whole plan.
enum LightConfig {
    static func load(_ location: ConfigPlace) -> InstallerConfig {
        let root = location.url.standardizedFileURL
        var meta = ConfigMeta(schema: ShawnCore.schemaVersion, name: "Dotfiles")
        if let map = (try? YAML.parseFile(root.appendingPathComponent(ConfigLoader.metaFileName)))??.map {
            if let name = map["name"]?.string { meta.name = name }
            meta.tagline = map["tagline"]?.string
            if let schema = map["schema"]?.int { meta.schema = schema }
            if let remote = map["remote"]?.map, let repo = remote["repo"]?.string {
                meta.remote = RemoteConfigRef(repo: repo, branch: remote["branch"]?.string ?? "main", path: remote["path"]?.string ?? "installer/config")
            }
            for entry in map["vars"]?.map?.entries ?? [] {
                if let value = entry.value.string { meta.vars[entry.key] = value }
            }
        }
        return InstallerConfig(root: root, meta: meta, steps: [], source: location.source)
    }
}
