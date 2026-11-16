import XCTest
@testable import ShawnCore

final class LineBufferTests: XCTestCase {
    func testNewlinesCarriageReturnsAndChunkBoundaries() {
        var buffer = LineBuffer()
        var lines = buffer.append(Data("one\ntw".utf8))
        XCTAssertEqual(lines, [.init(text: "one", isProgress: false)])
        lines = buffer.append(Data("o\r\nthree\r".utf8))
        XCTAssertEqual(lines, [.init(text: "two", isProgress: false)], "a trailing CR waits for the next byte")
        lines = buffer.append(Data("\n10%\r50%\rdone\npartial".utf8))
        XCTAssertEqual(lines, [
            .init(text: "three", isProgress: false),
            .init(text: "10%", isProgress: true),
            .init(text: "50%", isProgress: true),
            .init(text: "done", isProgress: false),
        ])
        XCTAssertEqual(buffer.flush(), [.init(text: "partial", isProgress: false)])
        XCTAssertEqual(buffer.flush(), [])
    }

    func testMultibyteCharactersSplitAcrossChunks() {
        var buffer = LineBuffer()
        let bytes = Array("héllo ⭐\n".utf8)
        var lines: [LineBuffer.Line] = []
        for byte in bytes { lines += buffer.append(Data([byte])) }
        XCTAssertEqual(lines, [.init(text: "héllo ⭐", isProgress: false)])
    }
}

final class TextUtilityTests: XCTestCase {
    func testShellQuoting() {
        XCTAssertEqual(Shell.quote("plain-arg_1.0"), "plain-arg_1.0")
        XCTAssertEqual(Shell.quote("two words"), "'two words'")
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(Shell.quote(""), "''")
        XCTAssertEqual(Shell.join(["brew", "install", "a b"]), "brew install 'a b'")
    }

    func testANSIStripping() {
        XCTAssertEqual(ANSI.strip("\u{1B}[1;32m==>\u{1B}[0m Pouring"), "==> Pouring")
        XCTAssertEqual(ANSI.strip("\u{1B}]8;;https://x.com\u{07}link\u{1B}]8;;\u{07}"), "link")
        XCTAssertEqual(ANSI.strip("no escapes"), "no escapes")
        XCTAssertEqual(ANSI.strip("\u{1B}[2K\u{1B}[1Gprogress"), "progress")
    }
}

final class ProcessRunnerTests: XCTestCase {
    private let environment = ["PATH": "/usr/bin:/bin"]

    func testCapturesOutputAndExitCode() async throws {
        let output = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], environment: environment)
        XCTAssertEqual(output.exitCode, 3)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "err\n")
        XCTAssertNil(output.terminationSignal)
    }

    func testEnvironmentWorkingDirectoryAndStdin() async throws {
        let directory = TempDirectory()
        let output = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "pwd -P; echo $GREETING; cat"],
            environment: environment.merging(["GREETING": "oh my glob"]) { $1 },
            currentDirectory: directory.url.path, stdin: Data("from stdin".utf8))
        let lines = String(decoding: output.stdout, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasSuffix("/" + directory.url.lastPathComponent), lines[0])
        XCTAssertEqual(lines[1], "oh my glob")
        XCTAssertEqual(lines[2], "from stdin")
    }

    func testStdinIsDevNullByDefault() async throws {
        // `cat` would hang forever on an inherited terminal; with /dev/null it returns at once.
        let output = try await ProcessRunner.run(executable: "/bin/cat", arguments: [], environment: environment, timeout: 10)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.stdout.isEmpty)
    }

    func testLargeOutputIsNotLostOrDeadlocked() async throws {
        let chunks = Recorder<Int>()
        let output = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' 'x'; head -c 100000 /dev/zero | tr '\\0' 'e' >&2"],
            environment: environment, onChunk: { _, data in chunks.add(data.count) })
        XCTAssertEqual(output.stdout.count, 3_000_000)
        XCTAssertEqual(output.stderr.count, 100_000)
        XCTAssertEqual(chunks.all.reduce(0, +), 3_100_000)
    }

    func testSpawnFailureIsReported() async {
        do {
            _ = try await ProcessRunner.run(executable: "/no/such/binary", arguments: [], environment: environment)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("/no/such/binary"), "\(error)")
        }
    }

    func testSignalTerminationIsReported() async throws {
        let output = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "kill -9 $$"], environment: environment)
        XCTAssertEqual(output.terminationSignal, 9)
        XCTAssertEqual(output.exitCode, 137)
    }

    func testTimeoutKillsTheWholeProcessGroup() async {
        let directory = TempDirectory()
        let marker = directory.url.appendingPathComponent("survivor").path
        let started = Date()
        do {
            // The grandchild would create the marker after 3s if it survived the kill.
            _ = try await ProcessRunner.run(
                executable: "/bin/sh", arguments: ["-c", "(sleep 3; touch '\(marker)') & sleep 30"],
                environment: environment, timeout: 0.5)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not finish"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the grandchild should have been killed with its group")
    }

    func testCancellationStopsTheChild() async {
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/usr/bin:/bin"])
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testChildLeadsItsOwnSessionSoItHasNoControllingTerminal() async throws {
        let output = try await ProcessRunner.run(
            executable: "/usr/bin/python3", arguments: ["-c", "import os; print(os.getsid(0) == os.getpid(), os.getpgrp() == os.getpid())"],
            environment: environment, timeout: 20)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "True True\n")
        let terminal = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "ps -o tt= -p $$"], environment: environment, timeout: 20)
        XCTAssertEqual(String(decoding: terminal.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "??")
    }

    func testOnSpawnGetsTheChildsSessionBeforeTheChildRuns() async throws {
        let directory = TempDirectory()
        let marker = directory.url.appendingPathComponent("ran").path
        let seen = Recorder<String>()
        let output = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "touch \"$1\"; echo $$", "sh", marker],
            environment: environment, timeout: 20,
            onSpawn: { processID in
                // Long enough for an unsuspended child to have touched the marker many times over.
                usleep(300_000)
                seen.add("\(processID) ran=\(FileManager.default.fileExists(atPath: marker)) session=\(getsid(processID))")
            })
        let processID = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(seen.all, ["\(processID) ran=false session=\(processID)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "the child runs once onSpawn has returned")
    }

    func testChattyGrandchildCannotKeepTheRunWaiting() async throws {
        // The background loop inherits stdout and keeps writing for about 9 seconds after the shell has exited.
        let started = Date()
        let script = "(i=0; while [ $i -lt 300 ]; do echo tick; sleep 0.03; i=$((i+1)); done) & echo started"
        let output = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], environment: environment)
        XCTAssertEqual(output.exitCode, 0)
        // Not hasPrefix: on a busy Mac the background loop can get its first "tick" out before the shell's line.
        XCTAssertTrue(String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").contains("started"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "draining must stop at the deadline even while output keeps coming")
    }

    func testDoesNotWaitForeverOnGrandchildHoldingThePipe() async throws {
        // The background sleep inherits stdout and outlives the shell.
        let started = Date()
        let output = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "sleep 9 & echo started"], environment: environment)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "started\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "should give up draining shortly after the child exits")
    }
}

