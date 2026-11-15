import Foundation
import ShawnCore
import XCTest
@testable import ActionsDev

final class SkillTests: XCTestCase {
    private let bundle = [
        "skills/demo/SKILL.md": "---\nname: demo\ndescription: test skill\n---\nBody\n",
        "skills/demo/scripts/run.sh": "#!/bin/sh\necho hi\n",
        "skills/demo/scripts/__pycache__/x.cpython-314.pyc": "junk",
        "skills/demo/.DS_Store": "junk",
    ]

    func testBundledSkillLayout() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo", files: bundle)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not installed in ~/.agents/skills yet"))

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("2 files written to ~/.agents/skills/demo; linked for claude, grok"))

        // A real directory in the canonical place, without caches or Finder droppings.
        XCTAssertNil(sandbox.linkTarget(".agents/skills/demo"))
        XCTAssertEqual(sandbox.readHome(".agents/skills/demo/SKILL.md"), bundle["skills/demo/SKILL.md"])
        XCTAssertTrue(sandbox.existsInHome(".agents/skills/demo/scripts/run.sh"))
        XCTAssertFalse(sandbox.existsInHome(".agents/skills/demo/scripts/__pycache__"))
        XCTAssertFalse(sandbox.existsInHome(".agents/skills/demo/.DS_Store"))

        // Relative links for Claude and Grok; Codex reads ~/.agents/skills itself.
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../.agents/skills/demo")
        XCTAssertEqual(sandbox.linkTarget(".grok/skills/demo"), "../../.agents/skills/demo")
        XCTAssertEqual(sandbox.readHome(".claude/skills/demo/SKILL.md"), bundle["skills/demo/SKILL.md"], "the link resolves")
        XCTAssertFalse(sandbox.existsInHome(".codex/skills/demo"))

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("installed for claude, codex, grok"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("already installed"))
    }

    private func backup(_ sandbox: DevSandbox, _ relative: String) -> String {
        "~/.shawn/backups/\(sandbox.environment.runID)/\(relative)"
    }

    /// A folder of the person's own at the link path (a private, richer version of the skill) is never
    /// swapped for the bundle behind their back. Codex still gets the bundled copy.
    func testLeavesTheirOwnCopyAtTheLinkPathAlone() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".claude/skills/demo/SKILL.md", "my private version\n")
        sandbox.writeHome(".claude/skills/demo/references/study.md", "study notes\n")
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo", files: bundle)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not installed in ~/.agents/skills yet"))

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .needsAttention("2 files written to ~/.agents/skills/demo; linked for grok; left your own ~/.claude/skills/demo alone"))
        XCTAssertNil(sandbox.linkTarget(".claude/skills/demo"), "still a real folder, not a link")
        XCTAssertEqual(sandbox.readHome(".claude/skills/demo/SKILL.md"), "my private version\n")
        XCTAssertEqual(sandbox.readHome(".claude/skills/demo/references/study.md"), "study notes\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.environment.backupDirectory.path), "nothing was backed up")
        XCTAssertEqual(sandbox.readHome(".agents/skills/demo/SKILL.md"), bundle["skills/demo/SKILL.md"], "the canonical copy is installed for Codex")

        XCTAssertEqual(sandbox.followUps.map(\.title), ["Your own copy of the demo skill"])
        let detail = try XCTUnwrap(sandbox.followUps.first?.detail)
        XCTAssertTrue(detail.contains("~/.claude/skills/demo differs from the bundled demo skill"), detail)
        XCTAssertTrue(detail.contains("Claude Code keeps using it"), detail)
        XCTAssertTrue(detail.contains("replace_existing: true"), detail)

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("~/.claude/skills/demo is your own copy, not the bundled one"))
    }

    func testReplaceExistingMovesTheirCopyToTheBackupsAndSaysWhere() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".claude/skills/demo/SKILL.md", "old hand-copied version\n")
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    replace_existing: true", files: bundle)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not installed in ~/.agents/skills yet"))

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("2 files written to ~/.agents/skills/demo; linked for claude, grok; "
            + "moved ~/.claude/skills/demo to \(backup(sandbox, ".claude/skills/demo"))"))
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../.agents/skills/demo")
        let saved = sandbox.environment.backupDirectory.appendingPathComponent(".claude/skills/demo/SKILL.md")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "old hand-copied version\n", "the old copy is in the backups")
        XCTAssertEqual(sandbox.followUps, [])
    }

    /// A copy identical to the bundle loses nothing by becoming the link (its backup is still named).
    func testAnIdenticalCopyAtTheLinkPathBecomesTheLink() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".claude/skills/demo/SKILL.md", bundle["skills/demo/SKILL.md"]!)
        sandbox.writeHome(".claude/skills/demo/scripts/run.sh", bundle["skills/demo/scripts/run.sh"]!)
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)
        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("2 files written to ~/.agents/skills/demo; linked for claude; "
            + "moved ~/.claude/skills/demo to \(backup(sandbox, ".claude/skills/demo"))"))
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../.agents/skills/demo")
    }

    /// An older copy of the same skill, from before the bundle gained a file, holds nothing of the person's
    /// own. Before: it had to match the bundle exactly, so a bundled LICENSE alone made it "your own copy".
    func testAnOlderCopyWithNothingOfItsOwnBecomesTheLink() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".claude/skills/demo/SKILL.md", bundle["skills/demo/SKILL.md"]!)
        sandbox.writeHome(".claude/skills/demo/.DS_Store", "finder")
        var newer = bundle
        newer["skills/demo/LICENSE"] = "MIT\n"
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: newer)
        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .done("3 files written to ~/.agents/skills/demo; linked for claude; "
            + "moved ~/.claude/skills/demo to \(backup(sandbox, ".claude/skills/demo"))"))
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../.agents/skills/demo")
        XCTAssertEqual(sandbox.readHome(".claude/skills/demo/LICENSE"), "MIT\n", "Claude now sees the whole bundled skill")
        XCTAssertEqual(sandbox.followUps, [])
        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("installed for claude"))
    }

    /// One edited file, or one file the bundle does not have, makes the folder theirs.
    func testAnEditedOrExtraFileMakesItTheirOwnCopy() async throws {
        for (path, contents) in [("scripts/run.sh", "#!/bin/sh\necho mine\n"), ("notes.md", "my notes\n")] {
            let sandbox = DevSandbox()
            sandbox.writeHome(".claude/skills/demo/SKILL.md", bundle["skills/demo/SKILL.md"]!)
            sandbox.writeHome(".claude/skills/demo/\(path)", contents)
            let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)
            guard case .needsAttention = try await action.run(sandbox.context(item, plan)) else { return XCTFail("\(path): must be left alone") }
            XCTAssertNil(sandbox.linkTarget(".claude/skills/demo"), path)
            XCTAssertEqual(sandbox.readHome(".claude/skills/demo/\(path)"), contents)
        }
    }

    /// A link to a folder of their own elsewhere is their copy too; replacing it only removes the link.
    func testALinkToTheirOwnFolderIsTheirCopy() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome("Projects/skills/demo/SKILL.md", "mine\n")
        try FileManager.default.createDirectory(at: sandbox.homeURL(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox.homeURL(".claude/skills/demo").path, withDestinationPath: "../../Projects/skills/demo")

        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)
        guard case .needsAttention = try await action.run(sandbox.context(item, plan)) else { return XCTFail("must be left alone") }
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../Projects/skills/demo")

        let (replacing, replacingItem, replacingPlan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]\n    replace_existing: true", files: bundle)
        let outcome = try await replacing.run(sandbox.context(replacingItem, replacingPlan))
        guard case .done(let message?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("~/.claude/skills/demo pointed to ~/Projects/skills/demo before (that folder is untouched)"), message)
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../.agents/skills/demo")
        XCTAssertEqual(sandbox.readHome("Projects/skills/demo/SKILL.md"), "mine\n")
    }

    /// The link reaches their folder through a linked folder (~/Projects on another disk). Listed by that
    /// path, the folder came back empty, so it "matched" the bundle and was swapped without a word.
    func testALinkToTheirOwnFolderThroughALinkedFolderIsTheirCopy() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome("real-projects/skills/demo/SKILL.md", "my private version\n")
        try FileManager.default.createSymbolicLink(atPath: sandbox.homeURL("Projects").path, withDestinationPath: "real-projects")
        try FileManager.default.createDirectory(at: sandbox.homeURL(".claude/skills"), withIntermediateDirectories: true)
        let mine = sandbox.homeURL("Projects/skills/demo").path
        try FileManager.default.createSymbolicLink(atPath: sandbox.homeURL(".claude/skills/demo").path, withDestinationPath: mine)
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .needsAttention("2 files written to ~/.agents/skills/demo; left your own ~/.claude/skills/demo alone"))
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), mine)
        XCTAssertEqual(sandbox.readHome("real-projects/skills/demo/SKILL.md"), "my private version\n")
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Your own copy of the demo skill"])
        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("~/.claude/skills/demo is your own copy, not the bundled one"))
    }

    /// ~/.claude/skills is a stow link into a dotfiles checkout that holds their own demo skill. Before, the
    /// folder was taken for an old copy: the stow link was unfolded and the item failed with an I/O error.
    func testTheirCopyInsideAStowLinkedSkillsFolderIsLeftAlone() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome("dotfiles/claude-skills/demo/SKILL.md", "my private version\n")
        try FileManager.default.createDirectory(at: sandbox.homeURL(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox.homeURL(".claude/skills").path, withDestinationPath: "../dotfiles/claude-skills")
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .needsAttention("2 files written to ~/.agents/skills/demo; left your own ~/.claude/skills/demo alone"))
        XCTAssertEqual(sandbox.linkTarget(".claude/skills"), "../dotfiles/claude-skills", "their stow link stays")
        let checkout = sandbox.homeURL("dotfiles/claude-skills")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: checkout.path), ["demo"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: checkout.appendingPathComponent("demo").path), ["SKILL.md"])
        XCTAssertEqual(sandbox.readHome("dotfiles/claude-skills/demo/SKILL.md"), "my private version\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.environment.backupDirectory.path), "nothing was backed up")
        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("~/.claude/skills/demo is your own copy, not the bundled one"))
    }

    /// ~/.claude/skills is a stow link into a dotfiles checkout, and the copy of the skill there is the bundle's,
    /// file for file. The link becomes a real folder, the old copy goes to the backups and the skill is linked.
    /// Before, a relative stow link made the item fail half-way, and an absolute one put `demo.2` in the checkout.
    func testAnOldCopyInsideAStowLinkedSkillsFolderIsReplacedWithoutTouchingTheCheckout() async throws {
        for absolute in [false, true] {
            let sandbox = DevSandbox()
            sandbox.writeHome("dotfiles/claude-skills/demo/SKILL.md", bundle["skills/demo/SKILL.md"]!)
            sandbox.writeHome("dotfiles/claude-skills/demo/scripts/run.sh", bundle["skills/demo/scripts/run.sh"]!)
            sandbox.writeHome("dotfiles/claude-skills/other/SKILL.md", "another skill of theirs\n")
            try FileManager.default.createDirectory(at: sandbox.homeURL(".claude"), withIntermediateDirectories: true)
            let target = absolute ? sandbox.homeURL("dotfiles/claude-skills").path : "../dotfiles/claude-skills"
            try FileManager.default.createSymbolicLink(atPath: sandbox.homeURL(".claude/skills").path, withDestinationPath: target)
            let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)

            let outcome = try await action.run(sandbox.context(item, plan))
            guard case .done(let message?) = outcome else { XCTFail("absolute=\(absolute): \(outcome)"); continue }
            XCTAssertTrue(message.hasPrefix("2 files written to ~/.agents/skills/demo; linked for claude; moved ~/.claude/skills/demo to ~/.shawn/backups/"),
                          "absolute=\(absolute): \(message)")
            XCTAssertTrue(message.hasSuffix("/.claude/skills.2/demo"), "absolute=\(absolute): the backup sits next to the moved link, not below it: \(message)")
            XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../.agents/skills/demo", "absolute=\(absolute)")
            XCTAssertNil(sandbox.linkTarget(".claude/skills"), "absolute=\(absolute): the stow link became a real folder")
            XCTAssertEqual(sandbox.readHome(".claude/skills/other/SKILL.md"), "another skill of theirs\n", "absolute=\(absolute): their other skill came along")
            let checkout = sandbox.homeURL("dotfiles/claude-skills")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: checkout.path).sorted(), ["demo", "other"],
                           "absolute=\(absolute): nothing is added to or taken from the checkout")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: checkout.appendingPathComponent("demo").path).sorted(), ["SKILL.md", "scripts"])
            sandbox.newRun()
            assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("installed for claude"))
        }
    }

    /// A git checkout of the skill is theirs even when its files are the bundle's (`.git` is left out of
    /// the comparison). Before, the whole repository, unpushed branch and all, went to the backups.
    func testAGitCheckoutAtTheLinkPathIsTheirs() async throws {
        let sandbox = DevSandbox()
        sandbox.writeHome(".claude/skills/demo/SKILL.md", bundle["skills/demo/SKILL.md"]!)
        sandbox.writeHome(".claude/skills/demo/scripts/run.sh", bundle["skills/demo/scripts/run.sh"]!)
        let checkout = sandbox.homeURL(".claude/skills/demo").path
        sandbox.git(["init", "-q", checkout])
        sandbox.git(["-C", checkout, "add", "-A"])
        sandbox.git(["-C", checkout, "-c", "user.name=x", "-c", "user.email=x@example.com", "commit", "-q", "-m", "mine"])
        sandbox.git(["-C", checkout, "branch", "unpushed-work"])
        XCTAssertTrue(sandbox.existsInHome(".claude/skills/demo/.git/HEAD"))
        // Grok's copy is edited, so the note names both, each with its own reason.
        sandbox.writeHome(".grok/skills/demo/SKILL.md", "my private version\n")
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude, grok]", files: bundle)

        let outcome = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(outcome, .needsAttention("2 files written to ~/.agents/skills/demo; left your own ~/.claude/skills/demo and ~/.grok/skills/demo alone"))
        XCTAssertNil(sandbox.linkTarget(".claude/skills/demo"))
        XCTAssertEqual(sandbox.git(["-C", checkout, "branch", "--list", "unpushed-work", "--format=%(refname:short)"]), "unpushed-work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.environment.backupDirectory.path), "nothing was backed up")
        let detail = try XCTUnwrap(sandbox.followUps.first?.detail)
        XCTAssertTrue(detail.hasPrefix("~/.claude/skills/demo is a git checkout and ~/.grok/skills/demo differs from the bundled demo skill, "
            + "so they were left alone and Claude Code and Grok keep using them. "), detail)
        XCTAssertTrue(detail.hasSuffix("move your copies somewhere safe and run the installer again, "
            + "or add 'replace_existing: true' to this item to have them moved to the backups."), detail)
        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("~/.claude/skills/demo is your own copy, not the bundled one"))

        // A link to a linked worktree (a `.git` file, not a folder) elsewhere: Claude keeps using their checkout.
        let worktree = DevSandbox()
        worktree.writeHome("Projects/demo/.git", "gitdir: /elsewhere/.git/worktrees/demo\n")
        worktree.writeHome("Projects/demo/SKILL.md", bundle["skills/demo/SKILL.md"]!)
        try FileManager.default.createDirectory(at: worktree.homeURL(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: worktree.homeURL(".claude/skills/demo").path, withDestinationPath: "../../Projects/demo")
        let (single, singleItem, singlePlan) = try worktree.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)
        guard case .needsAttention = try await single.run(worktree.context(singleItem, singlePlan)) else { return XCTFail("a worktree must be left alone") }
        XCTAssertEqual(worktree.linkTarget(".claude/skills/demo"), "../../Projects/demo")
        XCTAssertTrue(try XCTUnwrap(worktree.followUps.first?.detail).hasPrefix("~/.claude/skills/demo is a git checkout, so it was left alone"))
    }

    /// Old links (absolute, or dangling) to the canonical copy are simply repointed.
    func testAnOldLinkToTheCanonicalCopyIsRepointed() async throws {
        let sandbox = DevSandbox()
        try FileManager.default.createDirectory(at: sandbox.homeURL(".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox.homeURL(".claude/skills/demo").path,
                                                   withDestinationPath: sandbox.homeURL(".agents/skills/demo").path)
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("2 files written to ~/.agents/skills/demo; linked for claude"))
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/demo"), "../../.agents/skills/demo")
    }

    func testMirrorsTheBundleExactly() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo", files: bundle)
        _ = try await action.run(sandbox.context(item, plan))
        sandbox.writeHome(".agents/skills/demo/stray.txt", "left over from an older version\n")

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("installed copy differs from the bundled one"))
        // The old copy may hold edits made through a link, so the outcome says where it went.
        assertEqual(try await action.run(sandbox.context(item, plan)),
                    .done("2 files written to ~/.agents/skills/demo (the previous copy is in \(backup(sandbox, ".agents/skills/demo")))"))
        XCTAssertFalse(sandbox.existsInHome(".agents/skills/demo/stray.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.environment.backupDirectory.appendingPathComponent(".agents/skills/demo/stray.txt").path))
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("installed for claude, codex, grok"))
    }

    /// The config is read through a link (a checkout under ~/Dropbox, itself a link). Listed by that path,
    /// the bundle came back empty: ~/.agents/skills/demo stayed an empty folder and the item said done.
    func testABundledSkillFromAConfigReachedThroughALinkIsInstalled() async throws {
        let sandbox = DevSandbox()
        sandbox.writeConfig(items: "  - skill: demo\n    agents: [claude]", files: bundle)
        let linked = sandbox.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: "config")
        let plan = InstallPlan.build(config: try ConfigLoader.load(from: linked).config, registry: sandbox.registry(), environment: sandbox.environment)
        let item = try XCTUnwrap(plan.allItems.first)
        let action = try XCTUnwrap(item.action as? SkillAction)

        assertEqual(try await action.run(sandbox.context(item, plan)), .done("2 files written to ~/.agents/skills/demo; linked for claude"))
        XCTAssertEqual(sandbox.readHome(".agents/skills/demo/SKILL.md"), bundle["skills/demo/SKILL.md"])
        XCTAssertEqual(sandbox.readHome(".claude/skills/demo/scripts/run.sh"), bundle["skills/demo/scripts/run.sh"])
        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("installed for claude"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("already installed"))
    }

    func testOnlyRequestedAgentsAreLinked() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo\n    agents: [claude]", files: bundle)
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertNotNil(sandbox.linkTarget(".claude/skills/demo"))
        XCTAssertFalse(sandbox.existsInHome(".grok/skills/demo"))
    }

    func testMissingBundleFailsClearly() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo", files: bundle)
        try FileManager.default.removeItem(at: sandbox.root.appendingPathComponent("config/skills/demo"))
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not installed in ~/.agents/skills yet"))
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "The bundled skill 'demo' is missing (skills/demo/SKILL.md is not in the config)")
    }

    func testBundledDryRunWritesNothing() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: demo", files: bundle)
        let planned = try await action.run(sandbox.context(item, plan, dryRun: true))
        XCTAssertEqual(planned, .done("would write 2 files to ~/.agents/skills/demo; would link for claude, grok"), "a dry run says what it would do")
        XCTAssertFalse(sandbox.existsInHome(".agents"))
        XCTAssertFalse(sandbox.existsInHome(".claude"))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] link ~/.claude/skills/demo → ../../.agents/skills/demo"), sandbox.logText)

        // Their own copy is left alone in a dry run too, and an outdated canonical copy is only narrated.
        sandbox.writeHome(".claude/skills/demo/SKILL.md", "mine\n")
        sandbox.writeHome(".agents/skills/demo/SKILL.md", "outdated\n")
        let outcome = try await action.run(sandbox.context(item, plan, dryRun: true))
        guard case .needsAttention = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(sandbox.readHome(".claude/skills/demo/SKILL.md"), "mine\n")
        XCTAssertEqual(sandbox.readHome(".agents/skills/demo/SKILL.md"), "outdated\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.environment.backupDirectory.path))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] backing up ~/.agents/skills/demo"), sandbox.logText)
    }

    func testUpstreamSkillUsesTheSkillsCLI() async throws {
        var base = ProcessInfo.processInfo.environment
        base["CLAUDECODE"] = "1"
        base["CLAUDE_CODE_ENTRYPOINT"] = "cli"
        base["CODEX_SANDBOX"] = "seatbelt"
        base["CI"] = "true"
        let sandbox = DevSandbox(baseEnvironment: base)
        sandbox.installFakeNpx()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: find-skills\n    source: vercel-labs/skills")
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not installed in ~/.agents/skills yet"))

        assertEqual(try await action.run(sandbox.context(item, plan)), .done("installed from vercel-labs/skills"))
        XCTAssertEqual(sandbox.calls("npx"), [["--yes", "skills@latest", "add", "vercel-labs/skills", "-g", "-s", "find-skills",
                                               "-a", "claude-code", "-a", "codex", "-a", "grok", "-y"]])
        let seen = sandbox.lastEnvironment("npx")
        XCTAssertEqual(seen["DISABLE_TELEMETRY"], "1")
        XCTAssertNil(seen["CLAUDECODE"])
        XCTAssertNil(seen["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertNil(seen["CODEX_SANDBOX"])
        XCTAssertNil(seen["CI"])

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("installed for claude, codex, grok"))
    }

    func testUpstreamLinksAreMadeWhenTheCLIDidNot() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeNpx(createsLinks: false)
        sandbox.writeHome(".grok/skills/marimo-pair", "a stray file where the link belongs\n")
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: marimo-pair\n    source: marimo-team/marimo-pair\n    agents: [claude, grok]")
        assertEqual(try await action.run(sandbox.context(item, plan)),
                    .done("installed from marimo-team/marimo-pair (linked for claude, grok; moved ~/.grok/skills/marimo-pair to "
                        + "\(backup(sandbox, ".grok/skills/marimo-pair")))"))
        XCTAssertEqual(sandbox.linkTarget(".claude/skills/marimo-pair"), "../../.agents/skills/marimo-pair")
        XCTAssertEqual(sandbox.linkTarget(".grok/skills/marimo-pair"), "../../.agents/skills/marimo-pair")
    }

    func testCodexIsAlwaysPassedSoTheCanonicalCopyExists() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeNpx()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: marimo-pair\n    source: marimo-team/marimo-pair\n    agents: [claude]")
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertEqual(sandbox.calls("npx").first?.suffix(5), ["-a", "claude-code", "-a", "codex", "-y"])
        XCTAssertFalse(sandbox.existsInHome(".grok/skills/marimo-pair"))
    }

    func testUpstreamWithoutNpx() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: find-skills\n    source: vercel-labs/skills")
        // The sandbox PATH also has /usr/local/bin and /usr/bin; only run the assertion where npx is truly absent.
        guard sandbox.environment.resolveExecutable("npx") == nil else { throw XCTSkip("a system-wide npx is on the fixed search path") }
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "npx is not installed, so the 'find-skills' skill cannot be fetched from vercel-labs/skills")
    }

    func testUpstreamDryRun() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeNpx()
        let (action, item, plan) = try sandbox.single(SkillAction.self, "  - skill: find-skills\n    source: vercel-labs/skills")
        assertEqual(try await action.run(sandbox.context(item, plan, dryRun: true)), .done("would install find-skills from vercel-labs/skills"))
        XCTAssertEqual(sandbox.calls("npx"), [])
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ npx --yes skills@latest add vercel-labs/skills -g -s find-skills"), sandbox.logText)
    }
}

