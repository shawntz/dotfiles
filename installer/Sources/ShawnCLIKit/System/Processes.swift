import Darwin
import Foundation
import ShawnCore

/// A child process the CLI wants to run.
struct ProcessRequest: Sendable {
    /// Absolute path of the executable.
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var currentDirectory: URL?
    var timeout: TimeInterval?

    init(_ executable: String, _ arguments: [String] = [], environment: [String: String], currentDirectory: URL? = nil, timeout: TimeInterval? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
    }

    /// The command line as a person would type it.
    var displayString: String {
        Shell.join([(executable as NSString).lastPathComponent] + arguments)
    }
}

struct ProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    /// Set when the process could not be started at all.
    var launchError: String?

    var succeeded: Bool { exitCode == 0 && !timedOut && launchError == nil }
    /// stdout without surrounding whitespace.
    var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    var lines: [String] { output.isEmpty ? [] : output.components(separatedBy: "\n") }

    /// The last few meaningful lines of whatever the process said, for messages.
    func tail(_ count: Int = 3) -> String {
        if let launchError { return launchError }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        let lines = ANSI.strip(text).split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.filter { !$0.isEmpty }.suffix(count).joined(separator: " · ")
    }
}

/// Runs child processes. The real implementation is `SystemProcessLauncher`; tests substitute fakes.
protocol ProcessLaunching: Sendable {
    /// Runs with stdin from `/dev/null` and output captured, bounded by the request's timeout. Never throws:
    /// a missing executable or a timeout is reported in the result.
    func capture(_ request: ProcessRequest) async -> ProcessResult
    /// Runs attached to this terminal (inherits stdin/stdout/stderr) and returns the exit status.
    func interactive(_ request: ProcessRequest) async -> Int32
}

/// The `exec` half of fork/exec: replaces the running process.
struct ExecRequest: Sendable, Equatable {
    var path: String
    /// Full argv, including argv[0].
    var argv: [String]
    var environment: [String: String]
}

enum ExecOutcome: Sendable, Equatable {
    /// Only fakes ever return this; a real exec does not come back.
    case replaced
    /// execve failed with this errno.
    case failed(Int32)
}

protocol ProcessReplacing: Sendable {
    func replace(_ request: ExecRequest) -> ExecOutcome
}

struct SystemProcessReplacer: ProcessReplacing {
    func replace(_ request: ExecRequest) -> ExecOutcome {
        // Hand the new program a clean slate: the default disposition for every signal we may have
        // changed (ProcessRunner ignores SIGPIPE, the install runner catches SIGINT) and nothing blocked.
        for signalNumber in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGHUP] {
            signal(signalNumber, SIG_DFL)
        }
        var empty = sigset_t()
        sigemptyset(&empty)
        sigprocmask(SIG_SETMASK, &empty, nil)

        var argv: [UnsafeMutablePointer<CChar>?] = request.argv.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = request.environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        execve(request.path, argv, envp)
        let code = errno
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
        return .failed(code)
    }
}

struct SystemProcessLauncher: ProcessLaunching {
    func capture(_ request: ProcessRequest) async -> ProcessResult {
        do {
            let output = try await ProcessRunner.run(
                executable: request.executable,
                arguments: request.arguments,
                environment: request.environment,
                currentDirectory: request.currentDirectory?.path,
                timeout: request.timeout
            )
            return ProcessResult(exitCode: output.exitCode,
                                 stdout: String(decoding: output.stdout, as: UTF8.self),
                                 stderr: String(decoding: output.stderr, as: UTF8.self))
        } catch let error as ProcessRunnerError {
            if case .timedOut = error {
                return ProcessResult(exitCode: 124, stdout: "", stderr: "", timedOut: true)
            }
            return ProcessResult(exitCode: 127, stdout: "", stderr: "", launchError: error.description)
        } catch {
            return ProcessResult(exitCode: 130, stdout: "", stderr: "", launchError: "canceled")
        }
    }

