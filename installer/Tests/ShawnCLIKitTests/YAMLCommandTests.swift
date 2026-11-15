import Darwin
import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

final class YAMLCommandTests: XCTestCase {
    private let cli = """
    commands:
      claude:
        section: AI
        summary: Claude
        update: claude update
        update_timeout: 1
        env:
          GREETING: "hi {{github_user}}"
        exec:
          - claude
          - --settings
          - json:
              statusLine: { type: command, command: '"{{shawn_bin}}" statusline' }
              n: 3
      bare:
        summary: No update
        exec: claude
      ghost:
        summary: A tool that is not installed
        update: ghost update
        exec: [ghost-tool-that-does-not-exist]
    """

    private func makeHarness() -> Harness {
        let sandbox = Sandbox()
        sandbox.shim("claude", "echo fake claude")
        let config = makeConfig(in: sandbox.directory, steps: [:], cli: cli)
        return Harness(sandbox: sandbox, config: config)
    }

    /// Ctrl-C while the update runs. The update has a session of its own, so the terminal's SIGINT reaches only
    /// shawn; before, shawn died and left the update (and its `sleep`) running in the background.
    /// A real SIGINT is sent to this test process, with a no-op handler underneath as a safety net.
    func testCtrlCDuringTheUpdateStopsItAndLaunchesNothing() async throws {
        var safety = sigaction()
        safety.__sigaction_u.__sa_handler = { _ in }
        var original = sigaction()
        sigaction(SIGINT, &safety, &original)
        defer { sigaction(SIGINT, &original, nil) }

        var sandbox = Sandbox()
        sandbox.environment.baseEnvironment["SHAWN_NO_SELF_UPDATE"] = "1"
        sandbox.shim("slowtool", "exit 0")
        let marks = sandbox.directory.url.path
        let cli = "commands:\n  slow:\n    summary: Slow update\n    update_timeout: 60\n"
            + "    update: 'printf %s $$ > \(marks)/update.pid; sleep 30 & printf %s $! > \(marks)/sleep.pid; wait'\n"
            + "    exec: [slowtool]\n"
        let harness = Harness(sandbox: sandbox, config: makeConfig(in: sandbox.directory, steps: [:], cli: cli))
        harness.context.services.launcher = SystemProcessLauncher()
        let started = Date()
        let run = Task { await harness.run(["slow"]) }

        let sleepFile = marks + "/sleep.pid"
        for _ in 0..<500 where (try? String(contentsOfFile: sleepFile, encoding: .utf8))?.isEmpty ?? true { usleep(10_000) }
        let updatePID = try XCTUnwrap(Int32(try String(contentsOfFile: marks + "/update.pid", encoding: .utf8)))
        let sleepPID = try XCTUnwrap(Int32(try String(contentsOfFile: sleepFile, encoding: .utf8)))
        usleep(200_000)
        kill(getpid(), SIGINT)

        let code = await run.value
        XCTAssertEqual(code, ExitCode.interrupted)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "the 30 s update did not run to the end")
        XCTAssertTrue(harness.replacer.requests.isEmpty, "nothing launched")
        XCTAssertTrue(harness.err.plain.contains("■ slow: update stopped, nothing launched (shawn slow --no-update skips the update)"), harness.err.plain)
        for pid in [updatePID, sleepPID] {
            var gone = false
            for _ in 0..<500 {
                if kill(pid, 0) == -1 && errno == ESRCH { gone = true; break }
                usleep(10_000)
            }
            XCTAssertTrue(gone, "process \(pid) of the update is still running")
            if !gone { kill(pid, SIGKILL) }
        }
    }

    func testExecArgumentsJSONElementAndUserArguments() async throws {
        let harness = makeHarness()
        harness.launcher.respond("claude update", stdout: "Checking for updates...\nClaude Code is up to date (2.1.325)\n")
        let code = await harness.run(["claude", "-p", "it's lumpy", "--model", "opus"])
        XCTAssertEqual(code, 0)
        let request = try XCTUnwrap(harness.replacer.last)
        XCTAssertEqual(request.path, harness.sandbox.bin.appendingPathComponent("claude").path)
        let binary = harness.context.shawnBinary.path
        XCTAssertEqual(request.argv, [
            "claude", "--settings",
            #"{"statusLine":{"type":"command","command":"\"\#(binary)\" statusline"},"n":3}"#,
            "-p", "it's lumpy", "--model", "opus",
        ])
        XCTAssertEqual(request.environment["GREETING"], "hi tester", "{{vars}} expand in env")
        XCTAssertNil(request.environment[SelfUpdateRunner.reexecMarker])
        XCTAssertTrue(request.environment["PATH"]?.contains(harness.sandbox.environment.localBin.path) ?? false, "installer tool dirs appended to PATH")
    }

    func testUpdateRunsBeforeExecAndIsSummarisedInOneLine() async throws {
        let harness = makeHarness()
        harness.launcher.respond("claude update", stdout: "Current version: 2.1.325\nChecking for updates to latest version...\nClaude Code is up to date (2.1.325)\n")
        _ = await harness.run(["claude"])
        XCTAssertEqual(harness.events.all.count, 2)
        XCTAssertEqual(harness.events.all[0], "capture: -c claude update")
        XCTAssertTrue(harness.events.all[1].hasPrefix("exec: claude --settings"))
        XCTAssertEqual(harness.err.plain, "✓ claude: Claude Code is up to date (2.1.325)\n")
        let update = try XCTUnwrap(harness.launcher.requests.first)
        XCTAssertEqual(update.executable, "/bin/bash")
        XCTAssertEqual(update.timeout, 1)
    }

    func testFailingUpdateStillLaunches() async throws {
        let harness = makeHarness()
        harness.launcher.respond("claude update", stderr: "network unreachable\n", exit: 1)
        let code = await harness.run(["claude", "--version"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.err.plain, "! claude: update failed (exit 1: network unreachable); launching the version you have\n")
        XCTAssertEqual(harness.replacer.last?.argv.last, "--version")
    }

    func testSlowUpdateIsCutOffAndStillLaunches() async throws {
        let harness = makeHarness()
        harness.launcher.respond("claude update", stdout: "never seen", delay: 5)
        let started = Date()
        _ = await harness.run(["claude"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "bounded by update_timeout (1s)")
        XCTAssertEqual(harness.err.plain, "! claude: the update took longer than 1s, skipped it; launching the version you have\n")
        XCTAssertNotNil(harness.replacer.last)
    }

    func testNoUpdateFlagIsStrippedAndSkipsTheUpdate() async throws {
        for arguments in [["claude", "--no-update", "-p", "x"], ["--no-update", "claude", "-p", "x"], ["claude", "--no-update", "--no-update", "-p", "x"]] {
            let harness = makeHarness()
            _ = await harness.run(arguments)
            XCTAssertTrue(harness.launcher.requests.isEmpty, "\(arguments): no update")
            XCTAssertEqual(Array(try XCTUnwrap(harness.replacer.last).argv.suffix(2)), ["-p", "x"], "\(arguments)")
            XCTAssertFalse(try XCTUnwrap(harness.replacer.last).argv.contains("--no-update"))
            XCTAssertEqual(harness.err.text, "")
        }
        // Later on the line it belongs to the tool, untouched.
        let harness = makeHarness()
        _ = await harness.run(["claude", "-p", "--no-update"])
        XCTAssertEqual(harness.replacer.last?.argv.last, "--no-update")
    }

    func testEnvironmentVariableSkipsTheUpdate() async {
        let sandbox = Sandbox(extraEnvironment: ["SHAWN_NO_UPDATE": "1"])
        sandbox.shim("claude", "true")
        let config = makeConfig(in: sandbox.directory, steps: [:], cli: cli)
        let harness = Harness(sandbox: sandbox, config: config)
        _ = await harness.run(["claude"])
        XCTAssertTrue(harness.launcher.requests.isEmpty)
        XCTAssertNotNil(harness.replacer.last)
    }

    func testMissingToolFailsPolitelyBeforeAnyUpdate() async {
        let harness = makeHarness()
        let code = await harness.run(["ghost"])
        XCTAssertEqual(code, 127)
        XCTAssertTrue(harness.launcher.requests.isEmpty)
        XCTAssertTrue(harness.replacer.requests.isEmpty)
        XCTAssertTrue(harness.err.plain.contains("ghost-tool-that-does-not-exist is not installed"), harness.err.plain)
    }

    func testWrapperNeverExecsShawnItself() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: [:], cli: "commands:\n  loop:\n    summary: x\n    exec: [shawn]\n")
        let harness = Harness(sandbox: sandbox, config: config)
        // The only `shawn` on PATH is the running binary.
        try! FileManager.default.createSymbolicLink(at: sandbox.bin.appendingPathComponent("shawn"), withDestinationURL: harness.context.shawnBinary)
        do { let code = await harness.run(["loop"]); XCTAssertEqual(code, 127) }
    }

    func testExecFailureIsReported() async {
        let harness = makeHarness()
        harness.replacer.failure = EACCES
        let code = await harness.run(["bare"])
        XCTAssertEqual(code, ExitCode.cannotExecute)
        XCTAssertTrue(harness.err.plain.contains("Permission denied"), harness.err.plain)
    }

    func testLastMeaningfulLine() {
        XCTAssertEqual(YAMLCommandRunner.lastMeaningfulLine("Checking...\n\u{1B}[32mUpdated to 1.2\u{1B}[0m\n\n"), "Updated to 1.2")
        XCTAssertEqual(YAMLCommandRunner.lastMeaningfulLine("50%\r100%\rDone!\n"), "Done!")
        XCTAssertNil(YAMLCommandRunner.lastMeaningfulLine("\n  \n"))
    }
}
