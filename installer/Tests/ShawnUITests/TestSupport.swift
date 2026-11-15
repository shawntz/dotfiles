import Foundation
import ShawnCore
import ShawnFun
import ShawnSync
import XCTest
@testable import ShawnUI

/// A throwaway directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    init(_ name: String = "shawn-ui-tests") {
        // /tmp (not the long per-user temp path) keeps Unix socket paths under the 104-byte limit.
        url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) -> URL {
        let file = url.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: file)
        return file
    }
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

/// Keeps a `hold` item inside `run` until the test releases it, ignoring cancellation, so a test can
/// press STOP while one item runs and have the engine notice the stop only at the top of its loop.
final class HoldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            let waiting = waiters
            waiters.removeAll()
            return waiting
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// How many times each `counted` / `counted-boom` item has run, across runs.
final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ title: String) { lock.withLock { counts[title, default: 0] += 1 } }
    func count(_ title: String) -> Int { lock.withLock { counts[title, default: 0] } }
}

/// A scriptable action: succeeds, is already done, fails, needs a person, or takes a while.
struct FakeAction: Action {
    var title: String
    var satisfied = false
    var outcome: ActionOutcome = .done(nil)
    var failure: String?
    var followUp: String?
    var delay: TimeInterval = 0
    /// Waits in `run` until the gate opens (cancellation does not cut it short).
    var gate: HoldGate?
    /// Counts runs; a counted item that succeeded once checks as already done afterwards.
    var counter: RunCounter?

    func check(_ context: ActionContext) async -> CheckResult {
        if satisfied { return .satisfied("already there") }
        if let counter, failure == nil, counter.count(title) > 0 { return .satisfied("done by an earlier run") }
        return .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        counter?.record(title)
        if let gate { await gate.wait() }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let followUp { context.followUp(followUp, url: URL(string: "https://example.com/\(title)")) }
        context.info("working on \(title)")
        if let failure { throw ActionError(failure) }
        return outcome
    }

    /// Kinds `ok`, `present`, `boom`, `manual`, `slow`, plus `hold` (waits for `gate`), and `counted` /
    /// `counted-boom` (succeed once then check as done / always fail; both counted in `counter`).
    static func registry(gate: HoldGate = HoldGate(), counter: RunCounter = RunCounter()) -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(ActionDescriptor(kind: "hold", summary: "waits for the test", example: "- hold: thing") { parser in
            FakeAction(title: parser.primaryString(), gate: gate)
        })
        registry.register(ActionDescriptor(kind: "counted", summary: "succeeds once, then is done", example: "- counted: thing") { parser in
            FakeAction(title: parser.primaryString(), counter: counter)
        })
        registry.register(ActionDescriptor(kind: "counted-boom", summary: "always fails", example: "- counted-boom: thing") { parser in
            FakeAction(title: parser.primaryString(), failure: "kaboom", counter: counter)
        })
        registry.register(ActionDescriptor(kind: "ok", summary: "succeeds", example: "- ok: thing") { parser in
            FakeAction(title: parser.primaryString(), followUp: parser.options.string("follow_up"))
        })
        registry.register(ActionDescriptor(kind: "present", summary: "already done", example: "- present: thing") { parser in
            FakeAction(title: parser.primaryString(), satisfied: true)
        })
        registry.register(ActionDescriptor(kind: "boom", summary: "fails", example: "- boom: thing") { parser in
            FakeAction(title: parser.primaryString(), failure: "kaboom")
        })
        registry.register(ActionDescriptor(kind: "manual", summary: "needs a human", example: "- manual: thing") { parser in
            FakeAction(title: parser.primaryString(), outcome: .needsAttention("click the button"))
        })
        registry.register(ActionDescriptor(kind: "slow", summary: "takes a while", example: "- slow: thing") { parser in
            FakeAction(title: parser.primaryString(), delay: 20)
        })
        return registry
    }
}