final class CommandRunnerTests: XCTestCase {
    private func makeRunner(_ directory: TempDirectory, dryRun: Bool = false, sudo: (any SudoProviding)? = nil) -> (CommandRunner, Recorder<LogLine>) {
        let recorder = Recorder<LogLine>()
        let runner = CommandRunner(environment: .testSandbox(directory), dryRun: dryRun, sudo: sudo, itemID: "step/0") { recorder.add($0) }
        return (runner, recorder)
    }

    func testStreamsLinesWithStylesAndStripsANSI() async throws {
        let directory = TempDirectory()
        let (runner, recorder) = makeRunner(directory)
        let seen = Recorder<String>()
        let result = try await runner.run(Command.shell("printf '\\033[32mgreen\\033[0m\\n'; echo oops >&2").watching { line, _ in seen.add(line) })
        XCTAssertTrue(result.succeeded)
        let lines = recorder.all
        XCTAssertEqual(lines.first?.style, .command)
        XCTAssertTrue(lines.first?.text.hasPrefix("$ ") == true)
        XCTAssertTrue(lines.contains { $0.text == "green" && $0.style == .stdout && $0.itemID == "step/0" })
        XCTAssertTrue(lines.contains { $0.text == "oops" && $0.style == .stderr })
        XCTAssertEqual(Set(seen.all), ["green", "oops"])
    }

