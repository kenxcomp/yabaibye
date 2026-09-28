import AppKit
import YabaibyeCore

/// Opt-in integration check. Only test-owned windows are moved/resized.
/// Existing active desktops are restored even if a check fails.
@MainActor final class SmokeTest {
    private var windows: [NSWindow] = []
    private var results: [String] = []
    private let spaces = Spaces()
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
    func run(layoutOnly: Bool = false, completion: @escaping (String) -> Void) {
        guard AXIsProcessTrusted() else { completion("未执行：请先授予 Yabaibye 辅助功能权限。"); return }
        guard WindowManager.conflicts().isEmpty else { completion("未执行：请先停止 yabai/skhd。"); return }
        task = Task { @MainActor in
            let original = (try? spaces.snapshot()) ?? []
            results.append("事件投递权限：\(CGPreflightPostEventAccess())")
            let previousApp = NSWorkspace.shared.frontmostApplication
            do {
                let hotkeys = Hotkeys()
                try hotkeys.start(); hotkeys.stop()
                results.append("PASS：\(Binding.defaults.count) 个全局快捷键注册 / 释放")
                guard let screen = NSScreen.screens.first else { throw AppFailure("没有显示器") }
                for i in 0..<3 {
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
                guard managed.count == 3 else { throw AppFailure("无法读取自检窗口 AX 标识") }
                let frames = Layout.frames(count: 3, in: screen.axVisibleFrame)
                for (i, window) in managed.enumerated() {
                    let accepted = try await AX.applyFrames([(window.element, frames[i])])
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let actual = AX.frame(window.element)
                    guard accepted, let actual, abs(actual.width - frames[i].width) < 3, abs(actual.minX - frames[i].minX) < 3 else {
                        throw AppFailure("AX 平铺尺寸校验失败：accepted=\(accepted)，目标=\(frames[i])，实际=\(String(describing: actual))")
                    }
                }
                results.append("PASS：真实 AX 窗口移动和缩放")
                // Run production command handling against only the owned fixtures.
                let suiteName = "Yabaibye.LayoutSelfTest.\(UUID().uuidString)"
                let testDefaults = UserDefaults(suiteName: suiteName)!
                defer { testDefaults.removePersistentDomain(forName: suiteName) }
                let fixtureManager = WindowManager(visibleWindows: {
                    managed.compactMap { Windows.make($0.element, pid: $0.pid) }
                }, focusedWindow: { Windows.make(managed[0].element, pid: managed[0].pid) }, persistLayouts: false, layoutStore: LayoutPersistence(session: "test", defaults: testDefaults))
                do {
                    defer { fixtureManager.stop() }
                    try fixtureManager.start()
                    try await waitForIdle(fixtureManager)
                    let beforeZoom = managed.map { AX.frame($0.element) }
                    fixtureManager.execute(.toggleZoom)
                    try await waitForIdle(fixtureManager)
                    guard let zoom = AX.frame(managed[0].element), abs(zoom.width - screen.axVisibleFrame.width) < 3,
                          abs(zoom.height - screen.axVisibleFrame.height) < 3 else { throw AppFailure("放大窗口未铺满当前桌面") }
                    fixtureManager.execute(.toggleZoom)
                    try await waitForIdle(fixtureManager)
                    guard managed.enumerated().allSatisfy({ index, window in
                        guard let actual = AX.frame(window.element), let before = beforeZoom[index] else { return false }
                        return abs(actual.minX - before.minX) < 3 && abs(actual.minY - before.minY) < 3 && abs(actual.width - before.width) < 3 && abs(actual.height - before.height) < 3
                    }) else { throw AppFailure("放大后未恢复原平铺布局") }
                    results.append("PASS：当前桌面放大 / 恢复，原平铺布局保持")
                    fixtureManager.execute(.toggleFloat)
                    try await waitForIdle(fixtureManager)
                    guard fixtureManager.status == "窗口已浮动" else { throw AppFailure("浮动命令未完成") }
                    fixtureManager.execute(.toggleFloat)
                    try await waitForIdle(fixtureManager)
                    guard fixtureManager.status == "窗口已加入平铺",
                          let first = AX.frame(managed[0].element), let second = AX.frame(managed[1].element) else {
                        throw AppFailure("重新加入平铺失败")
                    }
                    let direction: Direction = abs(first.midX - second.midX) > abs(first.midY - second.midY)
                        ? (first.midX < second.midX ? .right : .left) : (first.midY < second.midY ? .down : .up)
                    fixtureManager.execute(.swap(direction))
                    try await waitForIdle(fixtureManager)
                    guard let afterFirst = AX.frame(managed[0].element), let afterSecond = AX.frame(managed[1].element),
                          abs(afterFirst.minX - second.minX) < 3, abs(afterFirst.minY - second.minY) < 3,
                          abs(afterSecond.minX - first.minX) < 3, abs(afterSecond.minY - first.minY) < 3 else {
                        throw AppFailure("方向交换后的实际窗口位置不匹配")
                    }
                    results.append("PASS：平铺 / 浮动切换与方向交换命令")
                    let row = managed.compactMap { Windows.make($0.element, pid: $0.pid) }.sorted { $0.frame.minX < $1.frame.minX }
                    guard row.count == 3, let space = spaces.memberships(row[0].id).first else { throw AppFailure("拖拽分区测试缺少窗口") }
                    fixtureManager.finishDrag(TileDragContext(space: space, source: row[0], candidates: row), target: row[1].identity, zone: .bottom)
                    try await waitForIdle(fixtureManager)
                    guard let a = AX.frame(row[0].element), let b = AX.frame(row[1].element), let c = AX.frame(row[2].element),
                          abs(a.minX - b.minX) < 3, a.minY > b.minY, c.minX > b.minX,
                          abs(a.width - c.width) < 3, abs(a.height - b.height) < 3 else { throw AppFailure("三列转左侧上下分区的实际位置不匹配") }
                    fixtureManager.stop()
                    let restarted = WindowManager(visibleWindows: {
                        managed.compactMap { Windows.make($0.element, pid: $0.pid) }
                    }, persistLayouts: false, layoutStore: LayoutPersistence(session: "test", defaults: UserDefaults(suiteName: suiteName)!))
                    do {
                        defer { restarted.stop() }
                        try restarted.start()
                        try await waitForIdle(restarted)
                        for (window, expected) in zip(row, [a, b, c]) {
                            guard let frame = AX.frame(window.element), abs(frame.minX - expected.minX) < 3,
                                  abs(frame.minY - expected.minY) < 3, abs(frame.width - expected.width) < 3,
                                  abs(frame.height - expected.height) < 3 else { throw AppFailure("管理器重建后丢失手动分区") }
                        }
                    }
                    results.append("PASS：从独立偏好存储重建管理器后，左侧 B/A、右侧 C 的实际窗口分区保持")
                    try fixtureManager.start()
                    try await waitForIdle(fixtureManager)
                    let fresh = row.compactMap { Windows.make($0.element, pid: $0.pid) }
                    fixtureManager.finishDrag(TileDragContext(space: space, source: fresh[0], candidates: fresh), target: fresh[2].identity, zone: .right)
                    try await waitForIdle(fixtureManager)
                    guard let lastA = AX.frame(row[0].element), let lastB = AX.frame(row[1].element), let lastC = AX.frame(row[2].element),
                          lastB.minX < lastC.minX, lastC.minX < lastA.minX,
                          abs(lastA.width - lastB.width) < 3, abs(lastB.width - lastC.width) < 3,
                          abs(lastA.height - lastC.height) < 3, abs(lastB.height - lastC.height) < 3 else {
                        throw AppFailure("嵌套分区恢复 B/C/A 等宽三列失败")
                    }
                    results.append("PASS：拖拽落点命令 III → 左侧 B/A → B/C/A 等宽三列（实际 AX 几何）")
                }
                if !layoutOnly {
                if let first = SpaceRouter.numbered(1, displays: try spaces.snapshot()),
                   let third = SpaceRouter.numbered(3, displays: try spaces.snapshot()),
                   first.display.uuid == third.display.uuid {
                    try await spaces.focus(first, forceMissionControl: true)
                    let started = Date()
                    try await spaces.focus(third, forceMissionControl: true)
                    results.append("PASS：Space 1 → 3 直接跳转（单次目标选择，\(String(format: "%.2f", Date().timeIntervalSince(started))) 秒）")
                    if let previous = original.first(where: { $0.uuid == first.display.uuid }) { try await restore(previous) }
                } else { results.append("SKIP：缺少同屏的 Space 1 和 3，未执行跨桌面直接跳转测试") }
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
                results.append("PASS：同屏原生 Space 移窗（已核对窗口归属）")
                if let otherDisplay = try spaces.snapshot().first(where: { $0.uuid != sourceDisplay.uuid }),
                   let otherIndex = otherDisplay.spaces.firstIndex(where: { $0.type == 0 }) {
                    try await spaces.move(focused, to: SpaceTargetForTest.make(otherDisplay, otherIndex))
                    results.append("PASS：跨屏原生 Space 移窗（已核对窗口归属）")
                } else { results.append("SKIP：没有第二块可用显示器") }
                guard let returnDisplay = try spaces.snapshot().first(where: { $0.uuid == sourceDisplay.uuid }),
                      let returnIndex = returnDisplay.spaces.firstIndex(where: { $0.id == sourceID }) else {
                    throw AppFailure("原桌面已不存在")
                }
                try await spaces.move(focused, to: SpaceTargetForTest.make(returnDisplay, returnIndex))
                results.append("PASS：测试窗口移回原 Space")
                }
            } catch { results.append("FAIL：\(error.localizedDescription)") }
            windows.forEach { $0.close() }; windows.removeAll()
            for display in original where !Task.isCancelled && !layoutOnly {
                do { try await restore(display) } catch { results.append("恢复桌面失败：\(error.localizedDescription)") }
            }
            previousApp?.activate(options: [])
            if AppDelegate.sipStatus() == "System Integrity Protection status: enabled." {
                results.append("SIP 状态：完整开启（以上为当前配置实测）")
            } else {
                results.append("SIP 尚未确认完整开启；开启后请重新运行自检")
            }
            if !Task.isCancelled { completion(results.joined(separator: "\n")) }
        }
    }
    private func waitForIdle(_ manager: WindowManager) async throws {
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 80_000_000)
            if manager.isIdle { return }
        }
        throw AppFailure("窗口管理命令执行超时")
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
