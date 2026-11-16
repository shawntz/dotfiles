import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

/// SU-3: every line and exit status of `shawn update` / `shawn update --check` says what really happened.
final class SelfUpdateCommandTests: XCTestCase {
    private typealias Report = SelfUpdater.Report

    /// Every outcome, with and without a pull before it.
    func testEverySummaryLineAndExitStatus() {
        let cases: [(Report, UpdateCommand.Summary.Mark, String, Int32)] = [
            (Report(outcome: .upToDate), .done, "up to date", 0),
            (Report(outcome: .pulled(commits: 1), pulledCommits: 1), .done, "pulled 1 commit; shawn itself did not change", 0),
            (Report(outcome: .pulled(commits: 3), pulledCommits: 3), .done, "pulled 3 commits; shawn itself did not change", 0),
            (Report(outcome: .rebuilt), .done, "rebuilt shawn from the sources in the checkout", 0),
            (Report(outcome: .rebuilt, pulledCommits: 2), .done, "pulled 2 commits and rebuilt shawn from the new sources", 0),
            (Report(outcome: .releaseInstalled("1.2.0")), .done, "installed shawn 1.2.0", 0),
            (Report(outcome: .updateAvailable("shawn 1.2.0")), .available, "update available: shawn 1.2.0. Run 'shawn update' to get it", 0),
            (Report(outcome: .disabled), .warning, "self-update is off (self_update.mode: off in cli.yaml)", 0),
            (Report(outcome: .notDue), .done, "checked less than a day ago (self_update.mode: daily)", 0),
            (Report(outcome: .nothingToCheck), .warning, "nothing to check: there is no dotfiles checkout and installer.yaml has no 'remote:'", 1),
            (Report(outcome: .offline("fatal: unable to access")), .warning,
             "could not reach the remote (fatal: unable to access); nothing changed. Try again when you are online", 69),
            (Report(outcome: .checkFailed("couldn't check origin for updates: git@github.com: Permission denied (publickey). …")), .failed,
             "couldn't check origin for updates: git@github.com: Permission denied (publickey). …", 1),
            (Report(outcome: .fetchFailed("error: cannot lock ref")), .failed, "could not fetch the new commits (error: cannot lock ref); nothing changed", 1),
            (Report(outcome: .skipped("~/d has uncommitted changes")), .warning, "skipped: ~/d has uncommitted changes", 1),
            (Report(outcome: .skipped("~/d has untracked files"), pulledCommits: 1), .warning,
             "pulled 1 commit, but skipped rebuilding shawn: ~/d has untracked files", 1),
            (Report(outcome: .buildFailed("error: x")), .failed, "the rebuild failed (error: x); the current shawn is still installed", 1),
            (Report(outcome: .buildFailed("error: x"), pulledCommits: 1), .failed,
             "pulled 1 commit, but the rebuild failed (error: x); the current shawn is still installed", 1),
            (Report(outcome: .notReplaced("the Swift sources changed, but this shawn is not replaced in place: it is a development build in /r/.build/debug")),
             .warning, "the Swift sources changed, but this shawn is not replaced in place: it is a development build in /r/.build/debug", 1),
            (Report(outcome: .notReplaced("the Swift sources changed, but …"), pulledCommits: 1), .warning, "pulled 1 commit; the Swift sources changed, but …", 1),
            (Report(outcome: .installFailed("could not replace /b/shawn: Permission denied")), .failed,
             "couldn't put the new shawn in place (could not replace /b/shawn: Permission denied); the current one is still installed", 1),
            (Report(outcome: .releaseRejected("checksum mismatch")), .failed, "rejected the download: checksum mismatch; the current shawn is still installed", 1),
            (Report(outcome: .downloadFailed("shawn.tar.gz: HTTP 404")), .failed,
             "couldn't download the new shawn (shawn.tar.gz: HTTP 404); the current one is still installed", 1),
        ]
        for (report, mark, text, code) in cases {
            XCTAssertEqual(UpdateCommand.summary(of: report), UpdateCommand.Summary(mark: mark, text: text, exitCode: code), "\(report.outcome)")
        }
    }

