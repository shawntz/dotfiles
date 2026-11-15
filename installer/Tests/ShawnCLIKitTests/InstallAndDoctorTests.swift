import Darwin
import Foundation
@testable import ShawnCore
import ShawnFun
import XCTest
@testable import ShawnCLIKit

final class InstallRendererTests: XCTestCase {
    private func plan() throws -> InstallPlan {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, steps: [
            "01-first.yaml": "id: first\ntitle: First Things\nsubtitle: the basics\nitems:\n  - ok: alpha\n  - present: beta\n",
            "02-second.yaml": "id: second\ntitle: Second\nitems:\n  - boom: gamma\n  - manual: delta\n",
        ])
        let loaded = try ConfigLoader.load(from: root)
        return InstallPlan.build(config: loaded.config, registry: FakeKinds.registry(), environment: Sandbox().environment)
    }

    func testPlainOutputFromSyntheticEvents() throws {
        let plan = try plan()
        let out = BufferOutput()
        let renderer = InstallRenderer(plan: plan, selection: .defaults(for: plan), fun: .fallback, terminal: .plain(), out: out, desktop: nil, seed: 0)
        var summary = InstallSummary()
        summary.done = 1
        summary.alreadyDone = 1
        summary.needsAttention = 1
        summary.failures = [.init(itemID: "second/0", title: "gamma", message: "kaboom")]
        summary.followUps = [FollowUp(id: "f", title: "Sign in to the thing", detail: "It's in the menu bar", url: URL(string: "https://example.com"))]
        summary.duration = 75
        let events: [InstallEvent] = [
            .runStarted(totalItems: 4),
            .stepStatus(stepID: "first", status: .running),
            .itemStatus(itemID: "first/0", status: .checking),
            .itemStatus(itemID: "first/0", status: .running),
            .log(LogLine("$ brew install alpha", style: .command, itemID: "first/0")),
            .log(LogLine("==> Pouring alpha", style: .stdout, itemID: "first/0")),
            .log(LogLine("50%", style: .stdout, itemID: "first/0", isProgress: true)),
            .itemStatus(itemID: "first/0", status: .done("installed")),
            .itemStatus(itemID: "first/1", status: .alreadyDone("already there")),
            .stepStatus(stepID: "first", status: .done),
            .stepStatus(stepID: "second", status: .running),
            .itemStatus(itemID: "second/0", status: .running),
            .log(LogLine("✗ gamma: kaboom", style: .error, itemID: "second/0")),
            .itemStatus(itemID: "second/0", status: .failed("kaboom")),
            .attention(itemID: "second/1", attention: Attention(title: "Waiting on you", message: "Enter the code on github.com", code: "ABCD-1234", url: URL(string: "https://github.com/login/device"))),
            .itemStatus(itemID: "second/1", status: .needsAttention("click the button")),
            .runFinished(summary),
        ]
        for event in events { renderer.handle(event) }
        XCTAssertEqual(out.text, """
        ▶ 4 items in 2 steps

        == [1/2] First Things · the basics ==
          → alpha
            $ brew install alpha
            │ ==> Pouring alpha
          ✓ alpha: installed
          · beta: already done (already there)

        == [2/2] Second ==
          → gamma
          ✗ gamma: kaboom

          ╭─ Waiting on you ────────────────╮
          │ Enter the code on github.com    │
          │ code: ABCD-1234                 │
          │ https://github.com/login/device │
          ╰─────────────────────────────────╯
          ! delta: click the button

        == Summary ==
          1 done · 1 already done · 1 needs you · 1 failed  (1m 15s)

        Failed:
          ✗ gamma: kaboom
          Fix what the messages say, then run it again: finished items are skipped.

        Things only you can do:
          ☐ Sign in to the thing  https://example.com
            It's in the menu bar

        "Ugh. That one didn't work."

        """.replacingOccurrences(of: "Ugh. That one didn't work.", with: FunConfig.fallback.line(for: .finishedWithFailures, seed: 0)))
        XCTAssertFalse(out.text.contains("\u{1B}"), "no escapes when not a terminal")
        XCTAssertFalse(out.text.contains("50%"), "progress frames are not logged line by line")
    }

    func testTerminalOutputRewritesTheLiveLine() throws {
        let plan = try plan()
        let out = BufferOutput()
        var terminal = Terminal.plain(width: 60)
        terminal.stdoutIsTTY = true
        let renderer = InstallRenderer(plan: plan, selection: .defaults(for: plan), fun: .fallback, terminal: terminal, out: out, desktop: nil, seed: 0)
        renderer.handle(.itemStatus(itemID: "first/0", status: .checking))
        renderer.handle(.log(LogLine("10%", style: .stdout, itemID: "first/0", isProgress: true)))
        renderer.handle(.itemStatus(itemID: "first/0", status: .done(nil)))
        XCTAssertEqual(out.text, "\r\u{1B}[2K  ⋯ checking alpha\r\u{1B}[2K    10%\r\u{1B}[2K  ✓ alpha\n")

        // Output under a running item keeps its "→ title" line above it; a quiet item's status replaces it.
        let streamed = BufferOutput()
        let second = InstallRenderer(plan: plan, selection: .defaults(for: plan), fun: .fallback, terminal: terminal, out: streamed, desktop: nil, seed: 0)
        second.handle(.itemStatus(itemID: "first/0", status: .running))
        second.handle(.log(LogLine("==> Pouring", style: .stdout, itemID: "first/0")))
        second.handle(.itemStatus(itemID: "first/0", status: .done(nil)))
        second.handle(.itemStatus(itemID: "first/1", status: .running))
        second.handle(.itemStatus(itemID: "first/1", status: .done(nil)))
        XCTAssertEqual(streamed.text, "\r\u{1B}[2K  → alpha\r\u{1B}[2K  → alpha\n    │ ==> Pouring\n  ✓ alpha\n\r\u{1B}[2K  → beta\r\u{1B}[2K  ✓ beta\n")
    }

    func testAStopIsShownAsAStopNotAFailure() throws {
        let plan = try plan()
        let out = BufferOutput()
        let renderer = InstallRenderer(plan: plan, selection: .defaults(for: plan), fun: .fallback, terminal: .plain(), out: out, desktop: nil, seed: 0)
        var summary = InstallSummary()
        summary.done = 1
        summary.wasCancelled = true
        for event: InstallEvent in [
            .stepStatus(stepID: "first", status: .running),
            .itemStatus(itemID: "first/0", status: .done(nil)),
            .itemStatus(itemID: "first/1", status: .alreadyDone(nil)),
            .stepStatus(stepID: "first", status: .done),
            .stepStatus(stepID: "second", status: .running),
            .itemStatus(itemID: "second/0", status: .running),
            .itemStatus(itemID: "second/0", status: .cancelled),
            .stepStatus(stepID: "second", status: .stopped),
            .runFinished(summary),
        ] { renderer.handle(event) }
        let text = out.text
        XCTAssertTrue(text.contains("  → gamma\n  ■ gamma: stopped before it finished\n  ■ Second stopped: 1 item did not get its turn\n"), text)
        XCTAssertTrue(text.contains("1 done · 0 already done · 0 failed"), text)
        XCTAssertFalse(text.contains("Failed:"), "a stop is not a failure")
        XCTAssertTrue(text.contains("Cancelled before the end. Run it again to pick up where it stopped."), text)
    }

    func testAttentionCopiesTheCodeAndOpensTheURLOnce() throws {
        final class Desktop: DesktopActions, @unchecked Sendable {
            var opened: [URL] = []
            var copied: [String] = []
            func open(_ url: URL) { opened.append(url) }
            func copy(_ text: String) { copied.append(text) }
        }
        let plan = try plan()
        let desktop = Desktop()
        let renderer = InstallRenderer(plan: plan, selection: .defaults(for: plan), fun: .fallback, terminal: .plain(), out: BufferOutput(), desktop: desktop)
        let attention = Attention(title: "Code", message: "m", code: "WXYZ", url: URL(string: "https://github.com/login/device"))
        renderer.handle(.attention(itemID: "second/1", attention: attention))
        renderer.handle(.attention(itemID: "second/1", attention: attention))
        XCTAssertEqual(desktop.copied, ["WXYZ"])
        XCTAssertEqual(desktop.opened.count, 1)
    }
}

