import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class PlistValueTests: XCTestCase {
    func testFoundationTypesAreToldApart() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>b</key><true/>
          <key>i</key><integer>1</integer>
          <key>r</key><real>128</real>
          <key>s</key><string>scale</string>
          <key>a</key><array><integer>1</integer><false/></array>
          <key>d</key><dict><key>k</key><real>0.5</real></dict>
          <key>data</key><data>AAE=</data>
        </dict></plist>
        """
        let values = try PlistValue.decodeDictionary(Data(xml.utf8))
        XCTAssertEqual(values["b"], .bool(true))
        XCTAssertEqual(values["i"], .int(1))
        XCTAssertEqual(values["r"], .real(128))
        XCTAssertEqual(values["s"], .string("scale"))
        XCTAssertEqual(values["a"], .array([.int(1), .bool(false)]))
        XCTAssertEqual(values["d"], .dict(["k": .real(0.5)]))
        XCTAssertEqual(values["data"], .data(Data([0, 1])))
        XCTAssertNotEqual(PlistValue.bool(true), .int(1))
        XCTAssertNotEqual(PlistValue.int(128), .real(128))
    }

    func testEncodingKeepsTypes() throws {
        let data = try PlistValue.encode(["b": .bool(false), "r": .real(128), "i": .int(5)], format: .xml)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("<key>b</key>\n\t<false/>"), text)
        XCTAssertTrue(text.contains("<key>r</key>\n\t<real>128</real>"), text)
        XCTAssertTrue(text.contains("<key>i</key>\n\t<integer>5</integer>"), text)
    }

    func testYAMLConversionAndForcedTypes() throws {
        func convert(_ text: String) -> (PlistValue?, [String]) {
            var problems: [String] = []
            let yaml = try! YAML.parse("v: \(text)")!.map!["v"]!
            return (PlistYAML.value(yaml, path: "set.v", report: { problems.append($0) }), problems)
        }
        XCTAssertEqual(convert("true").0, .bool(true))
        XCTAssertEqual(convert("1").0, .int(1))
        XCTAssertEqual(convert("0.5").0, .real(0.5))
        XCTAssertEqual(convert("Nlsv").0, .string("Nlsv"))
        XCTAssertEqual(convert("\"1\"").0, .string("1"))
        XCTAssertEqual(convert("[a, 1]").0, .array([.string("a"), .int(1)]))
        XCTAssertEqual(convert("{x: 1}").0, .dict(["x": .int(1)]))
        XCTAssertEqual(convert("{type: float, value: 128}").0, .real(128))
        XCTAssertEqual(convert("{value: 1, type: bool}").0, .bool(true))
        XCTAssertEqual(convert("{type: int, value: \"7\"}").0, .int(7))
        XCTAssertEqual(convert("{type: string, value: 0644}").0, .string("0644"))
        XCTAssertEqual(convert("~").1, ["'set.v' has no value (preferences cannot store null)"])
        XCTAssertEqual(convert("{type: double, value: 1}").1, ["'set.v.type' must be one of bool, int, float, string"])
        XCTAssertEqual(convert("{type: int, value: lots}").1, ["'set.v.value' (lots) is not a valid int"])
        XCTAssertEqual(convert("{type: bool, value: [1]}").1, ["'set.v.value' must be a single value"])
    }

    func testFloatHints() throws {
        let plain = try XCTUnwrap(YAML.parse("128"))
        let forced = try XCTUnwrap(YAML.parse("{type: int, value: 128}"))
        XCTAssertEqual(PlistYAML.applyingTypeHint(.int(128), domain: "com.apple.dock", key: "tilesize", yaml: plain), .real(128))
        XCTAssertEqual(PlistYAML.applyingTypeHint(.int(128), domain: "com.apple.dock", key: "tilesize", yaml: forced), .int(128))
        XCTAssertEqual(PlistYAML.applyingTypeHint(.int(1), domain: "NSGlobalDomain", key: "KeyRepeat", yaml: plain), .int(1))
        XCTAssertEqual(PlistYAML.applyingTypeHint(.int(0), domain: "NSGlobalDomain", key: "com.apple.sound.beep.volume", yaml: plain), .real(0))
    }

    func testRealsCompareAtTheSinglePrecisionMacOSStores() {
        func differs(_ current: PlistValue, _ wanted: PlistValue) -> Bool {
            !Preferences.differences(current: ["k": current], wanted: [("k", wanted)]).isEmpty
        }
        XCTAssertFalse(differs(.real(0.15000000596046448), .real(0.15)))
        XCTAssertFalse(differs(.real(Double(Float(0.001))), .real(0.001)))
        XCTAssertFalse(differs(.array([.real(Double(Float(0.1)))]), .array([.real(0.1)])), "inside arrays too")
        XCTAssertFalse(differs(.dict(["d": .real(Double(Float(0.2)))]), .dict(["d": .real(0.2)])), "and dictionaries")
        XCTAssertTrue(differs(.real(0.15), .real(0.16)))
        XCTAssertTrue(differs(.real(1e300), .real(2e300)), "values a Float cannot hold compare exactly")
        XCTAssertTrue(differs(.int(1), .real(1)), "types still count")
        XCTAssertTrue(differs(.array([.real(0.1)]), .array([.real(0.1), .real(0.1)])))
        XCTAssertTrue(differs(.dict(["a": .real(0.1)]), .dict(["b": .real(0.1)])))
    }

    /// The single-precision allowance is for values a `-float` write left behind, and those are always exactly a
    /// Float. A full double that some app wrote is not one, so a different value is a change even when both sides
    /// round to the same Float.
    func testAFullPrecisionRealThatDiffersIsNotAlreadySet() {
        func differs(_ current: Double, _ wanted: Double) -> Bool {
            !Preferences.differences(current: ["k": .real(current)], wanted: [("k", .real(wanted))]).isEmpty
        }
        XCTAssertEqual(Float(1_700_000_060), Float(1_700_000_000), "the two round to the same Float")
        XCTAssertTrue(differs(1_700_000_060, 1_700_000_000), "60 apart, and 1_700_000_060 cannot have come from a -float write")
        XCTAssertTrue(differs(16_777_217, 16_777_216), "2^24 + 1 is not a Float")
        XCTAssertTrue(differs(0.30000000000000004, 0.3), "a double one ulp away is still a different double")
        XCTAssertFalse(differs(Double(Float(0.15)), 0.15), "what -float 0.15 leaves is still already set")
        XCTAssertFalse(differs(16_777_216, 16_777_217), "a Float-shaped value is what -float 16777217 would leave")
        XCTAssertTrue(differs(Double(Float(0.15)), 0.16), "a Float-shaped value that rounds elsewhere is a change")
    }

    func testDomains() {
        XCTAssertEqual(PreferenceDomain("-g").name, "NSGlobalDomain")
        XCTAssertTrue(PreferenceDomain("-globalDomain").isGlobal)
        XCTAssertEqual(PreferenceDomain("com.apple.dock", currentHost: true).hostArguments, ["-currentHost"])
        XCTAssertTrue(PreferenceDomain("/Library/Preferences/com.apple.loginwindow").isPath)
    }
}

final class PlistFileStoreTests: XCTestCase {
    func testFileLocationsMirrorMacOS() {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let store = PlistFileStore(environment: environment, files: FileOps(environment: environment))
        let preferences = environment.home.appendingPathComponent("Library/Preferences")
        XCTAssertEqual(store.url(for: PreferenceDomain("com.apple.dock")), preferences.appendingPathComponent("com.apple.dock.plist"))
        XCTAssertEqual(store.url(for: PreferenceDomain("NSGlobalDomain")), preferences.appendingPathComponent(".GlobalPreferences.plist"))
        XCTAssertEqual(store.url(for: PreferenceDomain("com.apple.controlcenter", currentHost: true)),
                       preferences.appendingPathComponent("ByHost/com.apple.controlcenter.\(HostIdentity.uuid).plist"))
        XCTAssertEqual(store.url(for: PreferenceDomain("/Library/Preferences/com.apple.loginwindow")),
                       directory.url.appendingPathComponent("Library/Preferences/com.apple.loginwindow.plist"),
                       "system paths are re-rooted inside the sandbox")
        let inside = environment.home.appendingPathComponent("prefs/custom.plist").path
        XCTAssertEqual(store.url(for: PreferenceDomain(inside)).path, inside)
        XCTAssertEqual(HostIdentity.uuid.count, 36)
    }

    func testWriteKeepsOtherKeysAndTypes() async throws {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let store = PlistFileStore(environment: environment, files: FileOps(environment: environment))
        let domain = PreferenceDomain("com.example.app")
        try writePlist(["keep": .string("me"), "flag": .int(1)], to: store.url(for: domain))
        try await store.write([PreferenceChange(key: "flag", value: .bool(true)), PreferenceChange(key: "size", value: .real(64))], to: domain, asRoot: false)
        let values = try await store.read(domain)
        XCTAssertEqual(values, ["keep": .string("me"), "flag": .bool(true), "size": .real(64)])
        let missing = try await store.read(PreferenceDomain("com.example.missing"))
        XCTAssertEqual(missing, [:])
    }

    func testCorruptFileIsAClearError() async throws {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let store = PlistFileStore(environment: environment, files: FileOps(environment: environment))
        directory.write("home/Library/Preferences/com.example.bad.plist", "not a plist")
        do {
            _ = try await store.read(PreferenceDomain("com.example.bad"))
            XCTFail("expected an error")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.contains("is not a valid preferences file"), error.message)
        }
    }

    func testDryRunWritesNothing() async throws {
        let directory = TempDirectory()
        let environment = SystemEnvironment.testSandbox(directory)
        let lines = Recorder<LogLine>()
        let store = PlistFileStore(environment: environment, files: FileOps(environment: environment, dryRun: true, log: { lines.add($0) }))
        try await store.write([PreferenceChange(key: "a", value: .bool(true))], to: PreferenceDomain("com.example.app"), asRoot: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: PreferenceDomain("com.example.app")).path))
        XCTAssertTrue(lines.all.contains { $0.text.hasPrefix("[dry-run] write ~/Library/Preferences/com.example.app.plist") })
    }
}

/// The real-Mac store, driven against a stand-in `defaults` that records its arguments.
final class DefaultsCommandStoreTests: XCTestCase {
    struct Fixture {
        let harness = Harness()
        let lines = Recorder<LogLine>()
        let shim: URL

        init(currentDomain: [String: PlistValue] = ["autohide": .bool(false), "mod-count": .int(12), "keep": .string("me")],
             failWrites: Bool = false) throws {
            shim = harness.shim("defaults", body: """
            dir="$(dirname "$0")"
            [ "$1" = "-currentHost" ] && shift
            case "$1" in
              export) if [ "$3" = "-" ]; then cat "$dir/domain.plist"; else cp "$dir/domain.plist" "$3"; fi ;;
              import) cat > "$dir/imported.plist" ;;
              write) \(failWrites ? "echo 'Could not write domain' >&2; exit 1" : "exit 0") ;;
              *) echo "unexpected verb $1" >&2; exit 2 ;;
            esac
            """)
            try writePlist(currentDomain, to: shim.deletingLastPathComponent().appendingPathComponent("domain.plist"))
        }

        func store(dryRun: Bool = false) -> DefaultsCommandStore {
            let lines = self.lines
            let runner = CommandRunner(environment: harness.environment, dryRun: dryRun, sink: { lines.add($0) })
            return DefaultsCommandStore(commands: runner, executable: shim.path, temporaryDirectory: harness.environment.temporaryDirectory)
        }

        var calls: [String] { harness.shimCalls("defaults") }
    }

    func testReadsTheExportedDomainWithTypes() async throws {
        let fixture = try Fixture(currentDomain: ["tilesize": .real(128), "autohide": .bool(true), "mod-count": .int(330)])
        let values = try await fixture.store().read(PreferenceDomain("com.apple.dock"))
        XCTAssertEqual(values, ["tilesize": .real(128), "autohide": .bool(true), "mod-count": .int(330)])
        XCTAssertEqual(fixture.calls, ["[export][com.apple.dock][-]"])
        _ = try await fixture.store().read(PreferenceDomain("com.apple.controlcenter", currentHost: true))
        XCTAssertEqual(fixture.calls.last, "[-currentHost][export][com.apple.controlcenter][-]")
    }

    func testScalarsAreWrittenWithTypedFlags() async throws {
        let fixture = try Fixture()
        try await fixture.store().write([
            PreferenceChange(key: "autohide", value: .bool(true)),
            PreferenceChange(key: "tilesize", value: .real(128)),
            PreferenceChange(key: "autohide-time-modifier", value: .real(0.15)),
            PreferenceChange(key: "wvous-br-corner", value: .int(14)),
            PreferenceChange(key: "mineffect", value: .string("scale")),
        ], to: PreferenceDomain("com.apple.dock"), asRoot: false)
        // Reals go in as a property-list value: `-float` would keep only single precision.
        XCTAssertEqual(fixture.calls, [
            "[write][com.apple.dock][autohide][-bool][true]",
            "[write][com.apple.dock][tilesize][<real>128</real>]",
            "[write][com.apple.dock][autohide-time-modifier][<real>0.15</real>]",
            "[write][com.apple.dock][wvous-br-corner][-int][14]",
            "[write][com.apple.dock][mineffect][-string][scale]",
        ])
        XCTAssertTrue(fixture.lines.all.contains { $0.text == "$ defaults write com.apple.dock autohide -bool true" }, "commands are logged")
        XCTAssertTrue(fixture.lines.all.contains { $0.text == "$ defaults write com.apple.dock autohide-time-modifier '<real>0.15</real>'" },
                      fixture.lines.all.map(\.text).joined(separator: "\n"))

        try await fixture.store().write([PreferenceChange(key: "Battery", value: .int(18))],
                                        to: PreferenceDomain("com.apple.controlcenter", currentHost: true), asRoot: false)
        XCTAssertEqual(fixture.calls.last, "[-currentHost][write][com.apple.controlcenter][Battery][-int][18]")
    }

    /// A stand-in `defaults` that stores values the way the real tool does, for a round trip without touching
    /// cfprefsd: `write d k -float 0.15` keeps only single precision (it reads back as 0.15000000596046448, checked
    /// against /usr/bin/defaults on a scratch path domain), while a property-list value such as
    /// `'<real>0.15</real>'` is kept as the double it spells. `plutil` edits the stand-in's domain file.
    struct StoringDefaults {
        let harness = Harness()
        let shim: URL

        /// `floats` lists the values a `-float` write may receive, so the stand-in can store their single-precision form.
        init(floats: [Double]) throws {
            let singlePrecision = floats.map { "      \(PlistValue.format($0))) value='\(String(Double(Float($0))))' ;;" }
            shim = harness.shim("defaults", body: """
            plist="$(dirname "$0")/domain.plist"
            [ "$1" = "-currentHost" ] && shift
            case "$1" in
              export) if [ "$3" = "-" ]; then /usr/bin/plutil -convert xml1 -o - "$plist"; else cp "$plist" "$3"; fi ;;
              write)
                case "$4" in
                  -float)
                    case "$5" in
            \(singlePrecision.joined(separator: "\n"))
                      *) echo "the stand-in has no single-precision value for $5" >&2; exit 9 ;;
                    esac
                    /usr/bin/plutil -replace "$3" -xml "<real>$value</real>" "$plist" ;;
                  -bool) /usr/bin/plutil -replace "$3" -bool "$5" "$plist" ;;
                  -int) /usr/bin/plutil -replace "$3" -integer "$5" "$plist" ;;
                  -string) /usr/bin/plutil -replace "$3" -string "$5" "$plist" ;;
                  *) /usr/bin/plutil -replace "$3" -xml "$4" "$plist" ;;
                esac ;;
              *) echo "unexpected verb $1" >&2; exit 2 ;;
            esac
            """)
            try writePlist([:], to: shim.deletingLastPathComponent().appendingPathComponent("domain.plist"))
        }

        func store() -> DefaultsCommandStore {
            DefaultsCommandStore(commands: CommandRunner(environment: harness.environment), executable: shim.path,
                                 temporaryDirectory: harness.environment.temporaryDirectory)
        }
    }

    func testRealsRoundTripAsTheDoublesTheConfigSpells() async throws {
        let fixture = try StoringDefaults(floats: [0.1, 0.15, 128])
        let store = fixture.store()
        let domain = PreferenceDomain("com.apple.dock")
        let wanted: [(key: String, value: PlistValue)] = [("autohide-delay", .real(0.1)), ("autohide-time-modifier", .real(0.15)), ("tilesize", .real(128))]

        let changes = Preferences.differences(current: try await store.read(domain), wanted: wanted)
        XCTAssertEqual(changes.map(\.key), ["autohide-delay", "autohide-time-modifier", "tilesize"])
        try await store.write(changes, to: domain, asRoot: false)
        let stored = try await store.read(domain)
        XCTAssertEqual(stored["autohide-time-modifier"], .real(0.15), "stored as the double 0.15, not 0.15000000596046448")
        XCTAssertEqual(stored["autohide-delay"], .real(0.1))
        XCTAssertEqual(stored["tilesize"], .real(128))
        XCTAssertEqual(Preferences.differences(current: stored, wanted: wanted), [], "the next check has nothing to do")
    }

    func testAKeyAnEarlierFloatWriteLeftBehindIsAlreadySet() async throws {
        let fixture = try StoringDefaults(floats: [0.15])
        let runner = CommandRunner(environment: fixture.harness.environment)
        try await runner.runChecked(Command(fixture.shim.path, ["write", "com.apple.dock", "autohide-time-modifier", "-float", "0.15"]))
        let stored = try await fixture.store().read(PreferenceDomain("com.apple.dock"))
        XCTAssertEqual(stored["autohide-time-modifier"], .real(Double(Float(0.15))), "the stand-in keeps single precision, like the real tool")
        XCTAssertEqual(Preferences.differences(current: stored, wanted: [("autohide-time-modifier", .real(0.15))]), [])
    }

    func testArraysGoThroughExportAndImportKeepingEveryOtherKey() async throws {
        let fixture = try Fixture()
        let tile = PlistValue.dict(["tile-type": .string("file-tile")])
        try await fixture.store().write([
            PreferenceChange(key: "persistent-apps", value: .array([tile])),
            PreferenceChange(key: "autohide", value: .bool(true)),
        ], to: PreferenceDomain("com.apple.dock"), asRoot: false)
        let calls = fixture.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].hasPrefix("[export][com.apple.dock][\(fixture.harness.environment.temporaryDirectory.path)/shawn-prefs-"), calls[0])
        XCTAssertEqual(calls[1], "[import][com.apple.dock][-]")
        let imported = try readPlist(fixture.shim.deletingLastPathComponent().appendingPathComponent("imported.plist"))
        XCTAssertEqual(imported, ["persistent-apps": .array([tile]), "autohide": .bool(true), "mod-count": .int(12), "keep": .string("me")])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.harness.environment.temporaryDirectory.path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix("shawn-prefs-") }, [], "the temporary export is removed")
        XCTAssertTrue(fixture.lines.all.contains { $0.text == "$ defaults import com.apple.dock -   # sets persistent-apps, autohide" })
    }

    func testDryRunOnlyEchoes() async throws {
        let fixture = try Fixture()
        let store = fixture.store(dryRun: true)
        _ = try await store.read(PreferenceDomain("com.apple.dock"))
        try await store.write([PreferenceChange(key: "autohide", value: .bool(true))], to: PreferenceDomain("com.apple.dock"), asRoot: false)
        try await store.write([PreferenceChange(key: "persistent-apps", value: .array([]))], to: PreferenceDomain("com.apple.dock"), asRoot: false)
        XCTAssertEqual(fixture.calls, ["[export][com.apple.dock][-]"], "only the read-only export runs in a dry run")
        let texts = fixture.lines.all.map(\.text)
        XCTAssertTrue(texts.contains("[dry-run] $ defaults write com.apple.dock autohide -bool true"), "\(texts)")
        XCTAssertTrue(texts.contains("[dry-run] $ defaults import com.apple.dock -   # sets persistent-apps"), "\(texts)")
    }

    func testFailuresAreErrors() async throws {
        let fixture = try Fixture(failWrites: true)
        do {
            try await fixture.store().write([PreferenceChange(key: "a", value: .bool(true))], to: PreferenceDomain("com.example"), asRoot: false)
            XCTFail("expected an error")
        } catch let error as CommandError {
            XCTAssertTrue(error.description.contains("Could not write domain"), error.description)
        }
        let missing = DefaultsCommandStore(commands: CommandRunner(environment: fixture.harness.environment),
                                           executable: fixture.harness.url("no-such-defaults").path,
                                           temporaryDirectory: fixture.harness.environment.temporaryDirectory)
        do {
            _ = try await missing.read(PreferenceDomain("com.apple.dock"))
            XCTFail("expected an error")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.hasPrefix("could not read the com.apple.dock preferences"), error.message)
        }
    }

    func testRestarterRunsKillallAndOnlyWarnsOnFailure() async throws {
        let harness = Harness()
        let killall = harness.shim("killall", body: """
        [ "$1" = "Dock" ] && exit 0
        echo "No matching processes belonging to you were found" >&2
        exit 1
        """)
        let warnings = Recorder<String>()
        let runner = CommandRunner(environment: harness.environment)
        await ProcessRestarter(executable: killall.path).restart(["Dock", "ControlCenter"], commands: runner, warn: { warnings.add($0) })
        XCTAssertEqual(harness.shimCalls("killall"), ["[Dock]", "[ControlCenter]"])
        XCTAssertEqual(warnings.all.count, 1)
        XCTAssertTrue(warnings.all[0].contains("could not restart ControlCenter (No matching processes"), warnings.all[0])
    }
}
