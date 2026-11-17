import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

/// Each safety or latency guard of the self-updater has a test here (or in SelfUpdaterTests) that fails when the
/// guard is taken out, against real git and temporary bare repositories:
///
/// | guard                                   | test                                                            |
/// |-----------------------------------------|-----------------------------------------------------------------|
/// | dirty checkout, before pulling          | SelfUpdaterTests.testDirtyCheckoutIsSkippedWithANote            |
/// | dirty checkout, before building         | testTrackedSourceEditIsNeverBuilt, testStagedOnlyChange…        |
/// | untracked files in the Swift package    | testUntrackedSourceFileBlocksTheRebuild, …NewManifest…          |
/// | other branch / detached HEAD            | SelfUpdaterTests.testOtherBranchIsSkipped, testDetachedHead…    |
/// | unpushed commits                        | SelfUpdaterTests.testUnpushedCommitsAreSkipped                  |
/// | unpushed commits changing the sources   | testUnpushedSourceChangesAreNeverBuilt                          |
/// | files in the fast-forward's way         | testFastForwardNeverOverwritesAnIgnoredLocalFile, …             |
/// | ls-remote timeout (real process)        | testHangingRemoteIsCutOffEndToEnd                               |
/// | a refusal is not offline                | SelfUpdateCommandTests.testARefusedSSHKeyIsNotCalledOffline     |
/// | no prompts, no windows                  | GitClientTests.testGitIsNeverAskedToPromptOrOpenAWindow         |
/// | loop guard                              | SelfUpdateDispatchTests.testTheRestartedProcessDoesNotUpdateAgain |
/// | one updater at a time                   | testAnotherShawnHoldingTheLockMeansNoUpdate, testConcurrent…    |
/// | binary that must not be replaced        | testLinkIntoABuildDirectoryIsNotReplaced, …                     |
final class SelfUpdateGuardTests: XCTestCase {
    // MARK: Fit to build (SU-2, SU-4)

    func testUntrackedSourceFileBlocksTheRebuild() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/Sources/shawn/WIP.swift", "this does not compile yet\n")
        fixture.push("installer/Sources/shawn/main.swift", "print(7)\n")
        let report = await fixture.updater().run(fixture.request())
        let reason = "\(fixture.checkout.path) has untracked files in the Swift package (installer/Sources/shawn/WIP.swift). Commit or remove them"
        XCTAssertEqual(report.outcome, .skipped(reason))
        XCTAssertEqual(report.pulledCommits, 1, "the pull itself was fine")
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertNil(fixture.store.load().failedBuildTree, "the pushed sources are not marked as broken")
        XCTAssertEqual(fixture.installedContents, "old shawn")
        XCTAssertEqual(fixture.notes.all.last, "skipped rebuilding shawn: \(reason)")

