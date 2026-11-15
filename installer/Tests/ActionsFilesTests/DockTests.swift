import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class DockTests: XCTestCase {
    let liveLayout = """
    - dock:
        apps:
          - Google Chrome
          - Spotify
          - Slack
          - {app: Aero Dogfood, fallback: Aero}
          - Herdr
          - Granola
        folders:
          - {path: ~/Developer, view: grid, display: folder, sort: name}
        settings:
          autohide: true
          tilesize: 128
          mineffect: scale
          show-recents: false
    """

    func dockPlist(_ harness: Harness) -> URL {
        harness.home.appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    }

    /// A sandbox Mac with the live laptop's apps (Aero, not Aero Dogfood) and the stock macOS Dock.
    func makeHarness() throws -> Harness {
        let harness = Harness()
        for app in ["Google Chrome", "Spotify", "Slack", "Aero", "Herdr", "Granola", "Safari"] {
            harness.fakeApp("Applications/\(app).app")
        }
        harness.fakeApp("System/Applications/Notes.app")
        harness.fakeApp("System/Applications/Utilities/Terminal.app")
        harness.fakeApp("home/Applications/Carbon.app")
        try FileManager.default.createDirectory(at: harness.url("home/Developer"), withIntermediateDirectories: true)
        try writePlist([
            "mod-count": .int(4),
            "version": .int(1),
            "persistent-apps": .array([
                dockOwnTile(harness.url("Applications/Safari.app"), label: "Safari"),
                .dict(["tile-data": .dict(["file-data": .dict(["_CFURLString": .string(harness.url("System/Applications/Notes.app").path), "_CFURLStringType": .int(0)])])]),
            ]),
            "persistent-others": .array([
                .dict(["tile-data": .dict([
                    "arrangement": .int(2), "displayas": .int(0), "showas": .int(1),
                    "file-data": .dict(["_CFURLString": .string("file://\(harness.home.path)/Downloads/"), "_CFURLStringType": .int(15)]),
                    "file-type": .int(2),
                ]), "tile-type": .string("directory-tile")]),
            ]),
        ], to: dockPlist(harness))
        return harness
    }

    /// A tile the way the Dock itself stores one after a restart: a percent-encoded file URL with a trailing
    /// slash, a bookmark, a bundle id and a GUID.
    func dockOwnTile(_ url: URL, label: String) -> PlistValue {
        .dict([
            "GUID": .int(Int.random(in: 1_000_000...9_999_999)),
            "tile-data": .dict([
                "book": .data(Data([1, 2, 3])),
                "bundle-identifier": .string("com.example.\(Naming.slug(label))"),
                "dock-extra": .bool(false),
                "file-data": .dict(["_CFURLString": .string(URL(fileURLWithPath: url.path, isDirectory: true).absoluteString), "_CFURLStringType": .int(15)]),
                "file-label": .string(label),
                "file-mod-date": .int(3_877_183_266),
                "file-type": .int(41),
            ]),
            "tile-type": .string("file-tile"),
        ])
    }

    func appPaths(_ values: [String: PlistValue]) -> [String] {
        (values["persistent-apps"]?.array ?? []).map { tile in
            if case .file(let path) = DockAction.identity(of: tile) { return path }
            return "?"
        }
    }

    func testBuildsTheLiveLayoutWithMinimalTiles() async throws {
        let harness = try makeHarness()
        let item = try harness.item(liveLayout)
        XCTAssertEqual(item.action.subtitle, "6 apps, 1 folder, 4 settings, nothing else")
        XCTAssertNeeded(await item.check())

        let outcome = try await item.run()
        XCTAssertEqual(outcome, .done("set up 6 apps, 1 folder"))
        let values = try readPlist(dockPlist(harness))
        let applications = harness.environment.applicationsDirectory
        XCTAssertEqual(appPaths(values), ["Google Chrome", "Spotify", "Slack", "Aero", "Herdr", "Granola"].map {
            applications.appendingPathComponent("\($0).app").path
        })
        XCTAssertEqual(values["persistent-apps"]?.array?.first, .dict([
            "tile-data": .dict([
                "file-data": .dict(["_CFURLString": .string(applications.appendingPathComponent("Google Chrome.app").path), "_CFURLStringType": .int(0)]),
                "file-label": .string("Google Chrome"),
                "file-type": .int(41),
            ]),
            "tile-type": .string("file-tile"),
        ]), "exactly the keys the research says to write: no book, bundle id, dates or GUID")
        XCTAssertEqual(values["persistent-others"], .array([.dict([
            "tile-data": .dict([
                "arrangement": .int(1),
                "directory": .int(1),
                "displayas": .int(1),
                "file-data": .dict(["_CFURLString": .string(harness.url("home/Developer").path), "_CFURLStringType": .int(0)]),
                "file-label": .string("Developer"),
                "file-type": .int(2),
                "showas": .int(2),
            ]),
            "tile-type": .string("directory-tile"),
        ])]), "the stock Downloads stack is gone and ~/Developer is a grid folder sorted by name")
        XCTAssertEqual(values["autohide"], .bool(true))
        XCTAssertEqual(values["tilesize"], .real(128))
        XCTAssertEqual(values["mineffect"], .string("scale"))
        XCTAssertEqual(values["show-recents"], .bool(false))
        XCTAssertEqual(values["mod-count"], .int(4), "keys the Dock owns are left alone")
        XCTAssertTrue(harness.logText.contains("Aero Dogfood is not installed; using Aero instead"), harness.logText)
        XCTAssertTrue(harness.logText.contains("sandbox: not restarting Dock"), harness.logText)

        XCTAssertSatisfied(await item.check())
        let before = harness.snapshot()
        await XCTAssertOutcome(try await item.run(), .done("Dock already set up"))
        XCTAssertEqual(harness.snapshot(), before)
    }

    func testStaysSatisfiedAfterTheDockRewritesItsTiles() async throws {
        let harness = try makeHarness()
        let item = try harness.item(liveLayout)
        try await item.run()
        var values = try readPlist(dockPlist(harness))
        let names = ["Google Chrome", "Spotify", "Slack", "Aero", "Herdr", "Granola"]
        values["persistent-apps"] = .array(names.map { dockOwnTile(harness.url("Applications/\($0).app"), label: $0) })
        values["persistent-others"] = .array([.dict([
            "GUID": .int(42),
            "tile-data": .dict([
                "arrangement": .int(1), "directory": .int(1), "displayas": .int(1), "showas": .int(2),
                "book": .data(Data([9])),
                "file-data": .dict(["_CFURLString": .string(URL(fileURLWithPath: harness.url("home/Developer").path, isDirectory: true).absoluteString),
                                    "_CFURLStringType": .int(15)]),
                "file-label": .string("Developer"), "file-type": .int(2),
            ]),
            "tile-type": .string("directory-tile"),
        ])])
        try writePlist(values, to: dockPlist(harness))
        XCTAssertTrue(names[0].contains(" "), "the percent-encoded name is part of what is being checked")
        XCTAssertSatisfied(await item.check())

        // Reordering is a change.
        var reordered = values
        reordered["persistent-apps"] = .array(names.reversed().map { dockOwnTile(harness.url("Applications/\($0).app"), label: $0) })
        try writePlist(reordered, to: dockPlist(harness))
        XCTAssertNeeded(await item.check())
        try await item.run()
        let rewritten = try readPlist(dockPlist(harness))
        XCTAssertEqual(rewritten["persistent-apps"]?.array?.first?.dict?["tile-data"]?.dict?["book"], .data(Data([1, 2, 3])),
                       "a tile the Dock already knows keeps its bookmark when it is only moved")
    }

    func testMissingAppsAreSkippedWithAWarningNotAnError() async throws {
        let harness = try makeHarness()
        let item = try harness.item("""
        - dock:
            apps: [Google Chrome, Not Installed, {app: Nope, fallback: [Also Nope]}]
            folders: [{path: ~/Nowhere}]
        """)
        await XCTAssertOutcome(try await item.run(), .done("set up 1 app, 0 folders (skipped 3 missing)"))
        XCTAssertTrue(harness.logs.contains { $0.style == .warning && $0.text == "Dock: skipping Not Installed is not installed" }, harness.logText)
        XCTAssertTrue(harness.logText.contains("Dock: skipping Nope or Also Nope is not installed"), harness.logText)
        XCTAssertTrue(harness.logText.contains("Dock: skipping folder ~/Nowhere does not exist"), harness.logText)
        XCTAssertEqual(appPaths(try readPlist(dockPlist(harness))), [harness.url("Applications/Google Chrome.app").path])
        XCTAssertSatisfied(await item.check(), "missing apps do not keep the item pending forever")
    }

    func testNamesResolveAcrossTheStandardFolders() async throws {
        let harness = try makeHarness()
        let item = try harness.item("""
        - dock:
            apps:
              - Notes                         # /System/Applications
              - Terminal                      # /System/Applications/Utilities
              - Carbon                        # ~/Applications
              - "{{applications}}/Slack.app"  # a path
              - ~/Applications/Carbon.app     # the same app again is listed once
        """)
        try await item.run()
        XCTAssertEqual(appPaths(try readPlist(dockPlist(harness))), [
            harness.url("System/Applications/Notes.app").path,
            harness.url("System/Applications/Utilities/Terminal.app").path,
            harness.url("home/Applications/Carbon.app").path,
            harness.url("Applications/Slack.app").path,
        ])
    }

    func testClearFalseKeepsWhatIsThere() async throws {
        let harness = try makeHarness()
        let item = try harness.item("""
        - dock:
            apps: [Safari, Herdr]
            folders: [{path: ~/Downloads, view: list, display: folder, sort: added}]
            clear: false
        """)
        try FileManager.default.createDirectory(at: harness.url("home/Downloads"), withIntermediateDirectories: true)
        try await item.run()
        let values = try readPlist(dockPlist(harness))
        XCTAssertEqual(appPaths(values), [
            harness.url("Applications/Safari.app").path,
            harness.url("System/Applications/Notes.app").path,
            harness.url("Applications/Herdr.app").path,
        ], "Safari was already there; Herdr is appended; Notes stays")
        let others = try XCTUnwrap(values["persistent-others"]?.array)
        XCTAssertEqual(others.count, 1, "the Downloads stack is replaced in place by the folder version")
        XCTAssertEqual(DockAction.identity(of: others[0]), .folder(path: harness.url("home/Downloads").path, view: 3, display: 1, sort: 2))
        XCTAssertSatisfied(await item.check())
    }

    func testDryRunChangesNothing() async throws {
        let harness = try makeHarness()
        let item = try harness.item(liveLayout)
        let before = harness.snapshot()
        await XCTAssertOutcome(try await item.run(dryRun: true), .done("would set up 6 apps, 1 folder"))
        XCTAssertEqual(harness.snapshot(), before)
        XCTAssertTrue(harness.logText.contains("[dry-run] update ~/Library/Preferences/com.apple.dock.plist"), harness.logText)
        XCTAssertTrue(harness.logText.contains("Dock apps: Google Chrome, Spotify, Slack, Aero, Herdr, Granola"), harness.logText)
    }

    func testWaitsForAFreshDockToSetItselfUp() async throws {
        let harness = try makeHarness()
        let item = try harness.item(liveLayout)
        let context = harness.context(item)
        let store = PlistFileStore(environment: harness.environment, files: context.files)

        let ready = try await DockAction.waitForDockSetup(store: store, current: ["mod-count": .int(5)], timeout: 5, context: context)
        XCTAssertEqual(ready, ["mod-count": .int(5)])
        XCTAssertFalse(harness.logText.contains("waiting"))

        var values = try readPlist(dockPlist(harness))
        values["mod-count"] = .int(0)
        try writePlist(values, to: dockPlist(harness))
        let started = Date()
        let latest = try await DockAction.waitForDockSetup(store: store, current: values, timeout: 0.6, context: context)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(latest["mod-count"], .int(0))
        XCTAssertTrue(harness.logText.contains("waiting for the Dock to finish setting itself up"))
    }

    func testParseErrors() throws {
        let harness = Harness()
        let notMap = try harness.problems("- dock: [Safari]")
        XCTAssertTrue(notMap.contains { $0.contains("'dock' must be a mapping") }, "\(notMap)")

        let siblings = try harness.problems("""
        - dock:
          apps: [Safari]
        """)
        XCTAssertTrue(siblings.contains { $0.contains("indent 'apps:'") }, "\(siblings)")
        XCTAssertFalse(siblings.contains { $0.contains("unknown key") }, "\(siblings)")

        let empty = try harness.problems("- dock: {clear: true}")
        XCTAssertTrue(empty.contains { $0.contains("needs at least one of 'apps:'") }, "\(empty)")

        let bad = try harness.problems("""
        - dock:
            apps: [[Safari]]
            folders: [{path: ~/Developer, view: tiles}]
            settings: {persistent-apps: []}
            clr: false
        """)
        XCTAssertTrue(bad.contains { $0.contains("'apps' entry 1 must be an app name") }, "\(bad)")
        XCTAssertTrue(bad.contains { $0.contains("'view' must be one of: auto, fan, grid, list") }, "\(bad)")
        XCTAssertTrue(bad.contains { $0.contains("set 'persistent-apps' with 'apps:'") }, "\(bad)")
        XCTAssertTrue(bad.contains { $0.contains("unknown key 'clr' (expected: apps, clear, folders, settings)") }, "\(bad)")

        let entry = try harness.problems("""
        - dock:
            apps: [{fallback: Aero}]
        """)
        XCTAssertTrue(entry.contains { $0.contains("missing required key 'app'") }, "\(entry)")
    }

    /// Like macOS 13+: `/Applications/Safari.app` is a link into the Safari cryptex (itself reached through
    /// another link), and the Dock's own Safari tile names the cryptex path.
    func makeCryptexHarness() throws -> (harness: Harness, safariTile: PlistValue) {
        let harness = Harness()
        let fileManager = FileManager.default
        harness.fakeApp("System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")
        harness.fakeApp("System/Applications/Notes.app")
        try fileManager.createDirectory(at: harness.url("System/Cryptexes"), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: harness.url("System/Cryptexes/App").path, withDestinationPath: "../../System/Volumes/Preboot/Cryptexes/App")
        try fileManager.createSymbolicLink(atPath: harness.url("Applications/Safari.app").path, withDestinationPath: "../System/Cryptexes/App/System/Applications/Safari.app")
        let safariTile = dockOwnTile(harness.url("System/Cryptexes/App/System/Applications/Safari.app"), label: "Safari")
        try writePlist([
            "mod-count": .int(4),
            "persistent-apps": .array([safariTile, dockOwnTile(harness.url("System/Applications/Notes.app"), label: "Notes")]),
        ], to: dockPlist(harness))
        return (harness, safariTile)
    }

    func testAnAppReachedThroughALinkMatchesTheDocksOwnTile() async throws {
        let (harness, safariTile) = try makeCryptexHarness()
        let keep = try harness.item("""
        - dock:
            apps: [Safari]
            clear: false
        """)
        XCTAssertSatisfied(await keep.check(), "the Dock's cryptex Safari tile is the Safari the config names")
        let before = harness.snapshot()
        await XCTAssertOutcome(try await keep.run(), .done("Dock already set up"))
        XCTAssertEqual(harness.snapshot(), before, "no second Safari tile")

        let clear = try harness.item("""
        - dock:
            apps: [Safari]
        """)
        XCTAssertNeeded(await clear.check(), "Notes has to go")
        try await clear.run()
        XCTAssertEqual(try readPlist(dockPlist(harness))["persistent-apps"], .array([safariTile]),
                       "the Dock's own Safari tile (bundle id, bookmark) is kept, not swapped for a fresh one")
        XCTAssertSatisfied(await clear.check())
    }

    func testANewTileForALinkedAppKeepsThePathAsFound() async throws {
        let (harness, _) = try makeCryptexHarness()
        try writePlist(["mod-count": .int(4), "persistent-apps": .array([])], to: dockPlist(harness))
        let item = try harness.item("""
        - dock:
            apps: [Safari, Notes]
        """)
        try await item.run()
        let tiles = try XCTUnwrap(try readPlist(dockPlist(harness))["persistent-apps"]?.array)
        XCTAssertEqual(tiles.first?.dict?["tile-data"]?.dict?["file-data"]?.dict?["_CFURLString"], .string(harness.url("Applications/Safari.app").path))
        XCTAssertSatisfied(await item.check())
    }

    /// `{app: Aero Dogfood, fallback: Aero}` on a Mac that has both and already shows Aero: the Dock keeps Aero.
    func testWhenSeveralCandidatesAreInstalledTheOneInTheDockStays() async throws {
        let harness = try makeHarness()
        harness.fakeApp("Applications/Aero Dogfood.app")
        let aeroTile = dockOwnTile(harness.url("Applications/Aero.app"), label: "Aero")
        try writePlist([
            "mod-count": .int(4),
            "persistent-apps": .array([dockOwnTile(harness.url("Applications/Google Chrome.app"), label: "Google Chrome"), aeroTile]),
        ], to: dockPlist(harness))
        let item = try harness.item("""
        - dock:
            apps:
              - Google Chrome
              - {app: Aero Dogfood, fallback: Aero}
        """)
        XCTAssertSatisfied(await item.check())
        let before = harness.snapshot()
        await XCTAssertOutcome(try await item.run(), .done("Dock already set up"))
        XCTAssertEqual(harness.snapshot(), before)

        // Something else changes; the Aero tile still stays (with its bookmark) and the log says why.
        try writePlist(["mod-count": .int(4), "persistent-apps": .array([aeroTile])], to: dockPlist(harness))
        try await item.run()
        XCTAssertEqual(try readPlist(dockPlist(harness))["persistent-apps"]?.array?.last, aeroTile)
        XCTAssertTrue(harness.logText.contains("keeping Aero, which is already in the Dock (Aero Dogfood is installed too)"), harness.logText)

        // Neither build in the Dock yet: the first installed one wins, as before.
        try writePlist(["mod-count": .int(4), "persistent-apps": .array([])], to: dockPlist(harness))
        try await item.run()
        XCTAssertEqual(appPaths(try readPlist(dockPlist(harness))), [
            harness.url("Applications/Google Chrome.app").path,
            harness.url("Applications/Aero Dogfood.app").path,
        ])
    }

    func testThePreviousLayoutIsSavedAndLoggedBeforeItIsReplaced() async throws {
        let harness = try makeHarness()
        let original = try readPlist(dockPlist(harness))
        let item = try harness.item(liveLayout)
        let saved = harness.environment.backupDirectory.appendingPathComponent("Library/Preferences/com.apple.dock.plist")

        try await item.run(dryRun: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path), "a dry run saves nothing")
        XCTAssertTrue(harness.logText.contains("Dock apps were: Safari, Notes"), harness.logText)

        harness.events.reset()
        try await item.run()
        XCTAssertEqual(try readPlist(saved), original, "the whole com.apple.dock domain as it was, ready for 'defaults import'")
        XCTAssertTrue(harness.logText.contains("Dock apps were: Safari, Notes"), harness.logText)
        XCTAssertTrue(harness.logText.contains("Dock folders were: ~/Downloads"), harness.logText)
        XCTAssertTrue(harness.logText.contains("saved the previous Dock to ~/.shawn/backups/\(harness.environment.runID)/Library/Preferences/com.apple.dock.plist"),
                      harness.logText)

        // A second Dock item in the same run keeps the first copy: that one is the Dock from before the run.
        var changed = try readPlist(dockPlist(harness))
        changed["autohide"] = .bool(false)
        try writePlist(changed, to: dockPlist(harness))
        try await item.run()
        XCTAssertEqual(try readPlist(saved), original)
    }

    func testTileIdentityNormalizesBothSpellings() {
        let plain = PlistValue.dict(["tile-data": .dict(["file-data": .dict(["_CFURLString": .string("/Applications/Google Chrome.app"), "_CFURLStringType": .int(0)])])])
        let url = PlistValue.dict(["tile-data": .dict(["file-data": .dict(["_CFURLString": .string("file:///Applications/Google%20Chrome.app/"), "_CFURLStringType": .int(15)])]),
                                   "tile-type": .string("file-tile")])
        XCTAssertEqual(DockAction.identity(of: plain), .file("/Applications/Google Chrome.app"))
        XCTAssertEqual(DockAction.identity(of: plain), DockAction.identity(of: url))
        XCTAssertEqual(DockAction.identity(of: .dict(["tile-type": .string("spacer-tile"), "tile-data": .dict([:])])), .other("spacer-tile"))
    }
}
