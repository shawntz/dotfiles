import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

/// `github:` against a stateful fake gh (see FakeTools.swift) and the real ssh-keygen/git in the sandbox.
final class GitHubActionTests: XCTestCase {
    private let items = """
      - github: github.com
        key: ~/.ssh/id_ed25519.pub
        title: Test Mac
    """

    private func prepared(flow: DevSandbox.DeviceFlowBehaviour = .code, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                          hostKeys: [String] = gitHubHostKeyLines) throws -> (DevSandbox, GitHubAction, PlannedItem, InstallPlan) {
        let sandbox = DevSandbox(baseEnvironment: baseEnvironment)
        sandbox.installFakeGh(flow: flow, hostKeys: hostKeys)
        sandbox.generateKey()
        let (action, item, plan) = try sandbox.single(GitHubAction.self, items)
        return (sandbox, action, item, plan)
    }

    func testDeviceFlowSignInThenEverythingElse() async throws {
        let (sandbox, action, item, plan) = try prepared()
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not signed in to github.com"))

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("signed in as shawntz; git uses gh for github.com credentials; added github.com to known_hosts; uploaded authentication + signing key"))

        // The exact non-interactive login from research/gh-auth-flow.md.
        XCTAssertTrue(sandbox.calls("gh").contains(["auth", "login", "--hostname", "github.com", "--web", "--git-protocol", "ssh", "--skip-ssh-key",
                                                    "--clipboard=false", "--scopes", "admin:public_key,admin:ssh_signing_key"]), "\(sandbox.calls("gh"))")

        // The code and URL were surfaced while gh waited, then cleared.
        let shown = sandbox.attentions.compactMap { $0 }
        XCTAssertEqual(shown.last?.code, "1A2B-C3D4")
        XCTAssertEqual(shown.last?.url, URL(string: "https://github.com/login/device"))
        XCTAssertEqual(shown.last?.title, "Sign in to GitHub (github.com)")
        XCTAssertNil(sandbox.attentions.last ?? Attention(title: "", message: ""), "the callout is cleared afterwards")

        // Keys were uploaded once per type, with GH_HOST naming the host.
        let pub = try XCTUnwrap(SSHPublicKey(line: sandbox.readHome(".ssh/id_ed25519.pub") ?? ""))
        XCTAssertEqual(sandbox.ghRegisteredKeys("authentication"), [pub.material])
        XCTAssertEqual(sandbox.ghRegisteredKeys("signing"), [pub.material])
        let pubPath = sandbox.homeURL(".ssh/id_ed25519.pub").path
        XCTAssertTrue(sandbox.calls("gh").contains(["ssh-key", "add", pubPath, "--type", "signing", "--title", "Test Mac"]))

        // known_hosts got GitHub's three pinned keys.
        let knownHosts = try XCTUnwrap(sandbox.readHome(".ssh/known_hosts"))
        XCTAssertEqual(knownHosts, gitHubHostKeyLines.map { "github.com \($0)" }.joined(separator: "\n") + "\n")
        XCTAssertEqual(sandbox.permissions(".ssh/known_hosts"), 0o600)

        // gh auth setup-git ran (the fake writes the same helpers the real one does).
        XCTAssertTrue(sandbox.git(["config", "--global", "--get-all", "credential.https://github.com.helper"]).contains("auth git-credential"))