final class InstallCommandTests: XCTestCase {
    private func harness(steps: [String: String], interaction: ScriptedInteraction? = nil, log: FakeAction.Log = FakeAction.Log()) -> Harness {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: steps)
        return Harness(sandbox: sandbox, registry: FakeKinds.registry(log: log), config: config) { services in
            if let interaction { services.interaction = { _ in interaction } }
        }
    }

    private let steps = [
        "01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - ok: one\n  - present: two\n",
        "02-b.yaml": "id: b\ntitle: Beta\nitems:\n  - ok: three\n  - ok: four\n    optional: true\n",
        "03-c.yaml": "id: c\ntitle: Gamma\nenabled: false\nitems:\n  - ok: five\n",
    ]

    func testDryRunTranscript() async {
        let log = FakeAction.Log()
        let harness = harness(steps: steps, log: log)
        let code = await harness.run(["--no-update", "install", "--dry-run", "--no-remote"])
        XCTAssertEqual(code, 0, harness.err.plain)
        XCTAssertEqual(log.all, ["run:one:dryRun=true", "run:three:dryRun=true"], "defaults: optional items and disabled steps stay off")
        let text = harness.out.plain
        XCTAssertTrue(text.hasPrefix("▶ 3 items in 2 steps\n✦ Dry run: nothing on this Mac will be changed.\n\n== [1/2] Alpha ==\n"), text)
        XCTAssertTrue(text.contains("    [dry-run] $ echo installing one\n"), text)
        XCTAssertTrue(text.contains("  · two: already done (already there)\n"))
        XCTAssertTrue(text.contains("== Summary (dry run: nothing was changed) =="))
        XCTAssertTrue(text.contains("2 done · 1 already done · 0 failed"))
    }

    func testOnlySkipAndFresh() async {
        let log = FakeAction.Log()
        let harness = harness(steps: steps, log: log)
        let code = await harness.run(["--no-update", "install", "--dry-run", "--only", "a,c", "--skip", "a", "--fresh"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(log.all, ["run:five:dryRun=true"])

        let fresh = self.harness(steps: steps, log: FakeAction.Log())
        _ = await fresh.run(["--no-update", "install", "-n", "--only", "a", "--fresh"])
        XCTAssertTrue(fresh.out.plain.contains("✓ two"), "--fresh runs items that are already done")

        let typo = self.harness(steps: steps)
        let typoCode = await typo.run(["--no-update", "install", "--dry-run", "--only", "alpah"])
        XCTAssertEqual(typoCode, 64)
        XCTAssertTrue(typo.err.plain.contains("there is no step 'alpah'"), typo.err.plain)
    }

    func testRefusesToChangeTheMacWithoutATerminalOrYes() async {
        let log = FakeAction.Log()
        let harness = harness(steps: steps, log: log)
        let code = await harness.run(["--no-update", "install"])
        XCTAssertEqual(code, 64)
        XCTAssertTrue(harness.err.plain.contains("Add --yes to go ahead"))
        XCTAssertEqual(log.all, [])
    }

    func testYesRunsAndExitStatusReflectsFailures() async {
        let log = FakeAction.Log()
        let ok = harness(steps: steps, log: log)
        let code = await ok.run(["--no-update", "install", "--yes"])
        XCTAssertEqual(code, 0, ok.err.plain + ok.out.plain)
        XCTAssertEqual(log.all, ["run:one:dryRun=false", "run:three:dryRun=false"])

        let failing = harness(steps: ["01-x.yaml": "id: x\ntitle: X\nitems:\n  - boom: nope\n  - ok: after\n"])
        let failingCode = await failing.run(["--no-update", "install", "--yes"])
        XCTAssertEqual(failingCode, 1)
        XCTAssertTrue(failing.out.plain.contains("✗ nope: kaboom. Try again later"), failing.out.plain)
        XCTAssertTrue(failing.out.plain.contains("✓ after"), "one failure never stops the run")
    }

    func testPasswordIsOnlyAskedWhenTheEngineNeedsIt() async {
        let steps = ["01-x.yaml": "id: x\ntitle: X\nitems:\n  - root: admin-thing\n"]
        let dry = ScriptedInteraction()
        _ = await harness(steps: steps, interaction: dry).run(["--no-update", "install", "--dry-run"])
        XCTAssertEqual(dry.passwordRequests, 0, "a dry run never asks")

        let plain = ScriptedInteraction()
        _ = await harness(steps: ["01-x.yaml": "id: x\ntitle: X\nitems:\n  - ok: thing\n"], interaction: plain).run(["--no-update", "install", "--yes"])
        XCTAssertEqual(plain.passwordRequests, 0, "nothing needs admin rights: nothing is asked")

        let needed = ScriptedInteraction()
        let harness = harness(steps: steps, interaction: needed)
        let code = await harness.run(["--no-update", "install", "--yes"])
        XCTAssertGreaterThanOrEqual(needed.passwordRequests, 1)
        XCTAssertEqual(code, 1, "declining the password fails the item that needs it")
        XCTAssertTrue(harness.out.plain.contains("Continuing without administrator rights"), harness.out.plain)
    }

    func testCtrlCDecision() {
        XCTAssertEqual(InterruptHandler.action(press: 1), .cancelRun)
        XCTAssertEqual(InterruptHandler.action(press: 2), .quit)
        XCTAssertEqual(InterruptHandler.action(press: 3), .quit)
    }

    func testCtrlCWhileRunningCancelsThenQuits() {
        let err = BufferOutput()
        let events = Recorder<String>()
        let handler = InterruptHandler(err: err, style: .off, prompts: PromptScope(), cancel: { events.add("cancel") }, quit: { events.add("quit \($0)") })
        handler.handle()
        XCTAssertEqual(events.all, ["cancel"])
        XCTAssertTrue(err.plain.contains("■ stopping: cancelling the item in progress, then the summary… (Ctrl-C again to quit now)"), err.plain)
        handler.handle()
        XCTAssertEqual(events.all, ["cancel", "quit 130"])
    }

    /// A read from the terminal that nobody answers must end when the run is stopped, also when it was asked
    /// from a task the run's cancellation does not reach (the administrator password: `SudoSession` asks it from
    /// a task of its own). Before, only cancelling the task that waits for the read ended it: the first Ctrl-C at
    /// the install password prompt left the prompt waiting, and the run stuck, until Return or a second Ctrl-C.
    func testCtrlCAtAPromptWithdrawsThePromptAndStopsTheRun() async throws {
        var pipeEnds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(pipeEnds[0]); close(pipeEnds[1]); close(devNull) }
        let input = pipeEnds[0]

        let scope = PromptScope()
        let started = Recorder<Task<String?, Never>>()
        let run = Task {
            await PromptScope.$current.withValue(scope) {
                // Like SudoSession.ensureReady: the prompt is asked from an unstructured task of its own.
                let prompt = Task {
                    await TerminalInteraction.read(prompt: "Password: ", secret: true) { text, secret, cancellation in
                        TTY.readLine(prompt: text, secret: secret, input: input, output: devNull, cancellation: cancellation)
                    }
                }
                started.add(prompt)
                return await prompt.value
            }
        }
        for _ in 0..<400 where !TTY.isPrompting { usleep(5_000) }
        XCTAssertTrue(TTY.isPrompting, "a prompt is open while the read waits")

        let events = Recorder<String>()
        let handler = InterruptHandler(err: BufferOutput(), style: .off, prompts: scope,
                                       cancel: { events.add("cancel"); run.cancel() }, quit: { events.add("quit \($0)") })
        let pressed = Date()
        handler.handle()
        XCTAssertEqual(events.all, ["cancel"], "the first Ctrl-C stops the run; it does not have to quit")
        XCTAssertFalse(try XCTUnwrap(started.all.first).isCancelled, "the prompt's own task is not one the run's cancellation reaches")

        // Bounded, so a prompt that is not withdrawn fails the test instead of hanging it.
        for _ in 0..<600 where TTY.isPrompting { usleep(5_000) }
        let stillOpen = TTY.isPrompting
        if stillOpen { _ = "\n".withCString { write(pipeEnds[1], $0, 1) } }
        let answer = await run.value
        XCTAssertFalse(stillOpen, "the prompt was withdrawn without anybody pressing Return")
        XCTAssertNil(answer, "a withdrawn prompt has no answer")
        XCTAssertLessThan(Date().timeIntervalSince(pressed), 3, "the read ends promptly, not when somebody presses Return")

        // The next line typed belongs to the next prompt, not to the withdrawn one.
        _ = "next\n".withCString { write(pipeEnds[1], $0, 5) }
        XCTAssertEqual(TTY.readLine(prompt: "", secret: false, input: input, output: devNull), "next")
    }

    /// After the first Ctrl-C the run opens no new prompt: the password asked again after a wrong one, or by an
    /// item that was being checked when Ctrl-C came, ends at once, unseen, instead of holding the run.
    func testAPromptOpenedAfterTheRunWasStoppedIsNotShown() async {
        var pipeEnds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        var shown: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&shown), 0)
        defer { for end in pipeEnds + shown { close(end) } }
        let input = pipeEnds[0], output = shown[1]

        let scope = PromptScope()
        InterruptHandler(err: BufferOutput(), style: .off, prompts: scope, cancel: {}, quit: { _ in }).handle()
        let later = Task {
            await PromptScope.$current.withValue(scope) {
                await Task {
                    await TerminalInteraction.read(prompt: "Password: ", secret: true) { text, secret, cancellation in
                        TTY.readLine(prompt: text, secret: secret, input: input, output: output, cancellation: cancellation)
                    }
                }.value
            }
        }
        // Bounded, so a prompt that is shown anyway fails the test instead of hanging it.
        usleep(300_000)
        let stillOpen = TTY.isPrompting
        if stillOpen { _ = "\n".withCString { write(pipeEnds[1], $0, 1) } }
        let answer = await later.value
        XCTAssertFalse(stillOpen, "the prompt ended without waiting for an answer")
        XCTAssertNil(answer)
        XCTAssertEqual(TTY.waitForInput(shown[0], milliseconds: 50), .nothingYet, "no prompt was written")
        XCTAssertFalse(TTY.isPrompting)

        // A prompt outside that run is not affected.
        _ = "yes\n".withCString { write(pipeEnds[1], $0, 4) }
        let other = await TerminalInteraction.read(prompt: "? ", secret: false) { text, secret, cancellation in
            TTY.readLine(prompt: text, secret: secret, input: input, output: output, cancellation: cancellation)
        }
        XCTAssertEqual(other, "yes")
    }

    /// The first Ctrl-C does not turn echo back on while a password read is still open (what is typed next would
    /// show on screen); the read puts it back when it ends. A second Ctrl-C puts it back before quitting.
    func testCtrlCLeavesEchoOffWhileThePasswordIsReadAndRestoresItBeforeQuitting() throws {
        let terminal = try PseudoTerminal()
        let slave = terminal.slave
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            // A read the run cannot withdraw, so that it is still open at both presses.
            _ = TTY.readLine(prompt: "Password: ", secret: true, input: slave, output: slave)
            finished.signal()
        }
        for _ in 0..<400 where !TTY.isPrompting { usleep(5_000) }
        XCTAssertTrue(TTY.isPrompting)
        XCTAssertFalse(terminal.echo, "echo is off while the password is asked")

        let echoAtQuit = Recorder<Bool>()
        let handler = InterruptHandler(err: BufferOutput(), style: .off, prompts: PromptScope(), cancel: {}, quit: { _ in echoAtQuit.add(terminal.echo) })
        handler.handle()
        XCTAssertFalse(terminal.echo, "the first Ctrl-C leaves echo off")
        handler.handle()
        XCTAssertEqual(echoAtQuit.all, [true], "echo is back on by the time shawn quits")

        terminal.type("\n")
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    // MARK: Ctrl-C at the password prompt of a real `shawn install`

    /// Asks for the password as `TerminalInteraction.requestAdminPassword` does, on the given descriptors instead of /dev/tty.
    final class DescriptorInteraction: UserInteraction, @unchecked Sendable {
        let input: Int32
        let output: Int32

        init(input: Int32, output: Int32) {
            self.input = input
            self.output = output
        }

        func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
            let input = self.input, output = self.output
            guard let answer = await TerminalInteraction.read(prompt: "Password: ", secret: true, reader: { text, secret, cancellation in
                TTY.readLine(prompt: text, secret: secret, input: input, output: output, cancellation: cancellation)
            }), !answer.isEmpty else { return nil }
            return answer
        }

        func ask(_ question: Question) async -> String { question.defaultOptionID }
    }

    struct InterruptedInstall {
        var code: Int32
        var harness: Harness
        var log: FakeAction.Log
        /// The password prompt ended after the Ctrl-C without anybody pressing Return.
        var withdrawn: Bool
    }

    /// `shawn install --yes` in a terminal, with an item that needs administrator rights, and one real Ctrl-C (a
    /// SIGINT to this test process) once the up-front password prompt is open. `beforeCtrlC` and `afterCtrlC` look
    /// on; `pressReturn` ends a prompt that was not withdrawn (an empty answer: no password is ever handed to
    /// anything, and sudo is a fake).
    private func installInterruptedAtThePasswordPrompt(input: Int32, output: Int32, pressReturn: () -> Void,
                                                       beforeCtrlC: () -> Void = {}, afterCtrlC: () -> Void = {}) async -> InterruptedInstall {
        var safety = sigaction()
        safety.__sigaction_u.__sa_handler = { _ in }
        var original = sigaction()
        sigaction(SIGINT, &safety, &original)
        defer { sigaction(SIGINT, &original, nil) }

        var sandbox = Sandbox()
        sandbox.environment.sudoPath = sandbox.shim("sudo", "exit 1").path
        let log = FakeAction.Log()
        let config = makeConfig(in: sandbox.directory, steps: ["01-x.yaml": "id: x\ntitle: X\nitems:\n  - root: admin-thing\n  - ok: after\n"])
        let interaction = DescriptorInteraction(input: input, output: output)
        let harness = Harness(sandbox: sandbox, registry: FakeKinds.registry(log: log), config: config) { services in
            services.interaction = { _ in interaction }
        }
        // In a terminal, so install catches Ctrl-C and may ask.
        harness.context.terminal.stdinIsTTY = true
        let run = Task { await harness.run(["--no-update", "install", "--yes", "--no-remote"]) }
        for _ in 0..<400 where !TTY.isPrompting { usleep(5_000) }
        XCTAssertTrue(TTY.isPrompting, "the up-front password prompt is open")
        usleep(100_000)
        beforeCtrlC()
        kill(getpid(), SIGINT)
        afterCtrlC()

        var withdrawn = false
        for _ in 0..<600 {
            if !TTY.isPrompting { withdrawn = true; break }
            usleep(5_000)
        }
        if !withdrawn { pressReturn() }
        let code = await run.value
        return InterruptedInstall(code: code, harness: harness, log: log, withdrawn: withdrawn)
    }

    func testFirstCtrlCAtTheInstallPasswordPromptWithdrawsItAndPrintsTheSummary() async {
        var pipeEnds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(pipeEnds[0]); close(pipeEnds[1]); close(devNull) }
        let writer = pipeEnds[1]

        let result = await installInterruptedAtThePasswordPrompt(input: pipeEnds[0], output: devNull,
                                                                 pressReturn: { _ = "\n".withCString { write(writer, $0, 1) } })
        XCTAssertTrue(result.withdrawn, "the first Ctrl-C withdraws the password prompt; the run does not wait for Return or a second Ctrl-C")
        XCTAssertEqual(result.code, ExitCode.interrupted)
        XCTAssertEqual(result.log.all, [], "nothing ran after the Ctrl-C")
        let err = result.harness.err.plain, out = result.harness.out.plain
        XCTAssertTrue(err.contains("■ stopping: cancelling the item in progress, then the summary… (Ctrl-C again to quit now)"), err)
        XCTAssertFalse(out.contains("Continuing without administrator rights"), "a stopped run is not told its steps will fail: \(out)")
        XCTAssertTrue(out.contains("== Summary =="), out)
        XCTAssertTrue(out.contains("Cancelled before the end. Run it again to pick up where it stopped."), out)
    }

    /// Before, the first Ctrl-C turned echo back on while the password prompt went on waiting, so a password
    /// typed next was shown on screen (and then checked with sudo).
    func testPasswordTypedAfterTheFirstCtrlCIsNotEchoed() async throws {
        let terminal = try PseudoTerminal()
        var echoBeforeCtrlC = true
        var echoedWhileStillAsking = true
        let result = await installInterruptedAtThePasswordPrompt(
            input: terminal.slave, output: terminal.slave, pressReturn: { terminal.type("\n") },
            beforeCtrlC: { echoBeforeCtrlC = terminal.echo },
            afterCtrlC: {
                // Well past the moment the withdrawn read ends (it looks every 100 ms).
                usleep(500_000)
                echoedWhileStillAsking = terminal.echo && TTY.isPrompting
            })
        XCTAssertFalse(echoBeforeCtrlC, "echo is off while the password is asked")
        XCTAssertFalse(echoedWhileStillAsking, "after the first Ctrl-C the password prompt still waits for input with echo back on")
        XCTAssertTrue(result.withdrawn, "the password prompt does not stay open after the first Ctrl-C")
        XCTAssertTrue(terminal.echo, "the withdrawn prompt put echo back")
        XCTAssertEqual(result.code, ExitCode.interrupted)
    }

    func testACancellableReadStillReadsALine() async {
        var pipeEnds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        let devNull = open("/dev/null", O_WRONLY)
        defer { close(pipeEnds[0]); close(pipeEnds[1]); close(devNull) }
        let input = pipeEnds[0], output = pipeEnds[1]
        let prompt = Task {
            await TerminalInteraction.read(prompt: "Choose 1-2: ", secret: false) { text, secret, cancellation in
                TTY.readLine(prompt: text, secret: secret, input: input, output: devNull, cancellation: cancellation)
            }
        }
        // Longer than one polling slice, so the read has gone round its wait at least once.
        usleep(useconds_t(TTY.cancellationPollMilliseconds) * 2_500)
        _ = "2\nleft for later\n".withCString { write(output, $0, 17) }
        let answer = await prompt.value
        XCTAssertEqual(answer, "2")
        XCTAssertEqual(TTY.readLine(prompt: "", secret: false, input: input, output: devNull), "left for later", "only one line is taken")
    }

    func testAReadCancelledBeforeItStartsShowsNothing() {
        var pipeEnds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        var shown: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&shown), 0)
        defer { for end in pipeEnds + shown { close(end) } }
        let cancellation = TTY.Cancellation()
        cancellation.cancel()
        XCTAssertNil(TTY.readLine(prompt: "Password: ", secret: false, input: pipeEnds[0], output: shown[1], cancellation: cancellation))
        XCTAssertEqual(TTY.waitForInput(shown[0], milliseconds: 50), .nothingYet, "no prompt was written")
        XCTAssertFalse(TTY.isPrompting)
    }

    func testWaitForInputReportsWaitingBytesAndEndOfInput() {
        var pipeEnds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeEnds), 0)
        defer { close(pipeEnds[0]) }
        XCTAssertEqual(TTY.waitForInput(pipeEnds[0], milliseconds: 20), .nothingYet)
        _ = "x".withCString { write(pipeEnds[1], $0, 1) }
        XCTAssertEqual(TTY.waitForInput(pipeEnds[0], milliseconds: 20), .ready)
        var byte: UInt8 = 0
        XCTAssertEqual(read(pipeEnds[0], &byte, 1), 1)
        close(pipeEnds[1])
        XCTAssertEqual(TTY.waitForInput(pipeEnds[0], milliseconds: 20), .ready, "end of input is something to read")
        XCTAssertEqual(TTY.waitForInput(-1, milliseconds: 20), .unknown)
        XCTAssertEqual(TTY.waitForInput(5000, milliseconds: 20), .unknown, "beyond what select can watch")
    }

    func testNonInteractiveRunsNeverPrompt() {
        let options = TerminalInteraction.Options(assumeYes: true, allowPrompts: false)
        let interaction = TerminalInteraction(options: options, style: .off)
        let question = Question(title: "Sign in", message: "m", options: [.init(id: "skip", label: "Skip"), .init(id: "ok", label: "OK", isDefault: true)])
        let expectation = expectation(description: "answers")
        Task {
            let password = await interaction.requestAdminPassword(reason: "r", attempt: 1, lastError: nil)
            let answer = await interaction.ask(question)
            XCTAssertNil(password)
            XCTAssertEqual(answer, "ok")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}

final class DoctorTests: XCTestCase {
    func testReportsItemsAndEnvironment() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: [
            "01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - present: done-thing\n  - ok: missing-thing\n  - ok: optional-thing\n    optional: true\n",
        ])
        let harness = Harness(sandbox: sandbox, config: config) { $0.git = SystemGitClient(launcher: SystemProcessLauncher(), environment: sandbox.environment) }
        let code = await harness.run(["--no-update", "doctor"])
        XCTAssertEqual(code, 1)
        let text = harness.out.plain
        XCTAssertTrue(text.contains("  ✗ Alpha                       1/2\n      · missing-thing (ok)\n"), text)
        XCTAssertFalse(text.contains("optional-thing"), "items that are off by default are not missing")
        XCTAssertTrue(text.contains("✗ Homebrew"), text)
        XCTAssertTrue(text.contains("✗ git identity"), text)
        XCTAssertTrue(text.contains("✗ GitHub CLI      gh is not installed"), text)
        XCTAssertTrue(text.contains("✗ SSH key"), text)
        XCTAssertTrue(text.contains("✗ PATH            ~/.local/bin is missing"), text)
        XCTAssertTrue(text.contains("6 things to fix."), text)
    }

    func testAllGood() async {
        var sandbox = Sandbox()
        sandbox.environment.baseEnvironment["PATH"] = "\(sandbox.bin.path):$HOME/.local/bin:/usr/bin:/bin"
        let config = makeConfig(in: sandbox.directory, steps: ["01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - present: done-thing\n"])
        let brew = sandbox.environment.brewPrefix.appendingPathComponent("bin/brew")
        try! FileManager.default.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: brew)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        sandbox.shim("gh", #"[ "$1 $2" = "auth status" ] && exit 0; exit 1"#)
        sandbox.directory.write("home/.gitconfig", "[user]\n  name = Lumpy Space\n  email = lsp@example.com\n")
        sandbox.directory.write("home/.ssh/id_ed25519.pub", "ssh-ed25519 AAAA lsp@example.com\n")
        let harness = Harness(sandbox: sandbox, config: config) { $0.git = SystemGitClient(launcher: SystemProcessLauncher(), environment: sandbox.environment) }
        harness.context.services.launcher = SystemProcessLauncher()
        let code = await harness.run(["--no-update", "doctor"])
        XCTAssertEqual(code, 0, harness.out.plain)
        XCTAssertTrue(harness.out.plain.contains("✓ git identity    Lumpy Space <lsp@example.com>"), harness.out.plain)
        XCTAssertTrue(harness.out.plain.contains("All good."))
    }
}

