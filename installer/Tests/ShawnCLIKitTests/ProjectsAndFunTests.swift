import Foundation
import ShawnCore
import ShawnFun
import XCTest
@testable import ShawnCLIKit

final class ProjectsTests: XCTestCase {
    func testFindsReposOneAndTwoLevelsDownWithTheirState() async throws {
        let sandbox = Sandbox()
        let developer = sandbox.home.appendingPathComponent("Developer")
        for path in ["alpha", "org/beta", "not-a-repo/deeper/gamma", ".hidden"] {
            let repo = developer.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            git(["init", "-q", "-b", "main"], in: repo)
        }
        try Data("x".utf8).write(to: developer.appendingPathComponent("org/beta/file.txt"))
        let repos = Projects.find(in: developer)
        XCTAssertEqual(repos.map(\.lastPathComponent), ["alpha", "beta"])

        let harness = Harness(sandbox: sandbox)
        let code = await harness.run(["--no-update", "projects"])
        XCTAssertEqual(code, 0)
        let text = harness.out.plain
        XCTAssertTrue(text.hasPrefix("~/Developer · 2 repos\n"), text)
        XCTAssertTrue(text.contains("  alpha     main              ✓ clean\n"), text)
        XCTAssertTrue(text.contains("  org/beta  main              ● changes\n"), text)

        let paths = Harness(sandbox: sandbox)
        _ = await paths.run(["--no-update", "projects", "--paths"])
        XCTAssertEqual(paths.out.text, repos.map { $0.path + "\n" }.joined())
    }

    func testAheadBehindParsing() {
        var entry = Projects.Entry(url: URL(fileURLWithPath: "/x"), name: "x")
        Projects.apply("# branch.oid abc\n# branch.head feature\n# branch.upstream origin/feature\n# branch.ab +2 -5\n", to: &entry)
        XCTAssertEqual(entry.branch, "feature")
        XCTAssertEqual(entry.ahead, 2)
        XCTAssertEqual(entry.behind, 5)
        XCTAssertFalse(entry.dirty)
    }

    func testCloneSources() {
        let vars = TemplateVars(["github_user": "shawntz"])
        XCTAssertEqual(CloneCommand.source(for: "owner/repo", vars: vars), .init(slug: "owner/repo", url: "https://github.com/owner/repo.git", name: "repo"))
        XCTAssertEqual(CloneCommand.source(for: "dotfiles", vars: vars), .init(slug: "shawntz/dotfiles", url: "https://github.com/shawntz/dotfiles.git", name: "dotfiles"))
        XCTAssertEqual(CloneCommand.source(for: "git@github.com:a/b.git", vars: vars), .init(slug: "a/b", url: "git@github.com:a/b.git", name: "b"))
        XCTAssertEqual(CloneCommand.source(for: "https://gitlab.com/a/b", vars: vars), .init(slug: nil, url: "https://gitlab.com/a/b", name: "b"))
        XCTAssertNil(CloneCommand.source(for: "dotfiles", vars: TemplateVars()))
        XCTAssertNil(CloneCommand.source(for: "a/b/c", vars: vars))
        XCTAssertNil(CloneCommand.source(for: "bad name", vars: vars))
    }

    func testCloneRunsGitAndAsksTheShellToChangeDirectory() async throws {
        var sandbox = Sandbox()
        let cdFile = sandbox.directory.url.appendingPathComponent("cd")
        sandbox.environment.baseEnvironment[ChangeDirectory.variable] = cdFile.path
        let harness = Harness(sandbox: sandbox, config: makeConfig(in: sandbox.directory, steps: [:]))
        let code = await harness.run(["--no-update", "clone", "lumpy/space"])
        XCTAssertEqual(code, 0, harness.err.plain)
        let request = try XCTUnwrap(harness.launcher.requests.last)
        let target = sandbox.home.appendingPathComponent("Developer/space")
        XCTAssertEqual(Array(request.arguments.suffix(3)), ["clone", "https://github.com/lumpy/space.git", target.path])
        XCTAssertEqual(try String(contentsOf: cdFile, encoding: .utf8), target.path)

        let bad = Harness(sandbox: sandbox)
        let badCode = await bad.run(["--no-update", "clone", "../escape"])
        XCTAssertEqual(badCode, 64)
    }

