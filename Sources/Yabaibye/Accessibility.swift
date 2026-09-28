import AppKit
import ApplicationServices
import SpaceBridge

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AX {
    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    static func element(_ object: AXUIElement, _ key: String) -> AXUIElement? {
        guard let result = value(object, key), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    @MainActor static func applyFrames(_ requests: [(AXUIElement, CGRect)]) async throws -> Bool {
        try Task.checkCancellation()
        var accepted = true
        var enhancedApps: [AXUIElement] = []
        var seenPIDs = Set<pid_t>()
        for (element, _) in requests {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, seenPIDs.insert(pid).inserted else { continue }
            let app = AXUIElementCreateApplication(pid)
            if value(app, "AXEnhancedUserInterface") as? Bool == true,
               AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) == .success {
                enhancedApps.append(app)
            }
        }
        defer { enhancedApps.forEach { AXUIElementSetAttributeValue($0, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        // AX setters can return before the app applies a frame. Separate phases so
        // an asynchronous size update cannot overwrite a queued position change.
        for (element, frame) in requests {
            var size = frame.size
            guard let value = AXValueCreate(.cgSize, &size) else { accepted = false; continue }
            if AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) != .success { accepted = false }
        }
        try await settle(requests.map { $0.0 })
        for (element, frame) in requests {
            var point = frame.origin
            guard let value = AXValueCreate(.cgPoint, &point) else { accepted = false; continue }
            if AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) != .success { accepted = false }
        }
        try await settle(requests.map { $0.0 })
        for (element, frame) in requests {
            var size = frame.size
            guard let value = AXValueCreate(.cgSize, &size) else { accepted = false; continue }
            if AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) != .success { accepted = false }
        }
        try await settle(requests.map { $0.0 })
        return accepted && requests.allSatisfy { element, desired in
            guard let actual = frame(element) else { return false }
            return abs(actual.minX - desired.minX) < 3 && abs(actual.minY - desired.minY) < 3
                && abs(actual.width - desired.width) < 3 && abs(actual.height - desired.height) < 3
        }
    }
    @MainActor private static func settle(_ elements: [AXUIElement]) async throws {
        var previous = elements.map { frame($0) }
        var unchanged = 0
        for _ in 0..<25 {
            try await Task.sleep(nanoseconds: 60_000_000)
            let current = elements.map { frame($0) }
            unchanged = current == previous ? unchanged + 1 : 0
            if unchanged >= 2 { return }
            previous = current
        }
    }
    static func descendant(_ root: AXUIElement, depth: Int = 6, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        if predicate(root) { return root }
        guard depth > 0 else { return nil }
        for child in children(root) {
            if let match = descendant(child, depth: depth - 1, matching: predicate) { return match }
        }
        return nil
    }
    static func identifier(_ element: AXUIElement) -> String { value(element, kAXIdentifierAttribute) as? String ?? "" }
}

struct ManagedWindow {
    let id: UInt32
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    var identity: String { "\(pid):\(id)" }
}

struct WindowSnapshot {
    var windows: [ManagedWindow]
    var complete = true
    var unavailableDisplays: Set<CGDirectDisplayID> = []
    func isReliable(on display: CGDirectDisplayID) -> Bool { complete && !unavailableDisplays.contains(display) }
}

@MainActor enum Windows {
    static func focused() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = AX.element(root, kAXFocusedWindowAttribute) else { return nil }
        return make(element, pid: app.processIdentifier)
    }
    enum Inspection {
        case managed(ManagedWindow), excluded, unavailable
    }
    static func make(_ element: AXUIElement, pid: pid_t) -> ManagedWindow? {
        if case .managed(let window) = inspect(element, pid: pid) { return window }
        return nil
    }
    static func inspect(_ element: AXUIElement, pid: pid_t) -> Inspection {
        guard let subrole = AX.value(element, kAXSubroleAttribute) as? String else { return .unavailable }
        guard subrole == kAXStandardWindowSubrole else { return .excluded }
        guard let minimized = AX.value(element, kAXMinimizedAttribute) as? Bool else { return .unavailable }
        if minimized { return .excluded }
        // AXFullScreen is optional, but messaging failure is not evidence of an ordinary window.
        var fullScreen: CFTypeRef?
        let fullScreenStatus = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreen)
        guard fullScreenStatus == .success || fullScreenStatus == .attributeUnsupported || fullScreenStatus == .noValue else { return .unavailable }
        if fullScreen as? Bool == true { return .excluded }
        guard let frame = AX.frame(element) else { return .unavailable }
        guard frame.width > 80, frame.height > 60 else { return .excluded }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success else { return .unavailable }
        guard settable.boolValue else { return .excluded }
        let id = YBWindowID(element)
        guard id != 0 else { return .unavailable }
        return .managed(ManagedWindow(id: id, pid: pid, element: element, frame: frame))
    }
    static func visible() -> [ManagedWindow] { snapshot().windows }
    static func snapshot() -> WindowSnapshot {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] else {
            return WindowSnapshot(windows: [], complete: false)
        }
        let normal = records.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let ids = Set(normal.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let pids = Set(normal.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
        var result = WindowSnapshot(windows: [])
        func unavailable(_ pid: pid_t) {
            for record in normal where record[kCGWindowOwnerPID as String] as? Int32 == pid {
                guard let bounds = record[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), let display = screen(for: rect) else {
                    result.complete = false; continue
                }
                result.unavailableDisplays.insert(display.displayID)
            }
        }
        for app in NSWorkspace.shared.runningApplications where
            pids.contains(app.processIdentifier) && app.activationPolicy == .regular && !app.isHidden && app.processIdentifier != getpid() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            guard let elements = AX.value(root, kAXWindowsAttribute) as? [AXUIElement], !elements.isEmpty else {
                unavailable(app.processIdentifier); continue
            }
            for element in elements {
                // Windows on other Spaces are irrelevant to this visible snapshot.
                let id = YBWindowID(element)
                if id != 0 && !ids.contains(id) { continue }
                switch inspect(element, pid: app.processIdentifier) {
                case .managed(let window): if ids.contains(window.id) { result.windows.append(window) }
                case .excluded: break
                case .unavailable: unavailable(app.processIdentifier)
                }
            }
        }
        return result
    }
    static func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { intersectionArea($0.axFrame, rect) < intersectionArea($1.axFrame, rect) }
    }
    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }
}
extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    var uuid: String {
        guard let value = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, value) as String
    }
    var axFrame: CGRect { axConvert(frame) }
    var axVisibleFrame: CGRect { axConvert(visibleFrame) }
    private func axConvert(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}
