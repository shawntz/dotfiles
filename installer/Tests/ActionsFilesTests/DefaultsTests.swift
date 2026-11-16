import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class DefaultsTests: XCTestCase {
    func preferences(_ harness: Harness, _ name: String) -> URL {
        harness.home.appendingPathComponent("Library/Preferences/\(name).plist")
    }

    func testWritesTypedValuesIntoTheDomainPlist() async throws {
        let harness = Harness()
        try writePlist(["unrelated": .string("keep"), "autohide": .int(0)], to: preferences(harness, "com.apple.dock"))
        let item = try harness.item("""
        - defaults: com.apple.dock
          set:
            autohide: true
            tilesize: 128
            largesize: {type: int, value: 64}
            autohide-time-modifier: 0.15
            mineffect: scale
            persistent-others: []
            extra: {nested: {deep: [1, two]}}
          restart: [Dock]
        """)
        XCTAssertNeeded(await item.check())
        let outcome = try await item.run()
        XCTAssertEqual(outcome, .done("set 7 keys in com.apple.dock"))

        let values = try readPlist(preferences(harness, "com.apple.dock"))
        XCTAssertEqual(values["autohide"], .bool(true), "an int 0 already there is replaced by a real bool")
        XCTAssertEqual(values["tilesize"], .real(128), "tilesize is a float even when written as 128")
        XCTAssertEqual(values["largesize"], .int(64), "an explicit type wins over the hint")
        XCTAssertEqual(values["autohide-time-modifier"], .real(0.15))
        XCTAssertEqual(values["mineffect"], .string("scale"))
        XCTAssertEqual(values["persistent-others"], .array([]))
        XCTAssertEqual(values["extra"], .dict(["nested": .dict(["deep": .array([.int(1), .string("two")])])]))
        XCTAssertEqual(values["unrelated"], .string("keep"))

        let raw = try PropertyListSerialization.propertyList(from: Data(contentsOf: preferences(harness, "com.apple.dock")), format: nil) as? [String: Any]
        let tilesize = try XCTUnwrap(raw?["tilesize"] as? NSNumber)
        XCTAssertTrue(CFNumberIsFloatType(tilesize), "stored as <real>")
        XCTAssertEqual(CFGetTypeID(try XCTUnwrap(raw?["autohide"] as? NSNumber)), CFBooleanGetTypeID(), "stored as <true/>")

        XCTAssertTrue(harness.logText.contains("com.apple.dock autohide: 0 → true"), harness.logText)
        XCTAssertTrue(harness.logText.contains("sandbox: not restarting Dock"), harness.logText)

        XCTAssertSatisfied(await item.check())
        harness.events.reset()
        await XCTAssertOutcome(try await item.run(), .done("already set"))
        XCTAssertFalse(harness.logText.contains("restarting"), "nothing changed, so nothing restarts")
    }

    /// `defaults write … -float 0.15` stores 0.15000000596046448. A key left like that (by an earlier run or by
    /// other dotfiles) is set: no rewrite, no Dock restart, every run.
    func testRealsStoredAtSinglePrecisionCountAsSet() async throws {
        let harness = Harness()
        try writePlist([
            "autohide-delay": .real(Double(Float(0.1))),
            "autohide-time-modifier": .real(Double(Float(0.15))),
            "tilesize": .real(128),
        ], to: preferences(harness, "com.apple.dock"))
        let item = try harness.item("""
        - defaults: com.apple.dock
          set: {autohide-delay: 0.1, autohide-time-modifier: 0.15, tilesize: 128}
          restart: [Dock]
        """)
        XCTAssertSatisfied(await item.check())
        let before = harness.snapshot()
        await XCTAssertOutcome(try await item.run(), .done("already set"))
        XCTAssertEqual(harness.snapshot(), before)
        XCTAssertFalse(harness.logText.contains("restarting"), harness.logText)

        let changed = try harness.item("""
        - defaults: com.apple.dock
          set: {autohide-time-modifier: 0.2}
        """)
        XCTAssertNeeded(await changed.check(), "a different value is still a change")
    }

    func testGlobalDomainAndCurrentHost() async throws {
        let harness = Harness()
        let global = try harness.item("""
        - defaults: -g
          set: {KeyRepeat: 1, ApplePressAndHoldEnabled: false, com.apple.sound.beep.volume: 0}
        """)
        try await global.run()
        XCTAssertEqual(try readPlist(preferences(harness, ".GlobalPreferences")),
                       ["KeyRepeat": .int(1), "ApplePressAndHoldEnabled": .bool(false), "com.apple.sound.beep.volume": .real(0)])

        let host = try harness.item("""
        - defaults: com.apple.controlcenter
          current_host: true
          set: {Battery: 18}
        """)
        XCTAssertEqual(host.action.title, "com.apple.controlcenter (this Mac)")
        try await host.run()
        let byHost = harness.home.appendingPathComponent("Library/Preferences/ByHost/com.apple.controlcenter.\(HostIdentity.uuid).plist")
        XCTAssertEqual(try readPlist(byHost), ["Battery": .int(18)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences(harness, "com.apple.controlcenter").path))
    }

    func testVariablesExpandInStringValues() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - defaults: com.apple.screencapture
          set: {location: "{{home}}/Pictures/Screenshots", name: "{{full_name}}"}
        """)
        try await item.run()
        XCTAssertEqual(try readPlist(preferences(harness, "com.apple.screencapture")),
                       ["location": .string("\(harness.home.path)/Pictures/Screenshots"), "name": .string("Shawn Tester")])
        XCTAssertSatisfied(await item.check())
    }

    func testAPathDomainWithSudoStaysInsideTheSandbox() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - defaults: /Library/Preferences/com.apple.loginwindow
          set: {LoginwindowText: "Found this Mac? Call {{full_name}}"}
          sudo: true
        """)
        XCTAssertEqual(item.action.sudo, .always)
        try await item.run()
        XCTAssertEqual(try readPlist(harness.url("Library/Preferences/com.apple.loginwindow.plist")),
                       ["LoginwindowText": .string("Found this Mac? Call Shawn Tester")])
    }

    func testDryRunWritesNothing() async throws {
        let harness = Harness()
        let item = try harness.item("""
        - defaults: com.apple.finder
          set: {ShowPathbar: true}
          restart: [Finder]
        """)
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would set 1 key in com.apple.finder"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences(harness, "com.apple.finder").path))
        XCTAssertTrue(harness.logText.contains("[dry-run] write ~/Library/Preferences/com.apple.finder.plist"), harness.logText)
    }

    func testParseErrors() throws {
        let harness = Harness()
        let missing = try harness.problems("- defaults: com.apple.dock")
        XCTAssertTrue(missing.contains { $0.contains("missing required key 'set'") }, "\(missing)")

        let notMap = try harness.problems("""
        - defaults: com.apple.dock
          set: [autohide]
        """)
        XCTAssertTrue(notMap.contains { $0.contains("'set' must be a mapping") }, "\(notMap)")

        let null = try harness.problems("""
        - defaults: com.apple.dock
          set: {autohide: ~}
        """)
        XCTAssertTrue(null.contains { $0.contains("'set.autohide' has no value") }, "\(null)")

        let badType = try harness.problems("""
        - defaults: com.apple.dock
          set: {tilesize: {type: decimal, value: 1}}
        """)
        XCTAssertTrue(badType.contains { $0.contains("'set.tilesize.type' must be one of bool, int, float, string") }, "\(badType)")

        let restart = try harness.problems("""
        - defaults: com.apple.dock
          set: {autohide: true}
          restart: [/usr/bin/Dock]
        """)
        XCTAssertTrue(restart.contains { $0.contains("'restart' takes process names") }, "\(restart)")

        let typo = try harness.problems("""
        - defaults: com.apple.dock
          set: {autohide: true}
          currenthost: true
        """)
        XCTAssertTrue(typo.contains { $0.contains("Did you mean 'current_host'") }, "\(typo)")

        let unknownVariable = try harness.problems("""
        - defaults: com.apple.screencapture
          set: {location: "{{pictures}}/x"}
        """)
        XCTAssertTrue(unknownVariable.contains { $0.contains("'set.location' uses unknown variable {{pictures}}") }, "\(unknownVariable)")
    }

    func testAnUnreadableDomainIsReportedByCheckAndRun() async throws {
        let harness = Harness()
        harness.directory.write("home/Library/Preferences/com.apple.dock.plist", "garbage")
        let item = try harness.item("""
        - defaults: com.apple.dock
          set: {autohide: true}
        """)
        let check = await item.check()
        guard case .needed(let reason?) = check else { return XCTFail("\(check)") }
        XCTAssertTrue(reason.contains("could not read com.apple.dock"), reason)
        await XCTAssertThrowsActionError { try await item.run() }
    }
}
