import Foundation
import ShawnCore
import XCTest
@testable import ShawnCLIKit

final class CLIConfigTests: XCTestCase {
    private func parse(_ text: String) throws -> (CLIConfig, [ConfigIssue]) {
        let parsed = CLIConfig.parse(try YAML.parse(text, file: "cli.yaml"), file: "cli.yaml")
        return (parsed.config, parsed.issues)
    }

    func testFullSchema() throws {
        let (config, issues) = try parse("""
        self_update:
          mode: daily
          skip: [hello]
        add:
          brew: steps/03-packages.yaml
          cask: steps/04-apps.yaml
        upgrade:
          - name: Homebrew
            run: brew update && brew upgrade
            if: command -v brew
        statusline:
          quips: [one, two]
        commands:
          claude:
            section: AI
            summary: Claude, lumpy
            update: claude update
            update_timeout: 12
            env:
              FOO: "{{home}}/bar"
            exec:
              - claude
              - --settings
              - json:
                  statusLine: { type: command, command: "{{shawn_bin}} statusline" }
          ports:
            summary: Ports
            usage: "[port]"
            run: lsof -i
        """)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(config.selfUpdate, CLIConfig.SelfUpdate(mode: .daily, skip: ["hello"]))
        XCTAssertEqual(config.add.map(\.kind), ["brew", "cask"])
        XCTAssertEqual(config.add.first?.source, SourceRef(file: "cli.yaml", line: 5))
        XCTAssertEqual(config.upgrade, [CLIConfig.UpgradeStep(name: "Homebrew", run: "brew update && brew upgrade", condition: "command -v brew")])
        XCTAssertEqual(config.statuslineQuips, ["one", "two"])
        let claude = try XCTUnwrap(config.command(named: "claude"))
        XCTAssertEqual(claude.section, "AI")
        XCTAssertEqual(claude.updateTimeout, 12)
        XCTAssertEqual(claude.environment, [CLIConfig.EnvironmentEntry(name: "FOO", value: "{{home}}/bar")])
        guard case .exec(let parts) = claude.action else { return XCTFail("exec expected") }
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], .text("claude"))
        let ports = try XCTUnwrap(config.command(named: "ports"))
        XCTAssertEqual(ports.section, CLIConfig.defaultSection)
        XCTAssertEqual(ports.updateTimeout, CLIConfig.defaultUpdateTimeout)
        XCTAssertEqual(ports.action, .run("lsof -i"))
        XCTAssertEqual(ports.source, SourceRef(file: "cli.yaml", line: 26))
    }

    func testMistakesAreReportedWithFileAndLine() throws {
        let (config, issues) = try parse("""
        self_update:
          mode: sometimes
        upgrade:
          - name: Broken
        commands:
          Bad_Name:
            summary: x
            run: echo
          both:
            summary: x
            run: echo
            exec: [x]
          neither:
            summary: x
          typo:
            sumary: x
            run: echo
          jsonfirst:
            summary: x
            exec:
              - json: { a: 1 }
          weird:
            summary: x
            exec: [tool, [nested]]
          notamap: just text
        """)
        let messages = issues.map(\.description)
        XCTAssertTrue(messages.contains("cli.yaml:2: error: cli → self_update: 'mode' must be one of: always, daily, off (got 'sometimes')"), messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains("cli.yaml:3: error: cli → upgrade[1]: missing required key 'run'"), messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains("cli.yaml:6: error: command name 'Bad_Name' may only contain lowercase letters, digits and dashes"))
        XCTAssertTrue(messages.contains("cli.yaml:11: error: command 'both': use either 'exec' or 'run', not both"), messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains("cli.yaml:13: error: command 'neither': needs 'exec' (a command line to launch) or 'run' (a bash script)"))
        XCTAssertTrue(messages.contains("cli.yaml:16: error: command 'typo': unknown key 'sumary'. Did you mean 'summary'?"), messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains("cli.yaml:15: error: command 'typo': missing required key 'summary'"), messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains("cli.yaml:20: error: command 'jsonfirst': the first element of 'exec' must be the program to run, not a json value"), messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains("cli.yaml:24: error: command 'weird': 'exec' element 2 must be a string or a single-key mapping 'json: <value>', not a list"), messages.joined(separator: "\n"))
        XCTAssertTrue(messages.contains("cli.yaml:25: error: command 'notamap' must be a mapping with 'summary' and 'exec' or 'run', not a string"))
        XCTAssertNil(config.command(named: "neither"))
        XCTAssertNil(config.command(named: "typo"))
    }

    func testSyntaxErrorAndMissingFile() throws {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, steps: [:], cli: "commands:\n  x: [unclosed\n")
        let light = LightConfig.load(ConfigPlace(url: root, source: .local(root.path)))
        let (_, issues) = CLIConfig.load(from: light)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.source?.file, "cli.yaml")
        XCTAssertNotNil(issues.first?.source?.line)

        let empty = makeConfig(in: directory, at: "other", steps: [:])
        let (config, none) = CLIConfig.load(from: LightConfig.load(ConfigPlace(url: empty, source: .local(empty.path))))
        XCTAssertEqual(none, [])
        XCTAssertTrue(config.commands.isEmpty)
        XCTAssertEqual(config.selfUpdate.mode, .always)
    }

    func testSemanticValidation() throws {
        let directory = TempDirectory()
        let root = makeConfig(in: directory, steps: ["03-packages.yaml": "id: packages\ntitle: P\nitems:\n  - brew: eza\n"], cli: """
        add:
          brew: steps/03-packages.yaml
          cask: steps/04-missing.yaml
          potion: steps/03-packages.yaml
        commands:
          install:
            summary: hidden
            run: echo
          wrapper:
            summary: uses vars
            update: "{{nope}} update"
            exec: [tool, "{{home}}", { json: { a: "{{missing_too}}" } }]
        """)
        let config = LightConfig.load(ConfigPlace(url: root, source: .local(root.path)))
        let (cli, issues) = CLIConfig.load(from: config)
        XCTAssertEqual(issues, [])
        let problems = cli.validate(config: config, registry: FakeKinds.registry(), builtinNames: Builtins.names,
                                    vars: ActionContext.makeVars(config: config, environment: Sandbox().environment)).map(\.description)
        XCTAssertTrue(problems.contains("cli.yaml:3: error: add: cask → steps/04-missing.yaml does not exist"), problems.joined(separator: "\n"))
        XCTAssertTrue(problems.contains { $0.hasPrefix("cli.yaml:4: error: add: 'potion' is not an item kind") }, problems.joined(separator: "\n"))
        XCTAssertTrue(problems.contains("cli.yaml:6: warning: command 'install' is hidden by the built-in command of the same name"))
        XCTAssertTrue(problems.contains("cli.yaml:9: error: command 'wrapper' uses unknown variable {{missing_too}}"), problems.joined(separator: "\n"))
        XCTAssertTrue(problems.contains("cli.yaml:9: error: command 'wrapper' uses unknown variable {{nope}}"))
        XCTAssertFalse(problems.contains { $0.contains("{{home}}") })
    }

    /// The cli.yaml this module ships must load cleanly, and keep the commands the brief requires.
    func testShippedCLIYAMLLoadsWithZeroIssues() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/cli.yaml")
        let (config, issues) = CLIConfig.parse(try YAML.parseFile(file, displayName: "cli.yaml"), file: "cli.yaml")
        XCTAssertEqual(issues.map(\.description), [])
        for name in ["claude", "codex", "grok"] {
            let command = try XCTUnwrap(config.command(named: name), name)
            XCTAssertNotNil(command.update, "\(name) must update before launching")
            guard case .exec(let parts) = command.action else { return XCTFail("\(name) must exec") }
            XCTAssertEqual(parts.first, .text(name))
        }
        let runCommands = config.commands.filter { if case .run = $0.action { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(runCommands.count, 8)
        for command in config.commands {
            XCTAssertFalse(Builtins.names.contains(command.name), "\(command.name) would be hidden by a built-in")
        }
        XCTAssertEqual(config.selfUpdate.mode, .always)
        XCTAssertFalse(config.upgrade.isEmpty)
        XCTAssertFalse(config.statuslineQuips.isEmpty)
        XCTAssertTrue(config.statuslineQuips.allSatisfy { $0.count <= 28 }, "status-line quips must stay short")

        // claude: the status line points at this shawn; the user's spinner phrases are never overridden.
        let claude = try XCTUnwrap(config.command(named: "claude"))
        guard case .exec(let parts) = claude.action, case .json(let settings)? = parts.last else { return XCTFail("claude needs a json settings layer") }
        XCTAssertNil(settings.map?["spinnerVerbs"])
        let argv = YAMLCommandRunner.execArguments(parts, userArguments: [], vars: TemplateVars(["shawn_bin": "/Users/me/.local/bin/shawn"]))
        let json = try JSONSerialization.jsonObject(with: Data(argv[2].utf8)) as? [String: Any]
        let statusLine = json?["statusLine"] as? [String: Any]
        XCTAssertEqual(statusLine?["type"] as? String, "command")
        XCTAssertEqual(statusLine?["command"] as? String, "\"/Users/me/.local/bin/shawn\" statusline")
        let tips = (json?["spinnerTipsOverride"] as? [String: Any])?["tips"] as? [String]
        XCTAssertFalse(tips?.isEmpty ?? true)
        XCTAssertTrue((tips ?? []).allSatisfy { $0.count <= 500 && !$0.contains("\n") })
        XCTAssertLessThanOrEqual(((json?["spinnerTipsOverride"] as? [String: Any])?["label"] as? String)?.count ?? 0, 40)
    }

    func testJSONTextKeepsKeyOrderAndEscapes() throws {
        let value = try XCTUnwrap(try YAML.parse("""
        b: 1
        a: [true, null, 2.5, 128.0, "x \\"q\\" \\\\ {{who}}"]
        n: { z: "line\\nbreak" }
        """))
        XCTAssertEqual(JSONText.encode(value, vars: TemplateVars(["who": "me"])),
                       #"{"b":1,"a":[true,null,2.5,128,"x \"q\" \\ me"],"n":{"z":"line\nbreak"}}"#)
    }
}
