import XCTest
@testable import ActionsPackages
import ShawnCore

/// `softwareupdate -l` output: real (macOS 27.2) and synthetic.
enum SoftwareUpdateFixtures {
    static let real = """
    Software Update Tool

    Software Update found the following new or updated software:
    * Label: Command Line Tools for Xcode 27.2-27.2
    \tTitle: Command Line Tools for Xcode 27.2, Version: 27.2, Size: 521120KiB, Recommended: YES, \n\
    * Label: macOS 27.3 Beta-26C5035r
    \tTitle: macOS 27.3 Beta, Version: 27.3, Size: 6160384KiB, Recommended: YES, Action: restart, \n
    """

    static let withBeta = """
    Software Update Tool

    Finding available software
    Software Update found the following new or updated software:
    * Label: Command Line Tools for Xcode 27.3 beta 2-27.3
    \tTitle: Command Line Tools for Xcode 27.3 beta 2, Version: 27.3, Size: 530000KiB, Recommended: YES,
    * Label: Command Line Tools for Xcode 26.6-26.6
    \tTitle: Command Line Tools for Xcode 26.6, Version: 26.6, Size: 500000KiB, Recommended: YES,
    * Label: Command Line Tools for Xcode 27.2-27.2
    \tTitle: Command Line Tools for Xcode 27.2, Version: 27.2, Size: 521120KiB, Recommended: YES,
    * Label: macOS 27.3 Beta-26C5035r
    \tTitle: macOS 27.3 Beta, Version: 27.3, Size: 6160384KiB, Recommended: YES, Action: restart,
    """

    static let empty = """
    Software Update Tool

    Finding available software
    No new software available.
    """
}

final class CommandLineToolsLabelTests: XCTestCase {
    func testPicksTheReleaseFromRealOutput() {
        XCTAssertEqual(CommandLineToolsLabel.pick(from: SoftwareUpdateFixtures.real), "Command Line Tools for Xcode 27.2-27.2")
    }

    func testPrefersTheNewestReleaseOverANewerBeta() {
        XCTAssertEqual(CommandLineToolsLabel.pick(from: SoftwareUpdateFixtures.withBeta), "Command Line Tools for Xcode 27.2-27.2")
    }

    func testFallsBackToABetaWhenThatIsAllThereIs() {
        let output = """
        * Label: Command Line Tools for Xcode 27.3 beta 2-27.3
        \tTitle: Command Line Tools for Xcode 27.3 beta 2, Version: 27.3, Size: 530000KiB, Recommended: YES,
        - Label: Command Line Tools for Xcode 27.4 Release Candidate-27.4
        \tTitle: Command Line Tools for Xcode 27.4 Release Candidate, Version: 27.4, Size: 1KiB, Recommended: NO,
        """
        XCTAssertEqual(CommandLineToolsLabel.pick(from: output), "Command Line Tools for Xcode 27.4 Release Candidate-27.4")
    }

    func testNothingOfferedGivesNil() {
        XCTAssertNil(CommandLineToolsLabel.pick(from: SoftwareUpdateFixtures.empty))
        XCTAssertNil(CommandLineToolsLabel.pick(from: ""))
    }

    func testVersionsCompareNumericallyAndWithoutTitleLines() {
        let output = """
        - Label: Command Line Tools for Xcode 26.10-26.10
        * Label: Command Line Tools for Xcode 26.9-26.9
        """
        XCTAssertEqual(CommandLineToolsLabel.pick(from: output), "Command Line Tools for Xcode 26.10-26.10")
        XCTAssertEqual(CommandLineToolsLabel.compare([27, 2], [27, 2, 0]), .orderedSame)
        XCTAssertEqual(CommandLineToolsLabel.numericVersion("27.3b"), [27, 3])
    }
}

