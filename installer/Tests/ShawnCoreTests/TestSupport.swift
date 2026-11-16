import Foundation
import XCTest
@testable import ShawnCore

/// A throwaway directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    init(_ name: String = "shawn-tests") {
        // /tmp (not the long per-user temp path) keeps Unix socket paths under the 104-byte limit.
        url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String, permissions: Int? = nil) -> URL {
        let file = url.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: file)
        if let permissions {
            try! FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
        return file
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }
}

/// Collects events/log lines from concurrent callbacks.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func add(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    var all: [Element] { lock.withLock { storage } }
}

extension SystemEnvironment {
    /// A sandbox environment rooted in `directory`, with its directories created.
    static func testSandbox(_ directory: TempDirectory) -> SystemEnvironment {
        let environment = SystemEnvironment.sandbox(root: directory.url)
        for url in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return environment
    }
}

/// A scriptable action for engine tests.
struct FakeAction: Action {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
    }

    var title: String
    var sudo: SudoNeed = .never
    var satisfied = false
    var outcome: ActionOutcome = .done(nil)
    var failure: String?
    var validation: [String] = []
    var followUp: String?
    var delay: TimeInterval = 0
    var log: Log

    func validate(_ context: ValidationContext) -> [String] { validation }

    func check(_ context: ActionContext) async -> CheckResult {
        log.add("check:\(title)")
        return satisfied ? .satisfied("already there") : .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        log.add("run:\(title):dryRun=\(context.dryRun)")
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let followUp { context.followUp(followUp) }
        context.info("working on \(title)")
        if let failure { throw ActionError(failure) }
        return outcome
    }

    /// Registers kinds `ok`, `present`, `boom`, `manual`, `slow`, `root` that all record into `log`.
    static func registry(log: Log) -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(ActionDescriptor(kind: "ok", summary: "succeeds", example: "- ok: thing") { parser in
            let name = parser.primaryString()
            _ = parser.options.string("flavor")
            let followUp = parser.options.string("follow_up")
            return FakeAction(title: name, followUp: followUp, log: log)
        })
        registry.register(ActionDescriptor(kind: "present", summary: "already done", example: "- present: thing") { parser in
            FakeAction(title: parser.primaryString(), satisfied: true, log: log)
        })
        registry.register(ActionDescriptor(kind: "boom", summary: "fails", example: "- boom: thing") { parser in
            FakeAction(title: parser.primaryString(), failure: "kaboom", log: log)
        })
        registry.register(ActionDescriptor(kind: "manual", summary: "needs a human", example: "- manual: thing") { parser in
            FakeAction(title: parser.primaryString(), outcome: .needsAttention("click the button"), log: log)
        })
        registry.register(ActionDescriptor(kind: "slow", summary: "takes a while", example: "- slow: thing") { parser in
            FakeAction(title: parser.primaryString(), delay: 5, log: log)
        })
        registry.register(ActionDescriptor(kind: "invalid", summary: "fails validation", example: "- invalid: thing") { parser in
            FakeAction(title: parser.primaryString(), validation: ["payload file is missing"], log: log)
        })
        return registry
    }
}

/// Writes a config directory into `directory` and returns its URL.
@discardableResult
func makeConfig(in directory: TempDirectory, meta: String = "name: Test Dotfiles\nvars:\n  editor: nvim\n", steps: [String: String]) -> URL {
    let root = directory.url.appendingPathComponent("config")
    directory.write("config/installer.yaml", meta)
    for (name, body) in steps {
        directory.write("config/steps/\(name)", body)
    }
    if steps.isEmpty {
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("steps"), withIntermediateDirectories: true)
    }
    return root
}
