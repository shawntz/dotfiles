import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

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
    static func testSandbox(_ directory: TempDirectory, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> SystemEnvironment {
        let environment = SystemEnvironment.sandbox(root: directory.url, baseEnvironment: baseEnvironment)
        for url in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return environment
    }
}

/// GitHub's real host keys (fingerprints match `GitHubHostKeys.pinned`), as `gh api meta --jq '.ssh_keys[]'` prints them.
let gitHubHostKeyLines = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=",
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=",
]

/// A fake machine for one test: sandbox home, a config directory, recorded events and fake tools.
///
/// Fake tools are bash scripts in `<sandbox>/homebrew/bin` (first on the child PATH) that log
/// their argv tab-separated to `shims.log` and keep their state under the sandbox root.
final class DevSandbox {
    let directory: TempDirectory
    let environment: SystemEnvironment
    let events = Recorder<InstallEvent>()
    private(set) var shared = SharedState()

    static let installerYAML = """
    schema: 1
    name: Test Dotfiles
    vars:
      full_name: Test Person
      email: test@example.com
      github_user: tester
      dotfiles_repo: tester/dotfiles

    """

    init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        directory = TempDirectory("shawn-dev")
        environment = SystemEnvironment.testSandbox(directory, baseEnvironment: baseEnvironment)
        try! FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    var root: URL { directory.url }
    var home: URL { environment.home }
    var bin: URL { environment.brewPrefix.appendingPathComponent("bin") }
    var shimLog: URL { root.appendingPathComponent("shims.log") }

    /// A fresh `SharedState`, as a new installer run would have.
    func newRun() { shared = SharedState() }

    // MARK: Files

    func homeURL(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    @discardableResult
    func writeHome(_ relative: String, _ contents: String, permissions: Int? = nil) -> URL {
        directory.write("home/\(relative)", contents, permissions: permissions)
    }

    func readHome(_ relative: String) -> String? { directory.read("home/\(relative)") }

    func existsInHome(_ relative: String) -> Bool {
        let url = homeURL(relative)
        return FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func permissions(_ relative: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: homeURL(relative).path)[.posixPermissions] as? NSNumber)?.intValue
    }

    func linkTarget(_ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: homeURL(relative).path)
    }

    /// Generates a real unencrypted key in the sandbox (never anywhere else: -f is always explicit).
    @discardableResult
    func generateKey(_ relative: String = ".ssh/id_ed25519", comment: String = "fixture@example.com") -> URL {
        let key = homeURL(relative)
        try! FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", "ed25519", "-N", "", "-C", comment, "-f", key.path, "-q"]
        process.standardInput = FileHandle.nullDevice
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ssh-keygen fixture failed")
        return key
    }

    /// Runs real git in the sandbox (HOME pointed at the sandbox home).
    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitTool.locate(environment) ?? "/usr/bin/git")
        process.arguments = arguments
        var env = environment.processEnvironment()
        for name in GitTool.isolationVariables(environment) { env.removeValue(forKey: name) }
        process.environment = env
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try! process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func globalGitConfig(_ key: String) -> String {
        git(["config", "--global", "--get", key])
    }

    // MARK: Fake tools

    func shim(_ name: String, _ body: String) {
        let script = """
        #!/bin/bash
        ROOT='\(root.path)'
        { printf '%s' '\(name)'; for a in "$@"; do printf '\\t%s' "$a"; done; printf '\\n'; } >> "$ROOT/shims.log"
        env > "$ROOT/\(name).env"
        \(body)

        """
        directory.write("homebrew/bin/\(name)", script, permissions: 0o755)
    }

    /// Every recorded invocation of `tool`, as argument lists.
    func calls(_ tool: String) -> [[String]] {
        guard let text = try? String(contentsOf: shimLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.components(separatedBy: "\t") }
            .filter { $0.first == tool }
            .map { Array($0.dropFirst()) }
    }

    /// The environment the last invocation of `tool` saw.
    func lastEnvironment(_ tool: String) -> [String: String] {
        guard let text = directory.read("\(tool).env") else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            result[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return result
    }

    func clearShimLog() { try? FileManager.default.removeItem(at: shimLog) }

    // MARK: Config

    /// Writes `config/` with one step holding `items` (YAML list entries indented by two spaces).
    @discardableResult
    func writeConfig(items: String, files: [String: String] = [:], installer: String = installerYAML) -> URL {
        directory.write("config/installer.yaml", installer)
        directory.write("config/steps/01-dev.yaml", "id: dev\ntitle: Developer\nitems:\n\(items)\n")
        for (path, contents) in files { directory.write("config/\(path)", contents) }
        return root.appendingPathComponent("config")
    }

    func registry() -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(DevActions.descriptors)
        return registry
    }

    func plan(items: String, files: [String: String] = [:], installer: String = installerYAML) throws -> InstallPlan {
        let root = writeConfig(items: items, files: files, installer: installer)
        let config = try ConfigLoader.load(from: root).config
        return InstallPlan.build(config: config, registry: registry(), environment: environment)
    }

    /// Error messages for a config that is expected to be wrong.
    func problems(items: String, files: [String: String] = [:]) throws -> [String] {
        try plan(items: items, files: files).errors.map(\.message)
    }

    /// The single item of a valid config, as its concrete action type.
    func single<T: Action>(_ type: T.Type, _ items: String, files: [String: String] = [:], installer: String = installerYAML,
                           file: StaticString = #filePath, line: UInt = #line) throws -> (action: T, item: PlannedItem, plan: InstallPlan) {
        let plan = try plan(items: items, files: files, installer: installer)
        XCTAssertEqual(plan.errors, [], "config should be valid", file: file, line: line)
        let item = try XCTUnwrap(plan.allItems.first, file: file, line: line)
        let action = try XCTUnwrap(item.action as? T, "expected a \(T.self)", file: file, line: line)
        return (action, item, plan)
    }

    func context(_ item: PlannedItem, _ plan: InstallPlan, dryRun: Bool = false) -> ActionContext {
        let step = plan.steps.first { $0.items.contains { $0.id == item.id } }!.config
        let events = self.events
        return ActionContext(config: plan.config, environment: environment, options: RunOptions(dryRun: dryRun), step: step, item: item.config,
                             sudo: nil, interaction: NonInteractive(), shared: shared, emit: { events.add($0) })
    }

    // MARK: Recorded events

    var attentions: [Attention?] {
        events.all.compactMap { event in
            if case .attention(_, let attention) = event { return .some(attention) }
            return nil
        }
    }

    var followUps: [FollowUp] {
        events.all.compactMap { event in
            if case .followUp(let followUp) = event { return followUp }
            return nil
        }
    }

    var logLines: [LogLine] {
        events.all.compactMap { event in
            if case .log(let line) = event { return line }
            return nil
        }
    }

    var logText: String { logLines.map(\.text).joined(separator: "\n") }
}

/// `XCTAssertEqual` for values computed with `await` (XCTest's autoclosures cannot await).
func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, message, file: file, line: line)
}

/// Fails the test unless `body` throws an `ActionError`; returns it.
@discardableResult
func assertActionError(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> ActionError? {
    do {
        try await body()
        XCTFail("expected an ActionError", file: file, line: line)
        return nil
    } catch let error as ActionError {
        return error
    } catch {
        XCTFail("expected an ActionError, got \(error)", file: file, line: line)
        return nil
    }
}
