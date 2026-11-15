import Darwin
import Foundation

public enum SudoError: Error, Sendable, CustomStringConvertible {
    /// The user closed the password prompt.
    case declined
    case notAdministrator
    case tooManyAttempts
    case unavailable(String)

    public var description: String {
        switch self {
        case .declined:
            return "the administrator password was not provided"
        case .notAdministrator:
            return "this account is not allowed to administer this Mac (it is not in the sudoers list)"
        case .tooManyAttempts:
            return "the administrator password was wrong too many times"
        case .unavailable(let message):
            return message
        }
    }
}

/// Administrator rights for the whole run, from one password prompt.
///
/// GUI apps have no terminal for `sudo` to prompt on, so the password is asked
/// for once in the app and handed to `sudo -A` through an askpass helper. The
/// helper is a three-line script that reads the password from a Unix socket
/// this process serves, so the password never touches the disk or the
/// environment, and it is wiped when the run ends. Homebrew's installer and
/// `brew` itself both use `sudo -A` whenever `SUDO_ASKPASS` is set, so they
/// work unmodified.
///
/// The password is this Mac's login password, so it is guarded more tightly than
/// "anything this user runs can ask": the helper's location is only given to commands
/// marked as allowed to use sudo, and the socket answers only the helper as started by
/// `sudo` itself inside such a command, while that command is running (see `AskpassServer`).
/// Anything else the run starts meanwhile, a background download included, gets nothing.
public final class SudoSession: SudoProviding, @unchecked Sendable {
    public static let maxAttempts = 3

    private let environment: SystemEnvironment
    private let interaction: any UserInteraction
    private let dryRun: Bool
    private let lock = NSLock()
    private var server: AskpassServer?
    private var ready = false
    private var failure: SudoError?
    private var inFlight: Task<Void, Error>?
    /// Sessions of the privileged commands running right now (each command's process leads its own), with a count.
    private var privilegedSessions: [pid_t: Int] = [:]

    public init(environment: SystemEnvironment, interaction: any UserInteraction, dryRun: Bool = false) {
        self.environment = environment
        self.interaction = interaction
        self.dryRun = dryRun
    }

    deinit {
        server?.stop()
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    public var processEnvironment: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard ready, let server else { return [:] }
        var variables = ["SUDO_ASKPASS": server.helperPath]
        // A bare `sudo` (no -A) inside a third-party script only falls back to the askpass helper
        // when there is no terminal AND DISPLAY is set, so make sure it is.
        if environment.baseEnvironment["DISPLAY"] == nil { variables["DISPLAY"] = ":0" }
        return variables
    }

    public func beginPrivilegedCommand(processID: pid_t) {
        lock.withLock {
            privilegedSessions[processID, default: 0] += 1
            server?.allowSessions(Set(privilegedSessions.keys))
        }
    }

    public func endPrivilegedCommand(processID: pid_t) {
        lock.withLock {
            let remaining = (privilegedSessions[processID] ?? 0) - 1
            privilegedSessions[processID] = remaining > 0 ? remaining : nil
            server?.allowSessions(Set(privilegedSessions.keys))
        }
    }

    public func ensureReady(reason: String) async throws {
        // Nothing privileged actually runs in a dry run, so there is nothing to unlock.
        if dryRun { return }

        let task: Task<Void, Error> = lock.withLock {
            if ready { return Task {} }
            if let failure { return Task { throw failure } }
            if let inFlight { return inFlight }
            let task = Task { try await self.authenticateInteractively(reason: reason) }
            inFlight = task
            return task
        }
        defer { lock.withLock { if inFlight == task { inFlight = nil } } }
        try await task.value
    }

    private func authenticateInteractively(reason: String) async throws {
        var lastError: String?
        for attempt in 1...Self.maxAttempts {
            guard let password = await interaction.requestAdminPassword(reason: reason, attempt: attempt, lastError: lastError) else {
                lock.withLock { failure = .declined }
                throw SudoError.declined
            }
            switch await authenticate(password: password) {
            case .success:
                return
            case .wrongPassword:
                lastError = "That password was not accepted."
            case .notAdministrator:
                lock.withLock { failure = .notAdministrator }
                throw SudoError.notAdministrator
            case .failed(let message):
                lastError = message
            }
        }
        lock.withLock { failure = .tooManyAttempts }
        throw SudoError.tooManyAttempts
    }