extension DoctorTests {
    /// Opening an app or a reminder without a check can never say "already done": doctor lists them
    /// under their own heading and still passes on a Mac where everything that can be checked is in place.
    func testItemsThatCannotBeCheckedNeverCountAsMissing() async {
        var sandbox = Sandbox()
        sandbox.environment.baseEnvironment["PATH"] = "\(sandbox.bin.path):$HOME/.local/bin:/usr/bin:/bin"
        let config = makeConfig(in: sandbox.directory, steps: [
            "01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - present: done-thing\n  - reminder: Open Karabiner-Elements\n",
            "02-finish.yaml": "id: finish\ntitle: Finishing Up\nitems:\n  - reminder: Log out and back in\n  - reminder: Off by default\n    optional: true\n",
        ])
        let brew = sandbox.environment.brewPrefix.appendingPathComponent("bin/brew")
        try! FileManager.default.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: brew)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        sandbox.shim("gh", #"[ "$1 $2" = "auth status" ] && exit 0; exit 1"#)
        sandbox.directory.write("home/.gitconfig", "[user]\n  name = Lumpy Space\n  email = lsp@example.com\n")
        sandbox.directory.write("home/.ssh/id_ed25519.pub", "ssh-ed25519 AAAA lsp@example.com\n")
        let harness = Harness(sandbox: sandbox, config: config) { $0.git = SystemGitClient(launcher: SystemProcessLauncher(), environment: sandbox.environment) }
        harness.context.services.launcher = SystemProcessLauncher()
        let code = await harness.run(["--no-update", "doctor"])
        let text = harness.out.plain
        XCTAssertEqual(code, 0, text)
        XCTAssertTrue(text.contains("  ✓ Alpha                       1/1 · 1 can't be checked\n"), text)
        XCTAssertTrue(text.contains("  · Finishing Up                1 can't be checked\n"), text)
        XCTAssertTrue(text.contains("Can't be checked (2) · nothing can tell whether these are done, so they never count as missing\n"
                                    + "  · Open Karabiner-Elements (reminder) · Alpha\n  · Log out and back in (reminder) · Finishing Up\n"), text)
        XCTAssertFalse(text.contains("Off by default"), "optional items stay out")
        XCTAssertTrue(text.contains("All good."), text)
    }
}

