import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

/// Runs a whole step of file kinds through the real engine, twice, in a sandbox.
final class EngineIntegrationTests: XCTestCase {
    let items = """
    - mkdir: ~/Developer
    - copy: zsh/zshrc
      to: ~/.zshrc
      template: true
    - symlink: ~/.config/zsh
      to: ../.zshrc
    - json-merge: ~/.claude/settings.json
      values:
        model: opus
        permissions: {allow: [Read]}
      arrays: union
    - defaults: com.apple.finder
      set: {ShowPathbar: true, FXPreferredViewStyle: Nlsv}
      restart: [Finder]
    - dock:
        apps: [Google Chrome, Herdr, Missing App]
        folders: [{path: ~/Developer, view: grid}]
        settings: {autohide: true, tilesize: 128}
    - login-item: Herdr
      bundle_id: dev.herdr.app
    - shawn-cli: install
    """

    func makeHarness() -> Harness {
        let harness = Harness()
        harness.payload("zsh/zshrc", "export EDITOR={{editor}}\n")
        harness.fakeApp("Applications/Google Chrome.app")
        harness.fakeApp("Applications/Herdr.app")
        harness.directory.write("helpers/shawn", "#!/bin/sh\n[ \"$1\" = completions ] && echo '#compdef shawn'\nexit 0\n", permissions: 0o755)
        harness.environment.helpersDirectory = harness.url("helpers")
        return harness
    }

    func run(_ harness: Harness, _ plan: InstallPlan, dryRun: Bool = false) async -> InstallSummary {
        let engine = InstallEngine(plan: plan, environment: harness.environment, options: RunOptions(dryRun: dryRun))
        let events = harness.events
        return await engine.run(selection: .defaults(for: plan)) { events.add($0) }
    }

    func testFirstRunDoesEverythingAndTheSecondFindsItAllDone() async throws {
        let harness = makeHarness()
        let plan = try harness.plan(items)
        XCTAssertEqual(plan.errors.map(\.description), [])

        let dry = await run(harness, plan, dryRun: true)
        XCTAssertEqual(dry.failures.map(\.message), [])
        XCTAssertEqual(dry.done, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url("home/.zshrc").path), "the dry run wrote nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.url("home/Developer").path))

        let first = await run(harness, plan)
        XCTAssertEqual(first.failures.map(\.message), [])
        XCTAssertEqual(first.done, 8)
        XCTAssertEqual(harness.directory.read("home/.zshrc"), "export EDITOR=nvim\n")
        XCTAssertEqual(harness.directory.read("home/.config/zsh"), "export EDITOR=nvim\n")
        XCTAssertTrue(harness.directory.exists("home/.local/bin/shawn"))

        let second = await run(harness, plan)
        XCTAssertEqual(second.failures.map(\.message), [])
        XCTAssertEqual(second.alreadyDone, 8, "every item is idempotent")
        XCTAssertEqual(second.done, 0)
    }

    /// A Mac that is all set up has nothing left to do on a second run: reminders were handed out the first time.
    /// Every `shawn` command (and every launch of the app) is a run of its own, with its own run ID.
    func testRemindersAreHandedOutOnceAndTheNextRunIsClean() async throws {
        let harness = makeHarness()
        harness.environment.runID = "first"
        let plan = try harness.plan("""
        - mkdir: ~/Developer
        - manual: Log out and back in
          detail: Key repeat and trackpad settings apply after you log out.
        - manual: Sign in to ChatGPT
        """)
        XCTAssertEqual(plan.errors.map(\.description), [])

        let dry = await run(harness, plan, dryRun: true)
        XCTAssertEqual(dry.needsAttention, 2)
        let first = await run(harness, plan)
        XCTAssertEqual(first.needsAttention, 2)
        XCTAssertEqual(first.followUps.map(\.title), ["Log out and back in", "Sign in to ChatGPT"])

        harness.environment.runID = "second"
        let second = await run(harness, plan)
        XCTAssertEqual(second.alreadyDone, 3)
        XCTAssertEqual(second.needsAttention, 0)
        XCTAssertEqual(second.followUps, [])
    }

    /// The installer app keeps its environment, and so its run ID, for START, RETRY FAILED and RESUME, and its
    /// finished screen lists only the latest run's follow-ups. A retry must list the reminders the first pass
    /// handed out, or the checklist reads "Nothing left for you to do".
    func testARetryInTheSameAppSessionStillListsTheReminders() async throws {
        let harness = makeHarness()
        harness.directory.write("home/x", "a file where the folder should be\n")
        let plan = try harness.plan("""
        - manual: Log out and back in
        - mkdir: ~/x
        """)
        XCTAssertEqual(plan.errors.map(\.description), [])
        let first = await run(harness, plan)
        XCTAssertEqual(first.failures.count, 1)
        XCTAssertEqual(first.followUps.map(\.title), ["Log out and back in"])

        // The person fixes what failed and presses RETRY FAILED: a new engine, the same environment.
        try FileManager.default.removeItem(at: harness.url("home/x"))
        let retry = await run(harness, plan)
        XCTAssertEqual(retry.failures.map(\.message), [])
        XCTAssertEqual(retry.followUps.map(\.title), ["Log out and back in"])

        // Opening the app again (or `shawn sync`) is a new run: the reminder was shown, so it stays off the list.
        harness.environment.runID = "relaunched"
        let relaunched = await run(harness, plan)
        XCTAssertEqual(relaunched.followUps, [])
        XCTAssertEqual(relaunched.alreadyDone, 2)
    }
}
