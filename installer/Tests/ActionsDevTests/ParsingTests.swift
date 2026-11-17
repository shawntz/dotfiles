import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

final class ParsingTests: XCTestCase {
    func testEveryKindIsRegisteredAndItsExampleIsValid() throws {
        let kinds = DevActions.descriptors.map(\.kind)
        XCTAssertEqual(kinds, ["git-config", "ssh-key", "github", "git-signing", "clone", "skill", "claude-plugin"])

        let sandbox = DevSandbox()
        for descriptor in DevActions.descriptors {
            XCTAssertFalse(descriptor.summary.isEmpty)
            let items = descriptor.example.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
            let plan = try sandbox.plan(items: items, files: ["skills/unslop/SKILL.md": "---\nname: unslop\n---\n"])
            XCTAssertEqual(plan.errors.map(\.description), [], "example for \(descriptor.kind) should be valid:\n\(descriptor.example)")
            XCTAssertFalse(plan.allItems.isEmpty)
        }
    }

    func testTitles() throws {
        let sandbox = DevSandbox()
        let plan = try sandbox.plan(items: """
          - git-config:
              user.name: "{{full_name}}"
          - ssh-key: ~/.ssh/id_ed25519
          - github: github.com
          - git-signing: ~/.ssh/id_ed25519.pub
          - clone: owner/repo
            to: ~/Developer/repo
          - skill: find-skills
            source: vercel-labs/skills
          - claude-plugin: swift-lsp@claude-plugins-official
        """)
        XCTAssertEqual(plan.errors, [])
        XCTAssertEqual(plan.allItems.map(\.title), [
            "Git identity & settings", "~/.ssh/id_ed25519", "GitHub (github.com)", "Git commit signing",
            "owner/repo", "find-skills", "swift-lsp@claude-plugins-official",
        ])
    }

