import Foundation

/// A command the installer wants to run.
public struct Command: Sendable {
    /// Tool name (looked up on the installer's search path) or absolute path.
    public var executable: String
    public var arguments: [String]
    /// Extra environment on top of the installer's standard child environment.
    public var environment: [String: String] = [:]
    public var currentDirectory: URL?
    /// Bytes fed to stdin. When nil the child reads from `/dev/null`.
    public var stdin: Data?
    /// Run as root via `sudo -A` (the installer supplies the password).
    public var sudo = false
    /// The command runs as the user but may call `sudo` itself (Homebrew does, for pkg-based casks).
    /// Only commands marked this way, or with `sudo`, are told where the password helper is.
    public var mayUseSudo = false
    /// Variables removed from the child's environment after everything else has been applied.
    public var unsetEnvironment: [String] = []
    /// False for read-only probes: those run even in dry-run mode.
    public var mutates = true
    /// Capture output without streaming it to the log.
    public var quiet = false
    /// Log the command line before running it.
    public var echo = true
    /// Shown instead of the real command line (shorter, or hiding noise).
    public var label: String?
    public var timeout: TimeInterval?
    /// Called for every output line (ANSI-stripped), e.g. to pick out a device code.
    public var onLine: (@Sendable (String, OutputStreamKind) -> Void)?

    public init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Runs a script with `/bin/bash -c`. Extra `arguments` become `$1`, `$2`, ...
    public static func shell(_ script: String, arguments: [String] = []) -> Command {
        var command = Command("/bin/bash", ["-c", script, "shawn"] + arguments)
        let firstLine = script.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? script
        command.label = script.contains("\n") ? firstLine + " …" : script
        return command
    }

    // Fluent modifiers, so call sites read as one expression.

    public func env(_ overrides: [String: String]) -> Command {
        var copy = self
        copy.environment.merge(overrides) { _, new in new }
        return copy
    }

    public func cwd(_ directory: URL?) -> Command {
        var copy = self
        copy.currentDirectory = directory
        return copy
    }

    public func asRoot(_ enabled: Bool = true) -> Command {
        var copy = self
        copy.sudo = enabled
        return copy
    }

    /// Lets a user-level command that calls `sudo` internally reach the installer's password helper.
    public func allowingSudo(_ enabled: Bool = true) -> Command {
        var copy = self
        copy.mayUseSudo = enabled
        return copy
    }

    /// Removes variables from the child's environment (e.g. ones that would make a tool think it runs inside another tool).
    public func unsetting(_ names: [String]) -> Command {
        var copy = self
        copy.unsetEnvironment += names
        return copy
    }

    /// A probe: runs in dry-run mode too, output captured silently.
    public func readOnly() -> Command {
        var copy = self
        copy.mutates = false
        copy.quiet = true
        copy.echo = false
        return copy
    }

    public func silently() -> Command {
        var copy = self
        copy.quiet = true
        copy.echo = false
        return copy
    }

    public func labeled(_ label: String) -> Command {
        var copy = self
        copy.label = label
        return copy
    }

    public func timeout(_ seconds: TimeInterval) -> Command {
        var copy = self
        copy.timeout = seconds
        return copy
    }

    public func input(_ data: Data) -> Command {
        var copy = self
        copy.stdin = data
        return copy
    }

    public func watching(_ onLine: @escaping @Sendable (String, OutputStreamKind) -> Void) -> Command {
        var copy = self
        copy.onLine = onLine
        return copy
    }

    /// The command line as a person would type it.
    public var displayString: String {
        if let label { return (sudo ? "sudo " : "") + label }
        let name = executable.contains("/") ? (executable as NSString).lastPathComponent : executable
        return (sudo ? "sudo " : "") + Shell.join([name] + arguments)
    }
}

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// True when nothing was executed because of dry-run mode.
    public let wasDryRun: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, wasDryRun: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.wasDryRun = wasDryRun
    }

    public var succeeded: Bool { exitCode == 0 }
    /// stdout without surrounding whitespace.
    public var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var lines: [String] { output.isEmpty ? [] : output.components(separatedBy: "\n") }

    /// The last few lines of whatever the command printed, for error messages.
    public func tail(_ count: Int = 6) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        let lines = ANSI.strip(text).split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(count).joined(separator: "\n")
    }
}