    func testDryRunSkipsMutatingCommandsButRunsProbes() async throws {
        let directory = TempDirectory()
        let (runner, recorder) = makeRunner(directory, dryRun: true)
        let marker = directory.url.appendingPathComponent("touched").path
        let result = try await runner.run(Command("/usr/bin/touch", [marker]))
        XCTAssertTrue(result.wasDryRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        XCTAssertEqual(recorder.all.map(\.text), ["[dry-run] $ touch \(marker)"])

        let probe = await runner.capture("/bin/echo", ["still", "runs"])
        XCTAssertEqual(probe, "still runs")
        // A tool that is not installed yet must not break a dry run.
        let missing = try await runner.run(Command("definitely-not-installed-yet", ["install"]))
        XCTAssertTrue(missing.wasDryRun)
    }

    func testMissingToolAndCheckedFailure() async {
        let directory = TempDirectory()
        let (runner, _) = makeRunner(directory)
        do {
            _ = try await runner.run(Command("definitely-not-installed-yet"))
            XCTFail("expected notFound")
        } catch {
            XCTAssertTrue(String(describing: error).contains("is not installed"), "\(error)")
        }
        do {
            _ = try await runner.runChecked(Command.shell("echo first; echo 'the real reason' >&2; exit 7"))
            XCTFail("expected failure")
        } catch {
            let text = String(describing: error)
            XCTAssertTrue(text.contains("exit 7"), text)
            XCTAssertTrue(text.contains("the real reason"), text)
        }
        let quiet = await runner.capture("/usr/bin/false")
        XCTAssertNil(quiet)
        let ok = await runner.succeeds("/usr/bin/true")
        XCTAssertTrue(ok)
    }

    func testTimeoutIsReportedAgainstTheCommandNotItsWrapper() async {
        let directory = TempDirectory()
        let (runner, _) = makeRunner(directory)
        do {
            _ = try await runner.run(Command("/bin/sleep", ["30"]).labeled("gh auth login").timeout(0.3))
            XCTFail("expected a timeout")
        } catch let error as CommandError {
            XCTAssertTrue(error.isTimeout)
            XCTAssertEqual(error.description, "gh auth login did not finish within 0 seconds")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnsetEnvironmentRemovesVariables() async throws {
        let directory = TempDirectory()
        let recorder = Recorder<LogLine>()
        var environment = SystemEnvironment.testSandbox(directory)
        environment.baseEnvironment["CLAUDECODE"] = "1"
        environment.baseEnvironment["KEEP_ME"] = "yes"
        let runner = CommandRunner(environment: environment) { recorder.add($0) }
        let result = try await runner.run(Command.shell("echo ${CLAUDECODE:-gone} ${KEEP_ME:-gone}").silently().unsetting(["CLAUDECODE"]))
        XCTAssertEqual(result.output, "gone yes")
    }

    func testQuietCommandsDoNotLog() async throws {
        let directory = TempDirectory()
        let (runner, recorder) = makeRunner(directory)
        let result = try await runner.run(Command.shell("echo secret-ish").silently())
        XCTAssertEqual(result.output, "secret-ish")
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testChildEnvironmentUsesSandboxHomeAndSearchPath() async throws {
        let directory = TempDirectory()
        let (runner, _) = makeRunner(directory)
        let result = try await runner.run(Command.shell("echo $HOME; echo $PATH; echo $GIT_TERMINAL_PROMPT; echo ${SUDO_ASKPASS:-unset}").silently())
        XCTAssertEqual(result.lines[0], directory.url.appendingPathComponent("home").path)
        XCTAssertTrue(result.lines[1].contains(directory.url.appendingPathComponent("homebrew/bin").path))
        XCTAssertTrue(result.lines[1].hasSuffix("/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertEqual(result.lines[2], "0")
        XCTAssertEqual(result.lines[3], "unset")
    }

    func testDisplayString() {
        XCTAssertEqual(Command("/opt/homebrew/bin/brew", ["install", "--cask", "google chrome"]).displayString, "brew install --cask 'google chrome'")
        XCTAssertEqual(Command("softwareupdate", ["-i", "x"]).asRoot().displayString, "sudo softwareupdate -i x")
        XCTAssertEqual(Command.shell("echo one\necho two").displayString, "echo one …")
    }
}

/// Exercises the real askpass pipeline end to end, with a stand-in for the sudo binary
/// (running the real one would need this machine's administrator password).
final class SudoSessionTests: XCTestCase {
    /// A fake sudo: asks the askpass helper for the password, accepts only "open sesame",
    /// then (when given a command) runs it. It runs under zsh so that, like the real sudo, it is a
    /// different program from the bash scripts that might try to run the helper themselves.
    private func installFakeSudo(in directory: TempDirectory) -> String {
        directory.write("fake-sudo", """
        #!/bin/zsh
        log="$(dirname "$0")/sudo.log"
        echo "argv: $*" >> "$log"
        if [ -z "$SUDO_ASKPASS" ]; then echo "sudo: a terminal is required to read the password" >&2; exit 1; fi
        password="$("$SUDO_ASKPASS" "[sudo] password:")"
        if [ -z "$password" ]; then echo "sudo: no password was provided" >&2; exit 1; fi
        if [ "$password" != "open sesame" ]; then echo "Sorry, try again." >&2; echo "sudo: 1 incorrect password attempt" >&2; exit 1; fi
        validate=0
        while [ $# -gt 0 ]; do
          case "$1" in
            -A|-k) shift ;;
            -v) validate=1; shift ;;
            --) shift; break ;;
            *) break ;;
          esac
        done
        if [ "$validate" = 1 ]; then exit 0; fi
        exec "$@"

        """, permissions: 0o755).path
    }

    private final class ScriptedInteraction: UserInteraction, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String?]
        private(set) var prompts: [(attempt: Int, lastError: String?)] = []

        init(_ answers: [String?]) {
            self.answers = answers
        }

        func requestAdminPassword(reason: String, attempt: Int, lastError: String?) async -> String? {
            lock.withLock {
                prompts.append((attempt, lastError))
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }

        func ask(_ question: Question) async -> String { question.defaultOptionID }
    }

    /// Runs the helper (directly, or from `wrapper`) in a session of its own; with `server`, that session is the one allowed.
    private func runHelper(_ path: String, via wrapper: [String]? = nil, allowedBy server: AskpassServer? = nil) async throws -> String {
        let environment = ["PATH": "/usr/bin:/bin"]
        let allow: ((pid_t) -> Void)? = server.map { server in { server.allowSessions([$0]) } }
        let output: ProcessOutput
        if let wrapper {
            output = try await ProcessRunner.run(executable: wrapper[0], arguments: Array(wrapper.dropFirst()) + [path], environment: environment,
                                                 timeout: 10, onSpawn: allow)
        } else {
            output = try await ProcessRunner.run(executable: path, arguments: ["prompt"], environment: environment, timeout: 10, onSpawn: allow)
        }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    func testAskpassHelperServesThePasswordOverTheSocket() async throws {
        let directory = TempDirectory()
        let server = try AskpassServer(secret: "p@ss word'\"$x", temporaryDirectory: directory.url)
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: server.helperPath)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: server.directory.path)[.posixPermissions] as? Int, 0o700)

        let beforeArming = try await runHelper(server.helperPath)
        XCTAssertEqual(beforeArming, "", "nothing is served until a command allowed to use sudo is running")

        let first = try await runHelper(server.helperPath, allowedBy: server)
        XCTAssertEqual(first, "p@ss word'\"$x\n")
        // Some session is allowed now, but not this helper's.
        let otherSession = try await runHelper(server.helperPath)
        XCTAssertEqual(otherSession, "", "a helper outside the allowed sessions gets nothing")

        server.limitAnswers(to: 1)
        let second = try await runHelper(server.helperPath, allowedBy: server)
        XCTAssertEqual(second, "p@ss word'\"$x\n")
        let third = try await runHelper(server.helperPath, allowedBy: server)
        XCTAssertEqual(third, "", "the answer limit must be honored")

        // A session that is no longer allowed gets nothing: the wrapper's session is allowed when it starts, and
        // withdrawn before it runs the helper.
        server.limitAnswers(to: nil)
        let gate = directory.url.appendingPathComponent("gate").path
        let wrapper = ["/bin/sh", "-c", "touch \"$0.started\"; i=0; while [ ! -f \"$0\" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done; \"$1\"", gate]
        let afterRevoking = Task { try await runHelper(server.helperPath, via: wrapper, allowedBy: server) }
        try await waitFor(gate + ".started")
        server.allowSessions([])
        FileManager.default.createFile(atPath: gate, contents: nil)
        let revoked = try await afterRevoking.value
        XCTAssertEqual(revoked, "", "withdrawing a session stops the answers again")

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.directory.path), "stop() must remove the helper and socket")
    }

    func testAskpassAnswersOnlyTheHelperProgram() async throws {
        let directory = TempDirectory()
        let server = try AskpassServer(secret: "hunter2", temporaryDirectory: directory.url)
        try server.start()
        defer { server.stop() }
        server.allowSessions([getsid(0)])

        // Anything that is not the helper's own program (here: this test process, connecting directly) gets nothing.
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(server.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[0..<pathBytes.count])) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        let received = read(descriptor, &buffer, buffer.count)
        XCTAssertEqual(received, 0, "a direct connection must be closed without the secret")

        // The helper itself still works.
        let viaHelper = try await runHelper(server.helperPath, allowedBy: server)
        XCTAssertEqual(viaHelper, "hunter2\n")
    }

    func testAskpassLearnsWhoStartsTheHelperAndThenAnswersOnlyThem() async throws {
        let directory = TempDirectory()
        // `bash -c '"$1"; exit 0' bash <helper>` forks the helper, so the helper's parent is bash, standing in for sudo.
        let viaBash = ["/bin/bash", "-c", "\"$1\"; exit 0", "bash"]

        let server = try AskpassServer(secret: "hunter2", temporaryDirectory: directory.url)
        try server.start()
        defer { server.stop() }

        // While the password is being verified, the first helper is answered and its parent remembered.
        let learning = try await runHelper(server.helperPath, via: viaBash, allowedBy: server)
        XCTAssertEqual(learning, "hunter2\n")
        server.requireLearnedParent()

        let sameParent = try await runHelper(server.helperPath, via: viaBash, allowedBy: server)
        XCTAssertEqual(sameParent, "hunter2\n")
        let otherParent = try await runHelper(server.helperPath, allowedBy: server)
        XCTAssertEqual(otherParent, "", "a script that simply runs the helper itself must get nothing, even inside an allowed session")
    }

