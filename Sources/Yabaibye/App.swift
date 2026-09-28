import AppKit
import ServiceManagement
import SpaceBridge
import YabaibyeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let manager = WindowManager()
    private var item: NSStatusItem!
    private var helpWindow: NSWindow?
    private var statusItem: NSMenuItem?
    private var helpStatus: NSTextField?
    private let spacingSettings = SpacingSettings()
    private let foregroundKeeper = ForegroundKeeper()

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
        foregroundKeeper.start()
        manager.changed = { [weak self] in
            guard let self else { return }
            self.item.button?.title = self.manager.enabled ? "YB" : "YB Ⅱ"
            self.item.button?.toolTip = self.manager.status
            self.statusItem?.title = self.manager.status
            self.helpStatus?.stringValue = self.manager.status
        }
        if UserDefaults.standard.bool(forKey: "managerEnabled") {
            do { try manager.start() } catch { manager.report(error.localizedDescription, error: true) }
        }
        if !UserDefaults.standard.bool(forKey: "hasOpened") || !manager.enabled {
            UserDefaults.standard.set(true, forKey: "hasOpened")
            showHelp()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHelp()
        return true
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        statusItem = add(manager.status, to: menu)
        menu.addItem(.separator())
        add(manager.enabled ? "暂停窗口管理" : "启用窗口管理", to: menu, action: #selector(toggle))
        add("平铺留白…", to: menu, action: #selector(showSpacingSettings))
        let foreground = add("保持前台窗口在上层", to: menu, action: #selector(toggleForeground))
        foreground.state = ForegroundKeeper.enabled ? .on : .off
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
        add("拖拽布局练习…", to: menu, action: #selector(runDragPractice))
        add("运行窗口与 Space 自检…", to: menu, action: #selector(runSmokeTest))
        add("查看上次自检结果…", to: menu, action: #selector(showLastSmokeTest))
        add("复制诊断信息", to: menu, action: #selector(copyDiagnostics))
        menu.addItem(.separator())
        add("退出 Yabaibye", to: menu, action: #selector(quit), key: "q")
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self; menu.addItem(entry); return entry
    }
    @objc func toggle() {
        guard smokeTest == nil, practice == nil else { manager.report("请等待自检结束"); return }
        if manager.enabled { manager.stop() }
        else { do { try manager.start() } catch { showError(error) } }
    }
    @objc func toggleForeground() { ForegroundKeeper.enabled.toggle() }
    @objc func showSpacingSettings() {
        spacingSettings.onChange = { [weak self] in self?.manager.refresh(force: true) }
        spacingSettings.show()
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
    static func sipStatus() -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "unavailable" }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unavailable"
        } catch { return "unavailable" }
    }
    static func diagnostics() -> String {
        let spaces = Spaces()
        var data: [String: Any] = [
            "keepForegroundOnTop": ForegroundKeeper.enabled, "tilingPadding": LayoutSpacing.load().padding, "tilingGap": LayoutSpacing.load().gap,
            "sipStatus": sipStatus(), "version": "0.1.0", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibilityTrusted": AXIsProcessTrusted(), "postEventsAllowed": CGPreflightPostEventAccess(),
            "spaceReadSymbols": YBHasSpaceReadAPI(), "spaceMoveSymbols": YBHasWindowMoveAPI(), "bridgedWindowMoveAPI": YBHasBridgedWindowMoveAPI(),
            "separateSpaces": NSScreen.screensHaveSeparateSpaces, "conflictingProcesses": WindowManager.conflicts(),
            "screens": NSScreen.screens.map { ["uuid": $0.uuid, "id": $0.displayID, "frame": NSStringFromRect($0.frame)] as [String: Any] }
        ]
        do { data["displays"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spaces.snapshot())) }
        catch { data["spaceError"] = error.localizedDescription }
        let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        return encoded.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    private var practice: DragPractice?
    private var resumeAfterPractice = false
    @objc func runDragPractice() {
        guard smokeTest == nil, practice == nil else { return }
        let resume = manager.enabled
        resumeAfterPractice = resume
        manager.stop()
        let practice = DragPractice(); self.practice = practice
        do {
            try practice.run { [weak self] in
                guard let self else { return }
                self.practice = nil
                if resume { do { try self.manager.start() } catch { self.showError(error) } }
            }
        } catch { self.practice = nil; showError(error) }
    }
    private var smokeTest: SmokeTest?
    @objc func runSmokeTest() {
        guard smokeTest == nil, practice == nil else { return }
        if manager.enabled { manager.stop() }
        let test = SmokeTest()
        smokeTest = test
        test.run { [weak self] report in
            self?.smokeTest = nil
            UserDefaults.standard.set(report, forKey: "lastSmokeTestReport")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSmokeTestTime")
            self?.manager.report(report.contains("FAIL：") ? "自检未通过；可从菜单查看结果" : "自检完成；可从菜单查看结果")
        }
    }
    @objc func showLastSmokeTest() {
        let alert = NSAlert(); alert.messageText = "上次自检结果"
        alert.informativeText = UserDefaults.standard.string(forKey: "lastSmokeTestReport") ?? "尚未运行自检。"
        showHelp(); alert.beginSheetModal(for: helpWindow!)
    }
    @objc func showHelp() {
        if let helpWindow { helpWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Yabaibye"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "你的桌面，键盘掌控。")
        title.font = .systemFont(ofSize: 26, weight: .bold); stack.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "原生 Space · 自动平铺 · 独立快捷键\n不需要关闭 SIP，不依赖 yabai 或 skhd。")
        subtitle.textColor = .secondaryLabelColor; stack.addArrangedSubview(subtitle)
        let keys = NSTextField(wrappingLabelWithString: "⌥ A … I              跳转 Space 1–9\n⌥ ⇧ A … I          将前台窗口移到 Space 1–9\n⌥ T                       前台窗口：平铺 / 浮动\n⌥ [ / ]                  当前屏幕：上一个 / 下一个 Space\n⌥ ⇧ [ / ]              第二屏幕：上一个 / 下一个 Space\n⌥ ← ↑ ↓ →         与该方向的平铺窗口交换")
        keys.font = .monospacedSystemFont(ofSize: 14, weight: .regular); stack.addArrangedSubview(keys)
        let details = NSTextField(wrappingLabelWithString: "首次使用：授予辅助功能权限，再从菜单栏启用。请先停止 yabai / skhd，并开启‘显示器具有单独的空间’。建议关闭‘根据最近使用情况自动重新排列空间’。\n\n桌面跨屏统一编号，不含全屏应用；相邻切换到边界即停止。Space 切换必要时会短暂显示 Mission Control；移窗后保持当前桌面。当前版本的原生 Space 操作需在你的系统上验收。")
        details.font = .systemFont(ofSize: 12); details.textColor = .secondaryLabelColor; stack.addArrangedSubview(details)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        buttons.addArrangedSubview(NSButton(title: "权限设置", target: self, action: #selector(requestAccess)))
        buttons.addArrangedSubview(NSButton(title: "启用 / 暂停管理", target: self, action: #selector(toggle)))
        buttons.addArrangedSubview(NSButton(title: "运行窗口与 Space 自检", target: self, action: #selector(runSmokeTest)))
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(NSButton(title: "平铺留白…", target: self, action: #selector(showSpacingSettings)))
        stack.addArrangedSubview(NSButton(title: "拖拽布局练习（仅测试窗口）", target: self, action: #selector(runDragPractice)))
        let status = NSTextField(wrappingLabelWithString: manager.status); status.textColor = .secondaryLabelColor
        helpStatus = status; stack.addArrangedSubview(status)
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)])
        helpWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showError(_ error: Error) {
        manager.report(error.localizedDescription, error: true)
        let alert = NSAlert(); alert.messageText = "暂时无法启用"; alert.informativeText = error.localizedDescription
        showHelp(); alert.beginSheetModal(for: helpWindow!)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if CommandLine.arguments.contains("--diagnose") { return .terminateNow }
        // Give cancellation defers a main-run-loop turn to restore temporary accessibility settings.
        let resume = manager.enabled || (practice != nil && resumeAfterPractice)
        foregroundKeeper.stop()
        practice?.finish()
        manager.stop()
        smokeTest?.cancel()
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
