import XCTest
@testable import YabaibyeCore

final class LayoutApplicationTests: XCTestCase {
    func testFailureRemainsPendingAndSuccessStopsRetries() {
        let layout = TileLayout(ids: ["A", "B"])
        var state = LayoutApplication()
        XCTAssertTrue(state.needsApply(layout, signature: "screen", now: 100))
        state.failed(layout, signature: "screen", now: 100)
        XCTAssertFalse(state.needsApply(layout, signature: "screen", now: 100.5))
        XCTAssertTrue(state.needsApply(layout, signature: "screen", now: 101))
        state.succeeded(layout, signature: "screen")
        XCTAssertFalse(state.needsApply(layout, signature: "screen", now: 1000))
        // A later partial/cancelled write cannot leave the old confirmed cache valid.
        state.failed(layout, signature: "screen", now: 1000)
        XCTAssertTrue(state.needsApply(layout, signature: "screen", now: 1001))
    }
    func testRetryBackoffIsBoundedAndDoesNotBlockNewRequests() {
        let layout = TileLayout(ids: ["A", "B"])
        var state = LayoutApplication()
        for _ in 0..<50 { state.failed(layout, signature: "screen", now: 10) }
        XCTAssertEqual(state.retryAfter, 25)
        XCTAssertFalse(state.needsApply(layout, signature: "screen", now: 11))
        XCTAssertTrue(state.needsApply(layout, signature: "resized", now: 11))
        XCTAssertTrue(state.needsApply(TileLayout(ids: ["A"]), signature: "screen", now: 11))
        XCTAssertTrue(state.needsApply(layout, signature: "screen", now: 11, force: true))
    }
}
