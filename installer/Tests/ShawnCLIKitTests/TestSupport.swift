import Foundation
import ShawnCore
import ShawnFun
import XCTest
@testable import ShawnCLIKit

/// A throwaway directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    init(_ name: String = "shawn-cli-tests") {
        // /tmp (not the long per-user temp path) keeps Unix socket paths under the 104-byte limit.
        url = URL(fileURLWithPath: "/tmp").appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
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

/// Collects things from concurrent callbacks, in order.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func add(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    var all: [Element] { lock.withLock { storage } }
}

// MARK: - Sandbox machine

/// A sandbox with its own home, a `bin` directory first on PATH for fake tools, and the CLI's paths.
struct Sandbox {
    let directory: TempDirectory
    var environment: SystemEnvironment

    init(extraEnvironment: [String: String] = [:]) {
        directory = TempDirectory()
        let root = directory.url
        let bin = root.appendingPathComponent("bin")
        var base = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.appendingPathComponent("home").path,
            "LANG": "en_US.UTF-8",
        ]
        for (key, value) in extraEnvironment { base[key] = value }
        environment = SystemEnvironment.sandbox(root: root, baseEnvironment: base)
        for url in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory, bin,
                    environment.localBin, environment.stateDirectory] {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    var bin: URL { directory.url.appendingPathComponent("bin") }
    var home: URL { environment.home }

    /// An executable script on the sandbox PATH that records its arguments and prints canned output.
    @discardableResult
    func shim(_ name: String, _ body: String) -> URL {
        let url = bin.appendingPathComponent(name)
        try! Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The installed `shawn` the self-updater replaces.
    func installedBinary(contents: String = "old shawn") -> URL {
        let url = environment.localBin.appendingPathComponent("shawn")
        try! Data(contents.utf8).write(to: url)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

// MARK: - Config fixtures

/// Writes a config directory (installer.yaml + steps + optional cli.yaml and fun) and returns its URL.
@discardableResult
func makeConfig(in directory: TempDirectory, at path: String = "config", meta: String = "name: Test Dotfiles\ntagline: tiny test\nvars:\n  github_user: tester\n",
                steps: [String: String], cli: String? = nil, quotes: String? = nil, sprites: [String: String] = [:]) -> URL {
    let root = directory.url.appendingPathComponent(path)
    directory.write("\(path)/installer.yaml", meta)
    for (name, body) in steps { directory.write("\(path)/steps/\(name)", body) }
    if steps.isEmpty { try! FileManager.default.createDirectory(at: root.appendingPathComponent("steps"), withIntermediateDirectories: true) }
    if let cli { directory.write("\(path)/cli.yaml", cli) }
    if let quotes { directory.write("\(path)/fun/quotes.yaml", quotes) }
    for (id, body) in sprites { directory.write("\(path)/fun/sprites/\(id).yaml", body) }
    return root
}

let tinySprite = """
id: blob
name: Blob
palette:
  ".": transparent
  P: "#B57EDC"
  Y: "#FFE66D"
frames:
  - |
    .PP.
    PYYP
    PPPP
    .PP.

"""

// MARK: - Fake item kinds

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
    /// False for a kind whose check can never say "already done" (like opening an app).
    var checkable = true
    var outcome: ActionOutcome = .done(nil)
    var failure: String?
    var followUp: String?
    var log: Log

    var isCheckable: Bool { checkable }

    func check(_ context: ActionContext) async -> CheckResult {
        satisfied ? .satisfied("already there") : .needed(nil)
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        log.add("run:\(title):dryRun=\(context.dryRun)")
        if let followUp { context.followUp(followUp, url: URL(string: "https://example.com/follow")) }
        context.info("working on \(title)")
        _ = try await context.run(Command("/bin/echo", ["installing", title]))
        if let failure { throw ActionError(failure, hint: "try again later") }
        return outcome
    }
}

/// A package kind: satisfied when its name is in `installed`, or (like the real cask kind) when the
/// app its `app:` names is in the Applications folder.
struct FakePackageAction: Action, PackageProviding {
    var title: String
    var packageRef: PackageRef
    var installed: Set<String>
    var app: String?
    var log: FakeAction.Log

    func check(_ context: ActionContext) async -> CheckResult {
        if installed.contains(packageRef.name) { return .satisfied("installed") }
        if let app, FileManager.default.fileExists(atPath: context.environment.applicationsDirectory.appendingPathComponent(app).path) {
            return .satisfied("\(app) is already there (installed without Homebrew)")
        }
        return .needed("not installed")
    }

    func run(_ context: ActionContext) async throws -> ActionOutcome {
        log.add("install:\(packageRef.manager.rawValue):\(packageRef.name):dryRun=\(context.dryRun)")
        _ = try await context.run(Command("/bin/echo", ["install", packageRef.name]))
        return .done("installed")
    }
}

enum FakeKinds {
    /// `ok`, `present`, `boom`, `manual`, `root`, `reminder` (cannot be checked) plus package kinds named by
    /// `names` (manager → YAML kind).
    static func registry(log: FakeAction.Log = FakeAction.Log(), installed: Set<String> = [],
                         names: [PackageRef.Manager: String] = [.formula: "brew", .cask: "cask", .tap: "tap", .mas: "mas", .npm: "npm"]) -> ActionRegistry {
        var registry = ActionRegistry()
        registry.register(ActionDescriptor(kind: "ok", summary: "succeeds", example: "- ok: thing") { parser in
            FakeAction(title: parser.primaryString(), followUp: parser.options.string("follow_up"), log: log)
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
        registry.register(ActionDescriptor(kind: "root", summary: "needs admin rights", example: "- root: thing") { parser in
            FakeAction(title: parser.primaryString(), sudo: .always, log: log)
        })
        registry.register(ActionDescriptor(kind: "reminder", summary: "a to-do nothing can check", example: "- reminder: thing") { parser in
            FakeAction(title: parser.primaryString(), checkable: false, outcome: .needsAttention("do it by hand"), log: log)
        })
        for (manager, kind) in names {
            registry.register(ActionDescriptor(kind: kind, summary: "a \(manager.rawValue) package", example: "- \(kind): name") { parser in
                switch manager {
                case .mas:
                    let id = parser.primaryInt().map(String.init) ?? ""
                    // `name` is a common key: the registry hands it over as item.name, not as an option.
                    let label = parser.item.name ?? ""
                    if label.isEmpty { parser.fail("an App Store item needs name:") }
                    return FakePackageAction(title: label, packageRef: PackageRef(manager: .mas, name: id, label: label), installed: installed, log: log)
                case .tap:
                    let name = parser.primaryString()
                    if !name.isEmpty && name.split(separator: "/").count != 2 { parser.fail("a tap looks like user/repo") }
                    _ = parser.options.bool("trusted")
                    return FakePackageAction(title: name, packageRef: PackageRef(manager: .tap, name: name), installed: installed, log: log)
                default:
                    let name = parser.primaryString()
                    let app = parser.options.string("app")
                    return FakePackageAction(title: name, packageRef: PackageRef(manager: manager, name: name), installed: installed, app: app, log: log)
                }
            })
        }
        return registry
    }
}

// MARK: - Fake outside world

/// Records process launches; answers from a script of canned results.
final class FakeLauncher: ProcessLaunching, @unchecked Sendable {
    struct Response {
        var matches: @Sendable (ProcessRequest) -> Bool
        var result: ProcessResult
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    let events: Recorder<String>
    private(set) var requests: [ProcessRequest] = []
    var interactiveStatus: Int32 = 0
    /// Exit status of attached commands by program name (`gh`), when it differs from `interactiveStatus`.
    var interactiveStatuses: [String: Int32] = [:]

    init(events: Recorder<String> = Recorder()) {
        self.events = events
    }

    func respond(when matches: @escaping @Sendable (ProcessRequest) -> Bool, with result: ProcessResult, delay: TimeInterval = 0) {
        lock.withLock { responses.append(Response(matches: matches, result: result, delay: delay)) }
    }

    /// A canned result for commands whose display string contains `fragment`.
    func respond(_ fragment: String, stdout: String = "", stderr: String = "", exit: Int32 = 0, delay: TimeInterval = 0) {
        respond(when: { $0.displayString.contains(fragment) || $0.arguments.joined(separator: " ").contains(fragment) },
                with: ProcessResult(exitCode: exit, stdout: stdout, stderr: stderr), delay: delay)
    }

    func capture(_ request: ProcessRequest) async -> ProcessResult {
        let response: Response? = lock.withLock {
            requests.append(request)
            return responses.last { $0.matches(request) }
        }
        events.add("capture: " + request.arguments.joined(separator: " "))
        guard let response else { return ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        if response.delay > 0 {
            if let timeout = request.timeout, timeout < response.delay {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return ProcessResult(exitCode: 124, stdout: "", stderr: "", timedOut: true)
            }
            try? await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000))
        }
        return response.result
    }

    func interactive(_ request: ProcessRequest) async -> Int32 {
        lock.withLock { requests.append(request) }
        let program = (request.executable as NSString).lastPathComponent
        events.add("interactive: " + ([program] + request.arguments).joined(separator: " "))
        return lock.withLock { interactiveStatuses[program] ?? interactiveStatus }
    }
}

final class FakeReplacer: ProcessReplacing, @unchecked Sendable {
    let events: Recorder<String>
    private let lock = NSLock()
    private(set) var requests: [ExecRequest] = []
    var failure: Int32?

    init(events: Recorder<String> = Recorder()) {
        self.events = events
    }

    func replace(_ request: ExecRequest) -> ExecOutcome {
        lock.withLock { requests.append(request) }
        events.add("exec: " + request.argv.joined(separator: " "))
        if let failure { return .failed(failure) }
        return .replaced
    }

    var last: ExecRequest? { lock.withLock { requests.last } }
}

/// git that answers from a script (and records every call), for flows whose exact commands matter.
final class FakeGit: GitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(prefix: [String], result: ProcessResult)] = []
    private(set) var calls: [[String]] = []
    /// Seconds the commands in `slow` take (they time out when the caller's timeout is shorter).
    var delay: TimeInterval = 0
    var slow: Set<String> = []

    func answer(_ prefix: [String], stdout: String = "", exit: Int32 = 0, stderr: String = "") {
        lock.withLock { answers.append((prefix, ProcessResult(exitCode: exit, stdout: stdout, stderr: stderr))) }
    }

    func run(_ arguments: [String], in directory: URL?, timeout: TimeInterval?) async -> ProcessResult {
        let answer: ProcessResult? = lock.withLock {
            calls.append(arguments)
            return answers.last { Array(arguments.prefix($0.prefix.count)) == $0.prefix }?.result
        }
        if delay > 0, let command = arguments.first, slow.contains(command) {
            let wait = min(delay, timeout ?? delay)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if let timeout, timeout < delay { return ProcessResult(exitCode: 124, stdout: "", stderr: "", timedOut: true) }
        }
        return answer ?? ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    var commandLines: [String] { lock.withLock { calls.map { $0.joined(separator: " ") } } }
}

final class FakeBuilder: Builder, @unchecked Sendable {
    let output: URL
    var fail: String?
    private(set) var builds: [URL] = []

    init(output: URL) {
        self.output = output
    }

    func build(package: URL, product: String, timeout: TimeInterval) async -> Result<URL, BuildFailure> {
        builds.append(package)
        if let fail { return .failure(BuildFailure(message: fail)) }
        try! Data("#!/bin/sh\necho new shawn\n".utf8).write(to: output)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
        return .success(output)
    }
}

final class FakeReleases: ReleaseSource, @unchecked Sendable {
    var manifest: ReleaseManifest?
    var payload = Data()
    private(set) var downloads: [URL] = []

    func manifest(repo: String, tag: String, timeout: TimeInterval) async throws -> ReleaseManifest {
        guard let manifest else { throw BuildFailure(message: "no manifest") }
        return manifest
    }

    func download(_ url: URL, timeout: TimeInterval) async throws -> Data {
        downloads.append(url)
        return payload
    }
}

final class FakeRemoteConfig: RemoteConfigRefreshing, @unchecked Sendable {
    var root: URL?
    private(set) var refreshes = 0

    func refresh(timeout: TimeInterval) async -> URL? {
        refreshes += 1
        return root
    }
}

final class FakeClock: Clock, @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { date }
}

struct FakeInventory: Inventory {
    var packages: InstalledPackages
    func installed() async -> InstalledPackages { packages }
}

struct FakeStatusGit: StatusGitProbing {
    var root: URL?
    var status: GitStatus?

    func repositoryRoot(for directory: URL) -> URL? { root }
    func status(of root: URL, directory: URL) -> GitStatus? { status }
}

final class ScriptedInteraction: UserInteraction, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var passwordRequests = 0
    var password: String?

    func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
        lock.withLock { passwordRequests += 1 }
        return attempt == 1 ? password : nil
    }

    func ask(_ question: Question) async -> String { question.defaultOptionID }
}

