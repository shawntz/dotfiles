import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

/// git-config, ssh-key and git-signing against the real git and /usr/bin/ssh-keygen, with HOME in the sandbox.
final class GitConfigTests: XCTestCase {
    private let items = """
      - git-config:
          user.name: "{{full_name}}"
          user.email: "{{email}}"
          init.defaultBranch: main
          pull.rebase: true
          core.excludesFile: "{{home}}/.config/git/ignore"
    """

    func testSetsValuesAndIsIdempotent() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, items)
        let context = sandbox.context(item, plan)

        guard case .needed = await action.check(context) else { return XCTFail("fresh home needs git config") }
        let outcome = try await action.run(context)
        XCTAssertEqual(outcome, .done("set user.name, user.email, init.defaultBranch, pull.rebase, core.excludesFile"))

        XCTAssertEqual(sandbox.globalGitConfig("user.name"), "Test Person")
        XCTAssertEqual(sandbox.globalGitConfig("user.email"), "test@example.com")
        XCTAssertEqual(sandbox.globalGitConfig("init.defaultBranch"), "main")
        XCTAssertEqual(sandbox.globalGitConfig("pull.rebase"), "true")
        XCTAssertEqual(sandbox.globalGitConfig("core.excludesFile"), sandbox.home.path + "/.config/git/ignore")
        XCTAssertTrue(sandbox.existsInHome(".gitconfig"), "git --global wrote the sandbox home, nowhere else")

        sandbox.newRun()
        let again = sandbox.context(item, plan)
        assertEqual(await action.check(again), .satisfied("all 5 values already set"))
        let before = sandbox.logLines.count
        assertEqual(try await action.run(again), .done("already set"))
        XCTAssertFalse(sandbox.logLines.dropFirst(before).contains { $0.style == .command }, "a second run changes nothing")
    }

    func testBooleansCompareTheWayGitReadsThem() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".gitconfig", "[pull]\n\trebase = yes\n")
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      pull.rebase: true")
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("the value is already set"))
    }

    /// A key set several times keeps every value; the wanted one is added last, which is the one git reads.
    func testAKeyWithSeveralValuesIsAddedToNotCollapsed() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".gitconfig", "[user]\n\tname = One\n\tname = Two\n")
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      user.name: Three")
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("set user.name"))
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "user.name"]), "One\nTwo\nThree")
        XCTAssertEqual(sandbox.globalGitConfig("user.name"), "Three")
        XCTAssertTrue(sandbox.logText.contains("user.name has 2 values (One, Two); adding Three after them"), sandbox.logText)

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("the value is already set"))
    }

    func testOverwritingASettingLogsWhatItWas() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".gitconfig", "[user]\n\temail = old@example.com\n")
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      user.email: \"{{email}}\"")
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "user.email"]), "test@example.com")
        XCTAssertTrue(sandbox.logText.contains("user.email was old@example.com; setting it to test@example.com"), sandbox.logText)
    }

    /// List keys (url.*.insteadOf, credential helpers, ...) get the value added; nothing there is removed.
    func testListKeysAreAddedTo() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".gitconfig", "[url \"git@work.example.com:\"]\n\tinsteadOf = https://work.example.com/\n[safe]\n\tdirectory = /opt/x\n")
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, """
          - git-config:
              url.git@work.example.com:.insteadOf: https://git.work.example.com/
              safe.directory: /opt/x
        """)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("1 of 2 to set: url.git@work.example.com:.insteadOf"))
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "url.git@work.example.com:.insteadOf"]),
                       "https://work.example.com/\nhttps://git.work.example.com/")
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "safe.directory"]), "/opt/x")
        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("all 2 values already set"))
    }

    /// The reviewers' case: an existing [include] is kept, not replaced by ~/.gitconfig.local.
    func testIncludePathKeepsTheOtherIncludes() async throws {
        let sandbox = DevSandbox()
        let original = "[include]\n\tpath = ~/.config/git/work.gitconfig\n"
        sandbox.writeHome(".gitconfig", original)
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      include.path: ~/.gitconfig.local")
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("1 of 1 to set: include.path"))

        assertEqual(try await action.run(sandbox.context(item, plan)), .done("set include.path"))
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "include.path"]), "~/.config/git/work.gitconfig\n~/.gitconfig.local")
        XCTAssertEqual(sandbox.readHome(".gitconfig"), original + "[include]\n\tpath = ~/.gitconfig.local\n")
        XCTAssertEqual(try String(contentsOf: sandbox.environment.backupDirectory.appendingPathComponent(".gitconfig"), encoding: .utf8), original,
                       "the file was backed up before it was rewritten")

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("the value is already set"))

        // Later the person adds another include of their own: it stays, and nothing needs doing.
        sandbox.git(["config", "--global", "--add", "include.path", "~/.gitconfig.third"])
        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("the value is already set"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("already set"))
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "include.path"]),
                       "~/.config/git/work.gitconfig\n~/.gitconfig.local\n~/.gitconfig.third")
    }

    func testAnIncludeAlreadyLastIsLeftAlone() async throws {
        let sandbox = DevSandbox()
        let text = "[user]\n\tname = Me\n[include]\n\tpath = ~/.gitconfig.local\n\tpath = ~/.gitconfig.work\n"
        sandbox.writeHome(".gitconfig", text)
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      include.path: ~/.gitconfig.local")
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("the value is already set"))

        // With the .local line gone, it is added back and the .work one stays.
        sandbox.writeHome(".gitconfig", "[user]\n\tname = Me\n[include]\n\tpath = ~/.gitconfig.work\n")
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "include.path"]), "~/.gitconfig.work\n~/.gitconfig.local")
    }

    /// Settings written after the include (LFS, gh, signing) are moved above it, so ~/.gitconfig.local
    /// can override them. Only the include itself moves; the person's other includes stay where they are.
    func testAnIncludeIsMovedBelowSettingsWrittenAfterIt() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".gitconfig", """
        [user]
        \tname = Me
        [include]
        \tpath = ~/.gitconfig.work
        \tpath = ~/.gitconfig.local
        [filter "lfs"]
        \tprocess = git-lfs filter-process

        """)
        sandbox.writeHome(".gitconfig.local", "[filter \"lfs\"]\n\tprocess = local-filter\n")
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      include.path: ~/.gitconfig.local")
        XCTAssertEqual(sandbox.git(["config", "--global", "--includes", "--get", "filter.lfs.process"]), "git-lfs filter-process", "the bug: .local cannot override")
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("1 of 1 to set: include.path"))

        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "include.path"]), "~/.gitconfig.work\n~/.gitconfig.local")
        let list = sandbox.git(["config", "--global", "--list"]).components(separatedBy: "\n")
        XCTAssertEqual(list.last, "include.path=~/.gitconfig.local", "\(list)")
        XCTAssertEqual(sandbox.git(["config", "--global", "--includes", "--get", "filter.lfs.process"]), "local-filter")
        XCTAssertTrue(sandbox.logText.contains("moving include.path ~/.gitconfig.local to the end of ~/.gitconfig"), sandbox.logText)

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("the value is already set"))
    }

    /// The order config/steps/06-git.yaml uses, with real git: identity, the SSH key, signing, then the
    /// include. ~/.gitconfig.local then overrides signing and identity, and a second run changes nothing.
    func testGitconfigLocalOverridesWhatTheGitStepWrites() async throws {
        let sandbox = DevSandbox()
        let plan = try sandbox.plan(items: """
          - git-config:
              user.name: "{{full_name}}"
              user.email: "{{email}}"
              init.defaultBranch: main
          - ssh-key: ~/.ssh/id_ed25519
            hosts: [github.com]
          - git-signing: ~/.ssh/id_ed25519.pub
          - git-config:
              include.path: ~/.gitconfig.local
        """)
        XCTAssertEqual(plan.errors, [])
        let first = await InstallEngine(plan: plan, environment: sandbox.environment).run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(first.failures.map(\.message), [])
        XCTAssertEqual(first.done, 4)

        sandbox.writeHome(".gitconfig.local", "[commit]\n\tgpgsign = false\n[gpg]\n\tformat = openpgp\n[user]\n\temail = work@example.com\n")
        func effective(_ key: String) -> String { sandbox.git(["config", "--global", "--includes", "--get", key]) }
        XCTAssertEqual(effective("commit.gpgsign"), "false")
        XCTAssertEqual(effective("gpg.format"), "openpgp")
        XCTAssertEqual(effective("user.email"), "work@example.com")
        XCTAssertEqual(effective("tag.gpgsign"), "true", "what .local does not mention still comes from the step")

        let again = await InstallEngine(plan: plan, environment: sandbox.environment).run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(again.failures.map(\.message), [])
        XCTAssertEqual(again.alreadyDone, 4, "a second run finds everything in place")

        // A tool that writes after the include (here, what `git lfs install` adds) is moved above it on the next run.
        sandbox.git(["config", "--global", "filter.lfs.required", "true"])
        sandbox.writeHome(".gitconfig.local", "[filter \"lfs\"]\n\trequired = false\n")
        XCTAssertEqual(effective("filter.lfs.required"), "true")
        let third = await InstallEngine(plan: plan, environment: sandbox.environment).run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(third.done, 1)
        XCTAssertEqual(effective("filter.lfs.required"), "false")
        XCTAssertEqual(sandbox.git(["config", "--global", "--get-all", "include.path"]), "~/.gitconfig.local", "moved, not duplicated")
    }

    func testDryRunWritesNothing() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, items)
        _ = try await action.run(sandbox.context(item, plan, dryRun: true))
        XCTAssertFalse(sandbox.existsInHome(".gitconfig"))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ git config --global user.name 'Test Person'"), sandbox.logText)

        let original = "[include]\n\tpath = ~/.gitconfig.local\n[gpg]\n\tformat = ssh\n"
        sandbox.writeHome(".gitconfig", original)
        let (include, includeItem, includePlan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      include.path: ~/.gitconfig.local")
        _ = try await include.run(sandbox.context(includeItem, includePlan, dryRun: true))
        XCTAssertEqual(sandbox.readHome(".gitconfig"), original)
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ git config --global --fixed-value --unset-all include.path ~/.gitconfig.local"), sandbox.logText)
        XCTAssertTrue(sandbox.logText.contains("[dry-run] update ~/.gitconfig"), sandbox.logText)
    }

    func testAnUnreadableConfigIsReportedNotOverwritten() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".gitconfig", "[user\n\tname = broken\n")
        let (action, item, plan) = try sandbox.single(GitConfigAction.self, "  - git-config:\n      user.name: Me")
        guard case .needed(let why?) = await action.check(sandbox.context(item, plan)) else { return XCTFail("must be needed") }
        XCTAssertTrue(why.contains("git cannot read the global git config"), why)
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertTrue(error?.message.contains("bad config line 1") == true, "\(String(describing: error))")
        XCTAssertEqual(sandbox.readHome(".gitconfig"), "[user\n\tname = broken\n")
    }
}

