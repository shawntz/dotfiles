import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

final class ConfigEditorTests: XCTestCase {
    private let packages = """
    id: packages
    title: Homebrew Packages   # the big one
    mascot: jake
    items:
      # ── taps ──
      - tap: buildkite/buildkite
        trusted: true
      - tap: jurplel/tap

      # ── formulae ──
      - brew: eza            # ls, but lumpy
      - brew: fzf
      - brew: "7zip"

      # ── casks ──
      - cask: ghostty
        optional: true
        note: fallback terminal
    """

    private func insert(_ kind: String, _ value: String, _ options: [(String, String)] = [], into text: String) throws -> (String, ConfigEditor.Result) {
        try insert(kind, value, typed: options.map { (key: $0.0, value: YAMLValue.string($0.1)) }, into: text)
    }

    private func insert(_ kind: String, _ value: String, typed options: [ConfigEditor.Option], into text: String) throws -> (String, ConfigEditor.Result) {
        let result = try ConfigEditor.insert(kind: kind, value: value, options: options, into: text)
        return (result.text, result.result)
    }

    /// The shipped step files, as the real targets of `shawn add` and `shawn drift --write`.
    private func shipped(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/steps/\(name)")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Lines of `text` from `line` (1-based) on.
    private func lines(_ text: String, from line: Int, count: Int) -> [String] {
        Array(text.components(separatedBy: "\n").dropFirst(line - 1).prefix(count))
    }

    func testInsertsAfterTheLastItemOfTheSameKindKeepingEverythingElse() throws {
        let (text, result) = try insert("brew", "ripgrep", into: packages + "\n")
        XCTAssertEqual(result, .inserted(line: 14))
        XCTAssertEqual(text, """
        id: packages
        title: Homebrew Packages   # the big one
        mascot: jake
        items:
          # ── taps ──
          - tap: buildkite/buildkite
            trusted: true
          - tap: jurplel/tap

          # ── formulae ──
          - brew: eza            # ls, but lumpy
          - brew: fzf
          - brew: "7zip"
          - brew: ripgrep

          # ── casks ──
          - cask: ghostty
            optional: true
            note: fallback terminal

        """)
    }

    func testInsertAfterAMultiLineItem() throws {
        let (text, result) = try insert("tap", "withgraphite/tap", into: packages)
        XCTAssertEqual(result, .inserted(line: 9))
        XCTAssertTrue(text.contains("  - tap: buildkite/buildkite\n    trusted: true\n  - tap: jurplel/tap\n  - tap: withgraphite/tap\n\n  # ── formulae ──"), text)
        XCTAssertFalse(text.hasSuffix("\n"), "no trailing newline added when the file had none")

        let (casks, _) = try insert("cask", "raycast", into: packages)
        XCTAssertTrue(casks.hasSuffix("  - cask: ghostty\n    optional: true\n    note: fallback terminal\n  - cask: raycast"), casks)
    }

    func testKindNotYetInTheFileGoesAfterTheLastItem() throws {
        let plain = "id: x\ntitle: X\nitems:\n  - brew: a\n  - cask: b\n"
        let (text, result) = try insert("mas", "937984704", [("name", "Amphetamine")], into: plain)
        XCTAssertEqual(result, .inserted(line: 6))
        XCTAssertTrue(text.hasSuffix("  - cask: b\n  - mas: 937984704\n    name: Amphetamine\n"), text)
        let parsed = try XCTUnwrap(try YAML.parse(text)?.map?["items"]?.list?.last?.map)
        XCTAssertEqual(parsed["mas"]?.int, 937984704, "numeric ids stay numbers")
        XCTAssertEqual(parsed["name"]?.string, "Amphetamine")
    }

    /// Before: a new kind went after the very last item, here inside the trailing group of optional casks,
    /// though the new item is switched on.
    func testKindNotYetInTheFileStaysAboveTheTrailingOptionalGroup() throws {
        let (text, result) = try insert("mas", "937984704", [("name", "Amphetamine")], into: packages + "\n")
        XCTAssertEqual(result, .inserted(line: 14))
        XCTAssertTrue(text.contains("  - brew: \"7zip\"\n  - mas: 937984704\n    name: Amphetamine\n\n  # ── casks ──\n  - cask: ghostty\n    optional: true\n"), text)
    }

    func testAlreadyPresentIsReportedAndNothingChanges() throws {
        for (kind, value, line) in [("brew", "eza", 11), ("brew", "7zip", 13), ("tap", "jurplel/tap", 8)] {
            let (text, result) = try insert(kind, value, into: packages)
            XCTAssertEqual(result, .alreadyPresent(line: line), value)
            XCTAssertEqual(text, packages)
        }
    }

    func testZeroIndentedListsAndTabsKeepTheirIndentation() throws {
        let zero = "id: x\ntitle: X\nitems:\n- brew: a\n- brew: b\nquips:\n  - hi\n"
        let (text, _) = try insert("brew", "c", into: zero)
        XCTAssertEqual(text, "id: x\ntitle: X\nitems:\n- brew: a\n- brew: b\n- brew: c\nquips:\n  - hi\n")
    }

    func testEmptyAndMissingItemLists() throws {
        let flow = "id: x\ntitle: X\nitems: []  # nothing yet\n"
        let (fromFlow, result) = try insert("cask", "slack", into: flow)
        XCTAssertEqual(result, .inserted(line: 4))
        XCTAssertEqual(fromFlow, "id: x\ntitle: X\nitems:  # nothing yet\n  - cask: slack\n")

        let block = "id: x\ntitle: X\nitems:\n# later\nquips: [a]\n"
        let (fromBlock, _) = try insert("cask", "slack", into: block)
        XCTAssertEqual(fromBlock, "id: x\ntitle: X\nitems:\n  - cask: slack\n# later\nquips: [a]\n")

        let none = "id: x\ntitle: X"
        let (fromNone, _) = try insert("cask", "slack", into: none)
        XCTAssertEqual(fromNone, "id: x\ntitle: X\n\nitems:\n  - cask: slack\n")
    }

    func testValuesThatNeedQuoting() throws {
        XCTAssertEqual(ConfigEditor.scalar("eza"), "eza")
        XCTAssertEqual(ConfigEditor.scalar("nikitabobko/tap/aerospace"), "nikitabobko/tap/aerospace")
        XCTAssertEqual(ConfigEditor.scalar("937984704"), "937984704")
        XCTAssertEqual(ConfigEditor.scalar("Aero Dogfood"), "Aero Dogfood")
        XCTAssertEqual(ConfigEditor.scalar("yes"), "\"yes\"")
        XCTAssertEqual(ConfigEditor.scalar("1.10"), "\"1.10\"")
        XCTAssertEqual(ConfigEditor.scalar("a: b"), "\"a: b\"")
        XCTAssertEqual(ConfigEditor.scalar("# not a comment"), "\"# not a comment\"")
        XCTAssertEqual(ConfigEditor.scalar("https://my.carbonapp.co"), "\"https://my.carbonapp.co\"")
        let (text, _) = try insert("webapp", "Carbon", [("url", "https://my.carbonapp.co")], into: "id: w\ntitle: W\nitems:\n  - webapp: X\n    url: https://x.com\n")
        XCTAssertTrue(text.hasSuffix("  - webapp: Carbon\n    url: \"https://my.carbonapp.co\"\n"), text)
        XCTAssertEqual(try YAML.parse(text)?.map?["items"]?.list?.last?.map?["url"]?.string, "https://my.carbonapp.co")

        // '@' is reserved in YAML and cannot start a plain scalar (scoped npm packages).
        XCTAssertEqual(ConfigEditor.scalar("@openai/codex"), "\"@openai/codex\"")
        XCTAssertEqual(ConfigEditor.scalar("@anthropic-ai/claude-code"), "\"@anthropic-ai/claude-code\"")
        // Plain where it is safe, as the step files write them.
        for plain in ["Wispr Flow.app", "T3 Code (Beta).app", "zoom.us.app", "ghostty-config-cli", "c++", "-1", "0"] {
            XCTAssertEqual(ConfigEditor.scalar(plain), plain)
        }
        // Everything YAML would read as something else, or not at all.
        for tricky in ["- x", "-x", "a #b", "a: b", "a:", "", " lead", "trail ", "0123", "007", "1_000", "0x1F", "0o17", "+1", "1e3", ".inf", ".NaN",
                       "~", "Null", "Y", "n", "On", "2024-01-02", "*alias", "&anchor", "!tag", "%dir", "`tick", "'q", "\"q", "[a]", "{a}", "a, b",
                       "a\tb", "two\nlines", "bell\u{07}", "del\u{7F}", "sep\u{2028}", "bom\u{FEFF}", "Café", "back\\slash", "|", ">", "?", ":"] {
            XCTAssertNotEqual(ConfigEditor.scalar(tricky), tricky, "'\(tricky)' must be quoted")
        }
    }

    /// Whatever the text, what is written reads back as exactly that text (a string, or the whole number it spells).
    func testEveryScalarReadsBackAsWritten() throws {
        let samples = ["eza", "@openai/codex", "- x", "a #b", "a: b", "", " lead", "trail ", "0123", "1.10", "yes", "~", "null", "2024-01-02",
                       "*alias", "&a b", "!tag x", "%x", "`x", "'q'", "\"q\"", "[a, b]", "{a: b}", "a\tb", "two\nlines", "bell\u{07}",
                       "del\u{7F}", "c1\u{85}", "sep\u{2028}", "bom\u{FEFF}", "Café ☕️", "back\\slash", "ends with \\", "937984704", "-12"]
        for sample in samples {
            let written = ConfigEditor.scalar(sample)
            let value = try XCTUnwrap(try YAML.parse("k: " + written)?.map?["k"], sample)
            guard case .scalar(let scalar) = value else { return XCTFail("\(sample) → \(written) is not a scalar") }
            XCTAssertEqual(scalar.raw, sample, "\(sample) → \(written)")
            if ConfigEditor.isCanonicalInteger(sample) {
                XCTAssertEqual(scalar.kind, .int(Int(sample)!), sample)
            } else {
                XCTAssertEqual(scalar.kind, .string, "\(sample) → \(written)")
            }
        }
    }

    func testScopedNpmPackagesRoundTrip() throws {
        let (text, result) = try insert("npm", "@openai/codex", into: packages + "\n")
        XCTAssertEqual(result, .inserted(line: 14))
        XCTAssertTrue(text.contains("  - brew: \"7zip\"\n  - npm: \"@openai/codex\"\n"), text)
        let items = try XCTUnwrap(try YAML.parse(text)?.map?["items"]?.list)
        XCTAssertTrue(items.contains { $0.map?["npm"]?.string == "@openai/codex" }, text)
        let (again, second) = try insert("npm", "@openai/codex", into: text)
        XCTAssertEqual(second, .alreadyPresent(line: 14), "a quoted value is recognized on the next run")
        XCTAssertEqual(again, text)
    }

    func testOptionValuesKeepTheirType() throws {
        let (text, _) = try insert("cask", "zed", typed: [(key: "optional", value: .bool(true)), (key: "note", value: .string("true")), (key: "retries", value: .int(3))],
                                   into: packages + "\n")
        XCTAssertTrue(text.contains("  - cask: zed\n    optional: true\n    note: \"true\"\n    retries: 3\n"), text)
        let item = try XCTUnwrap(try YAML.parse(text)?.map?["items"]?.list?.last?.map)
        XCTAssertEqual(item["optional"]?.bool, true, "--optional becomes a real boolean, as the kinds require")
        XCTAssertEqual(item["note"]?.typeName, "string")
        XCTAssertEqual(item["retries"]?.int, 3)
    }

    /// The shipped 04-apps.yaml: everyday apps (alphabetical), App Store, downloads, then optional apps and
    /// optional App Store apps. A new app must not end up under "── Optional ──".
    func testNewAppsGoWithTheEverydayAppsInTheShippedAppsFile() throws {
        let apps = try shipped("04-apps.yaml")

        let (zed, zedResult) = try insert("cask", "zed", typed: [(key: "app", value: .string("Zed.app"))], into: apps)
        guard case .inserted(let zedLine) = zedResult else { return XCTFail("\(zedResult)") }
        XCTAssertEqual(lines(zed, from: zedLine - 2, count: 5), ["  - cask: wispr-flow", "    app: Wispr Flow.app", "  - cask: zed", "    app: Zed.app", ""])
        XCTAssertTrue(lines(zed, from: zedLine + 3, count: 1)[0].hasPrefix("  # ── Mac App Store"), "still before the App Store group")

        let (notion, notionResult) = try insert("cask", "notion", typed: [(key: "app", value: .string("Notion.app"))], into: apps)
        guard case .inserted(let notionLine) = notionResult else { return XCTFail("\(notionResult)") }
        XCTAssertEqual(lines(notion, from: notionLine - 1, count: 4), ["    note: paid; needs your license", "  - cask: notion", "    app: Notion.app", "  - cask: slack"],
                       "in alphabetical order: after middle, before slack")

        let (optional, optionalResult) = try insert("cask", "zzz-tool", typed: [(key: "optional", value: .bool(true))], into: apps)
        guard case .inserted(let optionalLine) = optionalResult else { return XCTFail("\(optionalResult)") }
        XCTAssertEqual(lines(optional, from: optionalLine - 3, count: 6), ["  - cask: zoom", "    app: zoom.us.app", "    optional: true", "  - cask: zzz-tool", "    optional: true", ""],
                       "an optional app joins the optional ones")

        let (store, storeResult) = try insert("mas", "409183694", [("name", "Keynote")], into: apps)
        guard case .inserted(let storeLine) = storeResult else { return XCTFail("\(storeResult)") }
        XCTAssertEqual(lines(store, from: storeLine - 2, count: 4), ["  - mas: 937984704", "    name: Amphetamine", "  - mas: 409183694", "    name: Keynote"],
                       "a switched-on App Store app joins Amphetamine, not the optional ones at the end")

        let (web, webResult) = try insert("webapp", "Carbon", [("url", "https://my.carbonapp.co")], into: apps)
        guard case .inserted(let webLine) = webResult else { return XCTFail("\(webResult)") }
        XCTAssertEqual(lines(web, from: webLine - 1, count: 4), ["    team_id: ZL4K35VM2L", "  - webapp: Carbon", "    url: \"https://my.carbonapp.co\"", ""],
                       "a kind the file does not have yet stays above the trailing optional groups")

        for text in [zed, notion, optional, store, web] {
            XCTAssertNotNil(try YAML.parse(text)?.map?["items"]?.list)
        }
    }

    func testNewCasksStayOutOfTheShippedPackagesFileGoneGroup() throws {
        let packages = try shipped("03-packages.yaml")
        let (text, result) = try insert("cask", "zed", into: packages)
        guard case .inserted(let line) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(lines(text, from: line - 2, count: 4), ["  - cask: vercel", "    note: a formula on the old laptop; Homebrew now ships it as a cask", "  - cask: zed", ""])
        let (brew, brewResult) = try insert("brew", "aaa-first", into: packages)
        guard case .inserted(let brewLine) = brewResult else { return XCTFail("\(brewResult)") }
        XCTAssertTrue(lines(brew, from: brewLine, count: 1)[0].hasPrefix("  - brew: aaa-first"), brew)
        XCTAssertFalse(lines(brew, from: brewLine - 1, count: 1)[0].contains("optional"))
    }

    func testGroupsAndOptionalItemsAreRecognized() {
        let layout = ConfigEditor.analyze(packages.components(separatedBy: "\n"))
        XCTAssertEqual(layout.items.map(\.group), [0, 0, 1, 1, 1, 2])
        XCTAssertEqual(layout.items.map(\.optional), [false, false, false, false, false, true])
        XCTAssertEqual(ConfigEditor.trailingOptionalStart(layout.items), 5)
        XCTAssertTrue(ConfigEditor.isOptionalTrue("optional: yes  # off for now"))
        XCTAssertFalse(ConfigEditor.isOptionalTrue("optional: false"))
    }

    func testWritesTheFileInPlacePreservingPermissions() throws {
        let directory = TempDirectory()
        let file = directory.write("steps/03-packages.yaml", packages + "\n", permissions: 0o640)
        XCTAssertEqual(try ConfigEditor.insert(kind: "brew", value: "bat", file: file), .inserted(line: 14))
        XCTAssertTrue(directory.read("steps/03-packages.yaml")?.contains("  - brew: \"7zip\"\n  - brew: bat\n") ?? false)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(try ConfigEditor.insert(kind: "brew", value: "bat", file: file), .alreadyPresent(line: 14))
        XCTAssertThrowsError(try ConfigEditor.insert(kind: "brew", value: "x", file: directory.url.appendingPathComponent("missing.yaml")))
    }
}

final class DriftTests: XCTestCase {
    private func plan(_ steps: [String: String], registry: ActionRegistry) throws -> InstallPlan {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, steps: steps)
        let loaded = try ConfigLoader.load(from: root)
        let plan = InstallPlan.build(config: loaded.config, registry: registry, environment: Sandbox().environment)
        XCTAssertEqual(plan.errors, [])
        return plan
    }

