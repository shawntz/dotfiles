import XCTest
@testable import ActionsPackages
import ShawnCore

/// The shipped `config/steps/03-packages.yaml`, parsed with this module's kinds and run against a sandbox.
final class ShippedPackagesConfigTests: XCTestCase {
    private var configRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("config")
    }

    private func packagesItems(_ sandbox: Sandbox) throws -> [(item: ItemConfig, action: any Action)] {
        let config = try ConfigLoader.load(from: configRoot).config
        let step = try XCTUnwrap(config.steps.first { $0.id == "packages" })
        let registry = sandbox.registry()
        return try step.rawItems.enumerated().map { index, raw in
            try registry.resolve(raw, stepID: step.id, index: index).get()
        }
    }

    func testTheOldVercelFormulaIsRetiredRightBeforeTheCaskInstalls() async throws {
        let sandbox = Sandbox()
        let items = try packagesItems(sandbox)
        let caskIndex = try XCTUnwrap(items.firstIndex { $0.item.kind == "cask" && $0.item.value.string == "vercel" })
        XCTAssertGreaterThan(caskIndex, 0)
        let retire = items[caskIndex - 1]
        XCTAssertEqual(retire.item.kind, "script")
        let script = try XCTUnwrap(retire.action as? ScriptAction)
        XCTAssertEqual(script.sudo, .never)

        // Homebrew's side of it: uninstalling the formula removes its rack, reinstalling the cask relinks it.
        let prefix = sandbox.brewPrefix.path
        sandbox.shim("brew", at: sandbox.brewBin, """
        case "$1" in
          uninstall) rm -rf "\(prefix)/Cellar/vercel" ;;
          reinstall) mkdir -p "\(prefix)/Caskroom/vercel/65.16.0" ;;
          *) echo "unexpected brew call: $*" >&2; exit 64 ;;
        esac
        """)
        let context = sandbox.context(retire.item)

        // A fresh Mac has no vercel formula: nothing to do.
        let fresh = await script.check(context)
        XCTAssertTrue(fresh.isSatisfied, "\(fresh)")

        // The old laptop: the orphaned formula owns bin/vercel, and the cask is not installed yet.
        sandbox.directory.mkdir("homebrew/Cellar/vercel/62.7.0")
        let oldLaptop = await script.check(context)
        XCTAssertEqual(oldLaptop, .needed(nil))
        let outcome = try await script.run(context)
        XCTAssertEqual(outcome, .done(nil))
        XCTAssertEqual(sandbox.calls("brew"), ["brew uninstall --formula --ignore-dependencies vercel"])
        let afterward = await script.check(context)
        XCTAssertTrue(afterward.isSatisfied, "\(afterward)")

        // A Mac where the cask went in while the formula still held the links (Homebrew skipped them):
        // the cask is reinstalled once the formula is gone, so its binaries get linked.
        sandbox.clearCalls()
        sandbox.directory.mkdir("homebrew/Cellar/vercel/62.7.0")
        sandbox.directory.mkdir("homebrew/Caskroom/vercel/65.16.0")
        _ = try await script.run(context)
        XCTAssertEqual(sandbox.calls("brew"), ["brew uninstall --formula --ignore-dependencies vercel", "brew reinstall --cask vercel"])
    }
}
