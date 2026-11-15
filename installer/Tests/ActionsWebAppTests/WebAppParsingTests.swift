import XCTest
@testable import ActionsWebApp
import ShawnCore

final class WebAppParsingTests: XCTestCase {
    private func messages(_ plan: InstallPlan) -> String {
        plan.errors.map(\.message).joined(separator: "\n")
    }

    private func action(_ plan: InstallPlan) throws -> WebAppAction {
        try XCTUnwrap(plan.steps.first?.items.first?.action as? WebAppAction)
    }

    func testDescriptorIsRegisteredWithAWorkingExample() throws {
        let descriptors = WebAppActions.descriptors
        XCTAssertEqual(descriptors.map(\.kind), ["webapp"])
        XCTAssertFalse(descriptors[0].summary.isEmpty)
        // A folder named "icons" is hidden by the repo's .gitignore ("Icon?"), so the documented place is webapp-icons/.
        XCTAssertTrue(descriptors[0].summary.contains("config/webapp-icons/"), descriptors[0].summary)
        XCTAssertTrue(descriptors[0].example.contains("icon: webapp-icons/x.png"), descriptors[0].example)

        let sandbox = WebAppSandbox(items: descriptors[0].example.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n")
        sandbox.directory.write("config/webapp-icons/x.png", TestImages.solidPNG(size: 64))
        let plan = try sandbox.plan()
        XCTAssertEqual(plan.errors, [], messages(plan))
    }

    func testMinimalItemUsesDefaults() throws {
        let sandbox = WebAppSandbox(items: "  - webapp: X\n    url: https://x.com\n")
        let plan = try sandbox.plan()
        XCTAssertEqual(plan.errors, [], messages(plan))
        let action = try action(plan)
        XCTAssertEqual(action.title, "X")
        XCTAssertEqual(action.subtitle, "https://x.com")
        XCTAssertEqual(action.spec, WebAppSpec(name: "X", url: "https://x.com", icon: nil, to: "{{applications}}", bundleID: nil,
                                               userAgent: nil, width: nil, height: nil, hosts: []))
        XCTAssertEqual(WebAppRules.defaultBundleID(for: "X"), "com.shawnschwartz.webapp.x")
        XCTAssertEqual(WebAppRules.defaultBundleID(for: "My Carbon App!"), "com.shawnschwartz.webapp.my-carbon-app")
    }

    func testEveryOptionIsReadAndHostsAreNormalised() throws {
        let sandbox = WebAppSandbox(items: """
          - webapp: Carbon
            url: https://my.carbonapp.co
            icon: https://cdn.example.com/carbon.png
            to: ~/Applications/Web
            bundle_id: co.carbonapp.desktop
            user_agent: CarbonBot/1.0
            width: 1400
            height: 900
            hosts: [Auth0.com, "*.google.com", auth0.com]

        """)
        let plan = try sandbox.plan()
        XCTAssertEqual(plan.errors, [], messages(plan))
        XCTAssertEqual(try action(plan).spec, WebAppSpec(
            name: "Carbon", url: "https://my.carbonapp.co", icon: "https://cdn.example.com/carbon.png", to: "~/Applications/Web",
            bundleID: "co.carbonapp.desktop", userAgent: "CarbonBot/1.0", width: 1400, height: 900, hosts: ["auth0.com", "google.com"]
        ))
    }

    func testBadValuesAreReportedTogetherWithHelpfulMessages() throws {
        let sandbox = WebAppSandbox(items: """
          - webapp: a/b
            url: http://x.com
            icon: webapp-icons/x.gif
            bundle_id: not valid
            width: wide
            height: 12
            hosts: [https://twitter.com]
            hots: [x.com]

        """)
        let text = messages(try sandbox.plan())
        XCTAssertTrue(text.contains("cannot contain '/' or ':'"), text)
        XCTAssertTrue(text.contains("'url' must use https://"), text)
        XCTAssertTrue(text.contains("'icon' must be a .png, .jpg or .icns file"), text)
        XCTAssertTrue(text.contains("'bundle_id' must look like com.example.app"), text)
        XCTAssertTrue(text.contains("'width' must be a whole number"), text)
        XCTAssertTrue(text.contains("'height' must be between 320 and 10000"), text)
        XCTAssertTrue(text.contains("'hosts' entries are host names like 'twitter.com'"), text)
        XCTAssertTrue(text.contains("unknown key 'hots'. Did you mean 'hosts'?"), text)
    }

    func testMissingURLAndNameAreErrors() throws {
        let sandbox = WebAppSandbox(items: "  - webapp:\n    icon: https://example.com/a.png\n")
        let text = messages(try sandbox.plan())
        XCTAssertTrue(text.contains("missing required key 'url'"), text)
        XCTAssertTrue(text.contains("'webapp' needs a value"), text)
    }

    func testIconPathRules() {
        XCTAssertNil(WebAppRules.iconProblem("webapp-icons/x.png"))
        XCTAssertNil(WebAppRules.iconProblem("webapp-icons/X.JPEG"))
        XCTAssertNil(WebAppRules.iconProblem("webapp-icons/x.icns"))
        // Any path under the config directory is accepted; webapp-icons/ is only the convention.
        XCTAssertNil(WebAppRules.iconProblem("files/art/x.png"))
        XCTAssertNil(WebAppRules.iconProblem("https://example.com/icon"))
        XCTAssertEqual(WebAppRules.iconProblem("http://example.com/a.png"), "'icon' must use https:// (got 'http://example.com/a.png')")
        XCTAssertNotNil(WebAppRules.iconProblem("/Users/me/x.png"))
        XCTAssertNotNil(WebAppRules.iconProblem("~/x.png"))
        XCTAssertNotNil(WebAppRules.iconProblem("../x.png"))
        XCTAssertNotNil(WebAppRules.iconProblem("webapp-icons/x.svg"))
        XCTAssertEqual(WebAppRules.iconProblem("../x.png"),
                       "'icon' must be a path inside the config directory (like webapp-icons/x.png) or an https:// address (got '../x.png')")
    }

    func testValidationReportsMissingIconFileAndUnknownVariables() throws {
        let sandbox = WebAppSandbox(items: """
          - webapp: X
            url: https://{{nope}}/home
            icon: webapp-icons/missing.png
          - webapp: Folder
            url: https://example.com
            icon: webapp-icons/folder.png

        """)
        try FileManager.default.createDirectory(at: sandbox.configRoot.appendingPathComponent("webapp-icons/folder.png"), withIntermediateDirectories: true)
        let text = messages(try sandbox.plan())
        XCTAssertTrue(text.contains("'url' uses unknown variable {{nope}}"), text)
        XCTAssertTrue(text.contains("icon file 'webapp-icons/missing.png' does not exist in the config directory (web-app icons go in config/webapp-icons/)"), text)
        XCTAssertTrue(text.contains("icon 'webapp-icons/folder.png' is a folder"), text)
    }

    func testTemplatedURLIsValidatedAfterExpansion() throws {
        let good = WebAppSandbox(items: "  - webapp: X\n    url: https://{{site}}/home\n")
        XCTAssertEqual(try good.plan().errors, [])

        let bad = WebAppSandbox(items: "  - webapp: X\n    url: \"{{site}}\"\n")
        let text = messages(try bad.plan())
        XCTAssertTrue(text.contains("'url' must be a full https:// address"), text)
    }

    func testHostNormalisation() {
        XCTAssertEqual(WebAppRules.normalizedHost("Twitter.COM."), "twitter.com")
        XCTAssertEqual(WebAppRules.normalizedHost("*.twimg.com"), "twimg.com")
        XCTAssertEqual(WebAppRules.normalizedHost("localhost"), "localhost")
        XCTAssertNil(WebAppRules.normalizedHost("https://x.com"))
        XCTAssertNil(WebAppRules.normalizedHost("x.com/path"))
        XCTAssertNil(WebAppRules.normalizedHost("-bad-.com"))
        XCTAssertNil(WebAppRules.normalizedHost(""))
    }
}