    /// The Xcode download (`sudo -A -- mas install`, `.asRoot()`, up to 4 hours) runs in the background while later items
    /// run. Those items' scripts are never told where the helper is, but the socket can be found in the temp folder, and
    /// a sudo of their own (the real one is /usr/bin/sudo, which anything can run) starts a helper of their own.
    func testWhileABackgroundCommandIsPrivilegedOnlyHelpersInsidePrivilegedCommandsAreAnswered() async throws {
        let directory = TempDirectory()
        var environment = SystemEnvironment.testSandbox(directory)
        environment.sudoPath = installFakeSudo(in: directory)
        let session = SudoSession(environment: environment, interaction: ScriptedInteraction(["open sesame"]))
        try await session.ensureReady(reason: "testing")
        defer { session.invalidate() }
        let runner = CommandRunner(environment: environment, sudo: session)

        // Stand-in for the background download: privileged, and running until the gate file appears.
        let gate = directory.url.appendingPathComponent("gate").path
        let background = Task {
            try await runner.runChecked(Command.shell("touch \"$1.started\"; i=0; while [ ! -f \"$1\" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done; echo downloaded",
                                                      arguments: [gate]).asRoot().silently())
        }
        defer { FileManager.default.createFile(atPath: gate, contents: nil) }
        try await waitFor(gate + ".started")

        // A later, ordinary item (a curl | bash installer, an npm postinstall).
        let thief = """
        echo "askpass=${SUDO_ASKPASS:-unset}"
        dir=$(ls -d "$SHAWN_TMP"/sdf-* | head -1)
        printf '#!/bin/sh\\nexec /usr/bin/nc -U -d %s > %s/leak\\n' "$dir/a.sock" "$SHAWN_TMP" > "$SHAWN_TMP/y"; chmod +x "$SHAWN_TMP/y"
        SUDO_ASKPASS="$SHAWN_TMP/y" "$THE_SUDO" -A -v >/dev/null 2>&1
        echo "leak=[$(cat "$SHAWN_TMP/leak" 2>/dev/null)]"
        SUDO_ASKPASS="$dir/askpass" "$THE_SUDO" -A -v >/dev/null 2>&1
        echo "own sudo with the real helper: exit $?"
        """
        let stolen = try await runner.run(Command.shell(thief)
            .env(["SHAWN_TMP": environment.temporaryDirectory.path, "THE_SUDO": environment.sudoPath]).silently())
        XCTAssertEqual(stolen.lines, ["askpass=unset", "leak=[]", "own sudo with the real helper: exit 1"], "an ordinary item read the password")

        // Another privileged command at the same time (brew installing a pkg cask) still gets its sudo.
        let brewLike = try await runner.run(Command.shell("\"$FAKE_SUDO\" -A -- /bin/echo elevated")
            .env(["FAKE_SUDO": environment.sudoPath]).silently().allowingSudo())
        XCTAssertEqual(brewLike.lines, ["elevated"])

        FileManager.default.createFile(atPath: gate, contents: nil)
        let downloaded = try await background.value
        XCTAssertEqual(downloaded.output, "downloaded")
        XCTAssertTrue(directory.exists("gate"))
    }

    /// The helper is answered only while the privileged command runs: whatever it leaves running in its session
    /// afterward gets nothing.
    func testWhatAPrivilegedCommandLeavesBehindGetsNothingOnceItHasEnded() async throws {
        let directory = TempDirectory()
        var environment = SystemEnvironment.testSandbox(directory)
        environment.sudoPath = installFakeSudo(in: directory)
        let session = SudoSession(environment: environment, interaction: ScriptedInteraction(["open sesame"]))
        try await session.ensureReady(reason: "testing")
        defer { session.invalidate() }
        let runner = CommandRunner(environment: environment, sudo: session)

        let gate = directory.url.appendingPathComponent("gate").path
        let late = directory.url.appendingPathComponent("late").path
        let script = """
        ( i=0; while [ ! -f "$GATE" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
          "$FAKE_SUDO" -A -v; echo "late sudo: exit $?" > "$LATE.tmp"; mv "$LATE.tmp" "$LATE" ) >/dev/null 2>&1 &
        "$FAKE_SUDO" -A -- /bin/echo elevated
        """
        let result = try await runner.run(Command.shell(script)
            .env(["FAKE_SUDO": environment.sudoPath, "GATE": gate, "LATE": late]).silently().allowingSudo())
        XCTAssertEqual(result.lines, ["elevated"])

        FileManager.default.createFile(atPath: gate, contents: nil)
        try await waitFor(late)
        XCTAssertEqual(directory.read("late")?.trimmingCharacters(in: .whitespacesAndNewlines), "late sudo: exit 1",
                       "the helper must be silent for the command's session once the command has ended")
    }

