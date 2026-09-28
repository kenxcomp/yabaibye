import AppKit
import SpaceBridge
import YabaibyeCore

/// Re-raises the already active app's focused window when a background normal
/// window is placed ahead of it. Never activates an app or changes window levels.
@MainActor final class ForegroundKeeper {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "keepForegroundOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepForegroundOnTop") }
    }
    private var timer: Timer?
    private var lastAttempt: String?
    private let spaces = Spaces()
    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; lastAttempt = nil }
    private func refresh() {
        guard Self.enabled, AXIsProcessTrusted(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              spaces.missionControl() == nil,
              let active = NSWorkspace.shared.frontmostApplication,
              active.activationPolicy == .regular, !active.isHidden else { lastAttempt = nil; return }
        let root = AXUIElementCreateApplication(active.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let focused = AX.element(root, kAXFocusedWindowAttribute),
              AX.value(focused, kAXMinimizedAttribute) as? Bool != true,
              AX.value(focused, "AXFullScreen") as? Bool != true else { lastAttempt = nil; return }
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
        guard let other = ForegroundPolicy.obstruction(focusedID: id, activePID: active.processIdentifier, stack: stack) else {
            lastAttempt = nil; return
        }
        let attempt = "\(active.processIdentifier):\(id):\(other)"
        guard lastAttempt != attempt else { return }
        lastAttempt = attempt
        // Verify focus again so a user-initiated app switch cannot be undone.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == active.processIdentifier else { return }
        _ = AXUIElementPerformAction(focused, kAXRaiseAction as CFString)
    }
}