        // Second run: everything is already there and nothing is repeated.
        sandbox.newRun()
        sandbox.clearShimLog()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("signed in as shawntz"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("already set up"))
        let repeated = sandbox.calls("gh").filter { ["login", "refresh", "setup-git"].contains($0.dropFirst().first ?? "") || $0.first == "ssh-key" }
        XCTAssertEqual(repeated, [])
        XCTAssertEqual(sandbox.readHome(".ssh/known_hosts"), knownHosts)
    }

    func testClipboardCodeFormat() async throws {
        let (sandbox, action, item, plan) = try prepared(flow: .clipboard)
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.attentions.compactMap { $0 }.last?.code, "ABCD-EF12")
    }

    func testAddsOnlyMissingScopesToAnExistingLogin() async throws {
        let (sandbox, action, item, plan) = try prepared()
        sandbox.ghSignedIn(scopes: "admin:public_key, gist, read:org, repo")
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("the github.com token lacks write:ssh_signing_key"))

        // The outcome names the scope that was asked for, which is the one in the command below.
        let outcome = try await action.run(sandbox.context(item, plan))
        if case .done(let message?) = outcome {
            XCTAssertTrue(message.contains("added admin:ssh_signing_key to the github.com login"), message)
        } else {
            XCTFail("\(outcome)")
        }
        XCTAssertTrue(sandbox.calls("gh").contains(["auth", "refresh", "--hostname", "github.com", "--clipboard=false", "--scopes", "admin:ssh_signing_key"]),
                      "\(sandbox.calls("gh"))")
        XCTAssertFalse(sandbox.calls("gh").contains { $0.starts(with: ["auth", "login"]) })
        XCTAssertEqual(sandbox.attentions.compactMap { $0 }.last?.code, "1A2B-C3D4", "refresh uses the same device flow")
    }

    func testKeyAlreadyUploadedIsNotUploadedAgain() async throws {
        let (sandbox, action, item, plan) = try prepared()
        sandbox.ghSignedIn()
        let pub = try XCTUnwrap(SSHPublicKey(line: sandbox.readHome(".ssh/id_ed25519.pub") ?? ""))
        sandbox.directory.write("gh/keys-authentication", "\(gitHubHostKeyLines[0])\n\(pub.material)\n")

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("git uses gh for github.com credentials; added github.com to known_hosts; uploaded signing key"))
        XCTAssertEqual(sandbox.calls("gh").filter { $0.first == "ssh-key" }.map { $0[4] }, ["signing"])
        XCTAssertTrue(sandbox.logText.contains("is already on github.com as an authentication key"))
    }

    func testSetsTheGitProtocolWhenItDiffers() async throws {
        let (sandbox, action, item, plan) = try prepared()
        sandbox.ghSignedIn(protocol: "https")
        let before = await action.check(sandbox.context(item, plan))
        XCTAssertEqual(before, .needed("gh's git protocol for github.com is not ssh"))
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertTrue(sandbox.calls("gh").contains(["config", "set", "--host", "github.com", "git_protocol", "ssh"]))
        XCTAssertEqual(sandbox.directory.read("gh/protocol-github.com"), "ssh\n")
    }

    func testMissingGh() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(GitHubAction.self, items)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("gh is not installed yet"))
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "The GitHub CLI (gh) is not installed")
        XCTAssertTrue(error?.hint?.contains("brew: gh") == true)
    }

    /// A gh that hangs past the code's lifetime is stopped, and the sign-in becomes a follow-up.
    func testDeviceFlowTimesOutIntoAFollowUp() async throws {
        let (sandbox, base, item, plan) = try prepared(flow: .slow)
        var action = base
        action.deviceFlowTimeout = 1
        action.deviceFlowGrace = 0
        let started = Date()
        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "the fake waits 30 s; the timeout must cut it short")
        XCTAssertEqual(outcome, .needsAttention("GitHub sign-in was not finished within 1 second"))
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Sign in to GitHub (github.com)"])
        XCTAssertEqual(sandbox.followUps.first?.url, URL(string: "https://github.com/login/device"))
        XCTAssertEqual(sandbox.attentions.compactMap { $0 }.last?.code, "1A2B-C3D4")
        XCTAssertNil(sandbox.attentions.last ?? Attention(title: "", message: ""))
        XCTAssertEqual(sandbox.ghRegisteredKeys("authentication"), [], "nothing after sign-in ran")
    }

    /// The usual way an unattended sign-in ends: gh reaches the code's expiry first and exits 1 itself.
    func testDeviceFlowExpiryInsideGhIsNeedsAttention() async throws {
        for flow in [DevSandbox.DeviceFlowBehaviour.expire, .expiredToken] {
            let (sandbox, action, item, plan) = try prepared(flow: flow)
            let outcome = try await action.run(sandbox.context(item, plan))
            XCTAssertEqual(outcome, .needsAttention("GitHub sign-in was not finished within 15 minutes"), "\(flow)")
            XCTAssertEqual(sandbox.followUps.map(\.title), ["Sign in to GitHub (github.com)"], "\(flow)")
            XCTAssertEqual(sandbox.followUps.first?.url, URL(string: "https://github.com/login/device"))
            XCTAssertEqual(sandbox.attentions.compactMap { $0 }.last?.code, "1A2B-C3D4", "the code was shown while gh waited")
            XCTAssertNil(sandbox.attentions.last ?? Attention(title: "", message: ""), "and cleared afterwards")
            XCTAssertEqual(sandbox.ghRegisteredKeys("authentication"), [], "nothing after sign-in ran")
        }
    }

    /// `gh auth refresh` prints the bare error (no "failed to authenticate" line); it is an expiry all the same.
    func testExpiredPermissionUpdateIsNeedsAttention() async throws {
        let (sandbox, action, item, plan) = try prepared(flow: .bareExpire)
        sandbox.ghSignedIn(scopes: "admin:public_key, gist, read:org, repo")
        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .needsAttention("GitHub sign-in was not finished within 15 minutes"))
        XCTAssertTrue(sandbox.calls("gh").contains { $0.starts(with: ["auth", "refresh"]) })
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Sign in to GitHub (github.com)"])
        XCTAssertNil(sandbox.attentions.last ?? Attention(title: "", message: ""))
    }

    func testFailedSignInExplainsWhy() async throws {
        let (sandbox, action, item, plan) = try prepared(flow: .fail)
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "GitHub sign-in for github.com failed: access_denied (access_denied)")
        XCTAssertTrue(error?.hint?.contains("new code") == true)
        XCTAssertNil(sandbox.attentions.last ?? Attention(title: "", message: ""))
    }

    func testUntrustedHostKeysAreNotWritten() async throws {
        let sandbox = DevSandbox()
        let impostorKey = sandbox.generateKey(".ssh/impostor")
        let impostor = try XCTUnwrap(SSHPublicKey(line: (try? String(contentsOf: URL(fileURLWithPath: impostorKey.path + ".pub"), encoding: .utf8)) ?? ""))
        sandbox.installFakeGh(hostKeys: [gitHubHostKeyLines[0], impostor.material])
        sandbox.shim("ssh-keyscan", "echo 'ssh-keyscan must not be needed when gh answered' >&2; exit 1")
        sandbox.generateKey()
        sandbox.ghSignedIn()
        let (action, item, plan) = try sandbox.single(GitHubAction.self, items)

        let outcome = try await action.run(sandbox.context(item, plan))
        guard case .needsAttention(let message) = outcome else { return XCTFail("expected needsAttention, got \(outcome)") }
        XCTAssertTrue(message.contains("github.com host keys not added"), message)
        XCTAssertFalse(sandbox.existsInHome(".ssh/known_hosts"))
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Check GitHub's SSH host keys"])
        XCTAssertEqual(sandbox.followUps.first?.url, GitHubHostKeys.fingerprintsURL)
        XCTAssertEqual(sandbox.ghRegisteredKeys("signing").count, 1, "the rest of the item still ran")
    }

    func testFallsBackToKeyscanAndKeepsExistingKnownHosts() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeGh(hostKeys: [])
        let scanned = gitHubHostKeyLines.map { "github.com \($0)" }.joined(separator: "\n")
        sandbox.shim("ssh-keyscan", "echo '# github.com:22 SSH-2.0-babeld' >&2\ncat <<'EOF'\n\(scanned)\nEOF")
        sandbox.generateKey()
        sandbox.ghSignedIn()
        sandbox.writeHome(".ssh/known_hosts", "example.org ssh-ed25519 AAAAexisting", permissions: 0o600)
        let (action, item, plan) = try sandbox.single(GitHubAction.self, items)

        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.calls("ssh-keyscan"), [["-t", "ed25519,ecdsa,rsa", "github.com"]])
        XCTAssertEqual(sandbox.readHome(".ssh/known_hosts"), "example.org ssh-ed25519 AAAAexisting\n" + scanned + "\n")
    }

    func testKnownHostsWithGitHubIsLeftAlone() async throws {
        let (sandbox, action, item, plan) = try prepared()
        sandbox.ghSignedIn()
        let existing = "github.com \(gitHubHostKeyLines[0])\n"
        sandbox.writeHome(".ssh/known_hosts", existing, permissions: 0o644)
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.readHome(".ssh/known_hosts"), existing)
        XCTAssertFalse(sandbox.calls("gh").contains { $0.contains("meta") })
    }

    func testOtherHostsGetAFollowUpInsteadOfTrustOnFirstUse() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeGh()
        sandbox.ghSignedIn("example.ghe.com", scopes: "gist, read:org, repo")
        let (action, item, plan) = try sandbox.single(GitHubAction.self, "  - github: example.ghe.com\n    setup_git: false")
        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .needsAttention("already set up; example.ghe.com host key needs checking by hand"))
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Add example.ghe.com's SSH host key"])
        XCTAssertFalse(sandbox.existsInHome(".ssh/known_hosts"))
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("signed in as shawntz"))
    }

    func testDryRunOnlyProbes() async throws {
        let (sandbox, action, item, plan) = try prepared()
        let outcome = try await action.run(sandbox.context(item, plan, dryRun: true))
        XCTAssertEqual(outcome, .done("would sign in to github.com"))
        let mutating = sandbox.calls("gh").filter { !["status"].contains($0.dropFirst().first ?? "") && $0.first != "api" }
        XCTAssertEqual(mutating, [], "only read-only gh calls run in a dry run")
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ gh auth login --hostname github.com --web"), sandbox.logText)
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ gh ssh-key add"), sandbox.logText)
        XCTAssertFalse(sandbox.existsInHome(".ssh/known_hosts"))
        XCTAssertEqual(sandbox.attentions.compactMap { $0 }, [], "no code is shown in a dry run")
    }

    func testTokensAndHostOverridesNeverReachGh() async throws {
        var base = ProcessInfo.processInfo.environment
        base["GH_TOKEN"] = "ghp_should_not_leak"
        base["GITHUB_TOKEN"] = "ghp_nor_this"
        base["GH_HOST"] = "evil.example.com"
        base["CLICOLOR_FORCE"] = "1"
        let (sandbox, action, item, plan) = try prepared(baseEnvironment: base)
        _ = try await action.run(sandbox.context(item, plan))
        let seen = sandbox.lastEnvironment("gh")
        XCTAssertNil(seen["GH_TOKEN"])
        XCTAssertNil(seen["GITHUB_TOKEN"])
        XCTAssertNil(seen["CLICOLOR_FORCE"])
        XCTAssertEqual(seen["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(seen["NO_COLOR"], "1")
        XCTAssertEqual(seen["HOME"], sandbox.home.path)
        // The last gh call was the signing-key upload, which must name the host itself.
        XCTAssertEqual(seen["GH_HOST"], "github.com")
    }
}