/// Writes a config directory into `directory` and returns its URL.
@discardableResult
func makeConfig(in directory: TempDirectory, meta: String = "name: Test Dotfiles\ntagline: testing, testing\n",
                steps: [String: String], extraFiles: [String: String] = [:]) -> URL {
    let root = directory.url.appendingPathComponent("config")
    directory.write("config/installer.yaml", meta)
    for (name, body) in steps { directory.write("config/steps/\(name)", body) }
    for (path, body) in extraFiles { directory.write("config/\(path)", body) }
    return root
}

/// The standard three-step test config: a normal step, one with an optional item, one switched off.
let standardSteps: [String: String] = [
    "01-base.yaml": """
    id: base
    title: Base
    subtitle: The basics
    mascot: blob
    quips: ["Base quip"]
    items:
      - ok: alpha
      - present: beta
      - boom: gamma
    """,
    "02-extras.yaml": """
    id: extras
    title: Extras
    items:
      - ok: delta
        follow_up: Sign in to delta
      - ok: epsilon
        optional: true
        note: off by default
      - manual: zeta
    """,
    "03-off.yaml": """
    id: off
    title: Switched Off
    enabled: false
    items:
      - ok: eta
    """,
]

/// Records desktop side effects instead of performing them.
@MainActor
final class DesktopRecorder {
    var copied: [String] = []
    var opened: [URL] = []
    var revealed: [URL] = []

    var actions: DesktopActions {
        DesktopActions(copyToPasteboard: { [unowned self] in copied.append($0) },
                       open: { [unowned self] in opened.append($0) },
                       reveal: { [unowned self] in revealed.append($0) })
    }
}

extension XCTestCase {
    /// A temporary directory that stays on disk until the test has finished.
    func makeTempDirectory() -> TempDirectory {
        let directory = TempDirectory()
        addTeardownBlock { withExtendedLifetime(directory) {} }
        return directory
    }

    /// A configured model over a temporary config (removed when the test ends).
    @MainActor
    func makeModel(steps: [String: String] = standardSteps, registry: ActionRegistry = FakeAction.registry(),
                   mode: RunMode = .live, dryRun: Bool = false, assumeFresh: Bool = false, desktop: DesktopActions = .none,
                   quipSeed: Int = 0, extraFiles: [String: String] = [:],
                   logCapacity: Int = LogBuffer.defaultCapacity) throws -> (InstallerModel, TempDirectory) {
        try buildModel(in: makeTempDirectory(), steps: steps, registry: registry, mode: mode, dryRun: dryRun,
                       assumeFresh: assumeFresh, desktop: desktop, quipSeed: quipSeed, extraFiles: extraFiles,
                       logCapacity: logCapacity)
    }
}

@MainActor
private func buildModel(in directory: TempDirectory, steps: [String: String], registry: ActionRegistry, mode: RunMode,
                        dryRun: Bool, assumeFresh: Bool, desktop: DesktopActions, quipSeed: Int, extraFiles: [String: String],
                        logCapacity: Int) throws -> (InstallerModel, TempDirectory) {
    let root = makeConfig(in: directory, steps: steps, extraFiles: extraFiles)
    let environment = SystemEnvironment.testSandbox(directory)
    let resolved = try ConfigResolver.load(directory: root, source: .local(root.path), registry: registry, environment: environment)
    var settings = InstallerModel.Settings()
    settings.mode = mode
    settings.assumeFresh = assumeFresh
    settings.logCapacity = logCapacity
    let model = InstallerModel(registry: registry, environment: environment,
                               resolveOptions: ConfigResolveOptions(explicitPath: root, allowRemote: false),
                               settings: settings, dryRun: dryRun, desktop: desktop, quipSeed: quipSeed)
    let fun = FunConfig.load(from: resolved.config)
    model.configure(resolved, fun: fun.fun, funIssues: fun.issues)
    return (model, directory)
}

struct TimedOut: Error {}

/// Polls `condition` on the main actor (letting queued main-actor work run in between).
@MainActor
func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
            throw TimedOut()
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
