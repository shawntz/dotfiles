import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class ShawnCLITests: XCTestCase {
    /// A sandbox whose helpers folder holds a stand-in `shawn` (prints a completion script, logs its calls
    /// outside the home folder) and a stand-in `WebAppShell`.
    func makeHarness(completions: String = "echo '#compdef shawn'; echo '_shawn() { _arguments \"1:command:(install doctor)\" }'",
                     webAppShell: Bool = true) -> Harness {
        let harness = Harness()
        let calls = harness.url("shawn-calls.log").path
        harness.directory.write("helpers/shawn", """
        #!/bin/sh
        echo "$* SHAWN_NO_UPDATE=$SHAWN_NO_UPDATE" >> '\(calls)'
        if [ "$1" = "completions" ] && [ "$2" = "zsh" ]; then
          \(completions)
          exit 0
        fi
        echo "shawn 1.0.0"

        """, permissions: 0o755)
        if webAppShell {
            harness.directory.writeData("helpers/WebAppShell", Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3]), permissions: 0o755)
        }
        harness.environment.helpersDirectory = harness.url("helpers")
        harness.payload("zsh/zshrc", "# zshrc\n")
        harness.directory.write("config/cli.yaml", "commands: {}\n")
        return harness
    }

    func calls(_ harness: Harness) -> [String] {
        (harness.directory.read("shawn-calls.log") ?? "").split(separator: "\n").map(String.init)
    }

    func testInstallsEverythingTheCLINeeds() async throws {
        let harness = makeHarness()
        let item = try harness.item("- shawn-cli: install")
        XCTAssertEqual(item.action.subtitle, "→ ~/.local/bin/shawn")
        XCTAssertNeeded(await item.check())

        let outcome = try await item.run()
        guard case .done(let message?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasPrefix("installed shawn \(ShawnCore.version): ~/.local/bin/shawn, WebAppShell, config copy ("), message)

        let installed = harness.url("home/.local/bin/shawn")
        XCTAssertEqual(FileManager.default.contents(atPath: installed.path), FileManager.default.contents(atPath: harness.url("helpers/shawn").path))
        XCTAssertEqual(harness.permissions(installed), 0o755)
        XCTAssertEqual(FileManager.default.contents(atPath: harness.url("home/.shawn/bin/WebAppShell").path), Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3]))
        XCTAssertEqual(harness.permissions(harness.url("home/.shawn/bin/WebAppShell")), 0o755)

        // The config the run used, mirrored so the CLI works without the checkout.
        XCTAssertEqual(harness.directory.read("home/.shawn/config/installer.yaml"), harness.meta)
        XCTAssertEqual(harness.directory.read("home/.shawn/config/files/zsh/zshrc"), "# zshrc\n")
        XCTAssertEqual(harness.directory.read("home/.shawn/config/cli.yaml"), "commands: {}\n")
        XCTAssertTrue(harness.directory.exists("home/.shawn/config/steps/01-test.yaml"))

        XCTAssertEqual(harness.directory.read("home/.config/shawn/config.yaml"), """
        # Written by Shawn's Dotfiles. Tells the `shawn` CLI where things live.
        dotfiles_repo: \(harness.home.path)/Developer/dotfiles
        config_path: installer/config

        """)

        XCTAssertEqual(harness.directory.read("home/.local/share/zsh/site-functions/_shawn"),
                       "#compdef shawn\n_shawn() { _arguments \"1:command:(install doctor)\" }\n")
        XCTAssertEqual(calls(harness), ["completions zsh SHAWN_NO_UPDATE=1"], "the INSTALLED binary is asked, with updates off")

        let record = try XCTUnwrap(try JSONParser.parse(XCTUnwrap(harness.directory.read("home/.shawn/state/cli.json"))).object)
        XCTAssertEqual(record.keys, ["version", "installedAt", "source"])
        XCTAssertEqual(record["version"], .string(ShawnCore.version))
        XCTAssertEqual(record["source"], .string(harness.url("helpers/shawn").path))
        guard case .string(let installedAt) = record["installedAt"] else { return XCTFail() }
        XCTAssertNotNil(ISO8601DateFormatter().date(from: installedAt))

        XCTAssertSatisfied(await item.check())
        let before = harness.snapshot("home")
        await XCTAssertOutcome(try await item.run(), .done("shawn \(ShawnCore.version) already installed"))
        XCTAssertEqual(harness.snapshot("home"), before, "a second run changes nothing (cli.json included)")
    }

    func testANewerBundledBinaryAndConfigAreInstalledOverTheOldOnes() async throws {
        let harness = makeHarness()
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        harness.directory.write("home/.shawn/config/stale.yaml", "left over\n")
        harness.directory.write("helpers/shawn", "#!/bin/sh\necho newer\n", permissions: 0o755)
        harness.payload("new.txt", "fresh\n")

        let check = await item.check()
        guard case .needed(let reason?) = check else { return XCTFail("\(check)") }
        XCTAssertEqual(reason, "to update: binary, config copy")
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.local/bin/shawn"), "#!/bin/sh\necho newer\n")
        XCTAssertEqual(harness.directory.read("home/.shawn/config/files/new.txt"), "fresh\n")
        XCTAssertFalse(harness.directory.exists("home/.shawn/config/stale.yaml"), "the copy mirrors the config exactly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.environment.backupDirectory.appendingPathComponent(".local/bin/shawn").path),
                       "rebuilt binaries are replaced, not backed up")
        XCTAssertEqual(harness.directory.read("home/.local/share/zsh/site-functions/_shawn"), "newer\n",
                       "completions come from the newly installed binary")
        XCTAssertSatisfied(await item.check())
    }

    func testCustomLocations() async throws {
        let harness = makeHarness()
        let item = try harness.item("""
        - shawn-cli: install
          to: ~/bin
          repo: ~/src/{{full_name}}/dotfiles
        """)
        try await item.run()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: harness.url("home/bin/shawn").path))
        XCTAssertTrue(harness.directory.read("home/.config/shawn/config.yaml")?.contains("dotfiles_repo: \(harness.home.path)/src/Shawn Tester/dotfiles\n") == true)
    }

    func testCompletionFailureIsOnlyAWarning() async throws {
        let harness = makeHarness(completions: "echo 'boom' >&2; exit 3")
        let item = try harness.item("- shawn-cli: install")
        let outcome = try await item.run()
        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(harness.directory.exists("home/.local/share/zsh/site-functions/_shawn"))
        XCTAssertTrue(harness.logs.contains { $0.style == .warning && $0.text.contains("could not generate zsh completions") }, harness.logText)
    }

    func testMissingWebAppShellIsOnlyAWarning() async throws {
        let harness = makeHarness(webAppShell: false)
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        XCTAssertTrue(harness.directory.exists("home/.local/bin/shawn"))
        XCTAssertFalse(harness.directory.exists("home/.shawn/bin/WebAppShell"))
        XCTAssertTrue(harness.logText.contains("WebAppShell was not found next to the installer"), harness.logText)
        XCTAssertSatisfied(await item.check())
    }

    /// From the CLI (`shawn sync`) the helpers folder is `~/.local/bin`, which never holds WebAppShell: the copy
    /// this item installed earlier is what `shawn add webapp` uses, so there is nothing to warn about.
    func testNoWebAppShellWarningWhenItIsAlreadyInstalled() async throws {
        let harness = makeHarness()
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: harness.url("home/.shawn/bin/WebAppShell").path))

        harness.environment.helpersDirectory = harness.url("home/.local/bin")
        harness.payload("zsh/zshrc", "# changed\n")
        let rerun = try harness.item("- shawn-cli: install")
        XCTAssertNeeded(await rerun.check())
        harness.events.reset()
        try await rerun.run()
        XCTAssertFalse(harness.logText.contains("WebAppShell was not found"), harness.logText)

        try FileManager.default.removeItem(at: harness.url("home/.shawn/bin/WebAppShell"))
        harness.payload("zsh/zshrc", "# changed again\n")
        harness.events.reset()
        try await rerun.run()
        XCTAssertTrue(harness.logs.contains { $0.style == .warning && $0.text.contains("WebAppShell was not found") }, harness.logText)
    }

    // MARK: Build provenance (Contents/Resources/build-info.json next to Contents/Helpers)

    func writeBuildInfo(_ harness: Harness, sourceTree: String, commit: String = "0123456789abcdef0123456789abcdef01234567") {
        harness.directory.write("Resources/build-info.json", """
        {"version": "\(ShawnCore.version)", "commit": "\(commit)", "sourceTree": "\(sourceTree)"}

        """)
    }

    func record(_ harness: Harness) throws -> JSONObject {
        try XCTUnwrap(try JSONParser.parse(XCTUnwrap(harness.directory.read("home/.shawn/state/cli.json"))).object)
    }

    func testAnInstalledBinaryRecordsWhichSourcesItWasBuiltFrom() async throws {
        let harness = makeHarness()
        writeBuildInfo(harness, sourceTree: "aaa,bbb,-")
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        let record = try record(harness)
        XCTAssertEqual(record.keys, ["version", "installedAt", "source", "sourceTree", "commit"])
        XCTAssertEqual(record["sourceTree"], .string("aaa,bbb,-"))
        XCTAssertEqual(record["commit"], .string("0123456789abcdef0123456789abcdef01234567"))
    }

    func testABuildFromUncommittedSourcesRecordsNoProvenance() async throws {
        let harness = makeHarness()
        writeBuildInfo(harness, sourceTree: "", commit: "")
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        XCTAssertEqual(try record(harness).keys, ["version", "installedAt", "source"], "unknown provenance: no sourceTree, no commit")
        XCTAssertFalse(harness.logs.contains { $0.style == .warning && $0.text.contains("build-info") }, "an empty sourceTree is normal, not a problem")
    }

    func testANewBinaryDropsTheOldProvenanceWhenItsOwnIsUnknown() async throws {
        let harness = makeHarness()
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        // A later self-update rebuilt the binary and recorded what it built from.
        harness.directory.write("home/.shawn/state/cli.json", """
        {"version": "1.0.0", "installedAt": "2026-01-01T00:00:00Z", "source": "/x", "sourceTree": "old,old,old", "commit": "abc", "updatedAt": "2026-02-01T00:00:00Z"}

        """)
        harness.directory.write("helpers/shawn", "#!/bin/sh\necho newer\n", permissions: 0o755)
        try await item.run()
        XCTAssertEqual(try record(harness).keys, ["version", "installedAt", "source"],
                       "the old sourceTree describes the replaced binary, not this one")
    }

    func testAnUnchangedBinaryKeepsItsRecordedProvenance() async throws {
        let harness = makeHarness()
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        let selfUpdated = """
        {"version": "1.0.0", "installedAt": "2026-01-01T00:00:00Z", "source": "/x", "sourceTree": "old,old,old", "commit": "abc", "updatedAt": "2026-02-01T00:00:00Z"}

        """
        harness.directory.write("home/.shawn/state/cli.json", selfUpdated)
        writeBuildInfo(harness, sourceTree: "new,new,new")
        harness.payload("zsh/zshrc", "# changed\n")
        XCTAssertNeeded(await item.check())
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.shawn/state/cli.json"), selfUpdated, "the binary did not change, so neither does its record")
    }

    /// A newer app replaces the binary, then something later in the same item fails (here the settings file). The
    /// next run finds the binary unchanged, so cli.json must already describe it, not the binary it replaced.
    func testARunThatFailsAfterReplacingTheBinaryHasAlreadyRecordedIt() async throws {
        let harness = makeHarness()
        writeBuildInfo(harness, sourceTree: "old,old,old", commit: "c-old")
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        XCTAssertEqual(try record(harness)["sourceTree"], .string("old,old,old"))

        harness.directory.write("helpers/shawn", "#!/bin/sh\n[ \"$1\" = completions ] && echo '#compdef shawn'\nexit 0\n", permissions: 0o755)
        writeBuildInfo(harness, sourceTree: "new,new,new", commit: "c-new")
        let settingsFolder = harness.url("home/.config/shawn")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: settingsFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: settingsFolder.path) }
        let moved = try harness.item("""
        - shawn-cli: install
          repo: ~/elsewhere
        """)
        let error = await XCTAssertThrowsActionError { try await moved.run() }
        XCTAssertTrue(error?.message.hasPrefix("could not install the shawn CLI: ") == true, "\(String(describing: error))")
        XCTAssertEqual(harness.directory.read("home/.local/bin/shawn"), harness.directory.read("helpers/shawn"), "the new binary is in place")
        XCTAssertEqual(try record(harness)["sourceTree"], .string("new,new,new"), "recorded together with the binary")
        XCTAssertEqual(try record(harness)["commit"], .string("c-new"))

        // The person fixes the folder and runs it again: the binary is unchanged now, and so is its (correct) record.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: settingsFolder.path)
        let recorded = harness.directory.read("home/.shawn/state/cli.json")
        try await moved.run()
        XCTAssertEqual(harness.directory.read("home/.shawn/state/cli.json"), recorded)
        XCTAssertEqual(try record(harness)["sourceTree"], .string("new,new,new"), "cli.json describes the installed binary")
        XCTAssertSatisfied(await moved.check())
    }

    func testAMissingRecordForAnUnchangedBinaryUsesTheBuildInfo() async throws {
        let harness = makeHarness()
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        try FileManager.default.removeItem(at: harness.url("home/.shawn/state/cli.json"))
        writeBuildInfo(harness, sourceTree: "aaa,bbb,ccc")
        harness.payload("zsh/zshrc", "# changed\n")
        try await item.run()
        XCTAssertEqual(try record(harness)["sourceTree"], .string("aaa,bbb,ccc"), "the installed binary is the bundled one the build info describes")
    }

    func testAnUnreadableBuildInfoIsAWarningAndUnknownProvenance() async throws {
        let harness = makeHarness()
        harness.directory.write("Resources/build-info.json", "{not json")
        let item = try harness.item("- shawn-cli: install")
        try await item.run()
        XCTAssertEqual(try record(harness).keys, ["version", "installedAt", "source"])
        XCTAssertTrue(harness.logs.contains { $0.style == .warning && $0.text.contains("build-info.json") }, harness.logText)
    }

    func testDryRunRecordsNothing() async throws {
        let harness = makeHarness()
        writeBuildInfo(harness, sourceTree: "aaa,bbb,ccc")
        let item = try harness.item("- shawn-cli: install")
        try await item.run(dryRun: true)
        XCTAssertFalse(harness.directory.exists("home/.shawn/state/cli.json"))
    }

    func testMissingBundledBinaryIsAClearError() async throws {
        let harness = makeHarness()
        try FileManager.default.removeItem(at: harness.url("helpers/shawn"))
        let item = try harness.item("- shawn-cli: install")
        XCTAssertNeeded(await item.check())
        let error = await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertEqual(error?.message, "the shawn binary was not found in \(harness.url("helpers").path)")
        XCTAssertNotNil(error?.hint)
    }

    func testDryRunWritesNothing() async throws {
        let harness = makeHarness()
        let item = try harness.item("- shawn-cli: install")
        let before = harness.snapshot("home")
        let outcome = try await item.run(dryRun: true)
        guard case .done(let message?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasPrefix("would install shawn"), message)
        XCTAssertEqual(harness.snapshot("home"), before)
        XCTAssertEqual(calls(harness), [], "the binary is not run in a dry run")
        XCTAssertTrue(harness.logText.contains("[dry-run] $ ~/.local/bin/shawn completions zsh"), harness.logText)
        XCTAssertTrue(harness.logText.contains("[dry-run] write ~/.local/bin/shawn"), harness.logText)
    }

    func testHelpersFallBackToTheRunningExecutable() {
        let harness = Harness()
        harness.environment.helpersDirectory = nil
        XCTAssertEqual(ShawnCLIAction.helpersDirectory(harness.environment), Bundle.main.executableURL?.deletingLastPathComponent())
        harness.environment.helpersDirectory = harness.url("helpers")
        XCTAssertEqual(ShawnCLIAction.helpersDirectory(harness.environment), harness.url("helpers"))
    }

    func testParseErrors() throws {
        let harness = Harness()
        let wrong = try harness.problems("- shawn-cli: upgrade")
        XCTAssertTrue(wrong.contains { $0.contains("the only value 'shawn-cli' takes is 'install'") }, "\(wrong)")
        let empty = try harness.problems("""
        - shawn-cli: install
          to: ""
        """)
        XCTAssertTrue(empty.contains { $0.contains("'to' must not be empty") }, "\(empty)")
    }
}
