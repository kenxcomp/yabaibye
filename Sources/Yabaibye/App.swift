import AppKit
import ServiceManagement
import SpaceBridge
import YabaibyeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let manager = WindowManager()
    private var item: NSStatusItem!
    private var helpWindow: NSWindow?
    private var statusItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Raw CLI diagnostics are read-only and never register keys or change layouts.
        if CommandLine.arguments.contains("--diagnose") {
            print(Self.diagnostics())
            NSApp.terminate(nil); return
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kenxcomp.yabaibye").filter { $0.processIdentifier != getpid() }
        guard others.isEmpty else { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "YB Ⅱ"
        item.button?.toolTip = "Yabaibye — 原生 Space 与窗口平铺"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        manager.changed = { [weak self] in
            guard let self else { return }
            self.item.button?.title = self.manager.enabled ? "YB" : "YB Ⅱ"
            self.item.button?.toolTip = self.manager.status
            self.statusItem?.title = self.manager.status
        }
        if UserDefaults.standard.bool(forKey: "managerEnabled") {
            do { try manager.start() } catch { manager.report(error.localizedDescription, error: true) }
        }
        if !UserDefaults.standard.bool(forKey: "hasOpened") || !manager.enabled {
            UserDefaults.standard.set(true, forKey: "hasOpened")
            showHelp()
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        statusItem = add(manager.status, to: menu)
        menu.addItem(.separator())
        add(manager.enabled ? "暂停窗口管理" : "启用窗口管理", to: menu, action: #selector(toggle))
        add("重新平铺当前桌面", to: menu, action: #selector(retile))
        if let displays = try? manager.spaces.snapshot() {
            let submenu = NSMenu()
            for number in 1...9 {
                guard let target = SpaceRouter.numbered(number, displays: displays) else { break }
                let displayIndex = displays.firstIndex(of: target.display).map { $0 + 1 } ?? 1
                let entry = add("Space \(number) · 屏幕 \(displayIndex)\(target.display.current == target.desktop.id ? " ✓" : "")", to: submenu, action: #selector(selectSpace(_:)))
                entry.tag = number; entry.isEnabled = manager.enabled
            }
            let entry = add("Space 列表", to: menu); entry.submenu = submenu
        }
        menu.addItem(.separator())
        add(AXIsProcessTrusted() ? "辅助功能权限：已授权" : "授予辅助功能权限…", to: menu, action: #selector(requestAccess))
        let login = add("登录时启动", to: menu, action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add("使用说明与快捷键…", to: menu, action: #selector(showHelp))
        add("运行窗口与 Space 自检…", to: menu, action: #selector(runSmokeTest))
        add("复制诊断信息", to: menu, action: #selector(copyDiagnostics))
        menu.addItem(.separator())
        add("退出 Yabaibye", to: menu, action: #selector(quit), key: "q")
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; menu.addItem(entry); return entry
    }
    @objc func toggle() {
        if manager.enabled { manager.stop() }
        else { do { try manager.start() } catch { showError(error) } }
    }
    @objc func retile() { manager.refresh(force: true) }
    @objc func selectSpace(_ sender: NSMenuItem) { manager.execute(.focusSpace(sender.tag)) }
    @objc func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(error) }
    }
    @objc func copyDiagnostics() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.diagnostics(), forType: .string)
        manager.report("诊断信息已复制（不含窗口标题）")
    }
    static func diagnostics() -> String {
        let spaces = Spaces()
        var data: [String: Any] = [
            "version": "0.1.0", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibilityTrusted": AXIsProcessTrusted(), "postEventsAllowed": CGPreflightPostEventAccess(),
            "spaceReadSymbols": YBHasSpaceReadAPI(), "spaceMoveSymbols": YBHasWindowMoveAPI(),
            "separateSpaces": NSScreen.screensHaveSeparateSpaces, "conflictingProcesses": WindowManager.conflicts(),
            "screens": NSScreen.screens.map { ["uuid": $0.uuid, "id": $0.displayID, "frame": NSStringFromRect($0.frame)] as [String: Any] }
        ]
        do { data["displays"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spaces.snapshot())) }
        catch { data["spaceError"] = error.localizedDescription }
        let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    private var smokeTest: SmokeTest?
    @objc func runSmokeTest() {
        guard smokeTest == nil else { return }
        if manager.enabled { manager.stop() }
        let test = SmokeTest()
        smokeTest = test
        test.run { [weak self] report in
            self?.smokeTest = nil
            let alert = NSAlert(); alert.messageText = "自检结果"; alert.informativeText = report
            alert.runModal()
        }
    }
    @objc func showHelp() {
        if let helpWindow { helpWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Yabaibye"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "你的桌面，键盘掌控。")
        title.font = .systemFont(ofSize: 26, weight: .bold); stack.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "原生 Space · 自动平铺 · 独立快捷键\n不需要关闭 SIP，不依赖 yabai 或 skhd。")
        subtitle.textColor = .secondaryLabelColor; stack.addArrangedSubview(subtitle)
        let keys = NSTextField(wrappingLabelWithString: "⌥ A … I              跳转 Space 1–9\n⌥ ⇧ A … I          将前台窗口移到 Space 1–9\n⌥ T                       前台窗口：平铺 / 浮动\n⌥ [ / ]                  当前屏幕：上一个 / 下一个 Space\n⌥ ⇧ [ / ]              第二屏幕：上一个 / 下一个 Space\n⌥ ← ↑ ↓ →         与该方向的平铺窗口交换")
        keys.font = .monospacedSystemFont(ofSize: 14, weight: .regular); stack.addArrangedSubview(keys)
        let details = NSTextField(wrappingLabelWithString: "首次使用：授予辅助功能权限，再从菜单栏启用。请先停止 yabai / skhd，并开启‘显示器具有单独的空间’。建议关闭‘根据最近使用情况自动重新排列空间’。\n\n桌面跨屏统一编号，不含全屏应用；相邻切换到边界即停止。Space 切换会短暂显示 Mission Control；拖拽移窗回退会跟随到目标桌面。当前版本的原生 Space 操作需在你的系统上验收。")
        details.font = .systemFont(ofSize: 12); details.textColor = .secondaryLabelColor; stack.addArrangedSubview(details)
        let button = NSButton(title: "打开辅助功能设置", target: self, action: #selector(requestAccess)); stack.addArrangedSubview(button)
        let testButton = NSButton(title: "运行窗口与 Space 自检", target: self, action: #selector(runSmokeTest)); stack.addArrangedSubview(testButton)
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)])
        helpWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showError(_ error: Error) {
        manager.report(error.localizedDescription, error: true)
        let alert = NSAlert(); alert.messageText = "暂时无法启用"; alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if CommandLine.arguments.contains("--diagnose") { return .terminateNow }
        // Give cancellation defers a main-run-loop turn to release any synthetic mouse-down.
        let resume = manager.enabled
        manager.stop()
        UserDefaults.standard.set(resume, forKey: "managerEnabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main
struct YabaibyeApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