final class ClaudePluginTests: XCTestCase {
    func testAddsAMissingMarketplaceThenInstalls() async throws {
        var base = ProcessInfo.processInfo.environment
        base["CLAUDECODE"] = "1"
        base["CLAUDE_CODE_SSE_PORT"] = "1234"
        let sandbox = DevSandbox(baseEnvironment: base)
        sandbox.installFakeClaude(marketplaces: ["claude-plugins-official anthropics/claude-plugins-official"])
        let (action, item, plan) = try sandbox.single(ClaudePluginAction.self, """
          - claude-plugin: warp@claude-code-warp
            marketplace: warpdotdev/claude-code-warp
        """)
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("not installed"))
        assertEqual(try await action.run(sandbox.context(item, plan)), .done("installed"))

        let calls = sandbox.calls("claude")
        XCTAssertTrue(calls.contains(["plugin", "marketplace", "add", "warpdotdev/claude-code-warp", "--json"]), "\(calls)")
        XCTAssertTrue(calls.contains(["plugin", "install", "warp@claude-code-warp", "--scope", "user", "--json"]), "\(calls)")
        XCTAssertFalse(calls.contains { $0.contains("-y") }, "command-source plugins must be refused, not auto-accepted")
        XCTAssertEqual(sandbox.claudePlugins, ["warp@claude-code-warp user true"])

