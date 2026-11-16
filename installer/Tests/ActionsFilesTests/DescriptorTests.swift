import Foundation
import ShawnCore
import XCTest
@testable import ActionsFiles

final class DescriptorTests: XCTestCase {
    func testEveryKindIsRegistered() {
        var registry = ActionRegistry()
        registry.register(FileActions.descriptors)
        XCTAssertEqual(registry.kinds, ["copy", "defaults", "dock", "json-merge", "login-item", "manual", "mkdir", "open", "shawn-cli", "symlink"])
        for descriptor in FileActions.descriptors {
            XCTAssertFalse(descriptor.summary.isEmpty, descriptor.kind)
            XCTAssertTrue(descriptor.example.contains("- \(descriptor.kind):"), "example for \(descriptor.kind) should show the kind")
        }
    }

    /// Every example in the docs must parse with this build (payload files may be missing; that is validation, not parsing).
    func testExamplesParse() throws {
        var registry = ActionRegistry()
        registry.register(FileActions.descriptors)
        for descriptor in FileActions.descriptors {
            let parsed = try YAML.parse(descriptor.example, file: "\(descriptor.kind) example")
            let items = try XCTUnwrap(parsed?.list, "\(descriptor.kind) example is not a list")
            XCTAssertFalse(items.isEmpty)
            for (index, element) in items.enumerated() {
                let raw = RawItem(map: try XCTUnwrap(element.map), source: SourceRef(file: "example"))
                switch registry.resolve(raw, stepID: "docs", index: index) {
                case .success(let resolved):
                    XCTAssertEqual(resolved.item.kind, descriptor.kind)
                case .failure(let error):
                    XCTFail("\(descriptor.kind) example item \(index + 1) does not parse: \(error)")
                }
            }
        }
    }

    func testUnknownOptionsAreReportedWithSuggestions() throws {
        let harness = Harness()
        let problems = try harness.problems("""
        - copy: zsh/zshrc
          to: ~/.zshrc
          mod: "0644"
        """)
        XCTAssertTrue(problems.contains { $0.contains("unknown key 'mod'") && $0.contains("Did you mean 'mode'") }, "\(problems)")
    }

    func testFileModeParsing() {
        XCTAssertEqual(FileMode.parse("0600"), 0o600)
        XCTAssertEqual(FileMode.parse("600"), 0o600)
        XCTAssertEqual(FileMode.parse("0o755"), 0o755)
        XCTAssertNil(FileMode.parse("0999"))
        XCTAssertNil(FileMode.parse("rw-r--r--"))
        XCTAssertNil(FileMode.parse("17777"))
        XCTAssertEqual(FileMode.describe(0o600), "0600")
        XCTAssertEqual(FileMode.describe(0o4755), "4755")
    }

    func testNaming() {
        XCTAssertEqual(Naming.slug("Google Chrome"), "google-chrome")
        XCTAssertEqual(Naming.slug("  1Password 8!  "), "1password-8")
        XCTAssertEqual(Naming.appName("/Applications/Herdr.app"), "Herdr")
        XCTAssertEqual(Naming.appName("Aero Dogfood"), "Aero Dogfood")
        XCTAssertTrue(Naming.looksLikeURL("https://x.com"))
        XCTAssertTrue(Naming.looksLikeURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
        XCTAssertFalse(Naming.looksLikeURL("Google Chrome"))
        XCTAssertFalse(Naming.looksLikeURL("~/Developer"))
        XCTAssertTrue(Naming.looksLikePath("~/Developer"))
        XCTAssertEqual(YAMLText.scalar("/Users/me/Developer/dotfiles"), "/Users/me/Developer/dotfiles")
        XCTAssertEqual(YAMLText.scalar("/Users/me/odd: name"), "\"/Users/me/odd: name\"")
    }
}