    private let steps = [
        "03-packages.yaml": "id: packages\ntitle: P\nitems:\n  - tap: buildkite/buildkite\n  - brew: eza\n  - brew: supabase/tap/supabase\n  - brew: node\n  - cask: warp\n    optional: true\n  - npm: ghostty-config-cli\n",
        "04-apps.yaml": "id: apps\ntitle: A\nitems:\n  - mas: 937984704\n    name: Amphetamine\n  - cask: nikitabobko/tap/aerospace\n",
    ]

    func testExtrasAndMissingAcrossManagers() throws {
        let registry = FakeKinds.registry()
        let plan = try plan(steps, registry: registry)
        var installed = InstalledPackages()
        installed.formulaLeaves = ["eza", "supabase/tap/supabase", "ripgrep"]
        installed.formulae = ["eza", "supabase", "ripgrep", "node", "libgit2"]
        installed.casks = ["aerospace", "raycast"]
        installed.taps = ["buildkite/buildkite", "mikker/tap"]
        installed.appStore = [.init(id: "937984704", name: "Amphetamine"), .init(id: "6448461551", name: "Command X")]
        installed.available = [.formula, .cask, .tap, .mas]
        let kinds = PackageKinds.discover(plan: plan, registry: registry, preferred: [])
        let report = Drift.compare(plan: plan, installed: installed, kinds: kinds)

        XCTAssertEqual(report.extras.map { "\($0.manager.rawValue):\($0.name):\($0.kind ?? "-")" },
                       ["tap:mikker/tap:tap", "formula:ripgrep:brew", "cask:raycast:cask", "mas:6448461551:mas"])
        XCTAssertEqual(report.extras.last?.label, "Command X")
        XCTAssertEqual(report.missing.map(\.ref.name), ["warp"], "node is installed as a dependency: not missing")
        XCTAssertEqual(report.missing.first?.optional, true)
        XCTAssertEqual(report.missing.first?.source.file, "steps/03-packages.yaml")
        XCTAssertEqual(report.unchecked, [.npm], "npm could not be asked: no claims either way")
    }