// MARK: - Context

struct Harness {
    let sandbox: Sandbox
    let context: CLIContext
    let out: BufferOutput
    let err: BufferOutput
    let launcher: FakeLauncher
    let replacer: FakeReplacer
    let events: Recorder<String>

    init(sandbox: Sandbox = Sandbox(), registry: ActionRegistry = FakeKinds.registry(), config: URL? = nil, width: Int = 100,
         stdin: String = "", configure: (inout CLIServices) -> Void = { _ in }) {
        self.sandbox = sandbox
        let events = Recorder<String>()
        self.events = events
        let launcher = FakeLauncher(events: events)
        let replacer = FakeReplacer(events: events)
        self.launcher = launcher
        self.replacer = replacer
        var services = CLIServices()
        services.launcher = launcher
        services.replacer = replacer
        let input = Data(stdin.utf8)
        services.readStdin = { input }
        services.clock = FakeClock()
        services.desktop = NoDesktop()
        services.inventory = FakeInventory(packages: InstalledPackages())
        services.interaction = { _ in ScriptedInteraction() }
        // Never the network: git answers everything with empty success unless a test says otherwise.
        services.git = FakeGit()
        services.releases = FakeReleases()
        services.remoteConfig = FakeRemoteConfig()
        services.builder = FakeBuilder(output: sandbox.directory.url.appendingPathComponent("built-shawn"))
        configure(&services)
        out = BufferOutput()
        err = BufferOutput()
        var environment = sandbox.environment
        if let config { environment.baseEnvironment["SHAWN_CONFIG_DIR"] = config.path }
        context = CLIContext(environment: environment, registry: registry, terminal: .plain(width: width), out: out, err: err,
                             services: services, shawnBinary: sandbox.installedBinary(), currentDirectory: sandbox.home, arguments: [])
    }

    func run(_ arguments: [String]) async -> Int32 {
        context.arguments = arguments
        return await Dispatcher.run(arguments: arguments, context: context)
    }
}

struct NoDesktop: DesktopActions {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
}

/// Runs git for real (fixtures for the self-updater and add/pr flows).
@discardableResult
func git(_ arguments: [String], in directory: URL, file: StaticString = #filePath, line: UInt = #line) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=master",
                         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
    process.currentDirectoryURL = directory
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")): \(output)", file: file, line: line)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}
