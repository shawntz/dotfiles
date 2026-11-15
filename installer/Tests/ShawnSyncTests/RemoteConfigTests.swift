import Foundation
import XCTest
import ShawnCore
@testable import ShawnSync

final class RemoteConfigTests: XCTestCase {
    private var temp: TempDirectory!
    private var environment: SystemEnvironment!
    private var local: ResolvedConfig!
    private var remote: RemoteConfigRef!
    private var transport: FakeTransport!

    override func setUpWithError() throws {
        temp = TempDirectory()
        environment = SystemEnvironment.testSandbox(temp)
        local = try loadLocal(writeConfig(in: temp, at: "local"), environment: environment)
        remote = try XCTUnwrap(local.config.meta.remote)
        transport = FakeTransport()
    }

    override func tearDown() {
        temp = nil
    }

    private var cacheRoot: URL { RemoteConfig.cacheRoot(environment: environment) }

    private func upgrade(timeout: TimeInterval = 5, ref: String? = nil, remote: RemoteConfigRef? = nil,
                         using transport: (any HTTPTransport)? = nil) async -> ResolvedConfig {
        await RemoteConfig.upgrade(local: local, remote: remote ?? self.remote,
                                   options: ConfigResolveOptions(remoteRef: ref, remoteTimeout: timeout),
                                   registry: testRegistry(), environment: environment, transport: transport ?? self.transport)
    }

