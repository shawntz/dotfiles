import XCTest
@testable import ActionsPackages
import ShawnCore

/// Small real installers: unsigned app bundles packed with ditto and hdiutil.
enum Fixtures {
    struct TimedOut: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs a real tool to build a fixture. `hdiutil` occasionally wedges inside the DiskImages service, so the
    /// tool is killed after `timeout` seconds and the test fails with a message instead of hanging the whole run.
    @discardableResult
    static func tool(_ path: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let output = Recorder<Data>()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.add(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            kill(process.processIdentifier, SIGKILL)
            throw TimedOut(description: "\(path) \(arguments) did not finish within \(Int(timeout)) seconds")
        }
        _ = drained.wait(timeout: .now() + 10)
        let text = String(decoding: output.all.first ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "fixtures", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(path) \(arguments): \(text)"])
        }
        return text
    }

    /// `<directory>/<name>.app` with an Info.plist and an executable; `marker` goes into Contents/marker.txt.
    @discardableResult
    static func app(_ name: String, in directory: URL, marker: String = "new") -> URL {
        let app = directory.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try! FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try! Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>\(name)</string>
        <key>CFBundleIdentifier</key><string>dev.example.\(name.lowercased())</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        </dict></plist>
        """.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        makeExecutable(contents.appendingPathComponent("MacOS/\(name)"), "#!/bin/sh\necho hi\n")
        try! Data(marker.utf8).write(to: contents.appendingPathComponent("marker.txt"))
        return app
    }

    /// A zip of the given app bundles (each at the top level), the way vendors ship them.
    static func zip(_ apps: [URL], to output: URL) throws -> URL {
        if apps.count == 1 {
            try tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", apps[0].path, output.path])
        } else {
            try tool("/usr/bin/ditto", ["-c", "-k", apps[0].deletingLastPathComponent().path, output.path])
        }
        return output
    }

    static func dmg(of folder: URL, to output: URL) throws -> URL {
        let arguments = ["create", "-quiet", "-ov", "-srcfolder", folder.path, "-volname", "Fixture", "-format", "UDZO", output.path]
        do {
            try tool("/usr/bin/hdiutil", arguments)
        } catch is TimedOut {
            // A wedged DiskImages service usually recovers; one more try before giving up.
            try tool("/usr/bin/hdiutil", arguments)
        }
        return output
    }
}

extension Sandbox {
    var downloads: URL { environment.cacheDirectory.appendingPathComponent("downloads") }

    /// Leftovers in the cache and temp directories (downloads, mount points, unpacked archives).
    var leftovers: [String] {
        let fileManager = FileManager.default
        let cached = (try? fileManager.contentsOfDirectory(atPath: downloads.path)) ?? []
        let scratch = ((try? fileManager.contentsOfDirectory(atPath: environment.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("shawn-") }
        return cached + scratch
    }

    /// True while any disk image is mounted under this sandbox.
    func hasMountedImage() throws -> Bool {
        try Fixtures.tool("/usr/bin/hdiutil", ["info"]).contains(root.lastPathComponent)
    }
}

final class DownloadTests: XCTestCase {
    private func makeDMG(_ sandbox: Sandbox, apps: [String] = ["Fixture"]) throws -> URL {
        let source = sandbox.root.appendingPathComponent("fixture-src")
        for name in apps { Fixtures.app(name, in: source) }
        sandbox.directory.mkdir("served")
        return try Fixtures.dmg(of: source, to: sandbox.root.appendingPathComponent("served/Fixture.dmg"))
    }

    private func makeZip(_ sandbox: Sandbox, apps: [String] = ["Fixture"]) throws -> URL {
        let source = sandbox.root.appendingPathComponent("fixture-src")
        let bundles = apps.map { Fixtures.app($0, in: source) }
        sandbox.directory.mkdir("served")
        return try Fixtures.zip(bundles, to: sandbox.root.appendingPathComponent("served/Fixture.zip"))
    }

    func testDiskImageInstallsTheAppThenDetachesAndCleansUp() async throws {
        let sandbox = Sandbox("download")
        let image = try makeDMG(sandbox)
        let yaml = "download: '\(image.absoluteString)'\napp: Fixture.app\nverify: false"

        let result = try await sandbox.run(yaml)
        XCTAssertEqual(result.check, .needed(nil))
        XCTAssertEqual(result.outcome, .done("installed Fixture.app"))
        let installed = sandbox.applications.appendingPathComponent("Fixture.app/Contents/MacOS/Fixture")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(sandbox.leftovers, [])
        XCTAssertFalse(try sandbox.hasMountedImage())
        let commands = sandbox.logLines.filter { $0.style == .command }.map(\.text)
        XCTAssertTrue(commands.contains { $0.contains("hdiutil attach -nobrowse -readonly -noautoopen -mountpoint") })
        XCTAssertTrue(commands.contains { $0.contains("hdiutil detach") })

        let second = try await sandbox.check(yaml)
        guard case .satisfied(let reason?) = second else { return XCTFail("\(second)") }
        XCTAssertTrue(reason.hasPrefix("Fixture.app is already in"), reason)
    }

    func testZipWithoutAppNameInstallsTheOnlyAppAndRemembersIt() async throws {
        let sandbox = Sandbox("download")
        let archive = try makeZip(sandbox)
        sandbox.shim("open")
        let yaml = "download: '\(archive.absoluteString)'\nverify: false\nlaunch: true"

        let result = try await sandbox.run(yaml)
        XCTAssertEqual(result.outcome, .done("installed Fixture.app"))
        XCTAssertEqual(sandbox.calls("open"), ["open -g -a \(sandbox.applications.appendingPathComponent("Fixture.app").path)"])
        XCTAssertEqual(sandbox.leftovers, [])
        let record = try XCTUnwrap(sandbox.directory.read("home/.shawn/state/downloads.json"))
        XCTAssertTrue(record.contains("Fixture.app"), record)

        let second = try await sandbox.check(yaml)
        XCTAssertTrue(second.isSatisfied, "the remembered app name makes the item idempotent: \(second)")
    }

    func testGatekeeperRejectionIsReportedAndNothingIsInstalled() async throws {
        let sandbox = Sandbox("download")
        let image = try makeDMG(sandbox)
        do {
            _ = try await sandbox.run("download: '\(image.absoluteString)'\napp: Fixture.app")
            XCTFail("an unsigned app must not pass verification")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.hasPrefix("Gatekeeper rejected Fixture.app"), error.message)
            XCTAssertTrue(error.hint?.contains("verify: false") == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.applications.appendingPathComponent("Fixture.app").path))
        XCTAssertEqual(sandbox.leftovers, [])
        XCTAssertFalse(try sandbox.hasMountedImage(), "the image is detached after a failure too")
    }

    func testWrongSigningTeamIsReported() async throws {
        let sandbox = Sandbox("download")
        let archive = try makeZip(sandbox)
        sandbox.system.spctl = sandbox.shim("spctl", "echo accepted >&2").path
        sandbox.system.codesign = sandbox.shim("codesign", "echo 'TeamIdentifier=AAAAAAAAAA' >&2").path
        do {
            _ = try await sandbox.run("download: '\(archive.absoluteString)'\napp: Fixture.app\nteam_id: ZL4K35VM2L")
            XCTFail("expected a team mismatch")
        } catch let error as ActionError {
            XCTAssertEqual(error.message, "Fixture.app is signed by team AAAAAAAAAA, not ZL4K35VM2L")
        }
        XCTAssertEqual(sandbox.leftovers, [])

        sandbox.system.codesign = sandbox.shim("codesign", "echo 'TeamIdentifier=ZL4K35VM2L' >&2").path
        let result = try await sandbox.run("download: '\(archive.absoluteString)'\napp: Fixture.app\nteam_id: ZL4K35VM2L")
        XCTAssertEqual(result.outcome, .done("installed Fixture.app"))
        XCTAssertTrue(sandbox.logText.contains("passed Gatekeeper and is signed by team ZL4K35VM2L"))
    }

    func testChecksumIsEnforced() async throws {
        let sandbox = Sandbox("download")
        let archive = try makeZip(sandbox)
        let wrong = String(repeating: "0", count: 64)
        do {
            _ = try await sandbox.run("download: '\(archive.absoluteString)'\napp: Fixture.app\nverify: false\nsha256: \(wrong)")
            XCTFail("expected a checksum failure")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.contains("does not match its sha256"), error.message)
        }
        XCTAssertEqual(sandbox.leftovers, [])

        let right = try Downloader.sha256(of: archive).uppercased()
        let result = try await sandbox.run("download: '\(archive.absoluteString)'\napp: Fixture.app\nverify: false\nsha256: \(right)")
        XCTAssertEqual(result.outcome, .done("installed Fixture.app"))
    }

    func testReplacingBacksUpTheExistingApp() async throws {
        let sandbox = Sandbox("download")
        let archive = try makeZip(sandbox)
        Fixtures.app("Fixture", in: sandbox.applications, marker: "old")
        let yaml = "download: '\(archive.absoluteString)'\napp: Fixture.app\nverify: false\nreplace: true"

        let check = try await sandbox.check(yaml)
        XCTAssertEqual(check, .needed("Fixture.app is there, but 'replace: true' installs it again"))
        let result = try await sandbox.run(yaml)
        XCTAssertEqual(result.outcome, .done("installed Fixture.app"))
        XCTAssertEqual(sandbox.directory.read("Applications/Fixture.app/Contents/marker.txt"), "new")
        let backup = sandbox.environment.backupDirectory.appendingPathComponent("_root" + sandbox.applications.appendingPathComponent("Fixture.app/Contents/marker.txt").path)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old")

        // Without replace, an existing app is left alone.
        let keep = try await sandbox.check("download: '\(archive.absoluteString)'\napp: Fixture.app\nverify: false")
        XCTAssertTrue(keep.isSatisfied)
    }

    func testAFailedCopyPutsThePreviousAppBack() async throws {
        let sandbox = Sandbox("download")
        let archive = try makeZip(sandbox)
        Fixtures.app("Fixture", in: sandbox.applications, marker: "old")
        // Unpacking works; copying into Applications dies half-way.
        sandbox.system.ditto = sandbox.shim("ditto", """
        if [ "$1" = "-x" ]; then exec /usr/bin/ditto "$@"; fi
        mkdir -p "$2/Contents"; echo 'ditto: No space left on device' >&2; exit 1
        """).path

        do {
            _ = try await sandbox.run("download: '\(archive.absoluteString)'\napp: Fixture.app\nverify: false\nreplace: true")
            XCTFail("expected the copy to fail")
        } catch {
            XCTAssertTrue("\(error)".contains("No space left on device"), "\(error)")
        }
        XCTAssertEqual(sandbox.directory.read("Applications/Fixture.app/Contents/marker.txt"), "old")
        XCTAssertEqual(sandbox.leftovers, [])
    }

    func testCancellingMidCopyStillDetachesAndCleansUp() async throws {
        let sandbox = Sandbox("download")
        let image = try makeDMG(sandbox)
        sandbox.system.ditto = sandbox.shim("ditto", "sleep 30").path
        let resolved = try sandbox.parse("download: '\(image.absoluteString)'\napp: Fixture.app\nverify: false")
        let context = sandbox.context(resolved.item)
        let running = Task { try await resolved.action.run(context) }

        // Wait until the copy has started (the image is mounted by then).
        let deadline = Date().addingTimeInterval(20)
        while sandbox.calls("ditto").isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(try sandbox.hasMountedImage())
        running.cancel()
        do {
            _ = try await running.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(try sandbox.hasMountedImage(), "the image must be detached after canceling")
        XCTAssertEqual(sandbox.leftovers, [])
    }

    func testSeveralAppsNeedAnAppName() async throws {
        let sandbox = Sandbox("download")
        let archive = try makeZip(sandbox, apps: ["Fixture", "Helper"])
        do {
            _ = try await sandbox.run("download: '\(archive.absoluteString)'\nverify: false")
            XCTFail("expected an ambiguity error")
        } catch let error as ActionError {
            XCTAssertEqual(error.message, "the zip archive holds 2 apps (Fixture.app, Helper.app)")
            XCTAssertEqual(error.hint, "add 'app:' naming the one to install")
        }
        do {
            _ = try await sandbox.run("download: '\(archive.absoluteString)'\napp: Other.app\nverify: false")
            XCTFail("expected a missing-app error")
        } catch let error as ActionError {
            XCTAssertEqual(error.message, "Other.app is not in the zip archive (it has Fixture.app, Helper.app)")
        }
        XCTAssertEqual(sandbox.leftovers, [])
    }

    func testPackagesInstallAsRootAndAreVerifiedFirst() async throws {
        let sandbox = Sandbox("download")
        let package = sandbox.directory.write("served/Thing.pkg", "not really a package")
        sandbox.shim("installer", "mkdir -p \"\(sandbox.applications.path)/Thing.app/Contents\"")

        let result = try await sandbox.run("download: '\(package.absoluteString)'\napp: Thing.app\nverify: false")
        XCTAssertEqual(result.outcome, .done("installed Thing.app"))
        let install = try XCTUnwrap(sandbox.calls("root installer").first)
        XCTAssertTrue(install.hasPrefix("root installer -pkg \(sandbox.downloads.path)/") && install.hasSuffix("-Thing.pkg -target /"), install)
        XCTAssertEqual(sandbox.leftovers, [])
        let check = try await sandbox.check("download: '\(package.absoluteString)'\napp: Thing.app")
        XCTAssertTrue(check.isSatisfied)

        // With verification, an unsigned package is refused before the installer runs.
        sandbox.system.pkgutil = "/usr/sbin/pkgutil"
        sandbox.clearCalls()
        do {
            _ = try await sandbox.run("download: '\(package.absoluteString)'\napp: Other.app")
            XCTFail("expected a signature failure")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.hasPrefix("Other is not properly signed"), error.message)
        }
        XCTAssertTrue(sandbox.calls("root installer").isEmpty)
    }

    func testAnUnnamedAppThatIsAlreadyThereIsLeftAlone() async throws {
        let sandbox = Sandbox("download")
        let archive = try makeZip(sandbox)
        Fixtures.app("Fixture", in: sandbox.applications, marker: "old")
        let yaml = "download: '\(archive.absoluteString)'\nverify: false"
        let result = try await sandbox.run(yaml)
        XCTAssertEqual(result.outcome, .done("Fixture.app was already there"))
        XCTAssertEqual(sandbox.directory.read("Applications/Fixture.app/Contents/marker.txt"), "old")
        let check = try await sandbox.check(yaml)
        XCTAssertTrue(check.isSatisfied, "\(check)")
    }

    func testAFailedPackageInstallPutsThePreviousAppBack() async throws {
        let sandbox = Sandbox("download")
        let package = sandbox.directory.write("served/Thing.pkg", "not really a package")
        Fixtures.app("Thing", in: sandbox.applications, marker: "old")
        sandbox.shim("installer", "echo 'installer: The Installer encountered an error' >&2; exit 1")
        do {
            _ = try await sandbox.run("download: '\(package.absoluteString)'\napp: Thing.app\nverify: false\nreplace: true")
            XCTFail("expected the installer to fail")
        } catch {
            XCTAssertTrue("\(error)".contains("The Installer encountered an error"), "\(error)")
        }
        XCTAssertEqual(sandbox.directory.read("Applications/Thing.app/Contents/marker.txt"), "old")
        XCTAssertEqual(sandbox.leftovers, [])
    }

    func testABrokenAddressFailsCleanly() async throws {
        let sandbox = Sandbox("download")
        let missing = sandbox.root.appendingPathComponent("served/missing.dmg")
        do {
            _ = try await sandbox.run("download: '\(missing.absoluteString)'\napp: Fixture.app")
            XCTFail("expected a download failure")
        } catch let error as ActionError {
            XCTAssertTrue(error.message.hasPrefix("Could not download \(missing.absoluteString)"), error.message)
        }
        XCTAssertEqual(sandbox.leftovers, [])
    }

    func testDryRunNarratesEveryStepAndChangesNothing() async throws {
        let sandbox = Sandbox("download")
        let before = sandbox.snapshot()
        let result = try await sandbox.run("download: https://dl.example.com/Aero-Dogfood-latest-mac-universal.dmg\napp: Aero Dogfood.app\nteam_id: ZL4K35VM2L\nlaunch: true", dryRun: true)
        XCTAssertEqual(result.outcome, .done(nil))
        XCTAssertEqual(sandbox.snapshot(), before)
        XCTAssertEqual(sandbox.calls, [])
        let commands = sandbox.logLines.filter { $0.style == .command }.map(\.text)
        XCTAssertEqual(commands.map { $0.split(separator: " ").prefix(3).joined(separator: " ") },
                       ["[dry-run] $ curl", "[dry-run] $ hdiutil", "[dry-run] $ ditto", "[dry-run] $ hdiutil", "[dry-run] $ open"])
        XCTAssertTrue(commands[1].contains("hdiutil attach -nobrowse -readonly -noautoopen"))
        XCTAssertTrue(commands[3].contains("hdiutil detach"))
        XCTAssertTrue(sandbox.logText.contains("would check Aero Dogfood.app with Gatekeeper and team ZL4K35VM2L"))
    }
}
