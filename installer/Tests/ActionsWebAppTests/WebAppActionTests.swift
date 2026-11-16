import XCTest
@testable import ActionsWebApp
import ShawnCore

final class WebAppActionTests: XCTestCase {
    private static let xItem = """
      - webapp: X
        url: https://x.com
        icon: webapp-icons/x.png
        hosts: [twitter.com]

    """

    private func makeSandbox(items: String = WebAppActionTests.xItem) -> WebAppSandbox {
        let sandbox = WebAppSandbox(items: items)
        sandbox.directory.write("config/webapp-icons/x.png", TestImages.solidPNG(size: 400, red: 0, green: 0, blue: 0))
        return sandbox
    }

    private func codesignVerifies(_ bundle: URL) throws -> Bool {
        try runProcess("/usr/bin/codesign", ["--verify", "--strict", bundle.path]).status == 0
    }

    private func failures(_ summary: InstallSummary) -> String {
        summary.failures.map(\.message).joined(separator: "\n")
    }

    // MARK: Building

    func testBuildsASignedBundleWithInfoPlistAndIcon() async throws {
        let sandbox = makeSandbox()
        let summary = try await sandbox.install()
        XCTAssertEqual(summary.failures.count, 0, failures(summary))
        XCTAssertEqual(summary.done, 1)

        let app = sandbox.app()
        let info = try XCTUnwrap(sandbox.info())
        XCTAssertEqual(info["ShawnWebAppURL"] as? String, "https://x.com")
        XCTAssertEqual(info["ShawnWebAppName"] as? String, "X")
        XCTAssertEqual(info["ShawnWebAppHosts"] as? [String], ["twitter.com"])
        XCTAssertNil(info["ShawnWebAppUserAgent"])
        XCTAssertNil(info["ShawnWebAppWidth"])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.shawnschwartz.webapp.x")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "X")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "27.0")
        XCTAssertEqual(info["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertNotNil(info["NSCameraUsageDescription"] as? String)
        XCTAssertNotNil(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertTrue((info["ShawnWebAppIcon"] as? String)?.hasPrefix("file:webapp-icons/x.png#") == true)
        XCTAssertEqual(info["ShawnWebAppIconOrigin"] as? String, "file:webapp-icons/x.png")
        XCTAssertEqual(info["ShawnWebAppShellSHA256"] as? String, Digest.sha256(Data(WebAppSandbox.fakeShell.utf8)))

        let executable = app.appendingPathComponent("Contents/MacOS/X")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertEqual(try Data(contentsOf: executable), Data(WebAppSandbox.fakeShell.utf8))
        let icns = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        XCTAssertEqual(TestImages.pixelWidths(of: icns).max(), 1024)
        XCTAssertTrue(try codesignVerifies(app))

        XCTAssertTrue(sandbox.fetcher.requests.isEmpty, "a configured icon file needs no network")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.environment.temporaryDirectory.path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix("shawn-webapp-") }, [], "scratch space is cleaned up")

        let check = try await sandbox.check()
        XCTAssertEqual(check, .satisfied("up to date"))
    }

    func testAllOptionsReachTheInfoPlistAndTheDestinationFolder() async throws {
        let sandbox = makeSandbox(items: """
          - webapp: Carbon
            url: https://my.carbonapp.co/dashboard
            to: ~/Applications/Web Apps
            bundle_id: co.carbonapp.mine
            user_agent: CarbonBot/1.0
            width: 1400
            height: 900
            hosts: ["*.auth0.com"]

        """)
        let summary = try await sandbox.install()
        XCTAssertEqual(summary.failures.count, 0, failures(summary))

        let app = sandbox.environment.home.appendingPathComponent("Applications/Web Apps/Carbon.app")
        let info = try XCTUnwrap(WebAppInfoPlist.read(bundle: app))
        XCTAssertEqual(info["ShawnWebAppURL"] as? String, "https://my.carbonapp.co/dashboard")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "co.carbonapp.mine")
        XCTAssertEqual(info["ShawnWebAppUserAgent"] as? String, "CarbonBot/1.0")
        XCTAssertEqual(info["ShawnWebAppWidth"] as? Int, 1400)
        XCTAssertEqual(info["ShawnWebAppHeight"] as? Int, 900)
        XCTAssertEqual(info["ShawnWebAppHosts"] as? [String], ["auth0.com"])
        XCTAssertEqual(info["ShawnWebAppIcon"] as? String, "auto")
        XCTAssertEqual(info["ShawnWebAppIconOrigin"] as? String, "letter")
    }

