import Foundation
import XCTest
import ShawnCore
@testable import ShawnSync

final class ConfigLocatorTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() {
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
    }

    /// A minimal app bundle at `Fake.app` whose resources hold a config directory.
    private func makeBundle(withConfig: Bool = true) throws -> Bundle {
        temp.write("Fake.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>test.fake.\(UUID().uuidString)</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """)
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("Fake.app/Contents/Resources"),
                                                withIntermediateDirectories: true)
        if withConfig { writeConfig(in: temp, at: "Fake.app/Contents/Resources/config", name: "Bundled") }
        return try XCTUnwrap(Bundle(path: temp.url.appendingPathComponent("Fake.app").path))
    }

    private func writeSettings(_ settings: ShawnSettings, environment: SystemEnvironment) throws {
        let url = ShawnSettings.fileURL(environment: environment)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(settings.yaml.utf8).write(to: url)
    }

    /// Creates every kind of location so each test can remove the ones that should not win.
    private func makeAllLocations() throws -> (environment: SystemEnvironment, explicit: URL, fromVariable: URL, checkout: URL,
                                              installed: URL, bundle: Bundle) {
        let fromVariable = writeConfig(in: temp, at: "from-variable", name: "From Variable")
        let environment = SystemEnvironment.testSandbox(temp, extraEnvironment: [ConfigLocator.environmentVariable: fromVariable.path])
        let explicit = writeConfig(in: temp, at: "explicit", name: "Explicit")
        let checkout = writeConfig(in: temp, at: "home/Developer/dotfiles/installer/config", name: "Checkout")
        try writeSettings(ShawnSettings(dotfilesRepo: "~/Developer/dotfiles"), environment: environment)
        let installed = writeConfig(in: temp, at: "home/.shawn/config", name: "Installed")
        let bundle = try makeBundle()
        return (environment, explicit, fromVariable, checkout, installed, bundle)
    }

    private func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(ConfigLoader.metaFileName))
    }

    func testSearchOrder() throws {
        let all = try makeAllLocations()
        func located(_ explicit: URL? = nil) -> ConfigLocator.Location? {
            ConfigLocator.locate(explicit: explicit, environment: all.environment, bundle: all.bundle)
        }

        XCTAssertEqual(located(all.explicit)?.url.path, all.explicit.path)
        XCTAssertEqual(located(all.explicit)?.origin, .explicit)
        XCTAssertEqual(located()?.url.path, all.fromVariable.path)
        XCTAssertEqual(located()?.origin, .environmentVariable)

        try remove(all.fromVariable)
        XCTAssertEqual(located()?.url.path, all.checkout.path)
        XCTAssertEqual(located()?.origin, .checkout)
        XCTAssertEqual(located()?.source, .local(all.checkout.path))

        try remove(all.checkout)
        XCTAssertEqual(located()?.url.path, all.installed.path)
        XCTAssertEqual(located()?.origin, .installed)

        try remove(all.installed)
        let bundled = try XCTUnwrap(located())
        XCTAssertEqual(bundled.origin, .bundled)
        XCTAssertEqual(bundled.source, .bundled)
        XCTAssertEqual(bundled.url.resolvingSymlinksInPath().path,
                       temp.url.appendingPathComponent("Fake.app/Contents/Resources/config").resolvingSymlinksInPath().path)
    }

    func testCandidatesListEveryPlaceInOrder() throws {
        let all = try makeAllLocations()

        let candidates = ConfigLocator.candidates(environment: all.environment, bundle: all.bundle)

        XCTAssertEqual(candidates.map(\.origin), [.environmentVariable, .checkout, .installed, .bundled])
        XCTAssertEqual(candidates.prefix(3).map(\.url.path), [all.fromVariable.path, all.checkout.path, all.installed.path])
        XCTAssertFalse(candidates.contains { $0.origin == .development }, "a sandbox never walks up from the working directory")
    }

    func testAMissingExplicitPathIsNotReplacedByAnotherConfig() throws {
        let all = try makeAllLocations()
        let typo = temp.url.appendingPathComponent("does-not-exist")

        XCTAssertNil(ConfigLocator.locate(explicit: typo, environment: all.environment, bundle: all.bundle))
        XCTAssertEqual(ConfigLocator.candidates(explicit: typo, environment: all.environment, bundle: all.bundle).map(\.url.path), [typo.path])
    }

    func testEnvironmentVariableExpandsTilde() throws {
        let environment = SystemEnvironment.testSandbox(temp, extraEnvironment: [ConfigLocator.environmentVariable: "~/my-config"])
        let config = writeConfig(in: temp, at: "home/my-config")

        XCTAssertEqual(ConfigLocator.locate(environment: environment, bundle: try makeBundle(withConfig: false))?.url.path, config.path)
    }

    func testSettingsConfigPathMayBeAbsolute() throws {
        let environment = SystemEnvironment.testSandbox(temp)
        let elsewhere = writeConfig(in: temp, at: "elsewhere/config")
        try writeSettings(ShawnSettings(dotfilesRepo: "~/Developer/dotfiles", configPath: elsewhere.path), environment: environment)

        let location = ConfigLocator.locate(environment: environment, bundle: try makeBundle(withConfig: false))

        XCTAssertEqual(location?.url.path, elsewhere.path)
        XCTAssertEqual(location?.origin, .checkout)
    }

    func testNothingFound() throws {
        let environment = SystemEnvironment.testSandbox(temp)
        XCTAssertNil(ConfigLocator.locate(environment: environment, bundle: try makeBundle(withConfig: false)))
        XCTAssertNil(ConfigLocator.bundledConfigDirectory(bundle: try makeBundle(withConfig: false)))
    }

    func testWalkUpFindsADevelopmentCheckout() throws {
        let config = writeConfig(in: temp, at: "repo/installer/config")
        let deep = temp.url.appendingPathComponent("repo/installer/Sources/Thing")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertEqual(ConfigLocator.walkUp(from: deep)?.path, config.path)
        XCTAssertNil(ConfigLocator.walkUp(from: temp.url.appendingPathComponent("repo/installer/Sources/Thing"), maxDepth: 1))
    }

    func testOutsideASandboxADevelopmentCheckoutComesAfterTheConfiguredOne() throws {
        var environment = SystemEnvironment.testSandbox(temp)
        environment.isSandbox = false
        let checkout = writeConfig(in: temp, at: "home/Developer/dotfiles/installer/config", name: "Checkout")
        try writeSettings(ShawnSettings(dotfilesRepo: "~/Developer/dotfiles"), environment: environment)
        let other = writeConfig(in: temp, at: "work/other-repo/installer/config", name: "Other")
        let insideCheckout = temp.url.appendingPathComponent("home/Developer/dotfiles/installer/Sources")
        let insideOther = temp.url.appendingPathComponent("work/other-repo/installer/Sources")
        for directory in [insideCheckout, insideOther] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let bundle = try makeBundle(withConfig: false)

        let fromCheckout = ConfigLocator.candidates(environment: environment, bundle: bundle, currentDirectory: insideCheckout)
        let fromOther = ConfigLocator.candidates(environment: environment, bundle: bundle, currentDirectory: insideOther)

        XCTAssertEqual(fromCheckout.map(\.origin), [.checkout, .installed], "the same checkout is not listed twice")
        XCTAssertEqual(fromOther.map(\.origin), [.checkout, .development, .installed])
        XCTAssertEqual(fromOther[1].url.path, other.path)
        XCTAssertEqual(ConfigLocator.locate(environment: environment, bundle: bundle, currentDirectory: insideOther)?.url.path, checkout.path)
    }

    func testWorkingCopiesAreTheEditableOrigins() {
        let working: [ConfigLocator.Location.Origin] = [.explicit, .environmentVariable, .checkout, .development]
        XCTAssertTrue(working.allSatisfy(\.isWorkingCopy))
        XCTAssertFalse(ConfigLocator.Location.Origin.installed.isWorkingCopy)
        XCTAssertFalse(ConfigLocator.Location.Origin.bundled.isWorkingCopy)
    }
}

