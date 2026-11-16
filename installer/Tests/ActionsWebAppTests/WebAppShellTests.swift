import XCTest
@testable import ActionsWebApp
import ShawnCore

/// Exercises the real WebAppShell executable through its command-line interface (`--print-config`,
/// `--check-url`), which never opens a window. The test target cannot import an executable target
/// without a manifest dependency, so the binary SwiftPM built next to this test bundle is run instead.
final class WebAppShellTests: XCTestCase {
    private struct MissingBinary: Error, CustomStringConvertible {
        let description: String
    }

    private func shellBinary() throws -> URL {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("WebAppShell")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw MissingBinary(description: "WebAppShell was not built next to the test bundle (\(binary.path)); run 'swift build' first")
        }
        return binary
    }

    private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> ProcessResult {
        try runProcess(try shellBinary().path, arguments, environment: ["PATH": "/usr/bin:/bin"].merging(environment) { $1 })
    }

    private func json(_ result: ProcessResult, file: StaticString = #filePath, line: UInt = #line) throws -> Any {
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        return try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
    }

    // MARK: Configuration

    func testPrintConfigFromTheEnvironment() throws {
        let result = try run(["--print-config"], environment: [
            "SHAWN_WEBAPP_URL": "https://my.carbonapp.co/home",
            "SHAWN_WEBAPP_NAME": "Carbon",
            "SHAWN_WEBAPP_HOSTS": "Auth0.com, *.google.com auth0.com",
            "SHAWN_WEBAPP_USER_AGENT": "CarbonBot/1.0",
            "SHAWN_WEBAPP_WIDTH": "1400",
        ])
        let config = try XCTUnwrap(try json(result) as? [String: Any])
        XCTAssertEqual(config["source"] as? String, "environment")
        XCTAssertEqual(config["url"] as? String, "https://my.carbonapp.co/home")
        XCTAssertEqual(config["name"] as? String, "Carbon")
        XCTAssertEqual(config["site"] as? String, "carbonapp.co")
        XCTAssertEqual(config["hosts"] as? [String], ["auth0.com", "google.com"])
        XCTAssertEqual(config["userAgent"] as? String, "CarbonBot/1.0")
        XCTAssertEqual(config["width"] as? Int, 1400)
        XCTAssertEqual(config["height"] as? Int, 800)
        XCTAssertEqual(config["bundleIdentifier"] as? String, "com.shawnschwartz.webapp.carbon")
        XCTAssertEqual(config["frameAutosaveName"] as? String, "com.shawnschwartz.webapp.carbon")
    }

    func testDefaultsAndLoopbackHTTP() throws {
        let config = try XCTUnwrap(try json(run(["--print-config"], environment: ["SHAWN_WEBAPP_URL": "http://localhost:3000"])) as? [String: Any])
        XCTAssertEqual(config["name"] as? String, "localhost")
        XCTAssertEqual(config["site"] as? String, "localhost")
        XCTAssertEqual(config["hosts"] as? [String], [])
        XCTAssertTrue(config["userAgent"] is NSNull)
        XCTAssertEqual(config["width"] as? Int, 1200)
    }

    func testInvalidConfigurationIsExplained() throws {
        let cases: [([String: String], String)] = [
            ([:], "SHAWN_WEBAPP_URL is missing from the environment"),
            (["SHAWN_WEBAPP_URL": "http://x.com"], "SHAWN_WEBAPP_URL must be an https:// address (got http://x.com)"),
            (["SHAWN_WEBAPP_URL": "not a url"], "SHAWN_WEBAPP_URL is not a valid web address"),
            (["SHAWN_WEBAPP_URL": "https://x.com", "SHAWN_WEBAPP_HOSTS": "https://t.co"], "SHAWN_WEBAPP_HOSTS entry 'https://t.co' is not a host name"),
            (["SHAWN_WEBAPP_URL": "https://x.com", "SHAWN_WEBAPP_WIDTH": "12"], "SHAWN_WEBAPP_WIDTH must be between 320 and 10000 (got 12)"),
            (["SHAWN_WEBAPP_URL": "https://x.com", "SHAWN_WEBAPP_HEIGHT": "tall"], "SHAWN_WEBAPP_HEIGHT must be a whole number"),
        ]
        for (environment, message) in cases {
            let result = try run(["--print-config"], environment: environment)
            XCTAssertEqual(result.status, 1, "\(environment)")
            XCTAssertTrue(result.stderr.contains(message), "expected '\(message)' in: \(result.stderr)")
            XCTAssertEqual(result.stdout, "")
        }
    }

    func testUsageErrorsAndHelp() throws {
        let unknown = try run(["--bogus"])
        XCTAssertEqual(unknown.status, 64)
        XCTAssertTrue(unknown.stderr.contains("unknown option --bogus"), unknown.stderr)

        let noAddress = try run(["--check-url"], environment: ["SHAWN_WEBAPP_URL": "https://x.com"])
        XCTAssertEqual(noAddress.status, 64)
        let noFrame = try run(["--check-url", "vnc://a.example", "--frame"], environment: ["SHAWN_WEBAPP_URL": "https://x.com"])
        XCTAssertEqual(noFrame.status, 64)
        XCTAssertTrue(noFrame.stderr.contains("--frame needs a frame address"), noFrame.stderr)

        let help = try run(["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.contains("--print-config"))
    }

    // MARK: Navigation policy

    private func decisions(_ urls: [String], from page: String? = nil, frame: String? = nil,
                           hosts: String = "twimg.com") throws -> [String: [String: Any]] {
        var arguments = ["--check-url"] + urls
        if let page { arguments += ["--from", page] }
        if let frame { arguments += ["--frame", frame] }
        let list = try XCTUnwrap(try json(run(arguments, environment: ["SHAWN_WEBAPP_URL": "https://x.com/home", "SHAWN_WEBAPP_HOSTS": hosts])) as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: list.map { ($0["url"] as! String, $0) })
    }

    func testSameSiteAndListedHostsStayInTheAppOtherSitesOpenInTheBrowser() throws {
        let result = try decisions([
            "https://x.com/explore", "https://mobile.x.com/i/flow", "https://abs.twimg.com/a.png",
            "https://t.co/abc", "https://notx.com/", "mailto:someone@example.com", "zoommtg://zoom.us/join",
        ])
        func decision(_ url: String, _ kind: String) -> String? { result[url]?[kind] as? String }

        XCTAssertEqual(decision("https://x.com/explore", "linkClick"), "app")
        XCTAssertEqual(decision("https://mobile.x.com/i/flow", "linkClick"), "app")
        XCTAssertEqual(result["https://abs.twimg.com/a.png"]?["inApp"] as? Bool, true)
        XCTAssertEqual(decision("https://abs.twimg.com/a.png", "linkClick"), "app")

        XCTAssertEqual(result["https://t.co/abc"]?["inApp"] as? Bool, false)
        XCTAssertEqual(decision("https://t.co/abc", "linkClick"), "browser")
        XCTAssertEqual(decision("https://notx.com/", "linkClick"), "browser", "a suffix match is not the same site")
        XCTAssertEqual(decision("mailto:someone@example.com", "linkClick"), "browser")
        // Another app only opens unasked when the user clicked a link in the page.
        XCTAssertEqual(decision("zoommtg://zoom.us/join", "linkClick"), "browser")
        XCTAssertEqual(decision("zoommtg://zoom.us/join", "redirect"), "ask")

        // ⌘-click always means "somewhere else".
        XCTAssertEqual(decision("https://x.com/explore", "commandClick"), "browser")
    }

    func testSignInFlowsStayInTheApp() throws {
        let result = try decisions(["https://accounts.google.com/o/oauth2/auth", "https://appleid.apple.com/auth/authorize", "about:blank"])
        func decision(_ url: String, _ kind: String) -> String? { result[url]?[kind] as? String }

        // Redirects and form posts that leave the site (OAuth) stay in the window.
        XCTAssertEqual(decision("https://accounts.google.com/o/oauth2/auth", "redirect"), "app")
        // window.open (a sign-in pop-up) becomes an in-app child window, including a blank one filled in later.
        XCTAssertEqual(decision("https://appleid.apple.com/auth/authorize", "windowOpen"), "popup")
        XCTAssertEqual(decision("about:blank", "windowOpen"), "popup")
        // Inside a pop-up anything web may load.
        XCTAssertEqual(decision("https://appleid.apple.com/auth/authorize", "linkClickInPopup"), "app")
        // Embedded frames never take over the window.
        XCTAssertEqual(decision("https://accounts.google.com/o/oauth2/auth", "frame"), "app")

        // Once a redirect has landed on the provider, its own links stay in the app...
        let onProvider = try decisions(["https://accounts.google.com/signin/v2/challenge", "https://example.org/"],
                                       from: "https://accounts.google.com/o/oauth2/auth")
        XCTAssertEqual(onProvider["https://accounts.google.com/signin/v2/challenge"]?["linkClick"] as? String, "app")
        // ...but links to third sites still go to the browser.
        XCTAssertEqual(onProvider["https://example.org/"]?["linkClick"] as? String, "browser")
    }

    func testTargetBlankLinksLoadHereOrInTheBrowser() throws {
        let result = try decisions(["https://x.com/compose", "https://github.com/shawntz"])
        XCTAssertEqual(result["https://x.com/compose"]?["targetBlankLink"] as? String, "app")
        XCTAssertEqual(result["https://github.com/shawntz"]?["targetBlankLink"] as? String, "browser")
    }

    func testOtherAppsOpenOnlyFromAClickOrAfterAskingAndNeverFromAFrameOnItsOwn() throws {
        let addresses = ["vnc://attacker.example", "smb://attacker.example/share", "ssh://attacker.example", "mailto:someone@example.com"]
        let result = try decisions(addresses)
        for address in addresses {
            func decision(_ kind: String) -> String? { result[address]?[kind] as? String }
            // A click on a link in the page (or a pop-up's page) is the user's own request.
            XCTAssertEqual(decision("linkClick"), "browser", address)
            XCTAssertEqual(decision("commandClick"), "browser", address)
            XCTAssertEqual(decision("linkClickInPopup"), "browser", address)
            XCTAssertEqual(decision("targetBlankLink"), "browser", address)
            // Nobody clicked (a redirect, or script setting location or calling link.click(), which WebKit reports
            // as a link activation with no mouse button), or the click was inside someone else's frame: ask first.
            XCTAssertEqual(decision("redirect"), "ask", address)
            XCTAssertEqual(decision("scriptedLinkClick"), "ask", address)
            XCTAssertEqual(decision("frameLinkClick"), "ask", address)
            // window.open only gets this far during a click (pop-ups need one), and still asks.
            XCTAssertEqual(decision("windowOpen"), "ask", address)
            // An embedded frame never launches anything by itself.
            XCTAssertEqual(decision("frame"), "blocked", address)
            XCTAssertEqual(decision("frameScriptedLinkClick"), "blocked", address)
        }

        // Local files and apps are never handed over, whoever asks.
        let file = try XCTUnwrap(try decisions(["file:///System/Applications/Calculator.app"]).first?.value)
        for kind in ["linkClick", "redirect", "frame", "frameLinkClick", "targetBlankLink", "windowOpen"] {
            XCTAssertEqual(file[kind] as? String, "blocked", kind)
        }

        // Web addresses are unaffected: frames load them inside the frame, and a scripted click counts as a click.
        let web = try decisions(["https://www.youtube.com/embed/abc", "https://x.com/explore"])
        XCTAssertEqual(web["https://www.youtube.com/embed/abc"]?["frame"] as? String, "app")
        XCTAssertEqual(web["https://www.youtube.com/embed/abc"]?["frameLinkClick"] as? String, "app")
        XCTAssertEqual(web["https://www.youtube.com/embed/abc"]?["scriptedLinkClick"] as? String, "browser")
        XCTAssertEqual(web["https://x.com/explore"]?["scriptedLinkClick"] as? String, "app")
    }

    func testALinkInAnEmbeddedFrameAsksFirstWhicheverWindowItTargets() throws {
        // A player card from another site inside the page, with a link to another app styled as a play button.
        let addresses = ["vnc://attacker.example", "smb://attacker.example/share", "mailto:someone@example.com"]
        let result = try decisions(addresses)
        for address in addresses {
            func decision(_ kind: String) -> String? { result[address]?[kind] as? String }
            // Only a link in the page itself is the user's own request. A click in someone else's frame asks, whether
            // the link opens in the frame, replaces the whole page (target="_top") or opens a new window (target="_blank").
            XCTAssertEqual(decision("frameLinkClick"), "ask", address)
            XCTAssertEqual(decision("frameTopLinkClick"), "ask", address)
            XCTAssertEqual(decision("frameBlankLinkClick"), "ask", address)
            // Script in the frame sending the whole page there, with no click, is the frame acting on its own.
            XCTAssertEqual(decision("frameTopNavigation"), "blocked", address)
            // The page's own link still opens the other app at once.
            XCTAssertEqual(decision("linkClick"), "browser", address)
        }

        // Web links in a frame are judged as before: another site opens in the browser, the app's own stays in the app.
        let web = try decisions(["https://github.com/shawntz", "https://x.com/explore"])
        XCTAssertEqual(web["https://github.com/shawntz"]?["frameTopLinkClick"] as? String, "browser")
        XCTAssertEqual(web["https://github.com/shawntz"]?["frameBlankLinkClick"] as? String, "browser")
        XCTAssertEqual(web["https://x.com/explore"]?["frameTopLinkClick"] as? String, "app")
        XCTAssertEqual(web["https://github.com/shawntz"]?["frameTopNavigation"] as? String, "app")
    }

    func testTheQuestionNamesTheFrameThatAskedNotThePageAroundIt() throws {
        let address = "vnc://attacker.example"
        let fromCard = try decisions([address], frame: "https://cards.example/player")
        let question = try XCTUnwrap(fromCard[address]?["question"] as? [String: Any], "\(fromCard)")
        let app = try XCTUnwrap(question["app"] as? String, "macOS always has an app for vnc: (Screen Sharing)")
        XCTAssertEqual(question["title"] as? String, "Open \"\(app)\"?")
        // A link clicked in a player card on x.com is the card's request, not x.com's.
        XCTAssertEqual(question["fromFrame"] as? String, "cards.example, embedded in this page, wants to open vnc://attacker.example in \(app).")
        // The page itself asking (its script, or a redirect it started) is named by its own site, not the address it is sent to.
        XCTAssertEqual(question["fromPage"] as? String, "x.com wants to open vnc://attacker.example in \(app).")

        // A frame or page with no site of its own (a sandboxed frame; nothing loaded yet) is not given someone else's.
        let anonymous = try decisions([address], from: "about:blank")
        let unnamed = try XCTUnwrap(anonymous[address]?["question"] as? [String: Any])
        XCTAssertEqual(unnamed["fromFrame"] as? String, "Something embedded in this page wants to open vnc://attacker.example in \(app).")
        XCTAssertEqual(unnamed["fromPage"] as? String, "This page wants to open vnc://attacker.example in \(app).")

        // Long addresses are cut short.
        let long = "vnc://attacker.example/" + String(repeating: "a", count: 300)
        let cut = try XCTUnwrap(try decisions([long])[long]?["question"] as? [String: Any])
        XCTAssertEqual(cut["fromPage"] as? String, "x.com wants to open \(long.prefix(200))… in \(app).")

        // Nothing is asked about web addresses, local files, or a scheme no app on this Mac handles.
        let none = try decisions(["https://github.com/shawntz", "file:///System/Applications/Calculator.app", "x-shawn-test-no-handler://x"])
        for (url, decision) in none {
            XCTAssertTrue(decision["question"] is NSNull, "\(url): \(decision)")
        }
    }

    func testPopUpsNeedAClickAndAreCapped() throws {
        let config = try XCTUnwrap(try json(run(["--print-config"], environment: ["SHAWN_WEBAPP_URL": "https://x.com"])) as? [String: Any])
        // Read back from the WebKit configuration the windows are made with: window.open without a click fails.
        XCTAssertEqual(config["popupsRequireUserGesture"] as? Bool, true)
        XCTAssertEqual(config["popupLimit"] as? Int, 5)

        let result = try decisions(["https://appleid.apple.com/auth/authorize", "about:blank", "https://github.com/shawntz"])
        XCTAssertEqual(result["https://appleid.apple.com/auth/authorize"]?["windowOpen"] as? String, "popup")
        XCTAssertEqual(result["https://appleid.apple.com/auth/authorize"]?["windowOpenAtPopupLimit"] as? String, "blocked")
        XCTAssertEqual(result["about:blank"]?["windowOpenAtPopupLimit"] as? String, "blocked")
        // The limit is on pop-up windows; a link that opens in the browser is not one.
        XCTAssertEqual(result["https://github.com/shawntz"]?["targetBlankLink"] as? String, "browser")
    }

    func testOnlyThePageAndTheAppsOwnSitesMayStartDownloads() throws {
        let result = try decisions(["https://x.com/export.csv", "https://pbs.twimg.com/media/a.zip", "https://ads.example/Update.dmg"])
        func decision(_ url: String, _ kind: String) -> String? { result[url]?[kind] as? String }

        // Anything the page itself loads as a file is saved.
        XCTAssertEqual(decision("https://x.com/export.csv", "download"), "download")
        XCTAssertEqual(decision("https://ads.example/Update.dmg", "download"), "download")
        // A hidden frame on the app's own sites is how many exports work...
        XCTAssertEqual(decision("https://x.com/export.csv", "frameDownload"), "download")
        XCTAssertEqual(decision("https://pbs.twimg.com/media/a.zip", "frameDownload"), "download")
        // ...but someone else's frame cannot drop files into Downloads.
        XCTAssertEqual(decision("https://ads.example/Update.dmg", "frameDownload"), "cancel")
    }

    // MARK: Failed loads

    private func errorDecision(_ arguments: [String]) throws -> [String: Any] {
        try XCTUnwrap(try json(run(["--check-error"] + arguments, environment: ["SHAWN_WEBAPP_URL": "https://x.com/home"])) as? [String: Any])
    }

    func testDownloadsAndCancelledLoadsDoNotReplaceThePageWithAnErrorPage() throws {
        // What WKWebView reports when a response becomes a download or a navigation is canceled by policy.
        XCTAssertEqual(try errorDecision(["WebKitErrorDomain", "102"])["showsErrorPage"] as? Bool, false)
        XCTAssertEqual(try errorDecision(["WebKitErrorDomain", "204"])["showsErrorPage"] as? Bool, false)
        XCTAssertEqual(try errorDecision(["NSURLErrorDomain", "-999"])["showsErrorPage"] as? Bool, false)
        // WKErrorDomain has no code 102; matching it there was the bug.
        XCTAssertEqual(try errorDecision(["WKErrorDomain", "102"])["showsErrorPage"] as? Bool, true)
    }

    func testReloadOnTheErrorPageRetriesTheSite() throws {
        let offline = try errorDecision(["NSURLErrorDomain", "-1009", "https://x.com/notifications"])
        XCTAssertEqual(offline["showsErrorPage"] as? Bool, true)
        // The error page itself is about:blank; Reload, Copy Page Address and Open in Default Browser use the failed address.
        XCTAssertEqual(offline["reloadLoads"] as? String, "https://x.com/notifications")
        XCTAssertEqual(offline["pageAddress"] as? String, "https://x.com/notifications")

        let firstLoad = try errorDecision(["NSURLErrorDomain", "-1004"])
        XCTAssertEqual(firstLoad["reloadLoads"] as? String, "https://x.com/home")

        let ignored = try errorDecision(["WebKitErrorDomain", "102"])
        XCTAssertNil(ignored["reloadLoads"])
    }

    func testCheckErrorUsage() throws {
        let missingCode = try run(["--check-error", "NSURLErrorDomain"], environment: ["SHAWN_WEBAPP_URL": "https://x.com"])
        XCTAssertEqual(missingCode.status, 64)
        XCTAssertTrue(missingCode.stderr.contains("--check-error needs an error domain and a code"), missingCode.stderr)
        let badCode = try run(["--check-error", "NSURLErrorDomain", "lots"], environment: ["SHAWN_WEBAPP_URL": "https://x.com"])
        XCTAssertEqual(badCode.status, 64)
        XCTAssertTrue(badCode.stderr.contains("'lots' is not an error code"), badCode.stderr)
        XCTAssertTrue(try run(["--help"]).stdout.contains("--check-error"))
    }

    func testSiteDerivation() throws {
        let result = try decisions([
            "https://my.carbonapp.co/", "https://news.bbc.co.uk/", "https://alice.github.io/", "https://192.168.1.10:8080/",
            "https://docs.example.com.au/", "https://LOCALHOST./",
        ])
        XCTAssertEqual(result["https://my.carbonapp.co/"]?["site"] as? String, "carbonapp.co")
        XCTAssertEqual(result["https://news.bbc.co.uk/"]?["site"] as? String, "bbc.co.uk")
        XCTAssertEqual(result["https://alice.github.io/"]?["site"] as? String, "alice.github.io")
        XCTAssertEqual(result["https://192.168.1.10:8080/"]?["site"] as? String, "192.168.1.10")
        XCTAssertEqual(result["https://docs.example.com.au/"]?["site"] as? String, "example.com.au")
        XCTAssertEqual(result["https://LOCALHOST./"]?["site"] as? String, "localhost")
    }

    // MARK: A real generated app

    func testGeneratedAppVerifiesAndReadsItsOwnInfoPlist() async throws {
        let shell = try shellBinary()
        let sandbox = WebAppSandbox(items: """
          - webapp: Carbon Web
            url: https://my.carbonapp.co
            hosts: [auth0.com]
            width: 1300
            height: 850

        """, installShell: false)
        sandbox.environment.helpersDirectory = shell.deletingLastPathComponent()

        let summary = try await sandbox.install()
        XCTAssertEqual(summary.failures.map(\.message), [])
        let app = sandbox.app("Carbon Web")

        let verify = try runProcess("/usr/bin/codesign", ["--verify", "--strict", "--deep", "--verbose=2", app.path])
        XCTAssertEqual(verify.status, 0, verify.stderr)
        let details = try runProcess("/usr/bin/codesign", ["-dv", app.path])
        XCTAssertTrue(details.stderr.contains("Identifier=com.shawnschwartz.webapp.carbon-web"), details.stderr)
        XCTAssertTrue(details.stderr.contains("Signature=adhoc"), details.stderr)

        // The bundle's own executable, run with --print-config, reports what the installer wrote (no window opens).
        let printed = try runProcess(app.appendingPathComponent("Contents/MacOS/Carbon Web").path, ["--print-config"])
        let config = try XCTUnwrap(try json(printed) as? [String: Any])
        XCTAssertEqual(config["source"] as? String, "bundle")
        XCTAssertEqual(config["url"] as? String, "https://my.carbonapp.co")
        XCTAssertEqual(config["name"] as? String, "Carbon Web")
        XCTAssertEqual(config["hosts"] as? [String], ["auth0.com"])
        XCTAssertEqual(config["width"] as? Int, 1300)
        XCTAssertEqual(config["height"] as? Int, 850)
        XCTAssertEqual(config["bundleIdentifier"] as? String, "com.shawnschwartz.webapp.carbon-web")
        XCTAssertEqual(config["frameAutosaveName"] as? String, "com.shawnschwartz.webapp.carbon-web")

        let check = try await sandbox.check()
        XCTAssertEqual(check, .satisfied("up to date"))
    }
}
