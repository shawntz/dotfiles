import Foundation
import XCTest
import ShawnCore
@testable import ShawnSync

final class ConfigResolverTests: XCTestCase {
    private var temp: TempDirectory!
    private var environment: SystemEnvironment!
    private var transport: FakeTransport!
    private var bundle: Bundle!

    override func setUpWithError() throws {
        temp = TempDirectory()
        environment = SystemEnvironment.testSandbox(temp)
        transport = FakeTransport()
        FakeRepo.standard().serve(on: transport)
        // An empty app bundle: no bundled config unless a test writes one.
        temp.write("Empty.app/Contents/Info.plist", "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>")
        bundle = try XCTUnwrap(Bundle(path: temp.url.appendingPathComponent("Empty.app").path))
    }

    override func tearDown() {
        temp = nil
    }

    private func resolve(_ options: ConfigResolveOptions = ConfigResolveOptions()) async throws -> ResolvedConfig {
        try await ConfigResolver.resolve(options: options, registry: testRegistry(), environment: environment,
                                         bundle: bundle, transport: transport)
    }

    private func useCheckout() throws -> URL {
        let checkout = writeConfig(in: temp, at: "home/Developer/dotfiles/installer/config", name: "Checkout")
        let settingsFile = ShawnSettings.fileURL(environment: environment)
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(ShawnSettings(dotfilesRepo: "~/Developer/dotfiles").yaml.utf8).write(to: settingsFile)
        return checkout
    }

