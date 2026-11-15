import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

final class AddAndPRTests: XCTestCase {
    private let apps = "id: apps\ntitle: Apps\nitems:\n  # browsers\n  - cask: ghostty\n    app: Ghostty.app\n\n  # the App Store\n  - mas: 937984704\n    name: Amphetamine\n"
    private let addCLI = "add:\n  cask: steps/04-apps.yaml\n  mas: steps/04-apps.yaml\n  tap: steps/04-apps.yaml\n  boom: steps/04-apps.yaml\ncommands: {}\n"

    private struct Setup {
        let harness: Harness
        let checkout: URL
        let git: FakeGit
        let log: FakeAction.Log
        var appsFile: URL { checkout.appendingPathComponent("installer/config/steps/04-apps.yaml") }
        var apps: String { (try? String(contentsOf: appsFile, encoding: .utf8)) ?? "" }
    }

    /// A checkout (fake .git) with a config, the settings file pointing at it, fake git and a gh shim.
    private func makeSetup(stagedFiles: String = "", fileChanges: String = "", appsText: String? = nil, extraSteps: [String: String] = [:],
                           cli: String? = nil) -> Setup {
        let sandbox = Sandbox()
        let checkout = sandbox.directory.url.appendingPathComponent("dotfiles")
        makeConfig(in: sandbox.directory, at: "dotfiles/installer/config", steps: ["04-apps.yaml": appsText ?? apps].merging(extraSteps) { $1 }, cli: cli ?? addCLI)
        try! FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        sandbox.directory.write("home/.config/shawn/config.yaml", "dotfiles_repo: \(checkout.path)\nconfig_path: installer/config\n")
        sandbox.shim("gh", "echo should not run for real >&2; exit 1")
        let git = FakeGit()
        // GitRepo reads both with -z: every name ends with a NUL.
        git.answer(["diff", "--cached", "--name-only"], stdout: stagedFiles.replacingOccurrences(of: "\n", with: "\0"))
        git.answer(["status", "--porcelain"], stdout: fileChanges.replacingOccurrences(of: "\n", with: "\0"))
        git.answer(["symbolic-ref"], stdout: "master")
        git.answer(["rev-parse", "--verify", "-q"], exit: 1)
        let log = FakeAction.Log()
        let harness = Harness(sandbox: sandbox, registry: FakeKinds.registry(log: log)) { $0.git = git }
        harness.launcher.respond("pr create", stdout: "Creating pull request…\nhttps://github.com/tester/dotfiles/pull/7\n")
        return Setup(harness: harness, checkout: checkout, git: git, log: log)
    }

    func testAddInstallsInsertsCommitsPushesAndOpensAPullRequest() async throws {
        let setup = makeSetup()
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--app", "Raycast.app", "--pr"])
        XCTAssertEqual(code, 0, setup.harness.err.plain)
        XCTAssertEqual(setup.log.all, ["install:cask:raycast:dryRun=false"])
        XCTAssertTrue(setup.apps.contains("  - cask: ghostty\n    app: Ghostty.app\n  - cask: raycast\n    app: Raycast.app\n\n  # the App Store"), setup.apps)

        let file = "installer/config/steps/04-apps.yaml"
        let lines = setup.git.commandLines
        let sequence = [
            "switch -c shawn/add-cask-raycast",
            "add -- \(file)",
            "commit -q -m Add cask raycast -- \(file)",
            "push -q -u origin shawn/add-cask-raycast",
            "switch -q master",
        ]
        var position = lines.startIndex
        for expected in sequence {
            guard let found = lines[position...].firstIndex(of: expected) else { return XCTFail("missing or out of order: \(expected)\n\(lines.joined(separator: "\n"))") }
            position = found + 1
        }
        let gh = try XCTUnwrap(setup.harness.launcher.requests.first { $0.arguments.first == "pr" })
        XCTAssertEqual(Array(gh.arguments.prefix(4)), ["pr", "create", "--title", "Add cask raycast"])
        XCTAssertEqual(Array(gh.arguments.suffix(4)), ["--base", "master", "--head", "shawn/add-cask-raycast"])
        XCTAssertEqual(gh.currentDirectory?.path, setup.checkout.path)
        let out = setup.harness.out.plain
        for step in ["added - cask: raycast, app: Raycast.app to steps/04-apps.yaml:7", "created branch shawn/add-cask-raycast", "committed: Add cask raycast",
                     "pushed shawn/add-cask-raycast to origin", "pull request: https://github.com/tester/dotfiles/pull/7", "back on master"] {
            XCTAssertTrue(out.contains(step), "\(step)\n\(out)")
        }
    }

