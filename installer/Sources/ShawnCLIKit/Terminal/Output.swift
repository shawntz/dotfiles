import Darwin
import Foundation

/// Somewhere text goes: stdout, stderr, or a buffer in tests.
protocol OutputSink: AnyObject, Sendable {
    func write(_ text: String)
}

extension OutputSink {
    func line(_ text: String = "") {
        write(text + "\n")
    }
}

/// Unbuffered writes to a file descriptor, so output interleaves correctly with child processes.
final class FileDescriptorOutput: OutputSink, @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    static let standardOutput = FileDescriptorOutput(STDOUT_FILENO)
    static let standardError = FileDescriptorOutput(STDERR_FILENO)

    func write(_ text: String) {
        lock.withLock {
            var bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeMutableBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    // EPIPE (output piped into `head`) and friends: nobody is listening any more.
                    return
                }
            }
        }
    }
}

/// Collects output in memory (tests, and rendering into a string).
final class BufferOutput: OutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    init() {}

    func write(_ text: String) {
        lock.withLock { storage += text }
    }

    var text: String { lock.withLock { storage } }

    /// The text with escape sequences removed.
    var plain: String { ANSIText.strip(text) }
}