public struct CommandError: Error, Sendable, CustomStringConvertible {
    public enum Reason: Sendable {
        case notFound
        case failed(exitCode: Int32, tail: String)
        case couldNotStart(String)
        /// The command was still running after its time limit and was stopped.
        case timedOut(seconds: TimeInterval)
    }

    public let command: String
    public let reason: Reason

    public var description: String {
        switch reason {
        case .notFound:
            return "'\(command)' is not installed (or not on the installer's PATH)"
        case .failed(let exitCode, let tail):
            return tail.isEmpty ? "\(command) failed (exit \(exitCode))" : "\(command) failed (exit \(exitCode)): \(tail)"
        case .couldNotStart(let message):
            return message
        case .timedOut(let seconds):
            return "\(command) did not finish within \(CommandError.describe(seconds))"
        }
    }

    public var isTimeout: Bool {
        if case .timedOut = reason { return true }
        return false
    }

    static func describe(_ seconds: TimeInterval) -> String {
        if seconds >= 120 { return "\(Int((seconds / 60).rounded())) minutes" }
        let whole = Int(seconds.rounded())
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }
}

/// Supplies administrator rights to commands that ask for them.
public protocol SudoProviding: Sendable {
    /// Makes sure `sudo -A` will work, prompting for the password if it has not been given yet.
    func ensureReady(reason: String) async throws
    /// Environment children need for `sudo` to find the password helper (empty until ready).
    var processEnvironment: [String: String] { get }
    /// Brackets a running command that is allowed to use sudo: called before its process runs any code, and once it
    /// has ended. `processID` is that process, which leads a session of its own; the password helper answers only
    /// helpers running in one of these sessions (that is, started inside such a command), and only between these calls.
    func beginPrivilegedCommand(processID: pid_t)
    func endPrivilegedCommand(processID: pid_t)
}

public extension SudoProviding {
    func beginPrivilegedCommand(processID: pid_t) {}
    func endPrivilegedCommand(processID: pid_t) {}
}

/// Runs `Command`s for one item: resolves tools, applies dry-run, handles sudo, streams output into the log.
public final class CommandRunner: @unchecked Sendable {
    public let environment: SystemEnvironment
    public let dryRun: Bool
    /// Pause after each simulated command so a dry run is watchable.
    public let dryRunDelay: TimeInterval
    public let itemID: String?
    private let sudo: (any SudoProviding)?
    private let sink: @Sendable (LogLine) -> Void

    public init(environment: SystemEnvironment, dryRun: Bool = false, dryRunDelay: TimeInterval = 0,
                sudo: (any SudoProviding)? = nil, itemID: String? = nil,
                sink: @escaping @Sendable (LogLine) -> Void = { _ in }) {
        self.environment = environment
        self.dryRun = dryRun
        self.dryRunDelay = dryRunDelay
        self.sudo = sudo
        self.itemID = itemID
        self.sink = sink
    }

