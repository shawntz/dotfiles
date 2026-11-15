import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class OpenTests: XCTestCase {
    func testOpensAppsPathsAndURLsThroughTheShim() async throws {
        let harness = Harness()
        harness.shim("open")
        let app = try harness.item("- open: Hammerspoon")
        XCTAssertNeeded(await app.check(), "open has nothing to check")
        await XCTAssertOutcome(try await app.run(), .done("opened Hammerspoon"))

        let foreground = try harness.item("""
        - open: Karabiner-Elements
          background: false
          args: [--hidden, "{{full_name}}"]
        """)
        try await foreground.run()

        let url = try harness.item("- open: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        try await url.run()

        let path = try harness.item("- open: ~/Developer")
        try await path.run()

        XCTAssertEqual(harness.shimCalls("open"), [
            "[-g][-a][Hammerspoon]",
            "[-a][Karabiner-Elements][--args][--hidden][Shawn Tester]",
            "[-g][x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility]",
            "[-g][\(harness.home.path)/Developer]",
        ])
        XCTAssertTrue(harness.logText.contains("$ open -g -a Hammerspoon"), harness.logText)
    }

    func testASandboxWithoutAStandInNeverLaunchesRealApps() async throws {
        let harness = Harness()
        let item = try harness.item("- open: Hammerspoon")
        await XCTAssertOutcome(try await item.run(), .skipped("sandbox: apps are not opened"))
        XCTAssertTrue(harness.logText.contains("sandbox: not running open -g -a Hammerspoon"), harness.logText)
    }

    func testFailureSaysWhatToCheck() async throws {
        let harness = Harness()
        harness.shim("open", body: "echo \"Unable to find application named 'Nope'\" >&2; exit 1")
        let item = try harness.item("- open: Nope")
        let error = await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertTrue(error?.message.contains("could not open Nope") == true, "\(String(describing: error))")
        XCTAssertTrue(error?.message.contains("Unable to find application named 'Nope'") == true, "\(String(describing: error))")
        XCTAssertEqual(error?.hint, "check that Nope is installed")
    }

    func testDryRunOnlyEchoes() async throws {
        let harness = Harness()
        harness.shim("open")
        let item = try harness.item("- open: Hammerspoon")
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would open Hammerspoon"))
        XCTAssertEqual(harness.shimCalls("open"), [])
        XCTAssertTrue(harness.logText.contains("[dry-run] $ open -g -a Hammerspoon"), harness.logText)
    }
}

final class ManualTests: XCTestCase {
    func testAddsAFollowUpAndNeverFails() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - manual: Sign in to Dropbox, {{full_name}}
          detail: Open Dropbox from the menu bar and sign in.
          url: https://www.dropbox.com/login
        """)
        XCTAssertEqual(item.action.subtitle, "Open Dropbox from the menu bar and sign in.")
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .needsAttention("Sign in to Dropbox, Shawn Tester"))
        XCTAssertEqual(harness.followUps.count, 1)
        XCTAssertEqual(harness.followUps.first?.title, "Sign in to Dropbox, Shawn Tester")
        XCTAssertEqual(harness.followUps.first?.detail, "Open Dropbox from the menu bar and sign in.")
        XCTAssertEqual(harness.followUps.first?.url, URL(string: "https://www.dropbox.com/login"))
        XCTAssertEqual(harness.followUps.first?.stepID, "test")
    }

    func testCheckScriptDecidesWhetherItIsDone() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - manual: Allow Hammerspoon in Accessibility
          check: test -f "$HOME/granted"
        """)
        XCTAssertNeeded(await item.check())
        harness.directory.write("home/granted", "")
        XCTAssertSatisfied(await item.check())
        XCTAssertSatisfied(await item.check(dryRun: true), "the check is a read-only probe and runs in dry runs too")
    }

    func remindersFile(_ harness: Harness) -> URL {
        harness.home.appendingPathComponent(".shawn/state/reminders.json")
    }

    func reminderEntries(_ harness: Harness, step: String = "test") throws -> [JSONObject] {
        let record = try XCTUnwrap(try JSONParser.parse(XCTUnwrap(FileManager.default.contents(atPath: remindersFile(harness).path))).object)
        guard case .array(let entries)? = record[step] else { XCTFail("no list for step \(step) in \(record)"); return [] }
        return entries.compactMap(\.object)
    }

    /// A reminder with no `check:` is raised once on a Mac; later runs (`shawn sync`, the app opened again: a new
    /// run ID each) report it as already shown instead of putting the same to-do back on the checklist every time.
    func testAReminderWithoutACheckIsShownOncePerMac() async throws {
        let harness = Harness()
        harness.environment.runID = "first"
        let item = try harness.item("""
        - manual: Log out and back in
          detail: Key repeat takes effect after you log out.
          url: x-apple.systempreferences:com.apple.Keyboard-Settings.extension
        """)
        XCTAssertNeeded(await item.check())

        await XCTAssertOutcome(try await item.run(dryRun: true), .needsAttention("Log out and back in"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remindersFile(harness).path), "a dry run records nothing")
        XCTAssertNeeded(await item.check())

        await XCTAssertOutcome(try await item.run(), .needsAttention("Log out and back in"))
        XCTAssertEqual(harness.followUps.map(\.title), ["Log out and back in", "Log out and back in"])
        let entries = try reminderEntries(harness)
        XCTAssertEqual(entries.map(\.keys), [["title", "detail", "url", "shownAt", "run"]])
        XCTAssertEqual(entries.first?["title"], .string("Log out and back in"))
        XCTAssertEqual(entries.first?["detail"], .string("Key repeat takes effect after you log out."))
        XCTAssertEqual(entries.first?["url"], .string("x-apple.systempreferences:com.apple.Keyboard-Settings.extension"))
        XCTAssertEqual(entries.first?["run"], .string("first"))
        guard case .string(let shownAt)? = entries.first?["shownAt"] else { return XCTFail("\(entries)") }
        XCTAssertNotNil(ISO8601DateFormatter().date(from: shownAt))

        XCTAssertNeeded(await item.check(), "the run that showed it (the app's RETRY FAILED / RESUME) lists it again")

        harness.environment.runID = "later"
        let afterwards = await item.check()
        XCTAssertEqual(afterwards, .satisfied("already shown"))
        let inADryRun = await item.check(dryRun: true)
        XCTAssertEqual(inADryRun, .satisfied("already shown"))

        // Another reminder in the same step is still new.
        let other = try harness.item("- manual: Sign in to Grok")
        XCTAssertNeeded(await other.check())
        try await other.run()
        XCTAssertEqual(try reminderEntries(harness).map { $0["title"] }, [.string("Log out and back in"), .string("Sign in to Grok")])
        XCTAssertEqual(try reminderEntries(harness).map { $0["run"] }, [.string("first"), .string("later")])
    }

    /// Two reminders with one title in one step, told apart by their detail or link, are two to-dos: each is
    /// shown, and each is recorded on its own.
    func testRemindersWithTheSameTitleAreToldApartByDetailAndLink() async throws {
        let harness = Harness()
        harness.environment.runID = "first"
        let plan = try harness.plan("""
        - manual: Sign in
          detail: ChatGPT (chatgpt.com)
        - manual: Sign in
          detail: Grok (grok.com)
        - manual: Sign in
          detail: Grok (grok.com)
          url: https://grok.com
        """)
        XCTAssertEqual(plan.errors.map(\.description), [], "the config is accepted")
        let engine = InstallEngine(plan: plan, environment: harness.environment, options: RunOptions())
        let first = await engine.run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(first.followUps.map(\.detail), ["ChatGPT (chatgpt.com)", "Grok (grok.com)", "Grok (grok.com)"])
        XCTAssertEqual(first.followUps.map(\.url), [nil, nil, URL(string: "https://grok.com")])
        XCTAssertEqual(try reminderEntries(harness).count, 3)

        harness.environment.runID = "later"
        let next = await InstallEngine(plan: plan, environment: harness.environment, options: RunOptions())
            .run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(next.alreadyDone, 3)
        XCTAssertEqual(next.followUps, [])

        // A reminder added to the step later, with a title already shown, is still new.
        let added = try harness.item("""
        - manual: Sign in
          detail: Claude (claude.ai)
        """)
        XCTAssertNeeded(await added.check())
    }

    func testAReminderShownInAnotherStepIsStillNew() async throws {
        let harness = Harness()
        harness.directory.write("home/.shawn/state/reminders.json", """
        {
          "finish": [
            {"title": "Log out and back in", "shownAt": "2026-01-01T00:00:00Z", "run": "20260101-000000"}
          ]
        }

        """)
        let item = try harness.item("- manual: Log out and back in")
        XCTAssertNeeded(await item.check())
        try await item.run()
        let record = try XCTUnwrap(try JSONParser.parse(XCTUnwrap(FileManager.default.contents(atPath: remindersFile(harness).path))).object)
        XCTAssertEqual(record.keys, ["finish", "test"], "what was there is kept")
        XCTAssertEqual(try reminderEntries(harness, step: "finish").map { $0["run"] }, [.string("20260101-000000")])
        harness.environment.runID = "later"
        XCTAssertSatisfied(await item.check())
    }

    func testAReminderWithACheckIsDecidedByTheCheckAlone() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - manual: Allow Hammerspoon in Accessibility
          check: test -f "$HOME/granted"
        """)
        try await item.run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: remindersFile(harness).path))
        XCTAssertNeeded(await item.check(), "still not done, so it is still on the list")
    }

    func testAnUnreadableReminderFileIsReplacedAndBackedUp() async throws {
        let harness = Harness()
        harness.directory.write("home/.shawn/state/reminders.json", "{oops")
        let item = try harness.item("- manual: Log out and back in")
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .needsAttention("Log out and back in"))
        XCTAssertTrue(harness.logs.contains { $0.style == .warning && $0.text.contains("reminders.json") }, harness.logText)
        XCTAssertEqual(try String(contentsOf: harness.environment.backupDirectory.appendingPathComponent(".shawn/state/reminders.json"), encoding: .utf8), "{oops")
        harness.environment.runID = "later"
        XCTAssertSatisfied(await item.check())
    }

    func testOnlyKindsThatCanBeVerifiedAreCheckable() throws {
        let harness = Harness()
        XCTAssertFalse(try harness.item("- open: Hammerspoon").action.isCheckable, "opening an app is never 'already done'")
        XCTAssertFalse(try harness.item("- manual: Sign in to Grok").action.isCheckable)
        XCTAssertTrue(try harness.item("""
        - manual: Allow Hammerspoon
          check: "true"
        """).action.isCheckable)
        XCTAssertTrue(try harness.item("- login-item: Herdr").action.isCheckable)
    }

    func testParseErrors() throws {
        let harness = Harness()
        let url = try harness.problems("""
        - manual: Do it
          url: not a url
        """)
        XCTAssertTrue(url.contains { $0.contains("'url' must be a full URL") }, "\(url)")
        let empty = try harness.problems("- manual:")
        XCTAssertTrue(empty.contains { $0.contains("'manual' needs a value") }, "\(empty)")
    }
}

final class LoginItemTests: XCTestCase {
    func agentURL(_ harness: Harness, _ slug: String) -> URL {
        harness.home.appendingPathComponent("Library/LaunchAgents/com.shawnschwartz.dotfiles.open.\(slug).plist")
    }

    func testWritesALaunchAgentThatOpensTheAppAtLogin() async throws {
        let harness = Harness()
        harness.shim("open")
        let item = try harness.item("""
        - login-item: Herdr
          bundle_id: dev.herdr.app
        """)
        XCTAssertEqual(item.action.title, "Herdr at login")
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("Herdr will open at login (from the next login)"))
        let agent = try readPlist(agentURL(harness, "herdr"))
        XCTAssertEqual(agent, [
            "Label": .string("com.shawnschwartz.dotfiles.open.herdr"),
            "ProgramArguments": .array(["/usr/bin/open", "-g", "-b", "dev.herdr.app"].map(PlistValue.string)),
            "RunAtLoad": .bool(true),
        ])
        XCTAssertEqual(harness.permissions(agentURL(harness, "herdr")), 0o644)
        XCTAssertEqual(harness.shimCalls("open"), [], "the app is not launched now")
        XCTAssertSatisfied(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("Herdr already opens at login"))
    }

    func testWithoutABundleIDTheAppIsOpenedByNameOrPath() async throws {
        let harness = Harness()
        let byName = try harness.item("- login-item: Google Chrome")
        try await byName.run()
        XCTAssertEqual(try readPlist(agentURL(harness, "google-chrome"))["ProgramArguments"],
                       .array(["/usr/bin/open", "-g", "-a", "Google Chrome"].map(PlistValue.string)))

        let byPath = try harness.item("- login-item: \"{{applications}}/Granola.app\"")
        try await byPath.run()
        XCTAssertEqual(try readPlist(agentURL(harness, "granola"))["ProgramArguments"],
                       .array(["/usr/bin/open", "-g", "-a", harness.environment.applicationsDirectory.appendingPathComponent("Granola.app").path].map(PlistValue.string)))
    }

    func testAChangedAgentIsRewritten() async throws {
        let harness = Harness()
        let item = try harness.item("- login-item: Herdr")
        try await item.run()
        try writePlist(["Label": .string("com.shawnschwartz.dotfiles.open.herdr"), "RunAtLoad": .bool(false)], to: agentURL(harness, "herdr"))
        XCTAssertNeeded(await item.check())
        try await item.run()
        XCTAssertEqual(try readPlist(agentURL(harness, "herdr"))["RunAtLoad"], .bool(true))
    }

    func testDryRunAndParseErrors() async throws {
        let harness = Harness()
        let item = try harness.item("- login-item: Herdr")
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would open Herdr at login"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL(harness, "herdr").path))

        let badID = try harness.problems("""
        - login-item: Herdr
          bundle_id: "dev herdr"
        """)
        XCTAssertTrue(badID.contains { $0.contains("'bundle_id' must look like com.example.App") }, "\(badID)")
        let noName = try harness.problems("- login-item: \"!!!\"")
        XCTAssertTrue(noName.contains { $0.contains("needs an app name with at least one letter or digit") }, "\(noName)")
    }
}