    /// gh refuses to clone anything while logged out (exit 4), even a public repo: plain git takes over.
    func testCloneFallsBackToGitWhenGhCannot() async throws {
        let sandbox = Sandbox()
        sandbox.shim("gh", "exit 4")
        let harness = Harness(sandbox: sandbox, config: makeConfig(in: sandbox.directory, steps: [:]))
        harness.launcher.interactiveStatuses = ["gh": 4]
        let code = await harness.run(["--no-update", "clone", "octocat/Hello-World"])
        XCTAssertEqual(code, 0, harness.err.plain)
        let target = sandbox.home.appendingPathComponent("Developer/Hello-World")
        XCTAssertEqual(harness.events.all.filter { $0.hasPrefix("interactive") }, [
            "interactive: gh repo clone octocat/Hello-World \(target.path)",
            "interactive: git clone https://github.com/octocat/Hello-World.git \(target.path)",
        ])
        XCTAssertTrue(harness.err.plain.contains("gh repo clone did not work (exit 4); trying git clone https://github.com/octocat/Hello-World.git"), harness.err.plain)
        XCTAssertTrue(harness.out.plain.contains("cloned into ~/Developer/Hello-World"), harness.out.plain)

        // gh working: git is never asked.
        let fine = Harness(sandbox: sandbox, config: makeConfig(in: sandbox.directory, at: "config2", steps: [:]))
        _ = await fine.run(["--no-update", "clone", "octocat/Spoon-Knife"])
        XCTAssertEqual(fine.events.all.filter { $0.hasPrefix("interactive") }.count, 1)

        // Something is already in the way (a half-finished clone): no second attempt over it.
        let partial = sandbox.home.appendingPathComponent("Developer/partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        XCTAssertTrue(CloneCommand.nothingCloned(at: partial))
        try Data("x".utf8).write(to: partial.appendingPathComponent("leftover"))
        XCTAssertFalse(CloneCommand.nothingCloned(at: partial))
        XCTAssertTrue(CloneCommand.nothingCloned(at: sandbox.home.appendingPathComponent("Developer/nope")))

        // An interrupted gh clone is not retried.
        let interrupted = Harness(sandbox: sandbox, config: makeConfig(in: sandbox.directory, at: "config3", steps: [:]))
        interrupted.launcher.interactiveStatuses = ["gh": ExitCode.interrupted]
        let interruptedCode = await interrupted.run(["--no-update", "clone", "octocat/linguist"])
        XCTAssertEqual(interruptedCode, ExitCode.interrupted)
        XCTAssertEqual(interrupted.events.all.filter { $0.hasPrefix("interactive") }.count, 1)
    }

    func testNewScaffoldsAProject() async throws {
        var sandbox = Sandbox()
        let cdFile = sandbox.directory.url.appendingPathComponent("cd")
        sandbox.environment.baseEnvironment[ChangeDirectory.variable] = cdFile.path
        sandbox.directory.write("home/.gitconfig", "[user]\n  name = LSP\n  email = lsp@example.com\n[commit]\n  gpgsign = false\n")
        let harness = Harness(sandbox: sandbox)
        harness.context.services.launcher = SystemProcessLauncher()
        let code = await harness.run(["--no-update", "new", "lumpy-app"])
        XCTAssertEqual(code, 0, harness.err.plain)
        let project = sandbox.home.appendingPathComponent("Developer/lumpy-app")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("README.md"), encoding: .utf8), "# lumpy-app\n")
        XCTAssertTrue(try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8).contains(".env"))
        XCTAssertEqual(git(["log", "--format=%s"], in: project), "Start lumpy-app")
        XCTAssertEqual(try String(contentsOf: cdFile, encoding: .utf8), project.path)

        let again = Harness(sandbox: sandbox)
        let againCode = await again.run(["--no-update", "new", "lumpy-app"])
        XCTAssertEqual(againCode, 1)
        XCTAssertTrue(again.err.plain.contains("already exists"))
        let invalid = Harness(sandbox: sandbox)
        let invalidCode = await invalid.run(["--no-update", "new", ".sneaky"])
        XCTAssertEqual(invalidCode, 64)
    }
}

final class FunTests: XCTestCase {
    private func sprite() -> Sprite {
        let collector = IssueCollector()
        let map = try! YAML.parse(tinySprite)!.map!
        return FunConfig.parseSprite(map, file: "blob.yaml", config: nil, collector: collector)!
    }

