import XCTest
import AppKit
@testable import Yabaibye

final class LifecycleTests: XCTestCase {
    @MainActor func testRejectedInstanceDoesNotRewriteStartupPreference() {
        let app = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: "managerEnabled") as? Bool
        let delegate = AppDelegate() // Never acquired lifecycle ownership.
        XCTAssertEqual(delegate.applicationShouldTerminate(app), .terminateNow)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "managerEnabled") as? Bool, previous)
    }
    @MainActor func testIsolatedManagerRejectsForeignFocusAndLeavesPreferencesAlone() {
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: "managerEnabled") as? Bool
        let owned = ManagedWindow(id: 10, pid: 100, element: AXUIElementCreateApplication(100), frame: .zero)
        let foreign = ManagedWindow(id: 11, pid: 200, element: AXUIElementCreateApplication(200), frame: .zero)
        var focused = foreign
        let manager = WindowManager(visibleWindows: { [owned] }, focusedWindow: { focused },
                                    persistLayouts: false, allowedWindows: [owned.identity], registerHotkeys: false)
        XCTAssertNil(manager.focusedWindow())
        focused = owned
        XCTAssertEqual(manager.focusedWindow()?.identity, owned.identity)
        manager.stop()
        XCTAssertEqual(UserDefaults.standard.object(forKey: "managerEnabled") as? Bool, previous)
    }
}
