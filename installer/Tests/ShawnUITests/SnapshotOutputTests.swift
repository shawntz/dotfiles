import ShawnCore
import XCTest
@testable import ShawnUI

/// What items print in the snapshots' LOG panel, by kind, in the engine's own words.
@MainActor
final class SnapshotOutputTests: XCTestCase {
    /// Real kind names played by FakeAction, so the output can be checked without the real actions.
    private func model(_ items: String, dryRun: Bool = false, meta: String = defaultMeta) throws -> InstallerModel {
        var registry = ActionRegistry()
        for kind in ["brew", "cask", "manual", "copy", "github", "skill", "script", "defaults", "mas", "xcode", "open", "mkdir", "clone", "ok"] {
            registry.register(ActionDescriptor(kind: kind, summary: kind, example: "- \(kind): x") { parser in
                for key in ["to", "run", "set", "source", "protocol", "detail", "url", "check", "creates"] { _ = parser.options.value(key) }
                return FakeAction(title: parser.primaryString())
            })
        }
        let (model, _) = try makeModel(steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n" + items], registry: registry,
                                       meta: meta, mode: .snapshot, dryRun: dryRun)
        model.apply(.runStarted(totalItems: model.enabledItemCount))
        return model
    }

    private func texts(_ events: [InstallEvent]) -> [String] {
        events.compactMap { event in
            if case .log(let line) = event { return line.text }
            return nil
        }
    }

    private func lines(of index: Int, in model: InstallerModel) -> [String] {
        texts(SnapshotOutput.start(model.steps[0].items[index], model: model))
    }

    func testTheChecklistIsTheRemindersTheRunDidNotFindDone() throws {
        let model = try model("""
              - cask: spotify
              - manual: Check your email
                detail: "({{email}}) must be a verified address"
                url: https://github.com/settings/emails
              - manual: Log out and back in
              - manual: Sign in to Dropbox
                detail: Dropbox is open in the menu bar.
              - brew: bat
            """)
        SnapshotScript.playFinished(model, failures: 0, stopped: false)
        let items = model.steps[0].items
        // The sample finds every fourth item already done, here the third, and that one adds nothing.
        XCTAssertEqual(model.status(of: items[2]), .alreadyDone("already shown"))
        XCTAssertEqual(model.status(of: items[1]), .needsAttention("Check your email"), "as the engine ends a reminder")
        XCTAssertEqual(model.status(of: items[3]), .needsAttention("Sign in to Dropbox"))
        let checklist = try XCTUnwrap(model.summary?.followUps)
        XCTAssertEqual(checklist.map(\.title), ["Check your email", "Sign in to Dropbox"], "the reminders that ran, in order")
        XCTAssertEqual(model.summary?.needsAttention, 2, "the count and the checklist agree")
        XCTAssertNil(checklist[0].detail, "text that still names a {{variable}} is left out")
        XCTAssertEqual(checklist[0].url, URL(string: "https://github.com/settings/emails"))
        XCTAssertEqual(checklist[1].detail, "Dropbox is open in the menu bar.")
        XCTAssertEqual(model.followUps, checklist)
    }

    func testAConfigWithNoRemindersEndsWithAnEmptyChecklist() throws {
        let model = try model("""
              - brew: bat
              - cask: spotify
            """)
        SnapshotScript.playFinished(model, failures: 0, stopped: false)
        XCTAssertEqual(model.summary?.followUps, [])
        XCTAssertEqual(model.summary?.needsAttention, 0)
    }

    func testAnItemFoundDoneSaysWhyInItsActionsWords() throws {
        let model = try model("""
              - brew: bat
              - copy: git/ignore
                to: ~/.config/git/ignore
              - defaults: com.apple.dock
                set:
                  autohide: true
                  tilesize: 48
              - manual: Log out and back in
              - manual: Give Karabiner Accessibility access
                check: "true"
              - mkdir: ~/Developer
              - script: Install the thing
                run: make install
                creates: ~/.local/bin/thing
            """)
        let reasons = model.steps[0].items.map { SnapshotOutput.alreadyDoneReason(for: $0) }
        XCTAssertEqual(reasons, ["installed", "up to date", "all 2 set", "already shown", "already done", "exists", nil])
    }

