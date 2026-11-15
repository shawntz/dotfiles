import Darwin
import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

/// Runs the `run:` scripts from the shipped config/cli.yaml with macOS's /bin/bash (3.2), in a sandbox
/// home with fake `pbcopy` / `caffeinate` / `shawn` first on PATH. Nothing here touches the real home.
final class ScriptTests: XCTestCase {
    static let config: CLIConfig = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/cli.yaml")
        return CLIConfig.parse(try! YAML.parseFile(file, displayName: "cli.yaml"), file: "cli.yaml").config
    }()

    struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func run(_ name: String, _ arguments: [String] = [], sandbox: Sandbox, environment extra: [String: String] = [:],
                     file: StaticString = #filePath, line: UInt = #line) -> Run {
        guard let command = Self.config.command(named: name), case .run(let script) = command.action else {
            XCTFail("no run command \(name)", file: file, line: line)
            return Run(status: -1, stdout: "", stderr: "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "shawn \(name)"] + arguments
        var environment = [
            "HOME": sandbox.home.path,
            "PATH": "\(sandbox.bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SHAWN_USER_PATH": "\(sandbox.bin.path):/usr/bin:/bin",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": sandbox.environment.temporaryDirectory.path,
        ]
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        process.currentDirectoryURL = sandbox.home
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try! process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    func testEveryRunCommandRejectsNonsenseArgumentsPolitely() {
        let sandbox = Sandbox()
        let bad: [(String, [String])] = [
            ("ports", ["a", "b"]), ("killport", []), ("killport", ["abc"]), ("killport", ["70000"]), ("killport", ["80", "--forse"]),
            ("ip", ["--bogus"]), ("keys", ["a", "b"]), ("clean", ["--all"]), ("brewfile", ["x"]), ("serve", ["80"]), ("serve", ["http"]),
            ("path", ["x"]), ("whatsup", ["x"]), ("today", ["yesterday"]), ("awake", []), ("awake", ["soon"]), ("awake", ["0"]), ("awake", ["2w"]),
            ("awake", ["00m"]), ("awake", ["0h0m0s"]), ("awake", ["99999999"]), ("awake", ["8d"]), ("awake", ["10081"]),
        ]
        for (name, arguments) in bad {
            let result = run(name, arguments, sandbox: sandbox)
            XCTAssertEqual(result.status, 64, "\(name) \(arguments): \(result.stderr)")
            XCTAssertTrue(result.stderr.hasPrefix("usage: shawn \(name)"), "\(name) \(arguments): \(result.stderr)")
            XCTAssertEqual(result.stdout, "", "\(name) \(arguments)")
        }
    }

    func testPathFlagsMissingAndDuplicateEntries() {
        let sandbox = Sandbox()
        let result = run("path", sandbox: sandbox, environment: ["SHAWN_USER_PATH": "/usr/bin:\(sandbox.home.path)/nope:/usr/bin::/bin"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, """
         1  /usr/bin
         2  ~/nope  ← does not exist
         3  /usr/bin  ← duplicate
         4    ← empty entry (means the current directory)
         5  /bin

        """)
    }

    func testKillportStopsAListener() throws {
        let sandbox = Sandbox()
        let port = Int.random(in: 40_000...60_000)
        // A listener on localhost only (all interfaces could raise the firewall prompt).
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        listener.arguments = ["-c", "import socket, time\ns = socket.socket()\ns.bind(('127.0.0.1', \(port)))\ns.listen()\ntime.sleep(60)"]
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer { if listener.isRunning { listener.terminate() } }
        for _ in 0..<100 where !run("ports", [String(port)], sandbox: sandbox).stdout.contains("127.0.0.1") { usleep(100_000) }

        let ports = run("ports", [String(port)], sandbox: sandbox)
        XCTAssertEqual(ports.status, 0)
        XCTAssertTrue(ports.stdout.hasPrefix("PORT    PID     PROGRAM                ADDRESS\n\(port) "), ports.stdout)
        XCTAssertTrue(ports.stdout.contains("127.0.0.1"), ports.stdout)

        let killed = run("killport", [String(port)], sandbox: sandbox)
        XCTAssertEqual(killed.status, 0, killed.stderr)
        XCTAssertTrue(killed.stdout.hasPrefix("stopping "), killed.stdout)
        XCTAssertTrue(killed.stdout.hasSuffix("Port \(port) is free.\n"), killed.stdout)
        listener.waitUntilExit()
        XCTAssertFalse(listener.isRunning)

        let nothing = run("killport", ["009"], sandbox: sandbox)
        XCTAssertEqual(nothing.stdout, "Nothing of yours is listening on port 9.\n", "leading zeros are not octal")
        XCTAssertEqual(run("ports", ["no-such-program-xyz"], sandbox: sandbox).stdout, "Nothing matching 'no-such-program-xyz' is listening on a TCP port.\n")
    }

    func testKeysPrintsAndCopiesTheDefaultKey() throws {
        let sandbox = Sandbox()
        let none = run("keys", sandbox: sandbox)
        XCTAssertEqual(none.status, 1)
        XCTAssertTrue(none.stderr.contains("No SSH public keys in ~/.ssh yet"))

        let ssh = sandbox.home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        for name in ["aaa_rsa", "id_ed25519"] {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "\(name)@test", "-f", ssh.appendingPathComponent(name).path]
            try keygen.run()
            keygen.waitUntilExit()
        }
        let clipboard = sandbox.directory.url.appendingPathComponent("clipboard.txt")
        sandbox.shim("pbcopy", "cat > '\(clipboard.path)'")
        let result = run("keys", sandbox: sandbox)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("aaa_rsa  SHA256:"), result.stdout)
        XCTAssertTrue(result.stdout.hasSuffix("copied id_ed25519.pub to the clipboard\n"), result.stdout)
        let expected = try String(contentsOf: ssh.appendingPathComponent("id_ed25519.pub"), encoding: .utf8).trimmingCharacters(in: .newlines)
        XCTAssertEqual(try String(contentsOf: clipboard, encoding: .utf8), expected)

        XCTAssertTrue(run("keys", ["aaa_rsa.pub"], sandbox: sandbox).stdout.hasSuffix("copied aaa_rsa.pub to the clipboard\n"))
        let missing = run("keys", ["nope"], sandbox: sandbox)
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.stderr.contains("no key named 'nope'"))
    }

    func testCleanMeasuresAndCleansOnlyWithYes() throws {
        let sandbox = Sandbox()
        XCTAssertEqual(run("clean", sandbox: sandbox).stdout, "No caches found.\n")
        let derived = sandbox.home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: derived.appendingPathComponent("blob"))
        let report = run("clean", sandbox: sandbox)
        XCTAssertEqual(report.status, 0)
        XCTAssertTrue(report.stdout.contains("  Xcode DerivedData        "), report.stdout)
        XCTAssertTrue(report.stdout.contains("~/Library/Developer/Xcode/DerivedData"), report.stdout)
        XCTAssertTrue(report.stdout.hasSuffix("Run 'shawn clean --yes' to empty them.\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: derived.path), "measuring changes nothing")

        let cleaned = run("clean", ["--yes"], sandbox: sandbox)
        XCTAssertEqual(cleaned.status, 0, cleaned.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: derived.deletingLastPathComponent().path), "DerivedData itself stays")
    }

    func testAwakeParsesDurations() {
        let sandbox = Sandbox()
        sandbox.shim("caffeinate", #"echo "caffeinate $*""#)
        // Leading zeros are decimal: before, 010 meant 8 minutes and 08 or 1h09m failed with "value too great for base".
        for (spec, seconds) in [("45m", 2700), ("2h", 7200), ("1h30m", 5400), ("90s", 90), ("15", 900),
                                ("010", 600), ("08", 480), ("09", 540), ("1h09m", 4140), ("1h08m", 4080), ("090s", 90), ("10080", 604800)] {
            let result = run("awake", [spec], sandbox: sandbox)
            XCTAssertEqual(result.status, 0, "\(spec): \(result.stderr)")
            XCTAssertTrue(result.stdout.hasPrefix("Keeping this Mac awake until "), result.stdout)
            XCTAssertTrue(result.stdout.hasSuffix("caffeinate -dims -t \(seconds)\n"), "\(spec): \(result.stdout)")
            XCTAssertEqual(result.stderr, "", spec)
        }
    }

    func testWhatsupAndToday() throws {
        let sandbox = Sandbox()
        sandbox.directory.write("home/.gitconfig", "[user]\n  name = LSP\n  email = lsp@example.com\n[init]\n  defaultBranch = main\n")
        let developer = sandbox.home.appendingPathComponent("Developer")
        let clean = developer.appendingPathComponent("clean-repo")
        let messy = developer.appendingPathComponent("org/messy-repo")
        for repo in [clean, messy] {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            git(["init", "-q", "-b", "main"], in: repo)
            try Data("hi\n".utf8).write(to: repo.appendingPathComponent("README.md"))
            git(["add", "."], in: repo)
            let commit = Process()
            commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            commit.arguments = ["commit", "-q", "-m", "first in \(repo.lastPathComponent)"]
            commit.currentDirectoryURL = repo
            commit.environment = ["HOME": sandbox.home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
            try commit.run()
            commit.waitUntilExit()
        }
        try Data("changed\n".utf8).write(to: messy.appendingPathComponent("README.md"))

        let whatsup = run("whatsup", sandbox: sandbox)
        XCTAssertEqual(whatsup.status, 0, whatsup.stderr)
        XCTAssertTrue(whatsup.stdout.hasPrefix("org/messy-repo"), whatsup.stdout)
        XCTAssertTrue(whatsup.stdout.contains("main"))
        XCTAssertTrue(whatsup.stdout.contains("1 changed"))
        XCTAssertFalse(whatsup.stdout.contains("clean-repo"))

        let today = run("today", sandbox: sandbox)
        XCTAssertEqual(today.status, 0, today.stderr)
        XCTAssertTrue(today.stdout.contains("clean-repo (1)\n"), today.stdout)
        XCTAssertTrue(today.stdout.contains("first in messy-repo"), today.stdout)
        XCTAssertTrue(today.stdout.hasSuffix("2 commit(s) since midnight.\n"), today.stdout)
        XCTAssertTrue(run("today", ["--since", "1 year ago"], sandbox: sandbox).stdout.hasSuffix("2 commit(s) since 1 year ago.\n"))

        try FileManager.default.removeItem(at: sandbox.home.appendingPathComponent(".gitconfig"))
        let noEmail = run("today", sandbox: sandbox)
        XCTAssertEqual(noEmail.status, 1)
        XCTAssertTrue(noEmail.stderr.contains("set your email first"))

        try Data("hi\n".utf8).write(to: messy.appendingPathComponent("README.md"))
        XCTAssertTrue(run("whatsup", sandbox: sandbox).stdout.hasPrefix("All quiet"))
    }

    func testBrewfileAndServeHandOverCorrectly() throws {
        let sandbox = Sandbox()
        let fakeShawn = sandbox.shim("fake-shawn", #"echo "args=$* no_self_update=$SHAWN_NO_SELF_UPDATE""#)
        let brewfile = run("brewfile", sandbox: sandbox, environment: ["SHAWN_BIN": fakeShawn.path])
        XCTAssertEqual(brewfile.stdout, "args=config brewfile no_self_update=1\n")

        sandbox.shim("python3", #"echo "python3 $*""#)
        let serve = run("serve", ["08080"], sandbox: sandbox)
        XCTAssertEqual(serve.status, 0, serve.stderr)
        XCTAssertTrue(serve.stdout.hasSuffix("python3 -m http.server 8080 --bind 127.0.0.1\n"), serve.stdout)
    }

    /// `shawn --config DIR brewfile` prints DIR's Brewfile: the script hands the config it was started with
    /// to `shawn config brewfile` (before, the child fell back to the default config).
    func testBrewfileUsesTheConfigItWasStartedWith() async throws {
        let sandbox = Sandbox()
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/cli.yaml")
        let cliText = try String(contentsOf: shipped, encoding: .utf8)
        let defaultConfig = makeConfig(in: sandbox.directory, at: "default config", steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - brew: eza\n"], cli: cliText)
        let other = makeConfig(in: sandbox.directory, at: "other config", steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - brew: zzz-only-in-other\n"], cli: cliText)

        // 1. The YAML command runs with SHAWN_CONFIG and SHAWN_CONFIG_EXPLICIT set to the --config directory.
        let harness = Harness(sandbox: sandbox, config: defaultConfig)
        _ = await harness.run(["--no-update", "--config", other.path, "brewfile"])
        let request = try XCTUnwrap(harness.replacer.last)
        let configDirectory = try XCTUnwrap(request.environment["SHAWN_CONFIG_EXPLICIT"])
        XCTAssertEqual(URL(fileURLWithPath: configDirectory).standardizedFileURL.path, other.standardizedFileURL.path)
        XCTAssertEqual(request.environment["SHAWN_CONFIG"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }, other.standardizedFileURL.path)

        // 2. The script, run with that environment, passes it on as --config (one argument, spaces and all).
        let fakeShawn = sandbox.shim("fake-shawn", #"printf '<%s>' "$@"; echo " no_self_update=$SHAWN_NO_SELF_UPDATE""#)
        let handedOver = run("brewfile", sandbox: sandbox, environment: request.environment.merging(["SHAWN_BIN": fakeShawn.path]) { $1 })
        XCTAssertEqual(handedOver.stdout, "<--config><\(configDirectory)><config><brewfile> no_self_update=1\n")

        // 3. ...and `config brewfile` reads that directory.
        let brewfile = Harness(sandbox: sandbox, config: defaultConfig)
        _ = await brewfile.run(["--no-update", "--config", configDirectory, "config", "brewfile"])
        XCTAssertTrue(brewfile.out.plain.contains("brew \"zzz-only-in-other\""), brewfile.out.plain)
        XCTAssertFalse(brewfile.out.plain.contains("brew \"eza\""), brewfile.out.plain)
    }

    /// `shawn brewfile` with no --config lets `shawn config brewfile` find the config itself, so it gets past a
    /// snapshot that no longer loads exactly as `shawn config brewfile` does. Before, the script always passed the
    /// config the CLI was using as --config, which is taken strictly: a copy fetched from GitHub that this build
    /// cannot load (a new item kind) made `shawn brewfile` fail while `shawn config brewfile` worked.
    func testBrewfileFallsBackPastAStaleFetchedConfigLikeConfigBrewfileDoes() async throws {
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/cli.yaml")
        let cliText = try String(contentsOf: shipped, encoding: .utf8)
        // An exported SHAWN_CONFIG_EXPLICIT from some outer shawn must not leak into this one.
        let sandbox = Sandbox(extraEnvironment: ["SHAWN_CONFIG_EXPLICIT": "/somewhere/else"])
        let fetched = makeConfig(in: sandbox.directory, at: "home/Library/Caches/ShawnsDotfiles/config",
                                 steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - teleport: somewhere\n  - brew: eza\n"], cli: cliText)
        makeConfig(in: sandbox.directory, at: "home/.shawn/config", steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - brew: eza\n"], cli: cliText)
        func harness() -> Harness {
            let harness = Harness(sandbox: sandbox)
            var state = harness.context.stateStore.load()
            state.remoteConfigRoot = fetched.path
            harness.context.stateStore.save(state)
            return harness
        }

        // `shawn config brewfile` skips the fetched copy and uses the installed one, with a note.
        let direct = harness()
        let directCode = await direct.run(["--no-update", "config", "brewfile"])
        XCTAssertEqual(directCode, 0, direct.err.plain)
        XCTAssertTrue(direct.out.plain.contains("brew \"eza\""), direct.out.plain)

        // `shawn brewfile` comes from the fetched copy's cli.yaml; nobody named a config, so none is handed on.
        let yaml = harness()
        _ = await yaml.run(["--no-update", "brewfile"])
        let request = try XCTUnwrap(yaml.replacer.last)
        XCTAssertEqual(request.environment["SHAWN_CONFIG"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }, fetched.standardizedFileURL.path)
        XCTAssertNil(request.environment["SHAWN_CONFIG_EXPLICIT"])

        let fakeShawn = sandbox.shim("fake-shawn", #"printf '%s\n' "$@""#)
        let script = run("brewfile", sandbox: sandbox, environment: request.environment.merging(["SHAWN_BIN": fakeShawn.path]) { $1 })
        let childArguments = script.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(childArguments, ["config", "brewfile"], script.stderr)

        // …so the shawn it starts behaves like `shawn config brewfile`.
        let child = harness()
        let childCode = await child.run(["--no-update"] + childArguments)
        XCTAssertEqual(childCode, 0, "shawn brewfile fails where shawn config brewfile works: " + child.err.plain)
        XCTAssertEqual(child.out.plain, direct.out.plain)
        XCTAssertTrue(child.err.plain.contains("Skipped the config at"), child.err.plain)
    }

    func testIPLocalOnlyIsReadOnly() {
        let result = run("ip", ["--local"], sandbox: Sandbox())
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("local"), result.stdout)
        XCTAssertFalse(result.stdout.contains("public"))
    }
}