/// `shawn doctor`, `drift` and `config` load the whole plan from disk through `PlanLoader`.
final class PlanLoaderTests: XCTestCase {
    private let goodStep = ["01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - present: done-thing\n"]
    /// A snapshot written for a different build: a kind this build does not know.
    private let staleStep = ["01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - teleport: somewhere\n"]

    /// Before: the config the self-updater fetched from GitHub was handed to the resolver as if somebody
    /// had named it, so one that no longer loads made `shawn doctor` fail although the copy the installer
    /// left in ~/.shawn/config was fine.
    func testAFetchedConfigThatDoesNotLoadFallsBackToTheInstalledCopy() {
        let sandbox = Sandbox()
        let fetched = makeConfig(in: sandbox.directory, at: "home/Library/Caches/ShawnsDotfiles/config", steps: staleStep)
        makeConfig(in: sandbox.directory, at: "home/.shawn/config", steps: goodStep)
        let harness = Harness(sandbox: sandbox)
        var state = harness.context.stateStore.load()
        state.remoteConfigRoot = fetched.path
        harness.context.stateStore.save(state)
        XCTAssertEqual(harness.context.configLocation()?.url.path, fetched.path, "the fetched config is the one the CLI uses")

        guard case .success(let resolved) = PlanLoader.local(context: harness.context) else {
            return XCTFail("expected the installed copy to be used: \(harness.err.plain)")
        }
        XCTAssertEqual(resolved.config.root.path, sandbox.home.appendingPathComponent(".shawn/config").path)
        XCTAssertEqual(resolved.plan.allItems.map(\.title), ["done-thing"])
        XCTAssertTrue(harness.err.plain.contains("Skipped the config at ~/Library/Caches/ShawnsDotfiles/config. It does not load with this shawn"), harness.err.plain)
        XCTAssertTrue(harness.err.plain.contains("teleport"), "the note says what is wrong: \(harness.err.plain)")
        XCTAssertTrue(harness.err.plain.contains("Using ~/.shawn/config instead."), harness.err.plain)
    }