    func testKindsAreDiscoveredNotAssumed() throws {
        // A registry whose package kinds have unusual names, and a plan that does not use them all.
        let registry = FakeKinds.registry(names: [.formula: "potion", .cask: "bottle", .mas: "store-app", .tap: "spring", .npm: "jar"])
        let kinds = PackageKinds.discover(plan: nil, registry: registry, preferred: ["bottle"])
        XCTAssertEqual(kinds, [.formula: "potion", .cask: "bottle", .mas: "store-app", .tap: "spring", .npm: "jar"])
    }

    func testMASListParsing() {
        let apps = BrewInventory.parseMASList("  937984704  Amphetamine        (5.3.2)\n1289583905  Pixelmator Pro  (3.6)\nnot an app\n")
        XCTAssertEqual(apps, [.init(id: "937984704", name: "Amphetamine"), .init(id: "1289583905", name: "Pixelmator Pro")])
    }

    func testBrewInventoryAgainstShims() async {
        let sandbox = Sandbox()
        let brewBin = sandbox.environment.brewPrefix.appendingPathComponent("bin")
        try! FileManager.default.createDirectory(at: brewBin, withIntermediateDirectories: true)
        let brew = brewBin.appendingPathComponent("brew")
        try! Data("""
        #!/bin/bash
        echo "$*" >> "$(dirname "$0")/brew.log"
        case "$*" in
          leaves) printf 'eza\\nsupabase/tap/supabase\\n' ;;
          "list --formula --full-name -1") printf 'eza\\nnode\\nsupabase/tap/supabase\\n' ;;
          "list --cask --full-name -1") printf 'ghostty\\n' ;;
          tap) printf 'homebrew/core\\nbuildkite/buildkite\\n' ;;
        esac

        """.utf8).write(to: brew)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        sandbox.shim("mas", "echo '937984704  Amphetamine  (5.3.2)'")
        sandbox.shim("npm", #"echo '{"dependencies":{"npm":{},"ghostty-config-cli":{}}}'"#)
        let installed = await BrewInventory(launcher: SystemProcessLauncher(), environment: sandbox.environment).installed()
        XCTAssertEqual(installed.formulaLeaves, ["eza", "supabase/tap/supabase"])
        XCTAssertEqual(installed.formulae, ["eza", "node", "supabase/tap/supabase"])
        XCTAssertEqual(installed.casks, ["ghostty"])
        XCTAssertEqual(installed.taps, ["buildkite/buildkite"])
        XCTAssertEqual(installed.appStore, [.init(id: "937984704", name: "Amphetamine")])
        XCTAssertEqual(installed.npm, ["ghostty-config-cli"])
        XCTAssertEqual(installed.available, [.formula, .cask, .tap, .mas, .npm])
    }

    func testDriftCommandPrintsAndWritesTheLines() async throws {
        let sandbox = Sandbox()
        let checkout = sandbox.directory.url.appendingPathComponent("dotfiles")
        makeConfig(in: sandbox.directory, at: "dotfiles/installer/config", steps: steps,
                   cli: "add:\n  brew: steps/03-packages.yaml\n  cask: steps/04-apps.yaml\n  mas: steps/04-apps.yaml\n  tap: steps/03-packages.yaml\ncommands: {}\n")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        var installed = InstalledPackages()
        installed.formulaLeaves = ["eza", "supabase", "ripgrep"]
        installed.formulae = installed.formulaLeaves + ["node"]
        installed.casks = ["aerospace", "warp", "raycast"]
        installed.taps = ["buildkite/buildkite"]
        installed.appStore = [.init(id: "937984704", name: "Amphetamine"), .init(id: "1289583905", name: "Pixelmator Pro")]
        installed.available = [.formula, .cask, .tap, .mas]
        let harness = Harness(sandbox: sandbox) { $0.inventory = FakeInventory(packages: installed) }
        let code = await harness.run(["--no-update", "drift", "--repo", checkout.path])
        XCTAssertEqual(code, 0)
        let text = harness.out.plain
        XCTAssertTrue(text.contains("Installed but not in the config (3)"), text)
        XCTAssertTrue(text.contains("- brew: ripgrep"), text)
        XCTAssertTrue(text.contains("- mas: 1289583905, name: Pixelmator Pro"), text)
        XCTAssertFalse(text.contains("In the config but not installed"), text)

        let writer = Harness(sandbox: sandbox) { $0.inventory = FakeInventory(packages: installed) }
        let writeCode = await writer.run(["--no-update", "drift", "--write", "--repo", checkout.path])
        XCTAssertEqual(writeCode, 0)
        let packages = try String(contentsOf: checkout.appendingPathComponent("installer/config/steps/03-packages.yaml"), encoding: .utf8)
        XCTAssertTrue(packages.contains("  - brew: node\n  - brew: ripgrep\n"), packages)
        let apps = try String(contentsOf: checkout.appendingPathComponent("installer/config/steps/04-apps.yaml"), encoding: .utf8)
        XCTAssertTrue(apps.contains("    name: Amphetamine\n  - mas: 1289583905\n    name: Pixelmator Pro\n"), apps)
        XCTAssertTrue(apps.contains("  - cask: nikitabobko/tap/aerospace\n  - cask: raycast"), apps)
        XCTAssertTrue(writer.out.plain.contains("✓ steps/03-packages.yaml:"), writer.out.plain)
    }

    /// A cask whose app is in /Applications but not in Homebrew is installed, as `shawn install` and `shawn doctor` see it.
    func testCaskAppsInstalledWithoutHomebrewAreNotMissing() async throws {
        let sandbox = Sandbox()
        try FileManager.default.createDirectory(at: sandbox.environment.applicationsDirectory.appendingPathComponent("Slack.app"), withIntermediateDirectories: true)
        let config = makeConfig(in: sandbox.directory, steps: [
            "04-apps.yaml": "id: apps\ntitle: Apps\nitems:\n  - cask: slack\n    app: Slack.app\n  - cask: zoom\n    app: zoom.us.app\n  - cask: spotify\n",
        ])
        var installed = InstalledPackages()
        installed.available = [.cask]
        let harness = Harness(sandbox: sandbox, config: config) { $0.inventory = FakeInventory(packages: installed) }
        let code = await harness.run(["--no-update", "drift"])
        XCTAssertEqual(code, 0)
        let text = harness.out.plain
        XCTAssertTrue(text.contains("In the config but not installed (2)"), text)
        XCTAssertTrue(text.contains("  cask    zoom "), text)
        XCTAssertTrue(text.contains("  cask    spotify "), text)
        XCTAssertFalse(text.contains("  cask    slack "), text)
        XCTAssertTrue(text.contains("Installed without Homebrew (1) · in place, but 'brew upgrade' does not update them\n  cask    slack\n"), text)
    }

    /// `drift --write` adds an extra cask with the app Homebrew says it installs, when the step file's casks name theirs.
    func testWriteGivesCasksTheirApp() async throws {
        let sandbox = Sandbox()
        let checkout = sandbox.directory.url.appendingPathComponent("dotfiles")
        makeConfig(in: sandbox.directory, at: "dotfiles/installer/config",
                   steps: ["04-apps.yaml": "id: apps\ntitle: A\nitems:\n  - cask: slack\n    app: Slack.app\n  - cask: zoom\n    app: zoom.us.app\n"],
                   cli: "add:\n  cask: steps/04-apps.yaml\ncommands: {}\n")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let brew = sandbox.environment.brewPrefix.appendingPathComponent("bin/brew")
        try FileManager.default.createDirectory(at: brew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        var installed = InstalledPackages()
        installed.casks = ["slack", "zoom", "raycast"]
        installed.available = [.cask]
        let harness = Harness(sandbox: sandbox) { $0.inventory = FakeInventory(packages: installed) }
        harness.launcher.respond("info --cask --json=v2 raycast", stdout: #"{"casks":[{"token":"raycast","artifacts":[{"app":["Raycast.app"]}]}]}"#)
        let code = await harness.run(["--no-update", "drift", "--write", "--repo", checkout.path])
        XCTAssertEqual(code, 0, harness.err.plain)
        let apps = try String(contentsOf: checkout.appendingPathComponent("installer/config/steps/04-apps.yaml"), encoding: .utf8)
        XCTAssertTrue(apps.contains("items:\n  - cask: raycast\n    app: Raycast.app\n  - cask: slack\n"), "in alphabetical order, with its app: \(apps)")
        XCTAssertTrue(harness.out.plain.contains("✓ steps/04-apps.yaml:4  - cask: raycast, app: Raycast.app"), harness.out.plain)
    }

    func testWriteNeedsACheckout() async {
        let harness = Harness()
        let code = await harness.run(["--no-update", "drift", "--write"])
        XCTAssertEqual(code, 64)
        XCTAssertTrue(harness.err.plain.contains("needs a checkout"), harness.err.plain)
    }
}
