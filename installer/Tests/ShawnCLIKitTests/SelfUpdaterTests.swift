import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

/// A GitHub stand-in: a bare repository, a clone where "another Mac" pushes, and this Mac's checkout.
///
/// By default the installed binary comes with the record the installer writes from the app's build-info.json
/// (`sourceTree` and `commit` of the first commit); `recorded: false` leaves cli.json the way an installer
/// without build provenance leaves it.
final class UpdateFixture {
    let sandbox = Sandbox()
    let remote: URL
    let upstream: URL
    let checkout: URL
    let installed: URL
    let store: FileStateStore
    let builder: FakeBuilder
    let releases = FakeReleases()
    let remoteConfig = FakeRemoteConfig()
    let clock = FakeClock()
    let notes = Recorder<String>()
    let details = Recorder<String>()

    static let cli = "commands:\n  hello:\n    summary: Hello\n    run: echo hello\n"
    static let sourcePaths = ["installer/Sources", "installer/Package.swift", "installer/Package.resolved"]

    init(recorded: Bool = true) {
        let root = sandbox.directory.url
        remote = root.appendingPathComponent("remote.git")
        upstream = root.appendingPathComponent("upstream")
        checkout = root.appendingPathComponent("checkout")
        installed = sandbox.installedBinary()
        store = FileStateStore(directory: sandbox.environment.stateDirectory.appendingPathComponent("state"))
        builder = FakeBuilder(output: root.appendingPathComponent("built-shawn"))

        git(["init", "-q", "--bare", "-b", "master", remote.path], in: root)
        git(["clone", "-q", remote.path, upstream.path], in: root)
        write(upstream, "installer/Package.swift", "// swift-tools-version: 6.0\n")
        write(upstream, "installer/Package.resolved", "{}\n")
        write(upstream, "installer/Sources/shawn/main.swift", "print(1)\n")
        write(upstream, "installer/config/installer.yaml", "name: Fixture\nremote:\n  repo: tester/dotfiles\n  branch: master\n")
        write(upstream, "installer/config/steps/01-a.yaml", "id: a\ntitle: A\nitems:\n  - ok: one\n")
        write(upstream, "installer/config/cli.yaml", Self.cli)
        git(["add", "-A"], in: upstream)
        git(["commit", "-q", "-m", "start"], in: upstream)
        git(["push", "-q", "origin", "master"], in: upstream)
        git(["clone", "-q", remote.path, checkout.path], in: root)
        if recorded {
            let start = head(upstream)
            writeInstallerRecord(sourceTree: contentID(at: start), commit: start)
        }
    }

    func write(_ repo: URL, _ path: String, _ contents: String) {
        let url = repo.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: url)
    }

    /// Another Mac commits and pushes.
    func push(_ path: String, _ contents: String, message: String = "change") {
        write(upstream, path, contents)
        git(["add", "-A"], in: upstream)
        git(["commit", "-q", "-m", message], in: upstream)
        git(["push", "-q", "origin", "master"], in: upstream)
    }

    func head(_ repo: URL) -> String { git(["rev-parse", "HEAD"], in: repo) }

    /// The build provenance content id, computed the way the contract spells it out (not through GitRepo).
    func contentID(at revision: String, in repo: URL? = nil) -> String {
        Self.sourcePaths.map { path in
            let id = git(["rev-parse", "-q", "--verify", "\(revision):\(path)"], in: repo ?? upstream, allowFailure: true)
            return id.isEmpty ? "-" : id
        }.joined(separator: ",")
    }

    /// cli.json the way the installer's `shawn-cli` item writes it: no sourceTree when the app had no build-info.json.
    func writeInstallerRecord(sourceTree: String?, commit: String?) {
        var record = ["version": "1.0.0", "installedAt": "2026-01-01T00:00:00Z", "source": "/Volumes/Shawn/ShawnsDotfiles.app/Contents/Helpers/shawn"]
        if let sourceTree { record["sourceTree"] = sourceTree }
        if let commit { record["commit"] = commit }
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try! FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try! data.write(to: store.installFile)
    }

    /// Every file under the state directory with its bytes, to prove a run wrote nothing.
    func stateSnapshot() -> [String: Data] {
        var files: [String: Data] = [:]
        let root = store.directory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            files[name] = FileManager.default.contents(atPath: root.appendingPathComponent(name).path) ?? Data()
        }
        return files
    }

    var realGit: any GitClient { SystemGitClient(launcher: SystemProcessLauncher(), environment: sandbox.environment) }

    /// origin over ssh (as on the Mac shawn is developed on), reached through an ssh that fails with `message`, ending
    /// the line with \r\n the way ssh does: the real git client, never the network.
    func sshGit(failingWith message: String) -> any GitClient {
        let ssh = sandbox.shim("fake-ssh", "printf '%s\\r\\n' '\(message)' >&2; exit 255")
        git(["remote", "set-url", "origin", "git@github.com:tester/dotfiles.git"], in: checkout)
        var environment = sandbox.environment
        environment.baseEnvironment["GIT_SSH_COMMAND"] = ssh.path
        return SystemGitClient(launcher: SystemProcessLauncher(), environment: environment)
    }

    func updater(git: (any GitClient)? = nil, builder: (any Builder)? = nil, timeouts: SelfUpdater.Timeouts = SelfUpdater.Timeouts()) -> SelfUpdater {
        let notes = self.notes, details = self.details
        return SelfUpdater(git: git ?? realGit, builder: builder ?? self.builder, releases: releases, remoteConfig: remoteConfig, clock: clock, store: store,
                           launcher: SystemProcessLauncher(), timeouts: timeouts, note: { notes.add($0) }, detail: { details.add($0) })
    }

    func request(mode: CLIConfig.SelfUpdateMode = .always, force: Bool = false, checkOnly: Bool = false, rebuild: Bool = false,
                 withCheckout: Bool = true, binary: URL? = nil) -> SelfUpdater.Request {
        SelfUpdater.Request(checkout: withCheckout ? checkout : nil, packagePath: "installer",
                            remote: RemoteConfigRef(repo: "tester/dotfiles", branch: "master", path: "installer/config"),
                            installedBinary: binary ?? installed, currentVersion: "1.0.0", home: sandbox.home,
                            temporaryDirectory: sandbox.environment.temporaryDirectory, mode: mode, force: force, checkOnly: checkOnly,
                            rebuild: rebuild)
    }

    /// The whole CLI pointed at this checkout, with this fixture's builder and clock.
    func harness(environment: [String: String] = [:], configPath: String = "installer/config") -> Harness {
        var sandbox = self.sandbox
        for (key, value) in environment { sandbox.environment.baseEnvironment[key] = value }
        write(sandbox.home, ".config/shawn/config.yaml", "dotfiles_repo: \(checkout.path)\nconfig_path: \(configPath)\n")
        return Harness(sandbox: sandbox) { services in
            services.git = self.realGit
            services.builder = self.builder
            services.clock = self.clock
        }
    }

    var installedContents: String { (try? String(contentsOf: installed, encoding: .utf8)) ?? "" }
}

