import ShawnCore
import XCTest
@testable import ShawnUI

/// What items print in the snapshots' LOG panel, by kind, in the engine's own words.
@MainActor
final class SnapshotOutputTests: XCTestCase {
    /// Real kind names played by FakeAction, so the output can be checked without the real actions.
    private func model(_ items: String, dryRun: Bool = false) throws -> InstallerModel {
        var registry = ActionRegistry()
        for kind in ["brew", "cask", "manual", "copy", "github", "skill", "script", "defaults", "mas", "xcode", "ok"] {
            registry.register(ActionDescriptor(kind: kind, summary: kind, example: "- \(kind): x") { parser in
                for key in ["to", "run", "set", "source", "protocol"] { _ = parser.options.value(key) }
                return FakeAction(title: parser.primaryString())
            })
        }
        let (model, _) = try makeModel(steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n" + items], registry: registry,
                                       mode: .snapshot, dryRun: dryRun)
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