    func testAnInstalledCopyThatDoesNotLoadIsAnErrorThatSaysHowToReplaceIt() {
        let sandbox = Sandbox()
        makeConfig(in: sandbox.directory, at: "home/.shawn/config", steps: staleStep)
        let harness = Harness(sandbox: sandbox)
        guard case .failure(let error) = PlanLoader.local(context: harness.context) else { return XCTFail("a config that does not load must not be used") }
        XCTAssertTrue(error.description.contains("teleport"), error.description)
        XCTAssertTrue(error.description.contains("the copy a previous install left"), error.description)
        XCTAssertTrue(error.description.contains("Run the latest Shawn's Dotfiles installer to replace it"), error.description)
        XCTAssertEqual(harness.err.plain, "", "nothing was skipped in favour of something else, so there is no note")
    }

    /// The checkout (or $SHAWN_CONFIG_DIR) is what the user edits: its mistakes are reported, never papered
    /// over by an older copy that happens to load.
    func testAWorkingCopyThatDoesNotLoadIsNeverSkipped() {
        let sandbox = Sandbox()
        let working = makeConfig(in: sandbox.directory, at: "checkout/config", steps: staleStep)
        makeConfig(in: sandbox.directory, at: "home/.shawn/config", steps: goodStep)
        let harness = Harness(sandbox: sandbox, config: working)
        guard case .failure(let error) = PlanLoader.local(context: harness.context) else { return XCTFail("the working copy's problems must be reported") }
        XCTAssertTrue(error.description.contains("teleport"), error.description)
        XCTAssertTrue(error.description.contains(working.path), error.description)
        XCTAssertEqual(harness.err.plain, "")
    }

