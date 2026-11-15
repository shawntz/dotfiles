import Darwin
import Foundation
import ShawnCore

/// Answers the engine's questions at the terminal: the admin password (typed with echo off on
/// `/dev/tty`, so it works even when stdout is piped to a log), multiple-choice questions and
/// one-line text questions (echo on).
struct TerminalInteraction: UserInteraction {
    struct Options: Sendable, Equatable {
        /// `--yes`: questions take their default answer.
        var assumeYes = false
        /// False for dry runs and runs without a terminal: nothing is ever asked.
        var allowPrompts = true
    }

    let options: Options
    let style: Style
    /// Reads a text answer: the terminal, or a script in tests. Takes the prompt, whether to hide what is typed,
    /// and the cancellation the run's `PromptScope` withdraws.
    var textReader: @Sendable (String, Bool, TTY.Cancellation) -> String? = { TTY.readLine(prompt: $0, secret: $1, cancellation: $2) }

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
        guard options.allowPrompts else { return nil }
        // Start on a clean line: the install output may be showing a live status line.
        var prompt = "\r\u{1B}[2K"
        if let lastError { prompt += style.bad("✗") + " \(lastError)\n" }
        if attempt == 1 { prompt += style.accent("✦") + " " + reason + "\n" }
        prompt += style.bold("Password for \(NSUserName()) (Enter to skip): ")
        guard let answer = await Self.read(prompt: prompt, secret: true), !answer.isEmpty else { return nil }
        return answer
    }

    func ask(_ question: Question) async -> String {
        guard options.allowPrompts, !options.assumeYes, !question.options.isEmpty else { return question.defaultOptionID }
        var prompt = "\r\u{1B}[2K\n" + style.heading(question.title) + "\n" + question.message + "\n"
        if let url = question.url { prompt += style.muted(url.absoluteString) + "\n" }
        for (index, option) in question.options.enumerated() {
            prompt += "  \(index + 1)) \(option.label)" + (option.isDefault ? style.muted(" (default)") : "") + "\n"
        }
        prompt += "Choose 1-\(question.options.count): "
        if let answer = await Self.read(prompt: prompt, secret: false),
           let number = Int(answer.trimmingCharacters(in: .whitespaces)), question.options.indices.contains(number - 1) {
            return question.options[number - 1].id
        }
        return question.defaultOptionID
    }

    /// `? Your email address for Git commits [jane@example.com]: `. Return takes the default; with no default it skips
    /// the question (nil). With `--yes`, or without a terminal, the default is taken without asking.
    func askText(_ request: TextRequest) async -> String? {
        guard options.allowPrompts, !options.assumeYes else { return request.defaultValue }
        guard let line = await Self.read(prompt: Self.textPrompt(request, style: style), secret: false, reader: textReader) else { return nil }
        let reply = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? request.defaultValue : reply
    }

    static func textPrompt(_ request: TextRequest, style: Style) -> String {
        // Start on a clean line: the install output may be showing a live status line.
        var prompt = "\r\u{1B}[2K"
        if let lastError = request.lastError { prompt += style.bad("✗") + " \(lastError)\n" }
        prompt += style.accent("?") + " " + style.bold(request.prompt)
        prompt += request.defaultValue.map { " [\($0)]" } ?? style.muted(" (Enter to skip)")
        return prompt + ": "
    }

    /// Reads one line from the terminal on its own thread. When the waiting task is cancelled (a question
    /// that timed out, a run that was stopped) the read ends within a moment and the answer is nil, so a
    /// withdrawn prompt never stays behind to swallow the next line typed or to compete with a later prompt.
    /// The same happens when the run's `PromptScope` is withdrawn, which also reaches a read that a task of
    /// its own asks for (the administrator password).
    static func read(prompt: String, secret: Bool,
                     reader: @escaping @Sendable (String, Bool, TTY.Cancellation) -> String? = { TTY.readLine(prompt: $0, secret: $1, cancellation: $2) }) async -> String? {
        let cancellation = TTY.Cancellation()
        let scope = PromptScope.current
        scope?.enter(cancellation)
        defer { scope?.leave(cancellation) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread { continuation.resume(returning: reader(prompt, secret, cancellation)) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// The prompts of one run, so that stopping the run withdraws them all.
///
/// Cancelling the run's task is not enough: the administrator password is asked from a task of its own
/// (`SudoSession` shares one prompt between the items that need it), which that cancellation never reaches.
/// The scope is bound as a task local around the run, and task locals are handed down to such tasks too.
/// After `withdraw()`, the prompt that is open ends within a moment with no answer, and any prompt the run
/// still opens ends before it is shown.
final class PromptScope: @unchecked Sendable {
    @TaskLocal static var current: PromptScope?

    private let lock = NSLock()
    private var open: [ObjectIdentifier: TTY.Cancellation] = [:]
    private var withdrawn = false

    /// Ends the prompts that are open and turns away the ones still to come.
    func withdraw() {
        let reads = lock.withLock { () -> [TTY.Cancellation] in
            withdrawn = true
            defer { open.removeAll() }
            return Array(open.values)
        }
        for read in reads { read.cancel() }
    }

    /// A read is starting; it is cancelled at once if the scope was already withdrawn.
    func enter(_ read: TTY.Cancellation) {
        let turnedAway = lock.withLock { () -> Bool in
            if !withdrawn { open[ObjectIdentifier(read)] = read }
            return withdrawn
        }
        if turnedAway { read.cancel() }
    }

    func leave(_ read: TTY.Cancellation) {
        lock.withLock { _ = open.removeValue(forKey: ObjectIdentifier(read)) }
    }
}

/// Direct access to the controlling terminal.
enum TTY {
    private static let lock = NSLock()
    /// Terminal settings to put back if we are interrupted while echo is off.
    nonisolated(unsafe) private static var saved: (descriptor: Int32, settings: termios)?
    /// Lines being read right now (a question or a password).
    nonisolated(unsafe) private static var reading = 0

    /// Lets another thread end a `readLine` that is still waiting for its line.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    /// How often a cancellable read looks at its `Cancellation` while no input is waiting.
    static let cancellationPollMilliseconds: Int32 = 100

    /// Reads one line from `/dev/tty`; nil when there is no terminal, input ended, or the read was cancelled.
    static func readLine(prompt: String, secret: Bool, cancellation: Cancellation? = nil) -> String? {
        let descriptor = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return readLine(prompt: prompt, secret: secret, input: descriptor, output: descriptor, cancellation: cancellation)
    }

    /// Writes `prompt` to `output` and reads one line from `input` (echo off for a secret on a terminal).
    ///
    /// With a `cancellation`, the wait for input is cut into short slices so that `cancel()` ends the read
    /// (returning nil) instead of leaving a thread blocked on the terminal.
    static func readLine(prompt: String, secret: Bool, input: Int32, output: Int32, cancellation: Cancellation? = nil) -> String? {
        if cancellation?.isCancelled == true { return nil }
        lock.withLock { reading += 1 }
        defer { lock.withLock { reading -= 1 } }
        write(output, prompt)

        var original = termios()
        let canControl = tcgetattr(input, &original) == 0
        if secret && canControl {
            var silent = original
            silent.c_lflag &= ~tcflag_t(ECHO)
            lock.withLock { saved = (input, original) }
            tcsetattr(input, TCSAFLUSH, &silent)
        }
        defer {
            if secret && canControl {
                var restore = original
                tcsetattr(input, TCSAFLUSH, &restore)
                lock.withLock { saved = nil }
                write(output, "\n")
            }
        }

        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            if let cancellation {
                switch waitForInput(input, milliseconds: cancellationPollMilliseconds) {
                case .nothingYet:
                    guard cancellation.isCancelled else { continue }
                    // Nobody pressed Return, so finish the prompt's line ourselves (a secret's is finished below).
                    if !secret || !canControl { write(output, "\n") }
                    return nil
                case .ready, .unknown:
                    break
                }
            }
            let count = read(input, &byte, 1)
            if count == 1 {
                if byte == 0x0A || byte == 0x0D { break }
                bytes.append(byte)
            } else if count == -1 && errno == EINTR {
                continue
            } else {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
        }
        defer { for index in bytes.indices { bytes[index] = 0 } }
        return String(decoding: bytes, as: UTF8.self)
    }

    enum InputState {
        /// A read would return at once (a line, a byte, or end of input).
        case ready
        case nothingYet
        /// `select` could not say (an error, or a descriptor it cannot watch): read without waiting on it.
        case unknown
    }

    /// Waits up to `milliseconds` for `descriptor` to have something to read. Uses `select`, which,
    /// unlike `poll` and kqueue, works on `/dev/tty` on macOS.
    static func waitForInput(_ descriptor: Int32, milliseconds: Int32) -> InputState {
        guard descriptor >= 0, descriptor < 1024 else { return .unknown }   // FD_SETSIZE
        var set = fd_set()
        withUnsafeMutableBytes(of: &set) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            words[Int(descriptor) / 32] |= UInt32(1) << UInt32(descriptor % 32)
        }
        var timeout = timeval(tv_sec: __darwin_time_t(milliseconds / 1000), tv_usec: __darwin_suseconds_t((milliseconds % 1000) * 1000))
        let result = select(descriptor + 1, &set, nil, nil, &timeout)
        if result > 0 { return .ready }
        if result == 0 || errno == EINTR { return .nothingYet }
        return .unknown
    }

    /// Puts echo back if a secret prompt was interrupted (Ctrl-C).
    static func restore() {
        lock.withLock {
            if var settings = saved?.settings, let descriptor = saved?.descriptor {
                tcsetattr(descriptor, TCSAFLUSH, &settings)
            }
            saved = nil
        }
    }

    /// True while a question or password prompt is waiting for its answer.
    static var isPrompting: Bool { lock.withLock { reading > 0 } }

    private static func write(_ descriptor: Int32, _ text: String) {
        var bytes = Array(text.utf8)
        _ = bytes.withUnsafeMutableBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
    }

    /// Asks a yes/no question on the terminal (default yes).
    static func confirm(_ question: String) -> Bool {
        guard let answer = readLine(prompt: question + " [Y/n] ", secret: false) else { return false }
        let trimmed = answer.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty || trimmed == "y" || trimmed == "yes"
    }
}

/// Opening URLs and the clipboard, for callouts like "enter this code on github.com".
protocol DesktopActions: Sendable {
    func open(_ url: URL)
    func copy(_ text: String)
}

struct SystemDesktop: DesktopActions {
    func open(_ url: URL) {
        run("/usr/bin/open", [url.absoluteString], input: nil)
    }

    func copy(_ text: String) {
        run("/usr/bin/pbcopy", [], input: Data(text.utf8))
    }

    private func run(_ path: String, _ arguments: [String], input: Data?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : pipe
        do {
            try process.run()
        } catch {
            // Convenience only: the code and URL are printed in full either way.
            return
        }
        if let input {
            pipe.fileHandleForWriting.write(input)
            try? pipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
    }
}