final class SSHKeyTests: XCTestCase {
    private let items = """
      - ssh-key: ~/.ssh/id_ed25519
        hosts: [github.com]
    """

    func testGeneratesKeyAndConfigBlock() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, items)
        let context = sandbox.context(item, plan)
        assertEqual(await action.check(context), .needed("no key at ~/.ssh/id_ed25519 yet"))

        let outcome = try await action.run(context)
        XCTAssertEqual(outcome, .done("created ~/.ssh/id_ed25519; updated ~/.ssh/config"))
        XCTAssertEqual(sandbox.permissions(".ssh"), 0o700)
        XCTAssertEqual(sandbox.permissions(".ssh/id_ed25519"), 0o600)
        XCTAssertEqual(sandbox.permissions(".ssh/id_ed25519.pub"), 0o644)
        XCTAssertEqual(sandbox.permissions(".ssh/config"), 0o600)

        let pub = try XCTUnwrap(sandbox.readHome(".ssh/id_ed25519.pub"))
        XCTAssertTrue(pub.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(pub.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(" test@example.com"), "comment defaults to {{email}}: \(pub)")

        XCTAssertEqual(sandbox.readHome(".ssh/config"), """
        # >>> shawn-dotfiles ssh-key ~/.ssh/id_ed25519 >>>
        # Managed by Shawn's Dotfiles: changes inside these markers are replaced on the next install.
        Host github.com
          User git
          IdentitiesOnly yes

        Host *
          IgnoreUnknown UseKeychain
          AddKeysToAgent yes
          UseKeychain yes
          IdentityFile ~/.ssh/id_ed25519
        # <<< shawn-dotfiles ssh-key ~/.ssh/id_ed25519 <<<

        """)

        // ssh itself accepts the file: -G parses it (no connection is made).
        let parse = Process()
        parse.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        parse.arguments = ["-G", "-F", sandbox.homeURL(".ssh/config").path, "github.com"]
        let output = Pipe()
        parse.standardOutput = output
        parse.standardError = Pipe()
        parse.standardInput = FileHandle.nullDevice
        try parse.run()
        parse.waitUntilExit()
        let resolved = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(parse.terminationStatus, 0)
        XCTAssertTrue(resolved.contains("user git"), resolved)
        XCTAssertTrue(resolved.contains("identitiesonly yes"), resolved)

        sandbox.newRun()
        let privateKey = sandbox.readHome(".ssh/id_ed25519")
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("key exists"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("already set up"))
        XCTAssertEqual(sandbox.readHome(".ssh/id_ed25519"), privateKey)
    }

    func testNeverOverwritesAnExistingKey() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".ssh/id_ed25519", "EXISTING PRIVATE KEY\n", permissions: 0o600)
        sandbox.writeHome(".ssh/id_ed25519.pub", gitHubHostKeyLines[0] + " old\n")
        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, items)
        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("updated ~/.ssh/config"))
        XCTAssertEqual(sandbox.readHome(".ssh/id_ed25519"), "EXISTING PRIVATE KEY\n")
        XCTAssertEqual(sandbox.readHome(".ssh/id_ed25519.pub"), gitHubHostKeyLines[0] + " old\n")
    }

    func testRestoresAMissingPublicKey() async throws {
        let sandbox = DevSandbox()
        let key = sandbox.generateKey()
        let original = try XCTUnwrap(sandbox.readHome(".ssh/id_ed25519.pub"))
        try FileManager.default.removeItem(atPath: key.path + ".pub")

        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, "  - ssh-key: ~/.ssh/id_ed25519\n    config: false")
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("~/.ssh/id_ed25519.pub is missing"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("restored ~/.ssh/id_ed25519.pub"))
        let restored = try XCTUnwrap(sandbox.readHome(".ssh/id_ed25519.pub"))
        XCTAssertEqual(SSHPublicKey(line: restored)?.material, SSHPublicKey(line: original)?.material)
        XCTAssertFalse(sandbox.existsInHome(".ssh/config"), "config: false leaves ~/.ssh/config alone")
    }

    func testReplacesTheBlockInPlaceAndKeepsEverythingElse() async throws {
        let sandbox = DevSandbox()
        sandbox.generateKey()
        let before = "Include ~/.orbstack/ssh/config\n\nHost work\n    HostName 10.0.0.1\n\t# user comment\n\n"
        let after = "\nHost *.internal\n  ProxyJump bastion\n"
        let stale = "# >>> shawn-dotfiles ssh-key ~/.ssh/id_ed25519 >>>\nHost *\n  IdentityFile ~/.ssh/old\n# <<< shawn-dotfiles ssh-key ~/.ssh/id_ed25519 <<<"
        sandbox.writeHome(".ssh/config", before + stale + after)

        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, items)
        guard case .needed = await action.check(sandbox.context(item, plan)) else { return XCTFail("stale block must be replaced") }
        _ = try await action.run(sandbox.context(item, plan))

        let text = try XCTUnwrap(sandbox.readHome(".ssh/config"))
        XCTAssertTrue(text.hasPrefix(before), "everything before the block is untouched")
        XCTAssertTrue(text.hasSuffix("# <<< shawn-dotfiles ssh-key ~/.ssh/id_ed25519 <<<" + after), "everything after the block is untouched")
        XCTAssertFalse(text.contains("~/.ssh/old"))
        XCTAssertTrue(text.contains("  IdentityFile ~/.ssh/id_ed25519\n"))
        XCTAssertEqual(text.components(separatedBy: ">>> shawn-dotfiles").count, 2, "exactly one block")

        let backups = sandbox.environment.backupDirectory.appendingPathComponent(".ssh/config")
        XCTAssertEqual(try String(contentsOf: backups, encoding: .utf8), before + stale + after, "the old file was backed up")
    }

    /// `ssh -G` against the sandbox config: the exit status and the resolved options (no connection is made).
    private func resolve(_ sandbox: DevSandbox, host: String) throws -> (status: Int32, options: String, errors: String) {
        let parse = Process()
        parse.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        parse.arguments = ["-F", sandbox.homeURL(".ssh/config").path, "-G", host]
        let output = Pipe(), errors = Pipe()
        parse.standardOutput = output
        parse.standardError = errors
        parse.standardInput = FileHandle.nullDevice
        try parse.run()
        let options = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let messages = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        parse.waitUntilExit()
        return (parse.terminationStatus, options, messages)
    }

    /// ssh keeps the first value it finds, so the block goes after the person's settings: their
    /// IgnoreUnknown and their AddKeysToAgent stay in charge, and ssh still parses the file.
    func testTheBlockNeverOverridesSettingsAlreadyInTheFile() async throws {
        for trailingNewline in [true, false] {
            let sandbox = DevSandbox()
            sandbox.generateKey()
            let mine = "IgnoreUnknown FooBarOption\nAddKeysToAgent no\n\nHost legacy\n  FooBarOption yes" + (trailingNewline ? "\n" : "")
            sandbox.writeHome(".ssh/config", mine, permissions: 0o600)
            let (action, item, plan) = try sandbox.single(SSHKeyAction.self, items)
            assertEqual(try await action.run(sandbox.context(item, plan)), .done("updated ~/.ssh/config"))

            let text = try XCTUnwrap(sandbox.readHome(".ssh/config"))
            XCTAssertTrue(text.hasPrefix(mine + (trailingNewline ? "" : "\n") + "\n# >>> shawn-dotfiles ssh-key ~/.ssh/id_ed25519 >>>\n"),
                          "the person's lines come first, byte for byte, then a blank line and the block:\n\(text)")
            XCTAssertTrue(text.hasSuffix("# <<< shawn-dotfiles ssh-key ~/.ssh/id_ed25519 <<<\n"))

            let resolved = try resolve(sandbox, host: "github.com")
            XCTAssertEqual(resolved.status, 0, "ssh must still parse the file: \(resolved.errors)")
            XCTAssertTrue(resolved.options.contains("addkeystoagent false"), resolved.options)
            XCTAssertTrue(resolved.options.contains("identityfile ~/.ssh/id_ed25519"), resolved.options)
            XCTAssertTrue(resolved.options.contains("user git"), resolved.options)
            XCTAssertEqual(try resolve(sandbox, host: "legacy").status, 0)

            sandbox.newRun()
            assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("key exists"))
        }
    }

    /// The file is handled as bytes, so a comment saved as Latin-1 stays as it was. Before, the file was
    /// decoded as UTF-8 with replacement and "é" (0xE9) was written back as U+FFFD (EF BF BD).
    func testBytesThatAreNotUTF8AreKeptAsTheyWere() async throws {
        let sandbox = DevSandbox()
        sandbox.generateKey()
        let mine = Data("# caf".utf8) + Data([0xE9]) + Data("\nHost work\n  User me\n".utf8)
        try FileManager.default.createDirectory(at: sandbox.homeURL(".ssh"), withIntermediateDirectories: true)
        try mine.write(to: sandbox.homeURL(".ssh/config"))
        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, items)
        guard case .needed = await action.check(sandbox.context(item, plan)) else { return XCTFail("the block is missing") }

        assertEqual(try await action.run(sandbox.context(item, plan)), .done("updated ~/.ssh/config"))
        let after = try Data(contentsOf: sandbox.homeURL(".ssh/config"))
        XCTAssertEqual(Array(after.prefix(mine.count)), Array(mine), "the person's lines, byte for byte")
        XCTAssertEqual(after, mine + Data("""

            # >>> shawn-dotfiles ssh-key ~/.ssh/id_ed25519 >>>
            # Managed by Shawn's Dotfiles: changes inside these markers are replaced on the next install.
            Host github.com
              User git
              IdentitiesOnly yes

            Host *
              IgnoreUnknown UseKeychain
              AddKeysToAgent yes
              UseKeychain yes
              IdentityFile ~/.ssh/id_ed25519
            # <<< shawn-dotfiles ssh-key ~/.ssh/id_ed25519 <<<

            """.utf8))
        XCTAssertEqual(try resolve(sandbox, host: "github.com").status, 0)

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("key exists"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("already set up"))
        XCTAssertEqual(try Data(contentsOf: sandbox.homeURL(".ssh/config")), after)
    }

    func testDamagedBlockIsReportedNotGuessed() async throws {
        let sandbox = DevSandbox()
        sandbox.generateKey()
        let damaged = "# >>> shawn-dotfiles ssh-key ~/.ssh/id_ed25519 >>>\nHost *\n"
        sandbox.writeHome(".ssh/config", damaged)
        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, items)
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertTrue(error?.message.contains("damaged Shawn's Dotfiles block") == true, "\(String(describing: error))")
        XCTAssertNotNil(error?.hint)
        XCTAssertEqual(sandbox.readHome(".ssh/config"), damaged)
    }

    func testDryRunCreatesNothing() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, items)
        let planned = try await action.run(sandbox.context(item, plan, dryRun: true))
        XCTAssertEqual(planned, .done("would create ~/.ssh/id_ed25519; would update ~/.ssh/config"), "a dry run says what it would do")
        XCTAssertFalse(sandbox.existsInHome(".ssh"))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ ssh-keygen -t ed25519 -a 100 -N '' -C test@example.com -f"), sandbox.logText)
        XCTAssertTrue(sandbox.logText.contains("[dry-run] write ~/.ssh/config"), sandbox.logText)
    }

    func testRSAKeysAreBig() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SSHKeyAction.self, "  - ssh-key: ~/.ssh/id_rsa\n    type: rsa\n    config: false\n    comment: rsa@example.com")
        _ = try await action.run(sandbox.context(item, plan, dryRun: true))
        XCTAssertTrue(sandbox.logText.contains("ssh-keygen -t rsa -a 100 -b 4096 -N '' -C rsa@example.com"), sandbox.logText)
    }
}