    func testItemsTheEngineRunsEveryTimeAreNeverFoundDone() throws {
        let model = try model("""
              - open: Dropbox
              - script: Say hello
                run: echo hello
              - script: Make the folder
                run: mkdir -p ~/x
                creates: ~/x
              - brew: bat
            """)
        let items = model.steps[0].items
        // Index 2 is one the sample would find done.
        XCTAssertFalse(SnapshotOutput.endsAlreadyDone(items[0], index: 2), "open: runs every time")
        XCTAssertFalse(SnapshotOutput.endsAlreadyDone(items[1], index: 2), "so does a script with no check: or creates:")
        XCTAssertTrue(SnapshotOutput.endsAlreadyDone(items[2], index: 2), "a script with creates: can be done")
        XCTAssertTrue(SnapshotOutput.endsAlreadyDone(items[3], index: 2))
    }

    func testEachKindPrintsWhatTheEngineDoes() throws {
        let model = try model("""
              - brew: bat
              - cask: nikitabobko/tap/aerospace
              - manual: Log out and back in
              - copy: git/ignore
                to: ~/.config/git/ignore
              - github: github.com
                protocol: ssh
              - skill: unslop
              - script: Retire the old vercel formula
                run: |
                  brew uninstall --formula --ignore-dependencies vercel
                  brew reinstall --cask vercel
              - defaults: org.hammerspoon.Hammerspoon
                set:
                  MJShowDockIconKey: false
              - ok: something new
            """)
        XCTAssertEqual(lines(of: 0, in: model), ["$ brew install --formula bat", "==> Fetching downloads for: bat"])
        XCTAssertEqual(lines(of: 1, in: model), ["$ brew install --cask nikitabobko/tap/aerospace", "==> Fetching downloads for: aerospace"])
        XCTAssertEqual(lines(of: 2, in: model), ["added to your checklist: Log out and back in"])
        XCTAssertEqual(lines(of: 3, in: model), ["write ~/.config/git/ignore"])
        XCTAssertEqual(lines(of: 4, in: model),
                       ["$ gh auth login --hostname github.com --web --git-protocol ssh --skip-ssh-key --clipboard=false"])
        XCTAssertEqual(lines(of: 5, in: model), [
            "mkdir ~/.agents/skills/unslop",
            "write ~/.agents/skills/unslop/SKILL.md",
            "link ~/.claude/skills/unslop → ../../.agents/skills/unslop",
            "link ~/.grok/skills/unslop → ../../.agents/skills/unslop",
        ])
        XCTAssertEqual(lines(of: 6, in: model), ["$ brew uninstall --formula --ignore-dependencies vercel …"])
        XCTAssertEqual(lines(of: 7, in: model), [
            "org.hammerspoon.Hammerspoon MJShowDockIconKey: unset → false",
            "$ defaults write org.hammerspoon.Hammerspoon MJShowDockIconKey -bool false",
        ])
        XCTAssertEqual(lines(of: 8, in: model), ["ok: something new"], "a kind it does not know gets a neutral line")
    }

    func testOnlyDownloadsShowABar() throws {
        let model = try model("""
              - brew: bat
              - manual: Log out and back in
              - xcode: finish
            """)
        let brew = model.steps[0].items[0], manual = model.steps[0].items[1], finish = model.steps[0].items[2]
        let running = SnapshotOutput.inProgress(brew, progress: 0.476, model: model)
        guard case .log(let bar)? = running.last else { return XCTFail("no bar") }
        XCTAssertEqual(bar.text, String(repeating: "#", count: 19) + String(repeating: " ", count: 21) + "  47.6%")
        XCTAssertTrue(bar.isProgress)
        guard case .log(let full)? = SnapshotOutput.end(brew, model: model).last else { return XCTFail("no last bar") }
        XCTAssertEqual(full.text, String(repeating: "#", count: 40) + "  100.0%")
        XCTAssertFalse(full.isProgress, "the finished bar stays")

        XCTAssertEqual(texts(SnapshotOutput.inProgress(manual, progress: 0.5, model: model)), ["added to your checklist: Log out and back in"])
        XCTAssertTrue(SnapshotOutput.end(manual, model: model).isEmpty)
        XCTAssertFalse(SnapshotOutput.downloads(finish), "xcode: finish sets up what xcode: download fetched")
        XCTAssertEqual(texts(SnapshotOutput.start(finish, model: model)), ["$ sudo xcodebuild -license accept", "$ sudo xcodebuild -runFirstLaunch"])
    }

