import AppKit
import CryptoKit
import SpaceBridge
import YabaibyeCore

struct WorkspaceObservation {
    let window: ManagedWindow
    let key: WorkspaceWindowKey
    let location: WorkspaceLocation
    let bounds: CGRect
}

struct WorkspaceSnapshot {
    var observations: [WorkspaceObservation]
    var complete: Bool
    var aliveIdentities: Set<String>? = nil
    var unavailableBundles: Set<String> = []
}

/// Unlike the tiler, memory must inspect windows on inactive desktops as well.
@MainActor enum WorkspaceWindows {
    static func snapshot(displays: [DisplaySpaces], session: String, salt: String, spaces: Spaces) -> WorkspaceSnapshot {
        guard let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]] else {
            return WorkspaceSnapshot(observations: [], complete: false)
        }
        let windowPIDs = Set(records.filter { $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { $0[kCGWindowOwnerPID as String] as? Int32 })
        let aliveIdentities = Set(records.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap { record -> String? in
            guard let pid = record[kCGWindowOwnerPID as String] as? Int32,
                  let id = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return "\(pid):\(id)"
        })
        var result = WorkspaceSnapshot(observations: [], complete: true, aliveIdentities: aliveIdentities)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() && windowPIDs.contains(app.processIdentifier) {
            guard let bundle = app.bundleIdentifier else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            guard let elements = AX.value(root, kAXWindowsAttribute) as? [AXUIElement] else {
                // Launching/terminating processes may temporarily lack an AX connection.
                result.unavailableBundles.insert(bundle); continue
            }
            for element in elements {
                switch Windows.inspect(element, pid: app.processIdentifier) {
                case .excluded: continue
                case .unavailable: result.unavailableBundles.insert(bundle)
                case .managed(let window):
                    guard let memberships = spaces.checkedMemberships(window.id) else { result.unavailableBundles.insert(bundle); continue }
                    guard memberships.count == 1,
                          let display = displays.first(where: { $0.spaces.contains(where: { $0.id == memberships[0] && $0.type == 0 }) }),
                          let index = display.spaces.filter({ $0.type == 0 }).firstIndex(where: { $0.id == memberships[0] }),
                          let screen = spaces.screen(for: display) else { continue }
                    // Hidden apps retain their previous geometry until they are shown again.
                    guard !app.isHidden else { continue }
                    let key = WorkspaceWindowKey(bundleID: bundle,
                        document: digest(AX.value(element, kAXDocumentAttribute) as? String, salt: salt),
                        identifier: digest(AX.value(element, kAXIdentifierAttribute) as? String, salt: salt),
                        title: digest(AX.value(element, kAXTitleAttribute) as? String, salt: salt))
                    result.observations.append(WorkspaceObservation(window: window, key: key,
                        location: WorkspaceLocation(display: display.uuid, space: memberships[0], normalIndex: index, session: session),
                        bounds: screen.axVisibleFrame))
                }
            }
        }
        return result
    }
    nonisolated static func digest(_ value: String?, salt: String) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return SHA256.hash(data: Data((salt + "\u{0}" + value).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func loginSession() -> String {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        let valid = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0
        let login = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first?.processIdentifier ?? 0
        // If the OS identity is unavailable, prevent reuse of native Space IDs across runs.
        return "\(valid ? String(cString: buffer) : UUID().uuidString):\(getuid()):\(login)"
    }
}
