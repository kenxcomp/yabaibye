import AppKit
import OSLog
import YabaibyeCore

@MainActor final class WindowManager {
    let spaces = Spaces()
    private let hotkeys = Hotkeys()
    private let logger = Logger(subsystem: "com.kenxcomp.yabaibye", category: "manager")
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var isLayingOut = false
    private var pendingCommand: Command?
    private var layouts: [UInt64: TileLayout] = [:]
    private var tiledWindows: [UInt64: [ManagedWindow]] = [:]
    private var renderedLayouts: [UInt64: TileLayout] = [:]
    private let drag = DragTiling()
    private var floating: [String: CGRect] = [:]
    private var originalFrames: [String: CGRect] = [:]
    private var signatures: [UInt64: String] = [:]
    private(set) var enabled = false
    private(set) var busy = false
    private(set) var status = "已暂停"
    var changed: (() -> Void)?

    private let visibleWindows: @MainActor () -> [ManagedWindow]
    private let focusedWindow: @MainActor () -> ManagedWindow?
    var isIdle: Bool { !busy && !isLayingOut }
    init(visibleWindows: @escaping @MainActor () -> [ManagedWindow] = { Windows.visible() },
         focusedWindow: @escaping @MainActor () -> ManagedWindow? = { Windows.focused() }) {
        self.visibleWindows = visibleWindows; self.focusedWindow = focusedWindow
        hotkeys.onCommand = { [weak self] command in self?.execute(command) }
        drag.capture = { [weak self] point in self?.captureDrag(at: point) }
        drag.validate = { [weak self] context in self?.validateDrag(context) == true }
        drag.commit = { [weak self] context, target, zone in self?.finishDrag(context, target: target, zone: zone) }
    }
    func start() throws {
        guard !enabled else { return }
        guard AXIsProcessTrusted() else { throw AppFailure("请先在系统设置 → 隐私与安全性 → 辅助功能中允许 Yabaibye。") }
        guard NSScreen.screensHaveSeparateSpaces else { throw AppFailure("请先启用‘显示器具有单独的空间’，注销后生效。") }
        let conflicts = Self.conflicts()
        guard conflicts.isEmpty else { throw AppFailure("请先停止 \(conflicts.joined(separator: "、"))，避免同时管理窗口。") }
        _ = try spaces.snapshot()
        try hotkeys.start()
        enabled = true
        drag.start()
        UserDefaults.standard.set(true, forKey: "managerEnabled")
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        report("正在管理窗口")
        refresh(force: true)
    }
    func stop() {
        drag.stop()
        task?.cancel(); task = nil
        layoutTask?.cancel(); pendingCommand = nil
        timer?.invalidate(); timer = nil
        hotkeys.stop(); enabled = false
        UserDefaults.standard.set(false, forKey: "managerEnabled")
        report("已暂停")
    }
    func report(_ message: String, error: Bool = false) {
        status = message
        if error { logger.error("\(message, privacy: .public)"); NSSound.beep() }
        else { logger.info("\(message, privacy: .public)") }
        changed?()
    }
    static func conflicts() -> [String] {
        ["yabai", "skhd"].filter { name in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
        }
    }
    func execute(_ command: Command) {
        guard enabled, !busy, !drag.isTracking else { return }
        if isLayingOut { pendingCommand = command; return }
        guard AXIsProcessTrusted() else { stop(); report("辅助功能权限已撤销；管理已暂停。", error: true); return }
        busy = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.refresh(force: true) }
            do {
                let displays = try self.spaces.snapshot()
                switch command {
                case .focusSpace(let number), .moveToSpace(let number):
                    guard let target = SpaceRouter.numbered(number, displays: displays) else { throw AppFailure("Space \(number) 不存在；请先在 Mission Control 创建桌面。") }
                    if case .moveToSpace = command {
                        guard let window = self.focusedWindow() else { throw AppFailure("前台没有可移动的标准窗口。") }
                        try await self.spaces.move(window, to: target)
                        self.report("窗口已移到 Space \(number)")
                    } else {
                        try await self.spaces.focus(target)
                        self.report("已切换到 Space \(number)")
                    }
                case .cycle(let delta, let secondary):
                    let display: DisplaySpaces?
                    if secondary {
                        guard displays.count > 1 else { throw AppFailure("未检测到第二个显示器。") }
                        display = displays[1]
                    } else if let screen = self.focusedWindow().flatMap({ Windows.screen(for: $0.frame) }) ?? NSScreen.main {
                        display = self.spaces.display(for: screen, in: displays)
                    } else { display = nil }
                    guard let display else { throw AppFailure("无法确定当前显示器。") }
                    guard let target = SpaceRouter.adjacent(delta, display: display) else { self.report("已到达此屏幕的 Space 边界"); return }
                    try await self.spaces.focus(target)
                    self.report("已切换\(secondary ? "第二屏" : "当前屏幕") Space")
                case .toggleFloat:
                    guard let window = self.focusedWindow() else { throw AppFailure("前台没有可平铺的标准窗口。") }
                    if let saved = self.floating.removeValue(forKey: window.identity) {
                        self.originalFrames[window.identity] = saved
                        self.report("窗口已加入平铺")
                    } else {
                        let frame = self.originalFrames[window.identity] ?? window.frame
                        guard try await AX.applyFrames([(window.element, frame)]) else { throw AppFailure("窗口拒绝恢复浮动尺寸。") }
                        self.floating[window.identity] = frame
                        self.report("窗口已浮动")
                    }
                case .swap(let direction): try self.swap(direction)
                }
            } catch is CancellationError { /* stop/quit cancels transitions */ }
            catch { self.report(error.localizedDescription, error: true) }
        }
    }
    func refresh(force: Bool = false) {
        guard enabled, !busy, !isLayingOut, !drag.isTracking else { return }
        guard AXIsProcessTrusted() else { stop(); report("辅助功能权限已撤销。", error: true); return }
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left), spaces.missionControl() == nil,
              let displays = try? spaces.snapshot() else { return }
        let windows = visibleWindows()
        var requests: [(AXUIElement, CGRect)] = []
        for display in displays {
            guard display.spaces.first(where: { $0.id == display.current })?.type == 0,
                  let screen = spaces.screen(for: display) else { continue }
            let members = windows.filter {
                floating[$0.identity] == nil && spaces.memberships($0.id) == [display.current] && Windows.screen(for: $0.frame)?.displayID == screen.displayID
            }
            tiledWindows[display.current] = members
            let ids = members.map(\.identity).sorted()
            var layout = layouts[display.current] ?? TileLayout(ids: ids)
            layout.reconcile(ids)
            layouts[display.current] = layout
            let signature = "\(screen.axVisibleFrame)"
            guard force || renderedLayouts[display.current] != layout || signatures[display.current] != signature else { continue }
            let frames = layout.frames(in: screen.axVisibleFrame)
            for window in members {
                guard let frame = frames[window.identity] else { continue }
                if originalFrames[window.identity] == nil { originalFrames[window.identity] = window.frame }
                requests.append((window.element, frame))
            }
            signatures[display.current] = signature
            renderedLayouts[display.current] = layout

        }
        guard !requests.isEmpty else { return }
        isLayingOut = true
        layoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isLayingOut = false
                if let command = self.pendingCommand { self.pendingCommand = nil; self.execute(command) }
            }
            do {
                if try await !AX.applyFrames(requests) { self.report("部分窗口有尺寸限制或拒绝调整；可用 ⌥T 将其浮动。", error: true) }
            } catch is CancellationError { }
            catch { self.report(error.localizedDescription, error: true) }
        }
    }
    private func swap(_ direction: Direction) throws {
        guard let window = self.focusedWindow(), floating[window.identity] == nil,
              let space = spaces.memberships(window.id).first,
              var layout = layouts[space], let index = layout.ids.firstIndex(of: window.identity),
              let screen = Windows.screen(for: window.frame) else { throw AppFailure("前台窗口不在平铺布局中。") }
        let geometry = layout.frames(in: screen.axVisibleFrame)
        let frames = layout.ids.compactMap { geometry[$0] }
        guard let next = Layout.neighbor(of: index, direction: direction, frames: frames) else { report("该方向没有平铺窗口"); return }
        layout.drop(window.identity, onto: layout.ids[next], zone: .center)
        layouts[space] = layout
        report("已交换窗口位置")
    }
    private func captureDrag(at point: CGPoint) -> TileDragContext? {
        guard enabled, !busy, !isLayingOut, AXIsProcessTrusted(), spaces.missionControl() == nil,
              let window = focusedWindow(), floating[window.identity] == nil,
              let space = spaces.memberships(window.id).first,
              let members = tiledWindows[space], let source = members.first(where: { $0.identity == window.identity }),
              source.frame.contains(point) else { return nil }
        return TileDragContext(space: space, source: source, candidates: members)
    }
    private func validateDrag(_ context: TileDragContext) -> Bool {
        guard enabled, !busy, !isLayingOut, AXIsProcessTrusted(), spaces.missionControl() == nil,
              let display = try? spaces.snapshot().first(where: { $0.current == context.space }),
              display.spaces.first(where: { $0.id == context.space })?.type == 0,
              spaces.memberships(context.source.id) == [context.space],
              let layout = layouts[context.space], Set(layout.ids) == Set(context.candidates.map(\.identity)) else { return false }
        return context.candidates.allSatisfy { spaces.memberships($0.id) == [context.space] && AX.frame($0.element) != nil }
    }
    func finishDrag(_ context: TileDragContext, target: String?, zone: DropZone?) {
        guard validateDrag(context) else { return }
        if let target, let zone, var layout = layouts[context.space],
           layout.drop(context.source.identity, onto: target, zone: zone) {
            layouts[context.space] = layout
            report(zone == .center ? "已交换窗口位置" : "已重新分区平铺")
        }
        // Dropping outside a tile returns the source to its existing tile.
        refresh(force: true)
    }
}
