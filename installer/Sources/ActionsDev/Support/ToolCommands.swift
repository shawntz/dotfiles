import Foundation
import ShawnCore

/// Commands for third-party CLIs whose behaviour depends on inherited environment variables.
///
/// Some variables have to be removed rather than set: a stray `GH_TOKEN` makes `gh auth login`
/// refuse to run, and `CLAUDECODE` makes the skills CLI and `claude` behave as if they were running
/// inside an agent. The tool itself is the process that runs, so a time-out or a failure to start
/// names it; the label keeps the log readable.
enum ToolCommand {
    /// - Parameters:
    ///   - executable: absolute path of the tool (resolve it first, so a missing tool is reported by name).
    ///   - unset: variables removed from the child's environment.
    ///   - set: variables added to it. A name may be in both lists; the value in `set` wins.
    ///   - display: what the tool is called in the log (`gh`, `claude`, ...).
    static func make(_ executable: String, _ arguments: [String], unset: [String] = [], set: [String: String] = [:],
                     display: String) -> Command {
        let variables = set.filter { isValidName($0.key) }
        // The runner removes `unsetEnvironment` after applying `environment`, so a name being set must not be removed too.
        let removed = Set(unset).filter { isValidName($0) && variables[$0] == nil }.sorted()
        return Command(executable, arguments)
            .env(variables)
            .unsetting(removed)
            .labeled(Shell.join([display] + arguments))
    }

    /// Names present in the inherited environment that match any of the prefixes (or equal one of `exact`).
    static func inherited(_ environment: SystemEnvironment, prefixes: [String] = [], exact: [String] = []) -> [String] {
        environment.baseEnvironment.keys.filter { name in
            exact.contains(name) || prefixes.contains(where: { name.hasPrefix($0) })
        }.sorted()
    }

    /// Variables that make AI CLIs believe they run inside an agent session (`CLAUDECODE`, `CLAUDE_CODE_*`).
    static func agentSessionVariables(_ environment: SystemEnvironment) -> [String] {
        inherited(environment, prefixes: ["CLAUDE_CODE"], exact: ["CLAUDECODE"])
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("=") && !name.contains(" ")
    }
}

/// Finds a real git without ever touching `/usr/bin/git`.
///
/// On a Mac without the Command Line Tools, `/usr/bin/git` is a shim that pops the
/// "install developer tools" dialog. Only binaries that are git itself are used: Homebrew's,
/// the Command Line Tools', or the selected/installed Xcode's.
enum GitTool {
    static let commandLineToolsGit = "/Library/Developer/CommandLineTools/usr/bin/git"
    static let xcodeSelectLink = "/var/db/xcode_select_link"

    static func candidates(_ environment: SystemEnvironment) -> [String] {
        var paths = [environment.brewPrefix.appendingPathComponent("bin/git").path, commandLineToolsGit]
        if let developerDirectory = try? FileManager.default.destinationOfSymbolicLink(atPath: xcodeSelectLink),
           developerDirectory.hasPrefix("/") {
            paths.append(developerDirectory + "/usr/bin/git")
        }
        paths.append(environment.applicationsDirectory.appendingPathComponent("Xcode.app/Contents/Developer/usr/bin/git").path)
        return paths
    }

    static func locate(_ environment: SystemEnvironment) -> String? {
        candidates(environment).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func missingError(for purpose: String) -> ActionError {
        ActionError("git is not available yet, so \(purpose) cannot run",
                    hint: "Let the bootstrap step install the Xcode Command Line Tools (or `brew install git`), then run this again")
    }

    /// Variables that would point git at some other repository or config file.
    ///
    /// In a sandbox the config-location variables go too, so tests can never write the
    /// developer's real git config; on a real Mac a deliberate `XDG_CONFIG_HOME` is respected.
    static func isolationVariables(_ environment: SystemEnvironment) -> [String] {
        var names = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"]
        if environment.isSandbox {
            names += ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "XDG_CONFIG_HOME"]
            names += ToolCommand.inherited(environment, prefixes: ["GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"])
        }
        return names
    }

    static func command(_ git: String, _ arguments: [String], environment: SystemEnvironment, set: [String: String] = [:]) -> Command {
        ToolCommand.make(git, arguments, unset: isolationVariables(environment), set: set, display: "git")
    }

    /// Value of a global git config key (last one wins, as git reads it), or nil when unset or unreadable.
    static func globalValue(_ key: String, typed type: String? = nil, git: String, context: ActionContext) async -> String? {
        var arguments = ["config", "--global"]
        if let type { arguments.append("--type=\(type)") }
        arguments += ["--get", key]
        guard let result = try? await context.commands.run(command(git, arguments, environment: context.environment).timeout(30).readOnly()),
              result.succeeded else { return nil }
        return String(result.stdout.dropLast(result.stdout.hasSuffix("\n") ? 1 : 0))
    }

    /// Every value of a multi-valued global key.
    static func globalValues(_ key: String, git: String, context: ActionContext) async -> [String] {
        let arguments = ["config", "--global", "--get-all", key]
        guard let result = try? await context.commands.run(command(git, arguments, environment: context.environment).timeout(30).readOnly()),
              result.succeeded else { return [] }
        return result.stdout.components(separatedBy: "\n").dropLast(result.stdout.hasSuffix("\n") ? 1 : 0).map { $0 }
    }
}

extension URL {
    /// The path as it should appear in a config file that understands `~` (ssh_config, messages).
    func tildePath(home: URL) -> String {
        PathExpansion.abbreviate(path, home: home)
    }

    /// Where a chain of symbolic links ends. Only the links themselves are resolved, not the folders
    /// above them, so a path under the home folder still reads as one.
    func followingLinks() -> URL {
        var current = self
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { return current }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
        }
        return current
    }
}

/// How long a time limit is, in words: "15 minutes", "1 second".
enum TimeLimit {
    static func describe(_ interval: TimeInterval) -> String {
        if interval >= 120 { return "\(Int((interval / 60).rounded())) minutes" }
        let seconds = Int(interval.rounded())
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}

extension CommandRunner {
    /// `run`, with a time-out reported as an `ActionError` that says what to try next.
    /// The message still names the command that hung.
    @discardableResult
    func run(_ command: Command, hintIfTimedOut hint: String) async throws -> CommandResult {
        do {
            return try await run(command)
        } catch let error as CommandError where error.isTimeout {
            throw ActionError(error.description, hint: hint)
        }
    }
}

/// Dry runs on a Mac where earlier steps have not really run.
enum DryRun {
    /// In a dry run a tool that an earlier step installs is expected to be missing: say what would
    /// happen and report success. Returns nil in a real run, where the caller should fail instead.
    static func whenMissing(_ tool: String, would action: String, _ context: ActionContext) -> ActionOutcome? {
        guard context.dryRun else { return nil }
        context.info("[dry-run] \(tool) is not installed yet (an earlier step installs it); would \(action)")
        return .done("would \(action)")
    }
}
