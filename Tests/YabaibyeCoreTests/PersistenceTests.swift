import XCTest
import CoreGraphics
@testable import YabaibyeCore

final class PersistenceTests: XCTestCase {
    func testCustomShortcutsPersistAndInvalidOrOldDataFallsBackToHomeRow() throws {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let original = Binding.defaults
        XCTAssertEqual(original.filter { if case .focusSpace = $0.command { return true }; return false }.map(\.label),
                       ["⌥A", "⌥S", "⌥D", "⌥F", "⌥G", "⌥H", "⌥J", "⌥K", "⌥L"])
        var custom = original
        custom[0] = Binding(18, control: true, option: false, cmd: true, command: .focusSpace(1))
        ShortcutPreferences.save(custom, to: defaults)
        XCTAssertEqual(ShortcutPreferences.load(from: UserDefaults(suiteName: name)!), custom)
        custom[0] = Binding(1, command: .focusSpace(1))
        XCTAssertNotNil(ShortcutPreferences.validate(custom))
        ShortcutPreferences.save(custom, to: defaults)
        XCTAssertEqual(ShortcutPreferences.load(from: defaults)[0].label, "⌃⌘1")
        custom[0] = Binding(0, shift: true, option: false, command: .focusSpace(1))
        XCTAssertNotNil(ShortcutPreferences.validate(custom))
        XCTAssertNotNil(ShortcutPreferences.validate(Array(original.dropLast())))
        defaults.set(Data("broken".utf8), forKey: ShortcutPreferences.storageKey)
        XCTAssertEqual(ShortcutPreferences.load(from: defaults), original)
    }
    func testSavedAutomaticColumnsAdoptCurrentGridWithoutChangingWindowOrder() throws {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        // Snapshot of the old default. Keep this independent of the current initializer.
        let saved = #"{"session":"login-1","layouts":{"screen:1":{"customized":false,"root":{"split":{"_0":{"horizontal":{}},"_1":[{"window":{"_0":"B"}},{"window":{"_0":"A"}},{"window":{"_0":"C"}}]}}}}}"#
        defaults.set(Data(saved.utf8), forKey: LayoutPersistence.storageKey)
        let store = LayoutPersistence(session: "login-1", defaults: defaults)
        var layout = try XCTUnwrap(store.layout(display: "screen", space: 1))
        layout.reconcile(["A", "B", "C"])
        XCTAssertEqual(layout, TileLayout(ids: ["B", "A", "C"]))
        XCTAssertFalse(layout.customized)
    }
    func testSavedManualColumnsStayCustomizedAfterRestart() throws {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var layout = TileLayout(ids: ["A", "B", "C"])
        layout.drop("A", onto: "C", zone: .right)
        var store = LayoutPersistence(session: "login-1", defaults: defaults)
        store.save(layout, display: "screen", space: 1)
        var restored = try XCTUnwrap(LayoutPersistence(session: "login-1", defaults: defaults).layout(display: "screen", space: 1))
        restored.reconcile(["A", "B", "C"])
        XCTAssertEqual(restored, layout)
        XCTAssertTrue(restored.customized)
        XCTAssertTrue(restored.frames(in: CGRect(x: 0, y: 0, width: 1200, height: 800), gap: 0).values.allSatisfy { $0.width == 400 })
    }
    func testRestartPreservesPartitionAndSubsequentDropRebalances() throws {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var layout = TileLayout(ids: ["A", "B", "C"])
        layout.drop("A", onto: "B", zone: .bottom)
        var store = LayoutPersistence(session: "login-1", defaults: defaults)
        store.save(layout, display: "screen-1", space: 1)
        store.save(TileLayout(ids: ["X", "Y"]), display: "screen-2", space: 2)
        let restarted = LayoutPersistence(session: "login-1", defaults: UserDefaults(suiteName: name)!)
        var restored = try XCTUnwrap(restarted.layout(display: "screen-1", space: 1))
        restored.reconcile(["C", "A", "B"])
        XCTAssertEqual(restored, layout)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = restored.frames(in: bounds, gap: 0)
        XCTAssertEqual(frames["B"], CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(frames["A"], CGRect(x: 0, y: 400, width: 600, height: 400))
        XCTAssertEqual(frames["C"], CGRect(x: 600, y: 0, width: 600, height: 800))
        restored.drop("A", onto: "C", zone: .right)
        XCTAssertEqual(restored.ids, ["B", "C", "A"])
        XCTAssertTrue(restored.frames(in: bounds, gap: 0).values.allSatisfy { $0.width == 400 })
        XCTAssertEqual(restarted.layout(display: "screen-2", space: 2)?.ids, ["X", "Y"])
        XCTAssertNil(restarted.layout(display: "screen-2", space: 1))
        XCTAssertNil(LayoutPersistence(session: "login-2", defaults: defaults).layout(display: "screen-1", space: 1))
    }
    func testSavedLayoutHandlesClosedAndAddedWindowsAndCorruption() throws {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var layout = TileLayout(ids: ["A", "B", "C"])
        layout.drop("A", onto: "B", zone: .bottom)
        var store = LayoutPersistence(session: "session", defaults: defaults)
        store.save(layout, display: "screen", space: 8)
        var restored = try XCTUnwrap(LayoutPersistence(session: "session", defaults: defaults).layout(display: "screen", space: 8))
        restored.reconcile(["A", "B", "D"])
        let rects = restored.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 600), gap: 0)
        XCTAssertNil(rects["C"])
        XCTAssertEqual(rects["A"]?.minX, rects["B"]?.minX)
        XCTAssertEqual(rects["D"]?.width, 500)
        defaults.set(Data("corrupt".utf8), forKey: LayoutPersistence.storageKey)
        XCTAssertNil(LayoutPersistence(session: "session", defaults: defaults).layout(display: "screen", space: 8))
    }
}
