import Foundation
import XCTest
import ShawnCore
// Deliberately not `@testable`: this file compiles only against ShawnSync's public API, the way the
// UI and CLI modules see it.
import ShawnSync

final class PublicAPITests: XCTestCase {
    func testALocationCanBeMadeOutsideTheModule() {
        let url = URL(fileURLWithPath: "/tmp/somewhere/config")
        let location = ConfigLocator.Location(url: url, source: .local(url.path), origin: .installed)

        XCTAssertEqual(location.url, url)
        XCTAssertEqual(location.source, .local(url.path))
        XCTAssertFalse(location.origin.isWorkingCopy)
    }
}