final class GitSigningTests: XCTestCase {
    private let items = "  - git-signing: ~/.ssh/id_ed25519.pub"

    func testConfiguresSigningAndAllowedSigners() async throws {
        let sandbox = DevSandbox()
        sandbox.generateKey()
        let pub = try XCTUnwrap(SSHPublicKey(line: sandbox.readHome(".ssh/id_ed25519.pub") ?? ""))
        let friend = "friend@example.com namespaces=\"git\" \(gitHubHostKeyLines[0])"
        sandbox.writeHome(".config/git/allowed_signers", "# kept\n\(friend)\n")

        let (action, item, plan) = try sandbox.single(GitSigningAction.self, items)
        guard case .needed = await action.check(sandbox.context(item, plan)) else { return XCTFail("needs setting up") }
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("signing commits and tags with ~/.ssh/id_ed25519.pub"))

        XCTAssertEqual(sandbox.globalGitConfig("gpg.format"), "ssh")
        XCTAssertEqual(sandbox.globalGitConfig("user.signingkey"), sandbox.home.path + "/.ssh/id_ed25519.pub")
        XCTAssertEqual(sandbox.globalGitConfig("commit.gpgsign"), "true")
        XCTAssertEqual(sandbox.globalGitConfig("tag.gpgsign"), "true")
        XCTAssertEqual(sandbox.globalGitConfig("gpg.ssh.allowedSignersFile"), sandbox.home.path + "/.config/git/allowed_signers")
        XCTAssertEqual(sandbox.readHome(".config/git/allowed_signers"),
                       "# kept\n\(friend)\ntest@example.com namespaces=\"git\" \(pub.material)\n")

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("signing with ~/.ssh/id_ed25519.pub"))

        // End to end: git signs a commit with that key and verifies it against allowed_signers.
        let repo = sandbox.root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        sandbox.git(["init", "-q"], in: repo)
        sandbox.git(["config", "--global", "user.name", "Test Person"])
        sandbox.git(["config", "--global", "user.email", "test@example.com"])
        let tree = sandbox.git(["hash-object", "-t", "tree", "/dev/null"], in: repo)
        let commit = sandbox.git(["commit-tree", "-S", "-m", "signed", tree], in: repo)
        XCTAssertEqual(commit.count, 40, "commit-tree -S printed \(commit)")
        XCTAssertEqual(sandbox.git(["log", "-1", "--format=%G?", commit], in: repo), "G", "git verified the signature")
    }

    func testReportsAMissingKeyClearly() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(GitSigningAction.self, items)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("~/.ssh/id_ed25519.pub does not exist yet"))
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "The public key ~/.ssh/id_ed25519.pub does not exist")
        XCTAssertFalse(sandbox.existsInHome(".gitconfig"))

        // A dry run cannot expect the earlier ssh-key item to have really made the key.
        let dry = try await action.run(sandbox.context(item, plan, dryRun: true))
        XCTAssertEqual(dry, .done("would sign with ~/.ssh/id_ed25519.pub, which does not exist yet"))
    }

    func testDryRunWritesNothing() async throws {
        let sandbox = DevSandbox()
        sandbox.generateKey()
        let (action, item, plan) = try sandbox.single(GitSigningAction.self, "  - git-signing: ~/.ssh/id_ed25519.pub\n    commits: false\n    tags: false")
        _ = try await action.run(sandbox.context(item, plan, dryRun: true))
        XCTAssertFalse(sandbox.existsInHome(".gitconfig"))
        XCTAssertFalse(sandbox.existsInHome(".config/git/allowed_signers"))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ git config --global commit.gpgsign false"), sandbox.logText)
    }
}
