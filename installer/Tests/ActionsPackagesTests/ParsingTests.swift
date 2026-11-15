import XCTest
@testable import ActionsPackages
import ShawnCore

final class ParsingTests: XCTestCase {
    func testEveryKindIsRegisteredOnceWithAParsableExample() throws {
        let descriptors = PackageActions.descriptors
        XCTAssertEqual(descriptors.map(\.kind), ["xcode-clt", "homebrew", "rosetta", "xcode", "tap", "brew", "cask", "mas", "npm", "download", "script"])
        var registry = ActionRegistry()
        registry.register(descriptors)

        for descriptor in descriptors {
            XCTAssertFalse(descriptor.summary.isEmpty)
            // Every example is a YAML list item that this registry accepts.
            let parsed = try XCTUnwrap(YAML.parse(descriptor.example)?.list?.first?.map, descriptor.kind)
            if case .failure(let error) = registry.resolve(RawItem(map: parsed, source: SourceRef(file: "example")), stepID: "x", index: 0) {
                XCTFail("example for \(descriptor.kind) does not parse: \(error)")
            }
        }
    }

    func testGoodItemsParseWithTitlesSubtitlesAndPackageRefs() throws {
        let sandbox = Sandbox()
        let formula = try sandbox.parse("brew: withgraphite/tap/graphite\nargs: [--HEAD]").action
        XCTAssertEqual(formula.title, "graphite")
        XCTAssertEqual(formula.subtitle, "withgraphite/tap · --HEAD")
        XCTAssertEqual((formula as? PackageProviding)?.packageRef, PackageRef(manager: .formula, name: "withgraphite/tap/graphite"))
        XCTAssertEqual(formula.sudo, .never)

        let cask = try sandbox.parse("cask: dropbox\napp: Dropbox\nlaunch: true").action
        XCTAssertEqual(cask.title, "dropbox")
        XCTAssertEqual(cask.subtitle, "Dropbox.app")
        XCTAssertEqual(cask.sudo, .maybe)
        XCTAssertEqual((cask as? PackageProviding)?.packageRef, PackageRef(manager: .cask, name: "dropbox"))

        let tap = try sandbox.parse("tap: nikitabobko/tap\ntrusted: true").action
        XCTAssertEqual((tap as? PackageProviding)?.packageRef, PackageRef(manager: .tap, name: "nikitabobko/tap"))
        XCTAssertEqual(tap.subtitle, "trusted")

        let mas = try sandbox.parse("mas: 937984704\nname: Amphetamine").action
        XCTAssertEqual(mas.title, "Amphetamine")
        XCTAssertEqual(mas.sudo, .always)
        XCTAssertEqual((mas as? PackageProviding)?.packageRef, PackageRef(manager: .mas, name: "937984704", label: "Amphetamine"))

        let npm = try sandbox.parse("npm: ghostty-config-cli").action
        XCTAssertEqual((npm as? PackageProviding)?.packageRef, PackageRef(manager: .npm, name: "ghostty-config-cli"))

        let download = try sandbox.parse("download: https://dl.aeromail.ai/desktop/dogfood/Aero-Dogfood-latest-mac-universal.dmg\napp: Aero Dogfood.app\nteam_id: ZL4K35VM2L").action
        XCTAssertEqual(download.title, "Aero Dogfood")
        XCTAssertEqual(download.sudo, .never)
        XCTAssertNil(download as? PackageProviding)
        let package = try sandbox.parse("download: https://example.com/files/Thing%20Installer.pkg").action
        XCTAssertEqual(package.title, "Thing-Installer")
        XCTAssertEqual(package.sudo, .always)

        let script = try sandbox.parse("script: Claude Code\nrun: |\n  curl -fsSL https://claude.ai/install.sh | bash\n  echo done\ncreates: ~/.local/bin/claude").action
        XCTAssertEqual(script.title, "Claude Code")
        XCTAssertEqual(script.subtitle, "curl -fsSL https://claude.ai/install.sh | bash …")
        XCTAssertEqual(script.sudo, .never)
        XCTAssertEqual(try sandbox.parse("script: Root thing\nrun: id\nsudo: true").action.sudo, .always)

        XCTAssertEqual(try sandbox.parse("xcode: download").action.title, "Xcode")
        let finish = try XCTUnwrap(try sandbox.parse("xcode: finish\ntimeout_minutes: 5\nplatforms: [ios, visionOS]").action as? XcodeAction)
        XCTAssertEqual(finish.timeout, 300)
        XCTAssertEqual(finish.platforms, ["iOS", "visionOS"])
        XCTAssertEqual(try sandbox.parse("homebrew: install\nmethod: script").action.subtitle, "install.sh")
        XCTAssertEqual(try sandbox.parse("xcode-clt: install").action.sudo, .always)
        XCTAssertEqual(try sandbox.parse("rosetta: install").action.title, "Rosetta 2")
    }

