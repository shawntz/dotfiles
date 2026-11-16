import Darwin
import Foundation

public enum OutputStreamKind: String, Sendable {
    case stdout
    case stderr
}

public struct ProcessOutput: Sendable {
    /// Exit status; `128 + signal` when the process was killed by a signal.
    public let exitCode: Int32
    public let terminationSignal: Int32?
    public let stdout: Data
    public let stderr: Data
}

public enum ProcessRunnerError: Error, Sendable, CustomStringConvertible {
    case spawnFailed(executable: String, code: Int32)
    case timedOut(executable: String, seconds: TimeInterval)

    public var description: String {
        switch self {
        case .spawnFailed(let executable, let code):
            return "could not start \(executable): \(String(cString: strerror(code)))"
        case .timedOut(let executable, let seconds):
            return "\(executable) did not finish within \(Int(seconds)) seconds"
        }
    }
}

/// Runs child processes with no terminal attached.
///
/// Children get `/dev/null` (or supplied bytes) on stdin and pipes on
/// stdout/stderr, and each runs in a session of its own: it has no controlling
/// terminal (so nothing can stop on `/dev/tty` waiting for a keyboard, even when
/// the CLI is run from Terminal) and leads a process group named after its pid
/// (so canceling takes the whole tree down with it).
public enum ProcessRunner {
    /// How long to keep draining output after the child exits. This is a hard limit: a grandchild that
    /// inherited the pipes (a daemon an installer started) would otherwise keep us waiting for as long as it lives.
    static let drainGrace: TimeInterval = 2.0
    /// Keep at most this much of each stream in memory.
    static let captureLimit = 8 * 1024 * 1024

    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// - Parameter onSpawn: called with the child's process ID (which, as it leads its own session, is also its
    ///   session ID) before the child runs any code: it is started suspended and only resumed once this returns.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil,
        onChunk: (@Sendable (OutputStreamKind, Data) -> Void)? = nil,
        onSpawn: ((pid_t) -> Void)? = nil
    ) async throws -> ProcessOutput {
        _ = ignoreSIGPIPE
        try Task.checkCancellation()

        let child = try spawn(executable: executable, arguments: arguments, environment: environment,
                              currentDirectory: currentDirectory, wantsStdin: stdin != nil, suspended: onSpawn != nil)
        if let onSpawn {
            onSpawn(child.pid)
            kill(child.pid, SIGCONT)
        }
        let state = RunState(pid: child.pid)

        if let stdin, child.stdinWrite >= 0 {
            let descriptor = child.stdinWrite
            DispatchQueue.global(qos: .utility).async {
                writeAll(descriptor, stdin)
                close(descriptor)
            }
        }

        var timeoutWork: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                state.markTimedOut()
                terminate(pid: child.pid)
            }
            timeoutWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
        }
        defer { timeoutWork?.cancel() }

        let output: ProcessOutput = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutput, Never>) in
                let group = DispatchGroup()

                group.enter()
                Thread.detachNewThread {
                    var status: Int32 = 0
                    while waitpid(child.pid, &status, 0) == -1 && errno == EINTR {}
                    state.markExited(status: status)
                    group.leave()
                }

                group.enter()
                Thread.detachNewThread {
                    pump(stdout: child.stdoutRead, stderr: child.stderrRead, state: state, onChunk: onChunk)
                    close(child.stdoutRead)
                    close(child.stderrRead)
                    group.leave()
                }

                group.notify(queue: .global(qos: .utility)) {
                    continuation.resume(returning: state.output())
                }
            }
        } onCancel: {
            terminate(pid: child.pid)
        }

        if state.timedOut, let timeout {
            throw ProcessRunnerError.timedOut(executable: executable, seconds: timeout)
        }
        try Task.checkCancellation()
        return output
    }

    /// SIGTERM to the child's process group, then SIGKILL if it is still around shortly after.
    static func terminate(pid: pid_t) {
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            kill(-pid, SIGKILL)
        }
    }

    // MARK: Spawning

    private struct Child {
        let pid: pid_t
        let stdoutRead: Int32
        let stderrRead: Int32
        let stdinWrite: Int32
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw ProcessRunnerError.spawnFailed(executable: "pipe", code: errno)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func spawn(executable: String, arguments: [String], environment: [String: String],
                              currentDirectory: String?, wantsStdin: Bool, suspended: Bool) throws -> Child {
        let outPipe = try makePipe()
        let errPipe = try makePipe()
        var inPipe: (read: Int32, write: Int32) = (-1, -1)
        if wantsStdin { inPipe = try makePipe() }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if wantsStdin {
            posix_spawn_file_actions_adddup2(&fileActions, inPipe.read, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, outPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe.write, STDERR_FILENO)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir(&fileActions, currentDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Own session (and with it, own process group); default signal dispositions; nothing inherited but stdio.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        // Resumed with SIGCONT by the caller.
        if suspended { flags |= POSIX_SPAWN_START_SUSPENDED }
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)

        close(outPipe.write)
        close(errPipe.write)
        if wantsStdin { close(inPipe.read) }

        guard result == 0 else {
            close(outPipe.read)
            close(errPipe.read)
            if wantsStdin { close(inPipe.write) }
            throw ProcessRunnerError.spawnFailed(executable: executable, code: result)
        }

        // Keep our ends out of any other child we spawn concurrently.
        for descriptor in [outPipe.read, errPipe.read, inPipe.write] where descriptor >= 0 {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        return Child(pid: pid, stdoutRead: outPipe.read, stderrRead: errPipe.read, stdinWrite: inPipe.write)
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    // MARK: Output pump

    private static func pump(stdout: Int32, stderr: Int32, state: RunState,
                             onChunk: (@Sendable (OutputStreamKind, Data) -> Void)?) {
        for descriptor in [stdout, stderr] {
            let current = fcntl(descriptor, F_GETFL)
            _ = fcntl(descriptor, F_SETFL, current | O_NONBLOCK)
        }

        var descriptors = [
            pollfd(fd: stdout, events: Int16(POLLIN), revents: 0),
            pollfd(fd: stderr, events: Int16(POLLIN), revents: 0),
        ]
        let kinds: [OutputStreamKind] = [.stdout, .stderr]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var drainDeadline: Date?

        while descriptors.contains(where: { $0.fd >= 0 }) {
            let exited = state.hasExited
            let ready = poll(&descriptors, nfds_t(descriptors.count), exited ? 100 : 250)
            if ready == -1 && errno != EINTR { break }

            if ready > 0 {
                for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                    let descriptor = descriptors[index].fd
                    var reachedEnd = false
                    while true {
                        let count = read(descriptor, &buffer, buffer.count)
                        if count > 0 {
                            let chunk = Data(buffer[0..<count])
                            state.append(chunk, to: kinds[index])
                            onChunk?(kinds[index], chunk)
                            if count < buffer.count { break }
                        } else if count == 0 {
                            reachedEnd = true
                            break
                        } else if errno == EINTR {
                            continue
                        } else {
                            if errno != EAGAIN && errno != EWOULDBLOCK { reachedEnd = true }
                            break
                        }
                    }
                    if reachedEnd { descriptors[index].fd = -1 }
                    descriptors[index].revents = 0
                }
            }

            // The child is gone but something still holds its pipes open. Whatever the child itself wrote
            // has been read by now (the loop above empties each pipe), so stop at the deadline even if a
            // chatty grandchild is still writing.
            if exited || state.hasExited {
                if drainDeadline == nil { drainDeadline = Date().addingTimeInterval(drainGrace) }
                if let drainDeadline, Date() >= drainDeadline { break }
            }
        }
    }
}

/// Mutable state shared between the waiter thread, the pump thread and the caller.
private final class RunState: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var status: Int32?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var didTimeOut = false

    init(pid: pid_t) {
        self.pid = pid
    }

    func markExited(status: Int32) {
        lock.lock()
        self.status = status
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
    }

    var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status != nil
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    func append(_ chunk: Data, to kind: OutputStreamKind) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .stdout:
            stdoutData.append(chunk)
            Self.trim(&stdoutData)
        case .stderr:
            stderrData.append(chunk)
            Self.trim(&stderrData)
        }
    }

    private static func trim(_ data: inout Data) {
        let limit = ProcessRunner.captureLimit
        if data.count > limit { data = Data(data.suffix(limit / 2)) }
    }

    func output() -> ProcessOutput {
        lock.lock()
        defer { lock.unlock() }
        let raw = status ?? 0
        let signalNumber = raw & 0x7F
        if signalNumber == 0 {
            return ProcessOutput(exitCode: (raw >> 8) & 0xFF, terminationSignal: nil, stdout: stdoutData, stderr: stderrData)
        }
        return ProcessOutput(exitCode: 128 + signalNumber, terminationSignal: signalNumber, stdout: stdoutData, stderr: stderrData)
    }
}