    func testGitConfigRejectsBadShapes() throws {
        let sandbox = DevSandbox()
        let notMapping = try sandbox.problems(items: "  - git-config: user.name")
        XCTAssertTrue(notMapping.contains { $0.contains("must be a mapping of git keys") }, "\(notMapping)")

        let problems = try sandbox.problems(items: """
          - git-config:
              user: Shawn
              user.email: [a, b]
              core.excludesFile: ~/.config/git/ignore
        """)
        XCTAssertTrue(problems.contains { $0.contains("'user' is not a git config key") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'user.email' must be a single value") }, "\(problems)")
        XCTAssertEqual(problems.count, 2, "\(problems)")
    }

    /// ~/.gitconfig.local can only override what comes before its include, so in the shipped git step the
    /// include must follow every item that writes the global git config.
    func testTheShippedGitStepIncludesGitconfigLocalLast() throws {
        let step = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/steps/06-git.yaml")
        let lines = try String(contentsOf: step, encoding: .utf8).components(separatedBy: "\n")
        func line(_ text: String) throws -> Int {
            try XCTUnwrap(lines.lastIndex { $0.contains(text) && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }, "\(text) not in 06-git.yaml")
        }
        let include = try line("include.path: ~/.gitconfig.local")
        for writer in ["user.email:", "git lfs install", "- github:", "- git-signing:"] {
            XCTAssertGreaterThan(include, try line(writer), "the include must come after \(writer)")
        }
    }

    func testGitConfigKeyShapes() {
        XCTAssertTrue(GitConfigAction.isValidKey("user.name"))
        XCTAssertTrue(GitConfigAction.isValidKey("credential.https://github.com.helper"))
        XCTAssertTrue(GitConfigAction.isValidKey("url.git@github.com:.insteadOf"))
        XCTAssertFalse(GitConfigAction.isValidKey("user"))
        XCTAssertFalse(GitConfigAction.isValidKey("user."))
        XCTAssertFalse(GitConfigAction.isValidKey("1user.name"))
    }

    func testUnknownOptionsGetSuggestions() throws {
        let problems = try DevSandbox().problems(items: """
          - ssh-key: ~/.ssh/id_ed25519
            coment: hi
        """)
        XCTAssertTrue(problems.contains { $0.contains("unknown key 'coment'. Did you mean 'comment'?") }, "\(problems)")
    }

    func testUnknownVariablesAreReported() throws {
        let problems = try DevSandbox().problems(items: """
          - git-config:
              user.name: "{{fullname}}"
          - git-signing: ~/.ssh/id_ed25519.pub
            email: "{{mail}}"
        """)
        XCTAssertTrue(problems.contains { $0.contains("unknown variable {{fullname}}") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("unknown variable {{mail}}") }, "\(problems)")
    }

    func testSSHKeyOptions() throws {
        let sandbox = DevSandbox()
        let problems = try sandbox.problems(items: """
          - ssh-key: ~/.ssh/id_ed25519.pub
            type: dsa
        """)
        XCTAssertTrue(problems.contains { $0.contains("takes the PRIVATE key path") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'type' must be one of: ed25519, ecdsa, rsa") }, "\(problems)")

        let (action, _, _) = try sandbox.single(SSHKeyAction.self, """
          - ssh-key: ~/.ssh/id_ed25519
            hosts: [github.com, gitlab.com]
            config: false
        """)
        XCTAssertEqual(action.type, "ed25519")
        XCTAssertEqual(action.comment, "{{email}}")
        XCTAssertEqual(action.hosts, ["github.com", "gitlab.com"])
        XCTAssertFalse(action.manageConfig)
    }

    func testGitHubOptions() throws {
        let sandbox = DevSandbox()
        let (defaults, _, _) = try sandbox.single(GitHubAction.self, """
          - github: github.com
            key: ~/.ssh/id_ed25519.pub
        """)
        XCTAssertEqual(defaults.gitProtocol, "ssh")
        XCTAssertEqual(defaults.uploadTypes, ["authentication", "signing"])
        XCTAssertEqual(defaults.keyTitle, "{{hostname}}")
        XCTAssertTrue(defaults.seedKnownHosts)
        XCTAssertTrue(defaults.setupGit)
        XCTAssertEqual(defaults.deviceFlowTimeout, 15 * 60)
        XCTAssertEqual(defaults.neededScopes, ["write:public_key", "write:ssh_signing_key"])
        XCTAssertEqual(defaults.requestedScopes(for: defaults.neededScopes), ["admin:public_key", "admin:ssh_signing_key"])

        let (bare, _, _) = try sandbox.single(GitHubAction.self, """
          - github: example.ghe.com
            protocol: https
            scopes: [workflow, "repo"]
        """)
        XCTAssertEqual(bare.uploadTypes, [])
        XCTAssertEqual(bare.neededScopes, ["workflow", "repo"])
        XCTAssertEqual(bare.requestedScopes(for: bare.neededScopes), ["workflow"], "gh grants repo anyway")

        let problems = try sandbox.problems(items: """
          - github: https://github.com
            upload: [authentication, deploy]
          - github: github.com
            key: ~/.ssh/id_ed25519
        """)
        XCTAssertTrue(problems.contains { $0.contains("takes a host name such as github.com") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'upload' entries must be authentication or signing (got 'deploy')") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'upload' needs 'key:'") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'key' must be the PUBLIC key") }, "\(problems)")
    }

    func testGitSigningOptions() throws {
        let sandbox = DevSandbox()
        let problems = try sandbox.problems(items: "  - git-signing: ~/.ssh/id_ed25519")
        XCTAssertTrue(problems.contains { $0.contains("takes the PUBLIC key path") }, "\(problems)")

        let (action, _, _) = try sandbox.single(GitSigningAction.self, """
          - git-signing: ~/.ssh/id_ed25519.pub
            tags: false
        """)
        XCTAssertEqual(action.email, "{{email}}")
        XCTAssertTrue(action.commits)
        XCTAssertFalse(action.tags)
    }

    func testCloneOptions() throws {
        let sandbox = DevSandbox()
        let problems = try sandbox.problems(items: """
          - clone: "not a repo"
            to: ~/x
          - clone: owner/repo
          - clone: https://example.com/a.git
            to: ~/a
            protocol: ssh
          - clone: owner/repo
            to: ~/b
            protocol: ftp
        """)
        XCTAssertTrue(problems.contains { $0.contains("'not a repo' is neither owner/repo nor a git URL") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("missing required key 'to'") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'protocol' only applies to owner/repo") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'protocol' must be one of: ssh, https (got 'ftp')") }, "\(problems)")

        // Variables are expanded before the repository is classified.
        let (action, _, _) = try sandbox.single(CloneAction.self, """
          - clone: "{{dotfiles_repo}}"
            to: ~/Developer/dotfiles
            branch: main
        """)
        XCTAssertNil(action.protocolOverride)
        XCTAssertEqual(action.branch, "main")
    }

    func testCloneClassification() {
        XCTAssertEqual(CloneAction.classify("shawntz/dotfiles"), .github(owner: "shawntz", name: "dotfiles"))
        XCTAssertEqual(CloneAction.classify("shawntz/dotfiles.git"), .github(owner: "shawntz", name: "dotfiles.git"))
        XCTAssertEqual(CloneAction.classify("git@github.com:shawntz/dotfiles.git"), .url("git@github.com:shawntz/dotfiles.git"))
        XCTAssertEqual(CloneAction.classify("https://gitlab.com/a/b.git"), .url("https://gitlab.com/a/b.git"))
        XCTAssertEqual(CloneAction.classify("/srv/repo.git"), .url("/srv/repo.git"))
        XCTAssertNil(CloneAction.classify("./relative"))
        XCTAssertNil(CloneAction.classify("just-a-name"))
        XCTAssertEqual(CloneAction.githubURL(owner: "a", name: "b", protocol: "ssh"), "git@github.com:a/b.git")
        XCTAssertEqual(CloneAction.githubURL(owner: "a", name: "b.git", protocol: "https"), "https://github.com/a/b.git")
    }

    func testCloneRecognizesTheConfigsOwnRepository() {
        func repository(_ text: String) -> String? { CloneAction.classify(text).flatMap(CloneAction.githubRepository) }
        XCTAssertEqual(repository("shawntz/dotfiles"), "shawntz/dotfiles")
        XCTAssertEqual(repository("shawntz/dotfiles.git"), "shawntz/dotfiles")
        XCTAssertEqual(repository("https://github.com/shawntz/dotfiles"), "shawntz/dotfiles")
        XCTAssertEqual(repository("https://github.com/shawntz/dotfiles.git"), "shawntz/dotfiles")
        XCTAssertEqual(repository("https://www.GitHub.com/shawntz/dotfiles.git/"), "shawntz/dotfiles")
        XCTAssertEqual(repository("git@github.com:shawntz/dotfiles.git"), "shawntz/dotfiles")
        XCTAssertEqual(repository("ssh://git@github.com/shawntz/dotfiles.git"), "shawntz/dotfiles")
        XCTAssertEqual(repository("ssh://git@github.com:22/shawntz/dotfiles"), "shawntz/dotfiles")
        XCTAssertEqual(repository("ssh://git@ssh.github.com:443/shawntz/dotfiles.git"), "shawntz/dotfiles", "GitHub's ssh over port 443")
        XCTAssertEqual(repository("git@ssh.github.com:shawntz/dotfiles.git"), "shawntz/dotfiles")
        XCTAssertNil(repository("git@github-personal:shawntz/dotfiles.git"), "an ssh host alias: only ssh knows where it leads")
        XCTAssertNil(repository("https://gitlab.com/shawntz/dotfiles.git"), "another host")
        XCTAssertNil(repository("https://github.com.example.org/shawntz/dotfiles.git"), "a host that only starts like GitHub")
        XCTAssertNil(repository("https://github.com/shawntz/dotfiles/tree/master"), "a page of the repository, not the repository")
        XCTAssertNil(repository("https://github.com/shawntz"), "an owner without a name")
        XCTAssertNil(repository("/srv/shawntz/dotfiles.git"), "a folder")

        let remote = RemoteConfigRef(repo: "shawntz/dotfiles", branch: "master", path: "installer/config")
        XCTAssertTrue(CloneAction.isConfigRepository(.github(owner: "shawntz", name: "dotfiles"), remote: remote))
        XCTAssertTrue(CloneAction.isConfigRepository(.github(owner: "Shawntz", name: "Dotfiles.git"), remote: remote), "GitHub ignores letter case")
        XCTAssertTrue(CloneAction.isConfigRepository(.url("git@github.com:shawntz/dotfiles.git"), remote: remote))
        XCTAssertFalse(CloneAction.isConfigRepository(.github(owner: "shawntz", name: "dotfiles-old"), remote: remote))
        XCTAssertFalse(CloneAction.isConfigRepository(.github(owner: "someone", name: "dotfiles"), remote: remote), "a fork is another repository")
        XCTAssertFalse(CloneAction.isConfigRepository(.github(owner: "shawntz", name: "dotfiles"), remote: nil), "a config without remote:")
        XCTAssertFalse(CloneAction.isConfigRepository(nil, remote: remote))
    }

    func testSkillOptions() throws {
        let sandbox = DevSandbox()
        let files = ["skills/nodoc/README.md": "no skill file here"]
        let problems = try sandbox.problems(items: """
          - skill: missing
          - skill: nodoc
          - skill: both
            from: skills/both
            source: owner/repo
          - skill: picky
            source: owner/repo
            agents: [claude, cursor]
          - skill: "bad/name"
            source: owner/repo
          - skill: fetched
            source: owner/repo
            replace_existing: true
        """, files: files)
        XCTAssertTrue(problems.contains { $0.contains("'replace_existing' only applies to bundled skills") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("bundled skill folder 'skills/missing' does not exist") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("bundled skill folder 'skills/nodoc' has no SKILL.md") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("use either 'from:'") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'agents' entries must be claude, codex or grok (got 'cursor')") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("skill names may only contain") }, "\(problems)")

        let (bundled, _, _) = try sandbox.single(SkillAction.self, """
          - skill: demo
            from: extras/demo
            agents: [grok, claude]
        """, files: ["extras/demo/SKILL.md": "x"])
        XCTAssertEqual(bundled.origin, .bundled("extras/demo"))
        XCTAssertEqual(bundled.agents, ["claude", "grok"])
        XCTAssertFalse(bundled.replaceExisting, "their own copies are left alone unless the item says otherwise")

        let (replacing, _, _) = try sandbox.single(SkillAction.self, "  - skill: demo\n    from: extras/demo\n    replace_existing: true",
                                                   files: ["extras/demo/SKILL.md": "x"])
        XCTAssertTrue(replacing.replaceExisting)

        let (upstream, _, _) = try sandbox.single(SkillAction.self, """
          - skill: marimo-pair
            source: marimo-team/marimo-pair
        """)
        XCTAssertEqual(upstream.origin, .upstream("marimo-team/marimo-pair"))
        XCTAssertEqual(upstream.agents, ["claude", "codex", "grok"])
    }

    func testClaudePluginOptions() throws {
        let sandbox = DevSandbox()
        let problems = try sandbox.problems(items: """
          - claude-plugin: stripe
          - claude-plugin: warp@claude-code-warp
            scope: global
        """)
        XCTAssertTrue(problems.contains { $0.contains("must look like name@marketplace") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("'scope' must be one of: user, project, local") }, "\(problems)")

        let (action, _, _) = try sandbox.single(ClaudePluginAction.self, """
          - claude-plugin: warp@claude-code-warp
            marketplace: warpdotdev/claude-code-warp
        """)
        XCTAssertEqual(action.marketplaceName, "claude-code-warp")
        XCTAssertEqual(action.scope, "user")
        XCTAssertEqual(action.marketplaceSource, "warpdotdev/claude-code-warp")
    }
}
