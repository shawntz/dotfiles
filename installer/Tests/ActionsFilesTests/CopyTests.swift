import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class CopyTests: XCTestCase {
    func testCopiesAFileAndIsIdempotent() async throws {
        let harness = Harness()
        harness.payload("zsh/zshrc", "export EDITOR=nvim\n", permissions: 0o644)
        let item = try harness.item("""
        - copy: zsh/zshrc
          to: ~/.zshrc
        """)
        XCTAssertEqual(item.action.title, "~/.zshrc")
        XCTAssertNeeded(await item.check())

        let outcome = try await item.run()
        XCTAssertEqual(outcome, .done("created ~/.zshrc"))
        XCTAssertEqual(harness.directory.read("home/.zshrc"), "export EDITOR=nvim\n")
        XCTAssertEqual(harness.permissions(harness.url("home/.zshrc")), 0o644)

        XCTAssertSatisfied(await item.check())
        let before = harness.snapshot()
        await XCTAssertOutcome(try await item.run(), .done("~/.zshrc already up to date"))
        XCTAssertEqual(harness.snapshot(), before, "a second run must change nothing")
    }

    func testModeAndBackupOfAReplacedFile() async throws {
        let harness = Harness()
        harness.payload("karabiner/karabiner.json", "{\"new\": true}\n", permissions: 0o644)
        harness.directory.write("home/.config/karabiner/karabiner.json", "{\"old\": true}\n")
        let item = try harness.item("""
        - copy: karabiner/karabiner.json
          to: ~/.config/karabiner/karabiner.json
          mode: "0600"
        """)
        let outcome = try await item.run()
        guard case .done(let message?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasPrefix("updated ~/.config/karabiner/karabiner.json (old copy: ~/.shawn/backups/"), message)
        XCTAssertEqual(harness.directory.read("home/.config/karabiner/karabiner.json"), "{\"new\": true}\n")
        XCTAssertEqual(harness.permissions(harness.url("home/.config/karabiner/karabiner.json")), 0o600)
        let backup = harness.environment.backupDirectory.appendingPathComponent(".config/karabiner/karabiner.json")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{\"old\": true}\n")
        XCTAssertSatisfied(await item.check())
    }

    func testModeAsAnUnquotedYAMLNumberIsReadAsOctal() async throws {
        let harness = Harness()
        harness.payload("secret", "x")
        let item = try harness.item("""
        - copy: secret
          to: ~/secret
          mode: 0600
        """)
        try await item.run()
        XCTAssertEqual(harness.permissions(harness.url("home/secret")), 0o600)
    }

    func testBackupFalseReplacesWithoutACopy() async throws {
        let harness = Harness()
        harness.payload("hushlogin", "")
        harness.directory.write("home/.hushlogin", "old")
        let item = try harness.item("""
        - copy: hushlogin
          to: ~/.hushlogin
          backup: false
        """)
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.hushlogin"), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.environment.backupDirectory.path))
    }

    func testIfMissingLeavesAnExistingFileAlone() async throws {
        let harness = Harness()
        harness.payload("nvim/init.lua", "-- starter\n")
        harness.directory.write("home/.config/nvim/init.lua", "-- mine\n")
        let item = try harness.item("""
        - copy: nvim/init.lua
          to: ~/.config/nvim/init.lua
          if_missing: true
        """)
        XCTAssertSatisfied(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("kept the existing ~/.config/nvim/init.lua (if_missing)"))
        XCTAssertEqual(harness.directory.read("home/.config/nvim/init.lua"), "-- mine\n")

        try FileManager.default.removeItem(at: harness.url("home/.config/nvim/init.lua"))
        XCTAssertNeeded(await item.check())
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.config/nvim/init.lua"), "-- starter\n")
    }

    func testTemplateExpandsVariables() async throws {
        let harness = Harness()
        harness.payload("git/config", "name = {{full_name}}\nhome = {{home}}\nkeep = {{not_a_var}}\n")
        let item = try harness.item("""
        - copy: git/config
          to: ~/.config/git/config
          template: true
        """)
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.config/git/config"),
                       "name = Shawn Tester\nhome = \(harness.home.path)\nkeep = {{not_a_var}}\n")
        XCTAssertSatisfied(await item.check())
    }

    func testWithoutTemplateTheTextIsCopiedVerbatim() async throws {
        let harness = Harness()
        harness.payload("raw", "{{full_name}}")
        let item = try harness.item("""
        - copy: raw
          to: ~/raw
        """)
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/raw"), "{{full_name}}")
    }

    func testBinaryFilesAreNeverTemplated() async throws {
        let harness = Harness()
        let bytes = Data([0x00, 0x7B, 0x7B, 0x68, 0x6F, 0x6D, 0x65, 0x7D, 0x7D, 0xFF])
        harness.directory.writeData("config/files/blob.bin", bytes)
        let item = try harness.item("""
        - copy: blob.bin
          to: ~/blob.bin
          template: true
        """)
        try await item.run()
        XCTAssertEqual(FileManager.default.contents(atPath: harness.url("home/blob.bin").path), bytes)
    }

    func testDirectoryMergeKeepsExtraFiles() async throws {
        let harness = Harness()
        harness.payload("hammerspoon/init.lua", "require('keyboard')\n")
        harness.payload("hammerspoon/keyboard/hyper.lua", "-- hyper\n")
        harness.payload("hammerspoon/.DS_Store", "junk")
        harness.directory.write("home/.hammerspoon/Spoons/local.lua", "-- mine\n")
        let item = try harness.item("""
        - copy: hammerspoon
          to: ~/.hammerspoon
        """)
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("copied 2 files to ~/.hammerspoon"))
        XCTAssertEqual(harness.directory.read("home/.hammerspoon/keyboard/hyper.lua"), "-- hyper\n")
        XCTAssertEqual(harness.directory.read("home/.hammerspoon/Spoons/local.lua"), "-- mine\n")
        XCTAssertFalse(harness.directory.exists("home/.hammerspoon/.DS_Store"))
        XCTAssertSatisfied(await item.check())
    }

    func testDirectoryReplaceMirrorsExactlyAndBacksUpTheOldFolder() async throws {
        let harness = Harness()
        harness.payload("starship/starship.toml", "format = '$all'\n")
        harness.directory.write("home/.config/starship/old.toml", "stale\n")
        let item = try harness.item("""
        - copy: starship
          to: ~/.config/starship
          replace: true
        """)
        try await item.run()
        XCTAssertTrue(harness.directory.exists("home/.config/starship/starship.toml"))
        XCTAssertFalse(harness.directory.exists("home/.config/starship/old.toml"))
        let backup = harness.environment.backupDirectory.appendingPathComponent(".config/starship/old.toml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertSatisfied(await item.check())

        harness.directory.write("home/.config/starship/extra", "x")
        XCTAssertNeeded(await item.check(), "an extra file breaks an exact mirror")
    }

    func testDirectoryExcludeAndFolderMode() async throws {
        let harness = Harness()
        harness.payload("karabiner/karabiner.json", "{}\n")
        harness.payload("karabiner/assets/rules.json", "[]\n")
        let item = try harness.item("""
        - copy: karabiner
          to: ~/.config/karabiner
          mode: "0700"
          exclude: [karabiner.json]
        """)
        try await item.run()
        XCTAssertFalse(harness.directory.exists("home/.config/karabiner/karabiner.json"))
        XCTAssertTrue(harness.directory.exists("home/.config/karabiner/assets/rules.json"))
        XCTAssertEqual(harness.permissions(harness.url("home/.config/karabiner")), 0o700)
        XCTAssertSatisfied(await item.check())

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.url("home/.config/karabiner").path)
        XCTAssertNeeded(await item.check(), "the folder's mode is part of the desired state")
    }

    func testTemplatedDirectory() async throws {
        let harness = Harness()
        harness.payload("shell/zshrc", "export EDITOR={{editor}}\n")
        harness.payload("shell/bin/hello", "#!/bin/sh\necho {{full_name}}\n", permissions: 0o755)
        let item = try harness.item("""
        - copy: shell
          to: ~/shell
          template: true
          replace: true
        """)
        XCTAssertNeeded(await item.check())
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/shell/zshrc"), "export EDITOR=nvim\n")
        XCTAssertEqual(harness.directory.read("home/shell/bin/hello"), "#!/bin/sh\necho Shawn Tester\n")
        XCTAssertEqual(harness.permissions(harness.url("home/shell/bin/hello")), 0o755)
        XCTAssertSatisfied(await item.check())
        let before = harness.snapshot()
        try await item.run()
        XCTAssertEqual(harness.snapshot(), before)
    }

    func testTrailingSlashCopiesIntoTheFolder() async throws {
        let harness = Harness()
        harness.payload("git/ignore", "*.swp\n")
        let item = try harness.item("""
        - copy: git/ignore
          to: ~/.config/git/
        """)
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.config/git/ignore"), "*.swp\n")
    }

    func testDryRunChangesNothingAndNarrates() async throws {
        let harness = Harness()
        harness.payload("zsh/zshrc", "new\n")
        harness.payload("dir/a", "a")
        harness.directory.write("home/.zshrc", "old\n")
        let file = try harness.item("""
        - copy: zsh/zshrc
          to: ~/.zshrc
        """)
        let before = harness.snapshot("home")
        await XCTAssertOutcome(try await file.run(dryRun: true), .done("would update ~/.zshrc"))
        let folder = try harness.item("""
        - copy: dir
          to: ~/dir
          mode: "0700"
        """)
        try await folder.run(dryRun: true)
        XCTAssertEqual(harness.snapshot("home"), before)
        XCTAssertTrue(harness.logText.contains("[dry-run] backing up ~/.zshrc"), harness.logText)
        XCTAssertTrue(harness.logText.contains("[dry-run] update ~/.zshrc"), harness.logText)
        XCTAssertTrue(harness.logText.contains("[dry-run] write ~/dir/a"), harness.logText)
    }

    func testValidationReportsMissingPayloadAndMisusedOptions() throws {
        let harness = Harness()
        harness.payload("a-file", "x")
        let missing = try harness.problems("""
        - copy: nope/zshrc
          to: ~/.zshrc
        """)
        XCTAssertTrue(missing.contains { $0.contains("payload files/nope/zshrc does not exist") }, "\(missing)")

        let misused = try harness.problems("""
        - copy: a-file
          to: ~/a
          replace: true
          exclude: [x]
        """)
        XCTAssertTrue(misused.contains { $0.contains("'replace' only applies when copying a folder") }, "\(misused)")
        XCTAssertTrue(misused.contains { $0.contains("'exclude' only applies when copying a folder") }, "\(misused)")

        let badMode = try harness.problems("""
        - copy: a-file
          to: ~/a
          mode: "0999"
        """)
        XCTAssertTrue(badMode.contains { $0.contains("'mode' must be an octal permission string") }, "\(badMode)")

        let noTo = try harness.problems("- copy: a-file")
        XCTAssertTrue(noTo.contains { $0.contains("missing required key 'to'") }, "\(noTo)")

        let escape = try harness.problems("""
        - copy: ../secrets
          to: ~/x
        """)
        XCTAssertTrue(escape.contains { $0.contains("path inside config/files/") }, "\(escape)")

        let unknownVariable = try harness.problems("""
        - copy: a-file
          to: "{{nowhere}}/a"
        """)
        XCTAssertTrue(unknownVariable.contains { $0.contains("unknown variable {{nowhere}}") }, "\(unknownVariable)")
    }

    /// `exclude:` names (and `.git`) are not part of the mirror, so `replace: true` must leave them where they
    /// are, also when some other file changed and the folder is brought back in line.
    func testMirrorLeavesExcludedEntriesInPlace() async throws {
        for template in [false, true] {
            for backup in [true, false] {
                let label = "template: \(template), backup: \(backup)"
                let harness = Harness()
                harness.payload("kb/a.txt", "new {{editor}}\n")
                harness.payload("kb/assets/rules.json", "[]\n")
                harness.directory.write("home/.config/kb/a.txt", "old\n")
                harness.directory.write("home/.config/kb/stale.txt", "stale\n")
                harness.directory.write("home/.config/kb/old/gone.txt", "gone\n")
                harness.directory.write("home/.config/kb/karabiner.json", "{\"mine\": true}\n")
                harness.directory.write("home/.config/kb/.git/HEAD", "ref: refs/heads/main\n")
                let item = try harness.item("""
                - copy: kb
                  to: ~/.config/kb
                  replace: true
                  exclude: [karabiner.json]
                  backup: \(backup)
                  template: \(template)
                """)
                XCTAssertNeeded(await item.check(), label)
                let outcome = try await item.run()
                XCTAssertEqual(outcome, .done("copied 2 files to ~/.config/kb and removed 2 not in files/kb"), label)

                XCTAssertEqual(harness.directory.read("home/.config/kb/a.txt"), template ? "new nvim\n" : "new {{editor}}\n", label)
                XCTAssertEqual(harness.directory.read("home/.config/kb/assets/rules.json"), "[]\n", label)
                XCTAssertFalse(harness.directory.exists("home/.config/kb/stale.txt"), label)
                XCTAssertFalse(harness.directory.exists("home/.config/kb/old"), "a folder emptied by the mirror goes too (\(label))")
                XCTAssertEqual(harness.directory.read("home/.config/kb/karabiner.json"), "{\"mine\": true}\n", "excluded: left in place (\(label))")
                XCTAssertEqual(harness.directory.read("home/.config/kb/.git/HEAD"), "ref: refs/heads/main\n", ".git is excluded by default (\(label))")

                let backups = harness.environment.backupDirectory.appendingPathComponent(".config/kb")
                if backup {
                    XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent("stale.txt"), encoding: .utf8), "stale\n", label)
                    XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent("old/gone.txt"), encoding: .utf8), "gone\n", label)
                    XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent("a.txt"), encoding: .utf8), "old\n", label)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: backups.appendingPathComponent("karabiner.json").path), label)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: backups.appendingPathComponent(".git").path), label)
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: harness.environment.backupDirectory.path), label)
                }
                XCTAssertSatisfied(await item.check(), label)
                let before = harness.snapshot()
                await XCTAssertOutcome(try await item.run(), .done("~/.config/kb up to date"))
                XCTAssertEqual(harness.snapshot(), before, label)
            }
        }
    }

    func testMirrorDryRunNarratesAndChangesNothing() async throws {
        let harness = Harness()
        harness.payload("kb/a.txt", "new\n")
        harness.directory.write("home/kb/a.txt", "old\n")
        harness.directory.write("home/kb/stale.txt", "stale\n")
        harness.directory.write("home/kb/karabiner.json", "{}\n")
        let item = try harness.item("""
        - copy: kb
          to: ~/kb
          replace: true
          exclude: [karabiner.json]
        """)
        let before = harness.snapshot()
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would copy 1 file to ~/kb and remove 1 not in files/kb"))
        XCTAssertEqual(harness.snapshot(), before)
        XCTAssertTrue(harness.logText.contains("[dry-run] backing up ~/kb/stale.txt"), harness.logText)
        XCTAssertFalse(harness.logText.contains("karabiner.json"), harness.logText)
    }

    /// The mirror removes files through `context.files`, which never reaches into a folder that is really a link
    /// to somewhere else (a stow-style checkout): the link is swapped for a real folder first.
    func testMirrorBelowALinkedFolderNeverTouchesTheLinkTarget() async throws {
        let harness = Harness()
        harness.payload("kb/a.txt", "new\n")
        harness.directory.write("checkout/config/kb/a.txt", "old\n")
        harness.directory.write("checkout/config/kb/stale.txt", "stale\n")
        try FileManager.default.createSymbolicLink(at: harness.url("home/.config"), withDestinationURL: harness.url("checkout/config"))
        let item = try harness.item("""
        - copy: kb
          to: ~/.config/kb
          replace: true
        """)
        try await item.run()
        XCTAssertEqual(harness.directory.read("checkout/config/kb/stale.txt"), "stale\n", "the checkout is left alone")
        XCTAssertEqual(harness.directory.read("checkout/config/kb/a.txt"), "old\n")
        XCTAssertFalse(harness.directory.exists("home/.config/kb/stale.txt"))
        XCTAssertEqual(harness.directory.read("home/.config/kb/a.txt"), "new\n")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: harness.url("home/.config").path))
    }

    /// A file payload never replaces a folder: with `backup: false` that used to delete the whole tree.
    func testAFileIsNeverCopiedOverAFolder() async throws {
        for backup in [true, false] {
            let harness = Harness()
            harness.payload("x/conf", "conf\n")
            harness.directory.write("home/.config/thing/keep.txt", "keep\n")
            harness.directory.write("home/.config/thing/themes/a.toml", "a\n")
            let item = try harness.item("""
            - copy: x/conf
              to: ~/.config/thing
              backup: \(backup)
            """)
            let check = await item.check()
            guard case .needed(let reason?) = check else { return XCTFail("\(check)") }
            XCTAssertEqual(reason, "~/.config/thing is a folder, not a file")
            let before = harness.snapshot()
            let error = await XCTAssertThrowsActionError { try await item.run() }
            XCTAssertEqual(error?.message, "~/.config/thing is a folder; copying the file files/x/conf there would replace it")
            XCTAssertEqual(error?.hint, "use 'to: ~/.config/thing/' to copy it into the folder, or give the full path of the file")
            XCTAssertEqual(harness.snapshot(), before, "nothing was removed or backed up (backup: \(backup))")
            XCTAssertEqual(harness.directory.read("home/.config/thing/keep.txt"), "keep\n")
        }
    }

    func testAFileIsNeverCopiedOverALinkToAFolder() async throws {
        let harness = Harness()
        harness.payload("x/conf", "conf\n")
        harness.directory.write("checkout/thing/keep.txt", "keep\n")
        try FileManager.default.createSymbolicLink(at: harness.url("home/thing"), withDestinationURL: harness.url("checkout/thing"))
        let item = try harness.item("""
        - copy: x/conf
          to: ~/thing
        """)
        XCTAssertNeeded(await item.check())
        await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: harness.url("home/thing").path), harness.url("checkout/thing").path)
    }

    /// The same one level down: merging a folder never writes one of its files over a folder of the person's.
    /// With `backup: false` that deleted the folder and reported "copied 2 files".
    func testAFolderMergeNeverWritesAFileOverAFolder() async throws {
        for template in [false, true] {
            for backup in [true, false] {
                let harness = Harness()
                harness.payload("kb/themes", "a file now\n")
                harness.payload("kb/a.txt", "a\n")
                harness.directory.write("home/.config/kb/themes/mine.toml", "user theme\n")
                let item = try harness.item("""
                - copy: kb
                  to: ~/.config/kb
                  backup: \(backup)
                  template: \(template)
                """)
                let check = await item.check()
                guard case .needed(let reason?) = check else { return XCTFail("\(check)") }
                XCTAssertEqual(reason, "~/.config/kb/themes is a folder, not a file")
                let before = harness.snapshot()
                for dryRun in [true, false] {
                    let error = await XCTAssertThrowsActionError { try await item.run(dryRun: dryRun) }
                    XCTAssertEqual(error?.message, "~/.config/kb/themes is a folder; copying the file files/kb/themes there would replace it")
                    XCTAssertEqual(error?.hint, "move or rename that folder, or set 'replace: true' to make ~/.config/kb an exact copy of files/kb")
                }
                XCTAssertEqual(harness.snapshot(), before, "nothing was written, removed or backed up (backup: \(backup), template: \(template))")
                XCTAssertEqual(harness.directory.read("home/.config/kb/themes/mine.toml"), "user theme\n")
            }
        }
    }

    /// A link to a folder counts as a folder for a payload file, as it does for a file payload; a payload link
    /// is never written over a real folder. Replacing one link with another loses nothing, so that stays allowed,
    /// and so does a second run once the payload's link is in place.
    func testAFolderMergeTreatsLinkedFoldersAndPayloadLinks() async throws {
        let linked = Harness()
        linked.payload("kb/themes", "a file now\n")
        linked.directory.write("elsewhere/themes/mine.toml", "user theme\n")
        try FileManager.default.createDirectory(at: linked.url("home/.config/kb"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.url("home/.config/kb/themes"), withDestinationURL: linked.url("elsewhere/themes"))
        let fileOverLink = try linked.item("""
        - copy: kb
          to: ~/.config/kb
          backup: false
        """)
        XCTAssertNeeded(await fileOverLink.check())
        await XCTAssertThrowsActionError { try await fileOverLink.run() }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked.url("home/.config/kb/themes").path),
                       linked.url("elsewhere/themes").path)

        let harness = Harness()
        harness.payload("nvim/init.lua", "-- init\n")
        try FileManager.default.createDirectory(at: harness.url("config/files/nvim/shared"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: harness.url("config/files/nvim/lua").path, withDestinationPath: "shared")
        harness.directory.write("home/.config/nvim/lua/mine.lua", "-- mine\n")
        let item = try harness.item("""
        - copy: nvim
          to: ~/.config/nvim
          backup: false
        """)
        let check = await item.check()
        XCTAssertEqual(check, .needed("~/.config/nvim/lua is a folder, not a link"))
        let error = await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertEqual(error?.message, "~/.config/nvim/lua is a folder; copying the link files/nvim/lua there would replace it")
        XCTAssertEqual(harness.directory.read("home/.config/nvim/lua/mine.lua"), "-- mine\n")

        // The person moves their folder away and points the name somewhere of their own; the payload's link replaces that link.
        try FileManager.default.removeItem(at: harness.url("home/.config/nvim/lua"))
        harness.directory.write("home/mylua/mine.lua", "-- mine\n")
        try FileManager.default.createSymbolicLink(at: harness.url("home/.config/nvim/lua"), withDestinationURL: harness.url("home/mylua"))
        harness.directory.write("home/.config/nvim/shared/x.lua", "-- x\n")
        await XCTAssertOutcome(try await item.run(), .done("copied 2 files to ~/.config/nvim"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: harness.url("home/.config/nvim/lua").path), "shared")
        XCTAssertEqual(harness.directory.read("home/mylua/mine.lua"), "-- mine\n", "only the link went; what it pointed to is untouched")
        XCTAssertSatisfied(await item.check(), "the payload's own link, pointing at a folder, is not in its own way")
        await XCTAssertOutcome(try await item.run(), .done("~/.config/nvim up to date"))
    }

    /// A mirror is asked to make the destination exactly the payload, so it does replace such a folder,
    /// backing up what the folder held.
    func testAFolderMirrorReplacesAFolderWhereThePayloadHasAFile() async throws {
        let harness = Harness()
        harness.payload("kb/themes", "a file now\n")
        harness.directory.write("home/.config/kb/themes/mine.toml", "user theme\n")
        let item = try harness.item("""
        - copy: kb
          to: ~/.config/kb
          replace: true
        """)
        XCTAssertNeeded(await item.check())
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.config/kb/themes"), "a file now\n")
        XCTAssertEqual(try String(contentsOf: harness.environment.backupDirectory.appendingPathComponent(".config/kb/themes/mine.toml"), encoding: .utf8),
                       "user theme\n")
        XCTAssertSatisfied(await item.check())
    }

    /// Like `FileOps.installDirectory`: a dry run over a file or a dangling link where the folder should be says
    /// what would happen instead of failing on the folder it cannot create yet.
    func testTemplatedDryRunOverAFileOrDanglingLinkDoesNotThrow() async throws {
        for replace in [false, true] {
            for dangling in [false, true] {
                let harness = Harness()
                harness.payload("shell/zshrc", "export EDITOR={{editor}}\n")
                if dangling {
                    try FileManager.default.createSymbolicLink(atPath: harness.url("home/shell").path, withDestinationPath: "nowhere")
                } else {
                    harness.directory.write("home/shell", "a file\n")
                }
                let item = try harness.item("""
                - copy: shell
                  to: ~/shell
                  template: true
                  replace: \(replace)
                  mode: "0700"
                """)
                let before = harness.snapshot()
                await XCTAssertOutcome(try await item.run(dryRun: true), .done("would copy 1 file to ~/shell"))
                XCTAssertEqual(harness.snapshot(), before)
                XCTAssertTrue(harness.logText.contains("[dry-run] mkdir ~/shell"), harness.logText)

                try await item.run()
                XCTAssertEqual(harness.directory.read("home/shell/zshrc"), "export EDITOR=nvim\n")
                XCTAssertSatisfied(await item.check())
            }
        }
    }

    func testMissingPayloadAtRunTimeIsAClearError() async throws {
        let harness = Harness()
        harness.payload("zsh/zshrc", "x")
        let item = try harness.item("""
        - copy: zsh/zshrc
          to: ~/.zshrc
        """)
        try FileManager.default.removeItem(at: harness.configRoot.appendingPathComponent("files/zsh/zshrc"))
        XCTAssertNeeded(await item.check())
        let error = await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertEqual(error?.message, "payload files/zsh/zshrc is missing from the config")
        XCTAssertNotNil(error?.hint)
    }
}