    func testADryRunMarksCommandsAndFileChangesAndDownloadsNothing() throws {
        let model = try model("""
              - brew: bat
              - copy: zsh/zshrc
                to: ~/.zshrc
              - manual: Log out and back in
            """, dryRun: true)
        XCTAssertTrue(model.runIsDryRun)
        XCTAssertEqual(texts(SnapshotOutput.inProgress(model.steps[0].items[0], progress: 0.5, model: model)),
                       ["[dry-run] $ brew install --formula bat"])
        XCTAssertTrue(SnapshotOutput.end(model.steps[0].items[0], model: model).isEmpty)
        XCTAssertEqual(lines(of: 1, in: model), ["[dry-run] write ~/.zshrc"])
        XCTAssertEqual(lines(of: 2, in: model), ["added to your checklist: Log out and back in"], "as the engine says it in a dry run")
    }

    /// Like the clone item, the fake output passes --depth=1 for the repository that `remote:` names and for no other.
    func testTheFakeOutputClonesOnlyTheNewestCommitOfTheConfigsOwnRepository() throws {
        let model = try model("""
              - clone: Tester/dotfiles
                to: ~/Developer/dotfiles
              - clone: tester/other
                to: ~/Developer/other
            """, meta: defaultMeta + "remote:\n  repo: tester/dotfiles\n  branch: main\n")
        let items = model.steps[0].items
        XCTAssertEqual(SnapshotOutput.command(items[0], model: model),
                       "git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=120 clone --progress --depth=1 -- https://github.com/Tester/dotfiles.git ~/Developer/dotfiles")
        XCTAssertEqual(SnapshotOutput.command(items[1], model: model),
                       "git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=120 clone --progress -- https://github.com/tester/other.git ~/Developer/other")
        XCTAssertEqual(lines(of: 0, in: model).last, "Cloning into '~/Developer/dotfiles'...")
    }

    func testAFailureNamesTheCommandThatFailed() throws {
        let model = try model("  - cask: spotify\n  - manual: Sign in\n")
        XCTAssertEqual(SnapshotOutput.command(model.steps[0].items[0], model: model), "brew install --cask spotify")
        XCTAssertEqual(SnapshotOutput.command(model.steps[0].items[1], model: model), "Sign in", "no command: its title")
    }

    func testKindsThatWaitForYouAreNeverAlreadyDone() throws {
        let model = try model("  - brew: bat\n  - github: github.com\n  - mas: 937984704\n")
        let items = model.steps[0].items
        XCTAssertTrue(SnapshotOutput.endsAlreadyDone(items[0], index: 2))
        XCTAssertFalse(SnapshotOutput.endsAlreadyDone(items[0], index: 3))
        XCTAssertFalse(SnapshotOutput.endsAlreadyDone(items[1], index: 2))
        XCTAssertFalse(SnapshotOutput.endsAlreadyDone(items[2], index: 6))
    }

    func testNoScreenPrintsTheOldPlaceholderOutput() throws {
        for state in SnapshotState.allCases {
            let model = try SnapshotCommand.makeSimulationModel(options: LaunchOptions(), scratch: makeTempDirectory().url, mode: .snapshot,
                                                                configureNow: state != .loading)
            SnapshotScript.apply(state, to: model)
            let text = model.log.entries.map(\.text)
            XCTAssertFalse(text.contains { $0.hasPrefix("$ install ") || $0.hasPrefix("[dry-run] $ install ") }, state.rawValue)
        }
    }
}