/// git that may fail (`rev-parse --verify` of a missing path); returns "" then.
@discardableResult
func git(_ arguments: [String], in directory: URL, allowFailure: Bool) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return "" }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

final class SelfUpdaterTests: XCTestCase {
    func testRemoteUnchangedDoesNothing() async {
        let fixture = UpdateFixture()
        let before = fixture.head(fixture.checkout)
        let record = try? Data(contentsOf: fixture.store.installFile)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report, SelfUpdater.Report(outcome: .upToDate))
        XCTAssertEqual(fixture.notes.all, [])
        XCTAssertEqual(fixture.head(fixture.checkout), before)
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertEqual(fixture.installedContents, "old shawn")
        XCTAssertNotNil(fixture.store.load().lastCheck)
        XCTAssertEqual(try? Data(contentsOf: fixture.store.installFile), record, "the installer's record is left as it was")
    }

    func testConfigOnlyChangeIsPulledWithoutRebuilding() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", UpdateFixture.cli + "  bye:\n    summary: Bye\n    run: echo bye\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report, SelfUpdater.Report(outcome: .pulled(commits: 1), restartWith: nil, configChanged: true, pulledCommits: 1))
        XCTAssertEqual(fixture.head(fixture.checkout), fixture.head(fixture.upstream))
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertEqual(fixture.installedContents, "old shawn")
        XCTAssertEqual(fixture.notes.all, ["pulled 1 new commit into \(fixture.checkout.path) from origin/master"])
    }

    func testSourceChangeRebuildsSwapsTheBinaryAndAsksForARestart() async throws {
        let fixture = UpdateFixture()
        let builtFrom = fixture.store.installedSourceTree()
        fixture.push("installer/Sources/shawn/main.swift", "print(2)\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .rebuilt)
        XCTAssertEqual(report.restartWith, fixture.installed)
        XCTAssertTrue(report.configChanged)
        XCTAssertEqual(report.pulledCommits, 1)
        XCTAssertEqual(fixture.builder.builds, [fixture.checkout.appendingPathComponent("installer")])
        XCTAssertEqual(fixture.installedContents, "#!/bin/sh\necho new shawn\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fixture.installed.path))
        let newHead = fixture.head(fixture.upstream)
        XCTAssertNotEqual(fixture.store.installedSourceTree(), builtFrom)
        XCTAssertEqual(fixture.store.installedSourceTree(), fixture.contentID(at: newHead), "cli.json records the contract's content id")
        let record = fixture.store.installRecord()
        XCTAssertEqual(record["commit"] as? String, newHead)
        XCTAssertNil(record["version"], "the installer's version described the binary that was replaced")
        XCTAssertEqual(record["source"] as? String, fixture.builder.output.path, "where the new binary came from")
        XCTAssertEqual(record["installedAt"] as? String, "2026-01-01T00:00:00Z", "the rest of the installer's record is kept")
        XCTAssertEqual(fixture.notes.all.last, "rebuilt at \(newHead.prefix(7)). Restarting with the new version")
        // Nothing left behind next to the binary.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.installed.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["shawn"])
    }

    func testPackageResolvedChangeAlsoRebuilds() async {
        let fixture = UpdateFixture()
        fixture.push("installer/Package.resolved", "{\"pins\": []}\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .rebuilt)
    }

    func testManualPullStillTriggersTheRebuild() async {
        let fixture = UpdateFixture()
        fixture.push("installer/Sources/shawn/main.swift", "print(3)\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .rebuilt)
        XCTAssertEqual(report.pulledCommits, 0)
    }

    func testDirtyCheckoutIsSkippedWithANote() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/cli.yaml", "# editing\n")
        let quiet = await fixture.updater().run(fixture.request())
        XCTAssertEqual(quiet.outcome, .upToDate, "nothing to pull: no note while the user works")
        XCTAssertEqual(fixture.notes.all, [])

        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A2\nitems: []\n")
        let before = fixture.head(fixture.checkout)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("\(fixture.checkout.path) has uncommitted changes"))
        XCTAssertEqual(fixture.head(fixture.checkout), before)
        XCTAssertEqual(fixture.notes.all, ["skipped self-update: \(fixture.checkout.path) has uncommitted changes"])
    }

    /// The check runs before every command, and a reason like this lasts until the user does something about the
    /// checkout. Before, the same line was printed on every call.
    func testAStandingReasonToSkipIsSaidOnceADay() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/cli.yaml", "# editing\n")
        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A2\nitems: []\n")
        let uncommitted = "skipped self-update: \(fixture.checkout.path) has uncommitted changes"
        for _ in 0..<3 {
            let report = await fixture.updater().run(fixture.request())
            XCTAssertEqual(report.outcome, .skipped("\(fixture.checkout.path) has uncommitted changes"), "the outcome is the same every time")
        }
        XCTAssertEqual(fixture.notes.all, [uncommitted], "said once, not before every command")
        XCTAssertEqual(fixture.details.all.filter { $0 == uncommitted }.count, 2, "the later calls still say it to whoever asks for details")
        XCTAssertNotNil(fixture.store.load().noted?["skipped-uncommitted"])

        // A different kind of reason is news, and is said at once.
        git(["switch", "-q", "-c", "side"], in: fixture.checkout)
        let otherBranch = "skipped self-update: \(fixture.checkout.path) is on 'side', not 'master'"
        _ = await fixture.updater().run(fixture.request())
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, [uncommitted, otherBranch])

        // `shawn update --check` and `shawn update` always say it, and --check does not count as having said it.
        let checked = await fixture.updater().run(fixture.request(force: true, checkOnly: true))
        XCTAssertEqual(checked.outcome, .skipped("\(fixture.checkout.path) is on 'side', not 'master'"))
        _ = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(fixture.notes.all, [uncommitted, otherBranch, otherBranch, otherBranch])

        fixture.clock.date = fixture.clock.date.addingTimeInterval(25 * 3600)
        _ = await fixture.updater().run(fixture.request())
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all.count, 5, "and once more the next day")
        XCTAssertEqual(fixture.notes.all.last, otherBranch)
    }

    /// 9:00 the checkout has an edit when commits arrive (said). 10:00 the edit is gone and the next command pulls.
    /// 14:00 the user edits again and new commits arrive. Held back by a reason that started after the last one ended,
    /// they are news, not something said this morning.
    func testAReasonThatWentAwayAndCameBackIsSaidAgain() async {
        let fixture = UpdateFixture()
        let uncommitted = "skipped self-update: \(fixture.checkout.path) has uncommitted changes"
        fixture.write(fixture.checkout, "installer/config/cli.yaml", "# editing\n")
        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A2\nitems: []\n")
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, [uncommitted])

        git(["checkout", "--", "installer/config/cli.yaml"], in: fixture.checkout)
        fixture.clock.date += 3600
        let pulled = await fixture.updater().run(fixture.request())
        XCTAssertEqual(pulled.outcome, .pulled(commits: 1), "the reason went away")
        XCTAssertNil(fixture.store.load().noted?["skipped-uncommitted"], "and its note with it")

        fixture.write(fixture.checkout, "installer/config/cli.yaml", "# editing again\n")
        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A3\nitems: []\n")
        fixture.clock.date += 4 * 3600
        let held = await fixture.updater().run(fixture.request())
        XCTAssertEqual(held.outcome, .skipped("\(fixture.checkout.path) has uncommitted changes"))
        XCTAssertEqual(fixture.notes.all.last, uncommitted, "\(fixture.notes.all)")
    }

    /// A check that fails never gets to the other reasons, so it does not count as their going away. When the remote
    /// answers again, the reason still standing is not said a second time that day.
    func testAFailedCheckLeavesTheOtherNotesAsTheyWere() async {
        let fixture = UpdateFixture()
        let uncommitted = "skipped self-update: \(fixture.checkout.path) has uncommitted changes"
        fixture.write(fixture.checkout, "installer/config/cli.yaml", "# editing\n")
        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A2\nitems: []\n")
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, [uncommitted])

        let nowhere = fixture.sandbox.directory.url.appendingPathComponent("nowhere.git").path
        git(["remote", "set-url", "origin", nowhere], in: fixture.checkout)
        let failed = await fixture.updater().run(fixture.request())
        guard case .checkFailed = failed.outcome else { return XCTFail("\(failed.outcome)") }
        XCTAssertEqual(fixture.notes.all.count, 2)

        git(["remote", "set-url", "origin", fixture.remote.path], in: fixture.checkout)
        let held = await fixture.updater().run(fixture.request())
        XCTAssertEqual(held.outcome, .skipped("\(fixture.checkout.path) has uncommitted changes"))
        XCTAssertEqual(fixture.notes.all.count, 2, "said this morning, and still the same reason: \(fixture.notes.all)")
        XCTAssertEqual(fixture.details.all.filter { $0 == uncommitted }.count, 1, "a detail line instead")
    }

    /// A note stored while the clock was a month ahead (a date set by hand, then corrected) does not silence the reason
    /// until the clock gets there.
    func testANoteStampedInTheFutureIsSaidAgain() async {
        let fixture = UpdateFixture()
        let uncommitted = "skipped self-update: \(fixture.checkout.path) has uncommitted changes"
        var state = SelfUpdateState()
        state.noted = ["skipped-uncommitted": .init(reason: uncommitted, at: fixture.clock.now().addingTimeInterval(30 * 24 * 3600))]
        fixture.store.save(state)
        fixture.write(fixture.checkout, "installer/config/cli.yaml", "# editing\n")
        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A2\nitems: []\n")
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, [uncommitted])
        XCTAssertEqual(fixture.store.load().noted?["skipped-uncommitted"]?.at, fixture.clock.now(), "stamped with the right time now")
    }

    /// The reason a fetch fails is git's, and curl puts a number of milliseconds in it that differs on every call. The
    /// same cause with another number is not news. Another cause is.
    func testAFetchThatKeepsFailingForTheSameCauseIsSaidOnce() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let recording = RecordingGit(fixture.realGit)
        func failing(after milliseconds: Int) -> String {
            "fatal: unable to access 'https://github.com/tester/dotfiles.git/': Failed to connect to github.com port 443 after \(milliseconds) ms: "
                + "Couldn't connect to server"
        }
        recording.fail("fetch", exit: 128, stderr: failing(after: 3001) + "\n")
        let first = await fixture.updater(git: recording).run(fixture.request())
        XCTAssertEqual(first.outcome, .fetchFailed(failing(after: 3001)))
        recording.fail("fetch", exit: 128, stderr: failing(after: 2999) + "\n")
        fixture.clock.date += 600
        _ = await fixture.updater(git: recording).run(fixture.request())
        XCTAssertEqual(fixture.notes.all, ["couldn't fetch origin/master: \(failing(after: 3001))"])
        XCTAssertTrue(fixture.details.all.contains("couldn't fetch origin/master: \(failing(after: 2999))"), "\(fixture.details.all)")

        let refused = "remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/tester/dotfiles.git/'"
        recording.fail("fetch", exit: 128, stderr: refused + "\n")
        fixture.clock.date += 600
        _ = await fixture.updater(git: recording).run(fixture.request())
        XCTAssertEqual(fixture.notes.all.last, "couldn't fetch origin/master: remote: Invalid username or password. "
                       + "fatal: Authentication failed for 'https://github.com/tester/dotfiles.git/'")
        XCTAssertEqual(SelfUpdater.stablePart("after 3001 ms from 140.82.112.4 port 22"), "after # ms from #.#.#.# port #")
    }

    /// New commands in cli.yaml work from the next call on. Steps and files only describe this Mac once applied.
    func testAPullThatChangesTheSetupPointsAtSync() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        fixture.push("installer/config/fun/quotes.yaml", "quotes: []\n")
        fixture.push("README.md", "docs\n")
        let commandsOnly = await fixture.updater().run(fixture.request())
        XCTAssertEqual(commandsOnly.outcome, .pulled(commits: 3))
        XCTAssertEqual(fixture.notes.all, ["pulled 3 new commits into \(fixture.checkout.path) from origin/master"],
                       "commands, quotes and files outside the config need no sync")

        fixture.push("installer/config/files/zsh/zshrc", "export EDITOR=nvim\n")
        let setup = await fixture.updater().run(fixture.request())
        XCTAssertEqual(setup.outcome, .pulled(commits: 1))
        XCTAssertEqual(Array(fixture.notes.all.suffix(2)), [
            "pulled 1 new commit into \(fixture.checkout.path) from origin/master",
            "the setup config changed. Run 'shawn sync' to apply it to this Mac",
        ])
    }

    func testUntrackedFilesOutsideTheSourcesDoNotBlockTheUpdate() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "scratch.txt", "mine\n")
        fixture.write(fixture.checkout, "installer/config/notes.md", "mine\n")
        fixture.push("installer/Sources/shawn/main.swift", "print(\"elsewhere\")\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .rebuilt, "only untracked files in the Swift package keep it from being built")
        XCTAssertEqual(report.pulledCommits, 1)
    }

    func testOtherBranchIsSkipped() async {
        let fixture = UpdateFixture()
        git(["switch", "-q", "-c", "feature"], in: fixture.checkout)
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("\(fixture.checkout.path) is on 'feature', not 'master'"))
        XCTAssertEqual(fixture.notes.all, ["skipped self-update: \(fixture.checkout.path) is on 'feature', not 'master'"])
    }

    func testUnpushedCommitsAreSkipped() async {
        let fixture = UpdateFixture()
        fixture.write(fixture.checkout, "installer/config/mine.txt", "local\n")
        git(["add", "-A"], in: fixture.checkout)
        git(["commit", "-q", "-m", "local work"], in: fixture.checkout)
        let ahead = await fixture.updater().run(fixture.request())
        XCTAssertEqual(ahead.outcome, .upToDate, "only ahead: nothing to pull, nothing said")
        XCTAssertEqual(fixture.notes.all, [])

        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let before = fixture.head(fixture.checkout)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .skipped("local commits on master are not on origin yet"))
        XCTAssertEqual(fixture.head(fixture.checkout), before)
    }

    /// No network: ssh cannot even look the host up.
    func testOfflineIsSilent() async {
        let fixture = UpdateFixture()
        let offline = fixture.sshGit(failingWith: "ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known")
        let report = await fixture.updater(git: offline).run(fixture.request())
        XCTAssertEqual(report.outcome, .offline("ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known; "
                                                + "fatal: Could not read from remote repository."), "git's own reason is kept for 'shawn update'")
        XCTAssertEqual(fixture.notes.all, [])
        XCTAssertNil(fixture.store.load().lastCheck, "a failed check does not count as a check")
        XCTAssertNil(fixture.store.load().noted)
    }

    /// A remote that is not there is not "offline": waiting does not bring it back, so it is said, once a day.
    func testAMissingRemoteRepositoryIsSaidOnceADay() async {
        let fixture = UpdateFixture()
        let nowhere = fixture.sandbox.directory.url.appendingPathComponent("nowhere.git").path
        git(["remote", "set-url", "origin", nowhere], in: fixture.checkout)
        let expected = "couldn't check origin for updates: fatal: '\(nowhere)' does not appear to be a git repository. "
            + "'git ls-remote origin' must work in \(fixture.checkout.path) without a prompt"
        let first = await fixture.updater().run(fixture.request())
        XCTAssertEqual(first.outcome, .checkFailed(expected))
        XCTAssertNil(fixture.store.load().lastCheck, "a failed check does not count as a check")
        let second = await fixture.updater().run(fixture.request())
        XCTAssertEqual(second.outcome, .checkFailed(expected))
        XCTAssertEqual(fixture.notes.all, [expected], "once, not on every call")
        XCTAssertEqual(fixture.details.all.last, expected)

        fixture.clock.date = fixture.clock.date.addingTimeInterval(25 * 3600)
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, [expected, expected], "and again the next day")
        let forced = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(UpdateCommand.summary(of: forced), UpdateCommand.Summary(mark: .failed, text: expected, exitCode: ExitCode.failure))
        XCTAssertEqual(fixture.notes.all.count, 3, "`shawn update` always says it")
    }

    /// The remote path was wrong (said). The user fixes it, and now the ssh key is refused. That reason needs another
    /// fix, so it is said at once.
    func testANewReasonTheCheckFailsForIsSaid() async {
        let fixture = UpdateFixture()
        let nowhere = fixture.sandbox.directory.url.appendingPathComponent("nowhere.git").path
        git(["remote", "set-url", "origin", nowhere], in: fixture.checkout)
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all.count, 1)

        let refused = fixture.sshGit(failingWith: "git@github.com: Permission denied (publickey).")
        fixture.clock.date += 600
        let report = await fixture.updater(git: refused).run(fixture.request())
        guard case .checkFailed(let reason) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertTrue(reason.contains("Permission denied (publickey)"), reason)
        XCTAssertEqual(fixture.notes.all.last, reason, "\(fixture.notes.all)")
        _ = await fixture.updater(git: refused).run(fixture.request())
        XCTAssertEqual(fixture.notes.all.count, 2, "and then once a day, like the first")
    }

    func testSlowRemoteTimesOutQuicklyAndSilently() async {
        let fixture = UpdateFixture()
        let slow = FakeGit()
        slow.answer(["symbolic-ref"], stdout: "master")
        slow.delay = 5
        slow.slow = ["ls-remote"]
        var timeouts = SelfUpdater.Timeouts()
        timeouts.lsRemote = 0.3
        let started = Date()
        let report = await fixture.updater(git: slow, timeouts: timeouts).run(fixture.request())
        XCTAssertEqual(report.outcome, .offline("no answer within 0.3 seconds"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(fixture.notes.all, [])
    }

    func testBuildFailureKeepsTheOldBinaryAndIsNotRetriedEveryTime() async {
        let fixture = UpdateFixture()
        fixture.builder.fail = "error: cannot find 'x' in scope"
        fixture.push("installer/Sources/shawn/main.swift", "x\n")
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .buildFailed("error: cannot find 'x' in scope"))
        XCTAssertNil(report.restartWith)
        XCTAssertEqual(fixture.installedContents, "old shawn")
        XCTAssertTrue(fixture.notes.all.contains("couldn't rebuild shawn (error: cannot find 'x' in scope); keeping the current version"), "\(fixture.notes.all)")
        XCTAssertNotNil(fixture.store.load().failedBuildTree)

        let again = await fixture.updater().run(fixture.request())
        XCTAssertEqual(again.outcome, .buildFailed("the last rebuild of these sources failed"))
        XCTAssertEqual(fixture.builder.builds.count, 1, "the same broken sources are not rebuilt on every call")
        XCTAssertEqual(fixture.notes.all.last, "the Swift sources changed, but the last rebuild failed. Run 'shawn update' to try again")

        fixture.builder.fail = nil
        let forced = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(forced.outcome, .rebuilt, "`shawn update` retries")
        XCTAssertNil(fixture.store.load().failedBuildTree)
    }

    func testDevelopmentBuildsAreNotReplaced() async {
        let fixture = UpdateFixture()
        let devBinary = fixture.sandbox.directory.url.appendingPathComponent("repo/.build/debug/shawn")
        try! FileManager.default.createDirectory(at: devBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("dev".utf8).write(to: devBinary)
        fixture.push("installer/Sources/shawn/main.swift", "print(4)\n")
        let report = await fixture.updater().run(fixture.request(binary: devBinary))
        XCTAssertEqual(report.outcome, .notReplaced("the Swift sources changed, but this shawn is not replaced in place: "
                                                    + "it is a development build in \(devBinary.deletingLastPathComponent().path)"))
        XCTAssertEqual(report.pulledCommits, 1)
        XCTAssertNil(report.restartWith)
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertEqual(fixture.notes.all, ["pulled 1 new commit into \(fixture.checkout.path) from origin/master"],
                       "a developer running their own build is not nagged on every call")
    }

    func testCheckOnlyReportsWithoutPullingOrWriting() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let before = fixture.head(fixture.checkout)
        let state = fixture.stateSnapshot()
        let report = await fixture.updater().run(fixture.request(force: true, checkOnly: true))
        XCTAssertEqual(report.outcome, .updateAvailable("origin/master has new commits (\(fixture.head(fixture.upstream).prefix(7)))"))
        XCTAssertEqual(fixture.head(fixture.checkout), before)
        XCTAssertEqual(fixture.stateSnapshot(), state, "--check writes no state, no record and no lock file")
    }

    func testNewerReleaseTagIsAlwaysMentioned() async {
        let fixture = UpdateFixture()
        git(["tag", "shawn-v1.0.0"], in: fixture.upstream)
        git(["tag", "shawn-v1.10.0"], in: fixture.upstream)
        git(["tag", "shawn-v1.9.0"], in: fixture.upstream)
        git(["push", "-q", "origin", "--tags"], in: fixture.upstream)
        let report = await fixture.updater().run(fixture.request())
        XCTAssertEqual(report.outcome, .upToDate)
        XCTAssertEqual(fixture.notes.all, ["version 1.10.0 is out (you have 1.0.0)"])
        XCTAssertEqual(fixture.store.load().latestTag, "shawn-v1.10.0")

        // While it lasts it is said once a day, and whenever `shawn update` is asked.
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all.count, 1, "not before every command")
        _ = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(fixture.notes.all.count, 2)
        fixture.clock.date = fixture.clock.date.addingTimeInterval(25 * 3600)
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, Array(repeating: "version 1.10.0 is out (you have 1.0.0)", count: 3))
    }

    /// 1.1.0 was mentioned this morning, and 2.0.0 is published an hour later.
    func testANewerReleaseThanTheOneMentionedIsSaidTheSameDay() async {
        let fixture = UpdateFixture()
        git(["tag", "shawn-v1.1.0"], in: fixture.upstream)
        git(["push", "-q", "origin", "--tags"], in: fixture.upstream)
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, ["version 1.1.0 is out (you have 1.0.0)"])

        git(["tag", "shawn-v2.0.0"], in: fixture.upstream)
        git(["push", "-q", "origin", "--tags"], in: fixture.upstream)
        fixture.clock.date += 3600
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, ["version 1.1.0 is out (you have 1.0.0)", "version 2.0.0 is out (you have 1.0.0)"])
    }

    /// A run that restarts into a rebuilt shawn says nothing about the release, and does not count as its going away.
    func testARebuildDoesNotRepeatTheReleaseNote() async {
        let fixture = UpdateFixture()
        git(["tag", "shawn-v1.1.0"], in: fixture.upstream)
        git(["push", "-q", "origin", "--tags"], in: fixture.upstream)
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all, ["version 1.1.0 is out (you have 1.0.0)"])

        fixture.push("installer/Sources/shawn/main.swift", "print(30)\n")
        let rebuilt = await fixture.updater().run(fixture.request())
        XCTAssertEqual(rebuilt.outcome, .rebuilt)
        XCTAssertNotNil(fixture.store.load().noted?["release-out"])
        _ = await fixture.updater().run(fixture.request())
        XCTAssertEqual(fixture.notes.all.filter { $0.hasPrefix("version") }, ["version 1.1.0 is out (you have 1.0.0)"], "\(fixture.notes.all)")
    }

    func testDailyAndOffModes() async {
        let fixture = UpdateFixture()
        let recording = FakeGit()
        var state = SelfUpdateState()
        state.lastCheck = fixture.clock.now().addingTimeInterval(-3600)
        fixture.store.save(state)
        let daily = await fixture.updater(git: recording).run(fixture.request(mode: .daily))
        XCTAssertEqual(daily.outcome, .notDue)
        XCTAssertTrue(recording.calls.isEmpty)

        state.lastCheck = fixture.clock.now().addingTimeInterval(-25 * 3600)
        fixture.store.save(state)
        let due = await fixture.updater().run(fixture.request(mode: .daily))
        XCTAssertEqual(due.outcome, .upToDate)
        XCTAssertEqual(fixture.store.load().lastCheck, fixture.clock.now())

        let off = await fixture.updater(git: recording).run(fixture.request(mode: .off))
        XCTAssertEqual(off.outcome, .disabled)
        XCTAssertTrue(recording.calls.isEmpty)
        let forced = await fixture.updater().run(fixture.request(mode: .off, force: true))
        XCTAssertEqual(forced.outcome, .upToDate, "`shawn update` works even with mode: off")
    }

    /// A last check stored while the clock was a month ahead does not stop the daily update for a month.
    func testDailyModeWithALastCheckInTheFutureStillChecks() async {
        let fixture = UpdateFixture()
        var state = SelfUpdateState()
        state.lastCheck = fixture.clock.now().addingTimeInterval(30 * 24 * 3600)
        fixture.store.save(state)
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let report = await fixture.updater().run(fixture.request(mode: .daily))
        XCTAssertEqual(report.outcome, .pulled(commits: 1))
        XCTAssertEqual(fixture.store.load().lastCheck, fixture.clock.now())
    }

    func testCheckDoesNotPostponeTheDailyUpdate() async {
        let fixture = UpdateFixture()
        var state = SelfUpdateState()
        state.lastCheck = fixture.clock.now().addingTimeInterval(-25 * 3600)
        fixture.store.save(state)
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        _ = await fixture.updater().run(fixture.request(force: true, checkOnly: true))
        let due = await fixture.updater().run(fixture.request(mode: .daily))
        XCTAssertEqual(due.outcome, .pulled(commits: 1), "a --check is not the daily update")
    }

    // MARK: No checkout: releases

    private func releaseGit(tag: String = "shawn-v1.2.0", head: String = "abc1234def") -> FakeGit {
        let fake = FakeGit()
        fake.answer(["ls-remote"], stdout: "ref: refs/heads/master\tHEAD\n\(head)\tHEAD\n\(head)\trefs/heads/master\n1111\trefs/tags/\(tag)\n2222\trefs/tags/\(tag)^{}\n")
        return fake
    }

    func testReleaseIsDownloadedVerifiedAndSwappedIn() async {
        let fixture = UpdateFixture()
        let binary = Data("#!/bin/sh\necho released\n".utf8)
        fixture.releases.payload = binary
        fixture.releases.manifest = ReleaseManifest(version: "1.2.0", sha256: Checksum.sha256(binary), url: URL(string: "https://example.com/shawn.tar.gz")!)
        let git = releaseGit()
        let report = await fixture.updater(git: git).run(fixture.request(withCheckout: false))
        XCTAssertEqual(report.outcome, .releaseInstalled("1.2.0"))
        XCTAssertEqual(report.restartWith, fixture.installed)
        XCTAssertEqual(fixture.installedContents, "#!/bin/sh\necho released\n")
        let record = fixture.store.installRecord()
        XCTAssertEqual(record["version"] as? String, "1.2.0")
        XCTAssertEqual(record["source"] as? String, "https://example.com/shawn.tar.gz", "where the new binary came from")
        let written = (try? String(contentsOf: fixture.store.installFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(written.contains("\"https://example.com/shawn.tar.gz\""), "addresses and paths are written as they are, without \\/: \(written)")
        XCTAssertNil(record["sourceTree"], "the old binary's sourceTree does not describe the release")
        XCTAssertNil(record["commit"])
        XCTAssertEqual(git.calls.first, ["ls-remote", "--symref", "https://github.com/tester/dotfiles.git", "HEAD", "refs/heads/master", "refs/tags/shawn-v*"])
        XCTAssertEqual(fixture.notes.all.last, "updated shawn 1.0.0 → 1.2.0. Restarting with the new version")
    }

    func testReleaseTarballIsUnpacked() async throws {
        let fixture = UpdateFixture()
        let data = try SelfUpdateTarball.make(in: fixture.sandbox, entries: ["shawn-1.2.0/shawn": .executable("#!/bin/sh\necho from tarball\n")])
        fixture.releases.payload = data
        fixture.releases.manifest = ReleaseManifest(version: "1.2.0", sha256: Checksum.sha256(data), url: URL(string: "https://example.com/shawn.tar.gz")!)
        let report = await fixture.updater(git: releaseGit()).run(fixture.request(withCheckout: false))
        XCTAssertEqual(report.outcome, .releaseInstalled("1.2.0"))
        XCTAssertEqual(fixture.installedContents, "#!/bin/sh\necho from tarball\n")
    }

    func testBadChecksumIsRejected() async {
        let fixture = UpdateFixture()
        fixture.releases.payload = Data("tampered".utf8)
        fixture.releases.manifest = ReleaseManifest(version: "1.2.0", sha256: String(repeating: "ab", count: 32), url: URL(string: "https://example.com/x")!)
        let report = await fixture.updater(git: releaseGit()).run(fixture.request(withCheckout: false))
        guard case .releaseRejected(let reason) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertTrue(reason.hasPrefix("checksum mismatch"))
        XCTAssertNil(report.restartWith)
        XCTAssertEqual(fixture.installedContents, "old shawn")
        XCTAssertTrue(fixture.notes.all.last?.hasPrefix("rejected shawn 1.2.0: checksum mismatch") ?? false, "\(fixture.notes.all)")
    }

    func testAReleaseThatNeedsANewerMacOSIsLeftAlone() async {
        func run(onMacOS major: Int, _ name: String) async -> (SelfUpdater.Report, UpdateFixture) {
            let fixture = UpdateFixture()
            let binary = Data("#!/bin/sh\necho released\n".utf8)
            fixture.releases.payload = binary
            fixture.releases.manifest = ReleaseManifest(version: "1.2.0", sha256: Checksum.sha256(binary), url: URL(string: "https://example.com/shawn.tar.gz")!,
                                                        minimumMacOS: 28)
            var request = fixture.request(withCheckout: false)
            request.macOSMajor = major
            request.macOSName = name
            return (await fixture.updater(git: releaseGit()).run(request), fixture)
        }

        let (older, olderFixture) = await run(onMacOS: 27, "27.2")
        XCTAssertEqual(older.outcome, .skipped("shawn 1.2.0 needs macOS 28 or later, and this Mac runs macOS 27.2"))
        XCTAssertNil(older.restartWith)
        XCTAssertEqual(olderFixture.installedContents, "old shawn", "the shawn that works stays")
        XCTAssertTrue(olderFixture.releases.downloads.isEmpty, "the manifest says enough; the tarball is not fetched")
        XCTAssertEqual(olderFixture.notes.all.last, "shawn 1.2.0 needs macOS 28 or later, and this Mac runs macOS 27.2; keeping 1.0.0")
        XCTAssertEqual(UpdateCommand.summary(of: older).text, "skipped: shawn 1.2.0 needs macOS 28 or later, and this Mac runs macOS 27.2")

        let (same, sameFixture) = await run(onMacOS: 28, "28.0")
        XCTAssertEqual(same.outcome, .releaseInstalled("1.2.0"), "the minimum itself is new enough")
        XCTAssertEqual(sameFixture.installedContents, "#!/bin/sh\necho released\n")
    }

    func testTheManifestMayNameTheMacOSItNeeds() throws {
        let with = try ReleaseManifest.parse(Data(#"{"version": "1.2.0", "sha256": "AB", "url": "https://example.com/x", "minimumMacOS": 27}"#.utf8))
        XCTAssertEqual(with.minimumMacOS, 27)
        let without = try ReleaseManifest.parse(Data(#"{"version": "1.2.0", "sha256": "AB", "url": "https://example.com/x"}"#.utf8))
        XCTAssertNil(without.minimumMacOS, "a release made before the field existed is installed as before")
    }

    func testReleaseCheckOnlyAndNotNewer() async {
        let fixture = UpdateFixture()
        let check = await fixture.updater(git: releaseGit()).run(fixture.request(checkOnly: true, withCheckout: false))
        XCTAssertEqual(check.outcome, .updateAvailable("shawn 1.2.0"))
        XCTAssertTrue(fixture.releases.downloads.isEmpty)
        XCTAssertEqual(fixture.notes.all, ["version 1.2.0 is out (you have 1.0.0). Run 'shawn update'"])

        let same = await fixture.updater(git: releaseGit(tag: "shawn-v1.0.0")).run(fixture.request(withCheckout: false))
        XCTAssertEqual(same.outcome, .upToDate)
    }

    func testOfflineWithoutCheckoutIsSilent() async {
        let fixture = UpdateFixture()
        let offline = FakeGit()
        let message = "fatal: unable to access 'https://github.com/tester/dotfiles.git/': Could not resolve host: github.com"
        offline.answer(["ls-remote"], exit: 128, stderr: message + "\n")
        let report = await fixture.updater(git: offline).run(fixture.request(withCheckout: false))
        XCTAssertEqual(report.outcome, .offline(message))
        XCTAssertEqual(fixture.notes.all, [])
    }

    /// GitHub answers an anonymous request for a private, renamed or misspelled repository by asking for a password.
    func testARepositoryGitHubWillNotServeIsSaidWithoutACheckout() async {
        let fixture = UpdateFixture()
        let refused = FakeGit()
        refused.answer(["ls-remote"], exit: 128, stderr: "fatal: could not read Username for 'https://github.com': terminal prompts disabled\n")
        let report = await fixture.updater(git: refused).run(fixture.request(withCheckout: false))
        let expected = "couldn't check tester/dotfiles on GitHub for updates: fatal: could not read Username for 'https://github.com': terminal prompts disabled"
            + ". 'git ls-remote https://github.com/tester/dotfiles.git' must work without a prompt (remote.repo in installer.yaml must name a public repository)"
        XCTAssertEqual(report.outcome, .checkFailed(expected))
        XCTAssertEqual(fixture.notes.all, [expected])
        XCTAssertNotNil(fixture.store.load().noted?["check-failed"])
    }

    func testNewConfigIsFetchedWhenTheBranchMovesWithoutACheckout() async {
        let fixture = UpdateFixture()
        fixture.remoteConfig.root = fixture.sandbox.directory.url.appendingPathComponent("cache/config/abc")
        let first = await fixture.updater(git: releaseGit(tag: "shawn-v1.0.0")).run(fixture.request(withCheckout: false))
        XCTAssertTrue(first.configChanged)
        XCTAssertEqual(fixture.remoteConfig.refreshes, 1)
        XCTAssertEqual(fixture.store.load().remoteConfigRoot, fixture.remoteConfig.root?.path)
        let second = await fixture.updater(git: releaseGit(tag: "shawn-v1.0.0")).run(fixture.request(withCheckout: false))
        XCTAssertFalse(second.configChanged)
        XCTAssertEqual(fixture.remoteConfig.refreshes, 1, "same commit: nothing fetched again")
        XCTAssertEqual(fixture.notes.all, ["picked up the latest config (abc1234). 'shawn sync' applies setup changes to this Mac"])

        // Before `shawn sync` the pointer to it would only repeat what the command is about to do.
        var syncing = fixture.request(withCheckout: false)
        syncing.appliesSetup = true
        _ = await fixture.updater(git: releaseGit(tag: "shawn-v1.0.0", head: "def5678abc")).run(syncing)
        XCTAssertEqual(fixture.notes.all.last, "picked up the latest config (def5678)")
    }

    /// The branch also moves for commits that leave the config alone (the Brewfile job's, say). The cache holds one
    /// copy per commit, so the new copy is compared with the one before: the same files are not news.
    func testABranchThatMovedWithoutChangingTheConfigIsNotNews() async throws {
        let fixture = UpdateFixture()
        func cached(_ commit: String, steps: String) throws -> URL {
            let root = fixture.sandbox.directory.url.appendingPathComponent("cache/config/\(commit)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("steps"), withIntermediateDirectories: true)
            try Data("name: Fixture\n".utf8).write(to: root.appendingPathComponent("installer.yaml"))
            try Data(steps.utf8).write(to: root.appendingPathComponent("steps/01-a.yaml"))
            return root
        }
        let steps = "id: a\ntitle: A\nitems: []\n"
        fixture.remoteConfig.root = try cached("aaa", steps: steps)
        _ = await fixture.updater(git: releaseGit(tag: "shawn-v1.0.0", head: "aaa1111aaa")).run(fixture.request(withCheckout: false))
        XCTAssertEqual(fixture.notes.all.count, 1, "the first copy is news")

        fixture.remoteConfig.root = try cached("bbb", steps: steps)
        let same = await fixture.updater(git: releaseGit(tag: "shawn-v1.0.0", head: "bbb2222bbb")).run(fixture.request(withCheckout: false))
        XCTAssertFalse(same.configChanged)
        XCTAssertEqual(fixture.notes.all.count, 1, "nothing in the config changed: nothing is said")
        XCTAssertEqual(fixture.details.all.filter { $0.contains("its config did not change") }.count, 1)
        XCTAssertEqual(fixture.store.load().remoteConfigRoot, fixture.remoteConfig.root?.path, "the newer copy is the one in use")
        XCTAssertEqual(fixture.store.load().lastRemoteCommit, "bbb2222bbb")

        fixture.remoteConfig.root = try cached("ccc", steps: "id: a\ntitle: A2\nitems: []\n")
        let changed = await fixture.updater(git: releaseGit(tag: "shawn-v1.0.0", head: "ccc3333ccc")).run(fixture.request(withCheckout: false))
        XCTAssertTrue(changed.configChanged)
        XCTAssertEqual(fixture.notes.all.last, "picked up the latest config (ccc3333). 'shawn sync' applies setup changes to this Mac")
    }

    func testSwiftBuilderRunsTheReleaseBuildAndFindsTheProduct() async throws {
        let sandbox = Sandbox()
        let package = sandbox.directory.url.appendingPathComponent("installer")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let log = sandbox.directory.url.appendingPathComponent("swift.log")
        sandbox.shim("swift", """
        echo "$PWD :: $*" >> '\(log.path)'
        case "$*" in
          *--show-bin-path*) echo "Another instance of SwiftPM (PID: 1) is already running, waiting..."; echo "$PWD/.build/release" ;;
          "build -c release --product shawn")
            [ -f FAIL ] && { echo "error: no such module 'Yams'" >&2; exit 1; }
            [ -f NOBINARY ] && exit 0
            mkdir -p .build/release && printf '#!/bin/sh\\necho built\\n' > .build/release/shawn && chmod +x .build/release/shawn ;;
        esac
        """)
        let builder = SwiftBuilder(launcher: SystemProcessLauncher(), environment: sandbox.environment)
        let built = try await builder.build(package: package, product: "shawn", timeout: 30).get()
        // The shell reports /private/tmp where Foundation says /tmp.
        func normal(_ text: String) -> String { text.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") }
        XCTAssertEqual(normal(built.path), normal(package.appendingPathComponent(".build/release/shawn").path))
        XCTAssertEqual(normal(try String(contentsOf: log, encoding: .utf8)), """
        \(package.path) :: build -c release --product shawn
        \(package.path) :: build -c release --product shawn --show-bin-path

        """)

        try FileManager.default.removeItem(at: package.appendingPathComponent(".build"))
        try Data().write(to: package.appendingPathComponent("FAIL"))
        let failed = await builder.build(package: package, product: "shawn", timeout: 30)
        XCTAssertEqual(failed, .failure(BuildFailure(message: "error: no such module 'Yams'")))

        try FileManager.default.removeItem(at: package.appendingPathComponent("FAIL"))
        try Data().write(to: package.appendingPathComponent("NOBINARY"))
        guard case .failure(let missing) = await builder.build(package: package, product: "shawn", timeout: 30) else { return XCTFail("expected a failure") }
        XCTAssertTrue(missing.message.hasPrefix("the build finished but shawn was not found"), missing.message)
    }

    func testVersionComparison() {
        XCTAssertTrue(VersionNumber.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(VersionNumber.isNewer("2", than: "1.99"))
        XCTAssertFalse(VersionNumber.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(VersionNumber.isNewer("1.0.0-beta", than: "1.0.0"))
        XCTAssertEqual(VersionNumber.fromTag("refs/tags/shawn-v1.2.3"), "1.2.3")
        XCTAssertNil(VersionNumber.fromTag("refs/tags/shawn-v1.2.3^{}"))
        XCTAssertNil(VersionNumber.fromTag("refs/tags/v1.2.3"))
        XCTAssertNil(VersionNumber.fromTag("refs/tags/shawn-vnext"))
    }
}

/// The whole loop through the dispatcher, as the user sees it.
final class SelfUpdateDispatchTests: XCTestCase {
    /// Requirement 19: a command added on another Mac works here on the very next call.
    func testANewCommandFromAnotherMacRunsOnTheNextCall() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", UpdateFixture.cli + "  fresh:\n    summary: Added elsewhere\n    run: echo fresh \"$@\"\n")
        let harness = fixture.harness()
        let code = await harness.run(["fresh", "a"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.replacer.last?.argv, ["bash", "-c", "echo fresh \"$@\"", "shawn fresh", "a"])
        XCTAssertTrue(harness.err.plain.contains("shawn: pulled 1 new commit into"), harness.err.plain)
    }

    func testChangedSourcesRestartTheNewBinaryWithTheSameArguments() async throws {
        let fixture = UpdateFixture()
        fixture.push("installer/Sources/shawn/main.swift", "print(5)\n")
        let harness = fixture.harness()
        let code = await harness.run(["hello", "x"])
        XCTAssertEqual(code, 0)
        let restart = try XCTUnwrap(harness.replacer.requests.first)
        XCTAssertEqual(restart.path, harness.context.shawnBinary.path)
        XCTAssertEqual(restart.argv, [harness.context.shawnBinary.path, "hello", "x"])
        XCTAssertEqual(restart.environment[SelfUpdateRunner.reexecMarker], "1")
        XCTAssertEqual(harness.replacer.requests.count, 1, "after the restart request nothing else runs in this process")
    }

    func testTheRestartedProcessDoesNotUpdateAgain() async {
        let fixture = UpdateFixture()
        let recording = FakeGit()
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let harness = fixture.harness(environment: [SelfUpdateRunner.reexecMarker: "1"])
        harness.context.services.git = recording
        _ = await harness.run(["hello"])
        XCTAssertTrue(recording.calls.isEmpty)
        XCTAssertNil(harness.replacer.last?.environment[SelfUpdateRunner.reexecMarker], "children never inherit the loop marker")
    }

    func testFailedBuildStillRunsTheCommand() async {
        let fixture = UpdateFixture()
        fixture.builder.fail = "boom"
        fixture.push("installer/Sources/shawn/main.swift", "print(6)\n")
        let harness = fixture.harness()
        let code = await harness.run(["hello"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.replacer.last?.argv.prefix(3), ["bash", "-c", "echo hello"])
        XCTAssertTrue(harness.err.plain.contains("couldn't rebuild shawn (boom); keeping the current version"), harness.err.plain)
    }

    /// `shawn sync` updates first and then applies the config it just pulled. Telling it to run 'shawn sync' would be
    /// wrong. A dry run or a part of the steps still gets the pointer.
    func testShawnSyncIsNotToldToRunShawnSync() async {
        let fixture = UpdateFixture()
        let hint = "the setup config changed. Run 'shawn sync' to apply it to this Mac"
        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A2\nitems:\n  - ok: two\n")
        let harness = fixture.harness()
        let code = await harness.run(["sync", "--yes", "--no-remote"])
        XCTAssertEqual(code, 0, harness.err.plain + harness.out.plain)
        XCTAssertTrue(harness.err.plain.contains("pulled 1 new commit"), harness.err.plain)
        XCTAssertTrue(harness.out.plain.contains("two"), "sync applied the pulled step: \(harness.out.plain)")
        XCTAssertFalse(harness.err.plain.contains(hint), harness.err.plain)

        fixture.push("installer/config/steps/01-a.yaml", "id: a\ntitle: A3\nitems:\n  - ok: three\n")
        let dryRun = fixture.harness()
        _ = await dryRun.run(["sync", "--dry-run", "--no-remote"])
        XCTAssertTrue(dryRun.err.plain.contains(hint), dryRun.err.plain)
    }

    func testOnlyAWholeSyncAppliesTheSetup() {
        let environment: [String: String] = [:]
        for arguments in [["sync"], ["install", "--yes"], ["sync", "-y", "--no-remote", "--fresh"], ["--no-color", "sync"]] {
            XCTAssertTrue(SelfUpdateRunner.appliesSetup(arguments, environment: environment), "\(arguments)")
        }
        let partly = [["sync", "--dry-run"], ["sync", "-n"], ["sync", "--only", "apps"], ["sync", "--skip=apps"], ["sync", "--config", "/tmp/x"],
                      ["--config", "/tmp/x", "sync"], ["sync", "--help"], ["--help", "sync"], ["sync", "extra"], ["sync", "--bogus"],
                      ["hello"], ["update"], []]
        for arguments in partly {
            XCTAssertFalse(SelfUpdateRunner.appliesSetup(arguments, environment: environment), "\(arguments)")
        }
    }

    /// config_path can name any folder in the checkout (installer.yaml's remote.path), not only one called config.
    func testTheSyncHintFollowsTheConfiguredConfigFolder() async {
        let fixture = UpdateFixture()
        git(["mv", "installer/config", "installer/setup"], in: fixture.upstream)
        git(["commit", "-q", "-m", "move the config"], in: fixture.upstream)
        git(["push", "-q", "origin", "master"], in: fixture.upstream)
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        fixture.push("installer/setup/steps/01-a.yaml", "id: a\ntitle: A2\nitems: []\n")
        let harness = fixture.harness(configPath: "installer/setup")
        _ = await harness.run(["hello"])
        XCTAssertTrue(harness.err.plain.contains("pulled 1 new commit"), harness.err.plain)
        XCTAssertTrue(harness.err.plain.contains("the setup config changed. Run 'shawn sync' to apply it to this Mac"), harness.err.plain)

        fixture.push("installer/setup/cli.yaml", UpdateFixture.cli + "  bye:\n    summary: Bye\n    run: echo bye\n")
        let commands = fixture.harness(configPath: "installer/setup/")
        _ = await commands.run(["hello"])
        XCTAssertTrue(commands.err.plain.contains("pulled 1 new commit"), commands.err.plain)
        XCTAssertFalse(commands.err.plain.contains("Run 'shawn sync'"), "only the commands changed: \(commands.err.plain)")
        XCTAssertEqual(SelfUpdater.setupPaths(config: "installer/setup/"),
                       ["installer/setup", ":(exclude)installer/setup/cli.yaml", ":(exclude)installer/setup/fun"])
    }

    func testUpdateCommandIsVerbose() async {
        let fixture = UpdateFixture()
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let harness = fixture.harness()
        let code = await harness.run(["update"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(harness.out.plain.contains("pulled 1 commit; shawn itself did not change"), harness.out.plain)
        XCTAssertTrue(harness.err.plain.contains("checking origin/master and shawn releases…"), harness.err.plain)
        XCTAssertTrue(harness.replacer.requests.isEmpty, "shawn update never restarts itself")

        let check = fixture.harness()
        let checkCode = await check.run(["update", "--check"])
        XCTAssertEqual(checkCode, 0)
        XCTAssertTrue(check.out.plain.hasSuffix("✓ up to date\n"), check.out.plain)
    }

    func testVersionShowsTheLastCheck() async {
        let fixture = UpdateFixture()
        let harness = fixture.harness()
        _ = await harness.run(["version"])
        let text = harness.out.plain
        XCTAssertTrue(text.hasPrefix("shawn \(ShawnCore.version)\n"), text)
        XCTAssertTrue(text.contains("checkout"), text)
        XCTAssertTrue(text.contains("just now · up to date"), text)
    }
}
