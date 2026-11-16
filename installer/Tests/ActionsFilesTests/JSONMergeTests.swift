import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class JSONMergeTests: XCTestCase {
    /// The portable base settings, as the config author would write them in `files/claude/settings.yaml`.
    let baseSettingsYAML = """
    model: opus
    theme: light
    env:
      CLAUDE_CODE_SUBAGENT_MODEL: opus
    permissions:
      allow:
        - Read
        - Edit
        - "Bash(git diff:*)"
    statusLine:
      type: command
      command: "{{home}}/.local/bin/shawn statusline"

    """

    func settingsHarness() -> Harness {
        let harness = Harness()
        harness.payload("claude/settings.yaml", baseSettingsYAML)
        harness.payload("claude/spinner-verbs.yaml", """
        spinnerVerbs:
          mode: replace
          verbs: [Lumping, Being dramatic, Oh my glob]

        """)
        harness.directory.write("home/.claude/settings.json", claudeSettingsFixture, permissions: 0o600)
        return harness
    }

    func testMergesIntoARealShapedSettingsFile() async throws {
        let harness = settingsHarness()
        let item = try harness.item("""
        - json-merge: ~/.claude/settings.json
          from: claude/settings.yaml
          arrays: union
        """)
        XCTAssertNeeded(await item.check())
        let outcome = try await item.run()
        guard case .done(let message?) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasPrefix("updated ~/.claude/settings.json (old copy: ~/.shawn/backups/"), message)

        let text = try XCTUnwrap(harness.directory.read("home/.claude/settings.json"))
        XCTAssertTrue(text.hasSuffix("}\n"))
        let object = try XCTUnwrap(try JSONParser.parse(text).object)
        // Existing keys keep their place; new ones (theme) are appended at the end.
        XCTAssertEqual(object.keys, ["$schema", "model", "env", "permissions", "hooks", "statusLine", "cleanupPeriodDays",
                                     "feedbackSurveyRate", "tinyNumber", "spinnerVerbs", "autoMode", "emptyThings", "nothing", "flag", "theme"])
        XCTAssertEqual(object["env"]?.object?.keys, ["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "CLAUDE_CODE_SUBAGENT_MODEL"])
        XCTAssertEqual(object["permissions"]?.object?["allow"],
                       .array(["Bash(npm test:*)", "Read", "Edit", "Bash(git diff:*)"].map(JSONValue.string)))
        XCTAssertEqual(object["permissions"]?.object?["defaultMode"], .string("auto"), "unknown nested keys survive")
        XCTAssertEqual(object["statusLine"]?.object?["command"], .string("\(harness.home.path)/.local/bin/shawn statusline"))
        XCTAssertEqual(object["statusLine"]?.object?.keys, ["type", "command", "padding"])
        XCTAssertEqual(object["hooks"], try JSONParser.parse(claudeSettingsFixture).object?["hooks"], "unrelated keys are untouched")
        XCTAssertTrue(text.contains("\"feedbackSurveyRate\": 0.0,"), "number spelling is kept")
        XCTAssertTrue(text.contains("emoji 🎉"), "unicode stays unescaped")
        XCTAssertFalse(text.contains("\\/"), "forward slashes are never escaped")
        XCTAssertEqual(harness.permissions(harness.url("home/.claude/settings.json")), 0o600, "the file's mode is kept")

        let backup = harness.environment.backupDirectory.appendingPathComponent(".claude/settings.json")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), claudeSettingsFixture)

        XCTAssertSatisfied(await item.check())
        let before = harness.snapshot()
        await XCTAssertOutcome(try await item.run(), .done("already merged"))
        XCTAssertEqual(harness.snapshot(), before)
    }

    func testSpinnerVerbsReplaceTheWholeList() async throws {
        let harness = settingsHarness()
        let item = try harness.item("""
        - json-merge: ~/.claude/settings.json
          from: claude/spinner-verbs.yaml
        """)
        try await item.run()
        let object = try XCTUnwrap(try JSONParser.parse(XCTUnwrap(harness.directory.read("home/.claude/settings.json"))).object)
        XCTAssertEqual(object["spinnerVerbs"]?.object?["verbs"], .array(["Lumping", "Being dramatic", "Oh my glob"].map(JSONValue.string)))
        XCTAssertEqual(object.keys.firstIndex(of: "spinnerVerbs"), 9, "the key stays where it was")
        XCTAssertSatisfied(await item.check())
    }

    func testInlineValuesWithVariablesAndAFileTogether() async throws {
        let harness = settingsHarness()
        let item = try harness.item("""
        - json-merge: ~/.claude/settings.json
          from: claude/settings.yaml
          values:
            theme: dark
            owner: "{{full_name}}"
        """)
        try await item.run()
        let object = try XCTUnwrap(try JSONParser.parse(XCTUnwrap(harness.directory.read("home/.claude/settings.json"))).object)
        XCTAssertEqual(object["theme"], .string("dark"), "inline values win over the file")
        XCTAssertEqual(object["owner"], .string("Shawn Tester"))
        XCTAssertEqual(object["permissions"]?.object?["allow"], .array(["Read", "Edit", "Bash(git diff:*)"].map(JSONValue.string)),
                       "arrays are replaced by default")
    }

    func testFromAJSONFile() async throws {
        let harness = Harness()
        harness.payload("codex/patch.json", "{\"b\": [1, 2], \"a\": {\"x\": 1.50}}\n")
        let item = try harness.item("""
        - json-merge: ~/.config/thing.json
          from: codex/patch.json
        """)
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/.config/thing.json"), """
        {
          "b": [
            1,
            2
          ],
          "a": {
            "x": 1.50
          }
        }

        """)
    }

    func testCreatesAMissingFile() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - json-merge: ~/.claude/settings.json
          values: {model: opus}
        """)
        XCTAssertNeeded(await item.check())
        await XCTAssertOutcome(try await item.run(), .done("created ~/.claude/settings.json"))
        XCTAssertEqual(harness.directory.read("home/.claude/settings.json"), "{\n  \"model\": \"opus\"\n}\n")
        XCTAssertSatisfied(await item.check())
    }

    func testCreateFalseLeavesAMissingFileAlone() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - json-merge: ~/.codex/config.json
          values: {a: 1}
          create: false
        """)
        XCTAssertSatisfied(await item.check())
        await XCTAssertOutcome(try await item.run(), .skipped("~/.codex/config.json does not exist and 'create' is false"))
        XCTAssertFalse(harness.directory.exists("home/.codex/config.json"))
    }

    func testInvalidExistingJSONIsRefusedAndLeftUntouched() async throws {
        let harness = Harness()
        let broken = "{\n  \"model\": \"opus\",\n}\n"
        harness.directory.write("home/.claude/settings.json", broken)
        let item = try harness.item("""
        - json-merge: ~/.claude/settings.json
          values: {theme: dark}
        """)
        let check = await item.check()
        XCTAssertNeeded(check)
        let error = await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertEqual(error?.message, "~/.claude/settings.json is not valid JSON (line 3, column 1: trailing comma before '}'); it was left untouched")
        XCTAssertNotNil(error?.hint)
        XCTAssertEqual(harness.directory.read("home/.claude/settings.json"), broken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.environment.backupDirectory.path))
    }

    func testANonObjectFileIsRefused() async throws {
        let harness = Harness()
        harness.directory.write("home/list.json", "[1, 2]\n")
        let item = try harness.item("""
        - json-merge: ~/list.json
          values: {a: 1}
        """)
        let error = await XCTAssertThrowsActionError { try await item.run() }
        XCTAssertTrue(error?.message.contains("holds a JSON array, not an object") == true, "\(String(describing: error))")
        XCTAssertEqual(harness.directory.read("home/list.json"), "[1, 2]\n")
    }

    func testAnEmptyFileCountsAsAnEmptyObject() async throws {
        let harness = Harness()
        harness.directory.write("home/empty.json", "  \n")
        let item = try harness.item("""
        - json-merge: ~/empty.json
          values: {a: 1}
        """)
        try await item.run()
        XCTAssertEqual(harness.directory.read("home/empty.json"), "{\n  \"a\": 1\n}\n")
    }

    func testDryRunChangesNothing() async throws {
        let harness = settingsHarness()
        let item = try harness.item("""
        - json-merge: ~/.claude/settings.json
          from: claude/settings.yaml
        """)
        let before = harness.snapshot("home")
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would update ~/.claude/settings.json"))
        XCTAssertEqual(harness.snapshot("home"), before)
        XCTAssertTrue(harness.logText.contains("[dry-run] update ~/.claude/settings.json"), harness.logText)
    }

    func testASymlinkedSettingsFileIsUpdatedThroughTheLink() async throws {
        let harness = Harness()
        harness.directory.write("home/dotfiles/settings.json", "{\"a\": 1}\n")
        try FileManager.default.createDirectory(at: harness.url("home/.claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: harness.url("home/.claude/settings.json").path, withDestinationPath: "../dotfiles/settings.json")
        let item = try harness.item("""
        - json-merge: ~/.claude/settings.json
          values: {b: 2}
        """)
        try await item.run()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: harness.url("home/.claude/settings.json").path), "../dotfiles/settings.json")
        XCTAssertEqual(harness.directory.read("home/dotfiles/settings.json"), "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
        XCTAssertSatisfied(await item.check())
    }

    func testValidation() throws {
        let harness = Harness()
        harness.payload("bad.yaml", "a: [unclosed\n")
        harness.payload("list.yaml", "- a\n- b\n")
        harness.payload("bad.json", "{\"a\": 1,}")

        let nothing = try harness.problems("- json-merge: ~/x.json")
        XCTAssertTrue(nothing.contains { $0.contains("needs 'values:'") }, "\(nothing)")

        let missing = try harness.problems("""
        - json-merge: ~/x.json
          from: nope.yaml
        """)
        XCTAssertTrue(missing.contains { $0.contains("'from' file files/nope.yaml does not exist") }, "\(missing)")

        let badYAML = try harness.problems("""
        - json-merge: ~/x.json
          from: bad.yaml
        """)
        XCTAssertFalse(badYAML.isEmpty)

        let list = try harness.problems("""
        - json-merge: ~/x.json
          from: list.yaml
        """)
        XCTAssertTrue(list.contains { $0.contains("must contain a mapping at the top level") }, "\(list)")

        let badJSON = try harness.problems("""
        - json-merge: ~/x.json
          from: bad.json
        """)
        XCTAssertTrue(badJSON.contains { $0.contains("is not valid JSON") }, "\(badJSON)")

        let arrays = try harness.problems("""
        - json-merge: ~/x.json
          values: {a: 1}
          arrays: merge
        """)
        XCTAssertTrue(arrays.contains { $0.contains("'arrays' must be one of: replace, union") }, "\(arrays)")

        let notMap = try harness.problems("""
        - json-merge: ~/x.json
          values: [1, 2]
        """)
        XCTAssertTrue(notMap.contains { $0.contains("'values' must be a mapping") }, "\(notMap)")
    }
}
