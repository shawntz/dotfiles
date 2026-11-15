import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

/// Shaped like a real `~/.claude/settings.json` (made-up values): nested objects, arrays, a shell command with
/// quotes and slashes, unicode, numbers in several spellings, and keys this installer knows nothing about.
let claudeSettingsFixture = """
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "opus",
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "permissions": {
    "allow": [
      "Bash(npm test:*)",
      "Read"
    ],
    "defaultMode": "auto"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash '/Users/someone/.claude/hooks/herdr-agent-state.sh' session"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "input=$(cat); echo \\"$(echo \\"$input\\" | jq -r '.model.display_name') ✨ $(git -C \\"$(echo \\"$input\\" | jq -r '.cwd')\\" --no-optional-locks branch --show-current 2>/dev/null)\\"",
    "padding": 0
  },
  "cleanupPeriodDays": 30,
  "feedbackSurveyRate": 0.0,
  "tinyNumber": 1e-7,
  "spinnerVerbs": {
    "mode": "replace",
    "verbs": [
      "Lumping",
      "Oh-my-globbing"
    ]
  },
  "autoMode": {
    "notes": "café, naïve, 日本語, emoji 🎉, tab\\tand newline\\n"
  },
  "emptyThings": {
    "list": [],
    "object": {}
  },
  "nothing": null,
  "flag": false
}

"""

final class JSONTests: XCTestCase {
    func testRoundTripIsByteIdentical() throws {
        let value = try JSONParser.parse(claudeSettingsFixture)
        XCTAssertEqual(value.rendered(), claudeSettingsFixture)
    }

    func testKeyOrderAndNumberSpellingArePreserved() throws {
        let object = try XCTUnwrap(try JSONParser.parse(claudeSettingsFixture).object)
        XCTAssertEqual(object.keys, ["$schema", "model", "env", "permissions", "hooks", "statusLine", "cleanupPeriodDays",
                                     "feedbackSurveyRate", "tinyNumber", "spinnerVerbs", "autoMode", "emptyThings", "nothing", "flag"])
        XCTAssertEqual(object["feedbackSurveyRate"], .number(JSONNumber(literal: "0.0")!))
        guard case .number(let tiny) = object["tinyNumber"] else { return XCTFail() }
        XCTAssertEqual(tiny.literal, "1e-7")
    }