    func testANamedConfigIsUsedStrictly() {
        let sandbox = Sandbox()
        let named = makeConfig(in: sandbox.directory, at: "named", steps: staleStep)
        makeConfig(in: sandbox.directory, at: "home/.shawn/config", steps: goodStep)
        let harness = Harness(sandbox: sandbox)
        guard case .failure(let error) = PlanLoader.local(context: harness.context, directory: named) else { return XCTFail("a named config is never replaced") }
        XCTAssertTrue(error.description.contains(named.path), error.description)
        harness.context.globals.configPath = named
        guard case .failure = PlanLoader.local(context: harness.context) else { return XCTFail("--config is never replaced") }
    }

    func testDoctorStillRunsWhenTheFetchedConfigIsStale() async {
        let sandbox = Sandbox()
        let fetched = makeConfig(in: sandbox.directory, at: "home/Library/Caches/ShawnsDotfiles/config", steps: staleStep)
        makeConfig(in: sandbox.directory, at: "home/.shawn/config", steps: goodStep)
        let harness = Harness(sandbox: sandbox)
        var state = harness.context.stateStore.load()
        state.remoteConfigRoot = fetched.path
        harness.context.stateStore.save(state)
        _ = await harness.run(["--no-update", "doctor"])
        XCTAssertTrue(harness.out.plain.contains("✓ Alpha"), harness.out.plain + harness.err.plain)
        XCTAssertTrue(harness.err.plain.contains("Skipped the config at ~/Library/Caches/ShawnsDotfiles/config"), harness.err.plain)
    }
}

