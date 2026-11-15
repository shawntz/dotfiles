import XCTest
@testable import ActionsPackages
import ShawnCore

final class BrewKindsTests: XCTestCase {
    // MARK: brew (formulae)

    func testFormulaInstallsOnceThenIsSatisfiedFromTheCellar() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()

        let first = try await sandbox.run("brew: eza\nargs: [--force-bottle]")
        XCTAssertEqual(first.check, .needed(nil))
        XCTAssertEqual(first.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("brew"), ["brew install --formula eza --force-bottle"])

        // Second run: the Cellar probe (no brew call) says it is there.
        sandbox.clearCalls()
        let second = try await sandbox.run("brew: eza")
        XCTAssertEqual(second.check, .satisfied("installed"))
        XCTAssertNil(second.outcome)
        XCTAssertEqual(sandbox.calls, [])
    }

    func testFullyQualifiedThirdPartyFormulaIsPassedAsWrittenAndCheckedByShortName() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        let result = try await sandbox.run("brew: withgraphite/tap/graphite")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("brew"), ["brew install --formula withgraphite/tap/graphite"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.brewPrefix.appendingPathComponent("Cellar/graphite/1.0").path))
        let check = try await sandbox.check("brew: withgraphite/tap/graphite")
        XCTAssertEqual(check, .satisfied("installed"))
    }

    func testBrewGetsTheStandardEnvironmentAndNoAutoUpdateOnlyAfterAnUpdate() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        _ = try await sandbox.run("brew: fd")
        var environment = try XCTUnwrap(sandbox.directory.read("brew-env.txt"))
        for line in ["CI=1", "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_ASK=1", "HOMEBREW_NO_COLOR=1", "HOMEBREW_NO_EMOJI=1",
                     "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_UPDATE_REPORT_NEW=1"] {
            XCTAssertTrue(environment.contains(line), "missing \(line) in \(environment)")
        }
        XCTAssertFalse(environment.contains("HOMEBREW_NO_AUTO_UPDATE"))
        // Disabled or deprecated in Homebrew 7: setting any of these aborts or warns.
        for banned in ["HOMEBREW_ASK=", "HOMEBREW_NO_REQUIRE_TAP_TRUST", "HOMEBREW_NO_SUDO", "HOMEBREW_DEVELOPER", "HOMEBREW_BUNDLE_JOBS"] {
            XCTAssertFalse(environment.contains(banned))
        }

        await Brew.markUpdated(sandbox.context())
        _ = try await sandbox.run("brew: bat")
        environment = try XCTUnwrap(sandbox.directory.read("brew-env.txt"))
        XCTAssertTrue(environment.contains("HOMEBREW_NO_AUTO_UPDATE=1"))
    }

    func testBrewMissingMeansNeededAndARunErrorThatPointsAtTheHomebrewStep() async throws {
        let sandbox = Sandbox()
        for yaml in ["brew: eza", "cask: ghostty", "tap: buildkite/buildkite"] {
            let resolved = try sandbox.parse(yaml)
            let context = sandbox.context(resolved.item)
            let check = await resolved.action.check(context)
            XCTAssertEqual(check, .needed("Homebrew is not installed yet"), yaml)
            do {
                _ = try await resolved.action.run(context)
                XCTFail("\(yaml) should fail without brew")
            } catch let error as ActionError {
                XCTAssertEqual(error.message, "Homebrew is not installed")
                XCTAssertTrue(error.hint?.contains("homebrew: install") == true)
            }
        }
    }

    func testFailedInstallExplainsUntrustedTaps() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.directory.write("homebrew/fail/aerospace", "Error: Refusing to load cask aerospace from untrusted tap nikitabobko/tap.")
        do {
            _ = try await sandbox.run("cask: aerospace")
            XCTFail("expected a failure")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.contains("brew install --cask aerospace failed (exit 1)"), error.message)
            XCTAssertTrue(error.hint?.contains("fully qualified name") == true, error.hint ?? "")
        }
    }

    func testDryRunNarratesBrewWithoutRunningItEvenBeforeHomebrewExists() async throws {
        let sandbox = Sandbox()
        let before = sandbox.snapshot()
        let result = try await sandbox.run("brew: eza", dryRun: true)
        XCTAssertEqual(result.outcome, .done(nil))
        XCTAssertEqual(sandbox.calls, [])
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .command && $0.text == "[dry-run] $ brew install --formula eza" }, sandbox.logText)
        XCTAssertEqual(sandbox.snapshot(), before)
    }

    func testInstalledStateIsCachedThenInvalidatedAfterAnInstall() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        let context = sandbox.context()
        let initially = await Brew.installedFormulae(context)
        XCTAssertEqual(initially, [])
        // Appears behind the cache's back: not seen until something invalidates it.
        sandbox.directory.mkdir("homebrew/Cellar/jq/1.7")
        let stillCached = await Brew.installedFormulae(context)
        XCTAssertEqual(stillCached, [])
        _ = try await sandbox.run("brew: fzf")
        let afterInstall = await Brew.installedFormulae(context)
        XCTAssertEqual(afterInstall, ["jq", "fzf"])
        // An empty rack (left over from a half-removed keg) does not count.
        sandbox.directory.mkdir("homebrew/Cellar/ghost")
        await Brew.invalidateInstalledState(context)
        let hasEmptyRack = await Brew.installedFormulae(context).contains("ghost")
        XCTAssertFalse(hasEmptyRack)
    }

    // MARK: tap

    func testTapWithTrustTapsThenTrustsAndIsSatisfiedNextTime() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        let first = try await sandbox.run("tap: buildkite/buildkite\ntrusted: true")
        XCTAssertEqual(first.outcome, .done("tapped and trusted"))
        XCTAssertEqual(sandbox.calls("brew"), ["brew tap buildkite/buildkite", "brew trust buildkite/buildkite"])

        sandbox.clearCalls()
        let second = try await sandbox.run("tap: buildkite/buildkite\ntrusted: true")
        XCTAssertEqual(second.check, .satisfied("tapped and trusted"))
        XCTAssertEqual(sandbox.calls, [])
    }

    func testTappedButUntrustedOnlyRunsTrust() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.directory.mkdir("homebrew/Library/Taps/mikker/homebrew-tap")
        let untrustedCheck = try await sandbox.check("tap: mikker/tap")
        XCTAssertEqual(untrustedCheck, .satisfied("tapped"))
        let result = try await sandbox.run("tap: mikker/tap\ntrusted: true")
        XCTAssertEqual(result.check, .needed("tapped, not trusted yet"))
        XCTAssertEqual(sandbox.calls("brew"), ["brew trust mikker/tap"])
    }

    func testTrustStoreHonoursXDGConfigHome() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.environment.baseEnvironment["XDG_CONFIG_HOME"] = sandbox.root.appendingPathComponent("xdg").path
        sandbox.directory.mkdir("homebrew/Library/Taps/supabase/homebrew-tap")
        sandbox.directory.write("xdg/homebrew/trust.json", #"{"trustedtaps":["Supabase/Tap"],"trustedcasks":[]}"#)
        let xdgCheck = try await sandbox.check("tap: supabase/tap\ntrusted: true")
        XCTAssertEqual(xdgCheck, .satisfied("tapped and trusted"))
        // The default location is not consulted when XDG_CONFIG_HOME is set.
        sandbox.directory.write("home/.homebrew/trust.json", #"{"trustedtaps":["jurplel/tap"]}"#)
        sandbox.directory.mkdir("homebrew/Library/Taps/jurplel/homebrew-tap")
        await Brew.invalidateInstalledState(sandbox.context())
        let defaultStoreCheck = try await sandbox.check("tap: jurplel/tap\ntrusted: true")
        XCTAssertEqual(defaultStoreCheck, .needed("tapped, not trusted yet"))
    }

    func testTapWithCustomURLPassesItAlong() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        _ = try await sandbox.run("tap: shawntz/tools\nurl: 'https://github.com/shawntz/homebrew-tools.git'")
        XCTAssertEqual(sandbox.calls("brew"), ["brew tap shawntz/tools https://github.com/shawntz/homebrew-tools.git"])
    }

    // MARK: cask

    func testCaskInstallsAndLaunchesTheAppInTheBackground() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.shim("open")
        sandbox.directory.write("homebrew/cask-apps/dropbox", "Dropbox.app")
        let result = try await sandbox.run("cask: dropbox\napp: Dropbox.app\nlaunch: true")
        XCTAssertEqual(result.outcome, .done("installed and opened"))
        XCTAssertEqual(sandbox.calls, [
            "brew install --cask dropbox",
            "open -g -a \(sandbox.applications.appendingPathComponent("Dropbox.app").path)",
        ])
        sandbox.clearCalls()
        let secondCheck = try await sandbox.check("cask: dropbox\napp: Dropbox.app\nlaunch: true")
        XCTAssertEqual(secondCheck, .satisfied("installed"))
    }

    func testCaskAlreadyInstalledOutsideHomebrewIsSatisfiedViaApp() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.directory.mkdir("Applications/Google Chrome.app/Contents")
        let result = try await sandbox.run("cask: google-chrome\napp: Google Chrome.app")
        guard case .satisfied(let reason?) = result.check else { return XCTFail("expected satisfied, got \(result.check)") }
        XCTAssertTrue(reason.contains("Google Chrome.app is already in") && reason.contains("installed without Homebrew"), reason)
        XCTAssertEqual(sandbox.calls, [])

        // Without `app:` the same situation is "needed" (Homebrew would refuse); the error says how to fix it.
        sandbox.directory.write("homebrew/fail/google-chrome", "Error: It seems there is already an App at '/Applications/Google Chrome.app'.")
        do {
            _ = try await sandbox.run("cask: google-chrome")
            XCTFail("expected a failure")
        } catch let error as ActionError {
            XCTAssertTrue(error.hint?.contains("Add 'app: <Name>.app'") == true, error.hint ?? "")
        }
    }

    func testCaskWarnsWhenTheNamedAppDoesNotAppear() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.shim("open")
        let result = try await sandbox.run("cask: warp\napp: Warp.app\nlaunch: true")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .warning && $0.text.contains("Check 'app:'") })
        XCTAssertTrue(sandbox.calls("open").isEmpty, "nothing to open")
    }

    func testACaskMayUseTheAdminPasswordButFormulaeTapsAndUpdatesAreNotToldAboutIt() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.shim("pkg-installer")
        sandbox.directory.write("homebrew/cask-needs-sudo/karabiner-elements", "")
        let session = try await sandbox.useRealSudo()
        defer { session.invalidate() }

        _ = try await sandbox.run("tap: nikitabobko/tap")
        _ = try await sandbox.run("brew: eza")
        let cask = try await sandbox.run("cask: karabiner-elements")
        XCTAssertEqual(cask.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("root pkg-installer"), ["root pkg-installer karabiner-elements"],
                       "Homebrew's own sudo for the cask's .pkg got the password through the helper")

        // mas comes from Homebrew (no rights needed), then runs as root through sudo -A.
        sandbox.installFakeMas()
        sandbox.directory.mkdir("homebrew/pending")
        try FileManager.default.moveItem(at: sandbox.brewBin.appendingPathComponent("mas"), to: sandbox.brewPrefix.appendingPathComponent("pending/mas"))
        sandbox.stageAppStoreApp(id: "937984704", name: "Amphetamine")
        let mas = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(mas.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 937984704"])

        XCTAssertEqual(sandbox.brewAskpass, [
            "tap nikitabobko/tap | askpass=unset",
            "install --formula eza | askpass=unset",
            "install --cask karabiner-elements | askpass=set",
            "install --formula mas | askpass=unset",
        ])
    }

    func testWithoutThePasswordHelperACaskThatNeedsSudoFailsWithAHint() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.shim("pkg-installer")
        sandbox.installAskpassSudo()
        sandbox.directory.write("homebrew/cask-needs-sudo/karabiner-elements", "")
        do {
            _ = try await sandbox.run("cask: karabiner-elements")
            XCTFail("expected a failure")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.contains("brew install --cask karabiner-elements failed"), error.message)
            XCTAssertTrue(error.hint?.contains("needs administrator rights") == true, error.hint ?? "")
        }
        XCTAssertTrue(sandbox.calls("root pkg-installer").isEmpty)
    }

    func testAnUnacceptedXcodeLicenseGetsItsOwnHint() {
        let hint = Brew.hint(forFailureOutput: """
        Error: You have not agreed to the Xcode license. Please resolve this by running:
          sudo xcodebuild -license accept
        """)
        XCTAssertTrue(hint.contains("sudo xcodebuild -license accept"), hint)
        XCTAssertTrue(hint.contains("xcode: finish"), hint)
    }

    func testFullyQualifiedCaskIsCheckedInTheCaskroomByToken() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        _ = try await sandbox.run("cask: nikitabobko/tap/aerospace")
        XCTAssertEqual(sandbox.calls("brew"), ["brew install --cask nikitabobko/tap/aerospace"])
        let qualifiedCheck = try await sandbox.check("cask: nikitabobko/tap/aerospace")
        XCTAssertEqual(qualifiedCheck, .satisfied("installed"))
    }

    // MARK: npm

    func testNpmChecksWithLsAndInstallsGlobally() async throws {
        let sandbox = Sandbox()
        let installed = sandbox.root.appendingPathComponent("npm-installed")
        sandbox.shim("npm", at: sandbox.brewBin, """
        case "$1" in
          ls) [ -f "\(installed.path)" ] ;;
          install) touch "\(installed.path)"; echo "added 1 package" ;;
        esac
        """)
        let first = try await sandbox.run("npm: ghostty-config-cli")
        XCTAssertEqual(first.check, .needed(nil))
        XCTAssertEqual(first.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls, ["npm ls -g --depth=0 ghostty-config-cli", "npm install -g ghostty-config-cli"])

        sandbox.clearCalls()
        let second = try await sandbox.run("npm: ghostty-config-cli")
        XCTAssertEqual(second.check, .satisfied("installed"))
        XCTAssertEqual(sandbox.calls, ["npm ls -g --depth=0 ghostty-config-cli"])
    }

    func testNpmMissingIsNeededAndFailsWithAHint() async throws {
        let sandbox = Sandbox()
        let missingCheck = try await sandbox.check("npm: ghostty-config-cli")
        XCTAssertEqual(missingCheck, .needed("npm is not installed yet"))
        do {
            _ = try await sandbox.run("npm: ghostty-config-cli")
            XCTFail("expected a failure")
        } catch let error as ActionError {
            XCTAssertEqual(error.message, "npm is not installed")
            XCTAssertTrue(error.hint?.contains("brew: node") == true)
        }
        let dry = try await sandbox.run("npm: ghostty-config-cli", dryRun: true)
        XCTAssertEqual(dry.outcome, .done(nil))
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ npm install -g ghostty-config-cli"))
    }

    func testNpmFailurePropagatesItsOutput() async throws {
        let sandbox = Sandbox()
        sandbox.shim("npm", at: sandbox.brewBin, """
        if [ "$1" = install ]; then echo "npm error 404 Not Found" >&2; exit 1; fi
        exit 1
        """)
        do {
            _ = try await sandbox.run("npm: does-not-exist")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue("\(error)".contains("404 Not Found"), "\(error)")
        }
    }
}