    private func waitFor(_ path: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: path) {
            guard Date() < deadline else { return XCTFail("\(path) never appeared", file: file, line: line) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testWrongThenRightPasswordThenPrivilegedCommand() async throws {
        let directory = TempDirectory()
        var environment = SystemEnvironment.testSandbox(directory)
        environment.sudoPath = installFakeSudo(in: directory)
        let interaction = ScriptedInteraction(["wrong", "open sesame"])
        let session = SudoSession(environment: environment, interaction: interaction)

        XCTAssertFalse(session.isReady)
        XCTAssertTrue(session.processEnvironment.isEmpty)
        try await session.ensureReady(reason: "testing")
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(interaction.prompts.count, 2)
        XCTAssertEqual(interaction.prompts[1].attempt, 2)
        XCTAssertEqual(interaction.prompts[1].lastError, "That password was not accepted.")

        let helper = try XCTUnwrap(session.processEnvironment["SUDO_ASKPASS"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper))

        // An ordinary command is not told where the helper is, and gets nothing from it if it finds out.
        let plainRunner = CommandRunner(environment: environment, sudo: session)
        let plain = try await plainRunner.run(Command.shell("echo ${SUDO_ASKPASS:-unset}; '\(helper)'").silently())
        XCTAssertEqual(plain.output, "unset")
        // A user-level command that may call sudo itself (brew) is told where the helper is, and its sudo gets
        // the password, but the command cannot read the password by running the helper itself.
        let brewLike = try await plainRunner.run(
            Command.shell("stolen=$(\"$SUDO_ASKPASS\"); echo \"stolen=[$stolen]\"; \"$FAKE_SUDO\" -A -- /bin/echo elevated")
                .env(["FAKE_SUDO": environment.sudoPath]).silently().allowingSudo())
        XCTAssertEqual(brewLike.lines, ["stolen=[]", "elevated"])
        let afterward = try await plainRunner.run(Command.shell("'\(helper)'").silently())
        XCTAssertEqual(afterward.output, "", "once the privileged command has finished the helper is silent again")

        // A second call must not prompt again.
        try await session.ensureReady(reason: "again")
        XCTAssertEqual(interaction.prompts.count, 2)

        // A privileged command goes through `sudo -A -- /usr/bin/env K=V <tool> args`.
        let recorder = Recorder<LogLine>()
        let runner = CommandRunner(environment: environment, sudo: session) { recorder.add($0) }
        let result = try await runner.runChecked(Command.shell("echo \"ran with $FLAVOR\"").env(["FLAVOR": "grape"]).asRoot())
        XCTAssertEqual(result.output, "ran with grape")
        XCTAssertTrue(recorder.all.contains { $0.style == .command && $0.text.hasPrefix("$ sudo ") })
        let log = try XCTUnwrap(directory.read("sudo.log"))
        XCTAssertTrue(log.contains("argv: -A -k -v"), log)
        XCTAssertTrue(log.contains("argv: -A -- /usr/bin/env FLAVOR=grape /bin/bash -c"), log)

        session.invalidate()
        XCTAssertFalse(session.isReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper), "the helper must be gone once the session ends")
    }

    func testDecliningIsRememberedAndNotAskedAgain() async {
        let directory = TempDirectory()
        var environment = SystemEnvironment.testSandbox(directory)
        environment.sudoPath = installFakeSudo(in: directory)
        let interaction = ScriptedInteraction([nil])
        let session = SudoSession(environment: environment, interaction: interaction)
        for _ in 0..<2 {
            do {
                try await session.ensureReady(reason: "testing")
                XCTFail("expected declined")
            } catch {
                XCTAssertEqual(String(describing: error), SudoError.declined.description)
            }
        }
        XCTAssertEqual(interaction.prompts.count, 1)
    }

    func testThreeWrongPasswordsGiveUp() async {
        let directory = TempDirectory()
        var environment = SystemEnvironment.testSandbox(directory)
        environment.sudoPath = installFakeSudo(in: directory)
        let interaction = ScriptedInteraction(["a", "b", "c", "open sesame"])
        let session = SudoSession(environment: environment, interaction: interaction)
        do {
            try await session.ensureReady(reason: "testing")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(String(describing: error), SudoError.tooManyAttempts.description)
        }
        XCTAssertEqual(interaction.prompts.count, 3)
        XCTAssertFalse(session.isReady)
    }

    func testConcurrentCallersShareOnePrompt() async throws {
        let directory = TempDirectory()
        var environment = SystemEnvironment.testSandbox(directory)
        environment.sudoPath = installFakeSudo(in: directory)
        let interaction = ScriptedInteraction(["open sesame"])
        let session = SudoSession(environment: environment, interaction: interaction)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask { try await session.ensureReady(reason: "caller \(index)") }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(interaction.prompts.count, 1)
        session.invalidate()
    }

    func testDryRunNeverPrompts() async throws {
        let directory = TempDirectory()
        let interaction = ScriptedInteraction([])
        let session = SudoSession(environment: .testSandbox(directory), interaction: interaction, dryRun: true)
        try await session.ensureReady(reason: "testing")
        XCTAssertTrue(interaction.prompts.isEmpty)
        XCTAssertFalse(session.isReady)
    }

    func testCommandNeedingSudoWithoutProviderFailsClearly() async {
        let directory = TempDirectory()
        let runner = CommandRunner(environment: .testSandbox(directory))
        do {
            _ = try await runner.run(Command("/usr/bin/true").asRoot())
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("needs administrator rights"), "\(error)")
        }
    }
}

final class FileOpsTests: XCTestCase {
    private func makeOps(_ directory: TempDirectory, dryRun: Bool = false) -> (FileOps, SystemEnvironment, Recorder<LogLine>) {
        let environment = SystemEnvironment.testSandbox(directory)
        let recorder = Recorder<LogLine>()
        return (FileOps(environment: environment, dryRun: dryRun) { recorder.add($0) }, environment, recorder)
    }

    func testWriteCreatesUpdatesBacksUpAndIsIdempotent() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let target = environment.home.appendingPathComponent(".config/tool/settings.json")

        XCTAssertEqual(try ops.write(Data("v1".utf8), to: target, permissions: 0o600), .created)
        XCTAssertEqual(ops.permissions(of: target), 0o600)
        XCTAssertEqual(try ops.write(Data("v1".utf8), to: target, permissions: 0o600), .unchanged)

