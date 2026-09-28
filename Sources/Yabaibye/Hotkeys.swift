import Carbon
import YabaibyeCore

@MainActor final class Hotkeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onCommand: ((Command) -> Void)?
    private static let signature: OSType = 0x59425945

    func start() throws {
        stop()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Hotkeys.signature, id.id > 0, id.id <= Binding.defaults.count else {
                return OSStatus(eventNotHandledErr)
            }
            let instance = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            instance.onCommand?(Binding.defaults[Int(id.id) - 1].command)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw AppFailure("无法安装快捷键处理器（\(status)）。") }
        for (index, binding) in Binding.defaults.enumerated() {
            var ref: EventHotKeyRef?
            let modifiers = UInt32(optionKey) | (binding.shift ? UInt32(shiftKey) : 0)
            let code = RegisterEventHotKey(binding.keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: UInt32(index + 1)),
                                           GetApplicationEventTarget(), 0, &ref)
            guard code == noErr, let ref else {
                stop()
                throw AppFailure("快捷键注册失败（第 \(index + 1) 项，\(code)）；请退出其他快捷键工具后重试。")
            }
            references.append(ref)
        }
    }
    func stop() {
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
