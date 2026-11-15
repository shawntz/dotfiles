import XCTest
@testable import ShawnUI

/// The running screen's NOW line: the step, then the item, unless the item only says the step again.
@MainActor
final class NowLineTests: XCTestCase {
    func testAnItemThatOnlyRepeatsItsStepIsLeftOff() {
        XCTAssertTrue(NowCard.repeats("Dock", step: "Dock"))
        XCTAssertTrue(NowCard.repeats("shawn CLI", step: "The shawn CLI"))
        XCTAssertTrue(NowCard.repeats("dropbox", step: "Dropbox"))
        XCTAssertFalse(NowCard.repeats("git", step: "Git & GitHub"), "a step whose title holds an item's name is not that item")
        XCTAssertFalse(NowCard.repeats("Sign in to Dropbox", step: "Dropbox"))
    }
}