    func testStringsAreDecodedAndReEncodedLikeJSONStringify() throws {
        let value = try JSONParser.parse(#"{"a": "slash\/ok", "b": "\u00e9\ud83c\udf89", "c": "\u001f\b\f", "d": "plain/slash"}"#)
        let object = try XCTUnwrap(value.object)
        XCTAssertEqual(object["a"], .string("slash/ok"))
        XCTAssertEqual(object["b"], .string("é🎉"))
        XCTAssertEqual(value.rendered(), """
        {
          "a": "slash/ok",
          "b": "é🎉",
          "c": "\\u001f\\b\\f",
          "d": "plain/slash"
        }

        """)
    }

    func testEmptyContainersAndScalarsRender() throws {
        XCTAssertEqual(JSONValue.object(JSONObject()).rendered(), "{}\n")
        XCTAssertEqual(JSONValue.array([]).rendered(), "[]\n")
        XCTAssertEqual(try JSONParser.parse(" [1, true, null, \"x\"] ").rendered(), "[\n  1,\n  true,\n  null,\n  \"x\"\n]\n")
    }

    func testStrictParsingRejectsWhatClaudeCodeRejects() {
        let cases: [(String, String)] = [
            ("{\"a\": 1,}", "trailing comma before '}'"),
            ("[1, 2,]", "trailing comma before ']'"),
            ("{\"a\": 1 // note\n}", "expected ',' or '}'"),
            ("// comment\n{}", "comments are not allowed"),
            ("{'a': 1}", "expected a key in double quotes"),
            ("{a: 1}", "expected a key in double quotes"),
            ("{\"a\": 01}", "invalid number"),
            ("{\"a\": NaN}", "unexpected character 'N'"),
            ("{\"a\": 1 \"b\": 2}", "expected ',' or '}'"),
            ("{\"a\": \"unterminated}", "unterminated string"),
            ("{} {}", "unexpected text after the end"),
            ("{\"a\": \"tab\there\"}", "control character inside a string"),
            ("{\"a\": \"\\ud800\"}", "unpaired surrogate"),
            ("{\"a\": \"\\x41\"}", "invalid escape"),
            ("", "unexpected end of file"),
            ("{\"a\": -}", "invalid number"),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try JSONParser.parse(text), text) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(text): \(error)")
            }
        }
    }

    func testErrorsCarryLineAndColumn() {
        XCTAssertThrowsError(try JSONParser.parse("{\n  \"a\": 1,\n  \"b\": tru\n}")) { error in
            let parseError = error as? JSONParseError
            XCTAssertEqual(parseError?.line, 3)
            XCTAssertEqual(parseError?.column, 8)
        }
    }

    func testByteOrderMarkIsTolerated() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("{\"a\": 1}".utf8))
        XCTAssertEqual(try JSONParser.parse(data).rendered(), "{\n  \"a\": 1\n}\n")
    }

    func testNumbersCompareByValue() {
        XCTAssertEqual(JSONNumber(literal: "1"), JSONNumber(literal: "1.0"))
        XCTAssertEqual(JSONNumber(literal: "1e3"), JSONNumber(literal: "1000"))
        XCTAssertNotEqual(JSONNumber(literal: "1"), JSONNumber(literal: "2"))
        XCTAssertNil(JSONNumber(literal: "01"))
        XCTAssertNil(JSONNumber(literal: "1."))
        XCTAssertNil(JSONNumber(literal: ".5"))
        XCTAssertEqual(JSONNumber(128.0)?.literal, "128")
        XCTAssertEqual(JSONNumber(0.15)?.literal, "0.15")
        XCTAssertNil(JSONNumber(Double.infinity))
    }

    /// Numbers compare by exact value, however long: Decimal keeps only 38 digits, so integers that differ further
    /// along used to compare equal and a changed value was reported as already merged.
    func testNumbersCompareExactlyAtAnyLength() throws {
        let long = try XCTUnwrap(JSONNumber(literal: "12345678901234567890123456789012345678901"))
        let longer = try XCTUnwrap(JSONNumber(literal: "12345678901234567890123456789012345678902"))
        XCTAssertNotEqual(long, longer)
        XCTAssertEqual(long, JSONNumber(literal: "1.2345678901234567890123456789012345678901e40"))
        XCTAssertNotEqual(JSONNumber(literal: "0.12345678901234567890123456789012345678901"),
                          JSONNumber(literal: "0.12345678901234567890123456789012345678902"))
        XCTAssertEqual(JSONNumber(literal: "1"), JSONNumber(literal: "1.0"))
        XCTAssertEqual(JSONNumber(literal: "1e3"), JSONNumber(literal: "1000"))
        XCTAssertEqual(JSONNumber(literal: "10e-1"), JSONNumber(literal: "1"))
        XCTAssertEqual(JSONNumber(literal: "1.5E+1"), JSONNumber(literal: "15"))
        XCTAssertEqual(JSONNumber(literal: "0.0"), JSONNumber(literal: "0"))
        XCTAssertEqual(JSONNumber(literal: "-0"), JSONNumber(literal: "0e5"))
        XCTAssertEqual(JSONNumber(literal: "0.000100"), JSONNumber(literal: "1e-4"))
        XCTAssertNotEqual(JSONNumber(literal: "100"), JSONNumber(literal: "10"))
        XCTAssertNotEqual(JSONNumber(literal: "-1"), JSONNumber(literal: "1"))
        XCTAssertNotEqual(JSONNumber(literal: "1e-4"), JSONNumber(literal: "1e4"))
        XCTAssertEqual(JSONNumber(literal: "1e99999999999999999999"), JSONNumber(literal: "1e99999999999999999999"))
        XCTAssertNotEqual(JSONNumber(literal: "1e99999999999999999999"), JSONNumber(literal: "1e99999999999999999998"))

        let existing = try JSONParser.parse(#"{"id": 12345678901234567890123456789012345678901}"#)
        let merged = existing.merging(try JSONParser.parse(#"{"id": 12345678901234567890123456789012345678902}"#), arrays: .replace)
        XCTAssertNotEqual(merged, existing, "the new value is a change")
        XCTAssertEqual(merged.object?["id"], .number(longer))
    }

    /// JSON keys are compared code point by code point: "é" written precomposed and as e + combining accent are two keys.
    func testKeysThatDifferOnlyInUnicodeNormalisationStayApart() throws {
        let composed = "Caf\u{E9}"
        let decomposed = "Cafe\u{301}"
        let existing = try JSONParser.parse(#"{"Café": 1, "Café": 2, "other": 0}"#)
        let object = try XCTUnwrap(existing.object)
        XCTAssertEqual(object.members.count, 3)
        XCTAssertEqual(object[composed], .number(JSONNumber(1)))
        XCTAssertEqual(object[decomposed], .number(JSONNumber(2)))

        let merged = existing.merging(try JSONParser.parse(#"{"other": 1, "Café": 3}"#), arrays: .replace)
        let expected = "{\n  \"\(composed)\": 1,\n  \"\(decomposed)\": 3,\n  \"other\": 1\n}\n"
        XCTAssertEqual(Array(merged.rendered().utf8), Array(expected.utf8), merged.rendered())

        XCTAssertNotEqual(JSONValue.object(JSONObject([composed: .null])), .object(JSONObject([decomposed: .null])))
        XCTAssertFalse(JSONValue.object(JSONObject([composed: .null])).sameJSON(as: .object(JSONObject([decomposed: .null]))))
        XCTAssertNotEqual(JSONValue.string(composed), .string(decomposed), "string values too")
        let union = JSONValue.array([.string(composed)]).merging(.array([.string(decomposed)]), arrays: .union)
        XCTAssertEqual(union, .array([.string(composed), .string(decomposed)]))
    }

    // MARK: Merge

    func testMergeKeepsExistingOrderAndAppendsNewKeys() throws {
        let existing = try JSONParser.parse(#"{"z": 1, "a": {"keep": true, "change": 1}, "m": "x"}"#)
        let patch = try JSONParser.parse(#"{"new": 2, "a": {"change": 2, "added": [1]}, "z": 1.0}"#)
        let merged = existing.merging(patch, arrays: .replace)
        XCTAssertEqual(merged.rendered(), """
        {
          "z": 1,
          "a": {
            "keep": true,
            "change": 2,
            "added": [
              1
            ]
          },
          "m": "x",
          "new": 2
        }

        """)
    }

    func testArrayReplaceAndUnion() throws {
        let existing = try JSONParser.parse(#"{"allow": ["Read", "Bash(git log:*)"], "objs": [{"a": 1, "b": 2}]}"#)
        let patch = try JSONParser.parse(#"{"allow": ["Edit", "Read"], "objs": [{"b": 2, "a": 1}, {"c": 3}]}"#)
        let replaced = try XCTUnwrap(existing.merging(patch, arrays: .replace).object)
        XCTAssertEqual(replaced["allow"], .array([.string("Edit"), .string("Read")]))

        let unioned = try XCTUnwrap(existing.merging(patch, arrays: .union).object)
        XCTAssertEqual(unioned["allow"], .array([.string("Read"), .string("Bash(git log:*)"), .string("Edit")]))
        guard case .array(let objects) = unioned["objs"] else { return XCTFail() }
        XCTAssertEqual(objects.count, 2, "an object with the same members in another order is already present")
    }

    func testMergingWhatIsAlreadyThereChangesNothing() throws {
        let existing = try JSONParser.parse(claudeSettingsFixture)
        let patch = try JSONParser.parse(#"{"model": "opus", "feedbackSurveyRate": 0, "permissions": {"allow": ["Read"]}}"#)
        XCTAssertEqual(existing.merging(patch, arrays: .union), existing)
        XCTAssertNotEqual(existing.merging(patch, arrays: .replace), existing, "replace shrinks the allow list")
    }

    func testYAMLConversion() throws {
        let yaml = try XCTUnwrap(try YAML.parse("""
        model: opus
        count: 3
        ratio: 0.5
        hex: 0x10
        quoted: "1"
        on: true
        none: null
        list: [a, 2]
        nested: {b: 1, a: 2}
        """))
        var problems: [String] = []
        let value = try XCTUnwrap(JSONValue.fromYAML(yaml, path: "", report: { problems.append($0) }))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(value.rendered(), """
        {
          "model": "opus",
          "count": 3,
          "ratio": 0.5,
          "hex": 16,
          "quoted": "1",
          "on": true,
          "none": null,
          "list": [
            "a",
            2
          ],
          "nested": {
            "b": 1,
            "a": 2
          }
        }

        """)
        let infinite = try XCTUnwrap(try YAML.parse("x: .inf"))
        XCTAssertNil(JSONValue.fromYAML(infinite, path: "", report: { problems.append($0) }))
        XCTAssertEqual(problems, ["'x' is .inf, which JSON cannot represent"])
    }
}
