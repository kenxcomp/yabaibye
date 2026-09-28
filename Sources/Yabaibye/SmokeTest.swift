import AppKit
import YabaibyeCore

/// Opt-in integration check. Only test-owned windows are moved/resized.
/// Existing active desktops are restored even if a check fails.
@MainActor final class SmokeTest {
    private var windows: [NSWindow] = []
    private var results: [String] = []
    private let spaces = Spaces()
    func run(completion: @escaping (String) -> Void) {
        guard AXIsProcessTrusted() else { completion("未执行：请先授予 Yabaibye 辅助功能权限。"); return }
        guard WindowManager.conflicts().isEmpty else { completion("未执行：请先停止 yabai/skhd。"); return }
        Task { @MainActor in
            let original = (try? spaces.snapshot()) ?? []
            let previousApp = NSWorkspace.shared.frontmostApplication
            do {
                guard let screen = NSScreen.screens.first else { throw AppFailure("没有显示器") }
                for i in 0..<2 {
                    let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 140 + CGFloat(i) * 80, y: screen.frame.minY + 180, width: 480, height: 340),
                                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.title = "Yabaibye 自检 \(i + 1)"; window.isReleasedWhenClosed = false
                    window.contentView = NSTextField(labelWithString: "仅用于自检，测试结束后自动关闭。")
                    window.makeKeyAndOrderFront(nil); windows.append(window)
                }
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(nanoseconds: 400_000_000)
                let app = AXUIElementCreateApplication(getpid())
                let elements = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
                let managed = elements.compactMap { Windows.make($0, pid: getpid()) }.filter { candidate in windows.contains { UInt32($0.windowNumber) == candidate.id } }
                guard managed.count == 2 else { throw AppFailure("无法读取自检窗口 AX 标识") }
                let frames = Layout.frames(count: 2, in: screen.axVisibleFrame)
                for (i, window) in managed.enumerated() {
                    guard AX.setFrame(window.element, frames[i]), let actual = AX.frame(window.element), abs(actual.width - frames[i].width) < 3, abs(actual.minX - frames[i].minX) < 3 else {
                        throw AppFailure("AX 平铺尺寸校验失败")
                    }
                }
                results.append("PASS：真实 AX 窗口移动和缩放")
                for display in original {
                    guard let target = SpaceRouter.adjacent(1, display: display) ?? SpaceRouter.adjacent(-1, display: display) else {
                        results.append("SKIP：屏幕只有一个 Space"); continue
                    }
                    try await spaces.focus(target)
                    results.append("PASS：显示器 \(original.firstIndex(of: display)! + 1) 原生 Space 切换")
                    try await restore(display)
                }
                // Refocus our window and test movement on its source display.
                windows[0].makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let focused = Windows.focused(), windows.contains(where: { UInt32($0.windowNumber) == focused.id }),
                      let sourceID = spaces.memberships(focused.id).first,
                      let sourceDisplay = try spaces.snapshot().first(where: { $0.spaces.contains(where: { $0.id == sourceID }) }),
                      let index = sourceDisplay.spaces.firstIndex(where: { $0.type == 0 && $0.id != sourceID }) else {
                    throw AppFailure("缺少可用于移窗测试的第二个普通 Space")
                }
                let target = SpaceTargetForTest.make(sourceDisplay, index)
                try await spaces.move(focused, to: target)
                results.append("PASS：原生 Space 移窗（已核对窗口归属）")
            } catch { results.append("FAIL：\(error.localizedDescription)") }
            windows.forEach { $0.close() }; windows.removeAll()
            for display in original {
                do { try await restore(display) } catch { results.append("恢复桌面失败：\(error.localizedDescription)") }
            }
            previousApp?.activate(options: [])
            results.append("SIP 完整开启后的兼容性：需重启开启 SIP 后再自检")
            completion(results.joined(separator: "\n"))
        }
    }
    private func restore(_ display: DisplaySpaces) async throws {
        guard let fresh = try spaces.snapshot().first(where: { $0.uuid == display.uuid }),
              let index = fresh.spaces.firstIndex(where: { $0.id == display.current }) else { return }
        try await spaces.focus(SpaceTargetForTest.make(fresh, index))
    }
}
private enum SpaceTargetForTest {
    static func make(_ display: DisplaySpaces, _ index: Int) -> SpaceTarget {
        SpaceTarget(display: display, desktop: display.spaces[index], missionControlIndex: index)
    }
}
