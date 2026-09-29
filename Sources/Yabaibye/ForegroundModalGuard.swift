import ApplicationServices

/// WindowServer process ownership does not identify a sheet. Check the focused
/// window's real accessibility relationship; unrelated same-app windows are safe.
enum ForegroundModalGuard {
    static func allowsRaise(_ window: AXUIElement,
                            read: (AXUIElement, String) -> (AXError, CFTypeRef?) = readAttribute) -> Bool {
        let (roleStatus, role) = read(window, kAXRoleAttribute)
        guard roleStatus == .success, role as? String == kAXWindowRole else { return false }
        let (modalStatus, modal) = read(window, kAXModalAttribute)
        switch modalStatus {
        case .success:
            guard let isModal = modal as? Bool, !isModal else { return false }
        case .attributeUnsupported, .noValue: break
        default: return false
        }
        let (childrenStatus, childrenValue) = read(window, kAXChildrenAttribute)
        let children: [AXUIElement]
        switch childrenStatus {
        case .success:
            guard let value = childrenValue as? [AXUIElement] else { return false }
            children = value
        case .attributeUnsupported, .noValue: children = []
        default: return false
        }
        // AXSheet's parent is its owning window. Inspect immediate roles only,
        // without traversing document content or treating all same-PID windows as sheets.
        for child in children {
            let (status, value) = read(child, kAXRoleAttribute)
            switch status {
            case .success:
                guard let role = value as? String, role != kAXSheetRole else { return false }
            case .attributeUnsupported, .noValue: continue
            default: return false
            }
        }
        return true
    }
    private static func readAttribute(_ element: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return (status, value)
    }
}
