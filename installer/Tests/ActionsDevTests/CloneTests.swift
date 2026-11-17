import Darwin
import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

final class CloneTests: XCTestCase {
    /// A bare repository with one commit on `main`, inside the sandbox.
    private func makeRemote(_ sandbox: DevSandbox) -> URL {
        let work = sandbox.root.appendingPathComponent("work")
        let bare = sandbox.root.appendingPathComponent("remote.git")
        try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        sandbox.git(["init", "-q", "-b", "main"], in: work)
        try! "hello\n".write(to: work.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        sandbox.git(["add", "README.md"], in: work)
        sandbox.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "first"], in: work)
        sandbox.git(["clone", "-q", "--bare", work.path, bare.path])
        return bare
    }

    func testClonesAndIsIdempotent() async throws {
        let sandbox = DevSandbox()
        let remote = makeRemote(sandbox)
        let (action, item, plan) = try sandbox.single(CloneAction.self, """
          - clone: \(remote.path)
            to: ~/Developer/thing
            branch: main
        """)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not cloned yet"))
        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("cloned \(remote.path) to ~/Developer/thing"))
        XCTAssertEqual(sandbox.readHome("Developer/thing/README.md"), "hello\n")
        XCTAssertEqual(sandbox.git(["rev-parse", "--abbrev-ref", "HEAD"], in: sandbox.homeURL("Developer/thing")), "main")

        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("already cloned at ~/Developer/thing"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("already cloned"))
    }

    func testClonesIntoAnEmptyDirectory() async throws {
        let sandbox = DevSandbox()
        let remote = makeRemote(sandbox)
        try FileManager.default.createDirectory(at: sandbox.homeURL("Developer/empty"), withIntermediateDirectories: true)
        let (action, item, plan) = try sandbox.single(CloneAction.self, "  - clone: \(remote.path)\n    to: ~/Developer/empty")
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertTrue(sandbox.existsInHome("Developer/empty/.git"))
    }

    func testRefusesANonEmptyDirectoryThatIsNotARepository() async throws {
        let sandbox = DevSandbox()
        let remote = makeRemote(sandbox)
        sandbox.writeHome("Developer/thing/notes.txt", "mine\n")
        let (action, item, plan) = try sandbox.single(CloneAction.self, "  - clone: \(remote.path)\n    to: ~/Developer/thing")
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("~/Developer/thing exists but is not a git repository"))
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "~/Developer/thing already exists and is not a git repository, so nothing was cloned into it")
        XCTAssertEqual(sandbox.readHome("Developer/thing/notes.txt"), "mine\n")
        XCTAssertFalse(sandbox.existsInHome("Developer/thing/.git"))
    }

    func testFailureNamesTheURLAndWhatToDo() async throws {
        let sandbox = DevSandbox()
        let missing = sandbox.root.appendingPathComponent("nope.git").path
        let (action, item, plan) = try sandbox.single(CloneAction.self, "  - clone: \(missing)\n    to: ~/x")
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertTrue(error?.message.hasPrefix("Cloning \(missing) failed:") == true, "\(String(describing: error))")
        XCTAssertEqual(error?.hint, "Check the URL and that you have access to it, then run this again")
    }

    /// owner/repo becomes an https URL unless gh is signed in to github.com with git_protocol ssh.
    func testGitHubShorthandPicksTheProtocol() async throws {
        var base = ProcessInfo.processInfo.environment
        base.removeValue(forKey: "GIT_SSH_COMMAND")
        let sandbox = DevSandbox(baseEnvironment: base)
        // A Homebrew git in the sandbox is preferred over the system one, so it can stand in for the network.
        sandbox.shim("git", #"""
        for last in "$@"; do :; done
        mkdir -p "$last/.git"
        """#)
        let items = "  - clone: \"{{dotfiles_repo}}\"\n    to: ~/Developer/dotfiles"
        let (action, item, plan) = try sandbox.single(CloneAction.self, items)
        _ = try await action.run(sandbox.context(item, plan))
        let target = sandbox.homeURL("Developer/dotfiles").path
        let stall = ["-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=120"]
        XCTAssertEqual(sandbox.calls("git").last, stall + ["clone", "--progress", "--", "https://github.com/tester/dotfiles.git", target])
        XCTAssertEqual(sandbox.lastEnvironment("git")["GIT_SSH_COMMAND"],
                       "ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4",
                       "ssh must never wait on a terminal, and must notice a connection that died")

        try FileManager.default.removeItem(at: sandbox.homeURL("Developer/dotfiles"))
        sandbox.installFakeGh()
        sandbox.ghSignedIn(protocol: "ssh")
        sandbox.newRun()
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.calls("git").last, stall + ["clone", "--progress", "--", "git@github.com:tester/dotfiles.git", target])

        try FileManager.default.removeItem(at: sandbox.homeURL("Developer/dotfiles"))
        let (forced, forcedItem, forcedPlan) = try sandbox.single(CloneAction.self, items + "\n    protocol: https")
        _ = try await forced.run(sandbox.context(forcedItem, forcedPlan))
        XCTAssertEqual(sandbox.calls("git").last, stall + ["clone", "--progress", "--", "https://github.com/tester/dotfiles.git", target])
    }

    /// The item passes --depth=1 for the repository that `remote:` in installer.yaml names, written as owner/repo
    /// or as a github.com URL, and for no other. With no `remote:` in the config, it clones every repository
    /// whole (the test above).
    func testTheConfigsOwnRepositoryGetsOnlyItsNewestCommit() async throws {
        var base = ProcessInfo.processInfo.environment
        base.removeValue(forKey: "GIT_SSH_COMMAND")
        let sandbox = DevSandbox(baseEnvironment: base)
        sandbox.shim("git", #"""
        for last in "$@"; do :; done
        mkdir -p "$last/.git"
        """#)
        let installer = DevSandbox.installerYAML + "remote:\n  repo: Tester/Dotfiles\n  branch: main\n"
        let stall = ["-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=120"]
        let target = sandbox.homeURL("Developer/dotfiles").path

        /// Runs one clone item on a home without the checkout, and gives back what the item asked git and what it said.
        func clone(_ items: String, dryRun: Bool = false) async throws -> (asked: [String]?, said: ActionOutcome) {
            try? FileManager.default.removeItem(at: sandbox.homeURL("Developer/dotfiles"))
            sandbox.clearShimLog()
            let (action, item, plan) = try sandbox.single(CloneAction.self, items, installer: installer)
            let said = try await action.run(sandbox.context(item, plan, dryRun: dryRun))
            return (sandbox.calls("git").last, said)
        }

        let own = "  - clone: \"{{dotfiles_repo}}\"\n    to: ~/Developer/dotfiles"
        var result = try await clone(own)
        XCTAssertEqual(result.asked, stall + ["clone", "--progress", "--depth=1", "--", "https://github.com/tester/dotfiles.git", target])
        XCTAssertEqual(result.said, .done("cloned https://github.com/tester/dotfiles.git to ~/Developer/dotfiles, newest commit only"))

        result = try await clone(own + "\n    branch: main")
        XCTAssertEqual(result.asked, stall + ["clone", "--progress", "--depth=1", "--branch", "main", "--", "https://github.com/tester/dotfiles.git", target])

        // A full URL of the same repository counts too, whatever its letter case.
        result = try await clone("  - clone: https://github.com/tester/DOTFILES.git\n    to: ~/Developer/dotfiles")
        XCTAssertEqual(result.asked, stall + ["clone", "--progress", "--depth=1", "--", "https://github.com/tester/DOTFILES.git", target])

        result = try await clone("  - clone: tester/other\n    to: ~/Developer/dotfiles")
        XCTAssertEqual(result.asked, stall + ["clone", "--progress", "--", "https://github.com/tester/other.git", target])
        XCTAssertEqual(result.said, .done("cloned https://github.com/tester/other.git to ~/Developer/dotfiles"))

        result = try await clone(own, dryRun: true)
        XCTAssertNil(result.asked, "a dry run runs no git")
        XCTAssertEqual(result.said, .done("would clone the newest commit of https://github.com/tester/dotfiles.git"))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=120 clone --progress --depth=1 -- https://github.com/tester/dotfiles.git"),
                      sandbox.logText)

        // Over ssh the option is the same.
        sandbox.installFakeGh()
        sandbox.ghSignedIn(protocol: "ssh")
        sandbox.newRun()
        result = try await clone(own)
        XCTAssertEqual(result.asked, stall + ["clone", "--progress", "--depth=1", "--", "git@github.com:tester/dotfiles.git", target])
    }

    func testDryRunClonesNothing() async throws {
        let sandbox = DevSandbox()
        let remote = makeRemote(sandbox)
        let (action, item, plan) = try sandbox.single(CloneAction.self, "  - clone: \(remote.path)\n    to: ~/Developer/thing")
        assertEqual(try await action.run(sandbox.context(item, plan, dryRun: true)), .done("would clone \(remote.path)"))
        XCTAssertFalse(sandbox.existsInHome("Developer/thing"))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=120 clone --progress -- \(remote.path)"),
                      sandbox.logText)
    }

    /// A server that accepts the connection and then says nothing: real git, stopped by the time limit.
    func testAStalledCloneIsStoppedAndLeavesNothingBehind() async throws {
        var base = ProcessInfo.processInfo.environment
        for name in ["http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"] { base.removeValue(forKey: name) }
        let sandbox = DevSandbox(baseEnvironment: base)
        let server = try SilentServer()
        let url = "http://127.0.0.1:\(server.port)/repo.git"
        let (configured, item, plan) = try sandbox.single(CloneAction.self, "  - clone: \(url)\n    to: ~/Developer/repo")
        var action = configured
        action.timeLimit = 2

        let started = Date()
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertEqual(error?.message, "Cloning \(url) did not finish within 2 seconds")
        XCTAssertEqual(error?.hint, "Check the network connection, then run this again")
        XCTAssertFalse(sandbox.existsInHome("Developer/repo"))
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not cloned yet"))
    }

    /// git cleans up after itself when told to stop, but not when it has to be killed: the installer
    /// removes the half-made clone so its .git cannot pass for a finished one.
    func testAKilledCloneIsCleanedUp() async throws {
        for preexisting in [false, true] {
            let sandbox = DevSandbox()
            sandbox.shim("git", #"""
            trap '' TERM
            for last in "$@"; do :; done
            mkdir -p "$last/.git/objects"
            echo partial > "$last/.git/HEAD"
            sleep 30
            """#)
            if preexisting { try FileManager.default.createDirectory(at: sandbox.homeURL("Developer/repo"), withIntermediateDirectories: true) }
            let (configured, item, plan) = try sandbox.single(CloneAction.self, "  - clone: owner/repo\n    to: ~/Developer/repo\n    protocol: https")
            var action = configured
            action.timeLimit = 1

            let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
            XCTAssertEqual(error?.message, "Cloning https://github.com/owner/repo.git did not finish within 1 second")
            XCTAssertFalse(sandbox.existsInHome("Developer/repo/.git"), "a half-made clone must not look finished")
            XCTAssertEqual(sandbox.existsInHome("Developer/repo"), preexisting, "an empty folder that was there before stays")
            assertEqual(await action.check(sandbox.context(item, plan)), .needed("not cloned yet"))
        }
    }
}

/// A TCP server on 127.0.0.1 that accepts connections (the kernel does that) and never answers.
private final class SilentServer {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = descriptor >= 0 && withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic -> Bool in
                bind(descriptor, generic, length) == 0 && listen(descriptor, 8) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard listening else {
            if descriptor >= 0 { close(descriptor) }
            throw XCTSkip("cannot listen on 127.0.0.1 here")
        }
        self.descriptor = descriptor
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(descriptor) }
}
