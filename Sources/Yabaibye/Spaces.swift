import AppKit
import SpaceBridge
import YabaibyeCore

@MainActor final class Spaces {
    func snapshot() throws -> [DisplaySpaces] {
        guard YBHasSpaceReadAPI(), let rows = YBCopyDisplays() as? [[String: Any]] else {
            throw AppFailure("当前 macOS 无法读取原生 Space；请查看诊断。")
        }
        let displays = rows.compactMap { row -> DisplaySpaces? in
            guard let uuid = row["Display Identifier"] as? String,
                  let spaces = row["Spaces"] as? [[String: Any]],
                  let current = row["Current Space"] as? [String: Any],
                  let currentID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
            let desktops = spaces.compactMap { value -> Desktop? in
                guard let id = (value["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                      let type = value["type"] as? Int else { return nil }
                return Desktop(id: id, type: type)
            }
            return DisplaySpaces(uuid: uuid, current: currentID, spaces: desktops)
        }
        guard !displays.isEmpty else { throw AppFailure("系统返回的 Space 列表为空或格式已变更。") }
        return displays
    }
    func memberships(_ id: UInt32) -> [UInt64] { (YBCopyWindowSpaces(id) ?? []).map(\.uint64Value) }
    func screen(for display: DisplaySpaces) -> NSScreen? {
        NSScreen.screens.first { $0.uuid.caseInsensitiveCompare(display.uuid) == .orderedSame }
            ?? (display.uuid == "Main" ? NSScreen.screens.first : nil)
    }
    func display(for screen: NSScreen, in displays: [DisplaySpaces]) -> DisplaySpaces? {
        displays.first { $0.uuid.caseInsensitiveCompare(screen.uuid) == .orderedSame }
            ?? (displays.count == 1 ? displays.first : nil)
    }
    func missionControl() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        return AX.descendant(root, depth: 2) { AX.identifier($0) == "mc" }
    }
    private func list(for displayID: CGDirectDisplayID) -> AXUIElement? {
        guard let mc = missionControl(), let display = AX.descendant(mc, depth: 2, matching: {
            AX.identifier($0) == "mc.display" && (AX.value($0, "AXDisplayID") as? NSNumber)?.uint32Value == displayID
        }) else { return nil }
        return AX.descendant(display, depth: 3) { AX.identifier($0) == "mc.spaces.list" }
    }
    private func wait(_ seconds: Double = 0.08) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try Task.checkCancellation()
    }
    private func isCurrent(_ target: SpaceTarget) -> Bool {
        (try? snapshot().first(where: { $0.uuid == target.display.uuid })?.current) == target.desktop.id
    }
    func focus(_ target: SpaceTarget) async throws {
        if isCurrent(target) { return }
        guard let screen = screen(for: target.display) else { throw AppFailure("目标显示器已断开。") }
        let openedByUs = missionControl() == nil
        if openedByUs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["/System/Applications/Mission Control.app"]
            try process.run()
        }
        var completed = false
        defer {
            if !completed && openedByUs && missionControl() != nil { Self.key(53) }
        }
        for _ in 0..<30 {
            try await wait()
            guard let list = list(for: screen.displayID) else { continue }
            // Abort if spaces were created/deleted/reordered during the transition.
            guard let fresh = try snapshot().first(where: { $0.uuid == target.display.uuid }),
                  fresh.spaces == target.display.spaces else { throw AppFailure("Space 顺序刚刚改变，请重试。") }
            let children = AX.children(list)
            guard children.count == fresh.spaces.count, children.indices.contains(target.missionControlIndex) else { continue }
            try await wait(0.18)
            let result = AXUIElementPerformAction(children[target.missionControlIndex], kAXPressAction as CFString)
            guard result == .success else { throw AppFailure("Mission Control 拒绝切换（AX \(result.rawValue)）。") }
            for _ in 0..<30 {
                try await wait()
                if isCurrent(target) && missionControl() == nil { completed = true; return }
            }
            throw AppFailure("Space 切换超时；未确认切换成功。")
        }
        throw AppFailure("未找到 Mission Control 的 Space 按钮；请检查辅助功能权限。")
    }
    func move(_ window: ManagedWindow, to target: SpaceTarget) async throws {
        let original = memberships(window.id)
        guard original.count == 1, target.desktop.type == 0,
              let source = try snapshot().flatMap(\.spaces).first(where: { $0.id == original.first }), source.type == 0 else {
            throw AppFailure("只能移动普通桌面上的单个标准窗口；不支持全屏或所有桌面共有窗口。")
        }
        if original.contains(target.desktop.id) { return }
        // Same-display moves can work without any animation on supported OS versions.
        if YBHasWindowMoveAPI(), screen(for: target.display)?.displayID == Windows.screen(for: window.frame)?.displayID {
            let result = YBMoveWindow(window.id, target.desktop.id)
            for _ in 0..<5 {
                try await wait()
                if memberships(window.id) == [target.desktop.id] { return }
            }
            guard memberships(window.id) == original else {
                throw AppFailure("移窗返回 \(result)，窗口所在 Space 已变化；请检查后重试。")
            }
        }
        // On newer systems, emulate a titlebar drag across Mission Control.
        guard let destination = screen(for: target.display), missionControl() == nil,
              let frame = AX.frame(window.element),
              let current = Windows.focused(), current.identity == window.identity,
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            throw AppFailure("无法安全开始拖拽；请关闭 Mission Control、松开鼠标并聚焦目标窗口。")
        }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let start = CGPoint(x: frame.midX, y: frame.minY + 6)
        let end = CGPoint(x: destination.axVisibleFrame.midX, y: destination.axVisibleFrame.minY + 24)
        guard CGPreflightPostEventAccess() else { throw AppFailure("需要辅助功能权限才能拖拽窗口。") }
        var releasePoint = start
        Self.mouse(.leftMouseDown, at: start)
        defer {
            Self.mouse(.leftMouseUp, at: releasePoint)
            CGWarpMouseCursorPosition(cursor)
        }
        try await wait(0.12)
        try await focus(target)
        for fraction in [0.25, 0.5, 0.75, 1.0] {
            releasePoint = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            Self.mouse(.leftMouseDragged, at: releasePoint)
            try await wait(0.06)
        }
        Self.mouse(.leftMouseUp, at: end)
        for _ in 0..<25 {
            try await wait()
            if memberships(window.id) == [target.desktop.id] { return }
        }
        throw AppFailure("拖拽后未确认窗口进入目标 Space；自定义标题栏可能不支持此操作。")
    }
    static func mouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = []; event?.post(tap: .cghidEventTap)
    }
    static func key(_ code: CGKeyCode) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = []; event?.post(tap: .cghidEventTap)
        }
    }
}