    // MARK: Icons

    func testUsesTheSitesOwnIconWhenNoneIsConfigured() async throws {
        let sandbox = makeSandbox(items: "  - webapp: X\n    url: https://x.com/home\n")
        sandbox.fetcher.serve("https://x.com/home", html: #"<link rel="apple-touch-icon" sizes="180x180" href="/touch.png">"#)
        sandbox.fetcher.serve("https://x.com/touch.png", TestImages.solidPNG(size: 180))

        let summary = try await sandbox.install()
        XCTAssertEqual(summary.failures.count, 0, failures(summary))
        XCTAssertEqual(sandbox.fetcher.requests, ["https://x.com/home", "https://x.com/touch.png"])
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIconOrigin"] as? String, "site:https://x.com/touch.png")
        XCTAssertEqual(TestImages.pixelWidths(of: sandbox.app().appendingPathComponent("Contents/Resources/AppIcon.icns")).max(), 1024)
    }

    func testDrawsALetterTileWhenTheSiteHasNoUsableIcon() async throws {
        let sandbox = makeSandbox(items: "  - webapp: Carbon\n    url: https://my.carbonapp.co\n")
        sandbox.fetcher.serve("https://my.carbonapp.co", html: "<html><head><title>Carbon</title></head></html>")
        sandbox.fetcher.serve("https://my.carbonapp.co/favicon.ico", TestImages.solidPNG(size: 16))
        let log = Recorder<LogLine>()

        let summary = try await sandbox.install(log: log)
        XCTAssertEqual(summary.failures.count, 0, failures(summary))
        let info = try XCTUnwrap(sandbox.info("Carbon"))
        XCTAssertEqual(info["ShawnWebAppIconOrigin"] as? String, "letter")
        XCTAssertEqual(info["ShawnWebAppIcon"] as? String, "auto")
        let icns = sandbox.app("Carbon").appendingPathComponent("Contents/Resources/AppIcon.icns")
        XCTAssertEqual(TestImages.pixelWidths(of: icns).max(), 1024)
        XCTAssertTrue(log.all.contains { $0.text == "icon: a letter tile for Carbon" }, "\(log.all.map(\.text))")

        let check = try await sandbox.check()
        XCTAssertEqual(check, .satisfied("up to date"), "a letter tile is an acceptable result for an automatic icon")
    }

    func testUnreachableConfiguredIconFallsBackNowAndIsRetriedNextRun() async throws {
        let iconItem = "  - webapp: X\n    url: https://x.com\n    icon: https://cdn.example.com/x.png\n"
        let sandbox = makeSandbox(items: iconItem)
        let log = Recorder<LogLine>()

        let summary = try await sandbox.install(log: log)
        XCTAssertEqual(summary.failures.count, 0, failures(summary))
        XCTAssertEqual(summary.done, 1)
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIcon"] as? String, "url-failed:https://cdn.example.com/x.png")
        XCTAssertTrue(log.all.contains { $0.style == .warning && $0.text.contains("could not use the icon at https://cdn.example.com/x.png") })
        // The reason says what really happened: nothing in the config or the icon changed.
        let check = try await sandbox.check()
        XCTAssertEqual(check, .needed("the icon at https://cdn.example.com/x.png could not be downloaded when X.app was built; it will be tried again"))

        // Still unreachable: the icon is tried again, but the app is not rebuilt (or the site searched again) for nothing.
        let executable = sandbox.app().appendingPathComponent("Contents/MacOS/X")
        let before = try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? Int
        let requestsBefore = sandbox.fetcher.requests.count
        let stillDown = try await sandbox.install()
        XCTAssertEqual(stillDown.failures.count, 0, failures(stillDown))
        XCTAssertEqual(stillDown.done, 0)
        XCTAssertEqual(stillDown.needsAttention, 1)
        XCTAssertEqual(Array(sandbox.fetcher.requests.dropFirst(requestsBefore)), ["https://cdn.example.com/x.png"])
        let after = try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "the bundle was not rebuilt")
        let (action, context) = try sandbox.firstItem()
        let outcome = try await action.run(context)
        XCTAssertEqual(outcome, .needsAttention("\(sandbox.app().path) keeps a stand-in icon because https://cdn.example.com/x.png still cannot be downloaded. "
            + "Check the address in 'icon:', or remove 'icon:' to use the site's own icon"))

        // Any other change still rebuilds, and the icon stays marked for another try.
        sandbox.setItems(iconItem + "    width: 1000\n")
        let resized = try await sandbox.install()
        XCTAssertEqual(resized.done, 1, failures(resized))
        XCTAssertEqual(sandbox.info()?["ShawnWebAppWidth"] as? Int, 1000)
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIcon"] as? String, "url-failed:https://cdn.example.com/x.png")

        sandbox.fetcher.serve("https://cdn.example.com/x.png", TestImages.solidPNG(size: 256))
        let retry = try await sandbox.install()
        XCTAssertEqual(retry.done, 1)
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIcon"] as? String, "url:https://cdn.example.com/x.png")
        let fixed = try await sandbox.check()
        XCTAssertEqual(fixed, .satisfied("up to date"))
    }