    func testBadItemsAreRejectedWithHelpfulMessages() {
        let sandbox = Sandbox()
        func expect(_ yaml: String, _ fragment: String, line: UInt = #line) {
            let messages = sandbox.errors(yaml, line: line)
            XCTAssertTrue(messages.contains { $0.contains(fragment) }, "\(yaml) → \(messages)", line: line)
        }

        expect("xcode-clt: yes", "takes the value 'install'")
        expect("homebrew: install\nmethod: curl", "must be one of: pkg, script")
        expect("rosetta: please", "takes the value 'install'")
        expect("xcode: install", "takes 'download' or 'finish'")
        expect("xcode: download\ntimeout_minutes: 10", "only applies to 'xcode: finish'")
        expect("xcode: download\nplatforms: [iOS]", "only applies to 'xcode: finish'")
        expect("xcode: finish\ntimeout_minutes: 0", "greater than 0")
        expect("xcode: finish\nplatforms: [android]", "must be among iOS, watchOS, tvOS, visionOS")
        expect("tap: buildkite", "must look like user/repo")
        expect("tap: buildkite/buildkite\ntrsted: true", "Did you mean 'trusted'")
        // The keys every item takes are read before the kind's own, and a typo of one still gets its suggestion.
        expect("brew: eza\noptionl: true", "unknown key 'optionl'. Did you mean 'optional'?")
        expect("brew: eza\nnmae: Eza", "unknown key 'nmae'. Did you mean 'name'?")
        expect("brew: eza\nnotes: fast ls", "unknown key 'notes'. Did you mean 'note'?")
        expect("tap: a/b\ntrusted: maybe", "must be true or false")
        expect("brew: foo/bar", "user/tap/name")
        expect("brew: has space", "user/tap/name")
        expect("brew: eza\nargs: {a: b}", "'args' must be a list of strings")
        expect("brew: [eza, fd]", "'brew' needs a value")
        expect("cask: ghostty\nlaunch: true", "'launch: true' needs 'app:'")
        expect("cask: ghostty\nappp: Ghostty.app", "Did you mean 'app'")
        expect("mas: 937984704", "need 'name:'")
        expect("mas: amphetamine\nname: Amphetamine", "numeric App Store id")
        expect("npm: two packages", "one package name")
        expect("download: ftp://example.com/x.dmg", "address of a .dmg, .zip or .pkg")
        expect("download: https://example.com/download?platform=mac", "add 'type: dmg'")
        expect("download: https://example.com/x.dmg\ntype: iso", "must be one of: auto, dmg, zip, pkg")
        expect("download: https://example.com/x.dmg\nsha256: abc", "64 hexadecimal")
        expect("download: https://example.com/x.dmg\nteam_id: nope", "10-character Developer ID team")
        expect("download: https://example.com/x.dmg\nverify: false\nteam_id: ZL4K35VM2L", "only checked when 'verify' is true")
        expect("download: https://example.com/x.dmg\napp: Sub/Thing.app", "use 'to:' for where it goes")
        expect("download: https://example.com/x.pkg\nlaunch: true", "needs 'app:'")
        expect("script: Thing", "missing required key 'run'")
        expect("script: Thing\nrun: ''", "must not be empty")
        expect("script: Thing\nrun: echo\nshell: fish", "must be one of: bash, zsh, sh")
        expect("script: Thing\nrun: echo\nenv: {1BAD: x}", "not a valid environment variable name")
        expect("script: Thing\nrun: echo\ntimeout: -1", "greater than 0")
        expect("script: Thing\nrun: echo\ncheck: '  '", "'check' must not be empty")
        expect("script: Thing\nrun: echo\ncreats: /tmp/x", "Did you mean 'creates'")
    }

    func testAllProblemsInOneItemAreReportedTogether() {
        let messages = Sandbox().errors("download: https://example.com/x.dmg\nsha256: abc\nteam_id: nope\nlaunchh: true")
        XCTAssertEqual(messages.count, 3, "\(messages)")
    }

    func testValidationFlagsUnknownVariables() throws {
        let sandbox = Sandbox()
        let script = try sandbox.parse("script: Thing\nrun: echo {{flavor}} {{nope}}\ncreates: '{{home}}/x'\nenv: {K: '{{missing}}'}")
        let messages = sandbox.validate(script)
        XCTAssertEqual(messages.count, 2, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("'run' uses unknown variable {{nope}}") })
        XCTAssertTrue(messages.contains { $0.contains("'env.K' uses unknown variable {{missing}}") })

        let download = try sandbox.parse("download: https://example.com/{{version}}/x.dmg\napp: X.app")
        XCTAssertEqual(sandbox.validate(download), ["'download' uses unknown variable {{version}}"])
        XCTAssertEqual(sandbox.validate(try sandbox.parse("download: https://example.com/x.dmg\nto: '{{applications}}'")), [])
    }

    func testTypeDetectionAndFileNames() {
        XCTAssertEqual(DownloadAction.detectType("https://x.com/a/b.DMG"), .dmg)
        XCTAssertEqual(DownloadAction.detectType("https://x.com/a/b.zip?token=1"), .zip)
        XCTAssertEqual(DownloadAction.detectType("https://x.com/a/b.mpkg#x"), .pkg)
        XCTAssertNil(DownloadAction.detectType("https://x.com/download"))
        XCTAssertEqual(DownloadAction.fileName(of: "https://x.com/a/My%20App%201.2.dmg?x=1"), "My-App-1.2.dmg")
        XCTAssertEqual(DownloadAction.fileName(of: "https://x.com/"), "x.com")
    }
}