        let seen = sandbox.lastEnvironment("claude")
        XCTAssertEqual(seen["CLAUDE_CODE_PLUGIN_PREFER_HTTPS"], "1")
        XCTAssertNil(seen["CLAUDECODE"])
        XCTAssertNil(seen["CLAUDE_CODE_SSE_PORT"])

        sandbox.newRun()
        assertEqual(await action.check(sandbox.context(item, plan)), .satisfied("installed at user scope"))
    }

    func testRegistersTheOfficialMarketplaceOnAFreshMac() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeClaude()
        let (action, item, plan) = try sandbox.single(ClaudePluginAction.self, "  - claude-plugin: swift-lsp@claude-plugins-official")
        _ = try await action.run(sandbox.context(item, plan))
        XCTAssertTrue(sandbox.calls("claude").contains(["plugin", "marketplace", "add", "anthropics/claude-plugins-official", "--json"]))
        XCTAssertEqual(sandbox.claudePlugins, ["swift-lsp@claude-plugins-official user true"])
    }

    func testUnknownMarketplaceWithoutSourceExplainsTheFix() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeClaude()
        let (action, item, plan) = try sandbox.single(ClaudePluginAction.self, "  - claude-plugin: thing@somewhere")
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "Claude Code does not know the plugin marketplace 'somewhere'")
        XCTAssertEqual(error?.hint, "Add 'marketplace: owner/repo' to this item so the installer can add it first")
        XCTAssertFalse(sandbox.calls("claude").contains { $0.starts(with: ["plugin", "install"]) })
    }

    func testInstallFailureIsReported() async throws {
        let sandbox = DevSandbox()
        // The marketplace list claims it is known, but install still fails: the error must surface.
        sandbox.installFakeClaude(marketplaces: ["somewhere-else owner/else"])
        let (action, item, plan) = try sandbox.single(ClaudePluginAction.self, "  - claude-plugin: thing@somewhere\n    marketplace: owner/else")
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertTrue(error?.message.contains("could not install thing@somewhere") == true, "\(String(describing: error))")
        XCTAssertTrue(error?.message.contains("marketplace \"somewhere\" is not known") == true, "\(String(describing: error))")
    }

    func testAlreadyInstalledAndDisabled() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeClaude(plugins: ["stripe@claude-plugins-official user true", "warp@claude-code-warp user false"],
                                  marketplaces: ["claude-plugins-official anthropics/claude-plugins-official", "claude-code-warp warpdotdev/claude-code-warp"])
        let (stripe, stripeItem, stripePlan) = try sandbox.single(ClaudePluginAction.self, "  - claude-plugin: stripe@claude-plugins-official")
        assertEqual(await stripe.check(sandbox.context(stripeItem, stripePlan)), .satisfied("installed at user scope"))
        assertEqual(try await stripe.run(sandbox.context(stripeItem, stripePlan)), .done("already installed"))

        sandbox.newRun()
        let (warp, warpItem, warpPlan) = try sandbox.single(ClaudePluginAction.self, "  - claude-plugin: warp@claude-code-warp")
        assertEqual(await warp.check(sandbox.context(warpItem, warpPlan)), .needed("installed but disabled"))
        assertEqual(try await warp.run(sandbox.context(warpItem, warpPlan)), .done("enabled"))
        XCTAssertTrue(sandbox.calls("claude").contains(["plugin", "enable", "warp@claude-code-warp", "--scope", "user", "--json"]))
        XCTAssertFalse(sandbox.calls("claude").contains { $0.starts(with: ["plugin", "install"]) })
    }

    func testMissingClaude() async throws {
        let sandbox = DevSandbox()
        let (action, item, plan) = try sandbox.single(ClaudePluginAction.self, "  - claude-plugin: stripe@claude-plugins-official")
        guard sandbox.environment.resolveExecutable("claude") == nil else { throw XCTSkip("a system-wide claude is on the fixed search path") }
        assertEqual(await action.check(sandbox.context(item, plan)), .needed("Claude Code is not installed yet"))
        let error = await assertActionError { _ = try await action.run(sandbox.context(item, plan)) }
        XCTAssertEqual(error?.message, "Claude Code (claude) is not installed")
    }

    func testDryRunOnlyLists() async throws {
        let sandbox = DevSandbox()
        sandbox.installFakeClaude()
        let (action, item, plan) = try sandbox.single(ClaudePluginAction.self, "  - claude-plugin: warp@claude-code-warp\n    marketplace: warpdotdev/claude-code-warp")
        assertEqual(try await action.run(sandbox.context(item, plan, dryRun: true)), .done("would be installed"))
        XCTAssertEqual(Set(sandbox.calls("claude").map { $0.prefix(3).joined(separator: " ") }), ["plugin list --json", "plugin marketplace list"])
        XCTAssertEqual(sandbox.claudePlugins, [])
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ claude plugin marketplace add warpdotdev/claude-code-warp --json"), sandbox.logText)
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ claude plugin install warp@claude-code-warp --scope user --json"), sandbox.logText)
    }

    func testListParsingToleratesChatter() {
        let text = "Checking plugins...\n[{\"id\":\"a@b\",\"scope\":\"user\",\"enabled\":true,\"errors\":[\"x\"]}]\n"
        XCTAssertEqual(ClaudePluginAction.decodeArray(ClaudePluginAction.InstalledPlugin.self, from: text),
                       [.init(id: "a@b", scope: "user", enabled: true)])
        XCTAssertNil(ClaudePluginAction.decodeArray(ClaudePluginAction.InstalledPlugin.self, from: "error: not logged in"))
    }
}