    func testInstalledSnapshotIsUpgradedFromGitHub() async throws {
        writeConfig(in: temp, at: "home/.shawn/config", name: "Installed")

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.meta.name, "Remote Dotfiles")
        XCTAssertEqual(resolved.config.source, .remote(repo: "octo/dots", ref: "main", commit: FakeRepo.commitSHA("first")))
    }

    func testCheckoutIsUsedAsIsWithoutAnyRequest() async throws {
        let checkout = try useCheckout()

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.meta.name, "Checkout")
        XCTAssertEqual(resolved.config.source, .local(checkout.standardizedFileURL.path))
        XCTAssertEqual(transport.urls, [], "local, unpushed edits in the checkout must not be replaced by GitHub's copy")
    }

    func testAnExplicitRemoteRefIsFetchedEvenWithACheckout() async throws {
        _ = try useCheckout()
        FakeRepo.standard().serve(on: transport, ref: "experiment")

        let resolved = try await resolve(ConfigResolveOptions(remoteRef: "experiment"))

        XCTAssertEqual(resolved.config.source, .remote(repo: "octo/dots", ref: "experiment", commit: FakeRepo.commitSHA("first")))
    }

    func testExplicitPathAndNoRemoteNeverTouchTheNetwork() async throws {
        writeConfig(in: temp, at: "home/.shawn/config", name: "Installed")
        let explicit = writeConfig(in: temp, at: "explicit", name: "Explicit")

        let fromExplicit = try await resolve(ConfigResolveOptions(explicitPath: explicit))
        let withoutRemote = try await resolve(ConfigResolveOptions(allowRemote: false))

        XCTAssertEqual(fromExplicit.config.meta.name, "Explicit")
        XCTAssertEqual(withoutRemote.config.meta.name, "Installed")
        XCTAssertEqual(transport.urls, [])
    }

    func testAConfigWithoutARemoteBlockStaysLocal() async throws {
        temp.write("home/.shawn/config/installer.yaml", "schema: 1\nname: No Remote\n")
        temp.write("home/.shawn/config/steps/01.yaml", "id: one\ntitle: One\nitems:\n  - ok: x\n")

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.meta.name, "No Remote")
        XCTAssertEqual(transport.urls, [])
    }

    func testFallbackNoteNamesTheLocalConfig() async throws {
        writeConfig(in: temp, at: "home/.shawn/config", name: "Installed")
        transport.fail("https://api.github.com/repos/octo/dots/commits/main", with: URLError(.notConnectedToInternet))

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.meta.name, "Installed")
        XCTAssertEqual(resolved.notes.count, 1)
        XCTAssertTrue(resolved.notes[0].hasPrefix("Using the config at ~/.shawn/config. The latest config from GitHub (octo/dots@main) did not arrive:"), resolved.notes[0])
    }

    func testBundledConfigIsLabelledAsBundled() async throws {
        writeConfig(in: temp, at: "Bundled.app/Contents/Resources/config", name: "Bundled")
        temp.write("Bundled.app/Contents/Info.plist", "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>")
        bundle = try XCTUnwrap(Bundle(path: temp.url.appendingPathComponent("Bundled.app").path))
        transport.fail("https://api.github.com/repos/octo/dots/commits/main", with: URLError(.cannotFindHost))

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.source, .bundled)
        XCTAssertTrue(resolved.notes[0].hasPrefix("Using the config bundled with this installer. "), resolved.notes[0])
    }

    func testMissingExplicitPathIsAnError() async throws {
        writeConfig(in: temp, at: "home/.shawn/config", name: "Installed")
        let typo = temp.url.appendingPathComponent("no-such-config")

        do {
            _ = try await resolve(ConfigResolveOptions(explicitPath: typo))
            XCTFail("expected an error")
        } catch let error as ConfigResolveError {
            XCTAssertTrue(error.message.contains("There is no config at \(typo.path)"), error.message)
        }
    }

    func testNoConfigAnywhereListsWhereItLooked() throws {
        XCTAssertThrowsError(try ConfigResolver.resolveLocal(options: ConfigResolveOptions(), registry: testRegistry(),
                                                             environment: environment, bundle: bundle)) { error in
            let message = (error as? ConfigResolveError)?.message ?? ""
            XCTAssertTrue(message.hasPrefix("No config found. Looked in:"), message)
            XCTAssertTrue(message.contains(ConfigLocator.installedConfigDirectory(environment: environment).path), message)
        }
    }

    func testInvalidLocalConfigIsAnErrorListingEveryIssue() throws {
        temp.write("home/.shawn/config/installer.yaml", "schema: 1\nname: Broken\n")
        temp.write("home/.shawn/config/steps/01.yaml", "id: one\ntitle: One\nitems:\n  - teleport: x\n  - ok: y\n    colour: red\n")

        XCTAssertThrowsError(try ConfigResolver.resolveLocal(options: ConfigResolveOptions(), registry: testRegistry(),
                                                             environment: environment, bundle: bundle)) { error in
            guard let error = error as? ConfigResolveError else { return XCTFail("unexpected error \(error)") }
            XCTAssertEqual(error.issues.count, 2, error.description)
            XCTAssertTrue(error.description.contains("teleport"), error.description)
            XCTAssertTrue(error.description.contains("colour"), error.description)
        }
    }

    // MARK: A snapshot that no longer loads

    /// `~/.shawn/config` written by an older build: its item uses an option this build no longer accepts.
    private func writeStaleSnapshot() {
        temp.write("home/.shawn/config/installer.yaml", metaYAML(name: "Stale Snapshot"))
        temp.write("home/.shawn/config/steps/01.yaml", "id: one\ntitle: One\nitems:\n  - ok: x\n    retired_option: 1\n")
    }

    private func useBundledConfig() throws {
        writeConfig(in: temp, at: "Bundled.app/Contents/Resources/config", name: "Bundled")
        temp.write("Bundled.app/Contents/Info.plist", "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>")
        bundle = try XCTUnwrap(Bundle(path: temp.url.appendingPathComponent("Bundled.app").path))
    }

    private func assertNamesTheStaleSnapshot(_ note: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let note else { return XCTFail("expected a note about ~/.shawn/config", file: file, line: line) }
        XCTAssertTrue(note.hasPrefix("Skipped the config at ~/.shawn/config"), note, file: file, line: line)
        XCTAssertTrue(note.contains("retired_option"), note, file: file, line: line)
    }

    func testAStaleSnapshotIsSkippedForGitHubsConfig() async throws {
        writeStaleSnapshot()
        try useBundledConfig()

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.source, .remote(repo: "octo/dots", ref: "main", commit: FakeRepo.commitSHA("first")))
        XCTAssertEqual(resolved.notes.count, 1, resolved.notes.joined(separator: "\n"))
        assertNamesTheStaleSnapshot(resolved.notes.first)
    }

    func testAStaleSnapshotFallsBackToTheBundledConfigWhenGitHubFails() async throws {
        writeStaleSnapshot()
        try useBundledConfig()
        transport.fail("https://api.github.com/repos/octo/dots/commits/main", with: URLError(.notConnectedToInternet))

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.source, .bundled)
        XCTAssertEqual(resolved.config.meta.name, "Bundled")
        XCTAssertEqual(resolved.notes.count, 2, resolved.notes.joined(separator: "\n"))
        assertNamesTheStaleSnapshot(resolved.notes.first)
        XCTAssertTrue(resolved.notes.last?.hasPrefix("Using the config bundled with this installer. The latest config from GitHub (octo/dots@main) did not arrive:") == true,
                      resolved.notes.last ?? "")
    }

    func testResolveLocalSkipsAStaleSnapshotForTheBundledConfig() throws {
        writeStaleSnapshot()
        try useBundledConfig()

        let resolved = try ConfigResolver.resolveLocal(options: ConfigResolveOptions(), registry: testRegistry(),
                                                       environment: environment, bundle: bundle)

        XCTAssertEqual(resolved.config.source, .bundled)
        assertNamesTheStaleSnapshot(resolved.notes.first)
    }

    func testAStaleSnapshotWithoutABundleUsesItsRemoteBlockToReachGitHub() async throws {
        // The installed `shawn` binary has no app bundle; the snapshot's `remote:` block is still readable.
        writeStaleSnapshot()

        let resolved = try await resolve()

        XCTAssertEqual(resolved.config.source, .remote(repo: "octo/dots", ref: "main", commit: FakeRepo.commitSHA("first")))
        assertNamesTheStaleSnapshot(resolved.notes.first)
    }

    func testAStaleSnapshotWithNothingElseToUseIsAnErrorThatSaysWhatToDo() async throws {
        writeStaleSnapshot()
        transport.fail("https://api.github.com/repos/octo/dots/commits/main", with: URLError(.notConnectedToInternet))

        do {
            _ = try await resolve()
            XCTFail("expected an error")
        } catch let error as ConfigResolveError {
            XCTAssertTrue(error.message.hasPrefix("The config at \(temp.url.path)/home/.shawn/config has problems."), error.message)
            XCTAssertTrue(error.message.contains("a previous install left for the `shawn` CLI"), error.message)
            XCTAssertTrue(error.message.contains("octo/dots@main"), error.message)
            XCTAssertTrue(error.message.contains("offline"), error.message)
            XCTAssertTrue(error.message.contains("Run the latest Shawn's Dotfiles installer"), error.message)
            XCTAssertEqual(error.issues.count, 1)
            XCTAssertTrue(error.description.contains("retired_option"), error.description)
        }
    }

    func testABrokenWorkingCopyIsStillAnErrorEvenWithOtherConfigsAround() async throws {
        temp.write("home/Developer/dotfiles/installer/config/installer.yaml", metaYAML(name: "Checkout"))
        temp.write("home/Developer/dotfiles/installer/config/steps/01.yaml", "id: one\ntitle: One\nitems:\n  - ok: x\n    colour: red\n")
        let settingsFile = ShawnSettings.fileURL(environment: environment)
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(ShawnSettings(dotfilesRepo: "~/Developer/dotfiles").yaml.utf8).write(to: settingsFile)
        writeConfig(in: temp, at: "home/.shawn/config", name: "Installed")
        try useBundledConfig()

        do {
            _ = try await resolve()
            XCTFail("a broken working copy must not be replaced silently")
        } catch let error as ConfigResolveError {
            XCTAssertTrue(error.message.contains("home/Developer/dotfiles/installer/config has problems"), error.message)
            XCTAssertTrue(error.description.contains("colour"), error.description)
        }
        XCTAssertEqual(transport.urls, [])
    }

    func testABrokenExplicitPathIsStillAnErrorEvenWithARemoteRef() async throws {
        temp.write("explicit/installer.yaml", metaYAML(name: "Explicit"))
        temp.write("explicit/steps/01.yaml", "id: one\ntitle: One\nitems:\n  - ok: x\n    colour: red\n")
        writeConfig(in: temp, at: "home/.shawn/config", name: "Installed")
        try useBundledConfig()

        do {
            _ = try await resolve(ConfigResolveOptions(explicitPath: temp.url.appendingPathComponent("explicit"), remoteRef: "main"))
            XCTFail("expected an error")
        } catch let error as ConfigResolveError {
            XCTAssertTrue(error.message.contains("explicit has problems"), error.message)
        }
        XCTAssertEqual(transport.urls, [])
    }

    // MARK: An explicit path with a remote ref

    func testAnExplicitRemoteRefIsFetchedForAnExplicitPath() async throws {
        let explicit = writeConfig(in: temp, at: "explicit", name: "Explicit")
        FakeRepo.standard().serve(on: transport, ref: "experiment")

        let resolved = try await resolve(ConfigResolveOptions(explicitPath: explicit, remoteRef: "experiment"))

        XCTAssertEqual(resolved.config.source, .remote(repo: "octo/dots", ref: "experiment", commit: FakeRepo.commitSHA("first")))
    }

    func testARemoteRefThatCannotBeUsedIsReportedNotDropped() async throws {
        let explicit = writeConfig(in: temp, at: "explicit", name: "Explicit")
        temp.write("plain/installer.yaml", "schema: 1\nname: No Remote\n")
        temp.write("plain/steps/01.yaml", "id: one\ntitle: One\nitems:\n  - ok: x\n")

        let remoteOff = try await resolve(ConfigResolveOptions(explicitPath: explicit, allowRemote: false, remoteRef: "experiment"))
        let noRemoteBlock = try await resolve(ConfigResolveOptions(explicitPath: temp.url.appendingPathComponent("plain"), remoteRef: "experiment"))

        XCTAssertEqual(remoteOff.config.meta.name, "Explicit")
        XCTAssertEqual(remoteOff.notes.count, 1)
        let offNote = remoteOff.notes.first ?? ""
        XCTAssertTrue(offNote.contains("'experiment'") && offNote.contains("turned off"), offNote)
        XCTAssertEqual(noRemoteBlock.config.meta.name, "No Remote")
        XCTAssertEqual(noRemoteBlock.notes.count, 1)
        let blockNote = noRemoteBlock.notes.first ?? ""
        XCTAssertTrue(blockNote.contains("'experiment'") && blockNote.contains("no `remote:` block"), blockNote)
        XCTAssertEqual(transport.urls, [])
    }

    func testABlankRemoteRefDoesNotOverrideAWorkingCopy() async throws {
        _ = try useCheckout()

        let resolved = try await resolve(ConfigResolveOptions(remoteRef: "  "))

        XCTAssertEqual(resolved.config.meta.name, "Checkout")
        XCTAssertEqual(resolved.notes, [])
        XCTAssertEqual(transport.urls, [])
    }

    // MARK: Pieces

    func testLoadKeepsNotesAndSource() throws {
        let root = writeConfig(in: temp, at: "somewhere")
        let resolved = try ConfigResolver.load(directory: root, source: .bundled, registry: testRegistry(),
                                               environment: environment, notes: ["hello"])
        XCTAssertEqual(resolved.notes, ["hello"])
        XCTAssertEqual(resolved.config.source, .bundled)
        XCTAssertEqual(resolved.plan.allItems.count, 1)
    }

    func testDefaultOptions() {
        let options = ConfigResolveOptions()
        XCTAssertNil(options.explicitPath)
        XCTAssertTrue(options.allowRemote)
        XCTAssertNil(options.remoteRef)
        XCTAssertEqual(options.remoteTimeout, 20)
    }
}
