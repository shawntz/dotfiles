import Foundation
import SystemConfiguration

/// Everything the engine needs to know about the machine it is running on.
///
/// All paths flow through this value so tests (and `--sandbox` runs) can point
/// the whole installer at a throwaway directory instead of the real home folder.
public struct SystemEnvironment: Sendable {
    /// The user's home directory.
    public var home: URL
    /// `/Applications`.
    public var applicationsDirectory: URL
    /// `~/Applications`.
    public var userApplicationsDirectory: URL
    /// Homebrew prefix: `/opt/homebrew`.
    public var brewPrefix: URL
    /// `~/.shawn`: backups, state, the CLI's installed config.
    public var stateDirectory: URL
    /// `~/Library/Logs/ShawnsDotfiles`.
    public var logsDirectory: URL
    /// `~/Library/Caches/ShawnsDotfiles`.
    public var cacheDirectory: URL
    /// Scratch space for downloads and helper scripts.
    public var temporaryDirectory: URL
    public var userName: String
    /// The computer's friendly name ("Shawn's MacBook Pro").
    public var hostName: String
    /// Environment inherited by child processes before PATH etc. are applied.
    public var baseEnvironment: [String: String]
    /// Directory holding bundled helper executables (`shawn`, `WebAppShell`), when running from the app bundle.
    public var helpersDirectory: URL?
    /// True for throwaway environments (tests, `--sandbox`).
    public var isSandbox: Bool
    /// Identifies this run in backup and log paths: `20261114-221530`.
    public var runID: String
    /// The sudo binary. Only tests point this anywhere else.
    public var sudoPath: String = "/usr/bin/sudo"

    public init(home: URL, applicationsDirectory: URL, userApplicationsDirectory: URL, brewPrefix: URL,
                stateDirectory: URL, logsDirectory: URL, cacheDirectory: URL, temporaryDirectory: URL,
                userName: String, hostName: String, baseEnvironment: [String: String],
                helpersDirectory: URL? = nil, isSandbox: Bool = false, runID: String = SystemEnvironment.makeRunID()) {
        self.home = home
        self.applicationsDirectory = applicationsDirectory
        self.userApplicationsDirectory = userApplicationsDirectory
        self.brewPrefix = brewPrefix
        self.stateDirectory = stateDirectory
        self.logsDirectory = logsDirectory
        self.cacheDirectory = cacheDirectory
        self.temporaryDirectory = temporaryDirectory
        self.userName = userName
        self.hostName = hostName
        self.baseEnvironment = baseEnvironment
        self.helpersDirectory = helpersDirectory
        self.isSandbox = isSandbox
        self.runID = runID
    }

    // MARK: Factories

    /// The real machine.
    public static func live() -> SystemEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SystemEnvironment(
            home: home,
            applicationsDirectory: URL(fileURLWithPath: "/Applications"),
            userApplicationsDirectory: home.appendingPathComponent("Applications"),
            brewPrefix: URL(fileURLWithPath: "/opt/homebrew"),
            stateDirectory: home.appendingPathComponent(".shawn"),
            logsDirectory: home.appendingPathComponent("Library/Logs/ShawnsDotfiles"),
            cacheDirectory: home.appendingPathComponent("Library/Caches/ShawnsDotfiles"),
            temporaryDirectory: FileManager.default.temporaryDirectory,
            userName: NSUserName(),
            hostName: computerName(),
            baseEnvironment: ProcessInfo.processInfo.environment
        )
    }

    /// A self-contained fake machine rooted at `root` (nothing outside it is written by file operations).
    public static func sandbox(root: URL, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> SystemEnvironment {
        let home = root.appendingPathComponent("home")
        return SystemEnvironment(
            home: home,
            applicationsDirectory: root.appendingPathComponent("Applications"),
            userApplicationsDirectory: home.appendingPathComponent("Applications"),
            brewPrefix: root.appendingPathComponent("homebrew"),
            stateDirectory: home.appendingPathComponent(".shawn"),
            logsDirectory: home.appendingPathComponent("Library/Logs/ShawnsDotfiles"),
            cacheDirectory: home.appendingPathComponent("Library/Caches/ShawnsDotfiles"),
            temporaryDirectory: root.appendingPathComponent("tmp"),
            userName: NSUserName(),
            hostName: "Sandbox Mac",
            baseEnvironment: baseEnvironment,
            isSandbox: true
        )
    }

    public static func makeRunID(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: Derived paths

    public var brewExecutable: String { brewPrefix.appendingPathComponent("bin/brew").path }
    public var localBin: URL { home.appendingPathComponent(".local/bin") }
    /// Where files replaced during this run are moved.
    public var backupDirectory: URL { stateDirectory.appendingPathComponent("backups/\(runID)") }

    /// Directories searched for tools, most specific first.
    public var searchPath: [String] {
        var entries = [
            brewPrefix.appendingPathComponent("bin").path,
            brewPrefix.appendingPathComponent("sbin").path,
            localBin.path,
            home.appendingPathComponent(".grok/bin").path,
        ]
        if let helpersDirectory { entries.append(helpersDirectory.path) }
        entries += ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }

    /// Environment for child processes.
    public func processEnvironment(overrides: [String: String] = [:]) -> [String: String] {
        var environment = baseEnvironment
        // The installer decides these; whatever launched us should not.
        for key in ["SUDO_ASKPASS", "SSH_ASKPASS", "GIT_ASKPASS"] { environment.removeValue(forKey: key) }
        environment["HOME"] = home.path
        environment["USER"] = userName
        environment["LOGNAME"] = userName
        environment["PATH"] = searchPath.joined(separator: ":")
        if environment["SHELL"] == nil { environment["SHELL"] = "/bin/zsh" }
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        if environment["TERM"] == nil { environment["TERM"] = "dumb" }
        if environment["TMPDIR"] == nil { environment["TMPDIR"] = temporaryDirectory.path }
        // Never let a child sit waiting for terminal input we cannot give it.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        for (key, value) in overrides { environment[key] = value }
        return environment
    }

    /// Finds an executable by name on the installer's search path.
    public func resolveExecutable(_ tool: String) -> String? {
        if tool.contains("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        for directory in searchPath {
            let candidate = directory + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Template variables describing this machine.
    public var templateVariables: [String: String] {
        [
            "home": home.path,
            "user": userName,
            "hostname": hostName,
            // Every Mac that runs macOS 27 has Apple silicon. The variable stays for configs that use it.
            "arch": "arm64",
            "brew_prefix": brewPrefix.path,
            "applications": applicationsDirectory.path,
            "state_dir": stateDirectory.path,
        ]
    }

    // MARK: Probes

    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }
}