final class CommandLineToolsTests: XCTestCase {
    func testHeadlessInstallPicksTheLabelSwitchesAndCleansUp() async throws {
        let sandbox = Sandbox()
        sandbox.installSoftwareUpdate(listing: SoftwareUpdateFixtures.withBeta)

        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertEqual(result.check, .needed(nil))
        XCTAssertEqual(result.outcome, .done("installed Command Line Tools for Xcode 27.2-27.2"))
        // The receipt is only probed once git and clang exist; the list runs as the user, the install as root.
        XCTAssertEqual(sandbox.calls.filter { !$0.hasPrefix("sudo ") }, [
            "softwareupdate -l",
            "root softwareupdate -i Command Line Tools for Xcode 27.2-27.2 --verbose",
            "pkgutil --pkg-info=com.apple.pkg.CLTools_Executables",
            "xcode-select -p",
            "root xcode-select --switch \(sandbox.system.commandLineTools.path)",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.system.cltPlaceholder.path), "the placeholder must be removed")
        XCTAssertTrue(sandbox.calls.contains { $0.hasPrefix("sudo -A -- /usr/bin/touch") })
        XCTAssertTrue(sandbox.calls.contains { $0.hasPrefix("sudo -A -- /bin/rm -f") })

        sandbox.clearCalls()
        let second = try await sandbox.check("xcode-clt: install")
        XCTAssertEqual(second, .satisfied("installed"))
    }

    func testKeepsAnAlreadySelectedFullXcode() async throws {
        let sandbox = Sandbox()
        sandbox.installSoftwareUpdate()
        let xcode = sandbox.applications.appendingPathComponent("Xcode.app/Contents/Developer")
        makeExecutable(xcode.appendingPathComponent("usr/bin/xcodebuild"))
        sandbox.directory.write("system/xcode-select-path", xcode.path)

        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertTrue(result.outcome?.isDone == true)
        XCTAssertTrue(sandbox.calls("root xcode-select").isEmpty, "\(sandbox.calls)")
        XCTAssertTrue(sandbox.logText.contains("Keeping the selected Xcode"))
    }

    func testRetriesTheListThenFallsBackToTheDialog() async throws {
        let sandbox = Sandbox()
        sandbox.installSoftwareUpdate(listing: SoftwareUpdateFixtures.empty)
        let clt = sandbox.system.commandLineTools.path
        // The dialog "installs" the tools a moment later, in the background like the real one.
        sandbox.installXcodeSelect(dialog: """
        ( sleep 0.3; mkdir -p "\(clt)/usr/bin"; printf '#!/bin/sh\\n' > "\(clt)/usr/bin/git"; printf '#!/bin/sh\\n' > "\(clt)/usr/bin/clang"; chmod +x "\(clt)/usr/bin/git" "\(clt)/usr/bin/clang"; touch "\(clt)/.receipt" ) >/dev/null 2>&1 &
        echo "xcode-select: note: install requested for command line developer tools"
        """)
        sandbox.shim("pgrep", "exit 0")

        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertEqual(result.outcome, .done("installed with Apple's installer"))
        XCTAssertEqual(sandbox.calls("softwareupdate -l").count, 2, "listed twice before giving up")
        XCTAssertTrue(sandbox.calls("root softwareupdate -i").isEmpty)
        XCTAssertEqual(sandbox.calls("xcode-select --install").count, 1)
        XCTAssertEqual(sandbox.calls("root xcode-select --switch").count, 1)
        XCTAssertEqual(sandbox.attentions.first??.title, "Install the Command Line Tools")
        XCTAssertNil(sandbox.attentions.last ?? nil, "the callout is cleared at the end")
    }