    func testAnIconThatDownloadsButCannotBeUsedIsNotCalledUndownloadable() async throws {
        // 'icon:' accepts any https address, and what it serves may be no use as an icon (here an SVG).
        let address = "https://cdn.example.com/logo.svg"
        let sandbox = makeSandbox(items: "  - webapp: X\n    url: https://x.com\n    icon: \(address)\n")
        sandbox.fetcher.serve(address, Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64"/></svg>"#.utf8))
        let log = Recorder<LogLine>()

        let first = try await sandbox.install(log: log)
        XCTAssertEqual(first.failures.count, 0, failures(first))
        XCTAssertEqual(first.done, 1)
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIcon"] as? String, "url-unusable:\(address)")
        XCTAssertTrue(log.all.contains { $0.style == .warning && $0.text.contains("could not use the icon at \(address) (SVG images are not supported") },
                      "\(log.all.map(\.text))")
        let check = try await sandbox.check()
        XCTAssertEqual(check, .needed("the icon at \(address) could not be used when X.app was built; it will be tried again"))

        // Still the same image: fetched again, nothing rebuilt, and the reason is the image, not the address.
        let executable = sandbox.app().appendingPathComponent("Contents/MacOS/X")
        let before = try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? Int
        let (action, context) = try sandbox.firstItem()
        let again = try await action.run(context)
        XCTAssertEqual(again, .needsAttention("\(sandbox.app().path) keeps a stand-in icon because the image at \(address) cannot be used "
            + "(SVG images are not supported; use a PNG, JPEG or ICNS file). Point 'icon:' at a PNG, JPEG or ICNS image, "
            + "or remove 'icon:' to use the site's own icon"))
        let after = try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "the bundle was not rebuilt")

        // A web page where the image should be (a CDN's error page sent with 200) is the same kind of problem.
        sandbox.fetcher.serve(address, html: "<html><body>Not found</body></html>")
        let page = try await action.run(context)
        guard case .needsAttention(let pageMessage) = page else { return XCTFail("expected needsAttention, got \(page)") }
        XCTAssertTrue(pageMessage.contains("because the image at \(address) cannot be used (not an image macOS can read"), pageMessage)

        sandbox.fetcher.serve(address, TestImages.solidPNG(size: 256))
        let fixed = try await sandbox.install()
        XCTAssertEqual(fixed.done, 1, failures(fixed))
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIcon"] as? String, "url:\(address)")
        let upToDate = try await sandbox.check()
        XCTAssertEqual(upToDate, .satisfied("up to date"))
    }

