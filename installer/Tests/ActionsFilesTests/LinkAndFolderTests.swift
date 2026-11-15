import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class SymlinkTests: XCTestCase {
    func link(_ harness: Harness, _ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: harness.url(relative).path)
    }

    func testCreatesARelativeLinkAndIsIdempotent() async throws {
        let harness = Harness()
        harness.directory.write("home/.agents/skills/unslop/SKILL.md", "# unslop\n")
        let item = try harness.item("""
        - symlink: ~/.claude/skills/unslop
          to: ../../.agents/skills/unslop
        """)
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("created ~/.claude/skills/unslop"))
        XCTAssertEqual(link(harness, "home/.claude/skills/unslop"), "../../.agents/skills/unslop")
        XCTAssertEqual(harness.directory.read("home/.claude/skills/unslop/SKILL.md"), "# unslop\n", "the relative link resolves")
        XCTAssertSatisfied(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("~/.claude/skills/unslop already up to date"))
    }

    func testRepointsALinkAndBacksUpARealFile() async throws {
        let harness = Harness()
        try FileManager.default.createDirectory(at: harness.url("home/.config"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: harness.url("home/.config/old-link").path, withDestinationPath: "/somewhere/else")
        harness.directory.write("home/.config/real-file", "precious")
        let repoint = try harness.item("""
        - symlink: ~/.config/old-link
          to: "{{home}}/target"
        """)
        try await repoint.run()
        XCTAssertEqual(link(harness, "home/.config/old-link"), harness.home.path + "/target")

        let replace = try harness.item("""
        - symlink: ~/.config/real-file
          to: ~/target
        """)
        try await replace.run()
        XCTAssertEqual(link(harness, "home/.config/real-file"), harness.home.path + "/target", "a leading ~ is expanded")
        let backup = harness.environment.backupDirectory.appendingPathComponent(".config/real-file")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "precious")
    }

    func testDryRunAndParseErrors() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - symlink: ~/link
          to: target
        """)
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would create ~/link"))
        XCTAssertNil(link(harness, "home/link"))
        XCTAssertTrue(harness.logText.contains("[dry-run] link ~/link → target"), harness.logText)

        let missing = try harness.problems("- symlink: ~/link")
        XCTAssertTrue(missing.contains { $0.contains("missing required key 'to'") }, "\(missing)")
    }
}

final class MkdirTests: XCTestCase {
    func testCreatesWithModeAndIsIdempotent() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - mkdir: ~/.ssh
          mode: "0700"
        """)
        XCTAssertEqual(item.action.subtitle, "mode 0700")
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("created ~/.ssh"))
        XCTAssertEqual(harness.permissions(harness.url("home/.ssh")), 0o700)
        XCTAssertSatisfied(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("~/.ssh already exists"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.url("home/.ssh").path)
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("set permissions of ~/.ssh to 0700"))
        XCTAssertEqual(harness.permissions(harness.url("home/.ssh")), 0o700)
    }

    func testCreatesParentsAndFailsClearlyWhenAFileIsInTheWay() async throws {
        let harness = Harness()
        let nested = try harness.item("- mkdir: ~/Developer/Projects")
        try await nested.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.url("home/Developer/Projects").path))

        harness.directory.write("home/Blocked", "a file")
        let blocked = try harness.item("- mkdir: ~/Blocked")
        XCTAssertNeeded(await blocked.check())
        let error = await XCTAssertThrowsActionError { try await blocked.run() }
        XCTAssertEqual(error?.message, "~/Blocked exists but is not a folder")
        XCTAssertEqual(error?.hint, "move or rename it, then run this step again")
    }

    /// `mkdir: ~/.config/karabiner` with a mode, on a Mac where that folder is a stow link into a checkout. The
    /// link counts as the folder, and its target is not chmodded, so the check must not ask for the mode forever.
    func testALinkToAFolderIsEnoughWhateverItsPermissions() async throws {
        let harness = Harness()
        harness.directory.write("home/dotfiles/karabiner/karabiner.json", "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.url("home/dotfiles/karabiner").path)
        try FileManager.default.createDirectory(at: harness.url("home/.config"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: harness.url("home/.config/karabiner").path, withDestinationPath: "../dotfiles/karabiner")
        let item = try harness.item("""
        - mkdir: ~/.config/karabiner
          mode: "0700"
        """)
        XCTAssertSatisfied(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("~/.config/karabiner already exists"))
        XCTAssertSatisfied(await item.check())
        XCTAssertEqual(harness.permissions(harness.url("home/dotfiles/karabiner")), 0o755, "the link's target is left as it was")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: harness.url("home/.config/karabiner").path), "../dotfiles/karabiner")
    }

    /// `mkdir: ~/.config/big/sub` where ~/.config/big is a stow link to a folder of more than 2,000 files. The
    /// refusal says to replace the link and nothing else. Folder permissions have nothing to do with it.
    func testALinkedFolderTooBigToUnfoldGetsOneInstruction() async throws {
        let harness = Harness()
        let big = harness.url("checkout/big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for index in 0...2_000 {
            FileManager.default.createFile(atPath: big.appendingPathComponent("f\(index)").path, contents: Data())
        }
        try FileManager.default.createDirectory(at: harness.url("home/.config"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: harness.url("home/.config/big"), withDestinationURL: big)
        let item = try harness.item("- mkdir: ~/.config/big/sub")
        let error = await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertEqual(error?.message, "could not create ~/.config/big/sub: ~/.config/big is a link to \(big.resolvingSymlinksInPath().path), which is too big to copy automatically")
        XCTAssertEqual(error?.hint, "replace the link with a real folder (or point this item somewhere else) and run this again")
        let shown = InstallEngine.describe(try XCTUnwrap(error))
        XCTAssertFalse(shown.contains("permissions"), "the item line reads: \(shown)")
        XCTAssertTrue(shown.hasSuffix("too big to copy automatically. Replace the link with a real folder (or point this item somewhere else) and run this again"), shown)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: harness.url("home/.config/big").path), big.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.appendingPathComponent("sub").path))
    }

    func testDryRun() async throws {
        let harness = Harness()
        let item = try harness.item("- mkdir: ~/Developer")
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would create ~/Developer"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url("home/Developer").path))
    }
}