    func testColorPolicyMapsOntoTheSharedSpriteRenderer() {
        XCTAssertEqual(Style.off.spriteColorMode, .plain)
        XCTAssertEqual(Style(enabled: false, trueColor: true).spriteColorMode, .plain, "no color means no escapes, whatever the terminal")
        XCTAssertEqual(Style(enabled: true, trueColor: true).spriteColorMode, .trueColor)
        XCTAssertEqual(Style(enabled: true, trueColor: false).spriteColorMode, .ansi256)
    }

    func testHalfBlocksWithoutColorShowTheSilhouette() {
        let lines = Style.off.spriteRenderer.render(sprite().frames[0])
        XCTAssertEqual(lines, ["▄██▄", "▀██▀"])
        // The shared renderer pads an odd number of rows at the top, so the art stands on its last line.
        let odd = SpriteFrame(pixels: [[RGBA(red: 255, green: 0, blue: 0), RGBA(red: 255, green: 0, blue: 0)]])
        XCTAssertEqual(Style.off.spriteRenderer.render(odd), ["▄▄"])
    }

    func testHalfBlocksWithColorUseForegroundAndBackground() {
        let lines = Style(enabled: true, trueColor: true).spriteRenderer.render(sprite().frames[0])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("\u{1B}[38;2;181;126;220m▄"), lines[0])
        XCTAssertTrue(lines[0].contains("\u{1B}[48;2;255;230;109m▀"), "lavender (already the foreground) over yellow in one cell")
        XCTAssertTrue(lines[0].hasSuffix("\u{1B}[0m"))
        XCTAssertEqual(ANSIText.strip(lines[0]), "▄▀▀▄")
        // Two pixels of one color: a space on that background (the shared renderer's way of filling a cell).
        XCTAssertEqual(ANSIText.strip(lines[1]), "▀  ▀")
        let palette256 = Style(enabled: true, trueColor: false).spriteRenderer.render(sprite().frames[0])
        XCTAssertTrue(palette256[0].contains("\u{1B}[38;5;"))
    }

    func testBubbleAndSpeaking() {
        XCTAssertEqual(Painter.bubble("Oh my glob", maxWidth: 40, style: .off), ["╭────────────╮", "│ Oh my glob │", "╰────────────╯"])
        let wrapped = Painter.bubble("this sentence is way too long for one line", maxWidth: 16, style: .off)
        XCTAssertEqual(wrapped.count, 5)
        XCTAssertEqual(Set(wrapped.map { TextWidth.of($0) }).count, 1, "every row the same width")

        let colored = Painter.bubble("Oh my glob", maxWidth: 40, style: Style(enabled: true, trueColor: true), tail: .left)
        XCTAssertEqual(colored.map(ANSIText.strip), [" ╭────────────╮", "─┤ Oh my glob │", " ╰────────────╯"])
        XCTAssertTrue(colored[1].contains("\u{1B}[38;2;255;230;109m Oh my glob "), "the words in the quote color, the frame in lavender")

        let speaking = Painter.speaking(sprite(), says: "Oh my glob", style: .off, width: 80)
        XCTAssertEqual(speaking, ["  ▄██▄  ╭────────────╮", "  ▀██▀ ─┤ Oh my glob │", "        ╰────────────╯"])
        XCTAssertEqual(Painter.speaking(nil, says: "Hi", style: .off, width: 80), ["╭────╮", "│ Hi │", "╰────╯"])
    }

    func testLineUpWrapsAndCaptions() {
        let blob = sprite()
        XCTAssertEqual(Painter.lineUp([blob, blob, blob], style: .off, width: 19), [
            "  ▄██▄   ▄██▄", "  ▀██▀   ▀██▀", "  Blob   Blob", "",
            "  ▄██▄", "  ▀██▀", "  Blob", "",
        ])
        // A name wider than its sprite is written out in full; the tile grows to fit it.
        let yaml = "id: queen\nname: Marceline the Vampire Queen\npalette:\n  D: \"#FF0000\"\nframes:\n  - |\n    DD\n"
        let queen = FunConfig.parseSprite(try! YAML.parse(yaml)!.map!, file: "queen.yaml", config: nil, collector: IssueCollector())!
        let lines = Painter.lineUp([queen], style: .off, width: 80)
        XCTAssertTrue(lines.contains { $0.contains("Marceline the Vampire Queen") }, "\(lines)")
    }

    func testBannerFallsBackWhenTooWide() {
        let header = "  ____  _\n / ___|| |__\n \\___ \\| '_ \\"
        XCTAssertEqual(Painter.banner(header, style: .off, width: 80), ["  ____  _", " / ___|| |__", " \\___ \\| '_ \\"])
        XCTAssertEqual(Painter.banner(header, style: .off, width: 8, tagline: "tiny"), ["✦ SHAWN'S DOTFILES ✦", "  tiny"])
    }

    func testFunCommandsWithFixtureSprites() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: [:], quotes: """
        speaker: blob
        about: Fan-made test fixture.
        show_quotes:
          - text: "Oh my glob!"
            episode: "Trouble in Lumpy Space"
        moments:
          idle: ["Lumping around."]
          launch: ["Hi, nerds."]
          success: ["Nailed it."]
          waiting: ["Waiting is the worst."]
          finished: ["Party time."]
        """, sprites: ["blob": tinySprite, "dot": "id: dot\nname: Dot\npalette:\n  D: \"#FF0000\"\nframes:\n  - |\n    DD\n"])
        let harness = Harness(sandbox: sandbox, config: config)
        _ = await harness.run(["--no-update", "lsp"])
        let lsp = harness.out.plain
        XCTAssertTrue(lsp.contains("▄██▄"), lsp)
        XCTAssertTrue(["Lumping around.", "Hi, nerds.", "Nailed it.", "Waiting is the worst."].contains { lsp.contains($0) }, lsp)

        let party = Harness(sandbox: sandbox, config: config)
        _ = await party.run(["--no-update", "party"])
        XCTAssertTrue(party.out.plain.contains("Blob"))
        XCTAssertTrue(party.out.plain.contains("Dot"))
        XCTAssertTrue(party.out.plain.contains("Party time."))
        XCTAssertTrue(party.out.plain.contains("Fan-made test fixture."))

        let quote = Harness(sandbox: sandbox, config: config)
        _ = await quote.run(["--no-update", "quote"])
        XCTAssertEqual(quote.out.plain, "\"Oh my glob!\"\n  Blob, \"Trouble in Lumpy Space\"\n  Fan-made test fixture.\n")

        let banner = Harness(sandbox: sandbox, config: config)
        _ = await banner.run(["--no-update", "banner"])
        XCTAssertEqual(banner.out.plain, "SHAWN'S DOTFILES\n  tiny test\n")
    }

    func testTextWidth() {
        XCTAssertEqual(TextWidth.of("\u{1B}[1mbold\u{1B}[22m"), 4)
        XCTAssertEqual(TextWidth.of("✦ ▰▱"), 4)
        XCTAssertEqual(TextWidth.of("🍑"), 2)
        XCTAssertEqual(TextWidth.truncate("abcdefgh", to: 5), "abcd…")
        XCTAssertEqual(TextWidth.wrap("one two three four", width: 9), ["one two", "three", "four"])
    }

    func testColorPolicy() {
        XCTAssertFalse(ColorPolicy(environment: ["NO_COLOR": "1"], noColorFlag: false).allows(tty: true))
        XCTAssertFalse(ColorPolicy(environment: [:], noColorFlag: true).allows(tty: true))
        XCTAssertFalse(ColorPolicy(environment: ["TERM": "dumb"], noColorFlag: false).allows(tty: true))
        XCTAssertTrue(ColorPolicy(environment: ["NO_COLOR": ""], noColorFlag: false).allows(tty: true), "an empty NO_COLOR does not count")
        XCTAssertFalse(ColorPolicy(environment: [:], noColorFlag: false).allows(tty: false))
        XCTAssertTrue(ColorPolicy(environment: ["CLICOLOR_FORCE": "1"], noColorFlag: false).allows(tty: false))
        XCTAssertEqual(Style.xterm256(RGBA(red: 0xB5, green: 0x7E, blue: 0xDC)), 140)
    }

    func testConfigSubcommands() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: [
            "01-a.yaml": "id: a\ntitle: Alpha\nitems:\n  - brew: eza\n  - cask: warp\n    optional: true\n  - mas: 937984704\n    name: Amphetamine\n  - tap: x/y\n",
        ], cli: "add:\n  brew: steps/01-a.yaml\ncommands: {}\n")
        let show = Harness(sandbox: sandbox, config: config)
        _ = await show.run(["--no-update", "config", "show"])
        XCTAssertTrue(show.out.plain.contains("a  Alpha  steps/01-a.yaml"), show.out.plain)
        // The kind column is as wide as the longest kind in the config, so no kind runs into its title.
        XCTAssertTrue(show.out.plain.contains("  brew  eza\n"), show.out.plain)
        XCTAssertTrue(show.out.plain.contains("  cask  warp  optional\n"), show.out.plain)

        let brewfile = Harness(sandbox: sandbox, config: config)
        _ = await brewfile.run(["--no-update", "config", "brewfile"])
        XCTAssertEqual(brewfile.out.plain, """
        # Brewfile generated from Test Dotfiles by `shawn config brewfile`.
        # Install with: brew bundle --file=<this file>

        tap "x/y"

        brew "eza"

        cask "warp"  # optional

        mas "Amphetamine", id: 937984704

        """)

        let validate = Harness(sandbox: sandbox, config: config)
        let code = await validate.run(["--no-update", "config", "validate"])
        XCTAssertEqual(code, 0, validate.out.plain)

        let broken = makeConfig(in: sandbox.directory, at: "broken", steps: ["01-a.yaml": "id: a\ntitle: A\nitems:\n  - bew: eza\n"],
                                cli: "commands:\n  x:\n    summry: typo\n    run: echo\n")
        let invalid = Harness(sandbox: sandbox)
        let invalidCode = await invalid.run(["--no-update", "config", "validate", broken.path])
        XCTAssertEqual(invalidCode, 1)
        XCTAssertTrue(invalid.out.plain.contains("steps/01-a.yaml:4: error: item 1: unknown item kind 'bew'. Did you mean 'brew'?"), invalid.out.plain)
        XCTAssertTrue(invalid.out.plain.contains("cli.yaml:3: error: command 'x': unknown key 'summry'. Did you mean 'summary'?"), invalid.out.plain)

        let kinds = Harness(sandbox: sandbox, config: config)
        _ = await kinds.run(["--no-update", "config", "kinds"])
        XCTAssertTrue(kinds.out.plain.contains("brew  a formula package\n    - brew: name\n"), kinds.out.plain)

        let unknown = Harness(sandbox: sandbox, config: config)
        let unknownCode = await unknown.run(["--no-update", "config", "shwo"])
        XCTAssertEqual(unknownCode, 64)
        XCTAssertTrue(unknown.err.plain.contains("Did you mean 'show'?"))
    }

    func testConfigEditOpensTheEditorOnTheConfigDirectory() async throws {
        var sandbox = Sandbox()
        sandbox.environment.baseEnvironment["EDITOR"] = "code -w"
        let config = makeConfig(in: sandbox.directory, steps: [:])
        let harness = Harness(sandbox: sandbox, config: config)
        let code = await harness.run(["--no-update", "config", "edit"])
        XCTAssertEqual(code, 0)
        let request = try XCTUnwrap(harness.replacer.last)
        XCTAssertEqual(request.path, "/bin/sh")
        XCTAssertEqual(request.argv, ["sh", "-c", "exec code -w \"$1\"", "shawn", config.path])
    }

    func testUpgradeRunsEachEntryAndReports() async {
        let sandbox = Sandbox()
        let config = makeConfig(in: sandbox.directory, steps: [:], cli: """
        upgrade:
          - name: First
            run: echo one
          - name: Missing tool
            run: nothing-here upgrade
            if: command -v nothing-here
          - name: Last
            run: echo last
        commands: {}
        """)
        let harness = Harness(sandbox: sandbox, config: config)
        harness.launcher.respond(when: { $0.arguments.last == "command -v nothing-here" }, with: ProcessResult(exitCode: 1, stdout: "", stderr: ""))
        let code = await harness.run(["--no-update", "upgrade"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(harness.events.all.filter { $0.hasPrefix("interactive") }, ["interactive: bash -c echo one", "interactive: bash -c echo last"])
        XCTAssertTrue(harness.out.plain.contains("  First         ✓ done\n  Missing tool  ↷ skipped (not installed here)\n  Last          ✓ done\n"), harness.out.plain)

        let failing = Harness(sandbox: sandbox, config: config)
        failing.launcher.interactiveStatus = 3
        let failingCode = await failing.run(["--no-update", "upgrade", "first"])
        XCTAssertEqual(failingCode, 1)
        XCTAssertTrue(failing.out.plain.contains("First  ✗ failed (exit 3)"), failing.out.plain)
    }
}
