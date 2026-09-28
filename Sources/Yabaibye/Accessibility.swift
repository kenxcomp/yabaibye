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

@MainActor enum Windows {
    static func focused() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = AX.element(root, kAXFocusedWindowAttribute) else { return nil }
        return make(element, pid: app.processIdentifier)
    }
    static func make(_ element: AXUIElement, pid: pid_t) -> ManagedWindow? {
        guard AX.value(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              AX.value(element, kAXMinimizedAttribute) as? Bool != true,
              AX.value(element, "AXFullScreen") as? Bool != true,
              let frame = AX.frame(element), frame.width > 80, frame.height > 60 else { return nil }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else { return nil }
        let id = YBWindowID(element)
        guard id != 0 else { return nil }
        return ManagedWindow(id: id, pid: pid, element: element, frame: frame)
    }
    static func visible() -> [ManagedWindow] {
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        let ids = Set(records.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let pids = Set(records.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
        return NSWorkspace.shared.runningApplications.filter {
            pids.contains($0.processIdentifier) && $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
        }.flatMap { app -> [ManagedWindow] in
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            let windows = AX.value(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            return windows.compactMap { make($0, pid: app.processIdentifier) }.filter { ids.contains($0.id) }
        }
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
