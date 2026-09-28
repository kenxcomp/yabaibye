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
    func checkedMemberships(_ id: UInt32) -> [UInt64]? { YBCopyWindowSpaces(id)?.map(\.uint64Value) }
    func memberships(_ id: UInt32) -> [UInt64] { checkedMemberships(id) ?? [] }
    func screen(for display: DisplaySpaces) -> NSScreen? {
        NSScreen.screens.first { $0.uuid.caseInsensitiveCompare(display.uuid) == .orderedSame }
            ?? (display.uuid == "Main" ? NSScreen.screens.first : nil)
    }
    func display(for screen: NSScreen, in displays: [DisplaySpaces]) -> DisplaySpaces? {
        displays.first { $0.uuid.caseInsensitiveCompare(screen.uuid) == .orderedSame }
            ?? (displays.count == 1 ? displays.first : nil)
    }
    func missionControl() -> AXUIElement? {
        // macOS 27 moved mc.display groups from Dock's mc container to
        // WindowManager's application root. Support both structures.
        for bundle in ["com.apple.WindowManager", "com.apple.dock"] {
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            let root = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            if let mc = AX.descendant(root, depth: 2, matching: { AX.identifier($0) == "mc" }) { return mc }
            if AX.children(root).contains(where: { AX.identifier($0) == "mc.display" }) { return root }
        }
        return nil
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
    func focus(_ target: SpaceTarget, forceMissionControl: Bool = false) async throws {
        if isCurrent(target) { return }
        guard let screen = screen(for: target.display) else { throw AppFailure("目标显示器已断开。") }
        // Native Mission Control left/right shortcuts are SIP-compatible and do
        // not depend on the accessibility tree exposed by a particular Dock version.
        if !forceMissionControl, try await focusUsingSystemShortcut(target, screen: screen) { return }
        let openedByUs = missionControl() == nil
        if openedByUs {
            guard YBToggleMissionControl() == 0 else { throw AppFailure("当前系统无法打开 Mission Control。") }
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
        throw AppFailure("未找到 Mission Control 的 Space 按钮；请检查权限和系统版本。")
    }
    private func focusUsingSystemShortcut(_ target: SpaceTarget, screen: NSScreen) async throws -> Bool {
        guard CGPreflightPostEventAccess(), missionControl() == nil else { return false }
        let originalCursor = CGEvent(source: nil)?.location ?? .zero
        CGWarpMouseCursorPosition(CGPoint(x: screen.axVisibleFrame.midX, y: screen.axVisibleFrame.midY))
        defer { CGWarpMouseCursorPosition(originalCursor) }
        for _ in 0..<target.display.spaces.count {
            let before = try snapshot()
            guard let display = before.first(where: { $0.uuid == target.display.uuid }),
                  let current = display.spaces.firstIndex(where: { $0.id == display.current }),
                  let destination = display.spaces.firstIndex(where: { $0.id == target.desktop.id }) else { return false }
            if current == destination { return true }
            let direction = current < destination ? 1 : -1
            let setting = direction > 0 ? "81" : "79"
            let preferences = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")?["AppleSymbolicHotKeys"] as? [String: [String: Any]]
            let binding = preferences?[setting]
            if binding?["enabled"] as? Bool == false { return false }
            let value = binding?["value"] as? [String: Any]
            let parameters = value?["parameters"] as? [NSNumber]
            let code = parameters.flatMap { $0.count >= 3 ? CGKeyCode($0[1].uint16Value) : nil } ?? (direction > 0 ? 124 : 123)
            let flags = parameters.flatMap { $0.count >= 3 ? CGEventFlags(rawValue: $0[2].uint64Value) : nil } ?? .maskControl
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
                event?.flags = [123, 124, 125, 126].contains(code) ? flags.union(.maskSecondaryFn) : flags; event?.post(tap: .cghidEventTap)
            }
            let expected = display.spaces[current + direction].id
            var advanced = false
            for _ in 0..<30 {
                try await wait()
                let after = try snapshot()
                if after.first(where: { $0.uuid == display.uuid })?.current == expected { advanced = true; break }
                if after.contains(where: { item in before.contains(where: { $0.uuid == item.uuid && $0.uuid != display.uuid && $0.current != item.current }) }) {
                    throw AppFailure("系统把桌面切换应用到了其他屏幕；请将焦点放到目标屏幕后重试。")
                }
            }
            guard advanced else { return false }
            // Allow the native transition to finish before sending another step.
            try await wait(0.3)
        }
        return isCurrent(target)
    }
    func move(_ window: ManagedWindow, to target: SpaceTarget) async throws {
        let original = memberships(window.id)
        guard original.count == 1, target.desktop.type == 0,
              let source = try snapshot().flatMap(\.spaces).first(where: { $0.id == original.first }), source.type == 0 else {
            throw AppFailure("只能移动普通桌面上的单个标准窗口；不支持全屏或所有桌面共有窗口。")
        }
        if original.contains(target.desktop.id) { return }
        // The modern WindowManager bridge also supports moves across displays.
        if YBHasWindowMoveAPI(), YBHasBridgedWindowMoveAPI() || screen(for: target.display)?.displayID == Windows.screen(for: window.frame)?.displayID {
            let result = YBMoveWindow(window.id, target.desktop.id)
            for _ in 0..<35 {
                try await wait()
                if memberships(window.id) == [target.desktop.id] { return }
            }
            guard memberships(window.id) == original else {
                throw AppFailure("移窗返回 \(result)，窗口所在 Space 已变化；请检查后重试。")
            }
        }
        throw AppFailure("当前系统未确认移窗成功；请运行自检检查系统兼容性。")
    }
    static func key(_ code: CGKeyCode) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
            event?.flags = []; event?.post(tap: .cghidEventTap)
        }
    }
}
