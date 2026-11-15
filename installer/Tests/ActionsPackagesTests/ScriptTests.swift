import XCTest
@testable import ActionsPackages
import ShawnCore

final class ScriptTests: XCTestCase {
    func testWithoutCheckOrCreatesItAlwaysRuns() async throws {
        let sandbox = Sandbox()
        let counter = sandbox.root.appendingPathComponent("count").path
        let yaml = "script: Counter\nrun: echo x >> '\(counter)'"
        for _ in 0..<2 {
            let result = try await sandbox.run(yaml)
            XCTAssertEqual(result.check, .needed(nil))
            XCTAssertEqual(result.outcome, .done(nil))
        }
        XCTAssertEqual(try String(contentsOfFile: counter, encoding: .utf8), "x\nx\n")
    }

    func testOnlyAScriptWithACheckOrCreatesCanBeHealthChecked() throws {
        let sandbox = Sandbox()
        XCTAssertFalse(try sandbox.parse("script: Counter\nrun: echo x").action.isCheckable, "it can never say 'already done'")
        XCTAssertTrue(try sandbox.parse("script: A\nrun: echo x\ncheck: 'true'").action.isCheckable)
        XCTAssertTrue(try sandbox.parse("script: B\nrun: echo x\ncreates: ~/b").action.isCheckable)
        XCTAssertTrue(try sandbox.parse("brew: eza").action.isCheckable)
    }

    func testCreatesMakesItIdempotentAndIsExpanded() async throws {
        let sandbox = Sandbox()
        let yaml = "script: Claude Code\nrun: mkdir -p ~/.local/bin && touch ~/.local/bin/claude\ncreates: '{{home}}/.local/bin/claude'"
        let first = try await sandbox.run(yaml)
        XCTAssertEqual(first.check, .needed("~/.local/bin/claude does not exist yet"))
        XCTAssertEqual(first.outcome, .done(nil))
        let second = try await sandbox.run(yaml)
        XCTAssertEqual(second.check, .satisfied("~/.local/bin/claude exists"))
        XCTAssertNil(second.outcome)
    }

    func testAScriptThatDoesNotCreateItsPathFails() async throws {
        let sandbox = Sandbox()
        do {
            _ = try await sandbox.run("script: Liar\nrun: 'true'\ncreates: ~/never")
            XCTFail("expected a failure")
        } catch let error as ActionError {
            XCTAssertEqual(error.message, "The script finished but ~/never does not exist")
        }
    }

