import XCTest
@testable import ActionsPackages
import ShawnCore

extension Sandbox {
    /// A fake mas in Homebrew's bin. `install`/`get` copy `<sandbox>/staging/<id>/*` into Applications after
    /// `delay` seconds; a file `<sandbox>/mas-fail/<command>` makes that command fail.
    func installFakeMas(delay: TimeInterval = 0) {
        shim("mas", at: brewBin, """
        case "$1" in
          install|get)
            if [ -f "\(root.path)/mas-fail/$1" ]; then echo "Error: No bag entry – Could not find key 'buyProduct' in bag" >&2; exit 1; fi
            sleep \(delay)
            if [ -d "\(root.path)/staging/$2" ]; then cp -R "\(root.path)/staging/$2/." "\(applications.path)/"; fi
            echo "==> Got $2" ;;
          *) exit 64 ;;
        esac
        """)
    }

    /// Stages an App Store app (with its receipt) for the fake mas to "install".
    func stageAppStoreApp(id: String, name: String) {
        directory.write("staging/\(id)/\(name).app/Contents/_MASReceipt/receipt", "receipt")
    }

    /// Stages an Xcode.app whose xcodebuild and simctl keep their state in `<sandbox>/system/xcode-state`.
    func stageXcode() {
        let developer = root.appendingPathComponent("staging/\(XcodeAction.appStoreID)/Xcode.app/Contents/Developer/usr/bin")
        let state = root.appendingPathComponent("system/xcode-state").path
        directory.mkdir("system/xcode-state")
        shim("xcodebuild", at: developer, """
        state="\(state)"
        case "$1" in
          -license) if [ "$2" = check ]; then [ -f "$state/license" ]; exit $?; fi; touch "$state/license" ;;
          -checkFirstLaunchStatus) [ -f "$state/first-launch" ]; exit $? ;;
          -runFirstLaunch) touch "$state/first-launch" ;;
          -downloadPlatform) touch "$state/platform-$2" ;;
          -version) echo "Xcode 27.2" ;;
        esac
        """)
        shim("simctl", at: developer, """
        printf '{"runtimes":['
        sep=""
        for f in "\(state)"/platform-*; do
          [ -f "$f" ] || continue
          p="${f##*/platform-}"; [ "$p" = visionOS ] && p=xrOS
          printf '%s{"platform":"%s","isAvailable":true,"name":"%s 27.0"}' "$sep" "$p" "$p"; sep=","
        done
        printf ']}\\n'
        """)
        directory.write("staging/\(XcodeAction.appStoreID)/Xcode.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>27.2</string></dict></plist>
        """)
    }

    var xcodeDeveloper: URL { applications.appendingPathComponent("Xcode.app/Contents/Developer") }

    /// The fake Command Line Tools, already installed.
    func installCommandLineTools() {
        let bin = system.commandLineTools.appendingPathComponent("usr/bin")
        makeExecutable(bin.appendingPathComponent("git"))
        makeExecutable(bin.appendingPathComponent("clang"))
        directory.write("system/Library/Developer/CommandLineTools/.receipt", "")
    }

    /// Installs another full Xcode (e.g. a beta) and selects it, as `sudo xcode-select -s` would. Returns its developer directory.
    @discardableResult
    func selectOtherXcode(_ name: String) -> String {
        let developer = applications.appendingPathComponent("\(name)/Contents/Developer")
        makeExecutable(developer.appendingPathComponent("usr/bin/xcodebuild"))
        directory.write("system/xcode-select-path", developer.path)
        return developer.path
    }

    /// What the fake xcode-select would print for `-p`.
    var selectedDeveloperDirectory: String? {
        directory.read("system/xcode-select-path")?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MasTests: XCTestCase {
    func testAsksOnceInstallsAsRootAndIsSatisfiedAfterward() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas()
        sandbox.stageAppStoreApp(id: "937984704", name: "Amphetamine")
        sandbox.stageAppStoreApp(id: "1289583905", name: "Pixelmator Pro")

        let first = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(first.check, .needed(nil))
        XCTAssertEqual(first.outcome, .done("installed"))
        let second = try await sandbox.run("mas: 1289583905\nname: Pixelmator Pro")
        XCTAssertEqual(second.outcome, .done("installed"))

        XCTAssertEqual(sandbox.interaction.questions.map(\.title), ["Sign in to the App Store"], "asked once per run")
        let question = try XCTUnwrap(sandbox.interaction.questions.first)
        XCTAssertEqual(question.options.map(\.label), ["I'm signed in", "Skip App Store apps"])
        XCTAssertEqual(question.defaultOptionID, AppStore.signedInOption)
        XCTAssertEqual(question.url?.scheme, "macappstore")
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 937984704", "root mas install 1289583905"])
        // While mas runs, a callout says what it may be waiting for; it is gone afterward.
        let shown = sandbox.attentions.compactMap { $0 }
        XCTAssertEqual(shown.map(\.title), ["Installing Amphetamine from the App Store", "Installing Pixelmator Pro from the App Store"])
        XCTAssertTrue(shown.allSatisfy { $0.message.contains("password or Touch ID") }, "\(shown)")
        XCTAssertNil(sandbox.attentions.last ?? nil)

        let again = try await sandbox.check("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(again, .satisfied("installed from the App Store"))
    }

    func testSkippingTheSignInSkipsEveryAppStoreItemAndLeavesEachOnTheChecklist() async throws {
        let sandbox = Sandbox()
        sandbox.interaction = ScriptedInteraction(answers: ["Sign in to the App Store": AppStore.skipOption])
        sandbox.installFakeMas()
        let first = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        let second = try await sandbox.run("mas: 6448461551\nname: Command X")
        XCTAssertEqual(first.outcome, .skipped("App Store apps are skipped for this run"))
        XCTAssertEqual(second.outcome, .skipped("App Store apps are skipped for this run"))
        XCTAssertEqual(sandbox.interaction.questions.count, 1)
        XCTAssertTrue(sandbox.calls("root mas").isEmpty)
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Install Amphetamine from the App Store", "Install Command X from the App Store"])
        XCTAssertEqual(sandbox.followUps.map { $0.url?.absoluteString }, ["macappstore://apps.apple.com/app/id937984704",
                                                                         "macappstore://apps.apple.com/app/id6448461551"])
    }

    func testAStalledMasTimesOutIntoAFollowUp() async throws {
        let sandbox = Sandbox()
        sandbox.system.timing.masInstallTimeout = 0.5
        sandbox.installFakeMas(delay: 30)
        sandbox.stageAppStoreApp(id: "937984704", name: "Amphetamine")

        let started = Date()
        let result = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(result.outcome, .needsAttention("install Amphetamine from the App Store"))
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 937984704"], "a hung install is not followed by a get that can hang too")
        let followUp = try XCTUnwrap(sandbox.followUps.first)
        XCTAssertEqual(followUp.title, "Install Amphetamine from the App Store")
        XCTAssertEqual(followUp.url?.absoluteString, "macappstore://apps.apple.com/app/id937984704")
        XCTAssertTrue(followUp.detail?.contains("did not finish within") == true, followUp.detail ?? "")
        XCTAssertEqual(sandbox.attentions.compactMap { $0?.title }, ["Installing Amphetamine from the App Store"])
        XCTAssertNil(sandbox.attentions.last ?? nil, "the callout is cleared")
    }

    func testAnUnansweredSignInQuestionSkipsTheAppStoreForThisRunInsteadOfWaitingForever() async throws {
        let sandbox = Sandbox()
        let nobody = SilentInteraction()
        sandbox.otherInteraction = nobody
        sandbox.system.timing.appStoreQuestionTimeout = 0.3
        sandbox.installFakeMas()
        sandbox.stageAppStoreApp(id: "937984704", name: "Amphetamine")

        let started = Date()
        let download = try await sandbox.run("xcode: download")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let skipped = ActionOutcome.skipped("nobody answered the App Store question, so App Store apps are skipped for this run")
        XCTAssertEqual(download.outcome, skipped)
        let withdrawn = await eventually { nobody.withdrawn == 1 }
        XCTAssertTrue(withdrawn, "the unanswered question is taken off screen")

        let amphetamine = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(amphetamine.outcome, skipped)
        XCTAssertEqual(nobody.asked, 1, "asked once per run")
        let finish = try await sandbox.run("xcode: finish")
        XCTAssertEqual(finish.outcome, .skipped("App Store apps were skipped, so Xcode was not downloaded"))

        XCTAssertTrue(sandbox.calls("root mas").isEmpty)
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Install Xcode from the App Store", "Install Amphetamine from the App Store"])
        XCTAssertTrue(sandbox.followUps.allSatisfy { $0.detail?.contains("Nobody answered") == true && $0.url?.scheme == "macappstore" })
        XCTAssertTrue(sandbox.logLines.contains { $0.style == .warning && $0.text.contains("Nobody answered") }, sandbox.logText)
        // The question says up front that it does not wait forever.
        XCTAssertTrue(AppStore.signInQuestion(url: XcodeAction.storeURL, timeout: 600).message.contains("10 minutes"))
    }

    func testAnAnswerThatArrivesAfterTheTimeoutIsIgnored() async throws {
        let sandbox = Sandbox()
        // Like a terminal read: cannot be interrupted, and answers "I'm signed in" once it is too late.
        let late = LateInteraction(answer: AppStore.signedInOption, after: 2)
        sandbox.otherInteraction = late
        sandbox.system.timing.appStoreQuestionTimeout = 0.2
        sandbox.installFakeMas()

        let started = Date()
        let first = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the run does not wait for a question it gave up on")
        XCTAssertEqual(late.answered, 0, "returned before the answer came")
        XCTAssertEqual(first.outcome, .skipped("nobody answered the App Store question, so App Store apps are skipped for this run"))
        let answered = await eventually { late.answered == 1 }
        XCTAssertTrue(answered)

        let second = try await sandbox.run("mas: 6448461551\nname: Command X")
        XCTAssertEqual(second.outcome, .skipped("nobody answered the App Store question, so App Store apps are skipped for this run"))
        XCTAssertTrue(sandbox.calls("root mas").isEmpty, "the late answer changed nothing")
    }

    func testStoppingWhileTheQuestionIsUpCancelsTheItem() async throws {
        let sandbox = Sandbox()
        let nobody = SilentInteraction()
        sandbox.otherInteraction = nobody
        sandbox.system.timing.appStoreQuestionTimeout = 60
        sandbox.installFakeMas()

        let running = Task { try await sandbox.run("mas: 937984704\nname: Amphetamine") }
        let asked = await eventually { nobody.asked == 1 }
        XCTAssertTrue(asked)
        running.cancel()
        do {
            _ = try await running.value
            XCTFail("expected the item to be cancelled")
        } catch is CancellationError {
        }
        let withdrawn = await eventually { nobody.withdrawn == 1 }
        XCTAssertTrue(withdrawn)
        XCTAssertTrue(sandbox.calls("root mas").isEmpty, "the default answer a cancelled sheet returns is not taken as 'signed in'")
        let remembered = await sandbox.shared.value(AppStore.signInKey, as: AppStore.SignIn.self)
        XCTAssertNil(remembered, "a stopped run decides nothing")
    }

    func testWhenBrewCannotInstallMasItIsAFollowUp() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.directory.write("homebrew/fail/mas", "Error: Failed to download resource \"mas\"")
        let result = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(result.outcome, .needsAttention("mas could not be installed; install Amphetamine from the App Store"))
        let followUp = try XCTUnwrap(sandbox.followUps.first)
        XCTAssertEqual(followUp.title, "Install Amphetamine from the App Store")
        XCTAssertEqual(followUp.url?.absoluteString, "macappstore://apps.apple.com/app/id937984704")
        XCTAssertTrue(followUp.detail?.contains("Failed to download resource") == true, followUp.detail ?? "")
        XCTAssertTrue(sandbox.interaction.questions.isEmpty)
    }

    func testFallsBackToGet() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas()
        sandbox.stageAppStoreApp(id: "937984704", name: "Amphetamine")
        sandbox.directory.write("mas-fail/install", "")
        let result = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 937984704", "root mas get 937984704"])
    }

    func testWhenMasFailsTheAppStorePageBecomesAFollowUp() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas()
        sandbox.directory.write("mas-fail/install", "")
        sandbox.directory.write("mas-fail/get", "")
        let result = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(result.outcome, .needsAttention("install Amphetamine from the App Store"))
        let followUp = try XCTUnwrap(sandbox.followUps.first)
        XCTAssertEqual(followUp.title, "Install Amphetamine from the App Store")
        XCTAssertEqual(followUp.url?.absoluteString, "macappstore://apps.apple.com/app/id937984704")
        XCTAssertTrue(followUp.detail?.contains("buyProduct") == true)
    }

    func testAnAppWithoutAReceiptIsNotCountedAndMissingMasIsInstalledWithBrew() async throws {
        let sandbox = Sandbox()
        sandbox.directory.mkdir("Applications/Amphetamine.app/Contents")
        let check = try await sandbox.check("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(check, .needed("Amphetamine.app is there, but not from the App Store"))

        sandbox.installFakeBrew()
        sandbox.installFakeMas()
        let mas = sandbox.brewBin.appendingPathComponent("mas")
        try FileManager.default.createDirectory(at: sandbox.brewPrefix.appendingPathComponent("pending"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: mas, to: sandbox.brewPrefix.appendingPathComponent("pending/mas"))
        try FileManager.default.removeItem(at: sandbox.applications.appendingPathComponent("Amphetamine.app"))
        sandbox.stageAppStoreApp(id: "937984704", name: "Amphetamine")

        let result = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(result.outcome, .done("installed"))
        XCTAssertEqual(sandbox.calls("brew"), ["brew install --formula mas"])
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 937984704"])
    }

    func testNoMasAndNoHomebrewIsAFollowUp() async throws {
        let sandbox = Sandbox()
        let result = try await sandbox.run("mas: 937984704\nname: Amphetamine")
        XCTAssertEqual(result.outcome, .needsAttention("mas is not installed (it comes from '- brew: mas'); install Amphetamine from the App Store"))
        XCTAssertEqual(sandbox.followUps.first?.url?.absoluteString, "macappstore://apps.apple.com/app/id937984704")
        XCTAssertTrue(sandbox.interaction.questions.isEmpty)
    }

    func testDryRunAsksNothingAndChangesNothing() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas()
        sandbox.stageAppStoreApp(id: "937984704", name: "Amphetamine")
        let before = sandbox.snapshot()
        let result = try await sandbox.run("mas: 937984704\nname: Amphetamine", dryRun: true)
        XCTAssertEqual(result.outcome, .done(nil))
        XCTAssertEqual(sandbox.snapshot(), before)
        XCTAssertTrue(sandbox.interaction.questions.isEmpty)
        XCTAssertEqual(sandbox.calls, [])
        XCTAssertTrue(sandbox.logText.contains("[dry-run] $ sudo mas install 937984704"), sandbox.logText)
    }
}

final class XcodeTests: XCTestCase {
    func testDownloadRunsInTheBackgroundThenFinishWaitsAndSetsEverythingUp() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas(delay: 1)
        sandbox.stageXcode()
        sandbox.installXcodeSelect()

        let download = try await sandbox.run("xcode: download")
        XCTAssertEqual(download.check, .needed(nil))
        XCTAssertEqual(download.outcome, .done("downloading in the background"))
        // download returned while mas is still busy: nothing has landed yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.applications.appendingPathComponent("Xcode.app").path))
        let task = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
        XCTAssertNotNil(task)
        XCTAssertEqual(sandbox.interaction.questions.map(\.title), ["Sign in to the App Store"])
        XCTAssertEqual(sandbox.interaction.questions.first?.url, XcodeAction.storeURL)

        // A second download item does not start another one.
        let again = try XCTUnwrap(try sandbox.parse("xcode: download").action as? XcodeAction)
        let againOutcome = try await again.run(sandbox.context())
        XCTAssertEqual(againOutcome, .done("already downloading in the background"))

        let finish = try await sandbox.run("xcode: finish\nplatforms: [iOS]")
        XCTAssertEqual(finish.check, .needed("Xcode is not installed yet"))
        XCTAssertEqual(finish.outcome, .done("Xcode 27.2 is ready"))
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 497799835"])
        let developer = sandbox.xcodeDeveloper.path
        // The license is accepted by the download itself, as soon as Xcode lands (Homebrew refuses to run while
        // the active Xcode is unlicensed); finish selects Xcode only once it is fully set up.
        XCTAssertEqual(sandbox.calls.filter { $0.hasPrefix("root xcode") || $0.hasPrefix("xcodebuild -download") }, [
            "root xcodebuild -license accept",
            "root xcodebuild -runFirstLaunch",
            "root xcode-select -s \(developer)",
            "xcodebuild -downloadPlatform iOS",
        ])
        XCTAssertEqual(sandbox.attentions.compactMap { $0?.title }.first, "Waiting for Xcode")
        XCTAssertNil(sandbox.attentions.last ?? nil)

        let after = try await sandbox.check("xcode: finish\nplatforms: [iOS]")
        XCTAssertEqual(after, .satisfied("Xcode 27.2 is set up"))
        let downloadAfter = try await sandbox.check("xcode: download")
        XCTAssertEqual(downloadAfter, .satisfied("Xcode 27.2 is installed"))
    }

    func testTheLicenseIsAcceptedAsSoonAsXcodeLandsAndTheToolsStaySelectedUntilFinish() async throws {
        // No selection at all, and a stale selection of an Xcode that is not there (macOS then falls back to
        // /Applications/Xcode.app): either way, the new Xcode would become active the moment it lands.
        for stale in [false, true] {
            let sandbox = Sandbox()
            sandbox.installFakeMas(delay: 0.2)
            sandbox.stageXcode()
            sandbox.installXcodeSelect()
            sandbox.installCommandLineTools()
            if stale { sandbox.directory.write("system/xcode-select-path", sandbox.xcodeDeveloper.path) }
            let tools = sandbox.system.commandLineTools.path

            let download = try await sandbox.run("xcode: download")
            XCTAssertEqual(download.outcome, .done("downloading in the background"))
            XCTAssertEqual(sandbox.calls("root xcode-select"), ["root xcode-select --switch \(tools)"], "stale: \(stale)")
            let registered = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
            let outcome = try await XCTUnwrap(registered).value
            XCTAssertEqual(outcome, .done("downloaded"))
            XCTAssertEqual(sandbox.calls("root xcodebuild"), ["root xcodebuild -license accept"])
            XCTAssertEqual(sandbox.selectedDeveloperDirectory, tools, "the Command Line Tools stay selected until finish")

            let check = try await sandbox.check("xcode: finish")
            XCTAssertEqual(check, .needed("not selected, first launch not run"))
            let finish = try await sandbox.run("xcode: finish")
            XCTAssertEqual(finish.outcome, .done("Xcode 27.2 is ready"))
            XCTAssertEqual(sandbox.calls.filter { $0.hasPrefix("root xcode") }, [
                "root xcode-select --switch \(tools)",
                "root xcodebuild -license accept",
                "root xcodebuild -runFirstLaunch",
                "root xcode-select -s \(sandbox.xcodeDeveloper.path)",
            ])
        }
    }

    func testFinishKeepsADeliberatelySelectedOtherXcode() async throws {
        let sandbox = Sandbox()
        sandbox.stageXcode()
        sandbox.installXcodeSelect()
        try FileManager.default.copyItem(at: sandbox.root.appendingPathComponent("staging/\(XcodeAction.appStoreID)/Xcode.app"),
                                         to: sandbox.applications.appendingPathComponent("Xcode.app"))
        sandbox.directory.write("system/xcode-state/first-launch", "")
        let beta = sandbox.selectOtherXcode("Xcode-beta.app")

        let result = try await sandbox.run("xcode: finish")
        XCTAssertEqual(result.check, .needed("license not accepted"))
        XCTAssertEqual(result.outcome, .done("Xcode 27.2 is ready"))
        XCTAssertEqual(sandbox.calls.filter { $0.hasPrefix("root ") }, ["root xcodebuild -license accept"])
        XCTAssertEqual(sandbox.selectedDeveloperDirectory, beta)
        XCTAssertTrue(sandbox.logText.contains("Keeping the selected Xcode (\(beta))"), sandbox.logText)

        let after = try await sandbox.check("xcode: finish")
        XCTAssertEqual(after, .satisfied("Xcode 27.2 is set up"))
    }

    func testDownloadLeavesADeliberatelySelectedOtherXcodeAlone() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas(delay: 0.2)
        sandbox.stageXcode()
        sandbox.installXcodeSelect()
        sandbox.installCommandLineTools()
        let beta = sandbox.selectOtherXcode("Xcode-beta.app")

        let download = try await sandbox.run("xcode: download")
        XCTAssertEqual(download.outcome, .done("downloading in the background"))
        let registered = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
        _ = try await XCTUnwrap(registered).value
        XCTAssertTrue(sandbox.calls("root xcode-select").isEmpty, "\(sandbox.calls)")
        XCTAssertEqual(sandbox.selectedDeveloperDirectory, beta)
    }

    func testWhenBrewCannotInstallMasTheStorePageOpens() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeBrew()
        sandbox.directory.write("homebrew/fail/mas", "Error: Failed to download resource \"mas\"")
        sandbox.shim("open")
        sandbox.installXcodeSelect()
        sandbox.installCommandLineTools()
        let download = try await sandbox.run("xcode: download")
        XCTAssertEqual(download.outcome, .needsAttention("opened Xcode in the App Store. Click Get there"))
        XCTAssertEqual(sandbox.calls("open"), ["open \(XcodeAction.storeURL.absoluteString)"])
        // Xcode may land mid-run from the App Store too, so the Command Line Tools are kept selected here as well.
        XCTAssertEqual(sandbox.calls("root xcode-select"), ["root xcode-select --switch \(sandbox.system.commandLineTools.path)"])
        let followUp = try XCTUnwrap(sandbox.followUps.first)
        XCTAssertEqual(followUp.title, "Install Xcode from the App Store")
        XCTAssertEqual(followUp.url, XcodeAction.storeURL)
        XCTAssertTrue(followUp.detail?.contains("Failed to download resource") == true, followUp.detail ?? "")
        XCTAssertTrue(sandbox.interaction.questions.isEmpty)
        let background = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
        XCTAssertNil(background)
    }

    func testAStalledXcodeDownloadGivesUpAndOpensTheStore() async throws {
        let sandbox = Sandbox()
        sandbox.system.timing.xcodeDownloadTimeout = 0.5
        sandbox.installFakeMas(delay: 30)
        sandbox.shim("open")
        _ = try await sandbox.run("xcode: download")
        let registered = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
        let task = try XCTUnwrap(registered)
        let started = Date()
        let outcome = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(outcome, .needsAttention("mas could not download Xcode"))
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 497799835"])
        XCTAssertEqual(sandbox.calls("open"), ["open \(XcodeAction.storeURL.absoluteString)"])
        let followUp = try XCTUnwrap(sandbox.followUps.first)
        XCTAssertTrue(followUp.detail?.contains("did not finish within") == true, followUp.detail ?? "")
    }

    func testFinishOnlyDoesWhatIsMissing() async throws {
        let sandbox = Sandbox()
        sandbox.stageXcode()
        sandbox.installXcodeSelect()
        try FileManager.default.copyItem(at: sandbox.root.appendingPathComponent("staging/\(XcodeAction.appStoreID)/Xcode.app"),
                                         to: sandbox.applications.appendingPathComponent("Xcode.app"))
        sandbox.directory.write("system/xcode-state/license", "")
        sandbox.directory.write("system/xcode-select-path", sandbox.xcodeDeveloper.path)

        let result = try await sandbox.run("xcode: finish")
        XCTAssertEqual(result.check, .needed("first launch not run"))
        XCTAssertEqual(result.outcome, .done("Xcode 27.2 is ready"))
        XCTAssertEqual(sandbox.calls.filter { $0.hasPrefix("root ") }, ["root xcodebuild -runFirstLaunch"])
        XCTAssertTrue(sandbox.attentions.isEmpty, "nothing to wait for")
    }

    func testWhenMasFailsTheStoreOpensAndFinishGivesUpGracefully() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas()
        sandbox.shim("open")
        sandbox.directory.write("mas-fail/install", "")
        sandbox.directory.write("mas-fail/get", "")

        _ = try await sandbox.run("xcode: download")
        let registered = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
        let task = try XCTUnwrap(registered)
        let outcome = try await task.value
        XCTAssertEqual(outcome, .needsAttention("mas could not download Xcode"))
        XCTAssertEqual(sandbox.calls("open"), ["open \(XcodeAction.storeURL.absoluteString)"])

        let finish = try await sandbox.run("xcode: finish\ntimeout_minutes: 0.005")
        XCTAssertEqual(finish.outcome, .needsAttention("Xcode has not arrived yet"))
        XCTAssertEqual(Set(sandbox.followUps.map(\.title)), ["Install Xcode from the App Store", "Finish installing Xcode"])
        let shown = sandbox.attentions.compactMap { $0 }
        XCTAssertEqual(shown.map(\.title), ["Install Xcode from the App Store"])
        XCTAssertEqual(shown.first?.url, XcodeAction.storeURL)
    }

    func testFinishNoticesAnXcodeInstalledByHand() async throws {
        let sandbox = Sandbox()
        sandbox.stageXcode()
        sandbox.installXcodeSelect()
        let staged = sandbox.root.appendingPathComponent("staging/\(XcodeAction.appStoreID)/Xcode.app")
        let target = sandbox.applications.appendingPathComponent("Xcode.app")
        let arrival = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            try FileManager.default.copyItem(at: staged, to: target)
        }
        let result = try await sandbox.run("xcode: finish")
        try await arrival.value
        XCTAssertEqual(result.outcome, .done("Xcode 27.2 is ready"))
        XCTAssertEqual(sandbox.attentions.compactMap { $0?.title }, ["Install Xcode from the App Store"])
    }

    func testSkippingTheAppStoreSkipsBothHalves() async throws {
        let sandbox = Sandbox()
        sandbox.interaction = ScriptedInteraction(answers: ["Sign in to the App Store": AppStore.skipOption])
        sandbox.installFakeMas()
        let download = try await sandbox.run("xcode: download")
        XCTAssertEqual(download.outcome, .skipped("App Store apps are skipped for this run"))
        let finish = try await sandbox.run("xcode: finish")
        XCTAssertEqual(finish.outcome, .skipped("App Store apps were skipped, so Xcode was not downloaded"))
        XCTAssertTrue(sandbox.calls("root mas").isEmpty)
        XCTAssertEqual(sandbox.followUps.map(\.title), ["Install Xcode from the App Store"])
    }

    func testWithoutMasOrHomebrewTheStorePageOpens() async throws {
        let sandbox = Sandbox()
        sandbox.shim("open")
        let download = try await sandbox.run("xcode: download")
        XCTAssertEqual(download.outcome, .needsAttention("opened Xcode in the App Store. Click Get there"))
        XCTAssertEqual(sandbox.calls, ["open \(XcodeAction.storeURL.absoluteString)"])
        XCTAssertEqual(sandbox.followUps.first?.url, XcodeAction.storeURL)
    }

    func testCancellingBackgroundWorkStopsMas() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas(delay: 30)
        _ = try await sandbox.run("xcode: download")
        let registered = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
        let task = try XCTUnwrap(registered)
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        await sandbox.shared.cancelBackgroundWork()
        let outcome = try await task.value
        XCTAssertEqual(outcome, .skipped("cancelled"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testDryRunNarratesBothHalvesWithoutAskingOrWaiting() async throws {
        let sandbox = Sandbox()
        sandbox.installFakeMas()
        sandbox.installXcodeSelect()
        let before = sandbox.snapshot()
        let download = try await sandbox.run("xcode: download", dryRun: true)
        let finish = try await sandbox.run("xcode: finish\nplatforms: [visionOS]", dryRun: true)
        XCTAssertEqual(download.outcome, .done(nil))
        XCTAssertEqual(finish.outcome, .done(nil))
        XCTAssertEqual(sandbox.snapshot(), before)
        XCTAssertTrue(sandbox.interaction.questions.isEmpty)
        let backgroundTask = await sandbox.shared.backgroundTask(XcodeAction.backgroundID)
        XCTAssertNil(backgroundTask)
        let commands = sandbox.logLines.filter { $0.style == .command }.map(\.text)
        XCTAssertEqual(commands.count, 5, "\(commands)")
        XCTAssertEqual(commands[0], "[dry-run] $ sudo mas install 497799835")
        XCTAssertTrue(commands[4].hasSuffix("xcodebuild -downloadPlatform visionOS"))
    }
}