    // MARK: Through the CLI

    func testAFailedDownloadFailsShawnUpdate() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, meta: "name: T\nremote:\n  repo: tester/dotfiles\n  branch: master\n  path: installer/config\n",
                                steps: [:], cli: "commands: {}\n")
        let fake = FakeGit()
        fake.answer(["ls-remote"], stdout: "abc\trefs/heads/master\n111\trefs/tags/shawn-v99.0.0\n")
        let harness = Harness(sandbox: sandbox, config: config) { $0.git = fake }
        let code = await harness.run(["update"])
        XCTAssertEqual(code, ExitCode.failure)
        XCTAssertTrue(harness.out.plain.hasSuffix("✗ couldn't download the new shawn (no manifest); the current one is still installed\n"), harness.out.plain)
        XCTAssertFalse(harness.out.plain.contains("update available"), harness.out.plain)
    }

    func testNothingToCheckSaysSo() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: [:], cli: "commands: {}\n")
        let harness = Harness(sandbox: sandbox, config: config)
        let code = await harness.run(["update"])
        XCTAssertEqual(code, ExitCode.failure)
        XCTAssertTrue(harness.out.plain.hasSuffix("! nothing to check: there is no dotfiles checkout and installer.yaml has no 'remote:'\n"), harness.out.plain)
        XCTAssertFalse(harness.out.plain.contains("up to date"))
    }

    func testCheckSaysARebuildIsNeededAndChangesNothing() async {
        let fixture = UpdateFixture()
        fixture.push("installer/Sources/shawn/main.swift", "print(\"new\")\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        let before = fixture.stateSnapshot()
        let harness = fixture.harness()
        let code = await harness.run(["update", "--check"])
        XCTAssertEqual(code, ExitCode.ok)
        let head = fixture.head(fixture.checkout).prefix(7)
        XCTAssertTrue(harness.out.plain.hasSuffix("↑ update available: a rebuild of shawn at \(head) (the Swift sources changed). Run 'shawn update' to get it\n"),
                      harness.out.plain)
        XCTAssertEqual(fixture.stateSnapshot(), before)
        XCTAssertTrue(fixture.builder.builds.isEmpty)
    }

    func testAFileInTheWayIsNamedByShawnUpdate() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/new.yaml", "mine\n")
        fixture.push("installer/config/new.yaml", "theirs\n")
        let harness = fixture.harness()
        let code = await harness.run(["update"])
        XCTAssertEqual(code, ExitCode.failure)
        XCTAssertTrue(harness.out.plain.hasSuffix("! skipped: pulling origin/master would overwrite installer/config/new.yaml in "
                                                  + "\(fixture.checkout.path). Move or remove it, then run 'shawn update'\n"), harness.out.plain)
        XCTAssertFalse(harness.out.plain.contains("Aborting"), harness.out.plain)
    }

    func testAFailedFetchIsNotCalledOffline() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let recording = RecordingGit(fixture.realGit)
        recording.fail("fetch", exit: 1, stderr: "error: cannot lock ref 'refs/remotes/origin/master': is at abc but expected def\n")
        let report = await fixture.updater(git: recording).run(fixture.request(force: true))
        XCTAssertEqual(report.outcome, .fetchFailed("error: cannot lock ref 'refs/remotes/origin/master': is at abc but expected def"))
        XCTAssertEqual(fixture.notes.all.last, "couldn't fetch origin/master: error: cannot lock ref 'refs/remotes/origin/master': is at abc but expected def")
    }

    /// origin over ssh, and the key is refused (not in the agent, or not the one GitHub knows): the remote answered, so this
    /// is not "offline", and ssh's reason is the one shown.
    func testARefusedSSHKeyIsNotCalledOffline() async {
        let fixture = UpdateFixture()
        let refused = fixture.sshGit(failingWith: "git@github.com: Permission denied (publickey).")
        let expected = "couldn't check origin for updates: git@github.com: Permission denied (publickey). fatal: Could not read from remote repository. "
            + "'git ls-remote origin' must work in \(fixture.checkout.path) without a prompt"

        // Automatic runs say it (once a day): self-update has stopped until somebody fixes this.
        let automatic = await fixture.updater(git: refused).run(fixture.request())
        XCTAssertEqual(automatic.outcome, .checkFailed(expected))
        XCTAssertEqual(fixture.notes.all, [expected])
        _ = await fixture.updater(git: refused).run(fixture.request())
        XCTAssertEqual(fixture.notes.all, [expected], "not on every call")

        let harness = fixture.harness()
        harness.context.services.git = refused
        let code = await harness.run(["update"])
        XCTAssertEqual(code, ExitCode.failure)
        XCTAssertTrue(harness.out.plain.hasSuffix("✗ \(expected)\n"), harness.out.plain)
        XCTAssertFalse(harness.out.plain.contains("online"), harness.out.plain)
    }

    /// The checkout has an unpushed commit, and an earlier run fetched the remote's different new commit: --check must
    /// say what `shawn update` then does, not "update available".
    func testCheckSaysAFetchedCommitDoesNotFastForward() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/mine.yaml", "mine\n")
        git(["add", "-A"], in: fixture.checkout)
        git(["commit", "-q", "-m", "unpushed"], in: fixture.checkout)
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let reason = "local commits on master are not on origin yet"
        let update = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(update.outcome, .skipped(reason))

        let before = fixture.stateSnapshot()
        let check = await fixture.updater().run(fixture.request(force: true, checkOnly: true))
        XCTAssertEqual(check.outcome, .skipped(reason))
        XCTAssertEqual(fixture.stateSnapshot(), before, "--check still writes nothing")

        let harness = fixture.harness()
        let code = await harness.run(["update", "--check"])
        XCTAssertEqual(code, ExitCode.failure)
        XCTAssertTrue(harness.out.plain.hasSuffix("! skipped: \(reason)\n"), harness.out.plain)
    }

    /// The Mac shawn is developed on: one unpushed commit (config only). `--rebuild` rebuilds; it does not say "up to date".
    func testRebuildWithAnUnpushedCommitRebuilds() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/mine.yaml", "mine\n")
        git(["add", "-A"], in: fixture.checkout)
        git(["commit", "-q", "-m", "unpushed"], in: fixture.checkout)
        let harness = fixture.harness()
        let code = await harness.run(["update", "--rebuild"])
        XCTAssertEqual(code, ExitCode.ok, harness.out.plain + harness.err.plain)
        XCTAssertEqual(fixture.builder.builds.count, 1)
        XCTAssertTrue(harness.out.plain.hasSuffix("✓ rebuilt shawn from the sources in the checkout\n"), harness.out.plain)
        XCTAssertEqual(fixture.store.installedSourceTree(), fixture.contentID(at: fixture.head(fixture.checkout), in: fixture.checkout))
    }

    func testDevelopmentBuildSaysItWasNotReplaced() async {
        let fixture = UpdateFixture()
        let devBinary = fixture.sandbox.directory.url.appendingPathComponent("repo/.build/debug/shawn")
        try! FileManager.default.createDirectory(at: devBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("dev".utf8).write(to: devBinary)
        fixture.push("installer/Sources/shawn/main.swift", "print(\"dev\")\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        let check = await fixture.updater().run(fixture.request(force: true, checkOnly: true, binary: devBinary))
        guard case .notReplaced(let reason) = check.outcome else { return XCTFail("--check said \(check.outcome)") }
        let summary = UpdateCommand.summary(of: check)
        XCTAssertEqual(summary.exitCode, ExitCode.failure)
        XCTAssertEqual(summary.text, reason)
        XCTAssertTrue(reason.contains("development build"), reason)
    }
}
