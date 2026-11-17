import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

/// Renders review transcripts (install dry run, drift, self-update). Set $SHAWN_CLI_SAMPLES_DIR to keep them
/// for reading. Without it they go to a scratch folder, so the assertions run on every test run: skipped
/// tests had let one of them go stale.
final class SampleOutputTests: XCTestCase {
    private func samplesDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["SHAWN_CLI_SAMPLES_DIR"] ?? ""
        let url = path.isEmpty
            ? FileManager.default.temporaryDirectory.appendingPathComponent("shawn-cli-samples-\(UUID().uuidString)")
            : URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if path.isEmpty { addTeardownBlock { try? FileManager.default.removeItem(at: url) } }
        return url
    }

    private let lsp = """
    id: lsp
    name: Lumpy Space Princess
    palette:
      ".": transparent
      P: "#B57EDC"
      D: "#8E5CB8"
      Y: "#FFE66D"
      W: "#FFFFFF"
      K: "#2B1B3D"
      R: "#E0607E"
    frames:
      - |
        ......PPPP......
        ....PPPPPPPP....
        ...PPPPYYPPPP...
        ..PPPPYYYYPPPP..
        .PPPPPPYYPPPPPP.
        .PPWKPPPPPPWKPP.
        PPPWKPPPPPPWKPPP
        PPPPPPPPPPPPPPPP
        DPPPPPPRRPPPPPPD
        .DPPPPPPPPPPPPD.
        ..DPP.DPPD.PPD..

    """

    private func fixtureConfig(in sandbox: Sandbox) -> URL {
        makeConfig(in: sandbox.directory, meta: "name: Shawn's Dotfiles\ntagline: one Mac, zero lumps\nvars:\n  github_user: shawntz\n", steps: [
            "01-bootstrap.yaml": "id: bootstrap\ntitle: Bootstrap\nsubtitle: Homebrew and friends\nmascot: lsp\nquips: [\"First things first, nerds.\"]\nitems:\n  - present: Xcode Command Line Tools\n  - brew: mas\n  - root: Homebrew\n",
            "02-packages.yaml": "id: packages\ntitle: Homebrew Packages\nmascot: blob\nitems:\n  - tap: buildkite/buildkite\n  - brew: eza\n  - brew: ripgrep\n  - cask: ghostty\n  - cask: warp\n    optional: true\n    note: no longer in /Applications\n",
            "03-apps.yaml": "id: apps\ntitle: Apps\nmascot: lsp\nitems:\n  - mas: 937984704\n    name: Amphetamine\n  - ok: Dropbox sign-in\n    follow_up: Sign in to Dropbox\n  - manual: Allow Karabiner in Privacy & Security\n",
        ], quotes: "speaker: lsp\nmoments:\n  working: [\"Working. Don't rush me.\"]\n  dry_run: [\"Pretend mode. Nothing actually happened, nerd.\"]\n",
           sprites: ["lsp": lsp, "blob": tinySprite], voices: ["blob": "id: blob\nsteps:\n  packages: [\"Blob counts the packages.\"]\n"])
    }

    func testWriteInstallTranscripts() async throws {
        let samples = try samplesDirectory()
        let sandbox = Sandbox()
        let config = fixtureConfig(in: sandbox)
        let plain = Harness(sandbox: sandbox, registry: FakeKinds.registry(installed: ["eza"]), config: config, width: 100)
        let code = await plain.run(["--no-update", "install", "--dry-run"])
        XCTAssertEqual(code, 0)
        try ("$ shawn install --dry-run    (stdout is a pipe: plain log lines)\n" + plain.out.text).write(to: samples.appendingPathComponent("install-dry-run.txt"), atomically: true, encoding: .utf8)

        let live = Harness(sandbox: sandbox, registry: FakeKinds.registry(installed: ["eza"]), config: config, width: 100)
        live.context.terminal = Terminal(stdoutIsTTY: true, stderrIsTTY: true, stdinIsTTY: false, width: 100, color: true, stderrColor: true, trueColor: true)
        _ = await live.run(["--no-update", "install", "--dry-run"])
        try live.out.text.write(to: samples.appendingPathComponent("install-dry-run.tty.ansi.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(live.out.text.contains("▀"), "mascots are drawn on a terminal")
        XCTAssertTrue(live.out.text.contains("Blob counts the packages."), "a voiced mascot says its own line in its step")
    }

    func testWriteDriftTranscript() async throws {
        let samples = try samplesDirectory()
        let sandbox = Sandbox()
        let checkout = sandbox.directory.url.appendingPathComponent("dotfiles")
        makeConfig(in: sandbox.directory, at: "dotfiles/installer/config", steps: [
            "03-packages.yaml": "id: packages\ntitle: Homebrew Packages\nitems:\n  # taps\n  - tap: buildkite/buildkite\n\n  # formulae\n  - brew: eza\n  - brew: fzf\n  - cask: warp\n    optional: true\n",
            "04-apps.yaml": "id: apps\ntitle: Apps\nitems:\n  - cask: ghostty\n  - mas: 937984704\n    name: Amphetamine\n",
        ], cli: "add:\n  tap: steps/03-packages.yaml\n  brew: steps/03-packages.yaml\n  cask: steps/04-apps.yaml\n  mas: steps/04-apps.yaml\ncommands: {}\n")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        var installed = InstalledPackages()
        installed.formulaLeaves = ["eza", "ripgrep", "withgraphite/tap/graphite"]
        installed.formulae = installed.formulaLeaves + ["fzf"]
        installed.casks = ["ghostty", "raycast"]
        installed.taps = ["buildkite/buildkite", "withgraphite/tap"]
        installed.appStore = [.init(id: "937984704", name: "Amphetamine"), .init(id: "1289583905", name: "Pixelmator Pro")]
        installed.available = [.formula, .cask, .tap, .mas]
        let harness = Harness(sandbox: sandbox, width: 110) { $0.inventory = FakeInventory(packages: installed) }
        _ = await harness.run(["--no-update", "drift", "--write", "--repo", checkout.path])
        let file = try String(contentsOf: checkout.appendingPathComponent("installer/config/steps/03-packages.yaml"), encoding: .utf8)
        let text = "$ shawn drift --write\n" + harness.out.text + harness.err.text + "\n--- steps/03-packages.yaml afterward ---\n" + file
        try text.write(to: samples.appendingPathComponent("drift.txt"), atomically: true, encoding: .utf8)
        // In its alphabetical place by name, whatever tap it comes from: graphite before ripgrep.
        XCTAssertTrue(file.contains("  - brew: fzf\n  - brew: withgraphite/tap/graphite\n  - brew: ripgrep\n"), file)
    }

    func testWriteSelfUpdateTranscripts() async throws {
        let samples = try samplesDirectory()
        let fixture = UpdateFixture()
        fixture.write(fixture.sandbox.home, ".config/shawn/config.yaml", "dotfiles_repo: \(fixture.checkout.path)\nconfig_path: installer/config\n")
        func harness() -> Harness {
            Harness(sandbox: fixture.sandbox) { services in
                services.git = fixture.realGit
                services.builder = fixture.builder
            }
        }
        var text = ""
        let first = harness()
        _ = await first.run(["update"])
        text += "$ shawn update            (nothing new)\n" + first.err.plain + first.out.plain + "\n"

        fixture.push("installer/config/cli.yaml", UpdateFixture.cli + "  fresh:\n    summary: Added on another Mac\n    run: echo fresh\n", message: "Add fresh")
        let automatic = harness()
        _ = await automatic.run(["fresh"])
        text += "$ shawn fresh             (another Mac pushed a new YAML command)\n" + automatic.err.plain
        text += "  → runs: \(automatic.replacer.last?.argv.joined(separator: " ") ?? "nothing")\n\n"

        fixture.push("installer/Sources/shawn/main.swift", "print(\"new built-in\")\n", message: "New built-in")
        git(["tag", "shawn-v1.1.0"], in: fixture.upstream)
        git(["push", "-q", "origin", "shawn-v1.1.0"], in: fixture.upstream)
        let rebuild = harness()
        _ = await rebuild.run(["hello"])
        text += "$ shawn hello             (another Mac changed the Swift sources)\n" + rebuild.err.plain
        text += "  → re-exec: \(rebuild.replacer.requests.first.map { "\($0.argv.joined(separator: " ")) with \(SelfUpdateRunner.reexecMarker)=1" } ?? "none")\n\n"

        git(["switch", "-q", "-c", "experiment"], in: fixture.checkout)
        fixture.push("installer/config/cli.yaml", UpdateFixture.cli, message: "Tidy")
        let skipped = harness()
        _ = await skipped.run(["hello"])
        text += "$ shawn hello             (checkout is on another branch)\n" + skipped.err.plain + "\n"

        // A remote that cannot be reached, the way ssh says it. A missing repository is not "offline": that is said.
        let unreachable = fixture.sshGit(failingWith: "ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known")
        let offline = Harness(sandbox: fixture.sandbox) { services in
            services.git = unreachable
            services.builder = fixture.builder
        }
        _ = await offline.run(["hello"])
        text += "$ shawn hello             (offline: nothing is printed)\n" + offline.err.plain + "\n"
        XCTAssertEqual(offline.err.plain, "", "being offline is silent")
        try text.write(to: samples.appendingPathComponent("self-update.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(text.contains("pulled 1 new commit"))
    }
}