    /// Runs the command and returns its result. A non-zero exit is NOT an error here. See `runChecked`.
    @discardableResult
    public func run(_ command: Command) async throws -> CommandResult {
        if command.mutates && dryRun {
            if command.echo {
                sink(LogLine("[dry-run] $ \(command.displayString)", style: .command, itemID: itemID))
            }
            if dryRunDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(dryRunDelay * 1_000_000_000))
            }
            return CommandResult(exitCode: 0, stdout: "", stderr: "", wasDryRun: true)
        }

        guard let resolved = environment.resolveExecutable(command.executable) else {
            throw CommandError(command: command.executable, reason: .notFound)
        }

        var executable = resolved
        var arguments = command.arguments
        // Only commands that may legitimately need administrator rights learn where the password helper is.
        let exposesSudo = command.sudo || command.mayUseSudo
        var overrides = exposesSudo ? (sudo?.processEnvironment ?? [:]) : [:]

        if command.sudo {
            guard let sudo else {
                throw CommandError(command: command.displayString,
                                   reason: .couldNotStart("\(command.displayString) needs administrator rights, which are not available in this run"))
            }
            try await sudo.ensureReady(reason: command.displayString)
            overrides = sudo.processEnvironment
            // sudo scrubs the environment, so anything the command needs is handed over via env(1).
            var wrapped = ["-A", "--"]
            if !command.environment.isEmpty {
                wrapped.append("/usr/bin/env")
                wrapped += command.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            }
            arguments = wrapped + [resolved] + arguments
            executable = environment.sudoPath
        }
        overrides.merge(command.environment) { _, new in new }

        if command.echo {
            sink(LogLine("$ \(command.displayString)", style: .command, itemID: itemID))
        }

        let splitter = OutputSplitter()
        let itemID = self.itemID
        let sink = self.sink
        let quiet = command.quiet
        let onLine = command.onLine
        let deliver: @Sendable (LineBuffer.Line, OutputStreamKind) -> Void = { line, kind in
            let text = ANSI.strip(line.text)
            if line.isProgress && text.trimmingCharacters(in: .whitespaces).isEmpty { return }
            if !quiet {
                sink(LogLine(text, style: kind == .stdout ? .stdout : .stderr, itemID: itemID, isProgress: line.isProgress))
            }
            if !line.isProgress { onLine?(text, kind) }
        }

        var childEnvironment = environment.processEnvironment(overrides: overrides)
        for name in command.unsetEnvironment { childEnvironment.removeValue(forKey: name) }

        // The password helper answers only inside this command's own session, and only while it runs.
        var privilegedProcess: pid_t?
        let privilegedSudo = exposesSudo ? sudo : nil
        defer { if let privilegedProcess { privilegedSudo?.endPrivilegedCommand(processID: privilegedProcess) } }

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: childEnvironment,
                currentDirectory: command.currentDirectory?.path,
                stdin: command.stdin,
                timeout: command.timeout,
                onChunk: { kind, data in
                    for line in splitter.append(data, kind) { deliver(line, kind) }
                },
                onSpawn: privilegedSudo.map { sudo in
                    { processID in
                        privilegedProcess = processID
                        sudo.beginPrivilegedCommand(processID: processID)
                    }
                }
            )
        } catch let error as ProcessRunnerError {
            if case .timedOut(_, let seconds) = error {
                throw CommandError(command: command.displayString, reason: .timedOut(seconds: seconds))
            }
            throw CommandError(command: command.displayString, reason: .couldNotStart(error.description))
        }
        for (line, kind) in splitter.flush() { deliver(line, kind) }

        return CommandResult(
            exitCode: output.exitCode,
            stdout: String(decoding: output.stdout, as: UTF8.self),
            stderr: String(decoding: output.stderr, as: UTF8.self)
        )
    }

    /// Like `run`, but a non-zero exit throws a `CommandError` carrying the tail of the output.
    @discardableResult
    public func runChecked(_ command: Command) async throws -> CommandResult {
        let result = try await run(command)
        guard result.succeeded else {
            throw CommandError(command: command.displayString, reason: .failed(exitCode: result.exitCode, tail: result.tail()))
        }
        return result
    }

    /// Runs a read-only probe and returns its trimmed stdout, or nil if the tool is missing or fails.
    public func capture(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval? = 60) async -> String? {
        var command = Command(executable, arguments).readOnly()
        command.timeout = timeout
        guard let result = try? await run(command), result.succeeded else { return nil }
        return result.output
    }

    /// True when a read-only probe exits 0.
    public func succeeds(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval? = 60) async -> Bool {
        var command = Command(executable, arguments).readOnly()
        command.timeout = timeout
        guard let result = try? await run(command) else { return false }
        return result.succeeded
    }

    public func toolExists(_ name: String) -> Bool {
        environment.resolveExecutable(name) != nil
    }
}

/// Per-stream line buffers. Fed only from the process pump thread, then flushed once it has finished.
private final class OutputSplitter: @unchecked Sendable {
    private var stdoutBuffer = LineBuffer()
    private var stderrBuffer = LineBuffer()

    func append(_ data: Data, _ kind: OutputStreamKind) -> [LineBuffer.Line] {
        switch kind {
        case .stdout: return stdoutBuffer.append(data)
        case .stderr: return stderrBuffer.append(data)
        }
    }

    func flush() -> [(LineBuffer.Line, OutputStreamKind)] {
        stdoutBuffer.flush().map { ($0, OutputStreamKind.stdout) } + stderrBuffer.flush().map { ($0, OutputStreamKind.stderr) }
    }
}