        try? FileManager.default.removeItem(at: fixture.checkout.appendingPathComponent("installer/Sources/shawn/WIP.swift"))
        let after = await fixture.updater().run(fixture.request())
        XCTAssertEqual(after.outcome, .rebuilt, "it builds by itself once the file is gone")
    }

    func testUntrackedNewManifestBlocksTheRebuild() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/Package@swift-6.0.swift", "// swift-tools-version: 6.0\n")
        fixture.push("installer/Sources/shawn/main.swift", "print(8)\n")
        let report = await fixture.updater().run(fixture.request())
        guard case .skipped(let reason) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertTrue(reason.contains("installer/Package@swift-6.0.swift"), reason)
        XCTAssertTrue(fixture.builder.builds.isEmpty)
    }

    func testIgnoredFilesInTheSourcesDoNotBlockTheRebuild() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, ".git/info/exclude", ".DS_Store\n")
        fixture.write(fixture.checkout, "installer/Sources/.DS_Store", "finder\n")
        fixture.push("installer/Sources/shawn/main.swift", "print(9)\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .rebuilt, "Finder litter is not work in progress")
    }

    /// HEAD equals the remote, the sources changed since the build, and someone is editing them.
    func testTrackedSourceEditIsNeverBuilt() async {
        let fixture = UpdateFixture()
        fixture.push("installer/Sources/shawn/main.swift", "print(10)\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        fixture.write(fixture.checkout, "installer/Sources/shawn/main.swift", "print(\"my uncommitted edit\")\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("\(fixture.checkout.path) has uncommitted changes"))
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertEqual(fixture.notes.all, ["skipped rebuilding shawn: \(fixture.checkout.path) has uncommitted changes"])

        // The edit can sit there for days: said once a day, and whenever `shawn update` is asked.
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all.count, 1, "not before every command")
        _ = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(fixture.notes.all.count, 2)
        fixture.clock.date = fixture.clock.date.addingTimeInterval(25 * 3600)
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, Array(repeating: "skipped rebuilding shawn: \(fixture.checkout.path) has uncommitted changes", count: 3))
    }

    /// The user discards the edit, but a file they started stays untracked. That reason needs another fix, so it is
    /// said at once. One more untracked file needs the same fix, so it is only a detail line.
    func testAnotherReasonNotToBuildIsSaidAtOnce() async {
        let fixture = UpdateFixture()
        fixture.push("installer/Sources/shawn/main.swift", "print(20)\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        fixture.write(fixture.checkout, "installer/Sources/shawn/main.swift", "print(\"edit\")\n")
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, ["skipped rebuilding shawn: \(fixture.checkout.path) has uncommitted changes"])

        git(["checkout", "--", "installer/Sources/shawn/main.swift"], in: fixture.checkout)
        fixture.write(fixture.checkout, "installer/Sources/shawn/WIP.swift", "wip\n")
        fixture.clock.date += 600
        let report = await fixture.updater().run(fixture.request())
        let reason = "\(fixture.checkout.path) has untracked files in the Swift package (installer/Sources/shawn/WIP.swift). Commit or remove them"
        XCTAssertEqual(report.outcome, .skipped(reason))
        XCTAssertEqual(fixture.notes.all.last, "skipped rebuilding shawn: \(reason)", "\(fixture.notes.all)")

        fixture.write(fixture.checkout, "installer/Sources/shawn/More.swift", "more\n")
        fixture.clock.date += 600
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all.count, 2, "\(fixture.notes.all)")
        XCTAssertTrue(fixture.details.all.contains { $0.contains("installer/Sources/shawn/More.swift") }, "\(fixture.details.all)")
    }

    func testStagedOnlyChangeIsNeverBuilt() async {
        let fixture = UpdateFixture()
        fixture.push("installer/Sources/shawn/main.swift", "print(11)\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        fixture.write(fixture.checkout, "installer/Sources/shawn/New.swift", "let staged = 1\n")
        git(["add", "installer/Sources/shawn/New.swift"], in: fixture.checkout)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("\(fixture.checkout.path) has uncommitted changes"))
        XCTAssertTrue(fixture.builder.builds.isEmpty)
    }

    func testCheckoutInTheMiddleOfAMergeIsLeftAlone() async {
        let fixture = UpdateFixture()
        git(["switch", "-q", "-c", "side"], in: fixture.checkout)
        fixture.write(fixture.checkout, "installer/config/side.yaml", "side: true\n")
        git(["add", "-A"], in: fixture.checkout)
        git(["commit", "-q", "-m", "side"], in: fixture.checkout)
        git(["switch", "-q", "master"], in: fixture.checkout)
        git(["merge", "-q", "--no-ff", "--no-commit", "side"], in: fixture.checkout)
        fixture.push("installer/Sources/shawn/main.swift", "print(12)\n")
        let before = fixture.head(fixture.checkout)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("\(fixture.checkout.path) has uncommitted changes"))
        XCTAssertEqual(fixture.head(fixture.checkout), before)
        XCTAssertTrue(fixture.builder.builds.isEmpty)
    }

    func testDetachedHeadIsSkipped() async {
        let fixture = UpdateFixture()
        git(["switch", "-q", "--detach"], in: fixture.checkout)
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("\(fixture.checkout.path) is on a detached HEAD, not 'master'"))
    }

    // MARK: Unpushed commits

    private func commitInCheckout(_ fixture: UpdateFixture, _ path: String, _ contents: String) {
        fixture.write(fixture.checkout, path, contents)
        git(["add", "-A"], in: fixture.checkout)
        git(["commit", "-q", "-m", "unpushed"], in: fixture.checkout)
    }

    /// Unpushed commits that leave the Swift sources alone: the sources are the remote's, so `--rebuild` rebuilds.
    func testRebuildWithUnpushedCommitsThatLeaveTheSourcesAlone() async {
        let fixture = UpdateFixture()
        commitInCheckout(fixture, "installer/config/mine.yaml", "mine\n")
        let plain = await fixture.updater().run(fixture.request())
        XCTAssertEqual(plain.outcome, .upToDate, "the record matches: nothing to do")
        XCTAssertTrue(fixture.builder.builds.isEmpty)

        let report = await fixture.updater().run(fixture.request(force: true, rebuild: true))
        XCTAssertEqual(report.outcome, .rebuilt)
        XCTAssertEqual(fixture.builder.builds.count, 1)
        XCTAssertEqual(fixture.installedContents, "#!/bin/sh\necho new shawn\n")
        XCTAssertEqual(fixture.store.installedSourceTree(), fixture.contentID(at: fixture.head(fixture.upstream)), "the remote's sources")
    }

    /// Unpushed commits that change the Swift sources are work in progress: never built, said only by `shawn update`.
    func testUnpushedSourceChangesAreNeverBuilt() async {
        let fixture = UpdateFixture()
        commitInCheckout(fixture, "installer/Sources/shawn/main.swift", "print(\"not pushed yet\")\n")
        let reason = "\(fixture.checkout.path) has unpushed commits on master that change the Swift sources; shawn is only rebuilt from "
            + "sources on origin. Push them, then run 'shawn update'"

        let automatic = await fixture.updater().run(fixture.request())
        XCTAssertEqual(automatic.outcome, .skipped(reason))
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertEqual(fixture.notes.all, [], "the developer committing on this Mac is not told on every call")
        XCTAssertTrue(fixture.details.all.contains("the Swift sources changed, but shawn is not rebuilt from unpushed commits."), "\(fixture.details.all)")
        XCTAssertEqual(fixture.installedContents, "old shawn")

        let before = fixture.stateSnapshot()
        let check = await fixture.updater().run(fixture.request(force: true, checkOnly: true))
        XCTAssertEqual(check.outcome, .skipped(reason), "--check says what shawn update does")
        XCTAssertEqual(fixture.stateSnapshot(), before)

        let rebuild = await fixture.updater().run(fixture.request(force: true, rebuild: true))
        XCTAssertEqual(rebuild.outcome, .skipped(reason.replacingOccurrences(of: "'shawn update'", with: "'shawn update --rebuild'")))
        XCTAssertTrue(fixture.builder.builds.isEmpty)

        let harness = fixture.harness()
        let code = await harness.run(["update"])
        XCTAssertEqual(code, ExitCode.failure)
        XCTAssertTrue(harness.out.plain.hasSuffix("! skipped: \(reason)\n"), harness.out.plain)

        git(["push", "-q", "origin", "master"], in: fixture.checkout)
        let pushed = await fixture.updater().run(fixture.request())
        XCTAssertEqual(pushed.outcome, .rebuilt, "once pushed they are the remote's sources")
    }

    /// Nothing records what the binary was built from, and an unpushed commit changes the Swift sources.
    func testUnknownBuildWithUnpushedSourceChangesIsNotCalledUpToDate() async {
        let fixture = UpdateFixture(recorded: false)
        fixture.writeInstallerRecord(sourceTree: nil, commit: nil)
        commitInCheckout(fixture, "installer/Sources/shawn/Extra.swift", "let extra = 1\n")
        let report = await fixture.updater().run(fixture.request(force: true))
        guard case .skipped(let reason) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertTrue(reason.contains("unpushed commits on master that change the Swift sources"), reason)
        XCTAssertEqual(UpdateCommand.summary(of: report).exitCode, ExitCode.failure)
        XCTAssertTrue(fixture.details.all.contains("nothing records which sources this shawn was built from, but shawn is not rebuilt from unpushed commits."),
                      "\(fixture.details.all)")
    }

    /// A binary already built from the checkout's committed sources (an app built on this Mac) needs nothing.
    func testUnpushedSourceChangesAlreadyBuiltAreLeftAlone() async {
        let fixture = UpdateFixture(recorded: false)
        commitInCheckout(fixture, "installer/Sources/shawn/main.swift", "print(\"built here\")\n")
        let head = fixture.head(fixture.checkout)
        fixture.writeInstallerRecord(sourceTree: fixture.contentID(at: head, in: fixture.checkout), commit: head)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .upToDate)
        XCTAssertEqual(fixture.notes.all, [])
        XCTAssertTrue(fixture.builder.builds.isEmpty)
    }

    // MARK: Fast-forward (SU-6, SU-3d)

    func testFastForwardNeverOverwritesAnIgnoredLocalFile() async {
        let fixture = UpdateFixture()
        fixture.push(".gitignore", "*.local\n")
        _ = await fixture.updater().run(fixture.request())
        let path = "installer/config/files/secrets.local"
        fixture.write(fixture.checkout, path, "MY LOCAL WORK\n")
        fixture.write(fixture.upstream, path, "upstream\n")
        git(["add", "-f", path], in: fixture.upstream)
        git(["commit", "-q", "-m", "track it"], in: fixture.upstream)
        git(["push", "-q", "origin", "master"], in: fixture.upstream)

        let report = await fixture.updater().run(fixture.request())
        let reason = "pulling origin/master would overwrite \(path) in \(fixture.checkout.path). Move or remove it, then run 'shawn update'"
        XCTAssertEqual(report.outcome, .skipped(reason))
        XCTAssertEqual(try String(contentsOf: fixture.checkout.appendingPathComponent(path), encoding: .utf8), "MY LOCAL WORK\n")
        XCTAssertEqual(fixture.notes.all.last, "skipped self-update: \(reason)")
    }

    func testUntrackedFileInTheWayIsNamedNotRefetchedAndRecoversByItself() async throws {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/new.yaml", "mine\n")
        fixture.write(fixture.checkout, "installer/config/other.yaml", "mine too\n")
        fixture.write(fixture.upstream, "installer/config/new.yaml", "theirs\n")
        fixture.write(fixture.upstream, "installer/config/other.yaml", "theirs too\n")
        git(["add", "-A"], in: fixture.upstream)
        git(["commit", "-q", "-m", "add files"], in: fixture.upstream)
        git(["push", "-q", "origin", "master"], in: fixture.upstream)
        let recording = RecordingGit(fixture.realGit)

        let first = await fixture.updater(git: recording).run(fixture.request())
        XCTAssertEqual(first.outcome, .skipped("pulling origin/master would overwrite installer/config/new.yaml and installer/config/other.yaml in "
                                               + "\(fixture.checkout.path). Move or remove them, then run 'shawn update'"))
        XCTAssertTrue(recording.subcommands.contains("fetch"))

        recording.reset()
        _ = await fixture.updater(git: recording).run(fixture.request())
        XCTAssertFalse(recording.subcommands.contains("fetch"), "the commits are already here: \(recording.subcommands)")

        try FileManager.default.removeItem(at: fixture.checkout.appendingPathComponent("installer/config/new.yaml"))
        try FileManager.default.removeItem(at: fixture.checkout.appendingPathComponent("installer/config/other.yaml"))
        let recovered = await fixture.updater().run(fixture.request())
        XCTAssertEqual(recovered.outcome, .pulled(commits: 1))
    }

    /// The user moved the file the note named and the pull went through. A later push is blocked by another file, and
    /// the note names it the same day.
    func testAnotherFileInTheWayAfterTheFirstWasMovedIsSaid() async throws {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/new.yaml", "mine\n")
        fixture.push("installer/config/new.yaml", "theirs\n")
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all.last, "skipped self-update: pulling origin/master would overwrite installer/config/new.yaml in "
                       + "\(fixture.checkout.path). Move or remove it, then run 'shawn update'")

        try FileManager.default.removeItem(at: fixture.checkout.appendingPathComponent("installer/config/new.yaml"))
        fixture.clock.date += 3600
        let pulled = await fixture.updater().run(fixture.request())
        XCTAssertEqual(pulled.outcome, .pulled(commits: 1))

        fixture.write(fixture.checkout, "installer/config/other.yaml", "mine\n")
        fixture.push("installer/config/other.yaml", "theirs\n")
        fixture.clock.date += 3600
        let blocked = await fixture.updater().run(fixture.request())
        let reason = "pulling origin/master would overwrite installer/config/other.yaml in \(fixture.checkout.path). Move or remove it, then run 'shawn update'"
        XCTAssertEqual(blocked.outcome, .skipped(reason))
        XCTAssertEqual(fixture.notes.all.last, "skipped self-update: \(reason)", "\(fixture.notes.all)")
    }

    // MARK: Bounded and silent (SU-4)

    /// Through the real process launcher: a remote that never answers costs the user about the ls-remote timeout.
    func testHangingRemoteIsCutOffEndToEnd() async {
        let fixture = UpdateFixture()
        let log = fixture.sandbox.directory.url.appendingPathComponent("ls-remote.log")
        fixture.sandbox.shim("git", """
        if [ "$1" = ls-remote ]; then echo started >> '\(log.path)'; /bin/sleep 10; exit 0; fi
        exec /usr/bin/git "$@"
        """)
        var timeouts = SelfUpdater.Timeouts()
        timeouts.lsRemote = 0.5
        let started = Date()
        let report = await fixture.updater(timeouts: timeouts).run(fixture.request())
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(report.outcome, .offline("no answer within 0.5 seconds"))
        XCTAssertLessThan(elapsed, 3, "a hung remote must not hold the command")
        XCTAssertEqual(fixture.notes.all, [])
        XCTAssertEqual(try? String(contentsOf: log, encoding: .utf8), "started\n", "the shim really ran")
    }

    func testEveryGitCallOnTheHotPathIsBoundedAndOnlyLsRemoteGoesOnline() async {
        let fixture = UpdateFixture()
        let recording = RecordingGit(fixture.realGit)
        let report = await fixture.updater(git: recording).run(fixture.request())
        XCTAssertEqual(report.outcome, .upToDate)
        let calls = recording.calls
        XCTAssertFalse(calls.isEmpty)
        for call in calls {
            XCTAssertNotNil(call.timeout, "unbounded: git \(call.arguments.joined(separator: " "))")
        }
        let network = calls.filter { ["ls-remote", "fetch", "pull", "push", "clone"].contains($0.arguments.first ?? "") }
        XCTAssertEqual(network.map { $0.arguments.first ?? "" }, ["ls-remote"])
        XCTAssertEqual(network.first?.timeout, SelfUpdater.Timeouts().lsRemote)
        XCTAssertEqual(SelfUpdater.Timeouts().lsRemote, 3, "the spec's 3 s")
    }

    // MARK: One updater at a time (SU-7)

    func testAnotherShawnHoldingTheLockMeansNoUpdate() async throws {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let recording = FakeGit()
        do {
            let held = try HeldUpdateLock(fixture.store, activity: "checking")
            let quick = await fixture.updater(git: recording).run(fixture.request())
            XCTAssertEqual(quick.outcome, .skipped("another shawn (pid 4242) is checking for updates"))
            XCTAssertTrue(recording.calls.isEmpty, "no network, no git: \(recording.commandLines)")
            XCTAssertEqual(fixture.notes.all, [], "a quick check in another pane is not worth a line")
            withExtendedLifetime(held) {}
        }
        do {
            let held = try HeldUpdateLock(fixture.store, activity: "rebuilding")
            let slow = await fixture.updater(git: recording).run(fixture.request())
            XCTAssertEqual(slow.outcome, .skipped("another shawn (pid 4242) is rebuilding itself"))
            XCTAssertEqual(fixture.notes.all, ["skipped self-update: another shawn (pid 4242) is rebuilding itself; this run uses the current version"])
            let forced = await fixture.updater(git: recording).run(fixture.request(force: true))
            XCTAssertEqual(forced.outcome, .skipped("another shawn (pid 4242) is rebuilding itself"))
            XCTAssertEqual(fixture.notes.all.last, "skipped self-update: another shawn (pid 4242) is rebuilding itself. Try again when it is done")
            let check = await fixture.updater().run(fixture.request(force: true, checkOnly: true))
            XCTAssertEqual(check.outcome, .updateAvailable("origin/master has new commits (\(fixture.head(fixture.upstream).prefix(7)))"),
                           "--check reads only, so it needs no lock")
            XCTAssertTrue(recording.calls.isEmpty)
            withExtendedLifetime(held) {}
        }
        let free = await fixture.updater().run(fixture.request())
        XCTAssertEqual(free.outcome, .pulled(commits: 1))
        XCTAssertTrue(HeldUpdateLock.isFree(fixture.store), "the lock is let go after the run")
    }

    func testTheLockSaysWhatItsHolderIsDoing() async throws {
        let fixture = UpdateFixture()
        let store = fixture.store
        let seen = Recorder<String>()
        let builder = CallbackBuilder(output: fixture.sandbox.directory.url.appendingPathComponent("built-shawn")) {
            // While building, a second shawn sees the lock held, by whom and why.
            if case .busy(let pid, let activity) = store.lockUpdates() {
                seen.add("busy \(pid.map(String.init) ?? "?") \(activity?.rawValue ?? "?")")
            } else {
                seen.add("free")
            }
        }
        fixture.push("installer/Sources/shawn/main.swift", "print(13)\n")
        let report = await fixture.updater(builder: builder).run(fixture.request())
        XCTAssertEqual(seen.all, ["busy \(getpid()) rebuilding"])
        XCTAssertEqual(report.outcome, .rebuilt)
        XCTAssertTrue(HeldUpdateLock.isFree(fixture.store))
    }

    func testConcurrentUpdatersDoNotRace() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", UpdateFixture.cli + "  c:\n    summary: C\n    run: echo c\n")
        let outcomes = await withTaskGroup(of: SelfUpdater.Outcome.self) { group -> [SelfUpdater.Outcome] in
            for _ in 0..<4 {
                group.addTask { await fixture.updater().run(fixture.request()).outcome }
            }
            var all: [SelfUpdater.Outcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertEqual(outcomes.filter { $0 == .pulled(commits: 1) }.count, 1, "\(outcomes)")
        for outcome in outcomes where outcome != .pulled(commits: 1) {
            switch outcome {
            case .upToDate: break
            case .skipped(let reason) where reason.hasPrefix("another shawn"): break
            default: XCTFail("a concurrent run must step aside, not fail: \(outcome)")
            }
        }
        XCTAssertEqual(fixture.head(fixture.checkout), fixture.head(fixture.upstream))
    }

    // MARK: Binaries that are not replaced in place (SU-10, SU-3a)

    func testLinkIntoABuildDirectoryIsNotReplaced() async throws {
        let fixture = UpdateFixture()
        let target = fixture.sandbox.directory.url.appendingPathComponent("dev/installer/.build/release/shawn")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dev build".utf8).write(to: target)
        let link = fixture.sandbox.directory.url.appendingPathComponent("linkbin/shawn")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let resolved = target.resolvingSymlinksInPath()

        let refusal = BinaryReplacement.refusal(for: link)
        XCTAssertEqual(refusal, "it links to \(resolved.path), which is a development build in \(resolved.deletingLastPathComponent().path)")

        fixture.push("installer/Sources/shawn/main.swift", "print(14)\n")
        let report = await fixture.updater().run(fixture.request(binary: link))
        XCTAssertEqual(report.outcome, .notReplaced("the Swift sources changed, but this shawn is not replaced in place: \(refusal ?? "")"))
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, "the link is untouched")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "dev build")
    }

    func testLinkedInstallIsUpdatedThroughTheLink() async throws {
        let fixture = UpdateFixture()
        let target = fixture.sandbox.directory.url.appendingPathComponent("opt/shawn/bin/shawn")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("linked old shawn".utf8).write(to: target)
        let link = fixture.sandbox.directory.url.appendingPathComponent("linkbin/shawn")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(BinaryReplacement.refusal(for: link))

        fixture.push("installer/Sources/shawn/main.swift", "print(15)\n")
        let report = await fixture.updater().run(fixture.request(binary: link))
        XCTAssertEqual(report.outcome, .rebuilt)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, "still a link, not a copy")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "#!/bin/sh\necho new shawn\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["shawn"])
    }

    func testAppBundleAndUnwritableFolderAreNotReplaced() throws {
        let sandbox = Sandbox()
        let bundled = sandbox.directory.url.appendingPathComponent("Shawn.app/Contents/Helpers/shawn")
        XCTAssertEqual(BinaryReplacement.refusal(for: bundled), "it is inside an app bundle (update the app instead)")
        let locked = sandbox.directory.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("shawn"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(BinaryReplacement.refusal(for: locked.appendingPathComponent("shawn")), "\(locked.path) is not writable")
    }

    func testReleaseArchiveWithoutABinaryOrWithALinkIsNotInstalled() async throws {
        let fixture = UpdateFixture()
        let git = FakeGit()
        git.answer(["ls-remote"], stdout: "abc\trefs/heads/master\n111\trefs/tags/shawn-v1.2.0\n")
        for entries: [String: SelfUpdateTarball.Entry] in [
            ["shawn-1.2.0/README": .executable("no binary here\n")],
            ["shawn-1.2.0/shawn": .link("/bin/sh")],
        ] {
            let data = try SelfUpdateTarball.make(in: fixture.sandbox, entries: entries)
            fixture.releases.payload = data
            fixture.releases.manifest = ReleaseManifest(version: "1.2.0", sha256: Checksum.sha256(data), url: URL(string: "https://example.com/shawn.tar.gz")!)
            let report = await fixture.updater(git: git).run(fixture.request(force: true, withCheckout: false))
            XCTAssertEqual(report.outcome, .installFailed("the release archive has no 'shawn' executable"))
            XCTAssertEqual(fixture.installedContents, "old shawn")
        }
    }

    func testFailedDownloadIsNotRetriedOnEveryCall() async {
        let fixture = UpdateFixture()
        let git = FakeGit()
        git.answer(["ls-remote"], stdout: "abc\trefs/heads/master\n111\trefs/tags/shawn-v1.2.0\n")
        let first = await fixture.updater(git: git).run(fixture.request(withCheckout: false))
        XCTAssertEqual(first.outcome, .downloadFailed("no manifest"))
        let second = await fixture.updater(git: git).run(fixture.request(withCheckout: false))
        XCTAssertEqual(second.outcome, .skipped("the download of shawn 1.2.0 failed less than a day ago"))
        XCTAssertEqual(fixture.notes.all.last, "couldn't download shawn 1.2.0 (no manifest); keeping 1.0.0", "said when it failed, not again on the next call")
        XCTAssertEqual(fixture.details.all.last, "version 1.2.0 is out (you have 1.0.0); the download of shawn 1.2.0 failed less than a day ago. Run 'shawn update' to try again")
        let forced = await fixture.updater(git: git).run(fixture.request(force: true, withCheckout: false))
        XCTAssertEqual(forced.outcome, .downloadFailed("no manifest"), "shawn update tries again")
        fixture.clock.date = fixture.clock.date.addingTimeInterval(25 * 3600)
        let tomorrow = await fixture.updater(git: git).run(fixture.request(withCheckout: false))
        XCTAssertEqual(tomorrow.outcome, .downloadFailed("no manifest"), "and so does the next day")
    }

    /// A failure stored while the clock was a month ahead is tried again, not left alone for a month.
    func testAFailedDownloadStampedInTheFutureIsRetried() async {
        let fixture = UpdateFixture()
        var state = SelfUpdateState()
        state.failedRelease = "shawn-v1.2.0"
        state.failedReleaseAt = fixture.clock.now().addingTimeInterval(30 * 24 * 3600)
        fixture.store.save(state)
        let git = FakeGit()
        git.answer(["ls-remote"], stdout: "abc\trefs/heads/master\n111\trefs/tags/shawn-v1.2.0\n")
        let report = await fixture.updater(git: git).run(fixture.request(withCheckout: false))
        XCTAssertEqual(report.outcome, .downloadFailed("no manifest"))
        XCTAssertEqual(fixture.store.load().failedReleaseAt, fixture.clock.now())
    }

    // MARK: Renamed default branch (SU-5)

    /// GitHub renames master to main; installer.yaml on main says so, but this Mac only reads master.
    private func renameRemoteBranch(_ fixture: UpdateFixture) {
        git(["branch", "-m", "master", "main"], in: fixture.upstream)
        fixture.write(fixture.upstream, "installer/config/installer.yaml", "name: Fixture\nremote:\n  repo: tester/dotfiles\n  branch: main\n")
        git(["add", "-A"], in: fixture.upstream)
        git(["commit", "-q", "-m", "follow main"], in: fixture.upstream)
        git(["push", "-q", "origin", "main"], in: fixture.upstream)
        git(["symbolic-ref", "HEAD", "refs/heads/main"], in: fixture.remote)
        git(["update-ref", "-d", "refs/heads/master"], in: fixture.remote)
    }

    func testRenamedDefaultBranchIsFollowed() async {
        let fixture = UpdateFixture()
        renameRemoteBranch(fixture)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .pulled(commits: 1))
        XCTAssertEqual(git(["symbolic-ref", "--short", "HEAD"], in: fixture.checkout), "main")
        XCTAssertEqual(git(["config", "branch.main.merge"], in: fixture.checkout), "refs/heads/main")
        XCTAssertEqual(git(["config", "branch.main.remote"], in: fixture.checkout), "origin")
        XCTAssertEqual(git(["config", "--get-all", "remote.origin.fetch"], in: fixture.checkout), "+refs/heads/*:refs/remotes/origin/*",
                       "a clone of every branch keeps its fetch list")
        XCTAssertEqual(fixture.head(fixture.checkout), git(["rev-parse", "main"], in: fixture.remote))
        XCTAssertEqual(fixture.notes.all, [
            "origin renamed 'master' to 'main'; renamed the branch in \(fixture.checkout.path) to match",
            "pulled 1 new commit into \(fixture.checkout.path) from origin/main",
            "the setup config changed. Run 'shawn sync' to apply it to this Mac",
        ])

        // The next call reads installer.yaml's new branch and carries on as usual.
        fixture.write(fixture.upstream, "installer/config/cli.yaml", "commands: {}\n")
        git(["commit", "-q", "-am", "more"], in: fixture.upstream)
        git(["push", "-q", "origin", "main"], in: fixture.upstream)
        var request = fixture.request()
        request.remote = RemoteConfigRef(repo: "tester/dotfiles", branch: "main", path: "installer/config")
        let next = await fixture.updater().run(request)
        XCTAssertEqual(next.outcome, .pulled(commits: 1))
    }

    /// A clone of one branch, which is what --depth=1 makes, fetches that branch by name. After the rename its
    /// fetch list asks for the new name, so a plain `git fetch` in the checkout still works. A branch the
    /// person added to the list stays in it.
    func testRenameAlsoMovesAOneBranchFetchList() async {
        let fixture = UpdateFixture()
        git(["push", "-q", "origin", "master:side"], in: fixture.upstream)
        git(["remote", "set-branches", "origin", "master"], in: fixture.checkout)
        git(["remote", "set-branches", "--add", "origin", "side"], in: fixture.checkout)
        renameRemoteBranch(fixture)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .pulled(commits: 1))
        XCTAssertEqual(git(["symbolic-ref", "--short", "HEAD"], in: fixture.checkout), "main")
        XCTAssertEqual(git(["config", "--get-all", "remote.origin.fetch"], in: fixture.checkout),
                       "+refs/heads/main:refs/remotes/origin/main\n+refs/heads/side:refs/remotes/origin/side")
        git(["fetch", "-q"], in: fixture.checkout)
        XCTAssertEqual(git(["rev-parse", "origin/main"], in: fixture.checkout), fixture.head(fixture.checkout),
                       "a plain fetch asks for the branch by its new name")
    }

    func testRenameIsNotForcedOverLocalCommits() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/mine.yaml", "mine\n")
        git(["add", "-A"], in: fixture.checkout)
        git(["commit", "-q", "-m", "unpushed"], in: fixture.checkout)
        renameRemoteBranch(fixture)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("origin's default branch 'main' does not contain the commits on 'master' in \(fixture.checkout.path)"))
        XCTAssertEqual(git(["symbolic-ref", "--short", "HEAD"], in: fixture.checkout), "master", "the branch keeps its name")
    }

    func testMissingBranchIsNotedOnceADay() async {
        let fixture = UpdateFixture()
        git(["symbolic-ref", "HEAD", "refs/heads/gone"], in: fixture.remote)
        git(["update-ref", "-d", "refs/heads/master"], in: fixture.remote)
        let expected = "skipped self-update: origin has no branch 'master'. Set remote.branch in installer.yaml to the branch \(fixture.checkout.path) follows"
        let first = await fixture.updater().run(fixture.request())
        XCTAssertEqual(first.outcome, .skipped("origin has no branch 'master'"))
        let second = await fixture.updater().run(fixture.request())
        XCTAssertEqual(second.outcome, .skipped("origin has no branch 'master'"))
        XCTAssertEqual(fixture.notes.all, [expected], "once, not on every call")
        fixture.clock.date = fixture.clock.date.addingTimeInterval(25 * 3600)
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, [expected, expected], "and again the next day")
    }
}
