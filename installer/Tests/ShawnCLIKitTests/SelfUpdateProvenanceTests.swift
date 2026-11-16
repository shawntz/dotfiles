import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

/// SU-1: the build provenance contract. A binary nobody recorded the sources of is never assumed to be
/// built from whatever the checkout holds now.
final class SelfUpdateProvenanceTests: XCTestCase {
    /// A new Mac: the app (built at "start") installs its shawn, the checkout is cloned at a later commit
    /// whose Swift sources differ, and cli.json has no sourceTree.
    private func newMac() -> UpdateFixture {
        let fixture = UpdateFixture(recorded: false)
        fixture.push("installer/Sources/shawn/main.swift", "print(\"master\")\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        fixture.writeInstallerRecord(sourceTree: nil, commit: nil)
        return fixture
    }

    func testCheckReportsAnUnknownBuildAndWritesNothing() async {
        let fixture = newMac()
        let before = fixture.stateSnapshot()
        let report = await fixture.updater().run(fixture.request(force: true, checkOnly: true))
        let head = fixture.head(fixture.checkout)
        XCTAssertEqual(report.outcome, .updateAvailable("a rebuild of shawn at \(head.prefix(7)) (nothing records which sources this shawn was built from)"))
        XCTAssertEqual(fixture.stateSnapshot(), before, "cli.json is byte-identical and nothing else was written")
        XCTAssertTrue(fixture.builder.builds.isEmpty)
    }

    func testUnknownBuildIsRebuiltOnceThenRecorded() async {
        let fixture = newMac()
        let automatic = await fixture.updater().run(fixture.request())
        XCTAssertEqual(automatic.outcome, .rebuilt)
        XCTAssertEqual(fixture.builder.builds.count, 1)
        XCTAssertEqual(fixture.installedContents, "#!/bin/sh\necho new shawn\n")
        let head = fixture.head(fixture.checkout)
        XCTAssertEqual(fixture.store.installedSourceTree(), fixture.contentID(at: head))
        XCTAssertEqual(fixture.store.installRecord()["commit"] as? String, head)
        XCTAssertTrue(fixture.notes.all.contains("nothing records which sources this shawn was built from. Rebuilding shawn (swift build, about a minute)…"),
                      "\(fixture.notes.all)")

        let next = await fixture.updater().run(fixture.request())
        XCTAssertEqual(next.outcome, .upToDate)
        XCTAssertEqual(fixture.builder.builds.count, 1, "once")
    }

    func testShawnUpdateRebuildsAnUnknownBuild() async {
        let fixture = newMac()
        let forced = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(forced.outcome, .rebuilt)
        XCTAssertEqual(fixture.notes.all.last, "rebuilt at \(fixture.head(fixture.checkout).prefix(7))")
    }

    /// The new Mac, plus an unpushed commit that leaves the Swift sources alone: still rebuilt, never "up to date".
    func testUnknownBuildWithAnUnpushedConfigCommitIsRebuilt() async {
        let fixture = newMac()
        fixture.write(fixture.checkout, "installer/config/mine.yaml", "mine\n")
        git(["add", "-A"], in: fixture.checkout)
        git(["commit", "-q", "-m", "unpushed"], in: fixture.checkout)
        let report = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(report.outcome, .rebuilt)
        XCTAssertEqual(UpdateCommand.summary(of: report), UpdateCommand.Summary(mark: .done, text: "rebuilt shawn from the sources in the checkout", exitCode: ExitCode.ok))
        XCTAssertEqual(fixture.builder.builds.count, 1)
        XCTAssertEqual(fixture.store.installedSourceTree(), fixture.contentID(at: fixture.head(fixture.upstream)), "the remote's sources")
    }

    /// The old pre-pull adoption: an unknown build whose sources the run cannot rebuild must still be unknown
    /// afterward, not recorded as the pre-pull (or post-pull) HEAD.
    func testAPullNeverRecordsTheCheckoutAsTheBaseline() async {
        let fixture = UpdateFixture(recorded: false)
        fixture.writeInstallerRecord(sourceTree: nil, commit: nil)
        let devBinary = fixture.sandbox.directory.url.appendingPathComponent("repo/.build/release/shawn")
        try! FileManager.default.createDirectory(at: devBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("dev".utf8).write(to: devBinary)
        fixture.push("installer/config/cli.yaml", "commands: {}\n")
        let report = await fixture.updater().run(fixture.request(binary: devBinary))
        guard case .notReplaced = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertEqual(report.pulledCommits, 1)
        XCTAssertNil(fixture.store.installedSourceTree(), "no sourceTree was made up")
        XCTAssertNil(fixture.store.installRecord()["commit"])
    }

    func testTheTagOfTheRunningVersionIsTheBaseline() async {
        let fixture = UpdateFixture(recorded: false)
        fixture.writeInstallerRecord(sourceTree: nil, commit: nil)
        git(["tag", "shawn-v1.0.0"], in: fixture.checkout)
        let record = try? Data(contentsOf: fixture.store.installFile)
        let same = await fixture.updater().run(fixture.request())
        XCTAssertEqual(same.outcome, .upToDate, "the sources at shawn-v1.0.0 are the ones checked out")
        XCTAssertTrue(fixture.builder.builds.isEmpty)
        XCTAssertEqual(try? Data(contentsOf: fixture.store.installFile), record, "a baseline derived from the tag is not written down")

        fixture.push("installer/Sources/shawn/main.swift", "print(\"after the release\")\n")
        let changed = await fixture.updater().run(fixture.request())
        XCTAssertEqual(changed.outcome, .rebuilt)
        XCTAssertEqual(fixture.store.installedSourceTree(), fixture.contentID(at: fixture.head(fixture.upstream)))
    }

    func testFailedBuildThenAnInstallerRecordIsRetriedByShawnUpdate() async {
        let fixture = UpdateFixture()
        fixture.builder.fail = "boom"
        fixture.push("installer/Sources/shawn/main.swift", "print(\"T2\")\n")
        let failed = await fixture.updater().run(fixture.request())
        XCTAssertEqual(failed.outcome, .buildFailed("boom"))
        // `shawn install` rewrites cli.json (its config mirror changed) without build provenance.
        fixture.writeInstallerRecord(sourceTree: nil, commit: nil)
        fixture.builder.fail = nil

        let automatic = await fixture.updater().run(fixture.request())
        XCTAssertEqual(automatic.outcome, .buildFailed("the last rebuild of these sources failed"), "not retried on every call")
        XCTAssertEqual(fixture.notes.all.last, "nothing records which sources this shawn was built from, but the last rebuild failed. Run 'shawn update' to try again")
        let forced = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(forced.outcome, .rebuilt)
        XCTAssertEqual(fixture.builder.builds.count, 2)
        XCTAssertEqual(fixture.installedContents, "#!/bin/sh\necho new shawn\n")
    }

    func testRebuildRepairsAWrongBaseline() async {
        // A record that claims the current sources although the binary is older (an earlier shawn adopted HEAD).
        let fixture = UpdateFixture(recorded: false)
        fixture.push("installer/Sources/shawn/main.swift", "print(\"M\")\n")
        git(["pull", "-q", "--ff-only"], in: fixture.checkout)
        let head = fixture.head(fixture.checkout)
        fixture.writeInstallerRecord(sourceTree: fixture.contentID(at: head), commit: head)
        let plain = await fixture.updater().run(fixture.request(force: true))
        XCTAssertEqual(plain.outcome, .upToDate)

        let check = await fixture.updater().run(fixture.request(force: true, checkOnly: true, rebuild: true))
        XCTAssertEqual(check.outcome, .updateAvailable("a rebuild of shawn at \(head.prefix(7)) (a rebuild was asked for)"))
        let rebuilt = await fixture.updater().run(fixture.request(force: true, rebuild: true))
        XCTAssertEqual(rebuilt.outcome, .rebuilt)
        XCTAssertEqual(fixture.installedContents, "#!/bin/sh\necho new shawn\n")

        let harness = fixture.harness()
        let code = await harness.run(["update", "--rebuild"])
        XCTAssertEqual(code, 0, harness.out.plain + harness.err.plain)
        XCTAssertTrue(harness.out.plain.hasSuffix("✓ rebuilt shawn from the sources in the checkout\n"), harness.out.plain)
    }

    func testRebuildWithoutACheckoutIsAUsageError() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, meta: "name: T\nremote:\n  repo: tester/dotfiles\n  branch: master\n", steps: [:], cli: "commands: {}\n")
        let harness = Harness(sandbox: sandbox, config: config)
        let code = await harness.run(["update", "--rebuild"])
        XCTAssertEqual(code, ExitCode.usage)
        XCTAssertTrue(harness.err.plain.contains("shawn update --rebuild: there is no dotfiles checkout to build from (set dotfiles_repo in ~/.config/shawn/config.yaml)"),
                      harness.err.plain)
    }

