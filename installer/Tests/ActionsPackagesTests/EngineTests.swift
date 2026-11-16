import XCTest
@testable import ActionsPackages
import ShawnCore

/// The kinds driven by the real `InstallEngine`, as the app and the CLI will drive them.
final class EngineTests: XCTestCase {
    private func loadPlan(_ sandbox: Sandbox, step: String) throws -> InstallPlan {
        sandbox.directory.write("config/installer.yaml", "name: Test Dotfiles\nvars:\n  flavor: grape\n")
        sandbox.directory.write("config/steps/01-test.yaml", step)
        let config = try ConfigLoader.load(from: sandbox.root.appendingPathComponent("config")).config
        let plan = InstallPlan.build(config: config, registry: sandbox.registry(), environment: sandbox.environment)
        XCTAssertEqual(plan.errors, [])
        return plan
    }

    func testBootstrapStepRunsEndToEndAndIsANoOpTheSecondTime() async throws {
        let sandbox = Sandbox("engine")
        sandbox.installAskpassSudo()
        sandbox.installSoftwareUpdate()
        sandbox.installHomebrewInstallers()
        // mas arrives with `brew: mas`, like on a fresh Mac.
        sandbox.installFakeMas(delay: 0.5)
        sandbox.directory.mkdir("homebrew/pending")
        try FileManager.default.moveItem(at: sandbox.brewBin.appendingPathComponent("mas"), to: sandbox.brewPrefix.appendingPathComponent("pending/mas"))
        sandbox.stageXcode()
        sandbox.directory.write("homebrew/cask-apps/dropbox", "Dropbox.app")
        // Like a cask whose installer is a .pkg: Homebrew calls sudo itself, which only works through the password helper.
        sandbox.directory.write("homebrew/cask-needs-sudo/dropbox", "")
        sandbox.shim("pkg-installer")
        sandbox.shim("open")

        let plan = try loadPlan(sandbox, step: """
        id: bootstrap
        title: Bootstrap
        items:
          - xcode-clt: install
          - homebrew: install
          - brew: mas
          - xcode: download
          - cask: dropbox
            app: Dropbox.app
            launch: true
          - xcode: finish
            timeout_minutes: 1
        """)
        let events = Recorder<InstallEvent>()
        let first = await InstallEngine(plan: plan, environment: sandbox.environment, interaction: NonInteractive(password: "open sesame"))
            .run(selection: .defaults(for: plan)) { events.add($0) }
        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(first.done, 6)
        let statuses = events.all.compactMap { event -> String? in
            if case .itemStatus(let id, let status) = event, status.isFinished { return "\(id) \(status)" }
            return nil
        }
        XCTAssertEqual(statuses, [
            "bootstrap/0 done(Optional(\"installed Command Line Tools for Xcode 27.2-27.2\"))",
            "bootstrap/1 done(Optional(\"installed\"))",
            "bootstrap/2 done(Optional(\"installed\"))",
            "bootstrap/3 done(Optional(\"downloading in the background\"))",
            "bootstrap/4 done(Optional(\"installed and opened\"))",
            "bootstrap/5 done(Optional(\"Xcode 27.2 is ready\"))",
        ])
        XCTAssertEqual(sandbox.calls("root mas"), ["root mas install 497799835"])
        XCTAssertTrue(sandbox.calls("root xcodebuild").contains("root xcodebuild -license accept"))
        XCTAssertEqual(sandbox.calls("root pkg-installer"), ["root pkg-installer dropbox"])
        XCTAssertEqual(sandbox.brewAskpass.filter { $0.contains("askpass=set") }, ["install --cask dropbox | askpass=set"],
                       "only the cask install may use the password helper")

        let second = await InstallEngine(plan: plan, environment: sandbox.environment, interaction: NonInteractive(password: "open sesame"))
            .run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(second.failures, [])
        XCTAssertEqual(second.alreadyDone, 6)
    }

    func testASandboxRunWithTheRealSystemToolsRefusesSystemWideChanges() async throws {
        let sandbox = Sandbox("engine")
        // Flagged as the real machine, but every tool points nowhere: if the guard failed, nothing could run anyway.
        var system = MacSystem()
        for keyPath: WritableKeyPath<MacSystem, String> in [\.softwareupdate, \.xcodeSelect, \.pkgutil, \.spctl, \.installer, \.codesign,
                                                            \.curl, \.hdiutil, \.ditto, \.open, \.pgrep, \.touch, \.rm, \.bash, \.zsh, \.sh] {
            system[keyPath: keyPath] = "/nonexistent/tool"
        }
        system.commandLineTools = sandbox.root.appendingPathComponent("system/clt")
        system.rosettaRuntime = sandbox.root.appendingPathComponent("system/rosetta")
        XCTAssertTrue(system.isRealMachine)
        sandbox.system = system
        sandbox.environment.sudoPath = "/nonexistent/sudo"
        // An npm outside the sandbox's Homebrew and home (the helpers directory is on the search path).
        sandbox.environment.helpersDirectory = sandbox.root.appendingPathComponent("outside")
        sandbox.shim("npm", at: sandbox.root.appendingPathComponent("outside"), "exit 1")
        sandbox.installFakeMas()
        let package = sandbox.directory.write("served/Thing.pkg", "bytes")

        for yaml in ["xcode-clt: install", "homebrew: install", "rosetta: install", "xcode: download", "xcode: finish",
                     "mas: 937984704\nname: Amphetamine", "download: '\(package.absoluteString)'\napp: Thing.app", "npm: left-pad"] {
            let result = try await sandbox.run(yaml)
            guard case .skipped(let reason)? = result.outcome else { return XCTFail("\(yaml): \(String(describing: result.outcome))") }
            XCTAssertTrue(reason.hasPrefix("sandbox run:"), reason)
        }
        XCTAssertEqual(sandbox.calls("npm"), ["npm ls -g --depth=0 left-pad"], "only the read-only check ran")
        XCTAssertTrue(sandbox.calls("mas").isEmpty)
        XCTAssertTrue(sandbox.interaction.questions.isEmpty)
    }

    func testADryRunOfEveryKindSucceedsAndChangesNothing() async throws {
        let sandbox = Sandbox("engine")
        let plan = try loadPlan(sandbox, step: """
        id: everything
        title: Everything
        items:
          - xcode-clt: install
          - homebrew: install
          - rosetta: install
          - xcode: download
          - tap: nikitabobko/tap
            trusted: true
          - brew: eza
          - cask: nikitabobko/tap/aerospace
          - mas: 937984704
            name: Amphetamine
          - npm: ghostty-config-cli
          - download: https://dl.example.com/Thing.zip
            app: Thing.app
          - download: https://dl.example.com/Thing.pkg
          - script: Hello
            run: echo hi > ~/hello
            creates: ~/hello
          - xcode: finish
            platforms: [iOS]
        """)
        let before = sandbox.snapshot()
        let engine = InstallEngine(plan: plan, environment: sandbox.environment, options: RunOptions(dryRun: true, assumeFresh: true),
                                   interaction: ScriptedInteraction())
        let summary = await engine.run(selection: .defaults(for: plan)) { _ in }
        XCTAssertEqual(summary.failures, [])
        XCTAssertEqual(summary.done, 13)
        XCTAssertEqual(sandbox.snapshot(), before)
        XCTAssertEqual(sandbox.calls, [], "nothing ran, not even sudo")
    }
}
