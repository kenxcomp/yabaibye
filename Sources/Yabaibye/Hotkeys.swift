import Carbon
import YabaibyeCore

@MainActor final class Hotkeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var bindings: [Binding] = []
    var onCommand: ((Command) -> Void)?
    private static let signature: OSType = 0x59425945

    func start(bindings: [Binding] = ShortcutPreferences.load()) throws {
        if let error = ShortcutPreferences.validate(bindings) { throw AppFailure(error) }
        stop()
        self.bindings = bindings
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Hotkeys.signature, id.id > 0, id.id <= Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().bindings.count else {
                return OSStatus(eventNotHandledErr)
            }
            let instance = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            instance.onCommand?(instance.bindings[Int(id.id) - 1].command)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw AppFailure("无法安装快捷键处理器（\(status)）。") }
        for (index, binding) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let modifiers = (binding.option ? UInt32(optionKey) : 0) | (binding.shift ? UInt32(shiftKey) : 0) | (binding.control ? UInt32(controlKey) : 0) | (binding.cmd ? UInt32(cmdKey) : 0)
            let code = RegisterEventHotKey(binding.keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: UInt32(index + 1)),
                                           GetApplicationEventTarget(), 0, &ref)
            guard code == noErr, let ref else {
                stop()
                throw AppFailure("快捷键 \(binding.label) 已被占用或无法注册（\(code)）；请调整冲突快捷键后重试。")
            }
            references.append(ref)
        }
    }
    func stop() {
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