    func testClosingTheDialogEndsInAFollowUpNotAFailure() async throws {
        let sandbox = Sandbox()
        sandbox.installSoftwareUpdate(installSucceeds: false)
        sandbox.installXcodeSelect(dialog: "exit 0")
        // The dialog is seen once, then it is gone (closed without installing).
        let seen = sandbox.root.appendingPathComponent("pgrep-seen").path
        sandbox.shim("pgrep", "if [ -f \"\(seen)\" ]; then exit 1; fi; touch \"\(seen)\"; exit 0")

        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertEqual(result.outcome, .needsAttention("the installer dialog was closed before the Command Line Tools were installed"))
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .warning && $0.text.contains("could not install Command Line Tools for Xcode 27.2-27.2") })
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Install the Xcode Command Line Tools"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.system.cltPlaceholder.path))
    }

    func testAHangingSoftwareUpdateFallsBackToTheDialog() async throws {
        let sandbox = Sandbox()
        sandbox.system.timing.cltInstallTimeout = 0.3
        sandbox.installSoftwareUpdate()
        let clt = sandbox.system.commandLineTools.path
        sandbox.shim("softwareupdate", """
        case "$1" in
          -l) cat "\(sandbox.root.path)/fixtures/su.txt" ;;
          -i) sleep 30 ;;
        esac
        """)
        sandbox.installXcodeSelect(dialog: """
        mkdir -p "\(clt)/usr/bin"; printf '#!/bin/sh\\n' > "\(clt)/usr/bin/git"; printf '#!/bin/sh\\n' > "\(clt)/usr/bin/clang"
        chmod +x "\(clt)/usr/bin/git" "\(clt)/usr/bin/clang"; touch "\(clt)/.receipt"
        """)
        sandbox.shim("pgrep", "exit 1")

        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertEqual(result.outcome, .done("installed with Apple's installer"))
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .warning && $0.text.contains("did not finish within") }, sandbox.logText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.system.cltPlaceholder.path))
    }

    func testAnInstallRequestThatFailsAtOnceDoesNotWait() async throws {
        let sandbox = Sandbox()
        sandbox.system.timing.cltDialogTimeout = 30
        sandbox.installSoftwareUpdate(installSucceeds: false)
        sandbox.installXcodeSelect(dialog: """
        echo 'xcode-select: error: command line tools are already installed, use "Software Update" in System Settings to install updates' >&2; exit 1
        """)
        sandbox.shim("pgrep", "exit 1")

        let started = Date()
        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "nothing to wait for: no dialog was opened (the timeout is 30 s)")
        guard case .needsAttention(let message)? = result.outcome else { return XCTFail("\(String(describing: result.outcome))") }
        XCTAssertTrue(message.hasPrefix("xcode-select --install did not start Apple's installer"), message)
        XCTAssertTrue(message.contains("already installed"), message)
        XCTAssertFalse(sandbox.attentions.compactMap { $0?.message }.contains { $0.contains("dialog macOS just opened") })
        XCTAssertTrue(sandbox.calls("pgrep").isEmpty)
        let followUp = try XCTUnwrap(sandbox.followUps.first)
        XCTAssertEqual(followUp.title, "Install the Xcode Command Line Tools")
        XCTAssertTrue(followUp.detail?.contains(sandbox.system.commandLineTools.path) == true, followUp.detail ?? "")
    }

    func testADialogThatNeverAppearsIsNotWaitedOnForTheWholeTimeout() async throws {
        let sandbox = Sandbox()
        sandbox.system.timing.cltDialogTimeout = 30
        sandbox.system.timing.cltDialogAppearanceTimeout = 0.3
        sandbox.installSoftwareUpdate(listing: SoftwareUpdateFixtures.empty)
        sandbox.installXcodeSelect(dialog: "echo 'xcode-select: note: install requested for command line developer tools'")
        sandbox.shim("pgrep", "exit 1")

        let started = Date()
        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(result.outcome, .needsAttention("Apple's installer dialog did not appear"))
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Install the Xcode Command Line Tools"])
        XCTAssertNil(sandbox.attentions.last ?? nil, "the callout is cleared at the end")
    }

    func testDialogTimeoutIsNeedsAttention() async throws {
        let sandbox = Sandbox()
        sandbox.system.timing.cltDialogTimeout = 0.2
        sandbox.installSoftwareUpdate(listing: SoftwareUpdateFixtures.empty)
        sandbox.installXcodeSelect(dialog: "exit 0")
        sandbox.shim("pgrep", "exit 1")
        let result = try await sandbox.run("xcode-clt: install")
        XCTAssertEqual(result.outcome, .needsAttention("the Command Line Tools did not finish installing in time"))
    }

    func testDryRunNarratesAndChangesNothing() async throws {
        let sandbox = Sandbox()
        sandbox.installSoftwareUpdate()
        let before = sandbox.snapshot()
        let result = try await sandbox.run("xcode-clt: install", dryRun: true)
        XCTAssertEqual(result.outcome, .done(nil))
        XCTAssertEqual(sandbox.snapshot(), before)
        // Only read-only probes ran.
        XCTAssertTrue(sandbox.calls.allSatisfy { $0.hasPrefix("pkgutil") || $0 == "xcode-select -p" }, "\(sandbox.calls)")
        let commands = sandbox.logLines.filter { $0.style == .command }.map(\.text)
        XCTAssertEqual(commands.count, 5, "\(commands)")
        XCTAssertTrue(commands[0].hasPrefix("[dry-run] $ sudo touch "))
        XCTAssertEqual(commands[1], "[dry-run] $ softwareupdate -l")
        XCTAssertTrue(commands[2].hasPrefix("[dry-run] $ sudo softwareupdate -i"))
        XCTAssertTrue(commands[3].hasPrefix("[dry-run] $ sudo rm -f "))
        XCTAssertTrue(commands[4].hasPrefix("[dry-run] $ sudo xcode-select --switch"))
    }

    func testCheckNeedsTheReceiptAsWellAsTheFiles() async throws {
        let sandbox = Sandbox()
        sandbox.installSoftwareUpdate()
        let bin = sandbox.system.commandLineTools.appendingPathComponent("usr/bin")
        makeExecutable(bin.appendingPathComponent("git"))
        makeExecutable(bin.appendingPathComponent("clang"))
        let withoutReceipt = try await sandbox.check("xcode-clt: install")
        XCTAssertEqual(withoutReceipt, .needed(nil))
        sandbox.directory.write("system/Library/Developer/CommandLineTools/.receipt", "")
        let withReceipt = try await sandbox.check("xcode-clt: install")
        XCTAssertEqual(withReceipt, .satisfied("installed"))
    }
}