    func interactive(_ request: ProcessRequest) async -> Int32 {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Self.spawnAttached(request))
            }
        }
    }

    /// posix_spawn with this process's stdio, then wait. While the child owns the terminal, Ctrl-C and
    /// Ctrl-\ are meant for it, so this process ignores them until the child is gone (like `system(3)`).
    private static func spawnAttached(_ request: ProcessRequest) -> Int32 {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&fileActions, descriptor)
        }
        if let directory = request.currentDirectory?.path {
            posix_spawn_file_actions_addchdir(&fileActions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([request.executable] + request.arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = request.environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        var previousInterrupt = sigaction()
        var previousQuit = sigaction()
        sigaction(SIGINT, &ignore, &previousInterrupt)
        sigaction(SIGQUIT, &ignore, &previousQuit)
        defer {
            sigaction(SIGINT, &previousInterrupt, nil)
            sigaction(SIGQUIT, &previousQuit, nil)
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, request.executable, &fileActions, &attributes, argv, envp)
        guard spawned == 0 else { return 127 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signalNumber = status & 0x7F
        return signalNumber == 0 ? (status >> 8) & 0xFF : 128 + signalNumber
    }
}

/// Short, read-only commands with a hard deadline (the status line's git probe, project listings).
///
/// Unlike `ProcessRunner` this never waits for a straggling grandchild to close the pipe: once the child
/// has exited and the pipe is quiet, or the deadline passes, it returns.
enum BoundedProcess {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    currentDirectory: String? = nil, timeout: TimeInterval) -> (status: Int32, stdout: String)? {
        var pipeDescriptors: [Int32] = [0, 0]
        guard pipe(&pipeDescriptors) == 0 else { return nil }
        let readEnd = pipeDescriptors[0], writeEnd = pipeDescriptors[1]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir(&fileActions, currentDirectory)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return nil
        }
        defer { close(readEnd) }
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(timeout)
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var status: Int32 = 0
        var exited = false
        var reachedEnd = false
        while true {
            if !exited, waitpid(pid, &status, WNOHANG) == pid { exited = true }
            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let ready = poll(&descriptor, 1, Int32(min(25, max(1, remaining * 1000))))
            if ready > 0 {
                while true {
                    let count = read(readEnd, &buffer, buffer.count)
                    if count > 0 {
                        collected.append(contentsOf: buffer[0..<count])
                    } else {
                        if count == 0 { reachedEnd = true }
                        break
                    }
                }
            }
            if reachedEnd || (exited && ready == 0) { break }
        }
        if !exited {
            // A child that has closed its output usually exits a moment later; wait for that, within the deadline.
            while deadline.timeIntervalSinceNow > 0 {
                if waitpid(pid, &status, WNOHANG) == pid {
                    exited = true
                    break
                }
                usleep(2_000)
            }
            if !exited {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                return nil
            }
        }
        let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return (code, String(decoding: collected, as: UTF8.self))
    }
}

/// Finds programs the way the user's shell would.
enum ToolLocator {
    /// Absolute path of `name`: an explicit path (with `~`), else the user's own `PATH`, then the
    /// installer's search path (so `~/.grok/bin` and Homebrew are found even from a bare environment).
    /// Never returns `excluding` (the running `shawn`), so a wrapper cannot exec itself in a loop.
    static func find(_ name: String, environment: SystemEnvironment, excluding: URL? = nil) -> String? {
        let fileManager = FileManager.default
        if name.contains("/") {
            let path = PathExpansion.expandTilde(name, home: environment.home)
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        let userPath = (environment.baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let excluded = excluding.map { resolvedPath($0.path) }
        for directory in (userPath + environment.searchPath) where !directory.isEmpty && seen.insert(directory).inserted {
            let candidate = PathExpansion.expandTilde(directory, home: environment.home) + "/" + name
            guard fileManager.isExecutableFile(atPath: candidate) else { continue }
            if let excluded, resolvedPath(candidate) == excluded { continue }
            return candidate
        }
        return nil
    }

    static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// git, but never the `/usr/bin/git` stub on a Mac without developer tools (running it opens the
    /// "install command line developer tools" dialog).
    static func git(environment: SystemEnvironment) -> String? {
        let fileManager = FileManager.default
        let brewGit = environment.brewPrefix.appendingPathComponent("bin/git").path
        if fileManager.isExecutableFile(atPath: brewGit) { return brewGit }
        if environment.isSandbox { return find("git", environment: environment) }
        let developerDirectories = [
            environment.baseEnvironment["DEVELOPER_DIR"],
            "/Library/Developer/CommandLineTools",
            "/Applications/Xcode.app/Contents/Developer",
            "/Applications/Xcode-beta.app/Contents/Developer",
        ].compactMap { $0 }
        if developerDirectories.contains(where: { fileManager.isExecutableFile(atPath: $0 + "/usr/bin/git") }) {
            return find("git", environment: environment) ?? "/usr/bin/git"
        }
        // A git elsewhere on PATH (not the stub) is fine too.
        if let found = find("git", environment: environment), found != "/usr/bin/git" { return found }
        return nil
    }
}

/// Where the running `shawn` lives.
enum ShawnBinary {
    static func current() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
        }
        return URL(fileURLWithPath: CommandLine.arguments.first ?? "shawn").standardizedFileURL
    }
}
