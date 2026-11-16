import XCTest
@testable import ShawnCore

final class AppNameTests: XCTestCase {
    /// The build scripts and the app's Info.plist cannot read `ShawnCore.appName`, so this compares them.
    func testTheScriptsAndTheInfoPlistNameTheAppAsTheCodeDoes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let common = try String(contentsOf: root.appendingPathComponent("scripts/common.sh"), encoding: .utf8)
        XCTAssertTrue(common.contains("\nAPP_NAME=\"\(ShawnCore.appName)\"\n"), "scripts/common.sh names the app something else")

        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleName"] as? String, ShawnCore.appName)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, ShawnCore.appName)
        XCTAssertEqual(ShawnCore.appName, "Dotfiles")
    }
}