    func testRefusesWhenOtherChangesAreStaged() async {
        let setup = makeSetup(stagedFiles: "README.md\n")
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--pr"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(setup.harness.err.plain.contains("the checkout has other staged changes (README.md)"), setup.harness.err.plain)
        XCTAssertEqual(setup.log.all, [], "nothing installed")
        XCTAssertEqual(setup.apps, apps, "nothing written")
        XCTAssertFalse(setup.git.commandLines.contains { $0.hasPrefix("switch") || $0.hasPrefix("commit") })
    }

    func testRefusesWhenTheStepFileAlreadyHasChanges() async {
        let setup = makeSetup(fileChanges: " M installer/config/steps/04-apps.yaml\n")
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--pr"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(setup.harness.err.plain.contains("already has uncommitted changes"), setup.harness.err.plain)
    }

    func testNoInstallOnlyAddsTheLine() async {
        let setup = makeSetup()
        let code = await setup.harness.run(["--no-update", "add", "mas", "1289583905", "--name", "Pixelmator Pro", "--no-install"])
        XCTAssertEqual(code, 0, setup.harness.err.plain)
        XCTAssertEqual(setup.log.all, [])
        XCTAssertTrue(setup.apps.hasSuffix("    name: Amphetamine\n  - mas: 1289583905\n    name: Pixelmator Pro\n"), setup.apps)
        XCTAssertTrue(setup.git.commandLines.isEmpty, "no --pr: git is not touched")
        XCTAssertTrue(setup.harness.out.plain.contains("Send it with 'shawn pr'"))
    }

