import XCTest
@testable import ShawnCore

final class MinimumMacOSTests: XCTestCase {
    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    func testTheMinimumAndNewerAreAllowedAndOlderIsNot() {
        XCTAssertTrue(MinimumMacOS.allows(version(27)))
        XCTAssertTrue(MinimumMacOS.allows(version(27, 2)))
        XCTAssertTrue(MinimumMacOS.allows(version(28, 1, 3)))
        XCTAssertFalse(MinimumMacOS.allows(version(26, 7, 2)), "a high minor number does not make up for the major one")
        XCTAssertFalse(MinimumMacOS.allows(version(14)))
    }

    func testAVersionReadsAsMacOSWritesIt() {
        XCTAssertEqual(MinimumMacOS.describe(version(26, 7, 2)), "26.7.2")
        XCTAssertEqual(MinimumMacOS.describe(version(26, 7)), "26.7", "no patch number when it is 0")
        XCTAssertEqual(MinimumMacOS.describe(version(27)), "27.0")
    }

    /// The package manifest and the app's Info.plist cannot read `MinimumMacOS`, so this compares them.
    func testThePackageAndTheAppNameTheSameMinimum() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("platforms: [.macOS(.v\(MinimumMacOS.major))]"),
                      "Package.swift targets a macOS other than \(MinimumMacOS.major)")

        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, MinimumMacOS.infoPlistValue)
        XCTAssertEqual(MinimumMacOS.infoPlistValue, "27.0")
    }
}
