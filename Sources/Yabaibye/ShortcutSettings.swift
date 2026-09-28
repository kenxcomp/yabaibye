import AppKit
import YabaibyeCore

@MainActor final class ShortcutSettings: NSObject {
    @MainActor private struct Row {
        let command: Command
        let key: NSPopUpButton
        let modifiers: [NSButton] // Option, Shift, Control, Command
        var binding: Binding {
            Binding(UInt32(key.selectedTag()), shift: modifiers[1].state == .on,
                    control: modifiers[2].state == .on, option: modifiers[0].state == .on,
                    cmd: modifiers[3].state == .on, command: command)
        }
    }
    private var window: NSWindow?
    private var rows: [Row] = []
    private let message = NSTextField(wrappingLabelWithString: "修改后点击保存；关闭窗口会放弃未保存的修改。")
    var onSave: (([Binding]) throws -> Void)?
    func show() {
        if let window { sync(ShortcutPreferences.load()); message.stringValue = "修改后点击保存。"; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "快捷键设置"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "选择你的顺手键位")
        title.font = .systemFont(ofSize: 22, weight: .semibold); stack.addArrangedSubview(title)
        let note = NSTextField(wrappingLabelWithString: "默认主行 A S D F G H J K L 对应 Space 1–9。每项操作均可独立修改按键与修饰键。使用物理 ANSI 键位。")
        note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 410).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 604).isActive = true
        let list = NSStackView(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        list.translatesAutoresizingMaskIntoConstraints = false
        for binding in ShortcutPreferences.load() {
            let line = NSStackView(); line.orientation = .horizontal; line.spacing = 10
            let label = NSTextField(labelWithString: binding.actionLabel)
            label.widthAnchor.constraint(equalToConstant: 190).isActive = true; line.addArrangedSubview(label)
            let key = NSPopUpButton(frame: .zero, pullsDown: false)
            for code in Binding.keyNames.keys.sorted(by: { Binding.keyNames[$0]! < Binding.keyNames[$1]! }) {
                key.addItem(withTitle: Binding.keyNames[code]!); key.lastItem?.tag = Int(code)
            }
            key.widthAnchor.constraint(equalToConstant: 95).isActive = true
            key.setAccessibilityLabel(binding.actionLabel + "按键"); line.addArrangedSubview(key)
            let modifiers = ["⌥", "⇧", "⌃", "⌘"].enumerated().map { index, symbol in
                let button = NSButton(checkboxWithTitle: symbol, target: nil, action: nil)
                button.setAccessibilityLabel(binding.actionLabel + " " + ["Option", "Shift", "Control", "Command"][index])
                line.addArrangedSubview(button); return button
            }
            rows.append(Row(command: binding.command, key: key, modifiers: modifiers)); list.addArrangedSubview(line)
        }
        scroll.documentView = list
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        stack.addArrangedSubview(scroll)
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        message.widthAnchor.constraint(equalToConstant: 604).isActive = true
        stack.addArrangedSubview(message)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 12
        buttons.addArrangedSubview(NSButton(title: "恢复默认（保存后生效）", target: self, action: #selector(reset)))
        buttons.addArrangedSubview(NSButton(title: "保存快捷键", target: self, action: #selector(save)))
        stack.addArrangedSubview(buttons)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        self.window = window; sync(ShortcutPreferences.load())
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, list.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func sync(_ bindings: [Binding]) {
        for (row, binding) in zip(rows, bindings) {
            row.key.selectItem(withTag: Int(binding.keyCode))
            for (button, on) in zip(row.modifiers, [binding.option, binding.shift, binding.control, binding.cmd]) { button.state = on ? .on : .off }
        }
    }
    @objc private func reset() { sync(Binding.defaults); message.stringValue = "已填入默认键位，点击保存后生效。" }
    @objc private func save() {
        do {
            try onSave?(rows.map(\.binding))
            message.textColor = .secondaryLabelColor; message.stringValue = "快捷键已保存。"
        } catch { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    }
}
