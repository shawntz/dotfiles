import Foundation
import ShawnSync
import XCTest
@testable import ShawnUI

final class LaunchOptionsTests: XCTestCase {
    func testDefaults() throws {
        let options = try LaunchOptions.parse([])
        XCTAssertEqual(options, LaunchOptions())
        XCTAssertFalse(options.dryRun)
        XCTAssertTrue(options.allowRemote)
        XCTAssertNil(options.snapshotPath)
        XCTAssertEqual(options.snapshotState, .welcome)
        XCTAssertEqual(options.snapshotSize, CGSize(width: 1100, height: 760))
        XCTAssertEqual(options.snapshotScale, 2)
        XCTAssertFalse(options.autoStart)
    }

    func testEveryFlag() throws {
        let options = try LaunchOptions.parse([
            "--dry-run", "--fresh", "--config", "~/cfg", "--no-remote", "--config-ref", "feature/x",
            "--sandbox", "/tmp/box", "--simulate", "--snapshot", "/tmp/out.png", "--snapshot-state", "config-error",
            "--snapshot-size", "960x640", "--snapshot-scale", "1", "--snapshot-contrast", "high",
        ])
        XCTAssertTrue(options.snapshotHighContrast)
        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.assumeFresh)
        XCTAssertEqual(options.configPath, "~/cfg")
        XCTAssertFalse(options.allowRemote)
        XCTAssertEqual(options.configRef, "feature/x")
        XCTAssertEqual(options.sandboxRoot, "/tmp/box")
        XCTAssertTrue(options.simulate)
        XCTAssertEqual(options.snapshotPath, "/tmp/out.png")
        XCTAssertEqual(options.snapshotState, .configError)
        XCTAssertEqual(options.snapshotSize, CGSize(width: 960, height: 640))
        XCTAssertEqual(options.snapshotScale, 1)
    }

    func testEqualsFormAndDemo() throws {
        let options = try LaunchOptions.parse(["--config=/x", "--snapshot-state=running", "--demo"])
        XCTAssertEqual(options.configPath, "/x")
        XCTAssertEqual(options.snapshotState, .running)
        XCTAssertTrue(options.autoStart)
        XCTAssertTrue(options.startsInDryRun, "--demo is a dry run")
        XCTAssertTrue(options.startsFresh, "--demo assumes a fresh Mac")
        XCTAssertFalse(options.dryRun, "the flag itself stays as given")
    }

    func testEverySnapshotStateParses() throws {
        for state in SnapshotState.allCases {
            XCTAssertEqual(try LaunchOptions.parse(["--snapshot-state", state.rawValue]).snapshotState, state)
        }
        for required in ["welcome", "customize", "running", "password", "question", "attention", "finished", "failed", "config-error"] {
            XCTAssertNotNil(SnapshotState(rawValue: required), required)
        }
    }

    func testBadArgumentsAreReportedClearly() {
        XCTAssertThrowsError(try LaunchOptions.parse(["--frobnicate"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .unknownArgument("--frobnicate"))
            XCTAssertEqual("\(error)", "unknown argument '--frobnicate'")
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["--config"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .missingValue("--config"))
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["--config", "--dry-run"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .missingValue("--config"))
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["--snapshot-state", "sideways"])) { error in
            XCTAssertTrue("\(error)".contains("welcome"), "lists the valid states: \(error)")
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["--snapshot-size", "big"]))
        XCTAssertThrowsError(try LaunchOptions.parse(["--snapshot-size", "100x100"]), "too small to be a window")
        XCTAssertThrowsError(try LaunchOptions.parse(["--snapshot-scale", "9"]))
        XCTAssertThrowsError(try LaunchOptions.parse(["--snapshot-contrast", "loud"]))
        XCTAssertThrowsError(try LaunchOptions.parse(["--dry-run=yes"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .unexpectedValue("--dry-run"))
        }
    }

    func testIgnoresArgumentsMacOSAddsWhenLaunching() throws {
        let options = try LaunchOptions.parse(["-psn_0_12345", "-NSDocumentRevisionsDebugMode", "YES", "-AppleLanguages", "(en)", "--dry-run"])
        XCTAssertTrue(options.dryRun)
    }

    func testHelp() throws {
        XCTAssertTrue(try LaunchOptions.parse(["--help"]).showHelp)
        XCTAssertTrue(try LaunchOptions.parse(["-h"]).showHelp)
        for flag in ["--dry-run", "--fresh", "--config", "--no-remote", "--config-ref", "--sandbox", "--demo", "--simulate",
                     "--snapshot", "--snapshot-state", "--snapshot-size"] {
            XCTAssertTrue(LaunchOptions.usage.contains(flag), "usage mentions \(flag)")
        }
    }

    func testResolveOptionsFollowTheFlags() throws {
        var options = try LaunchOptions.parse(["--config", "/tmp/somewhere", "--config-ref", "v2"])
        var resolve = AppEnvironment.resolveOptions(options: options)
        XCTAssertEqual(resolve.explicitPath?.path, "/tmp/somewhere")
        XCTAssertEqual(resolve.remoteRef, "v2")
        XCTAssertTrue(resolve.allowRemote)

        options = try LaunchOptions.parse(["--no-remote"])
        resolve = AppEnvironment.resolveOptions(options: options)
        XCTAssertNil(resolve.explicitPath)
        XCTAssertFalse(resolve.allowRemote)
    }

    func testSandboxEnvironmentStaysInsideItsRoot() throws {
        let directory = makeTempDirectory()
        let options = try LaunchOptions.parse(["--sandbox", directory.url.path])
        let environment = try AppEnvironment.make(options: options)
        XCTAssertTrue(environment.isSandbox)
        for url in [environment.home, environment.applicationsDirectory, environment.logsDirectory, environment.cacheDirectory] {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(directory.url.standardizedFileURL.path), url.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.home.path))
        XCTAssertNotNil(environment.helpersDirectory)
    }

    func testHelpersDirectoryIsTheBundlesHelpersOrTheExecutablesFolder() throws {
        let directory = makeTempDirectory()
        let app = directory.url.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(AppEnvironment.helpersDirectory(bundle: bundle)?.path, app.appendingPathComponent("Contents/Helpers").path)
        let development = AppEnvironment.helpersDirectory(bundle: .main)
        XCTAssertEqual(development, Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent())
    }
}