    func testAnIconAddressThatStartsServingSomethingUnusableIsRecordedAsUnusable() async throws {
        let address = "https://cdn.example.com/x.png"
        let sandbox = makeSandbox(items: "  - webapp: X\n    url: https://x.com\n    icon: \(address)\n")
        _ = try await sandbox.install()
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIcon"] as? String, "url-failed:\(address)")

        // The address answers now, but with a page: the record (and so every later reason) says so.
        sandbox.fetcher.serve(address, html: "<html><body>Moved</body></html>")
        let summary = try await sandbox.install()
        XCTAssertEqual(summary.done, 1, failures(summary))
        XCTAssertEqual(sandbox.info()?["ShawnWebAppIcon"] as? String, "url-unusable:\(address)")
        let check = try await sandbox.check()
        XCTAssertEqual(check, .needed("the icon at \(address) could not be used when X.app was built; it will be tried again"))
    }

    func testChangingAnUnreachableIconAddressIsStillAnIconChange() async throws {
        let sandbox = makeSandbox(items: "  - webapp: X\n    url: https://x.com\n    icon: https://cdn.example.com/x.png\n")
        _ = try await sandbox.install()
        sandbox.setItems("  - webapp: X\n    url: https://x.com\n    icon: https://cdn.example.com/x-new.png\n")
        let check = try await sandbox.check()
        XCTAssertEqual(check, .needed("icon changed since it was built"))
    }

    func testAnUnreadableIconFileFailsWithAHint() async throws {
        let sandbox = makeSandbox()
        sandbox.directory.write("config/webapp-icons/x.png", "this is not a png")
        let summary = try await sandbox.install()
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertTrue(failures(summary).contains("the icon 'webapp-icons/x.png' cannot be used: not an image macOS can read"), failures(summary))
        XCTAssertTrue(failures(summary).contains("remove 'icon:'"), failures(summary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.app().path))
    }

    // MARK: Dry run and idempotency

