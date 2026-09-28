import AppKit
import YabaibyeCore

/// Exercises new-window admission against owned fixtures, never the user's windows.
@MainActor enum FloatingWindowSmokeTest {
    static func run(existing: [ManagedWindow], screen: NSScreen) async throws {
        var added: NSWindow?
        var addedWindow: ManagedWindow?
        var applyCount = 0
        let suiteName = "Yabaibye.FloatingSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func makeManager() -> WindowManager {
            WindowManager(visibleWindows: {
            (existing + [addedWindow].compactMap { $0 }).compactMap { Windows.make($0.element, pid: $0.pid) }
        }, focusedWindow: {
            addedWindow.flatMap { Windows.make($0.element, pid: $0.pid) }
        }, persistLayouts: false, layoutStore: LayoutPersistence(session: "floating-test", defaults: defaults),
           registerHotkeys: false, applyFrames: { requests in
            applyCount += 1
            return try await AX.applyFrames(requests)
        })
        }
        let manager = makeManager()
        defer { manager.stop(); added?.close() }
        try manager.start()
        try await idle(manager)
        let before = try existing.map { window -> CGRect in
            guard let frame = AX.frame(window.element) else { throw AppFailure("无法读取已有测试窗口") }
            return frame
        }
        let beforeApplyCount = applyCount
        let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 140, y: screen.frame.minY + 180, width: 480, height: 340),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Yabaibye 新窗口浮动自检"
        window.isReleasedWhenClosed = false
        added = window
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        let app = AXUIElementCreateApplication(getpid())
        let elements = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        addedWindow = elements.compactMap { Windows.make($0, pid: getpid()) }.first { $0.id == UInt32(window.windowNumber) }
        guard let fresh = addedWindow else { throw AppFailure("无法读取新窗口浮动测试标识") }
        let floatingFrame = fresh.frame
        manager.refresh()
        try await idle(manager)
        guard applyCount == beforeApplyCount,
              close(AX.frame(fresh.element), floatingFrame),
              zip(existing, before).allSatisfy({ close(AX.frame($0.0.element), $0.1) }) else {
            throw AppFailure("新窗口出现后改变了自身尺寸或已有平铺布局")
        }
        manager.stop()
        try manager.start()
        try await idle(manager)
        guard close(AX.frame(fresh.element), floatingFrame),
              zip(existing, before).allSatisfy({ close(AX.frame($0.0.element), $0.1) }) else {
            throw AppFailure("暂停恢复后新窗口错误加入平铺")
        }
        manager.execute(.toggleZoom)
        try await idle(manager)
        guard close(AX.frame(fresh.element), screen.axVisibleFrame) else { throw AppFailure("浮动窗口无法放大") }
        manager.execute(.toggleFloat)
        try await idle(manager)
        let all = existing + [fresh]
        let expected = TileLayout(ids: all.map(\.identity).sorted()).frames(in: screen.axVisibleFrame,
            gap: CGFloat(LayoutSpacing.load().gap), padding: CGFloat(LayoutSpacing.load().padding))
        // Admission appends the new ID; validate geometry as a set, not AX enumeration order.
        let actual = all.compactMap { AX.frame($0.element) }
        guard manager.status == "窗口已加入平铺", actual.count == 4,
              expected.values.allSatisfy({ target in actual.contains { close($0, target) } }) else {
            throw AppFailure("新窗口手动加入后没有形成四窗口田字布局")
        }
        manager.execute(.toggleFloat)
        try await idle(manager)
        guard manager.status == "窗口已浮动", close(AX.frame(fresh.element), floatingFrame),
              zip(existing, before).allSatisfy({ close(AX.frame($0.0.element), $0.1) }) else {
            throw AppFailure("切回浮动后没有恢复浮动尺寸与原三窗口布局")
        }
        manager.stop()
        let restarted = makeManager()
        defer { restarted.stop() }
        try restarted.start()
        try await idle(restarted)
        guard close(AX.frame(fresh.element), floatingFrame),
              zip(existing, before).allSatisfy({ close(AX.frame($0.0.element), $0.1) }) else {
            throw AppFailure("从存储重建管理器后浮动归属或原布局改变")
        }
    }
    private static func close(_ actual: CGRect?, _ target: CGRect) -> Bool {
        guard let actual else { return false }
        return abs(actual.minX - target.minX) < 3 && abs(actual.minY - target.minY) < 3
            && abs(actual.width - target.width) < 3 && abs(actual.height - target.height) < 3
    }
    private static func idle(_ manager: WindowManager) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !manager.isIdle {
            guard Date() < deadline else { throw AppFailure("新窗口自检等待布局超时") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