    public enum AuthenticationOutcome: Equatable, Sendable {
        case success
        case wrongPassword
        case notAdministrator
        case failed(String)
    }

    /// Checks `password` with sudo and, if it is right, keeps serving it for the rest of the run.
    public func authenticate(password: String) async -> AuthenticationOutcome {
        let candidate: AskpassServer
        do {
            candidate = try AskpassServer(secret: password, temporaryDirectory: environment.temporaryDirectory)
            try candidate.start()
        } catch {
            return .failed("could not start the password helper: \(error)")
        }
        // One answer only: a wrong password must not be retried three times by sudo itself.
        candidate.limitAnswers(to: 1)

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                executable: environment.sudoPath,
                // -k: ignore any cached credentials so the password is really tested.
                arguments: ["-A", "-k", "-v"],
                environment: environment.processEnvironment(overrides: ["SUDO_ASKPASS": candidate.helperPath]),
                timeout: 60,
                // Only this sudo's own helper is answered.
                onSpawn: { candidate.allowSessions([$0]) }
            )
        } catch {
            candidate.stop()
            return .failed("could not run sudo: \(error)")
        }

        if output.exitCode == 0 {
            // sudo accepted the one answer that was served, so whatever started that helper process is
            // the real sudo: from now on only helpers started by the same program are answered.
            lock.withLock {
                candidate.allowSessions(Set(privilegedSessions.keys))
                candidate.requireLearnedParent()
                candidate.limitAnswers(to: nil)
                server?.stop()
                server = candidate
                ready = true
                failure = nil
            }
            return .success
        }

        candidate.stop()
        let message = String(decoding: output.stderr, as: UTF8.self)
        if message.contains("not in the sudoers") || message.contains("not allowed to run sudo") || message.contains("may not run sudo") {
            return .notAdministrator
        }
        if message.contains("incorrect password") || message.contains("try again") || message.contains("no password was provided") {
            return .wrongPassword
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(trimmed.isEmpty ? "sudo exited with status \(output.exitCode)" : trimmed)
    }

    /// Forgets the password and drops any cached sudo credentials.
    public func invalidate() {
        let wasReady: Bool = lock.withLock {
            let previous = ready
            server?.stop()
            server = nil
            ready = false
            return previous
        }
        guard wasReady else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.sudoPath)
        process.arguments = ["-k"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Serves one secret over a private Unix domain socket, but only to the askpass helper.
///
/// A connection gets the secret only when ALL of these hold:
/// - the peer runs as this user;
/// - the peer is `/usr/bin/nc`, which is what the helper script turns into;
/// - the peer runs in one of the allowed sessions: those of the commands allowed to use sudo that are running
///   right now. Each command the installer runs leads a session of its own, and sudo starts the helper in its
///   caller's session, so this is "started inside such a command". A process cannot join a session it was not
///   born into, so anything else (another item's script, any other program of this user) is refused, however
///   long a privileged command such as a background download keeps running;
/// - once the password has been verified: that process was started by the same program that started
///   the helper during verification, that is, by sudo. (Learned rather than hard-coded, so an unusual
///   sudo setup can never lock out a correct password.)
/// So a script the installer runs cannot simply connect to the socket, or run the helper (or a sudo of its own
/// with a helper of its own), and read the password.
final class AskpassServer: @unchecked Sendable {
    /// What the helper script execs to talk to the socket.
    static let clientPath = "/usr/bin/nc"

    /// Who may start the helper.
    private enum ParentRule {
        /// Anyone; remember who started the helper that got an answer.
        case learning
        case anyone
        case mustBe(String)
    }

    let directory: URL
    let socketPath: String
    let helperPath: String

    private let lock = NSLock()
    private var parentRule = ParentRule.learning
    private var learnedParentPath: String?
    private var secret: [UInt8]
    private var listenDescriptor: Int32 = -1
    private var remainingAnswers: Int?
    private var allowedSessions: Set<pid_t> = []
    private var stopped = false

    init(secret: String, temporaryDirectory: URL) throws {
        self.secret = Array(secret.utf8)
        // sun_path holds 104 bytes; macOS temp paths are long, so fall back to /tmp if needed.
        let name = "sdf-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        var candidate = temporaryDirectory.appendingPathComponent(name)
        if candidate.appendingPathComponent("a.sock").path.utf8.count >= 100 {
            candidate = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        }
        directory = candidate
        socketPath = candidate.appendingPathComponent("a.sock").path
        helperPath = candidate.appendingPathComponent("askpass").path
    }

    func limitAnswers(to count: Int?) {
        lock.withLock { remainingAnswers = count }
    }

    /// Only helpers running in one of these sessions are answered; with none, every connection is closed unanswered.
    func allowSessions(_ sessions: Set<pid_t>) {
        lock.withLock { allowedSessions = sessions }
    }

    /// From now on, answer only helpers started by the program that started the last answered helper.
    func requireLearnedParent() {
        lock.withLock { parentRule = learnedParentPath.map { .mustBe($0) } ?? .anyone }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw SudoError.unavailable("could not create \(directory.path): \(String(cString: strerror(errno)))")
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SudoError.unavailable("could not create a socket: \(String(cString: strerror(errno)))")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            close(descriptor)
            throw SudoError.unavailable("socket path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<pathBytes.count]))
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw SudoError.unavailable("could not listen on \(socketPath): \(reason)")
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        listenDescriptor = descriptor

        let script = """
        #!/bin/sh
        # Hands sudo the password already typed into Shawn's Dotfiles.
        # Created for this run only and deleted when it ends.
        exec \(Self.clientPath) -U -d '\(socketPath)'

        """
        guard FileManager.default.createFile(atPath: helperPath, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
            stop()
            throw SudoError.unavailable("could not write the password helper at \(helperPath)")
        }

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(descriptor)
        }
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            if lock.withLock({ stopped }) { return }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 250)
            if ready < 0 && errno != EINTR { return }
            if ready <= 0 { continue }

            let client = accept(descriptor, nil, nil)
            if client < 0 { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            answer(client)
            close(client)
        }
    }

    private func answer(_ client: Int32) {
        guard let helper = helperProcess(client) else { return }
        let session = getsid(helper)
        let parentPath = ProcessInspector.parent(of: helper).flatMap { ProcessInspector.executablePath(of: $0) }

        let reply: [UInt8]? = lock.withLock {
            if stopped || session <= 0 || !allowedSessions.contains(session) { return nil }
            if case .mustBe(let required) = parentRule, parentPath != required { return nil }
            if let remaining = remainingAnswers {
                if remaining <= 0 { return nil }
                remainingAnswers = remaining - 1
            }
            if case .learning = parentRule { learnedParentPath = parentPath }
            return secret + [0x0A]
        }
        guard var bytes = reply else { return }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(client, $0.baseAddress! + offset, bytes.count - offset) }
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        for index in bytes.indices { bytes[index] = 0 }
    }

    /// The connecting process, if it runs as this user and is the helper's own program.
    private func helperProcess(_ client: Int32) -> pid_t? {
        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(client, &peerUser, &peerGroup) == 0, peerUser == getuid() else { return nil }

        var peerProcess: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peerProcess, &size) == 0, peerProcess > 0,
              ProcessInspector.executablePath(of: peerProcess) == Self.clientPath else { return nil }
        return peerProcess
    }

    func stop() {
        let descriptor: Int32 = lock.withLock {
            if stopped { return -1 }
            stopped = true
            for index in secret.indices { secret[index] = 0 }
            secret.removeAll()
            let current = listenDescriptor
            listenDescriptor = -1
            return current
        }
        if descriptor >= 0 { close(descriptor) }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Facts about other processes, from libproc.
enum ProcessInspector {
    /// The executable a process is running, or nil if it has gone away.
    static func executablePath(of process: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(process, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func parent(of process: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
