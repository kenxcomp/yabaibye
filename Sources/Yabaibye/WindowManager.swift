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
    private var persistence: LayoutPersistence?
    private var layoutDisplays: [UInt64: String] = [:]
    private var tiledWindows: [UInt64: [ManagedWindow]] = [:]
    private var applications: [UInt64: LayoutApplication] = [:]
    private let drag = DragTiling()
    private struct ZoomedWindow {
        let window: ManagedWindow
        let restoreFrame: CGRect
    }
    private var zoomed: [UInt64: ZoomedWindow] = [:]
    private var tilingPolicy: WindowTilingPolicy?
    private var originalFrames: [String: CGRect] = [:]

    private(set) var enabled = false
    private(set) var busy = false
    private(set) var status = "已暂停"
    var changed: (() -> Void)?

    private let snapshotProvider: @MainActor () -> WindowSnapshot
    private let initialWindowIDs: @MainActor () -> Set<String>?
    private let rawFocusedWindow: @MainActor () -> ManagedWindow?
    private let allowedWindows: Set<String>?
    private let registerHotkeys: Bool
    private let managesUserPreferences: Bool
    private let applyFrames: @MainActor ([(AXUIElement, CGRect)]) async throws -> Bool
    func focusedWindow() -> ManagedWindow? {
        guard let window = rawFocusedWindow(), allowedWindows?.contains(window.identity) ?? true else { return nil }
        return window
    }
    var isIdle: Bool { !busy && !isLayingOut }
    init(visibleWindows: (@MainActor () -> [ManagedWindow])? = nil,
         focusedWindow: @escaping @MainActor () -> ManagedWindow? = { Windows.focused() },
         persistLayouts: Bool = true, layoutStore: LayoutPersistence? = nil,
         snapshotProvider: (@MainActor () -> WindowSnapshot)? = nil,
         allowedWindows: Set<String>? = nil, registerHotkeys: Bool = true,
         applyFrames: @escaping @MainActor ([(AXUIElement, CGRect)]) async throws -> Bool = { try await AX.applyFrames($0) }) {
        persistence = layoutStore
        if persistLayouts, layoutStore == nil {
            // Scope WindowServer identities to this boot and loginwindow process.
            var size = 0
            sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
            var buffer = [CChar](repeating: 0, count: max(size, 1))
            let valid = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0
            let login = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first?.processIdentifier
            if valid, let login { persistence = LayoutPersistence(session: "\(String(cString: buffer)):\(getuid()):\(login)") }
        }
        let provider = snapshotProvider ?? visibleWindows.map { provider in { WindowSnapshot(windows: provider()) } } ?? { Windows.snapshot() }
        self.snapshotProvider = provider
        if snapshotProvider != nil || visibleWindows != nil {
            self.initialWindowIDs = {
                let snapshot = provider()
                guard snapshot.complete, snapshot.unavailableDisplays.isEmpty else { return nil }
                return Set(snapshot.windows.filter { allowedWindows?.contains($0.identity) ?? true }.map(\.identity))
            }
        } else { self.initialWindowIDs = { Windows.existingWindowIDs() } }
        self.tilingPolicy = persistence?.tilingPolicy
        self.rawFocusedWindow = focusedWindow
        self.allowedWindows = allowedWindows; self.registerHotkeys = registerHotkeys
        self.managesUserPreferences = persistLayouts; self.applyFrames = applyFrames
        hotkeys.onCommand = { [weak self] command in self?.execute(command) }
        drag.capture = { [weak self] point in self?.captureDrag(at: point) }
        drag.validate = { [weak self] context in self?.validateDrag(context) == true }
        drag.commit = { [weak self] context, target, zone in self?.finishDrag(context, target: target, zone: zone) }
    }
    func applyShortcuts(_ bindings: [Binding]) throws {
        if let error = ShortcutPreferences.validate(bindings) { throw AppFailure(error) }
        let previous = ShortcutPreferences.load()
        do {
            try hotkeys.start(bindings: bindings)
            if !enabled { hotkeys.stop() }
        } catch {
            let original = error
            if enabled {
                do { try hotkeys.start(bindings: previous) }
                catch { stop(); throw AppFailure("新快捷键注册失败，旧快捷键也无法恢复；窗口管理已暂停。") }
            }
            throw original
        }
        ShortcutPreferences.save(bindings)
        report(enabled ? "快捷键已保存并生效" : "快捷键已保存，启用管理后生效")
    }
    private func persist(_ space: UInt64) {
        guard let layout = layouts[space], let display = layoutDisplays[space] else { return }
        persistence?.save(layout, display: display, space: space)
    }
    func start() throws {
        guard !enabled else { return }
        guard AXIsProcessTrusted() else { throw AppFailure("请先在系统设置 → 隐私与安全性 → 辅助功能中允许 Yabaibye。") }
        guard NSScreen.screensHaveSeparateSpaces else { throw AppFailure("请先启用‘显示器具有单独的空间’，注销后生效。") }
        let conflicts = Self.conflicts()
        guard conflicts.isEmpty else { throw AppFailure("请先停止 \(conflicts.joined(separator: "、"))，避免同时管理窗口。") }
        _ = try spaces.snapshot()
        let policy: WindowTilingPolicy
        if let existing = tilingPolicy { policy = existing }
        else {
            guard let ids = initialWindowIDs() else { throw AppFailure("暂时无法读取初始窗口列表，请重试启用。") }
            policy = WindowTilingPolicy(initialWindowIDs: ids)
        }
        if registerHotkeys { try hotkeys.start() }
        tilingPolicy = policy
        persistence?.saveTilingPolicy(policy)
        enabled = true
        drag.start()
        if managesUserPreferences { UserDefaults.standard.set(true, forKey: "managerEnabled") }
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
        if managesUserPreferences { UserDefaults.standard.set(false, forKey: "managerEnabled") }
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
                try Task.checkCancellation()
                let displays = try self.spaces.snapshot()
                switch command {
                case .focusSpace(let number), .moveToSpace(let number):
                    guard let target = SpaceRouter.numbered(number, displays: displays) else { throw AppFailure("Space \(number) 不存在；请先在 Mission Control 创建桌面。") }
                    if case .moveToSpace = command {
                        guard let window = self.focusedWindow() else { throw AppFailure("前台没有可移动的标准窗口。") }
                        try await self.restoreZoom(for: window)
                        try await self.spaces.move(window, to: target)
                        self.report("窗口已移到 Space \(number)")
                    } else {
                        try await self.spaces.focus(target, forceMissionControl: true)
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
                    try await self.restoreZoom(for: window)
                    guard var policy = self.tilingPolicy else { return }
                    if policy.isTiled(window.identity) {
                        let frame = self.originalFrames[window.identity] ?? window.frame
                        guard try await AX.applyFrames([(window.element, frame)]) else { throw AppFailure("窗口拒绝恢复浮动尺寸。") }
                        policy.setTiled(false, for: window.identity)
                        self.report("窗口已浮动")
                    } else {
                        guard let frame = AX.frame(window.element) else { throw AppFailure("暂时无法读取浮动窗口尺寸，请重试。") }
                        self.originalFrames[window.identity] = frame
                        policy.setTiled(true, for: window.identity)
                        self.report("窗口已加入平铺")
                    }
                    self.tilingPolicy = policy
                    self.persistence?.saveTilingPolicy(policy)
                case .toggleZoom:
                    guard let window = self.focusedWindow(), let screen = Windows.screen(for: window.frame),
                          self.spaces.memberships(window.id).count == 1,
                          let space = self.spaces.memberships(window.id).first,
                          displays.contains(where: { $0.current == space && $0.spaces.contains(where: { $0.id == space && $0.type == 0 }) }) else {
                        throw AppFailure("前台没有可放大的普通桌面窗口。")
                    }
                    if self.zoomed[space]?.window.identity == window.identity {
                        try await self.restoreZoom(for: window)
                        self.report("已恢复窗口布局")
                    } else {
                        if let previous = self.zoomed[space] { try await self.restoreZoom(for: previous.window) }
                        // Keep the tree intact; refresh pauses this Space's other tiles while zoomed.
                        let saved = AX.frame(window.element) ?? window.frame
                        self.zoomed[space] = ZoomedWindow(window: window, restoreFrame: saved)
                        guard try await AX.applyFrames([(window.element, screen.axVisibleFrame)]) else {
                            self.zoomed.removeValue(forKey: space)
                            _ = try await AX.applyFrames([(window.element, saved)])
                            throw AppFailure("该窗口的尺寸限制不允许铺满屏幕。")
                        }
                        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                        self.report("窗口已铺满当前桌面；再次按放大快捷键恢复")
                    }
                case .swap(let direction):
                    if let window = self.focusedWindow() { try await self.restoreZoom(for: window) }
                    try self.swap(direction)
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
        let snapshot = snapshotProvider()
        guard snapshot.complete else { return }
        let windows = snapshot.windows.filter { allowedWindows?.contains($0.identity) ?? true }
        var memberships: [UInt32: [UInt64]] = [:]
        // A failed Space lookup must never be interpreted as a window leaving its tile.
        for window in windows {
            guard let values = spaces.checkedMemberships(window.id), !values.isEmpty else { return }
            memberships[window.id] = values
        }
        let spacing = LayoutSpacing.load()
        struct Batch {
            let space: UInt64
            let layout: TileLayout?
            let signature: String
            let requests: [(AXUIElement, CGRect)]
        }
        var batches: [Batch] = []
        for display in displays {
            guard display.spaces.first(where: { $0.id == display.current })?.type == 0,
                  let screen = spaces.screen(for: display), snapshot.isReliable(on: screen.displayID) else { continue }
            if let zoom = zoomed[display.current] {
                let source = zoom.window
                let minimized = AX.value(source.element, kAXMinimizedAttribute) as? Bool
                let hidden = NSRunningApplication(processIdentifier: source.pid)?.isHidden == true
                let fullscreen = AX.value(source.element, "AXFullScreen") as? Bool == true
                if minimized == true || hidden || fullscreen {
                    zoomed.removeValue(forKey: display.current)
                    applications.removeValue(forKey: display.current)
                } else if let frame = AX.frame(source.element), memberships[source.id] == [display.current],
                          Windows.screen(for: frame)?.displayID == screen.displayID {
                    if abs(frame.minX - screen.axVisibleFrame.minX) > 3 || abs(frame.minY - screen.axVisibleFrame.minY) > 3 ||
                        abs(frame.width - screen.axVisibleFrame.width) > 3 || abs(frame.height - screen.axVisibleFrame.height) > 3 {
                        batches.append(Batch(space: display.current, layout: nil, signature: "", requests: [(source.element, screen.axVisibleFrame)]))
                    }
                    continue
                } else {
                    zoomed.removeValue(forKey: display.current)
                    applications.removeValue(forKey: display.current)
                }
            }
            let members = windows.filter {
                tilingPolicy?.isTiled($0.identity) == true && memberships[$0.id] == [display.current] && Windows.screen(for: $0.frame)?.displayID == screen.displayID
            }
            tiledWindows[display.current] = members
            let ids = members.map(\.identity).sorted()
            layoutDisplays[display.current] = display.uuid
            var layout = layouts[display.current] ?? persistence?.layout(display: display.uuid, space: display.current) ?? TileLayout(ids: ids)
            layout.reconcile(ids)
            layouts[display.current] = layout
            persist(display.current)
            let signature = "\(screen.axVisibleFrame)@\(spacing.padding):\(spacing.gap)"
            guard applications[display.current, default: LayoutApplication()].needsApply(layout, signature: signature,
                        now: Date.timeIntervalSinceReferenceDate, force: force) else { continue }
            var requests: [(AXUIElement, CGRect)] = []
            let frames = layout.frames(in: screen.axVisibleFrame, gap: CGFloat(spacing.gap), padding: CGFloat(spacing.padding))
            for window in members {
                guard let frame = frames[window.identity] else { continue }
                if originalFrames[window.identity] == nil { originalFrames[window.identity] = window.frame }
                requests.append((window.element, frame))
            }
            if requests.isEmpty {
                applications[display.current, default: LayoutApplication()].succeeded(layout, signature: signature)
            } else {
                batches.append(Batch(space: display.current, layout: layout, signature: signature, requests: requests))
            }

        }
        guard !batches.isEmpty else { return }
        isLayingOut = true
        layoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isLayingOut = false
                if let command = self.pendingCommand { self.pendingCommand = nil; self.execute(command) }
            }
            for batch in batches {
                do {
                    try Task.checkCancellation()
                    let accepted = try await self.applyFrames(batch.requests)
                    try Task.checkCancellation()
                    guard self.enabled else { return }
                    if let layout = batch.layout {
                        if accepted {
                            self.applications[batch.space, default: LayoutApplication()].succeeded(layout, signature: batch.signature)
                        } else {
                            var state = self.applications[batch.space, default: LayoutApplication()]
                            state.failed(layout, signature: batch.signature, now: Date.timeIntervalSinceReferenceDate)
                            self.applications[batch.space] = state
                            if state.failureCount == 1 { self.report("部分窗口暂时拒绝调整；将延迟重试，尺寸受限的窗口可设为浮动。", error: true) }
                        }
                    }
                } catch {
                    if let layout = batch.layout {
                        self.applications[batch.space, default: LayoutApplication()].failed(layout, signature: batch.signature, now: Date.timeIntervalSinceReferenceDate)
                    }
                    if error is CancellationError { return }
                    self.report(error.localizedDescription, error: true)
                }
            }
        }
    }
    private func restoreZoom(for window: ManagedWindow) async throws {
        guard let entry = zoomed.first(where: { $0.value.window.identity == window.identity }) else { return }
        guard try await AX.applyFrames([(window.element, entry.value.restoreFrame)]) else {
            throw AppFailure("窗口暂时无法恢复原尺寸，请重试。")
        }
        zoomed.removeValue(forKey: entry.key)
        applications.removeValue(forKey: entry.key)
    }
    private func swap(_ direction: Direction) throws {
        guard let window = self.focusedWindow(), tilingPolicy?.isTiled(window.identity) == true,
              let space = spaces.memberships(window.id).first,
              var layout = layouts[space], let index = layout.ids.firstIndex(of: window.identity),
              let screen = Windows.screen(for: window.frame) else { throw AppFailure("前台窗口不在平铺布局中。") }
        let spacing = LayoutSpacing.load()
        let geometry = layout.frames(in: screen.axVisibleFrame, gap: CGFloat(spacing.gap), padding: CGFloat(spacing.padding))
        let frames = layout.ids.compactMap { geometry[$0] }
        guard let next = Layout.neighbor(of: index, direction: direction, frames: frames) else { report("该方向没有平铺窗口"); return }
        layout.drop(window.identity, onto: layout.ids[next], zone: .center)
        layouts[space] = layout
        persist(space)
        report("已交换窗口位置")
    }
    private func captureDrag(at point: CGPoint) -> TileDragContext? {
        guard enabled, !busy, !isLayingOut, AXIsProcessTrusted(), spaces.missionControl() == nil,
              let window = focusedWindow(), tilingPolicy?.isTiled(window.identity) == true,
              let space = spaces.memberships(window.id).first, zoomed[space] == nil,
              let members = tiledWindows[space], let source = members.first(where: { $0.identity == window.identity }),
              source.frame.contains(point) else { return nil }
        return TileDragContext(space: space, source: source, candidates: members)
    }
    private func validateDrag(_ context: TileDragContext) -> Bool {
        guard enabled, !busy, !isLayingOut, zoomed[context.space] == nil, AXIsProcessTrusted(), spaces.missionControl() == nil,
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
            persist(context.space)
            report(zone == .center ? "已交换窗口位置" : "已重新分区平铺")
        }
        // Dropping outside a tile returns the source to its existing tile.
        refresh(force: true)
    }
}
