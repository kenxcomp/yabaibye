import XCTest
import CoreGraphics
@testable import YabaibyeCore

final class CoreTests: XCTestCase {
    let first = DisplaySpaces(uuid: "A", current: 12, spaces: [Desktop(id: 11), Desktop(id: 90, type: 4), Desktop(id: 12)])
    let second = DisplaySpaces(uuid: "B", current: 21, spaces: [Desktop(id: 21), Desktop(id: 22)])
    func testGlobalNumberingSkipsFullscreenButPreservesAXIndex() {
        let target = SpaceRouter.numbered(2, displays: [first, second])
        XCTAssertEqual(target?.desktop.id, 12)
        XCTAssertEqual(target?.missionControlIndex, 2)
        XCTAssertEqual(SpaceRouter.numbered(3, displays: [first, second])?.display.uuid, "B")
    }
    func testMissingSpaceIsNotClamped() {
        for n in [-1, 0, 5, 9] { XCTAssertNil(SpaceRouter.numbered(n, displays: [first, second])) }
    }
    func testRelativeNavigationStaysOnItsDisplayAndStopsAtEdges() {
        XCTAssertNil(SpaceRouter.adjacent(1, display: first))
        XCTAssertEqual(SpaceRouter.adjacent(-1, display: first)?.desktop.id, 90)
        XCTAssertNil(SpaceRouter.adjacent(-1, display: second))
        XCTAssertEqual(SpaceRouter.adjacent(1, display: second)?.desktop.id, 22)
    }
    func testAllRequestedBindingsAreUnique() {
        let bindings = Binding.defaults
        XCTAssertEqual(bindings.count, 28)
        XCTAssertEqual(Set(bindings.map { "\($0.keyCode):\($0.shift):\($0.control)" }).count, 28)
        XCTAssertEqual(bindings.first { $0.keyCode == 36 }?.command, .toggleZoom)
        let letters: [UInt32] = [0, 11, 8, 2, 14, 3, 5, 4, 34]
        for (i, key) in letters.enumerated() {
            XCTAssertEqual(bindings.first { $0.keyCode == key && !$0.shift }?.command, .focusSpace(i + 1))
            XCTAssertEqual(bindings.first { $0.keyCode == key && $0.shift }?.command, .moveToSpace(i + 1))
        }
    }
    func testTilingIsInsideWorkAreaAndNeverOverlaps() {
        for bounds in [CGRect(x: 0, y: 30, width: 1440, height: 850), CGRect(x: -1200, y: -500, width: 1000, height: 1600)] {
            for count in 1...24 {
                let frames = Layout.frames(count: count, in: bounds)
                XCTAssertEqual(frames.count, count)
                for (i, frame) in frames.enumerated() {
                    XCTAssertTrue(bounds.contains(frame)); XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
                    for other in frames.dropFirst(i + 1) { XCTAssertFalse(frame.intersects(other)) }
                }
            }
        }
    }
    func testDirectionUsesTopLeftCoordinateSystem() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 110, y: 0, width: 100, height: 100),
                      CGRect(x: 0, y: 110, width: 100, height: 100), CGRect(x: 110, y: 110, width: 100, height: 100)]
        XCTAssertEqual(Layout.neighbor(of: 0, direction: .right, frames: frames), 1)
        XCTAssertEqual(Layout.neighbor(of: 0, direction: .down, frames: frames), 2)
        XCTAssertEqual(Layout.neighbor(of: 3, direction: .up, frames: frames), 1)
        XCTAssertEqual(Layout.neighbor(of: 3, direction: .left, frames: frames), 2)
        XCTAssertNil(Layout.neighbor(of: 0, direction: .up, frames: frames))
        XCTAssertNil(Layout.neighbor(of: 0, direction: .left, frames: frames))
    }
    func testEmptyLayoutAndInvalidFocusAreSafe() {
        XCTAssertEqual(Layout.frames(count: 0, in: .zero), [])
        XCTAssertNil(Layout.neighbor(of: 9, direction: .left, frames: []))
    }
}
