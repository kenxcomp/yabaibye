import AppKit

/// Isolated native windows for trying drag behavior without moving the user's work.
@MainActor final class DragPractice: NSObject, NSWindowDelegate {
    private var windows: [NSWindow] = []
    private var manager: WindowManager?
    private var completion: (() -> Void)?
    private var closing = false
    func run(completion: @escaping () -> Void) throws {
        self.completion = completion
        guard let screen = NSScreen.screens.first else { throw AppFailure("没有显示器") }
        for name in ["A", "B", "C"] {
            let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 100, y: screen.frame.minY + 200, width: 400, height: 400),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Yabaibye 拖拽练习 \(name)"
            window.isReleasedWhenClosed = false; window.delegate = self
            window.isMovableByWindowBackground = true
            let label = NSTextField(wrappingLabelWithString: "\(name)\n\n拖动标题栏到其他窗口：\n中间交换，四边分割。\n\n练习：A → B 下方，再 A → C 右侧。\n关闭任意练习窗口即可结束并恢复管理。")
            label.font = .systemFont(ofSize: 22); label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor), label.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: window.contentView!.widthAnchor, constant: -40)])
            windows.append(window); window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        let manager = WindowManager(visibleWindows: { [weak self] in
            guard let self else { return [] }
            let root = AXUIElementCreateApplication(getpid())
            return (AX.value(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap { Windows.make($0, pid: getpid()) }
                .filter { item in self.windows.contains { UInt32($0.windowNumber) == item.id } }
        }, focusedWindow: { [weak self] in
            guard let self, let window = Windows.focused(), window.pid == getpid(),
                  self.windows.contains(where: { UInt32($0.windowNumber) == window.id }) else { return nil }
            return window
        }, persistLayouts: false, allowedWindows: Set(windows.map { "\(getpid()):\($0.windowNumber)" }), registerHotkeys: false)
        self.manager = manager
        do { try manager.start() } catch { finish(); throw error }
    }
    func windowWillClose(_ notification: Notification) { finish() }
    func finish() {
        guard !closing else { return }; closing = true
        manager?.stop(); manager = nil
        windows.forEach { $0.delegate = nil; $0.close() }; windows.removeAll()
        completion?(); completion = nil
    }
}