final class ShawnSettingsTests: XCTestCase {
    private var temp: TempDirectory!
    private var environment: SystemEnvironment!

    override func setUp() {
        temp = TempDirectory()
        environment = SystemEnvironment.testSandbox(temp)
    }

    override func tearDown() {
        temp = nil
    }

    private func writeSettingsFile(_ text: String) {
        temp.write("home/.config/shawn/config.yaml", text)
    }

    func testMissingFileGivesDefaults() {
        let (settings, problem) = ShawnSettings.loadReportingProblem(environment: environment)
        XCTAssertEqual(settings, ShawnSettings())
        XCTAssertNil(settings.dotfilesRepo)
        XCTAssertEqual(settings.configPath, "installer/config")
        XCTAssertNil(problem)
        XCTAssertNil(settings.repoURL(environment: environment))
    }

    func testYAMLRoundTrip() throws {
        let values = [
            "~/Developer/dotfiles",
            "/Users/someone/My Projects/dot files",
            "~/weird: path #1",
            "say \"hi\"",
            "back\\slash",
            "~",
            "null",
            " leading and trailing ",
            "tab\there",
            "-dash-first",
            "it's fine",
        ]
        for value in values {
            let original = ShawnSettings(dotfilesRepo: value, configPath: value)
            writeSettingsFile(original.yaml)

            let (loaded, problem) = ShawnSettings.loadReportingProblem(environment: environment)

            XCTAssertNil(problem, value)
            XCTAssertEqual(loaded, original, "round trip of \(value.debugDescription) via:\n\(original.yaml)")
        }
    }

