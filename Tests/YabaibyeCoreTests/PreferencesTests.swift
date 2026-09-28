import XCTest
import CoreGraphics
@testable import YabaibyeCore

final class PreferencesTests: XCTestCase {
    func testPaddingAndGapAreIndependent() {
        let layout = TileLayout(ids: ["A", "B"])
        let bounds = CGRect(x: -1000, y: 20, width: 1000, height: 600)
        let frames = layout.frames(in: bounds, gap: 12, padding: 30)
        XCTAssertEqual(frames["A"], CGRect(x: -970, y: 50, width: 464, height: 540))
        XCTAssertEqual(frames["B"]?.minX, -494)
        XCTAssertEqual(frames["B"]!.minX - frames["A"]!.maxX, 12)
        let edgeToEdge = layout.frames(in: bounds, gap: 20, padding: 0)
        XCTAssertEqual(edgeToEdge["A"]?.minX, bounds.minX)
        XCTAssertEqual(edgeToEdge["B"]!.minX - edgeToEdge["A"]!.maxX, 20)
        let touching = layout.frames(in: bounds, gap: 0, padding: 20)
        XCTAssertEqual(touching["B"]?.minX, touching["A"]?.maxX)
    }
    func testExcessivePaddingAndGapStayInsideSmallNestedLayout() {
        var layout = TileLayout(ids: ["A", "B", "C"])
        layout.drop("A", onto: "B", zone: .bottom)
        for bounds in [CGRect(x: 0, y: 0, width: 40, height: 20), CGRect(x: -900, y: -300, width: 900, height: 1600)] {
            for gap: CGFloat in [0, 100, .infinity, .nan, -10] {
                let frames = Array(layout.frames(in: bounds, gap: gap, padding: 100).values)
                for (i, frame) in frames.enumerated() {
                    XCTAssertTrue(bounds.contains(frame)); XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
                    for other in frames.dropFirst(i + 1) { XCTAssertFalse(frame.intersects(other)) }
                }
            }
        }
    }
    func testPreferencesSurviveNewDefaultsInstanceAndRejectInvalidValues() {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(LayoutSpacing.load(from: defaults), .standard)
        LayoutSpacing(padding: 30, gap: 7).save(to: defaults)
        XCTAssertEqual(LayoutSpacing.load(from: UserDefaults(suiteName: name)!), LayoutSpacing(padding: 30, gap: 7))
        defaults.set(-100, forKey: "tiling.outerPadding"); defaults.set(99999, forKey: "tiling.windowGap")
        XCTAssertEqual(LayoutSpacing.load(from: defaults), LayoutSpacing(padding: 0, gap: 100))
        defaults.set("invalid", forKey: "tiling.outerPadding")
        XCTAssertEqual(LayoutSpacing.load(from: defaults).padding, 10)
    }
    func testForegroundProtectionOnlyTargetsOverlappingBackgroundNormalWindows() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let active = WindowStackEntry(id: 1, owner: 100, frame: rect)
        let background = WindowStackEntry(id: 2, owner: 200, frame: rect)
        let panel = WindowStackEntry(id: 3, owner: 200, layer: 3, frame: rect)
        let sheet = WindowStackEntry(id: 4, owner: 100, frame: rect)
        XCTAssertEqual(ForegroundPolicy.obstruction(focusedID: 1, activePID: 100, stack: [background, active]), 2)
        XCTAssertNil(ForegroundPolicy.obstruction(focusedID: 1, activePID: 100, stack: [active, background]))
        XCTAssertNil(ForegroundPolicy.obstruction(focusedID: 1, activePID: 100, stack: [panel, active]))
        XCTAssertNil(ForegroundPolicy.obstruction(focusedID: 1, activePID: 100, stack: [sheet, background, active]))
        XCTAssertNil(ForegroundPolicy.obstruction(focusedID: 1, activePID: 200, stack: [background, active]))
        let offscreen = WindowStackEntry(id: 5, owner: 200, frame: CGRect(x: 700, y: 0, width: 100, height: 100))
        XCTAssertNil(ForegroundPolicy.obstruction(focusedID: 1, activePID: 100, stack: [offscreen, active]))
    }
}