    /// The content id must be exactly what scripts/build-app.sh and scripts/release.sh compute.
    func testContentIDFollowsTheContract() async {
        let fixture = UpdateFixture()
        let repo = GitRepo(root: fixture.checkout, git: fixture.realGit)
        let head = fixture.head(fixture.checkout)
        let sources = git(["rev-parse", "HEAD:installer/Sources"], in: fixture.checkout)
        let manifest = git(["rev-parse", "HEAD:installer/Package.swift"], in: fixture.checkout)
        let resolved = git(["rev-parse", "HEAD:installer/Package.resolved"], in: fixture.checkout)
        let id = await repo.contentID(of: UpdateFixture.sourcePaths, at: head)
        XCTAssertEqual(id, "\(sources),\(manifest),\(resolved)")

        git(["rm", "-q", "installer/Package.resolved"], in: fixture.checkout)
        git(["commit", "-q", "-m", "no lock file"], in: fixture.checkout)
        let withoutResolved = await repo.contentID(of: UpdateFixture.sourcePaths, at: "HEAD")
        XCTAssertEqual(withoutResolved, "\(sources),\(manifest),-")

        // A package at the root of its repository: no prefix.
        let standalone = fixture.sandbox.directory.url.appendingPathComponent("standalone")
        fixture.write(standalone, "Package.swift", "// swift-tools-version: 6.0\n")
        fixture.write(standalone, "Sources/tool/main.swift", "print(0)\n")
        git(["init", "-q", standalone.path], in: fixture.sandbox.directory.url)
        git(["add", "-A"], in: standalone)
        git(["commit", "-q", "-m", "root package"], in: standalone)
        let rootID = await GitRepo(root: standalone, git: fixture.realGit).contentID(of: SelfUpdater.sourcePaths, at: "HEAD")
        XCTAssertEqual(rootID, "\(git(["rev-parse", "HEAD:Sources"], in: standalone)),\(git(["rev-parse", "HEAD:Package.swift"], in: standalone)),-")
    }