    func testOrdinaryPathsStayReadable() {
        let yaml = ShawnSettings(dotfilesRepo: "~/Developer/dotfiles").yaml
        XCTAssertTrue(yaml.contains("\ndotfiles_repo: ~/Developer/dotfiles\n"), yaml)
        XCTAssertTrue(yaml.hasSuffix("config_path: installer/config\n"), yaml)
        XCTAssertTrue(yaml.hasPrefix("# "), "starts with a comment saying who wrote it")
        XCTAssertFalse(ShawnSettings().yaml.contains("dotfiles_repo"))
    }

    func testFileWrittenByTheInstallerIsRead() {
        writeSettingsFile("dotfiles_repo: ~/Developer/dotfiles\nconfig_path: installer/config\n")

        let settings = ShawnSettings.load(environment: environment)

        XCTAssertEqual(settings.dotfilesRepo, "~/Developer/dotfiles")
        XCTAssertEqual(settings.repoURL(environment: environment)?.path, environment.home.path + "/Developer/dotfiles")
        XCTAssertEqual(settings.configDirectoryURL(environment: environment)?.path, environment.home.path + "/Developer/dotfiles/installer/config")
    }

    func testMalformedFileIsIgnoredWithAProblem() {
        writeSettingsFile("dotfiles_repo: [unclosed\n")
        let (settings, problem) = ShawnSettings.loadReportingProblem(environment: environment)
        XCTAssertEqual(settings, ShawnSettings())
        XCTAssertTrue(problem?.contains("~/.config/shawn/config.yaml") == true, problem ?? "nil")

        writeSettingsFile("- just\n- a list\n")
        let listProblem = ShawnSettings.loadReportingProblem(environment: environment).problem
        XCTAssertTrue(listProblem?.contains("mapping") == true, listProblem ?? "nil")
    }

    func testEmptyValuesKeepDefaults() {
        writeSettingsFile("dotfiles_repo: \"\"\nconfig_path:\n")
        XCTAssertEqual(ShawnSettings.load(environment: environment), ShawnSettings())
    }
}
