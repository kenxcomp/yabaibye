import XCTest
import CoreGraphics
@testable import YabaibyeCore

final class TileLayoutTests: XCTestCase {
    let bounds = CGRect(x: -1200, y: 40, width: 1200, height: 800)
    func testThreeTilesUseTwoColumnsAndFillTheAvailableArea() {
        let frames = TileLayout(ids: ["A", "B", "C"]).frames(in: bounds, gap: 0)
        XCTAssertEqual(frames["A"], CGRect(x: -1200, y: 40, width: 600, height: 400))
        XCTAssertEqual(frames["B"], CGRect(x: -1200, y: 440, width: 600, height: 400))
        XCTAssertEqual(frames["C"], CGRect(x: -600, y: 40, width: 600, height: 800))
    }
    func testClosingFourthWindowKeepsTwoColumnGrid() {
        var layout = TileLayout(ids: ["A", "B", "C", "D"])
        layout.reconcile(["C", "B", "A"])
        XCTAssertEqual(layout, TileLayout(ids: ["A", "B", "C"]))
        XCTAssertFalse(layout.customized)
    }
    func testFourTilesFormGridEvenOnUltrawideDisplay() {
        let frames = TileLayout(ids: ["A", "B", "C", "D"]).frames(in: CGRect(x: 0, y: 0, width: 3440, height: 1440), gap: 0)
        XCTAssertEqual(frames["A"], CGRect(x: 0, y: 0, width: 1720, height: 720))
        XCTAssertEqual(frames["B"], CGRect(x: 0, y: 720, width: 1720, height: 720))
        XCTAssertEqual(frames["C"], CGRect(x: 1720, y: 0, width: 1720, height: 720))
        XCTAssertEqual(frames["D"], CGRect(x: 1720, y: 720, width: 1720, height: 720))
    }
    func testRequestedThreeWindowSequenceRebalancesToEqualColumns() {
        var layout = TileLayout(ids: ["A", "B", "C"])
        XCTAssertTrue(layout.drop("A", onto: "B", zone: .bottom))
        var f = layout.frames(in: bounds, gap: 0)
        XCTAssertEqual(f["B"], CGRect(x: -1200, y: 40, width: 600, height: 400))
        XCTAssertEqual(f["A"], CGRect(x: -1200, y: 440, width: 600, height: 400))
        XCTAssertEqual(f["C"], CGRect(x: -600, y: 40, width: 600, height: 800))
        XCTAssertTrue(layout.drop("A", onto: "C", zone: .right))
        XCTAssertEqual(layout.ids, ["B", "C", "A"])
        f = layout.frames(in: bounds, gap: 0)
        for (i, id) in ["B", "C", "A"].enumerated() {
            XCTAssertEqual(f[id], CGRect(x: -1200 + CGFloat(i) * 400, y: 40, width: 400, height: 800))
        }
    }
    func testCenterSwapsLeavesWithoutChangingPartitionGeometry() {
        var layout = TileLayout(ids: ["A", "B", "C"])
        layout.drop("A", onto: "B", zone: .bottom)
        let before = layout.frames(in: bounds)
        layout.drop("A", onto: "C", zone: .center)
        let after = layout.frames(in: bounds)
        XCTAssertEqual(after["A"], before["C"])
        XCTAssertEqual(after["C"], before["A"])
        XCTAssertEqual(after["B"], before["B"])
    }
    func testAllEdgesAndHitRegions() {
        let rect = CGRect(x: 100, y: 200, width: 800, height: 400)
        for (point, zone) in [(CGPoint(x: 500, y: 400), DropZone.center), (CGPoint(x: 120, y: 400), .left),
                              (CGPoint(x: 880, y: 400), .right), (CGPoint(x: 500, y: 210), .top), (CGPoint(x: 500, y: 590), .bottom)] {
            XCTAssertEqual(DropZone.hit(at: point, in: rect), zone)
            XCTAssertTrue(zone.preview(in: rect).contains(point))
        }
        XCTAssertNil(DropZone.hit(at: .zero, in: rect))
        for zone in DropZone.allCases {
            var layout = TileLayout(ids: ["A", "B"])
            XCTAssertTrue(layout.drop("A", onto: "B", zone: zone))
            XCTAssertEqual(Set(layout.ids), Set(["A", "B"]))
            let frames = layout.frames(in: bounds)
            XCTAssertFalse(frames["A"]!.intersects(frames["B"]!))
        }
    }
    func testReconcilePreservesCustomizedPartitionsAndRemovesEmptyGroups() {
        var layout = TileLayout(ids: ["A", "B", "C"])
        layout.drop("A", onto: "B", zone: .bottom)
        let custom = layout
        layout.reconcile(["C", "A", "B"])
        XCTAssertEqual(layout, custom)
        layout.reconcile(["B", "C"])
        XCTAssertEqual(layout.frames(in: bounds, gap: 0)["B"]?.width, 600)
        layout.reconcile(["B", "C", "D"])
        XCTAssertEqual(layout.ids, ["B", "C", "D"])
        layout.reconcile([])
        XCTAssertNil(layout.root)
        layout.reconcile(["X"])
        XCTAssertEqual(layout.ids, ["X"])
    }
    func testRepeatedMovesPreserveEveryWindowAndValidGeometry() {
        for count in 2...20 {
            let ids = (0..<count).map(String.init)
            var layout = TileLayout(ids: ids)
            for step in 0..<100 {
                layout.drop(ids[step % count], onto: ids[(step * 7 + 1) % count], zone: DropZone.allCases[step % 5])
                XCTAssertEqual(Set(layout.ids), Set(ids)); XCTAssertEqual(layout.ids.count, count)
                let frames = Array(layout.frames(in: bounds).values)
                for (i, frame) in frames.enumerated() {
                    XCTAssertTrue(bounds.contains(frame)); XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
                    for other in frames.dropFirst(i + 1) { XCTAssertFalse(frame.intersects(other)) }
                }
            }
        }
    }
    func testSwapStillAllowsAutomaticGridWhenFourthWindowOpens() {
        var layout = TileLayout(ids: ["A", "B", "C"])
        layout.drop("A", onto: "B", zone: .center)
        layout.reconcile(["A", "B", "C", "D"])
        let frames = layout.frames(in: bounds, gap: 0)
        XCTAssertEqual(Set(frames.values.map(\.minX)).count, 2)
        XCTAssertEqual(Set(frames.values.map(\.minY)).count, 2)
        XCTAssertEqual(layout.ids, ["B", "A", "C", "D"])
    }
    func testInvalidDropsDoNotMutateLayout() {
        var layout = TileLayout(ids: ["A", "B"])
        let before = layout
        XCTAssertFalse(layout.drop("A", onto: "A", zone: .center))
        XCTAssertFalse(layout.drop("missing", onto: "B", zone: .bottom))
        XCTAssertEqual(layout, before)
    }
}
