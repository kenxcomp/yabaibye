import AppKit
import YabaibyeCore

@MainActor final class SpacingSettings: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private var sliders: [NSSlider] = []
    private var fields: [NSTextField] = []
    private let preview = SpacingPreview()
    private var foregroundToggle: NSButton?
    var onChange: (() -> Void)?

    func show() {
        if let window { sync(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "平铺留白"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "让桌面留一点呼吸空间")
        title.font = .systemFont(ofSize: 20, weight: .semibold); stack.addArrangedSubview(title)
        let description = NSTextField(wrappingLabelWithString: "拖动滑块或输入数值，自动保存并应用到所有屏幕的平铺窗口。浮动窗口不受影响。")
        description.textColor = .secondaryLabelColor; stack.addArrangedSubview(description)
        for (index, name) in ["屏幕边缘留白", "窗口之间间距"].enumerated() {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            let label = NSTextField(labelWithString: name); label.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let slider = NSSlider(value: 10, minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged(_:)))
            slider.tag = index; slider.isContinuous = true; slider.setAccessibilityLabel(name)
            slider.widthAnchor.constraint(equalToConstant: 205).isActive = true
            let field = NSTextField(string: "10"); field.tag = index; field.delegate = self
            field.setAccessibilityLabel(name + "数值"); field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
            formatter.minimum = 0; formatter.maximum = 100; formatter.isLenient = false
            field.formatter = formatter
            row.addArrangedSubview(label); row.addArrangedSubview(slider); row.addArrangedSubview(field)
            row.addArrangedSubview(NSTextField(labelWithString: "pt"))
            sliders.append(slider); fields.append(field); stack.addArrangedSubview(row)
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 424).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 160).isActive = true
        preview.setAccessibilityElement(true); preview.setAccessibilityRole(.image)
        stack.addArrangedSubview(preview)
        let presets = NSStackView(); presets.orientation = .horizontal; presets.spacing = 12
        for (value, title) in [(0, "无留白"), (10, "恢复默认"), (24, "宽松")] {
            let button = NSButton(title: title, target: self, action: #selector(preset(_:))); button.tag = value
            presets.addArrangedSubview(button)
        }
        stack.addArrangedSubview(presets)
        let foreground = NSButton(checkboxWithTitle: "保持前台窗口在上层", target: self, action: #selector(toggleForeground(_:)))
        foregroundToggle = foreground; stack.addArrangedSubview(foreground)
        let note = NSTextField(wrappingLabelWithString: "减少后台普通窗口的遮挡，不切换应用焦点。系统提示和特殊浮层仍由 macOS 管理。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; stack.addArrangedSubview(note)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        self.window = window; sync()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func toggleForeground(_ sender: NSButton) { ForegroundKeeper.enabled = sender.state == .on }
    @objc private func sliderChanged(_ sender: NSSlider) { update(index: sender.tag, value: Int(sender.doubleValue.rounded())) }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        guard let number = (field.formatter as? NumberFormatter)?.number(from: field.stringValue) else { sync(); return }
        update(index: field.tag, value: number.intValue)
    }
    @objc private func preset(_ sender: NSButton) { save(LayoutSpacing(padding: sender.tag, gap: sender.tag)) }
    private func update(index: Int, value: Int) {
        let previous = LayoutSpacing.load()
        save(LayoutSpacing(padding: index == 0 ? value : previous.padding, gap: index == 1 ? value : previous.gap))
    }
    private func save(_ value: LayoutSpacing) { value.save(); sync(); onChange?() }
    private func sync() {
        let value = LayoutSpacing.load()
        for (index, number) in [value.padding, value.gap].enumerated() where sliders.indices.contains(index) {
            sliders[index].integerValue = number; fields[index].integerValue = number
        }
        preview.spacing = value
        foregroundToggle?.state = ForegroundKeeper.enabled ? .on : .off
    }
}

private final class SpacingPreview: NSView {
    var spacing = LayoutSpacing.standard {
        didSet {
            needsDisplay = true
            setAccessibilityLabel("留白预览：边缘 \(spacing.padding) pt，窗口间距 \(spacing.gap) pt")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        // A scaled 1000 x 360 desktop makes the selected point sizes comparable.
        let scale: CGFloat = bounds.width / 1000
        let tiles = TileLayout(ids: ["1", "2", "3", "4"]).frames(in: bounds, gap: CGFloat(spacing.gap) * scale, padding: CGFloat(spacing.padding) * scale)
        NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
        for frame in tiles.values { NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill() }
    }
}