        let change = try ops.write(Data("v2".utf8), to: target, permissions: 0o600)
        guard case .replaced(let backup?) = change else { return XCTFail("expected a backup, got \(change)") }
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "v1")
        XCTAssertTrue(backup.path.hasPrefix(environment.backupDirectory.path))
        XCTAssertTrue(backup.path.hasSuffix(".config/tool/settings.json"), backup.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "v2")

        // A permissions-only difference is still a change.
        XCTAssertTrue(try ops.write(Data("v2".utf8), to: target, permissions: 0o644).didChange)
    }

    func testReplacingAFileKeepsItsPermissionsUnlessToldOtherwise() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let target = environment.home.appendingPathComponent(".ssh/config")
        try ops.write(Data("one".utf8), to: target, permissions: 0o600)
        try ops.write(Data("two".utf8), to: target)
        XCTAssertEqual(ops.permissions(of: target), 0o600, "a private file must stay private when its contents change")
        try ops.write(Data("three".utf8), to: target, permissions: 0o644)
        XCTAssertEqual(ops.permissions(of: target), 0o644)
    }

    func testDryRunTouchesNothing() throws {
        let directory = TempDirectory()
        let (ops, environment, recorder) = makeOps(directory, dryRun: true)
        let existing = environment.home.appendingPathComponent("keep.txt")
        try Data("original".utf8).write(to: existing)

        XCTAssertTrue(try ops.write(Data("new".utf8), to: existing).didChange)
        XCTAssertEqual(try ops.ensureDirectory(environment.home.appendingPathComponent("Developer")), .created)
        XCTAssertEqual(try ops.symlink(at: environment.home.appendingPathComponent("link"), pointingTo: "keep.txt"), .created)
        XCTAssertTrue(try ops.remove(existing).didChange)

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.home.appendingPathComponent("Developer").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.home.appendingPathComponent("link").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.backupDirectory.path))
        XCTAssertTrue(recorder.all.allSatisfy { $0.text.hasPrefix("[dry-run] ") })
        XCTAssertFalse(recorder.all.isEmpty)
    }

    func testInstallFileKeepsExecutableBit() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let source = directory.write("payload/script.sh", "#!/bin/sh\n", permissions: 0o755)
        let target = environment.home.appendingPathComponent("bin/script.sh")
        XCTAssertEqual(try ops.installFile(from: source, to: target), .created)
        XCTAssertEqual(ops.permissions(of: target), 0o755)
        XCTAssertTrue(ops.fileMatches(source: source, destination: target))
        XCTAssertEqual(try ops.installFile(from: source, to: target), .unchanged)
    }

    func testInstallDirectoryMergeKeepsExtraFilesAndBacksUpChangedOnes() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        directory.write("payload/karabiner/karabiner.json", "{\"new\": true}")
        directory.write("payload/karabiner/assets/complex/rule.json", "{}")
        directory.write("payload/karabiner/.DS_Store", "junk")
        let source = directory.url.appendingPathComponent("payload/karabiner")
        let target = environment.home.appendingPathComponent(".config/karabiner")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("automatic_backups"), withIntermediateDirectories: true)
        try Data("{\"old\": true}".utf8).write(to: target.appendingPathComponent("karabiner.json"))
        try Data("keep me".utf8).write(to: target.appendingPathComponent("automatic_backups/b.json"))

        XCTAssertFalse(ops.directoryMatches(source: source, destination: target))
        XCTAssertEqual(try ops.installDirectory(from: source, to: target), 2)
        XCTAssertTrue(ops.directoryMatches(source: source, destination: target))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("automatic_backups/b.json"), encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".DS_Store").path))
        XCTAssertEqual(try String(contentsOf: environment.backupDirectory.appendingPathComponent(".config/karabiner/karabiner.json"), encoding: .utf8), "{\"old\": true}")
        XCTAssertEqual(try ops.installDirectory(from: source, to: target), 0, "second run is a no-op")
    }

    func testInstallDirectoryReplaceMirrorsExactly() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        directory.write("payload/skill/SKILL.md", "# skill v2")
        directory.write("payload/skill/scripts/run.sh", "#!/bin/sh\n", permissions: 0o755)
        let source = directory.url.appendingPathComponent("payload/skill")
        let target = environment.home.appendingPathComponent(".claude/skills/skill")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("# skill v1".utf8).write(to: target.appendingPathComponent("SKILL.md"))
        try Data("stale".utf8).write(to: target.appendingPathComponent("removed-upstream.md"))

        XCTAssertFalse(ops.directoryMatches(source: source, destination: target, exact: true))
        XCTAssertEqual(try ops.installDirectory(from: source, to: target, replace: true), 2)
        XCTAssertTrue(ops.directoryMatches(source: source, destination: target, exact: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("removed-upstream.md").path))
        XCTAssertEqual(ops.permissions(of: target.appendingPathComponent("scripts/run.sh")), 0o755)
        let backedUp = environment.backupDirectory.appendingPathComponent(".claude/skills/skill/removed-upstream.md")
        XCTAssertEqual(try String(contentsOf: backedUp, encoding: .utf8), "stale", "the old directory is preserved whole in the backup")
    }

    func testInstallDirectoryReplacesSymlinkedDestination() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        directory.write("payload/skill/SKILL.md", "# real")
        directory.write("elsewhere/SKILL.md", "# linked")
        let target = environment.home.appendingPathComponent(".claude/skills/skill")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: directory.url.appendingPathComponent("elsewhere"))

        try ops.installDirectory(from: directory.url.appendingPathComponent("payload/skill"), to: target, replace: true)
        XCTAssertFalse(ops.isSymlink(target))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8), "# real")
        XCTAssertEqual(directory.read("elsewhere/SKILL.md"), "# linked", "the old link target must be untouched")
    }

    func testSymlinkCreateRepointAndReplaceRealFile() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let link = environment.home.appendingPathComponent(".claude/skills/find-skills")
        XCTAssertEqual(try ops.symlink(at: link, pointingTo: "../../.agents/skills/find-skills"), .created)
        XCTAssertTrue(ops.symlinkMatches(at: link, target: "../../.agents/skills/find-skills"))
        XCTAssertTrue(ops.exists(link), "a dangling link still exists")
        XCTAssertEqual(try ops.symlink(at: link, pointingTo: "../../.agents/skills/find-skills"), .unchanged)
        XCTAssertEqual(try ops.symlink(at: link, pointingTo: "/somewhere/else"), .replaced(backup: nil))

        let real = environment.home.appendingPathComponent("real.txt")
        try Data("precious".utf8).write(to: real)
        guard case .replaced(let backup?) = try ops.symlink(at: real, pointingTo: "/target") else { return XCTFail("expected backup") }
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "precious")
    }

    func testBackupsNeverCollideWithinARun() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let target = environment.home.appendingPathComponent("file.txt")
        try ops.write(Data("1".utf8), to: target)
        try ops.write(Data("2".utf8), to: target)
        try ops.write(Data("3".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: environment.backupDirectory.appendingPathComponent("file.txt"), encoding: .utf8), "1")
        XCTAssertEqual(try String(contentsOf: environment.backupDirectory.appendingPathComponent("file.txt.2"), encoding: .utf8), "2")
    }

    func testWritingBelowALinkedFolderReplacesTheLinkInsteadOfWritingThroughIt() throws {
        let directory = TempDirectory()
        let (ops, environment, recorder) = makeOps(directory)
        // A stow-style setup: ~/.config/ghostty is a link into a dotfiles checkout.
        let repoFolder = environment.home.appendingPathComponent("Developer/dotfiles/darwin/ghostty/.config/ghostty")
        try FileManager.default.createDirectory(at: repoFolder.appendingPathComponent("themes"), withIntermediateDirectories: true)
        try Data("old config".utf8).write(to: repoFolder.appendingPathComponent("config"))
        try Data("theme".utf8).write(to: repoFolder.appendingPathComponent("themes/cyberdream"))
        let linked = environment.home.appendingPathComponent(".config/ghostty")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: repoFolder)

        let target = linked.appendingPathComponent("config")
        let change = try ops.write(Data("new config".utf8), to: target)

        XCTAssertFalse(ops.isSymlink(linked), "the link must have been replaced by a real folder")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new config")
        XCTAssertEqual(try String(contentsOf: linked.appendingPathComponent("themes/cyberdream"), encoding: .utf8), "theme", "other files in the folder survive")
        XCTAssertEqual(try String(contentsOf: repoFolder.appendingPathComponent("config"), encoding: .utf8), "old config", "the checkout must be untouched")
        XCTAssertEqual(listing(repoFolder), ["config", "themes"], "nothing may be added to the checkout, backups included")
        XCTAssertTrue(ops.isSymlink(environment.backupDirectory.appendingPathComponent(".config/ghostty")), "the link itself is kept in the backups")
        guard case .replaced(let backup?) = change else { return XCTFail("expected a backup, got \(change)") }
        XCTAssertEqual(backup.path, environment.backupDirectory.appendingPathComponent(".config/ghostty.2/config").path,
                       "the replaced file goes next to the backed-up link, not through it")
        XCTAssertEqual(backup.resolvingSymlinksInPath().path,
                       environment.backupDirectory.appendingPathComponent(".config/ghostty.2/config").resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old config")
        XCTAssertTrue(recorder.all.contains { $0.text.contains("is a link to") })
        XCTAssertEqual(try ops.write(Data("new config".utf8), to: target), .unchanged, "second run is a no-op")
    }

    private func listing(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? []
    }

    /// GNU stow (the old installer's `stow -R`) makes RELATIVE links. Once the link has been moved to the backups it
    /// dangles there, and a later backup that resolved through it failed, and kept failing for every retry in the run.
    func testWritingBelowARelativeStowLinkWorksAndRetriesInTheSameRunWorkToo() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let repoFolder = environment.home.appendingPathComponent("Developer/dotfiles/darwin/ghostty/.config/ghostty")
        try FileManager.default.createDirectory(at: repoFolder, withIntermediateDirectories: true)
        try Data("old config".utf8).write(to: repoFolder.appendingPathComponent("config"))
        let linked = environment.home.appendingPathComponent(".config/ghostty")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: "../Developer/dotfiles/darwin/ghostty/.config/ghostty")
        let target = linked.appendingPathComponent("config")

        XCTAssertNoThrow(try ops.write(Data("new config".utf8), to: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new config")
        XCTAssertFalse(ops.isSymlink(linked))
        // Same FileOps, same run ID: what RETRY FAILED and RESUME in the app do.
        XCTAssertNoThrow(try ops.write(Data("newer config".utf8), to: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "newer config")

        XCTAssertEqual(listing(repoFolder), ["config"], "the checkout must not gain files")
        XCTAssertEqual(directory.read("home/Developer/dotfiles/darwin/ghostty/.config/ghostty/config"), "old config")
        let backups = environment.backupDirectory.appendingPathComponent(".config")
        XCTAssertEqual(listing(backups), ["ghostty", "ghostty.2"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: backups.appendingPathComponent("ghostty").path),
                       "../Developer/dotfiles/darwin/ghostty/.config/ghostty", "the link is kept exactly as it was")
        XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent("ghostty.2/config"), encoding: .utf8), "old config")
        XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent("ghostty.2/config.2"), encoding: .utf8), "new config")
    }

    /// Nested links, the outer one pointing outside home: every backup stays inside this run's backup folder.
    func testNestedLinkedFoldersOutsideHomeGetNoBackupsWrittenIntoThem() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let external = directory.url.appendingPathComponent("external")
        let realConfig = external.appendingPathComponent("config")
        let realGhostty = external.appendingPathComponent("ghostty-real")
        try FileManager.default.createDirectory(at: realConfig, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realGhostty, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: realGhostty.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(at: realConfig.appendingPathComponent("ghostty"), withDestinationURL: realGhostty)
        try FileManager.default.createSymbolicLink(at: environment.home.appendingPathComponent(".config"), withDestinationURL: realConfig)

        let target = environment.home.appendingPathComponent(".config/ghostty/config")
        let change = try ops.write(Data("new".utf8), to: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertFalse(ops.isSymlink(environment.home.appendingPathComponent(".config")))
        XCTAssertFalse(ops.isSymlink(environment.home.appendingPathComponent(".config/ghostty")))
        XCTAssertEqual(listing(realConfig), ["ghostty"], "nothing may be added outside home")
        XCTAssertEqual(listing(realGhostty), ["config"], "nothing may be added outside home")
        XCTAssertEqual(directory.read("external/ghostty-real/config"), "old")
        guard case .replaced(let backup?) = change else { return XCTFail("expected a backup, got \(change)") }
        let backupRoot = environment.backupDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(backup.resolvingSymlinksInPath().path.hasPrefix(backupRoot + "/"), backup.resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")
    }

    func testBackUpPassesByFilesAndLinksAlreadyInTheBackups() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let elsewhere = directory.url.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // Earlier backups in this run: a FILE where a folder is now needed, and a link to a folder outside the backups.
        let backups = environment.backupDirectory
        try FileManager.default.createDirectory(at: backups.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data("a was a file".utf8).write(to: backups.appendingPathComponent("a"))
        try FileManager.default.createSymbolicLink(at: backups.appendingPathComponent("b/c"), withDestinationURL: elsewhere)
        directory.write("home/a/one.txt", "1")
        directory.write("home/b/c/two.txt", "2")
        directory.write("home/b/three.txt", "3")

        XCTAssertEqual(try ops.backUp(environment.home.appendingPathComponent("a/one.txt"))?.path, backups.appendingPathComponent("a.2/one.txt").path)
        XCTAssertEqual(try ops.backUp(environment.home.appendingPathComponent("b/c/two.txt"))?.path, backups.appendingPathComponent("b/c.2/two.txt").path)
        XCTAssertEqual(try ops.backUp(environment.home.appendingPathComponent("b/three.txt"))?.path, backups.appendingPathComponent("b/three.txt").path,
                       "a real folder in the backups is used as it is")
        XCTAssertEqual(listing(elsewhere), [], "nothing is moved through a link in the backups")
        XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent("a"), encoding: .utf8), "a was a file")
    }

    /// A folder listed nothing when its path ran through a link (a checkout under a linked ~/Dropbox, say), so a
    /// payload folder read that way installed empty and still counted as done.
    func testAFolderListsTheSameFilesHoweverItsPathIsSpelled() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let manager = FileManager.default
        let real = environment.home.appendingPathComponent("Cloud Drive/it's/demo")
        try manager.createDirectory(at: real.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try manager.createDirectory(at: real.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try manager.createDirectory(at: real.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: real.appendingPathComponent("SKILL.md"))
        try Data("run".utf8).write(to: real.appendingPathComponent("scripts/run.sh"))
        try Data("x".utf8).write(to: real.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: real.appendingPathComponent(".git/objects/pack"))
        try manager.createSymbolicLink(atPath: real.appendingPathComponent("latest").path, withDestinationPath: "scripts")
        let expected = ["SKILL.md", "latest", "scripts/run.sh"]
        XCTAssertEqual(ops.files(in: real), expected, "links are listed, not followed; excluded names and empty folders are left out")

        // Through an absolute link and a relative one, and when the folder itself is a link.
        let absolute = environment.home.appendingPathComponent("Absolute")
        try manager.createSymbolicLink(at: absolute, withDestinationURL: environment.home.appendingPathComponent("Cloud Drive"))
        try manager.createSymbolicLink(atPath: environment.home.appendingPathComponent("Relative").path, withDestinationPath: "Cloud Drive/it's")
        try manager.createSymbolicLink(at: environment.home.appendingPathComponent("Demo"), withDestinationURL: real)
        XCTAssertEqual(ops.files(in: absolute.appendingPathComponent("it's/demo")), expected)
        XCTAssertEqual(ops.files(in: environment.home.appendingPathComponent("Relative/demo")), expected)
        XCTAssertEqual(ops.files(in: environment.home.appendingPathComponent("Demo")), expected)

        // In another letter case, where the volume does not tell the two apart.
        let shouted = environment.home.appendingPathComponent("CLOUD DRIVE/IT'S/DEMO")
        if manager.fileExists(atPath: shouted.path) {
            XCTAssertEqual(ops.files(in: shouted), expected)
        }

        // What reads a folder that way gets its files: a copy from the linked path is complete and counts as matching.
        let copy = environment.home.appendingPathComponent("copy")
        XCTAssertEqual(try ops.installDirectory(from: absolute.appendingPathComponent("it's/demo"), to: copy), 3)
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("scripts/run.sh"), encoding: .utf8), "run")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("latest").path), "scripts")
        XCTAssertTrue(ops.directoryMatches(source: absolute.appendingPathComponent("it's/demo"), destination: copy, exact: true))
        XCTAssertEqual(ops.files(in: environment.home.appendingPathComponent("nowhere")), [])
    }

    func testLinkedFolderHandlingInDryRunAndWhenTooBig() throws {
        let directory = TempDirectory()
        let (dryOps, environment, recorder) = makeOps(directory, dryRun: true)
        let elsewhere = directory.url.appendingPathComponent("external/Projects")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for index in 0..<5 { try Data("x".utf8).write(to: elsewhere.appendingPathComponent("file\(index)")) }
        let linked = environment.home.appendingPathComponent("Projects")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)

        XCTAssertTrue(try dryOps.write(Data("hi".utf8), to: linked.appendingPathComponent("note.txt")).didChange)
        XCTAssertTrue(dryOps.isSymlink(linked), "a dry run leaves the link alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("note.txt").path))
        XCTAssertTrue(recorder.all.contains { $0.text.hasPrefix("[dry-run] ") && $0.text.contains("is a link to") })

        var realOps = FileOps(environment: environment)
        realOps.unfoldFileLimit = 3
        XCTAssertThrowsError(try realOps.write(Data("hi".utf8), to: linked.appendingPathComponent("note.txt"))) { error in
            // The instruction is a hint of its own, so a caller that adds a general hint can use this one instead.
            let refusal = error as? FileOpsError
            XCTAssertEqual(refusal?.message.hasSuffix(", which is too big to copy automatically"), true, "\(error)")
            XCTAssertEqual(refusal?.hint, "replace the link with a real folder (or point this item somewhere else) and run this again")
            XCTAssertTrue(InstallEngine.describe(error).hasSuffix(
                "too big to copy automatically. Replace the link with a real folder (or point this item somewhere else) and run this again"), "\(error)")
        }
        XCTAssertTrue(realOps.isSymlink(linked), "a folder that is too big is never copied or unlinked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("note.txt").path))

        // A link that IS the destination folder is accepted as the folder, and never chmod-ed through.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)
        XCTAssertEqual(try realOps.ensureDirectory(linked, permissions: 0o700), .unchanged)
        XCTAssertEqual(realOps.permissions(of: elsewhere), 0o755)
    }

    func testDryRunOfInstallDirectoryOverAFileOrDanglingLinkDoesNotFail() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory, dryRun: true)
        directory.write("payload/hammerspoon/init.lua", "-- init")
        let source = directory.url.appendingPathComponent("payload/hammerspoon")

        let dangling = environment.home.appendingPathComponent(".hammerspoon")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/nowhere/at/all")
        XCTAssertEqual(try ops.installDirectory(from: source, to: dangling), 1)
        XCTAssertTrue(ops.isSymlink(dangling))

        let plainFile = environment.home.appendingPathComponent(".other")
        try Data("a file".utf8).write(to: plainFile)
        XCTAssertEqual(try ops.installDirectory(from: source, to: plainFile), 1)
        XCTAssertEqual(try String(contentsOf: plainFile, encoding: .utf8), "a file")
    }

    func testEnsureDirectoryRefusesToClobberAFile() throws {
        let directory = TempDirectory()
        let (ops, environment, _) = makeOps(directory)
        let path = environment.home.appendingPathComponent("Developer")
        try Data("i am a file".utf8).write(to: path)
        XCTAssertThrowsError(try ops.ensureDirectory(path))
    }
}