final class HomebrewTests: XCTestCase {
    func testInstallsFromThePackageThenUpdatesAndRemembersIt() async throws {
        let sandbox = Sandbox()
        sandbox.environment.architecture = "arm64"
        sandbox.installHomebrewInstallers()

        let result = try await sandbox.run("homebrew: install")
        XCTAssertEqual(result.check, .needed(nil))
        XCTAssertEqual(result.outcome, .done("installed"))
        let calls = sandbox.calls.filter { !$0.hasPrefix("sudo ") }
        XCTAssertEqual(calls.map { $0.split(separator: " ").prefix(2).joined(separator: " ") },
                       ["curl -fL", "pkgutil --check-signature", "spctl --assess", "root installer", "brew --version", "brew update"])
        XCTAssertTrue(sandbox.calls.contains { $0.hasPrefix("sudo -A -- ") && $0.hasSuffix("-target /") })
        let updated = await Brew.hasUpdated(sandbox.context())
        XCTAssertTrue(updated)
        let downloads = sandbox.environment.cacheDirectory.appendingPathComponent("downloads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [], "the package is removed afterwards")

        sandbox.clearCalls()
        let second = try await sandbox.check("homebrew: install")
        XCTAssertEqual(second, .satisfied("installed"))
        XCTAssertEqual(sandbox.calls, ["brew --version"])
    }

    func testFallsBackToTheScriptWhenThePackageFails() async throws {
        let sandbox = Sandbox()
        sandbox.environment.architecture = "arm64"
        sandbox.installHomebrewInstallers(packageInstalls: false)
        let result = try await sandbox.run("homebrew: install")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .warning && $0.text.contains("Trying the official install script") })
        XCTAssertTrue(sandbox.logLines.contains { $0.text == "NONINTERACTIVE=1" }, "install.sh runs non-interactively")
        XCTAssertFalse(sandbox.calls("sudo").contains { $0.contains("bash") }, "install.sh is never run as root")
        XCTAssertEqual(sandbox.calls("curl").count, 2)
    }

    func testTheInstallScriptMayUseTheAdminPasswordButBrewUpdateIsNotToldAboutIt() async throws {
        let sandbox = Sandbox()
        sandbox.installHomebrewInstallers(scriptUsesSudo: true)
        sandbox.shim("pkg-installer")
        let session = try await sandbox.useRealSudo()
        defer { session.invalidate() }

        let result = try await sandbox.run("homebrew: install\nmethod: script")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("root pkg-installer"), ["root pkg-installer homebrew-prefix"],
                       "install.sh's own sudo -A got the password through the helper")
        XCTAssertFalse(sandbox.calls("sudo").contains { $0.contains("bash") }, "install.sh itself is never run as root")
        XCTAssertEqual(sandbox.brewAskpass, ["--version | askpass=unset", "update | askpass=unset"])
    }

    func testScriptMethodSkipsThePackage() async throws {
        let sandbox = Sandbox()
        sandbox.installHomebrewInstallers()
        let result = try await sandbox.run("homebrew: install\nmethod: script")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertTrue(sandbox.calls("root installer").isEmpty)
        XCTAssertEqual(sandbox.calls("curl").count, 1)
    }

    func testFailedUpdateStillCountsAsInstalled() async throws {
        let sandbox = Sandbox()
        sandbox.installHomebrewInstallers()
        sandbox.directory.write("homebrew/fail/update", "")
        let result = try await sandbox.run("homebrew: install\nmethod: script")
        XCTAssertEqual(result.outcome, .done("installed (brew update failed)"))
        let updated = await Brew.hasUpdated(sandbox.context())
        XCTAssertFalse(updated, "no HOMEBREW_NO_AUTO_UPDATE without a successful update")
    }

    func testDryRunTouchesNothing() async throws {
        let sandbox = Sandbox()
        sandbox.environment.architecture = "arm64"
        sandbox.installHomebrewInstallers()
        let before = sandbox.snapshot()
        let result = try await sandbox.run("homebrew: install", dryRun: true)
        XCTAssertEqual(result.outcome, .done(nil))
        XCTAssertEqual(sandbox.snapshot(), before)
        XCTAssertEqual(sandbox.calls, [])
        let commands = sandbox.logLines.filter { $0.style == .command }.map(\.text)
        XCTAssertTrue(commands[0].hasPrefix("[dry-run] $ curl -fL --retry 3 -o ~/Library/Caches/ShawnsDotfiles/downloads/"), commands[0])
        XCTAssertTrue(commands[1].hasPrefix("[dry-run] $ sudo installer -pkg"))
        XCTAssertEqual(commands[2], "[dry-run] $ brew update")
    }
}