    private func cacheEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []).sorted()
    }

    private func assertFellBack(_ result: ResolvedConfig, mentioning fragments: [String],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.config.source, local.config.source, "expected the local config", file: file, line: line)
        XCTAssertEqual(result.config.meta.name, "Local Dotfiles", file: file, line: line)
        guard let note = result.notes.last else {
            return XCTFail("expected a note explaining the fallback", file: file, line: line)
        }
        for fragment in fragments {
            XCTAssertTrue(note.contains(fragment), "note \"\(note)\" should mention \"\(fragment)\"", file: file, line: line)
        }
    }

    // MARK: Success and cache

    func testFetchesTheRemoteConfigPinnedToItsCommit() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)

        let result = await upgrade()

        XCTAssertEqual(result.config.source, .remote(repo: "octo/dots", ref: "main", commit: repo.commit))
        XCTAssertEqual(result.config.meta.name, "Remote Dotfiles")
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.plan.allItems.map(\.title), ["remote thing", "hello"])
        let root = cacheRoot.appendingPathComponent(repo.commit)
        XCTAssertEqual(result.config.root.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        for relative in ["installer.yaml", "steps/01-base.yaml", "steps/02-more.yaml", "files/bin/hello.sh", "files/readme with spaces.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path), relative)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("files/bin/hello.sh"), encoding: .utf8), "#!/bin/sh\necho hi\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path), "files outside the config path are not fetched")
        XCTAssertEqual(cacheEntries().filter { $0.hasPrefix(ConfigCache.stagingPrefix) }, [], "no staging directory is left behind")

        let requests = transport.requests
        XCTAssertEqual(requests.first?.url.absoluteString, repo.commitURL + "main")
        XCTAssertEqual(requests.first?.headers["Accept"], "application/vnd.github.sha")
        XCTAssertEqual(requests.dropFirst().first?.url.absoluteString, repo.treeURL)
        let raw = requests.dropFirst(2).map(\.url.absoluteString).sorted()
        XCTAssertEqual(raw, repo.files.filter { $0.path.hasPrefix("installer/config/") }.map { repo.rawURL($0.path) }.sorted())
        XCTAssertTrue(raw.allSatisfy { $0.contains("/\(repo.commit)/") }, "raw downloads are pinned to the commit")
        XCTAssertTrue(raw.contains("https://raw.githubusercontent.com/octo/dots/\(repo.commit)/installer/config/files/readme%20with%20spaces.txt"))
        for request in requests {
            XCTAssertNil(request.headers["Authorization"])
            XCTAssertNil(request.headers["Cookie"])
        }
    }

    func testExecutableBitsAreRestoredFromTheTreeModes() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)

        let result = await upgrade()

        let root = result.config.root
        XCTAssertEqual(permissions(of: root.appendingPathComponent("files/bin/hello.sh")), 0o755)
        XCTAssertEqual(permissions(of: root.appendingPathComponent("files/readme with spaces.txt")), 0o644)
        XCTAssertEqual(permissions(of: root.appendingPathComponent("installer.yaml")), 0o644)
    }

    func testAFetchIntoASandboxUnderPrivateUsesGitHubsConfig() async throws {
        // `--sandbox /private/tmp/sb`, or a relative `--sandbox sb` typed from a folder under /tmp: the
        // sandbox (and so the cache) did not exist at launch and is named with its /private prefix.
        let physical = TempDirectory("shawn-sync José it's", underPrivate: true)
        XCTAssertTrue(physical.url.path.hasPrefix("/private/"), physical.url.path)
        let environment = SystemEnvironment.testSandbox(physical)
        let local = try loadLocal(writeConfig(in: physical, at: "local"), environment: environment)
        let repo = FakeRepo.standard()
        repo.serve(on: transport)

        let result = await RemoteConfig.upgrade(local: local, remote: remote, options: ConfigResolveOptions(remoteTimeout: 5),
                                                registry: testRegistry(), environment: environment, transport: transport)

        XCTAssertEqual(result.config.source, .remote(repo: "octo/dots", ref: "main", commit: repo.commit),
                       result.notes.joined(separator: "\n"))
        XCTAssertEqual(result.notes, [])
        let root = RemoteConfig.cacheRoot(environment: environment).appendingPathComponent(repo.commit)
        XCTAssertTrue(root.path.hasPrefix("/private/"), root.path)
        for relative in ["installer.yaml", "steps/01-base.yaml", "steps/02-more.yaml", "files/bin/hello.sh", "files/readme with spaces.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path), relative)
        }
        let script = root.appendingPathComponent("files/bin/hello.sh").path
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testSecondCallReusesTheCacheAfterOnlyTheRefLookup() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        _ = await upgrade()
        transport.clearRequests()

        let again = await upgrade()

        XCTAssertEqual(again.config.source, .remote(repo: "octo/dots", ref: "main", commit: repo.commit))
        XCTAssertEqual(transport.urls, [repo.commitURL + "main"], "only the ref is resolved; nothing is downloaded")
        XCTAssertEqual(transport.requests.first?.headers["If-None-Match"], "\"\(repo.commit)\"",
                       "the ref lookup is conditional, so an unchanged ref is answered with an empty 304 "
                       + "(which still counts against the unauthenticated rate limit)")
    }

    func testAConditionalRefLookupCanStillBeRateLimited() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        _ = await upgrade()
        let reset = Date(timeIntervalSinceNow: 1_800)
        // Unauthenticated 304s count against the 60-an-hour limit, so the conditional lookup can be refused too.
        transport.set(repo.commitURL + "main", .text(#"{"message":"API rate limit exceeded for 203.0.113.9."}"#, status: 403, headers: [
            "X-RateLimit-Limit": "60", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970)),
        ]))
        transport.clearRequests()

        let result = await upgrade()

        XCTAssertEqual(transport.requests.map { $0.headers["If-None-Match"] }, ["\"\(repo.commit)\""])
        let expectedTime = RemoteConfigError.clockTime(Date(timeIntervalSince1970: TimeInterval(Int(reset.timeIntervalSince1970))))
        assertFellBack(result, mentioning: ["rate limit", "resets at \(expectedTime)"])
    }

    func testANewCommitIsDownloadedNextToTheOldOne() async throws {
        FakeRepo.standard().serve(on: transport)
        _ = await upgrade()
        let newer = FakeRepo.standard(commit: FakeRepo.commitSHA("second"), name: "Newer Dotfiles")
        newer.serve(on: transport)

        let result = await upgrade()

        XCTAssertEqual(result.config.meta.name, "Newer Dotfiles")
        XCTAssertEqual(result.config.source, .remote(repo: "octo/dots", ref: "main", commit: newer.commit))
        XCTAssertEqual(Set(cacheEntries()).subtracting([ConfigCache.refsFileName]), [FakeRepo.commitSHA("first"), newer.commit])
    }

    func testRemoteRefOverridesTheBranch() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport, ref: "release/v2")

        let result = await upgrade(ref: "release/v2")

        XCTAssertEqual(result.config.source, .remote(repo: "octo/dots", ref: "release/v2", commit: repo.commit))
        XCTAssertEqual(transport.urls.first, repo.commitURL + "release/v2")
    }

    func testAFullCommitRefNeedsNoRequestOnceCached() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        _ = await upgrade()
        transport.clearRequests()

        let result = await upgrade(ref: repo.commit.uppercased())

        XCTAssertEqual(result.config.source, .remote(repo: "octo/dots", ref: repo.commit.uppercased(), commit: repo.commit))
        XCTAssertEqual(transport.urls, [])
    }

    func testOldCommitsArePrunedKeepingTheThreeMostRecent() async throws {
        let fileManager = FileManager.default
        let old = (1...4).map { FakeRepo.commitSHA("old-\($0)") }
        for (index, commit) in old.enumerated() {
            let directory = cacheRoot.appendingPathComponent(commit)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("name: old\n".utf8).write(to: directory.appendingPathComponent("installer.yaml"))
            // old-1 is the most recently used, old-4 the least.
            try fileManager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -Double(index + 1) * 86_400)], ofItemAtPath: directory.path)
        }
        let abandoned = cacheRoot.appendingPathComponent(ConfigCache.stagingPrefix + "abandoned")
        let inProgress = cacheRoot.appendingPathComponent(ConfigCache.stagingPrefix + "in-progress")
        try fileManager.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inProgress, withIntermediateDirectories: true)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: abandoned.path)
        let repo = FakeRepo.standard()
        repo.serve(on: transport)

        _ = await upgrade()

        XCTAssertEqual(Set(cacheEntries()),
                       [repo.commit, old[0], old[1], ConfigCache.refsFileName, inProgress.lastPathComponent])
    }

    func testCachedConfigDirectoryLooksOnlyAtDisk() async throws {
        let repo = FakeRepo.standard()
        XCTAssertNil(RemoteConfig.cachedConfigDirectory(commit: repo.commit, environment: environment))
        repo.serve(on: transport)
        _ = await upgrade()

        let cached = try XCTUnwrap(RemoteConfig.cachedConfigDirectory(commit: repo.commit.uppercased(), environment: environment))
        XCTAssertTrue(ConfigLoader.isConfigDirectory(cached))
        XCTAssertNil(RemoteConfig.cachedConfigDirectory(commit: "../\(repo.commit)", environment: environment))
        XCTAssertNil(RemoteConfig.cachedConfigDirectory(commit: "main", environment: environment))
    }

    func testSymlinksAndSubmodulesAreSkippedWithANote() async throws {
        var repo = FakeRepo.standard()
        repo.extraEntries = [
            ["path": "installer/config/files/link", "mode": "120000", "type": "blob", "sha": FakeRepo.commitSHA("link"), "size": 12],
            ["path": "installer/config/vendor/module", "mode": "160000", "type": "commit", "sha": FakeRepo.commitSHA("module")],
        ]
        repo.serve(on: transport)

        let result = await upgrade()

        XCTAssertEqual(result.config.source, .remote(repo: "octo/dots", ref: "main", commit: repo.commit))
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertTrue(result.notes[0].contains("symlinks") && result.notes[0].contains("files/link"), result.notes[0])
        XCTAssertTrue(result.notes[1].contains("submodules") && result.notes[1].contains("vendor/module"), result.notes[1])
        XCTAssertFalse(transport.urls.contains { $0.hasSuffix("files/link") || $0.hasSuffix("vendor/module") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.config.root.appendingPathComponent("files/link").path))
    }

    func testBoundedConcurrentDownloads() async throws {
        var repo = FakeRepo.standard()
        for index in 0..<30 { repo.add("installer/config/files/many/\(index).txt", "file \(index)\n") }
        repo.serve(on: transport)
        for file in repo.files where file.path.contains("/many/") {
            transport.update(repo.rawURL(file.path)) { $0.delay = 0.02 }
        }

        let result = await upgrade()

        XCTAssertEqual(result.config.meta.name, "Remote Dotfiles")
        XCTAssertLessThanOrEqual(transport.maxConcurrentRequests, RemoteConfig.maxConcurrentDownloads)
        XCTAssertGreaterThan(transport.maxConcurrentRequests, 1, "downloads run concurrently")
    }

    // MARK: Fallbacks

    func testOfflineFallsBackToTheLocalConfig() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.fail(repo.commitURL + "main", with: URLError(.notConnectedToInternet))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["Using the config at \(local.config.root.path)", "octo/dots@main", "offline"])
        XCTAssertEqual(cacheEntries(), [])
    }

    func testRequestTimeoutFallsBack() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.fail(repo.treeURL, with: URLError(.timedOut))

        let result = await upgrade(timeout: 7)

        assertFellBack(result, mentioning: ["did not answer within 7 seconds"])
        XCTAssertNil(RemoteConfig.cachedConfigDirectory(commit: repo.commit, environment: environment))
    }

    func testRateLimitFallsBackAndSaysWhenItResets() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        let reset = Date(timeIntervalSinceNow: 1_800)
        transport.set(repo.commitURL + "main", .text(#"{"message":"API rate limit exceeded for 203.0.113.9."}"#, status: 403, headers: [
            "X-RateLimit-Limit": "60", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970)),
        ]))

        let result = await upgrade()

        let expectedTime = RemoteConfigError.clockTime(Date(timeIntervalSince1970: TimeInterval(Int(reset.timeIntervalSince1970))))
        assertFellBack(result, mentioning: ["rate limit", "resets at \(expectedTime)"])
    }

    func testSecondaryRateLimitSaysWhenToRetry() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.set(repo.treeURL, .text("slow down", status: 429, headers: ["Retry-After": "60"]))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["rate limit", "try again in 60 seconds"])
    }

    func testUnknownRefFallsBack() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.set(repo.commitURL + "main", .text(#"{"message":"No commit found for SHA: main"}"#, status: 422))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["no branch, tag or commit named 'main'"])
    }

    func testTruncatedTreeFallsBack() async throws {
        var repo = FakeRepo.standard()
        repo.truncated = true
        repo.serve(on: transport)

        let result = await upgrade()

        assertFellBack(result, mentioning: ["truncated"])
        XCTAssertFalse(transport.urls.contains { $0.hasPrefix(GitHubAPI.rawBase) }, "nothing is downloaded from a partial listing")
    }

    func testAFailedFileDownloadFallsBackAndLeavesNoPartialCache() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.set(repo.rawURL("installer/config/steps/02-more.yaml"), .text("404: Not Found", status: 404))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["downloading installer/config/steps/02-more.yaml failed (HTTP 404)"])
        XCTAssertEqual(cacheEntries().filter { $0 != ConfigCache.refsFileName }, [], "a cache directory is either complete or absent")
    }

    func testDamagedFileFallsBack() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.set(repo.rawURL("installer/config/installer.yaml"), .text("<html>Welcome to Hotel Wi-Fi</html>"))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["installer/config/installer.yaml", "checksum"])
    }

    func testUnexpectedRefAnswerFallsBack() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.set(repo.commitURL + "main", .text("<html>Sign in to the network</html>"))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["unexpected answer"])
    }

    func testServerErrorFallsBack() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.set(repo.treeURL, .text(#"{"message":"Server Error"}"#, status: 502))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["HTTP 502", "Server Error"])
    }

    func testTLSFailureFallsBack() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.fail(repo.commitURL + "main", with: URLError(.serverCertificateUntrusted))

        let result = await upgrade()

        assertFellBack(result, mentioning: ["secure connection"])
    }

    func testMissingConfigDirectoryFallsBack() async throws {
        var repo = FakeRepo()
        repo.add("README.md", "just a readme\n")
        repo.serve(on: transport)

        let result = await upgrade()

        assertFellBack(result, mentioning: ["has no 'installer/config' directory"])
    }

    func testDirectoryWithoutInstallerYAMLFallsBack() async throws {
        var repo = FakeRepo()
        repo.add("installer/config/steps/01-base.yaml", "id: base\ntitle: Base\nitems:\n  - ok: x\n")
        repo.serve(on: transport)

        let result = await upgrade()

        assertFellBack(result, mentioning: ["has no installer.yaml"])
    }

    func testPathTraversalEntriesAreRefused() async throws {
        let hostile = [
            "installer/config/../../escape.txt",
            // The combining mark merges with the slash before it into one Character, so a Character-based
            // split sees a single component; the file system still sees `..` followed by `\u{301}escape.txt`.
            "installer/config/../\u{301}escape.txt",
            "installer/config/steps/../../../\u{301}escape.txt",
            "/etc/passwd",
            "installer/config/./escape.txt",
            "installer/config//escape.txt",
        ]
        for path in hostile {
            let transport = FakeTransport()
            // A commit of its own, so one case can never be answered from another case's cache.
            var repo = FakeRepo.standard(commit: FakeRepo.commitSHA(path))
            // Listed with its real blob SHA and served, so only the path check stands between it and the disk.
            repo.addListedBlob(path, "escaped\n")
            repo.serve(on: transport)

            let result = await upgrade(using: transport)

            assertFellBack(result, mentioning: ["unsafe path", path])
            XCTAssertFalse(transport.urls.contains { $0.hasPrefix(GitHubAPI.rawBase) }, "\(path.debugDescription): nothing is downloaded")
            XCTAssertNil(RemoteConfig.cachedConfigDirectory(commit: repo.commit, environment: environment))
            let landed = temp.everything().filter { $0.hasSuffix("escape.txt") }
            XCTAssertEqual(landed, [], "\(path.debugDescription) was written to disk")
        }
    }

    func testFilesAreNeverWrittenOutsideTheStagingDirectory() async throws {
        // FetchPlan.make refuses such entries; this checks the second line of defence on its own.
        let commit = FakeRepo.commitSHA("first")
        let staging = temp.url.appendingPathComponent("cache/.staging-test")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let contents = Data("escaped\n".utf8)
        let repoPath = "installer/config/../\u{301}escape.txt"
        transport.set("https://raw.githubusercontent.com/octo/dots/\(commit)/\(GitHubAPI.encodePath(repoPath))",
                      CannedResponse(status: 200, headers: [:], body: contents))
        let github = GitHubAPI(repo: "octo/dots", transport: transport, deadline: Deadline(seconds: 5))
        let file = FetchPlan.File(relativePath: "../\u{301}escape.txt", repoPath: repoPath,
                                  sha: GitHubAPI.gitBlobHash(contents, likeSHA: commit), size: contents.count, executable: false)

        do {
            try await RemoteConfig.save(file, commit: commit, into: staging, github: github)
            XCTFail("expected the file to be refused")
        } catch {
            XCTAssertEqual(error as? RemoteConfigError, .unsafePath("../\u{301}escape.txt"))
        }
        var plan = FetchPlan()
        plan.directories = ["files/../../\u{301}outside"]
        XCTAssertThrowsError(try RemoteConfig.createDirectories(for: plan, in: staging)) { error in
            XCTAssertEqual(error as? RemoteConfigError, .unsafePath("files/../../\u{301}outside"))
        }

        XCTAssertEqual(transport.urls, [], "nothing is downloaded for a path that cannot be written")
        XCTAssertEqual(temp.everything().filter { $0.hasSuffix("escape.txt") || $0.hasSuffix("outside") }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.deletingLastPathComponent().path), [".staging-test"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testTheStagingCheckAcceptsOrdinaryPathsUnderPrivateAndStillRefusesEscapes() throws {
        // The staging folder exists and the files about to be written in it do not; the check must not
        // depend on which of them Foundation can look up (it drops /private only from paths that exist).
        let physical = TempDirectory("shawn-sync-staging", underPrivate: true)
        let staging = physical.url.appendingPathComponent("cache/config/.staging-test")
        XCTAssertTrue(staging.path.hasPrefix("/private/"), staging.path)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // The same folder as a caller might spell it, with a `..` in it.
        let roundabout = physical.url.appendingPathComponent("cache/elsewhere/../config/.staging-test")

        for folder in [staging, roundabout] {
            for relative in ["installer.yaml", "steps/01-base.yaml", "files/readme with spaces.txt", "files/José it's/100% #1?.txt"] {
                XCTAssertEqual(try RemoteConfig.destination(of: relative, in: folder).path, staging.path + "/" + relative,
                               "\(relative) in \(folder.path)")
            }
            for hostile in ["../escape.txt", "../\u{301}escape.txt", "steps/../../escape.txt", "/etc/passwd", "./escape.txt",
                            "steps//escape.txt", "steps/", ""] {
                XCTAssertThrowsError(try RemoteConfig.destination(of: hostile, in: folder), hostile.debugDescription) { error in
                    XCTAssertEqual(error as? RemoteConfigError, .unsafePath(hostile))
                }
            }
        }

        var plan = FetchPlan()
        plan.directories = ["steps", "files/bin"]
        try RemoteConfig.createDirectories(for: plan, in: staging)
        XCTAssertEqual(physical.everything().filter { !$0.hasPrefix("cache/config/.staging-test") }.sorted(), ["cache", "cache/config"])
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: staging.path).sorted(), ["files", "files/bin", "steps"])
    }

    func testInvalidRepoOrPathFallsBackWithoutAnyRequest() async throws {
        let badRepo = RemoteConfigRef(repo: "octo/../../etc", branch: "main", path: "installer/config")
        let badPath = RemoteConfigRef(repo: "octo/dots", branch: "main", path: "installer/../../config")

        let first = await upgrade(remote: badRepo)
        let second = await upgrade(remote: badPath)

        assertFellBack(first, mentioning: ["not a GitHub repo name"])
        assertFellBack(second, mentioning: ["not a plain relative path"])
        XCTAssertEqual(transport.urls, [])
    }

    func testImplausibleRefsAreRejectedWithoutAnyRequest() async throws {
        for ref in ["../../users/someone", "/main", "main/", "has space", "a:b", "x~1"] {
            let result = await upgrade(ref: ref)
            assertFellBack(result, mentioning: ["'\(ref)' is not a valid branch, tag or commit name"])
        }
        XCTAssertEqual(transport.urls, [])
        XCTAssertTrue(RemoteConfig.isPlausibleRef("release/v2.0"))
        XCTAssertTrue(RemoteConfig.isPlausibleRef("shawn-v1.2.3"))
    }

    // MARK: Configs this build cannot use

    func testUnknownItemKindFallsBackWithNewerInstallerNote() async throws {
        let repo = FakeRepo.standard(extraStep: "id: extra\ntitle: Extra\nitems:\n  - teleport: home\n")
        repo.serve(on: transport)

        let result = await upgrade()

        assertFellBack(result, mentioning: ["octo/dots@main, \(repo.commit.prefix(7))", "does not know: teleport.",
                                            "A newer installer is needed", "shawn update"])
    }

    func testNewerSchemaFallsBackWithNewerInstallerNote() async throws {
        let repo = FakeRepo.standard(schema: ShawnCore.schemaVersion + 1)
        repo.serve(on: transport)

        let result = await upgrade()

        assertFellBack(result, mentioning: ["is config schema \(ShawnCore.schemaVersion + 1), and this installer",
                                            "A newer installer is needed", "shawn update"])
    }

    func testBrokenRemoteConfigFallsBackNamingTheProblem() async throws {
        let repo = FakeRepo.standard(extraStep: "id: extra\ntitle: Extra\nitems:\n  - ok: x\n    colour: blue\n")
        repo.serve(on: transport)

        let result = await upgrade()

        assertFellBack(result, mentioning: ["does not load with this installer", "colour", "otherwise the config on GitHub needs fixing"])
    }

    // MARK: Deadline

    func testDeadlineHoldsWhenGitHubNeverAnswers() async throws {
        let hanging = HangingTransport()
        let started = Date()

        let result = await upgrade(timeout: 0.3, using: hanging)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3, "the deadline must hold even when a request ignores cancellation")
        assertFellBack(result, mentioning: ["did not answer within 0.3 seconds"])
        XCTAssertEqual(hanging.hangingCount, 1)
        hanging.release()
    }

    func testDeadlineDuringDownloadsLeavesNoPartialCache() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        let hanging = HangingTransport(answering: transport) { $0.absoluteString.hasSuffix("02-more.yaml") }

        let result = await upgrade(timeout: 0.5, using: hanging)

        assertFellBack(result, mentioning: ["did not answer within 0.5 seconds"])
        hanging.release()
        let cleaned = await waitUntil { self.cacheEntries().filter { $0 != ConfigCache.refsFileName }.isEmpty }
        XCTAssertTrue(cleaned, "abandoned staging directory is removed once the hung request unwinds: \(cacheEntries())")
    }

    func testCancellingTheCallerFallsBackPromptly() async throws {
        let hanging = HangingTransport()
        let task = Task { await self.upgrade(timeout: 60, using: hanging) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let result = await task.value

        assertFellBack(result, mentioning: ["cancelled"])
        hanging.release()
    }

    // MARK: latestCommit

    func testLatestCommitResolvesTheBranchOrARef() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        repo.serve(on: transport, ref: "v1.2.0")

        let commit = try await RemoteConfig.latestCommit(for: remote, timeout: 5, environment: nil, transport: transport)
        let tagged = try await RemoteConfig.latestCommit(for: remote, ref: "v1.2.0", timeout: 5, environment: nil, transport: transport)

        XCTAssertEqual(commit, repo.commit)
        XCTAssertEqual(tagged, repo.commit)
        XCTAssertEqual(transport.urls, [repo.commitURL + "main", repo.commitURL + "v1.2.0"])
        XCTAssertNil(transport.requests[0].headers["If-None-Match"])
    }

    func testLatestCommitUsesConditionalRequestsWhenGivenAnEnvironment() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)

        let first = try await RemoteConfig.latestCommit(for: remote, timeout: 5, environment: environment, transport: transport)
        let second = try await RemoteConfig.latestCommit(for: remote, timeout: 5, environment: environment, transport: transport)

        XCTAssertEqual(first, repo.commit)
        XCTAssertEqual(second, repo.commit)
        XCTAssertEqual(transport.requests.map { $0.headers["If-None-Match"] }, [nil, "\"\(repo.commit)\""])
    }

    func testLatestCommitThrowsDescriptiveErrors() async throws {
        let repo = FakeRepo.standard()
        repo.serve(on: transport)
        transport.set(repo.commitURL + "main", .text("{}", status: 403, headers: ["X-RateLimit-Remaining": "0"]))

        do {
            _ = try await RemoteConfig.latestCommit(for: remote, timeout: 5, environment: nil, transport: transport)
            XCTFail("expected a rate-limit error")
        } catch let error as RemoteConfigError {
            XCTAssertEqual(error, .rateLimited(resetsAt: nil, retryAfter: nil))
            XCTAssertTrue(error.description.contains("rate limit"))
        }

        let hanging = HangingTransport()
        do {
            _ = try await RemoteConfig.latestCommit(for: remote, timeout: 0.2, environment: nil, transport: hanging)
            XCTFail("expected a timeout")
        } catch let error as RemoteConfigError {
            XCTAssertEqual(error, .timedOut(seconds: 0.2))
        }
        hanging.release()
    }

    // MARK: Pieces

    func testGitBlobHashMatchesGit() {
        // `printf 'hello' | git hash-object --stdin` and `printf 'hello\n' | git hash-object --stdin`
        let sha1 = String(repeating: "0", count: 40)
        XCTAssertEqual(GitHubAPI.gitBlobHash(Data("hello".utf8), likeSHA: sha1), "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
        XCTAssertEqual(GitHubAPI.gitBlobHash(Data("hello\n".utf8), likeSHA: sha1), "ce013625030ba8dba906f756967f9e9ca394464a")
        XCTAssertEqual(GitHubAPI.gitBlobHash(Data(), likeSHA: String(repeating: "0", count: 64)).count, 64)
    }

    func testURLEncodingKeepsSlashesAndEscapesEverythingElse() {
        XCTAssertEqual(GitHubAPI.encodePath("files/readme with spaces.txt"), "files/readme%20with%20spaces.txt")
        XCTAssertEqual(GitHubAPI.encodePath("release/v2"), "release/v2")
        XCTAssertEqual(GitHubAPI.encodePath("a#b?c+d"), "a%23b%3Fc%2Bd")
    }

    func testSafeRelativePaths() {
        // Components are what the file system sees: bytes between `/` bytes. A name that merely starts
        // with a combining mark, or `..` followed by one, is an ordinary name.
        for good in ["installer.yaml", "steps/01.yaml", "files/.hushlogin", "a/b..c/d", "\u{301}x", "a/\u{301}/b", "a/..\u{301}/b"] {
            XCTAssertTrue(FetchPlan.isSafeRelativePath(good), good.debugDescription)
        }
        for bad in ["", "/abs", "../x", "a/../b", "a/./b", "a//b", "a/", "a\0b",
                    "../\u{301}x", "a/../\u{301}b", "a/.\u{20DD}/../../b", "a/./\u{301}b", "a//\u{301}b", "/\u{301}x", "a/\u{200D}/../b/.."] {
            XCTAssertFalse(FetchPlan.isSafeRelativePath(bad), bad.debugDescription)
        }
        XCTAssertThrowsError(try RemoteConfig.validatedConfigPath("installer/../\u{301}config"))
        XCTAssertEqual(try RemoteConfig.validatedConfigPath("/installer/config/"), "installer/config")
    }

    func testOnlyEntriesUnderTheConfigPathByteForByteAreFetched() throws {
        let sha = FakeRepo.commitSHA("blob")
        func blob(_ path: String) -> GitTree.Entry { GitTree.Entry(path: path, mode: "100644", type: "blob", sha: sha, size: 1) }
        let tree = GitTree(sha: nil, tree: [
            blob("installer/config/installer.yaml"),
            // A name starting with a combining mark, directly under the config path: part of the config
            // (a Character-based prefix check misses it, because the mark merges with the slash).
            blob("installer/config/\u{301}accent.txt"),
            blob("installer/configuration.yaml"),
            blob("README.md"),
        ], truncated: false)

        let plan = try FetchPlan.make(tree: tree, configPath: "installer/config", repo: "octo/dots", commit: sha)

        XCTAssertEqual(plan.files.map(\.relativePath), ["installer.yaml", "\u{301}accent.txt"])
        XCTAssertEqual(plan.files.map(\.repoPath), ["installer/config/installer.yaml", "installer/config/\u{301}accent.txt"])
    }

    func testCommitParsingAcceptsBareShaOrJSON() {
        let sha = FakeRepo.commitSHA("x")
        XCTAssertEqual(GitHubAPI.parseCommit(Data("\(sha.uppercased())\n".utf8)), sha)
        XCTAssertEqual(GitHubAPI.parseCommit(Data(#"{"sha":"\#(sha)"}"#.utf8)), sha)
        XCTAssertNil(GitHubAPI.parseCommit(Data("<html></html>".utf8)))
    }

    func testLiveTransportSendsNothingPersonal() throws {
        let transport = URLSessionTransport()
        let configuration = transport.session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["User-Agent"] as? String, "ShawnsDotfiles/\(ShawnCore.version)")
        XCTAssertEqual(configuration.httpAdditionalHeaders?.count, 1)
    }

    func testNonFiniteTimeoutsDoNotTrap() {
        XCTAssertEqual(sleepNanoseconds(0.5), 500_000_000)
        XCTAssertEqual(sleepNanoseconds(-1), 0)
        XCTAssertEqual(sleepNanoseconds(.nan), 0)
        XCTAssertEqual(sleepNanoseconds(.infinity), UInt64(365 * 86_400) * 1_000_000_000)
        XCTAssertEqual(RemoteConfigError.timedOut(seconds: .infinity).description, "GitHub did not answer within the time allowed")
        XCTAssertEqual(RemoteConfigError.timedOut(seconds: 2.5).description, "GitHub did not answer within 2.5 seconds")
    }

    func testErrorDescriptionsAreReadable() {
        XCTAssertEqual(RemoteConfigError.offline.description, "GitHub could not be reached; this Mac looks offline")
        XCTAssertEqual(RemoteConfigError.timedOut(seconds: 20).description, "GitHub did not answer within 20 seconds")
        XCTAssertEqual(RemoteConfigError.timedOut(seconds: 1).description, "GitHub did not answer within 1 second")
        XCTAssertEqual(RemoteConfigError.rateLimited(resetsAt: nil, retryAfter: nil).description,
                       "GitHub's API rate limit for this network is used up")
        XCTAssertEqual(RemoteConfigError.classify(URLError(.cannotFindHost)), .offline)
        XCTAssertEqual(RemoteConfigError.classify(CancellationError()), .cancelled)
        XCTAssertEqual(RemoteConfigError.classify(CocoaError(.fileWriteOutOfSpace)),
                       .cache(CocoaError(.fileWriteOutOfSpace).localizedDescription))
    }
}