    func testAlreadyInTheConfig() async {
        let setup = makeSetup()
        let code = await setup.harness.run(["--no-update", "add", "cask", "ghostty", "--no-install", "--pr"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(setup.harness.out.plain.contains("steps/04-apps.yaml:5 already has cask ghostty"), setup.harness.out.plain)
        XCTAssertFalse(setup.git.commandLines.contains { $0.hasPrefix("switch -c") })
    }

    func testValidatesKindAndName() async {
        let setup = makeSetup()
        let unknown = await setup.harness.run(["--no-update", "add", "caks", "raycast"])
        XCTAssertEqual(unknown, 64)
        XCTAssertTrue(setup.harness.err.plain.contains("can't add 'caks'. Did you mean 'cask'? (kinds you can add: cask, mas, tap, boom)"), setup.harness.err.plain)

        let badName = await setup.harness.run(["--no-update", "add", "tap", "not-a-tap"])
        XCTAssertEqual(badName, 64)
        XCTAssertTrue(setup.harness.err.plain.contains("a tap looks like user/repo"), setup.harness.err.plain)

        let missingName = await setup.harness.run(["--no-update", "add", "mas", "123"])
        XCTAssertEqual(missingName, 64)
        XCTAssertTrue(setup.harness.err.plain.contains("an App Store item needs name:"))

        let typo = await setup.harness.run(["--no-update", "add", "cask", "x", "--ap", "X.app"])
        XCTAssertEqual(typo, 64)
        XCTAssertTrue(setup.harness.err.plain.contains("unknown key 'ap'. Did you mean 'app'?"), setup.harness.err.plain)

        let missing = await setup.harness.run(["--no-update", "add", "cask"])
        XCTAssertEqual(missing, 64)
        XCTAssertEqual(setup.apps, apps)
    }

    func testFailedInstallIsNotAdded() async {
        let setup = makeSetup()
        let code = await setup.harness.run(["--no-update", "add", "boom", "thing"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(setup.harness.err.plain.contains("thing did not install, so it was not added to the config"))
        XCTAssertEqual(setup.apps, apps)
    }

    func testDryRunChangesNothing() async {
        let setup = makeSetup()
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--dry-run", "--pr"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(setup.log.all, ["install:cask:raycast:dryRun=true"])
        XCTAssertEqual(setup.apps, apps)
        XCTAssertTrue(setup.harness.out.plain.contains("[dry-run] would add - cask: raycast to steps/04-apps.yaml:7"), setup.harness.out.plain)
        XCTAssertFalse(setup.git.commandLines.contains { $0.hasPrefix("switch") || $0.hasPrefix("push") })
    }

    func testNeedsACheckout() async {
        let harness = Harness()
        let code = await harness.run(["--no-update", "add", "cask", "raycast"])
        XCTAssertEqual(code, 64)
        XCTAssertTrue(harness.err.plain.contains("needs a checkout"))
    }

    func testPRSendsEverythingUnderTheConfigDirectory() async throws {
        let setup = makeSetup(fileChanges: " M installer/config/steps/04-apps.yaml\n?? installer/config/steps/99-new.yaml\n")
        let code = await setup.harness.run(["--no-update", "pr"])
        XCTAssertEqual(code, 0, setup.harness.err.plain)
        let lines = setup.git.commandLines
        XCTAssertTrue(lines.contains { $0.hasPrefix("switch -c shawn/config-") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("add -- installer/config"))
        XCTAssertTrue(lines.contains("commit -q -m Update config: steps/04-apps.yaml, steps/99-new.yaml -- installer/config"), lines.joined(separator: "\n"))
        let gh = try XCTUnwrap(setup.harness.launcher.requests.first { $0.arguments.first == "pr" })
        XCTAssertTrue(gh.arguments.contains("Config changes from Sandbox Mac:\n\n- `steps/04-apps.yaml`\n- `steps/99-new.yaml`"))

        let custom = makeSetup(fileChanges: " M installer/config/cli.yaml\n")
        _ = await custom.harness.run(["--no-update", "pr", "-m", "Add ports command"])
        XCTAssertTrue(custom.git.commandLines.contains("commit -q -m Add ports command -- installer/config"))
    }

    func testPRWithNothingToSend() async {
        let setup = makeSetup()
        let code = await setup.harness.run(["--no-update", "pr"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(setup.harness.out.plain.contains("nothing to send"))
        XCTAssertFalse(setup.git.commandLines.contains { $0.hasPrefix("switch") })
    }

    func testBranchNamesAreSlugsAndNeverCollide() async {
        XCTAssertEqual(PullRequestFlow.slug("nikitabobko/tap/aerospace"), "nikitabobko-tap-aerospace")
        XCTAssertEqual(PullRequestFlow.slug("Aero Dogfood!"), "aero-dogfood")
        let setup = makeSetup()
        setup.git.answer(["rev-parse", "--verify", "-q", "refs/heads/shawn/add-cask-raycast"], exit: 0)
        _ = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertTrue(setup.git.commandLines.contains("switch -c shawn/add-cask-raycast-2"), setup.git.commandLines.joined(separator: "\n"))
    }

    /// A local "GitHub" (bare repo) and a clone of it with the config, set up as this Mac's checkout.
    private final class RealCheckout {
        let sandbox = Sandbox()
        let remote: URL
        let checkout: URL
        let apps: URL

        init(apps appsText: String, cli: String, extraSteps: [String: String] = [:]) {
            let root = sandbox.directory.url
            remote = root.appendingPathComponent("remote.git")
            checkout = root.appendingPathComponent("checkout")
            apps = checkout.appendingPathComponent("installer/config/steps/04-apps.yaml")
            git(["init", "-q", "--bare", "-b", "master", remote.path], in: root)
            git(["clone", "-q", remote.path, checkout.path], in: root)
            makeConfig(in: sandbox.directory, at: "checkout/installer/config", steps: ["04-apps.yaml": appsText].merging(extraSteps) { $1 }, cli: cli)
            git(["add", "-A"], in: checkout)
            git(["commit", "-q", "-m", "start"], in: checkout)
            git(["push", "-q", "-u", "origin", "master"], in: checkout)
            sandbox.directory.write("home/.config/shawn/config.yaml", "dotfiles_repo: \(checkout.path)\nconfig_path: installer/config\n")
            sandbox.directory.write("home/.gitconfig", "[user]\n  name = Test\n  email = test@example.com\n[commit]\n  gpgsign = false\n")
            sandbox.shim("gh", "exit 0")
        }

        func harness() -> Harness {
            let git = SystemGitClient(launcher: SystemProcessLauncher(), environment: sandbox.environment)
            let harness = Harness(sandbox: sandbox) { $0.git = git }
            harness.launcher.respond("pr create", stdout: "https://github.com/tester/dotfiles/pull/8\n")
            return harness
        }

        var appsText: String { (try? String(contentsOf: apps, encoding: .utf8)) ?? "" }
    }

    /// End to end with real git and a local "GitHub": only the step file is committed, on its own branch.
    func testRealGitCommitsOnlyTheConfigFile() async throws {
        let fixture = RealCheckout(apps: apps, cli: addCLI)
        fixture.sandbox.directory.write("checkout/notes.txt", "untracked, must stay out of the commit\n")
        let harness = fixture.harness()
        let code = await harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertEqual(code, 0, harness.err.plain + harness.out.plain)

        XCTAssertEqual(git(["symbolic-ref", "--short", "HEAD"], in: fixture.checkout), "master", "back where we started")
        let branchFiles = git(["show", "--name-only", "--format=", "shawn/add-cask-raycast"], in: fixture.remote)
        XCTAssertEqual(branchFiles, "installer/config/steps/04-apps.yaml")
        let committed = git(["show", "shawn/add-cask-raycast:installer/config/steps/04-apps.yaml"], in: fixture.remote)
        XCTAssertTrue(committed.contains("  - cask: raycast"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.checkout.appendingPathComponent("notes.txt").path))
    }

    /// Offline (or the ssh key not loaded): the push fails. The checkout goes back to master with the change
    /// uncommitted, exactly as if --pr had not been given, and 'shawn pr' sends it later.
    func testRealGitPushFailureLeavesTheCheckoutAsItWas() async throws {
        let fixture = RealCheckout(apps: apps, cli: addCLI)
        let missing = fixture.sandbox.directory.url.appendingPathComponent("no-such-remote.git").path
        git(["remote", "set-url", "origin", missing], in: fixture.checkout)
        let harness = fixture.harness()
        let code = await harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertEqual(code, 1)

        XCTAssertEqual(git(["symbolic-ref", "--short", "HEAD"], in: fixture.checkout), "master", "never left on the new branch")
        XCTAssertEqual(git(["branch", "--list", "shawn/*"], in: fixture.checkout), "", "no unpushed branch left behind")
        XCTAssertEqual(git(["status", "--porcelain"], in: fixture.checkout), "M installer/config/steps/04-apps.yaml", "the change is back, uncommitted")
        XCTAssertTrue(fixture.appsText.contains("  - cask: raycast\n"), fixture.appsText)
        XCTAssertEqual(git(["rev-list", "--count", "HEAD"], in: fixture.checkout), "1", "master has no new commit")
        let err = harness.err.plain
        XCTAssertTrue(err.contains("✗ git push -q -u origin shawn/add-cask-raycast failed"), err)
        XCTAssertTrue(err.contains("Nothing was sent. Back on master with the change uncommitted, as before (installer/config/steps/04-apps.yaml); "
                                   + "send it with 'shawn pr' once origin can be reached."), err)

        // Back online: 'shawn pr' picks the change up.
        git(["remote", "set-url", "origin", fixture.remote.path], in: fixture.checkout)
        let retry = fixture.harness()
        let retryCode = await retry.run(["--no-update", "pr", "-m", "Add cask raycast"])
        XCTAssertEqual(retryCode, 0, retry.err.plain + retry.out.plain)
        XCTAssertEqual(git(["symbolic-ref", "--short", "HEAD"], in: fixture.checkout), "master")
        XCTAssertEqual(git(["status", "--porcelain"], in: fixture.checkout), "")
        let branch = git(["for-each-ref", "--format=%(refname:short)", "refs/heads/shawn/"], in: fixture.remote)
        XCTAssertTrue(branch.hasPrefix("shawn/config-"), branch)
        XCTAssertTrue(git(["show", "\(branch):installer/config/steps/04-apps.yaml"], in: fixture.remote).contains("  - cask: raycast"))
    }

    func testPushFailureGoesBackRestoresTheChangeAndDropsTheBranch() async {
        let setup = makeSetup()
        setup.git.answer(["push"], exit: 1, stderr: "fatal: Could not read from remote repository.")
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertEqual(code, 1)
        let file = "installer/config/steps/04-apps.yaml"
        let lines = setup.git.commandLines
        let pushed = lines.firstIndex { $0.hasPrefix("push ") } ?? lines.endIndex
        XCTAssertEqual(Array(lines[pushed...]), [
            "push -q -u origin shawn/add-cask-raycast",
            "switch -q master",
            "restore --source=shawn/add-cask-raycast --worktree -- \(file)",
            "branch -D shawn/add-cask-raycast",
        ])
        XCTAssertFalse(setup.harness.launcher.requests.contains { $0.arguments.first == "pr" }, "no pull request without a pushed branch")
    }

    func testCommitFailureGoesBackAndKeepsTheChange() async {
        let setup = makeSetup()
        setup.git.answer(["commit"], exit: 128, stderr: "Author identity unknown")
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertEqual(code, 1)
        let lines = setup.git.commandLines
        let committed = lines.firstIndex { $0.hasPrefix("commit ") } ?? lines.endIndex
        XCTAssertEqual(Array(lines[committed...].dropFirst()), ["switch -q master", "branch -d shawn/add-cask-raycast"])
        XCTAssertTrue(setup.harness.err.plain.contains("Back on master; nothing was committed and the change is still in your working tree."), setup.harness.err.plain)
        XCTAssertTrue(setup.apps.contains("  - cask: raycast"))
    }

    func testPullRequestFailureGoesBackAndSaysWhereTheBranchIs() async {
        let setup = makeSetup()
        setup.harness.launcher.respond("pr create", stderr: "To get started with GitHub CLI, please run:  gh auth login", exit: 4)
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertEqual(code, 1)
        XCTAssertEqual(setup.git.commandLines.last, "switch -q master")
        let err = setup.harness.err.plain
        XCTAssertTrue(err.contains("gh pr create failed: To get started with GitHub CLI"), err)
        XCTAssertTrue(err.contains("Back on master. The change is on shawn/add-cask-raycast, pushed to origin; "
                                   + "open the pull request with: gh pr create --base master --head shawn/add-cask-raycast"), err)
    }

    func testCannotSwitchBackSaysWhereTheCheckoutIs() async {
        let setup = makeSetup()
        setup.git.answer(["push"], exit: 1)
        setup.git.answer(["switch", "-q"], exit: 1, stderr: "error: Your local changes would be overwritten")
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertEqual(code, 1)
        let err = setup.harness.err.plain
        XCTAssertTrue(err.contains("could not switch back to master: error: Your local changes would be overwritten"), err)
        XCTAssertTrue(err.contains("The checkout is still on shawn/add-cask-raycast; go back with: git switch master"), err)
        XCTAssertTrue(err.contains("The change is committed on shawn/add-cask-raycast, not pushed."), err)
        XCTAssertFalse(setup.git.commandLines.contains { $0.hasPrefix("branch -D") || $0.hasPrefix("restore") }, "nothing is undone from the wrong branch")
    }

    /// Another step file declares the cask already: no second entry, no pull request.
    func testAlreadyDeclaredInAnotherStepFile() async {
        let setup = makeSetup(extraSteps: ["03-packages.yaml": "id: packages\ntitle: Packages\nitems:\n  - brew: eza\n  - cask: ghostty-nightly\n  - cask: raycast\n    optional: true\n"])
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--no-install", "--pr"])
        XCTAssertEqual(code, 0, setup.harness.err.plain)
        XCTAssertEqual(setup.apps, apps, "04-apps.yaml unchanged")
        XCTAssertTrue(setup.harness.out.plain.contains("· steps/03-packages.yaml:6 already has cask raycast (as optional: true, so it is off unless switched on); nothing to add"),
                      setup.harness.out.plain)
        XCTAssertTrue(setup.harness.out.plain.contains("no pull request needed"))
        XCTAssertFalse(setup.git.commandLines.contains { $0.hasPrefix("switch") || $0.hasPrefix("commit") })

        // A tap-qualified name is the same package as the short one; asked to install, it still installs.
        let tapped = makeSetup(extraSteps: ["03-packages.yaml": "id: packages\ntitle: Packages\nitems:\n  - cask: nikitabobko/tap/aerospace\n"])
        let tappedCode = await tapped.harness.run(["--no-update", "add", "cask", "aerospace"])
        XCTAssertEqual(tappedCode, 0, tapped.harness.err.plain)
        XCTAssertEqual(tapped.log.all, ["install:cask:aerospace:dryRun=false"])
        XCTAssertEqual(tapped.apps, apps)
        XCTAssertTrue(tapped.harness.out.plain.contains("· steps/03-packages.yaml:4 already has cask aerospace; nothing to add"), tapped.harness.out.plain)
    }

    /// '@' cannot start a plain YAML scalar: the line is quoted, and the add succeeds end to end.
    func testScopedNpmPackageIsAdded() async throws {
        let setup = makeSetup(extraSteps: ["03-packages.yaml": "id: packages\ntitle: Packages\nitems:\n  - npm: ghostty-config-cli\n"],
                              cli: addCLI.replacingOccurrences(of: "add:\n", with: "add:\n  npm: steps/03-packages.yaml\n"))
        let code = await setup.harness.run(["--no-update", "add", "npm", "@openai/codex"])
        XCTAssertEqual(code, 0, setup.harness.err.plain)
        XCTAssertEqual(setup.log.all, ["install:npm:@openai/codex:dryRun=false"])
        let packages = try String(contentsOf: setup.checkout.appendingPathComponent("installer/config/steps/03-packages.yaml"), encoding: .utf8)
        XCTAssertTrue(packages.hasSuffix("  - npm: ghostty-config-cli\n  - npm: \"@openai/codex\"\n"), packages)
        XCTAssertTrue(setup.harness.out.plain.contains("added - npm: \"@openai/codex\" to steps/03-packages.yaml:5"), setup.harness.out.plain)
    }

    /// When the line cannot be written, nothing is installed either (no package the config does not know about).
    func testAnEditThatCannotBeMadeInstallsNothing() async {
        let broken = "id: apps\ntitle: Apps\nitems:\n  - cask: ghostty\n    app: [unclosed\n"
        let setup = makeSetup(appsText: broken)
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--app", "Raycast.app"])
        XCTAssertEqual(code, 1)
        XCTAssertEqual(setup.log.all, [], "nothing installed")
        XCTAssertEqual(setup.apps, broken)
        XCTAssertTrue(setup.harness.err.plain.contains("without breaking the file's YAML; add it by hand. Nothing was installed"), setup.harness.err.plain)
    }

    func testOptionalFlagIsWrittenAsABooleanInTheOptionalGroup() async throws {
        let withOptional = apps.replacingOccurrences(of: "\n  # the App Store", with: "\n  # optional\n  - cask: zoom\n    optional: true\n\n  # the App Store")
        let setup = makeSetup(appsText: withOptional)
        let code = await setup.harness.run(["--no-update", "add", "cask", "warp", "--optional", "--no-install"])
        XCTAssertEqual(code, 0, setup.harness.err.plain)
        XCTAssertTrue(setup.apps.contains("  - cask: zoom\n    optional: true\n  - cask: warp\n    optional: true\n"), setup.apps)
        let items = try XCTUnwrap(try YAML.parse(setup.apps)?.map?["items"]?.list)
        XCTAssertEqual(items.first { $0.map?["cask"]?.string == "warp" }?.map?["optional"]?.bool, true, "a boolean, not the string \"true\"")
    }

    /// The step file's casks name their app: the new one gets its app from Homebrew too.
    func testCaskGetsItsAppFromBrewInfo() async throws {
        let setup = makeSetup()
        let brew = setup.harness.sandbox.environment.brewPrefix.appendingPathComponent("bin/brew")
        try FileManager.default.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        setup.harness.launcher.respond("info --cask --json=v2 raycast", stdout: #"{"formulae":[],"casks":[{"token":"raycast","full_token":"raycast","artifacts":[{"uninstall":[{"quit":"com.raycast.macos"}]},{"app":["Raycast.app"]}]}]}"#)
        let code = await setup.harness.run(["--no-update", "add", "cask", "raycast", "--no-install"])
        XCTAssertEqual(code, 0, setup.harness.err.plain)
        XCTAssertTrue(setup.apps.contains("  - cask: raycast\n    app: Raycast.app\n"), setup.apps)
        let info = try XCTUnwrap(setup.harness.launcher.requests.first { $0.arguments.first == "info" })
        XCTAssertEqual(info.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")

        // Without Homebrew's answer it says what to add instead of guessing.
        let unknown = makeSetup()
        _ = await unknown.harness.run(["--no-update", "add", "cask", "mystery", "--no-install"])
        XCTAssertTrue(unknown.harness.err.plain.contains("add --app '<Name>.app' so a copy that is already installed counts as done"), unknown.harness.err.plain)
    }

    func testBrewInfoAppParsing() {
        let json = #"{"casks":[{"token":"a","full_token":"user/tap/a","artifacts":[{"app":["A.app"]}]},"#
            + #"{"token":"b","artifacts":[{"app":["Build/B.app",{"target":"Bee.app"}]}]},{"token":"c","artifacts":[{"binary":["c"]}]}]}"#
        XCTAssertEqual(CaskApps.parse(json), ["a": "A.app", "user/tap/a": "A.app", "b": "Bee.app"])
        XCTAssertEqual(CaskApps.parse("not json"), [:])
    }
}