final class RosettaTests: XCTestCase {
    func testInstallsOnAppleSiliconThenIsSatisfied() async throws {
        let sandbox = Sandbox()
        sandbox.environment.architecture = "arm64"
        let runtime = sandbox.system.rosettaRuntime.path
        sandbox.shim("softwareupdate", "mkdir -p \"$(dirname \"\(runtime)\")\"; touch \"\(runtime)\"")
        let result = try await sandbox.run("rosetta: install")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("root softwareupdate"), ["root softwareupdate --install-rosetta --agree-to-license"])
        let second = try await sandbox.check("rosetta: install")
        XCTAssertEqual(second, .satisfied("installed"))
    }

    func testSkippedOnIntel() async throws {
        let sandbox = Sandbox()
        sandbox.environment.architecture = "x86_64"
        let result = try await sandbox.run("rosetta: install")
        XCTAssertEqual(result.outcome, .skipped("this Mac has an Intel processor; Rosetta is not needed"))
        XCTAssertEqual(sandbox.calls, [])
    }

    func testMissingAfterInstallIsAnError() async throws {
        let sandbox = Sandbox()
        sandbox.environment.architecture = "arm64"
        sandbox.shim("softwareupdate", "exit 0")
        do {
            _ = try await sandbox.run("rosetta: install")
            XCTFail("expected a failure")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.contains("Rosetta is still missing"))
        }
    }
}