    func testDryRunFetchesAndWritesNothing() async throws {
        let sandbox = makeSandbox(items: "  - webapp: X\n    url: https://x.com\n    to: ~/Applications/Web\n")
        let log = Recorder<LogLine>()
        let summary = try await sandbox.install(dryRun: true, log: log)

        XCTAssertEqual(summary.failures.count, 0, failures(summary))
        XCTAssertEqual(summary.done, 1)
        XCTAssertTrue(sandbox.fetcher.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.environment.home.appendingPathComponent("Applications").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.environment.temporaryDirectory.path), [])
        let lines = log.all.map(\.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("[dry-run] would build ~/Applications/Web/X.app for https://x.com") }, "\(lines)")
        XCTAssertTrue(lines.contains("[dry-run] $ iconutil -c icns AppIcon.iconset"), "\(lines)")
        XCTAssertTrue(lines.contains("[dry-run] $ codesign --force --sign - X.app"), "\(lines)")
    }

    func testSecondRunChangesNothing() async throws {
        let sandbox = makeSandbox()
        _ = try await sandbox.install()
        let executable = sandbox.app().appendingPathComponent("Contents/MacOS/X")
        let before = try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? Int

        let second = try await sandbox.install()
        XCTAssertEqual(second.alreadyDone, 1)
        XCTAssertEqual(second.done, 0)
        let after = try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "the bundle was not rebuilt")
    }

    func testChangingTheURLRebuildsTheBundle() async throws {
        let sandbox = makeSandbox()
        _ = try await sandbox.install()

        sandbox.setItems(WebAppActionTests.xItem.replacingOccurrences(of: "https://x.com", with: "https://x.com/explore"))
        let stale = try await sandbox.check()
        XCTAssertEqual(stale, .needed("url changed since it was built"))

        let summary = try await sandbox.install()
        XCTAssertEqual(summary.done, 1, failures(summary))
        XCTAssertEqual(sandbox.info()?["ShawnWebAppURL"] as? String, "https://x.com/explore")
        XCTAssertTrue(try codesignVerifies(sandbox.app()))
        let fresh = try await sandbox.check()
        XCTAssertEqual(fresh, .satisfied("up to date"))
    }

    func testOtherChangesAreNamedInTheCheckReason() async throws {
        let sandbox = makeSandbox()
        _ = try await sandbox.install()

        sandbox.directory.write("config/webapp-icons/x.png", TestImages.solidPNG(size: 400, red: 1, green: 1, blue: 0))
        let iconChanged = try await sandbox.check()
        XCTAssertEqual(iconChanged, .needed("icon changed since it was built"))
        _ = try await sandbox.install()

        sandbox.setItems(WebAppActionTests.xItem + "    width: 1000\n")
        sandbox.writeShell(WebAppSandbox.fakeShell + "# a newer build\n")
        let both = try await sandbox.check()
        XCTAssertEqual(both, .needed("WebAppShell, width changed since it was built"))
    }

    func testDamagedBundlesAreRebuilt() async throws {
        let sandbox = makeSandbox()
        _ = try await sandbox.install()

        let executable = sandbox.app().appendingPathComponent("Contents/MacOS/X")
        try Data((WebAppSandbox.fakeShell + "echo tampered\n").utf8).write(to: executable)
        let tampered = try await sandbox.check()
        XCTAssertEqual(tampered, .needed("\(sandbox.app().path) has a missing or broken code signature"))

        try FileManager.default.removeItem(at: sandbox.app().appendingPathComponent("Contents/Resources/AppIcon.icns"))
        let incomplete = try await sandbox.check()
        XCTAssertEqual(incomplete, .needed("\(sandbox.app().path) is incomplete"))

        let summary = try await sandbox.install()
        XCTAssertEqual(summary.done, 1, failures(summary))
        let repaired = try await sandbox.check()
        XCTAssertEqual(repaired, .satisfied("up to date"))
    }

    // MARK: Failures

    func testMissingShellIsAClearError() async throws {
        let sandbox = WebAppSandbox(items: "  - webapp: X\n    url: https://x.com\n", installShell: false)
        let check = try await sandbox.check()
        XCTAssertEqual(check, .needed("WebAppShell is missing"))

        let summary = try await sandbox.install()
        XCTAssertEqual(summary.failures.count, 1)
        let message = failures(summary)
        XCTAssertTrue(message.contains("WebAppShell, the program inside every web app, is missing"), message)
        XCTAssertTrue(message.contains("~/.shawn/bin/WebAppShell"), message)
        XCTAssertTrue(message.contains("swift build -c release --product WebAppShell"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.app().path))
    }

    func testShellIsFoundInHelpersFirstThenInTheStateDirectory() throws {
        let sandbox = WebAppSandbox(items: "  - webapp: X\n    url: https://x.com\n", installShell: false)
        let stateCopy = sandbox.environment.stateDirectory.appendingPathComponent("bin/WebAppShell")
        sandbox.directory.write("home/.shawn/bin/WebAppShell", "#!/bin/sh\n", permissions: 0o755)
        XCTAssertEqual(WebAppShellLocator.locate(in: sandbox.environment), stateCopy)

        sandbox.writeShell(WebAppSandbox.fakeShell)
        XCTAssertEqual(WebAppShellLocator.locate(in: sandbox.environment), sandbox.directory.url.appendingPathComponent("helpers/WebAppShell"))

        var withoutHelpers = sandbox.environment
        withoutHelpers.helpersDirectory = nil
        XCTAssertEqual(WebAppShellLocator.locate(in: withoutHelpers), stateCopy)
    }

    func testRefusesToReplaceAnAppItDidNotMake() async throws {
        let sandbox = makeSandbox()
        let foreignPlist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.x.native"], format: .xml, options: 0)
        sandbox.directory.write("Applications/X.app/Contents/Info.plist", foreignPlist)

        let check = try await sandbox.check()
        XCTAssertEqual(check, .needed("\(sandbox.app().path) exists but was not made by this installer"))
        let summary = try await sandbox.install()
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertTrue(failures(summary).contains("already exists and was not made by Shawn's Dotfiles, so it was left alone"), failures(summary))
        XCTAssertEqual(WebAppInfoPlist.read(bundle: sandbox.app())?["CFBundleIdentifier"] as? String, "com.x.native")
    }

    func testWhenNeitherAppCanBeMovedInThePreviousOneIsSavedWhereTheHintSays() async throws {
        let sandbox = makeSandbox()
        _ = try await sandbox.install()
        sandbox.setItems(WebAppActionTests.xItem.replacingOccurrences(of: "https://x.com", with: "https://x.com/explore"))

        // The old bundle can be moved out of Applications, but neither the new one nor the old one back in.
        let lock = try FolderLock.denyAddingFolders(to: sandbox.environment.applicationsDirectory)
        defer { lock.allow() }
        let summary = try await sandbox.install()
        lock.allow()

        XCTAssertEqual(summary.failures.count, 1)
        let message = failures(summary)
        XCTAssertTrue(message.contains("could not install the new \(sandbox.app().path)"), message)
        XCTAssertTrue(message.contains("nor put the old one back"), message)
        let saved = sandbox.environment.backupDirectory.appendingPathComponent("X.app")
        XCTAssertTrue(message.contains("The previous app was saved to ~/.shawn/backups/\(sandbox.environment.runID)/X.app"), message)
        XCTAssertEqual(WebAppInfoPlist.read(bundle: saved)?["ShawnWebAppURL"] as? String, "https://x.com", "the saved copy is the old app")
        XCTAssertTrue(try codesignVerifies(saved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.app().path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.environment.temporaryDirectory.path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix("shawn-webapp-") }, [])

        // Once the folder is writable again, a rerun builds the app afresh.
        let rerun = try await sandbox.install()
        XCTAssertEqual(rerun.done, 1, failures(rerun))
        XCTAssertEqual(sandbox.info()?["ShawnWebAppURL"] as? String, "https://x.com/explore")
    }

    /// A move to another volume copies; one that fails part-way leaves some of the new bundle behind.
    private func partialCopy(of staged: URL) -> (URL, URL) throws -> Void {
        { from, to in
            if from == staged {
                try FileManager.default.createDirectory(at: to.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    private func stage(_ sandbox: WebAppSandbox) throws -> (scratch: URL, staged: URL) {
        let scratch = sandbox.environment.temporaryDirectory.appendingPathComponent("shawn-webapp-test")
        let staged = scratch.appendingPathComponent("X.app")
        try FileManager.default.createDirectory(at: staged.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try WebAppInfoPlist.serialize(["ShawnWebAppURL": "https://x.com/new"]).write(to: staged.appendingPathComponent("Contents/Info.plist"))
        return (scratch, staged)
    }

    func testAPartlyCopiedNewAppIsRemovedSoThePreviousOneComesBack() async throws {
        let sandbox = makeSandbox()
        _ = try await sandbox.install()
        let (action, context) = try sandbox.firstItem()
        let (scratch, staged) = try stage(sandbox)

        var keepScratch = false
        XCTAssertThrowsError(try action.install(staged, at: sandbox.app(), scratch: scratch, keepScratch: &keepScratch,
                                                context: context, move: partialCopy(of: staged))) { error in
            XCTAssertTrue("\(error)".contains("the previous version is still there"), "\(error)")
        }
        XCTAssertFalse(keepScratch)
        XCTAssertEqual(sandbox.info()?["ShawnWebAppURL"] as? String, "https://x.com", "the old app is back in place")
        XCTAssertTrue(try codesignVerifies(sandbox.app()))
    }

    func testAPartlyCopiedFirstInstallLeavesNothingBehind() async throws {
        let sandbox = makeSandbox()
        let (action, context) = try sandbox.firstItem()
        let (scratch, staged) = try stage(sandbox)

        var keepScratch = false
        XCTAssertThrowsError(try action.install(staged, at: sandbox.app(), scratch: scratch, keepScratch: &keepScratch,
                                                context: context, move: partialCopy(of: staged))) { error in
            XCTAssertTrue("\(error)".contains("could not install \(sandbox.app().path)"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.app().path), "no half-built app where Finder can see it")
    }

    func testInfoPlistComparisonIgnoresTheInformationalIconOrigin() {
        let expected: [String: Any] = ["ShawnWebAppURL": "https://x.com", "ShawnWebAppHosts": ["a.com"], "ShawnWebAppWidth": 900]
        var actual = expected
        actual["ShawnWebAppIconOrigin"] = "letter"
        XCTAssertEqual(WebAppInfoPlist.differences(expected: expected, actual: actual), [])
        actual["ShawnWebAppHosts"] = ["b.com"]
        actual["ShawnWebAppUserAgent"] = "old"
        XCTAssertEqual(WebAppInfoPlist.differences(expected: expected, actual: actual), ["hosts", "user_agent"])
    }
}
