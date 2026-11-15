import Foundation
import XCTest
@testable import ActionsFiles
import ShawnCore

/// A throwaway directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    init(_ name: String = "shawn-files-tests") {
        // /tmp (not the long per-user temp path) keeps paths short.
        url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String, permissions: Int? = nil) -> URL {
        writeData(relativePath, Data(contents.utf8), permissions: permissions)
    }

    @discardableResult
    func writeData(_ relativePath: String, _ data: Data, permissions: Int? = nil) -> URL {
        let file = url.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: file)
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

    func reset() {
        lock.withLock { storage.removeAll() }
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

/// Builds one-step configs in a sandbox and runs their items the way the engine would.
final class Harness {
    let directory = TempDirectory()
    var environment: SystemEnvironment
    let registry: ActionRegistry
    let events = Recorder<InstallEvent>()
    var meta = """
    name: Test Dotfiles
    remote:
      repo: shawntz/dotfiles
      branch: master
      path: installer/config
    vars:
      full_name: Shawn Tester
      editor: nvim

    """

    init() {
        environment = .testSandbox(directory)
        var registry = ActionRegistry()
        registry.register(FileActions.descriptors)
        self.registry = registry
    }

    var home: URL { environment.home }
    var root: URL { directory.url }
    var configRoot: URL { directory.url.appendingPathComponent("config") }

    /// A path relative to the sandbox root (`home/.zshrc`, `Applications/Slack.app`).
    func url(_ relative: String) -> URL { directory.url.appendingPathComponent(relative) }

    /// Writes a payload file under `config/files/`.
    @discardableResult
    func payload(_ relative: String, _ contents: String, permissions: Int? = nil) -> URL {
        directory.write("config/files/\(relative)", contents, permissions: permissions)
    }

    /// Writes a config with one step holding `items` and builds its plan.
    func plan(_ items: String) throws -> InstallPlan {
        directory.write("config/installer.yaml", meta)
        let indented = items.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
        directory.write("config/steps/01-test.yaml", "id: test\ntitle: Test\nitems:\n\(indented)\n")
        let config = try ConfigLoader.load(from: configRoot).config
        return InstallPlan.build(config: config, registry: registry, environment: environment)
    }

    /// The single item of a config that must have no problems.
    func item(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) throws -> Planned {
        let plan = try plan(yaml)
        XCTAssertEqual(plan.errors.map(\.description), [], "unexpected config problems", file: file, line: line)
        let item = try XCTUnwrap(plan.allItems.first, "no item was built", file: file, line: line)
        return Planned(harness: self, plan: plan, item: item)
    }

    /// Error messages for a config that should be rejected.
    func problems(_ yaml: String) throws -> [String] {
        try plan(yaml).errors.map(\.description)
    }

    func context(_ planned: Planned, dryRun: Bool = false) -> ActionContext {
        let step = planned.plan.steps[0].config
        let events = self.events
        return ActionContext(config: planned.plan.config, environment: environment, options: RunOptions(dryRun: dryRun),
                             step: step, item: planned.item.config, sudo: nil, interaction: NonInteractive(),
                             shared: SharedState(), emit: { events.add($0) })
    }

    var logs: [LogLine] {
        events.all.compactMap { event in
            if case .log(let line) = event { return line }
            return nil
        }
    }

    var logText: String { logs.map(\.text).joined(separator: "\n") }

    var followUps: [FollowUp] {
        events.all.compactMap { event in
            if case .followUp(let followUp) = event { return followUp }
            return nil
        }
    }

    /// A stand-in tool placed first on the sandbox PATH. Every call appends one line to `<name>.log`
    /// with each argument in brackets: `[-g][-a][Google Chrome]`. `body` runs afterwards.
    @discardableResult
    func shim(_ name: String, body: String = "exit 0") -> URL {
        let bin = environment.brewPrefix.appendingPathComponent("bin")
        try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent(name)
        let text = """
        #!/bin/sh
        log="$(dirname "$0")/\(name).log"
        for arg in "$@"; do printf '[%s]' "$arg" >> "$log"; done
        printf '\\n' >> "$log"
        \(body)

        """
        try! Data(text.utf8).write(to: script)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Lines logged by a shim (one per call).
    func shimCalls(_ name: String) -> [String] {
        let log = environment.brewPrefix.appendingPathComponent("bin/\(name).log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Every file under `directory` (relative paths), for "nothing changed" assertions.
    func snapshot(_ relative: String = "") -> [String: Data] {
        let base = directory.url.appendingPathComponent(relative)
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return result }
        for case let url as URL in enumerator {
            let path = url.path.replacingOccurrences(of: base.path + "/", with: "")
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                result[path] = Data("-> \(destination)".utf8)
            } else if let data = FileManager.default.contents(atPath: url.path) {
                result[path] = data
            } else {
                result[path] = Data()
            }
        }
        return result
    }

    func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Makes an empty `.app` folder so name lookups find it.
    @discardableResult
    func fakeApp(_ relative: String) -> URL {
        let url = directory.url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        return url
    }
}

/// One built item plus everything needed to check and run it.
struct Planned {
    let harness: Harness
    let plan: InstallPlan
    let item: PlannedItem

    var action: any Action { item.action }

    func check(dryRun: Bool = false) async -> CheckResult {
        await action.check(harness.context(self, dryRun: dryRun))
    }

    @discardableResult
    func run(dryRun: Bool = false) async throws -> ActionOutcome {
        try await action.run(harness.context(self, dryRun: dryRun))
    }
}

/// Reads a plist file into typed values.
func readPlist(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: PlistValue] {
    let data = try XCTUnwrap(FileManager.default.contents(atPath: url.path), "missing \(url.path)", file: file, line: line)
    return try PlistValue.decodeDictionary(data)
}

/// Writes a plist file from typed values (as XML, like a hand-made fixture).
func writePlist(_ values: [String: PlistValue], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PlistValue.encode(values, format: .xml).write(to: url)
}

func XCTAssertSatisfied(_ result: CheckResult, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(result.isSatisfied, "expected satisfied, got \(result) \(message)", file: file, line: line)
}

func XCTAssertNeeded(_ result: CheckResult, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(result.isSatisfied, "expected needed, got \(result) \(message)", file: file, line: line)
}

/// Asserts that `body` throws an `ActionError` and returns it.
@discardableResult
func XCTAssertThrowsActionError(_ body: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async -> ActionError? {
    do {
        _ = try await body()
        XCTFail("expected an ActionError", file: file, line: line)
        return nil
    } catch let error as ActionError {
        return error
    } catch {
        XCTFail("expected an ActionError, got \(error)", file: file, line: line)
        return nil
    }
}

/// `XCTAssertEqual` for an outcome produced by an async call.
func XCTAssertOutcome(_ body: @autoclosure () async throws -> ActionOutcome, _ expected: ActionOutcome,
                      file: StaticString = #filePath, line: UInt = #line) async {
    do {
        let outcome = try await body()
        XCTAssertEqual(outcome, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