final class ShellIntegrationTests: XCTestCase {
    private let cli = """
    commands:
      claude:
        section: AI
        summary: "Claude: it's lumpy [really]"
        exec: [claude]
      ports:
        summary: Ports
        run: lsof -i
    """

    private func zshCheck(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let directory = TempDirectory()
        let url = directory.write("_shawn", script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try! process.run()
        process.waitUntilExit()
        let errors = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, errors, file: file, line: line)
    }

    func testCompletionsListEveryCommandAndParse() async throws {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: [:], cli: cli)
        let harness = Harness(sandbox: sandbox, config: config)
        let code = await harness.run(["completions", "zsh"])
        XCTAssertEqual(code, 0)
        let script = harness.out.text
        XCTAssertTrue(script.hasPrefix("#compdef shawn\n"))
        for name in Builtins.all.map(\.name) + ["sync", "claude", "ports"] {
            XCTAssertTrue(script.contains("    '\(name):"), "\(name) missing")
        }
        XCTAssertTrue(script.contains(#"'claude:Claude: it'\''s lumpy [really]'"#), "quotes survive")
        XCTAssertTrue(script.contains("'(-n --dry-run)'{-n,--dry-run}'[Show what would happen; change nothing]'"))
        XCTAssertTrue(script.contains("'--config[Use this config directory]:dir:_files -/'"))
        XCTAssertTrue(script.contains("        claude)\n          words[1]='claude'; _normal\n"), "wrappers hand over to the tool's own completion")
        XCTAssertTrue(script.contains("'1:action:(path show validate kinds edit brewfile)'"))
        zshCheck(script)

        // It defines a working completion function in a real zsh.
        let file = sandbox.directory.write("fpath/_shawn", script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "fpath=(\(file.deletingLastPathComponent().path) $fpath); autoload -Uz compinit; compinit -u -D; print -r -- ${_comps[shawn]}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.environment = ["HOME": sandbox.home.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "_shawn\n")
    }

    func testShellInitIsValidZshAndSideEffectFree() async throws {
        let harness = Harness()
        let code = await harness.run(["shell-init", "zsh"])
        XCTAssertEqual(code, 0)
        let script = harness.out.text
        XCTAssertTrue(script.contains("sd() {"))
        XCTAssertTrue(script.contains("shawn() {"))
        XCTAssertTrue(script.contains("SHAWN_CD_FILE"))
        zshCheck(script)
        XCTAssertTrue(harness.launcher.requests.isEmpty && harness.replacer.requests.isEmpty)

        // Sourcing it only defines functions, and the clone wrapper changes directory afterwards.
        let sandbox = Sandbox()
        let target = sandbox.home.appendingPathComponent("Developer/new-thing")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let fakeShawn = sandbox.shim("shawn", #"[ -n "$SHAWN_CD_FILE" ] && printf '%s' "$HOME/Developer/new-thing" > "$SHAWN_CD_FILE"; exit 0"#)
        let initFile = sandbox.directory.write("init.zsh", script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "source \(initFile.path); whence -w sd shawn | tr '\\n' ' '; shawn clone x/new-thing; pwd"]
        process.environment = ["HOME": sandbox.home.path, "PATH": "\(fakeShawn.deletingLastPathComponent().path):/usr/bin:/bin", "TMPDIR": sandbox.environment.temporaryDirectory.path]
        process.currentDirectoryURL = sandbox.home
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "sd: function shawn: function \(target.path)\n")
    }

    func testOnlyZshIsSupported() async {
        let harness = Harness()
        let code = await harness.run(["completions", "fish"])
        XCTAssertEqual(code, 64)
        let other = Harness()
        let otherCode = await other.run(["shell-init"])
        XCTAssertEqual(otherCode, 64)
    }
}

/// A pseudo-terminal whose screen side is drained continuously (tcsetattr with TCSAFLUSH waits for output to drain).
final class PseudoTerminal: @unchecked Sendable {
    let master: Int32
    let slave: Int32
    private let drained = DispatchSemaphore(value: 0)

    init() throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.ENXIO) }
        self.master = master
        self.slave = slave
        let drained = self.drained
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 256)
            while read(master, &buffer, buffer.count) > 0 {}
            drained.signal()
        }
    }

    deinit {
        close(slave)
        // The screen side reads until the terminal is gone; only then is it safe to close.
        _ = drained.wait(timeout: .now() + 5)
        close(master)
    }

    /// Whether the terminal shows what is typed.
    var echo: Bool {
        var settings = termios()
        tcgetattr(slave, &settings)
        return settings.c_lflag & tcflag_t(ECHO) != 0
    }

    /// Keys typed at the keyboard.
    func type(_ text: String) {
        _ = text.withCString { write(master, $0, strlen($0)) }
    }
}
