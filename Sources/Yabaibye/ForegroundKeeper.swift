import AppKit
import OSLog
import SpaceBridge
import YabaibyeCore

/// Re-raises the already active app's focused window when a background normal
/// window is placed ahead of it. Never activates apps or changes window levels.
@MainActor final class ForegroundKeeper {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepForegroundOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepForegroundOnTop") }
    }
    struct Observation {
        let pid: pid_t
        let windowID: UInt32
        let element: AXUIElement
        let obstructionID: UInt32
        let frame: CGRect
        var occluders: [WindowStackEntry] = []
        func matches(_ other: Observation) -> Bool {
            pid == other.pid && windowID == other.windowID && obstructionID == other.obstructionID && frame == other.frame
        }
    }
    private let logger = Logger(subsystem: "com.kenxcomp.yabaibye", category: "foreground")
    private var timer: Timer?
    private var pending: Observation?
    private var attempts = 0
    private var nextAttempt: TimeInterval = 0
    private let observe: () -> Observation?
    private let isCurrent: (Observation) -> Bool
    private let raise: (Observation) -> AXError
    private let now: () -> TimeInterval

    init(observe: (() -> Observation?)? = nil,
         isCurrent: ((Observation) -> Bool)? = nil,
         raise: ((Observation) -> AXError)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.observe = observe ?? { ForegroundKeeper.observeObstruction() }
        self.isCurrent = isCurrent ?? { ForegroundKeeper.hasCurrentFocus($0) }
        self.raise = raise ?? { AXUIElementPerformAction($0.element, kAXRaiseAction as CFString) }
        self.now = now
    }
    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; reset() }
    private func reset() { pending = nil; attempts = 0; nextAttempt = 0 }
    func refresh() {
        guard let observation = observe() else { reset(); return }
        if pending?.matches(observation) != true {
            reset()
            pending = observation
        }
        // AXRaise success only acknowledges the request. Confirm recovery in the
        // next stack snapshot; a background app may raise itself again meanwhile.
        // Bound each episode so an uncooperative app cannot cause an endless fight.
        guard isCurrent(observation) else { reset(); return }
        guard attempts < 4, now() >= nextAttempt else { return }
        let result = raise(observation)
        attempts += 1
        nextAttempt = now() + 0.4 * pow(2, Double(attempts - 1))
        if result != .success {
            logger.error("Foreground raise failed: AX=\(result.rawValue), attempt=\(self.attempts), pid=\(observation.pid), window=\(observation.windowID)")
        }
        if attempts == 4 {
            let layers = observation.occluders.map { "pid=\($0.owner)/window=\($0.id)/layer=\($0.layer)" }.joined(separator: ", ")
            logger.notice("Foreground obstruction snapshot: \(layers, privacy: .public)")
            logger.notice("Foreground recovery attempt limit reached; waiting for obstruction or focus/geometry to change. pid=\(observation.pid), window=\(observation.windowID)")
        }
    }
    private static func hasCurrentFocus(_ observation: Observation) -> Bool {
        guard enabled, !CGEventSource.buttonState(.combinedSessionState, button: .left),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == observation.pid else { return false }
        let root = AXUIElementCreateApplication(observation.pid)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let focused = AX.element(root, kAXFocusedWindowAttribute) else { return false }
        // Switching windows inside one app must not raise the old focused window.
        guard YBWindowID(focused) == observation.windowID,
              ForegroundModalGuard.allowsRaise(focused),
              let current = AX.element(root, kAXFocusedWindowAttribute) else { return false }
        // Modal reads can wait on another process. Check identity again afterward.
        return YBWindowID(current) == observation.windowID
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == observation.pid
            && !CGEventSource.buttonState(.combinedSessionState, button: .left)
    }
    private static func observeObstruction() -> Observation? {
        guard enabled, AXIsProcessTrusted(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              Spaces().missionControl() == nil,
              let active = NSWorkspace.shared.frontmostApplication,
              active.activationPolicy == .regular, !active.isHidden else { return nil }
        let root = AXUIElementCreateApplication(active.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let focused = AX.element(root, kAXFocusedWindowAttribute) else { return nil }
        guard AX.value(focused, kAXMinimizedAttribute) as? Bool != true,
              AX.value(focused, "AXFullScreen") as? Bool != true,
              ForegroundModalGuard.allowsRaise(focused) else { return nil }
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        let id = YBWindowID(focused)
        let stack = records.compactMap { record -> WindowStackEntry? in
            guard let wid = record[kCGWindowNumber as String] as? NSNumber,
                  let owner = record[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = record[kCGWindowLayer as String] as? Int,
                  (record[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return WindowStackEntry(id: wid.uint32Value, owner: owner.int32Value, layer: layer, frame: rect)
        }
        guard let other = ForegroundPolicy.obstruction(focusedID: id, activePID: active.processIdentifier, stack: stack),
              let entry = stack.first(where: { $0.id == id && $0.owner == active.processIdentifier }) else { return nil }
        let above = stack.prefix { $0.id != id }.filter { $0.owner != active.processIdentifier && $0.frame.intersects(entry.frame) }
        return Observation(pid: active.processIdentifier, windowID: id, element: focused, obstructionID: other, frame: entry.frame, occluders: Array(above))
    }
}
