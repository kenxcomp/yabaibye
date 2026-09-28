import AppKit
import YabaibyeCore

/// Exercises the production cycle command with focus on each display, then restores it.
@MainActor enum OtherDisplaySmokeTest {
    static func run() async throws -> [String] {
        let spaces = Spaces()
        let displays = try spaces.snapshot()
        guard displays.count > 1 else { return ["SKIP：另一屏切换自检需要至少两块屏幕"] }
        var results: [String] = []
        for source in displays {
            guard let screen = spaces.screen(for: source),
                  let other = SpaceRouter.navigationDisplay(currentDisplayID: source.uuid, other: true, displays: try spaces.snapshot()),
                  let target = SpaceRouter.adjacent(1, display: other) ?? SpaceRouter.adjacent(-1, display: other) else {
                results.append("SKIP：目标显示器只有一个 Space"); continue
            }
            let delta = SpaceRouter.adjacent(1, display: other) == target ? 1 : -1
            let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.midY - 100, width: 360, height: 200),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Yabaibye 另一屏切换自检"; window.isReleasedWhenClosed = false
            defer { window.close() }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let focused = Windows.focused(), focused.id == UInt32(window.windowNumber),
                  Windows.screen(for: focused.frame)?.displayID == screen.displayID else {
                throw AppFailure("另一屏自检无法聚焦源屏幕窗口")
            }
            let manager = WindowManager(visibleWindows: { [] }, persistLayouts: false,
                                        allowedWindows: [focused.identity], registerHotkeys: false)
            defer { manager.stop() }
            try manager.start()
            let before = try spaces.snapshot()
            manager.execute(.cycle(delta, secondary: true))
            try await idle(manager)
            let after = try spaces.snapshot()
            guard after.first(where: { $0.uuid == other.uuid })?.current == target.desktop.id,
                  before.filter({ $0.uuid != other.uuid }).allSatisfy({ original in after.first(where: { $0.uuid == original.uuid })?.current == original.current }),
                  Windows.focused()?.identity == focused.identity else {
                throw AppFailure("另一屏切换命令未只切换目标屏幕并保留源窗口焦点：\(manager.status)")
            }
            // A second press must still control the other display, not switch direction
            // because Mission Control moved focus there after the first command.
            manager.execute(.cycle(-delta, secondary: true))
            try await idle(manager)
            let restored = try spaces.snapshot()
            guard before.allSatisfy({ original in restored.first(where: { $0.uuid == original.uuid })?.current == original.current }),
                  Windows.focused()?.identity == focused.identity else {
                throw AppFailure("连续另一屏切换没有返回原 Space 或源窗口焦点")
            }
            results.append("PASS：以显示器 \(displays.firstIndex(of: source)! + 1) 为当前屏，另一屏来回切换且当前 Space 与焦点保持")
        }
        return results
    }
    private static func idle(_ manager: WindowManager) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !manager.isIdle {
            guard Date() < deadline else { throw AppFailure("另一屏切换自检等待命令超时") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
