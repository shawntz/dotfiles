import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

/// The whole git/skills step as the installer runs it: through `InstallEngine`, twice.
final class EngineIntegrationTests: XCTestCase {
    func testFullDeveloperStepRunsThenIsAlreadyDone() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeGh()
        sandbox.installFakeNpx()
        sandbox.installFakeClaude()

        let work = sandbox.root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        sandbox.git(["init", "-q", "-b", "main"], in: work)
        try "hi\n".write(to: work.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        sandbox.git(["add", "."], in: work)
        sandbox.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init"], in: work)

        let plan = try sandbox.plan(items: """
          - git-config:
              user.name: "{{full_name}}"
              user.email: "{{email}}"
              init.defaultBranch: main
          - ssh-key: ~/.ssh/id_ed25519
            hosts: [github.com]
          - github: github.com
            key: ~/.ssh/id_ed25519.pub
          - git-signing: ~/.ssh/id_ed25519.pub
          - skill: demo
          - skill: find-skills
            source: vercel-labs/skills
          - claude-plugin: swift-lsp@claude-plugins-official
          - claude-plugin: warp@claude-code-warp
            marketplace: warpdotdev/claude-code-warp
          - clone: \(work.path)
            to: ~/Developer/work
        """, files: ["skills/demo/SKILL.md": "---\nname: demo\n---\n"])
        XCTAssertEqual(plan.errors, [])

        let first = Recorder<InstallEvent>()
        let engine = InstallEngine(plan: plan, environment: sandbox.environment)
        let summary = await engine.run(selection: .defaults(for: plan)) { first.add($0) }
        XCTAssertEqual(summary.failures.map { "\($0.title): \($0.message)" }, [])
        XCTAssertEqual(summary.done, 9)
        XCTAssertEqual(summary.followUps, [])
        let codes = first.all.compactMap { event -> String? in
            if case .attention(_, let attention?) = event { return attention.code }
            return nil
        }
        XCTAssertEqual(codes.last, "1A2B-C3D4", "the GitHub code reached the UI through the engine")

        // The pieces fit together: signing uses the key ssh-key made, which github uploaded.
        let pub = try XCTUnwrap(SSHPublicKey(line: sandbox.readHome(".ssh/id_ed25519.pub") ?? ""))
        XCTAssertEqual(sandbox.ghRegisteredKeys("signing"), [pub.material])
        XCTAssertTrue(sandbox.readHome(".config/git/allowed_signers")?.contains("test@example.com namespaces=\"git\" \(pub.material)") == true)
        XCTAssertEqual(sandbox.globalGitConfig("user.signingkey"), sandbox.homeURL(".ssh/id_ed25519.pub").path)

        sandbox.clearShimLog()
        let again = await InstallEngine(plan: plan, environment: sandbox.environment).run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(again.failures.map(\.message), [])
        XCTAssertEqual(again.alreadyDone, 9, "a second run finds everything in place")
        let mutating = (sandbox.calls("gh") + sandbox.calls("claude") + sandbox.calls("npx")).filter { call in
            !(call.starts(with: ["auth", "status"]) || call.first == "api" || call.starts(with: ["plugin", "list"]))
        }
        XCTAssertEqual(mutating, [], "only read-only probes on the second run")
    }

    func testDryRunOfTheWholeStepChangesNothing() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeGh()
        sandbox.installFakeNpx()
        sandbox.installFakeClaude()
        let plan = try sandbox.plan(items: """
          - git-config:
              user.name: "{{full_name}}"
          - ssh-key: ~/.ssh/id_ed25519
          - github: github.com
            key: ~/.ssh/id_ed25519.pub
          - git-signing: ~/.ssh/id_ed25519.pub
          - skill: demo
          - skill: find-skills
            source: vercel-labs/skills
          - claude-plugin: swift-lsp@claude-plugins-official
          - clone: tester/dotfiles
            to: ~/Developer/dotfiles
        """, files: ["skills/demo/SKILL.md": "x"])

        let engine = InstallEngine(plan: plan, environment: sandbox.environment, options: RunOptions(dryRun: true))
        let summary = await engine.run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(summary.failures.map(\.message), [])
        XCTAssertTrue(summary.wasDryRun)

        let home = try FileManager.default.contentsOfDirectory(atPath: sandbox.home.path)
        XCTAssertEqual(home.filter { $0 != "Library" }, [], "nothing but the engine's own logs appears in the home folder")
        XCTAssertEqual(sandbox.ghRegisteredKeys("authentication"), [])
        XCTAssertEqual(sandbox.claudePlugins, [])
        XCTAssertEqual(sandbox.calls("npx"), [])
    }
}