    func testCheckDecidesAndRunsEvenInDryRun() async throws {
        let sandbox = Sandbox()
        let marker = sandbox.root.appendingPathComponent("marker").path
        let yaml = "script: Marker\nrun: touch '\(marker)'\ncheck: test -f '\(marker)'"

        let dry = try await sandbox.run(yaml, dryRun: true)
        XCTAssertEqual(dry.check, .needed(nil), "check ran as a probe in the dry run")
        XCTAssertEqual(dry.outcome, .done(nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the dry run did not run the script")
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ touch "), sandbox.logText)

        _ = try await sandbox.run(yaml)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        let again = try await sandbox.check(yaml)
        XCTAssertEqual(again, .satisfied("its check passes"))
    }

    func testCheckAndCreatesTogetherMustBothHold() async throws {
        let sandbox = Sandbox()
        sandbox.directory.write("home/thing", "")
        let failingCheck = try await sandbox.check("script: Both\nrun: 'true'\ncreates: ~/thing\ncheck: exit 3")
        XCTAssertEqual(failingCheck, .needed(nil))
        let both = try await sandbox.check("script: Both\nrun: 'true'\ncreates: ~/thing\ncheck: exit 0")
        XCTAssertEqual(both, .satisfied("~/thing exists"))
        let missingPath = try await sandbox.check("script: Both\nrun: 'true'\ncreates: ~/other\ncheck: exit 0")
        XCTAssertEqual(missingPath, .needed("~/other does not exist yet"))
    }

    func testStrictModeStopsAtTheFirstFailureForBashAndZsh() async throws {
        let sandbox = Sandbox()
        for shell in ["bash", "zsh"] {
            let after = sandbox.root.appendingPathComponent("after-\(shell)").path
            do {
                _ = try await sandbox.run("script: Strict\nshell: \(shell)\nrun: |\n  false | cat\n  touch '\(after)'")
                XCTFail("\(shell): pipefail should stop the script")
            } catch {
                XCTAssertTrue("\(error)".contains("failed (exit 1)"), "\(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: after), shell)
        }
        // sh gets no prelude: the script decides for itself.
        let after = sandbox.root.appendingPathComponent("after-sh").path
        let result = try await sandbox.run("script: Lenient\nshell: sh\nrun: |\n  false\n  touch '\(after)'")
        XCTAssertEqual(result.outcome, .done(nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: after))
    }

    func testEnvironmentWorkingDirectoryAndVariablesAreExpanded() async throws {
        let sandbox = Sandbox()
        sandbox.directory.mkdir("home/work")
        let out = sandbox.root.appendingPathComponent("out").path
        let yaml = """
        script: Env
        run: echo "$GREETING {{flavor}} $(pwd -P) $HOME" > '\(out)'
        env: {GREETING: 'hi {{email}}'}
        cwd: ~/work
        """
        _ = try await sandbox.run(yaml)
        let home = physicalPath(sandbox.home.path)
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8),
                       "hi lsp@example.com grape \(home)/work \(sandbox.home.path)\n")
    }

    func testAMissingWorkingDirectoryIsAClearError() async throws {
        let sandbox = Sandbox()
        let yaml = "script: Nowhere\nrun: 'true'\ncheck: 'true'\ncwd: ~/missing"
        let check = try await sandbox.check(yaml)
        XCTAssertEqual(check, .needed("its working directory ~/missing does not exist"))
        do {
            _ = try await sandbox.run(yaml)
            XCTFail("expected a failure")
        } catch let error as ActionError {
            XCTAssertEqual(error.message, "The working directory ~/missing does not exist")
        }
    }

    func testSudoRunsTheScriptAsRootButNeverTheCheck() async throws {
        let sandbox = Sandbox()
        let out = sandbox.root.appendingPathComponent("who").path
        _ = try await sandbox.run("script: Root\nsudo: true\nenv: {K: v}\ncheck: '[ -n \"$RUN_AS_ROOT\" ]'\nrun: echo \"root=$RUN_AS_ROOT K=$K\" > '\(out)'")
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "root=1 K=v\n")
        let sudo = try XCTUnwrap(sandbox.calls("sudo").first)
        XCTAssertTrue(sudo.hasPrefix("sudo -A -- /usr/bin/env K=v /bin/bash -c set -euo pipefail"), sudo)
        XCTAssertEqual(sandbox.calls("sudo").count, 1, "the check ran unprivileged")
    }

    func testTimeoutStopsALongScript() async throws {
        let sandbox = Sandbox()
        let started = Date()
        do {
            _ = try await sandbox.run("script: Slow\nrun: sleep 30\ntimeout: 0.5")
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("did not finish within"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testFailureCarriesTheOutputTail() async throws {
        let sandbox = Sandbox()
        do {
            _ = try await sandbox.run("script: Broken\nrun: |\n  echo 'step one'\n  echo 'curl: (6) Could not resolve host' >&2\n  exit 6")
            XCTFail("expected a failure")
        } catch let error as CommandError {
            XCTAssertEqual(error.description, "echo 'step one' … failed (exit 6): curl: (6) Could not resolve host")
        }
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .stdout && $0.text == "step one" })
    }

    func testStillFailingCheckAfterARunIsAWarning() async throws {
        let sandbox = Sandbox()
        let result = try await sandbox.run("script: Stubborn\nrun: 'true'\ncheck: exit 1")
        XCTAssertEqual(result.outcome, .done(nil))
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .warning && $0.text.contains("its check still fails") })
    }
}