    func testAReleaseRecordsTheManifestsSourceTree() async {
        let fixture = UpdateFixture()
        let binary = Data("#!/bin/sh\necho released\n".utf8)
        fixture.releases.payload = binary
        fixture.releases.manifest = ReleaseManifest(version: "1.2.0", sha256: Checksum.sha256(binary), url: URL(string: "https://example.com/shawn")!,
                                                    sourceTree: "aaa,bbb,ccc", commit: "c0ffee")
        let git = FakeGit()
        git.answer(["ls-remote"], stdout: "abc\trefs/heads/master\n111\trefs/tags/shawn-v1.2.0\n")
        let report = await fixture.updater(git: git).run(fixture.request(withCheckout: false))
        XCTAssertEqual(report.outcome, .releaseInstalled("1.2.0"))
        XCTAssertEqual(fixture.store.installedSourceTree(), "aaa,bbb,ccc")
        XCTAssertEqual(fixture.store.installRecord()["commit"] as? String, "c0ffee")
    }

    func testManifestParsing() throws {
        let full = try ReleaseManifest.parse(Data(#"{"version":"1.2.0","tag":"shawn-v1.2.0","url":"https://x/y.tar.gz","sha256":"ABC","sourceTree":"a,b,c"}"#.utf8))
        XCTAssertEqual(full, ReleaseManifest(version: "1.2.0", sha256: "abc", url: URL(string: "https://x/y.tar.gz")!, sourceTree: "a,b,c"))
        XCTAssertEqual(full.provenance, .known(sourceTree: "a,b,c", commit: nil))
        let empty = try ReleaseManifest.parse(Data(#"{"version":"1.2.0","url":"https://x/y","sha256":"abc","sourceTree":""}"#.utf8))
        XCTAssertEqual(empty.provenance, .unknown, "an empty sourceTree means the release does not know")
        XCTAssertThrowsError(try ReleaseManifest.parse(Data(#"{"version":"1.2.0"}"#.utf8)))
    }

    func testEmptySourceTreeInCliJsonIsUnknown() {
        let fixture = UpdateFixture(recorded: false)
        fixture.writeInstallerRecord(sourceTree: "", commit: "")
        XCTAssertNil(fixture.store.installedSourceTree())
    }
}
