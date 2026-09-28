import XCTest
@testable import YabaibyeCore

final class WindowTilingPolicyTests: XCTestCase {
    func testInitialMembershipAndUnknownWindowsDefaultToFloating() {
        let policy = WindowTilingPolicy(initialWindowIDs: ["existing", "temporarily-hidden"])
        XCTAssertTrue(policy.isTiled("existing"))
        XCTAssertTrue(policy.isTiled("temporarily-hidden"))
        XCTAssertFalse(policy.isTiled("new-window"))
    }

    func testOnlyExplicitChangesAddOrRemoveMembers() throws {
        var policy = WindowTilingPolicy(initialWindowIDs: ["existing", "minimized"])
        policy.setTiled(true, for: "new-window")
        policy.setTiled(true, for: "new-window")
        policy.setTiled(false, for: "existing")
        policy.setTiled(false, for: "unknown")
        XCTAssertTrue(policy.isTiled("new-window"))
        XCTAssertTrue(policy.isTiled("minimized"))
        XCTAssertFalse(policy.isTiled("existing"))
        XCTAssertFalse(policy.isTiled("unknown"))
        let restored = try JSONDecoder().decode(WindowTilingPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(restored, policy)
    }

    func testPolicyAndLayoutsRoundTripWithoutOverwritingEachOther() throws {
        let suite = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstLayout = TileLayout(ids: ["A", "B"])
        let secondLayout = TileLayout(ids: ["C"])
        var policy = WindowTilingPolicy(initialWindowIDs: ["A", "B", "C", "hidden"])
        var store = LayoutPersistence(session: "login-1", defaults: defaults)
        store.save(firstLayout, display: "screen", space: 1)
        store.saveTilingPolicy(policy)
        store.save(secondLayout, display: "screen", space: 2)
        var restarted = LayoutPersistence(session: "login-1", defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restarted.layout(display: "screen", space: 1), firstLayout)
        XCTAssertEqual(restarted.layout(display: "screen", space: 2), secondLayout)
        XCTAssertEqual(restarted.tilingPolicy, policy)

        // A layout may omit a minimized or hidden member without changing its policy.
        restarted.save(TileLayout(ids: ["A"]), display: "screen", space: 1)
        policy.setTiled(false, for: "C")
        restarted.saveTilingPolicy(policy)
        let restored = LayoutPersistence(session: "login-1", defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restored.layout(display: "screen", space: 1)?.ids, ["A"])
        XCTAssertEqual(restored.layout(display: "screen", space: 2), secondLayout)
        let restoredPolicy = try XCTUnwrap(restored.tilingPolicy)
        XCTAssertEqual(restoredPolicy, policy)
        XCTAssertTrue(restoredPolicy.isTiled("B"))
        XCTAssertTrue(restoredPolicy.isTiled("hidden"))
        XCTAssertFalse(restoredPolicy.isTiled("C"))
    }

    func testLegacyArchiveKeepsLayoutAndHasNoPolicy() {
        let suite = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = #"{"session":"login-1","layouts":{"screen:1":{"customized":false,"root":{"window":{"_0":"A"}}}}}"#
        defaults.set(Data(legacy.utf8), forKey: LayoutPersistence.storageKey)
        let store = LayoutPersistence(session: "login-1", defaults: defaults)
        XCTAssertNil(store.tilingPolicy)
        XCTAssertEqual(store.layout(display: "screen", space: 1), TileLayout(ids: ["A"]))
    }

    func testNewSessionClearsBothPolicyAndLayouts() {
        let suite = "Yabaibye.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var original = LayoutPersistence(session: "login-1", defaults: defaults)
        original.save(TileLayout(ids: ["A"]), display: "screen", space: 1)
        original.saveTilingPolicy(WindowTilingPolicy(initialWindowIDs: ["A"]))
        var nextSession = LayoutPersistence(session: "login-2", defaults: defaults)
        XCTAssertNil(nextSession.tilingPolicy)
        XCTAssertNil(nextSession.layout(display: "screen", space: 1))
        let newPolicy = WindowTilingPolicy(initialWindowIDs: ["B"])
        nextSession.saveTilingPolicy(newPolicy)
        let restored = LayoutPersistence(session: "login-2", defaults: defaults)
        XCTAssertEqual(restored.tilingPolicy, newPolicy)
        XCTAssertNil(restored.layout(display: "screen", space: 1))
    }
}
