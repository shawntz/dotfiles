import Foundation
import XCTest
import ShawnCore
@testable import ShawnSync

/// A throwaway directory under the per-user temporary directory, removed when the test ends.
final class TempDirectory {
    let url: URL

    /// With `underPrivate`, the directory is named by its physical path, starting with `/private/` (as a
    /// `--sandbox` folder under /tmp or /var/folders is, or a relative one typed from a working directory
    /// there). `standardizedFileURL` and `resolvingSymlinksInPath` drop that prefix only from paths that
    /// exist, so code that compares a folder with a file not yet written in it misbehaves only there; the
    /// default form, which drops the prefix up front, cannot show it.
    init(_ name: String = "shawn-sync-tests", underPrivate: Bool = false) {
        let unique = "\(name)-\(UUID().uuidString.prefix(8))"
        if underPrivate {
            url = Self.physicalTemporaryDirectory().appendingPathComponent(unique)
        } else {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(unique).resolvingSymlinksInPath()
        }
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The per-user temporary directory as the kernel names it (`realpath`, which keeps `/private`), or
    /// /private/tmp when that is not under /private.
    private static func physicalTemporaryDirectory() -> URL {
        if let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) {
            defer { free(resolved) }
            let path = String(cString: resolved)
            if path.hasPrefix("/private/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return URL(fileURLWithPath: "/private/tmp", isDirectory: true)
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

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }

    /// Every file and folder below the directory, as relative paths.
    func everything() -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []
    }
}

extension SystemEnvironment {
    /// A sandbox rooted in `directory` with its directories created and no inherited `SHAWN_CONFIG_DIR`.
    static func testSandbox(_ directory: TempDirectory, extraEnvironment: [String: String] = [:]) -> SystemEnvironment {
        var base = ProcessInfo.processInfo.environment
        base.removeValue(forKey: ConfigLocator.environmentVariable)
        for (key, value) in extraEnvironment { base[key] = value }
        let environment = SystemEnvironment.sandbox(root: directory.url, baseEnvironment: base)
        for url in [environment.home, environment.applicationsDirectory, environment.temporaryDirectory] {
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return environment
    }
}

/// An action that does nothing; enough for configs to load and plan.
struct NoopAction: Action {
    let title: String
    func check(_ context: ActionContext) async -> CheckResult { .satisfied(nil) }
    func run(_ context: ActionContext) async throws -> ActionOutcome { .done(nil) }
}

/// Registers the kinds `ok` and `note-only` (the latter takes a `text:` option).
func testRegistry() -> ActionRegistry {
    var registry = ActionRegistry()
    registry.register(ActionDescriptor(kind: "ok", summary: "does nothing", example: "- ok: thing") { parser in
        NoopAction(title: parser.primaryString())
    })
    registry.register(ActionDescriptor(kind: "note-only", summary: "does nothing either", example: "- note-only: thing") { parser in
        _ = parser.options.string("text")
        return NoopAction(title: parser.primaryString())
    })
    return registry
}

/// `installer.yaml` text for test configs.
func metaYAML(name: String, schema: Int = 1, repo: String = "octo/dots", branch: String = "main",
              path: String = "installer/config") -> String {
    """
    schema: \(schema)
    name: \(name)
    remote:
      repo: \(repo)
      branch: \(branch)
      path: \(path)
    vars:
      editor: nvim

    """
}

/// Writes a config directory at `relative` inside `directory` and returns its URL.
@discardableResult
func writeConfig(in directory: TempDirectory, at relative: String = "config", name: String = "Local Dotfiles",
                 remoteBranch: String = "main") -> URL {
    directory.write("\(relative)/installer.yaml", metaYAML(name: name, branch: remoteBranch))
    directory.write("\(relative)/steps/01-base.yaml", "id: base\ntitle: Base\nitems:\n  - ok: local thing\n")
    return directory.url.appendingPathComponent(relative)
}

/// Loads a local config the way `ConfigResolver.resolveLocal` would.
func loadLocal(_ root: URL, environment: SystemEnvironment, source: ConfigSource? = nil) throws -> ResolvedConfig {
    try ConfigResolver.load(directory: root, source: source ?? .local(root.path), registry: testRegistry(), environment: environment)
}

func permissions(of url: URL) -> Int {
    (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

/// Polls until `condition` holds or `timeout` passes (for work that unwinds in the background).
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
