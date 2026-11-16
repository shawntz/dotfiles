import Darwin
import Foundation
import XCTest
@testable import ShawnCLIKit

/// Real git that records every call with its timeout, and can stand in a canned failure for one subcommand.
final class RecordingGit: GitClient, @unchecked Sendable {
    let wrapped: any GitClient
    private let lock = NSLock()
    private var log: [(arguments: [String], timeout: TimeInterval?)] = []
    private var failures: [String: ProcessResult] = [:]

    init(_ wrapped: any GitClient) {
        self.wrapped = wrapped
    }

    /// `git <subcommand>` answers with this instead of running.
    func fail(_ subcommand: String, exit: Int32 = 1, stderr: String) {
        lock.withLock { failures[subcommand] = ProcessResult(exitCode: exit, stdout: "", stderr: stderr) }
    }

    func run(_ arguments: [String], in directory: URL?, timeout: TimeInterval?) async -> ProcessResult {
        let canned: ProcessResult? = lock.withLock {
            log.append((arguments, timeout))
            return failures[arguments.first ?? ""]
        }
        if let canned { return canned }
        return await wrapped.run(arguments, in: directory, timeout: timeout)
    }

    var calls: [(arguments: [String], timeout: TimeInterval?)] { lock.withLock { log } }
    var subcommands: [String] { calls.map { $0.arguments.first ?? "" } }

    func reset() {
        lock.withLock { log.removeAll() }
    }
}

/// A builder that runs `during` while it "builds", then produces a working binary.
final class CallbackBuilder: Builder, @unchecked Sendable {
    let output: URL
    let during: @Sendable () -> Void

    init(output: URL, during: @escaping @Sendable () -> Void) {
        self.output = output
        self.during = during
    }

    func build(package: URL, product: String, timeout: TimeInterval) async -> Result<URL, BuildFailure> {
        during()
        try! Data("#!/bin/sh\necho new shawn\n".utf8).write(to: output)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
        return .success(output)
    }
}

/// Another shawn holding the update lock, saying what it is doing.
final class HeldUpdateLock {
    private let descriptor: Int32

    init(_ store: FileStateStore, pid: Int32 = 4242, activity: String) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        descriptor = open(store.lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw BuildFailure(message: "could not take \(store.lockFile.path)")
        }
        let text = Array("\(pid) \(activity)\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pwrite(descriptor, text, text.count, 0)
    }

    deinit {
        close(descriptor)
    }

    /// True when nobody holds the lock (it is taken and dropped again to find out).
    static func isFree(_ store: FileStateStore) -> Bool {
        let descriptor = open(store.lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

/// Release tarballs built with the system tar.
enum SelfUpdateTarball {
    enum Entry {
        case executable(String)
        case link(String)
    }

    static func make(in sandbox: Sandbox, entries: [String: Entry]) throws -> Data {
        let staging = sandbox.directory.url.appendingPathComponent("tarball-\(UUID().uuidString.prefix(6))")
        for (path, entry) in entries {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch entry {
            case .executable(let contents):
                try Data(contents.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            case .link(let destination):
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
            }
        }
        let tarball = staging.appendingPathExtension("tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tarball.path, "-C", staging.path] + entries.keys.map { String($0.split(separator: "/").first!) }
        try tar.run()
        tar.waitUntilExit()
        return try Data(contentsOf: tarball)
    }
}

/// A loopback HTTP server that sends its body `chunk` bytes at a time with `interval` seconds between them:
/// never silent long enough for an idle timeout, yet far slower than any sane overall deadline.
final class TrickleServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let status: Int
    private let body: Data
    private let chunk: Int
    private let interval: TimeInterval
    private let lock = NSLock()
    private var stopped = false

    init(status: Int = 200, body: Data, chunk: Int, interval: TimeInterval) throws {
        self.status = status
        self.body = body
        self.chunk = chunk
        self.interval = interval
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw BuildFailure(message: "could not listen on 127.0.0.1")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/shawn.tar.gz")! }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        while !isStopped {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var request = [UInt8](repeating: 0, count: 4096)
        _ = read(client, &request, request.count)
        let header = "HTTP/1.1 \(status) Test\r\nContent-Length: \(body.count)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        guard send(client, Array(header.utf8)) else { return }
        var offset = 0
        while offset < body.count, !isStopped {
            let end = min(offset + chunk, body.count)
            guard send(client, Array(body[offset..<end])) else { return }
            offset = end
            if interval > 0 { usleep(useconds_t(interval * 1_000_000)) }
        }
    }

    private func send(_ client: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { write(client, $0.baseAddress, bytes.count) } == bytes.count
    }

    /// Stops accepting and ends every transfer. The accept thread keeps the server alive, so tests call this.
    func stop() {
        let first: Bool = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }
}
