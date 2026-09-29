import XCTest
import AppKit
@testable import Yabaibye

final class ForegroundKeeperTests: XCTestCase {
    @MainActor private final class Probe {
        var time: TimeInterval = 0
        var current = true
        var result: AXError = .success
        var raised: [UInt32] = []
        var observation: ForegroundKeeper.Observation? = Probe.makeObservation()
        lazy var keeper = ForegroundKeeper(
            observe: { [unowned self] in observation },
            isCurrent: { [unowned self] _ in current },
            raise: { [unowned self] item in
                raised.append(item.windowID)
                return result
            },
            now: { [unowned self] in time }
        )

        static func makeObservation(windowID: UInt32 = 10, obstructionID: UInt32 = 20,
                                    frame: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400)) -> ForegroundKeeper.Observation {
            // The injected raise callback never messages this placeholder.
            ForegroundKeeper.Observation(pid: 900001, windowID: windowID,
                element: AXUIElementCreateApplication(900001), obstructionID: obstructionID, frame: frame)
        }

        func refresh(at time: TimeInterval) {
            self.time = time
            keeper.refresh()
        }
    }

    @MainActor func testFailedRaiseRetriesAfterBackoff() {
        let probe = Probe()
        probe.result = .cannotComplete
        probe.refresh(at: 0)
        XCTAssertEqual(probe.raised, [10])
        probe.refresh(at: 0.2)
        XCTAssertEqual(probe.raised, [10])
        probe.result = .success
        probe.refresh(at: 0.41)
        XCTAssertEqual(probe.raised, [10, 10])
    }

    @MainActor func testSuccessfulRaiseStillRetriesWhenObstructionRemains() {
        let probe = Probe()
        probe.refresh(at: 0)
        probe.refresh(at: 0.2)
        XCTAssertEqual(probe.raised, [10])
        probe.refresh(at: 0.41)
        XCTAssertEqual(probe.raised, [10, 10])
        probe.refresh(at: 1.0)
        XCTAssertEqual(probe.raised.count, 2)
        probe.refresh(at: 1.22)
        XCTAssertEqual(probe.raised.count, 3)
    }

    @MainActor func testPersistentObstructionHasFourAttemptLimit() {
        let probe = Probe()
        probe.result = .cannotComplete
        for time in [0.0, 0.41, 1.22, 2.83] { probe.refresh(at: time) }
        XCTAssertEqual(probe.raised.count, 4)
        for time in [5.0, 60.0, 3600.0] { probe.refresh(at: time) }
        XCTAssertEqual(probe.raised.count, 4)
    }

    @MainActor func testClearObservationAllowsLaterObstructionToRecover() {
        let probe = Probe()
        for time in [0.0, 0.41, 1.22, 2.83] { probe.refresh(at: time) }
        probe.observation = nil
        probe.refresh(at: 3)
        XCTAssertEqual(probe.raised.count, 4)
        probe.observation = Probe.makeObservation()
        probe.refresh(at: 3.01)
        XCTAssertEqual(probe.raised.count, 5)
    }

    @MainActor func testFocusChangeRejectsStaleWindowAndResetsRetryState() {
        let probe = Probe()
        probe.current = false
        probe.refresh(at: 0)
        XCTAssertTrue(probe.raised.isEmpty)
        probe.current = true
        probe.refresh(at: 0)
        XCTAssertEqual(probe.raised, [10])
        probe.current = false
        probe.refresh(at: 0.1)
        XCTAssertEqual(probe.raised, [10])
        probe.current = true
        probe.refresh(at: 0.11)
        XCTAssertEqual(probe.raised, [10, 10])
    }

    @MainActor func testDifferentFocusedWindowInSameAppStartsNewAttempt() {
        let probe = Probe()
        for time in [0.0, 0.41, 1.22, 2.83] { probe.refresh(at: time) }
        probe.observation = Probe.makeObservation(windowID: 11)
        probe.refresh(at: 2.84)
        XCTAssertEqual(probe.raised, [10, 10, 10, 10, 11])
    }

    @MainActor func testChangedFrameStartsNewAttemptAfterLimit() {
        let probe = Probe()
        for time in [0.0, 0.41, 1.22, 2.83] { probe.refresh(at: time) }
        probe.observation = Probe.makeObservation(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        probe.refresh(at: 2.84)
        XCTAssertEqual(probe.raised.count, 5)
    }

    @MainActor func testStopClearsRetryState() {
        let probe = Probe()
        for time in [0.0, 0.41, 1.22, 2.83] { probe.refresh(at: time) }
        probe.keeper.stop()
        probe.refresh(at: 2.84)
        XCTAssertEqual(probe.raised.count, 5)
    }

    @MainActor func testDifferentObstructionStartsNewEpisodeAfterLimit() {
        let probe = Probe()
        for time in [0.0, 0.41, 1.22, 2.83] { probe.refresh(at: time) }
        XCTAssertEqual(probe.raised.count, 4)
        probe.observation = Probe.makeObservation(obstructionID: 21)
        probe.refresh(at: 2.84)
        XCTAssertEqual(probe.raised.count, 5)
        probe.refresh(at: 3.0)
        XCTAssertEqual(probe.raised.count, 5)
        probe.refresh(at: 3.25)
        XCTAssertEqual(probe.raised.count, 6)
    }
}
