import Foundation

public enum ShortcutPreferences {
    public static let storageKey = "shortcuts.v1"
    public static func validate(_ bindings: [Binding]) -> String? {
        guard bindings.map(\.command) == Binding.defaults.map(\.command) else { return "快捷键操作列表不完整。" }
        var seen = Set<String>()
        for binding in bindings {
            guard Binding.keyNames[binding.keyCode] != nil else { return "不支持的按键。" }
            guard binding.option || binding.control || binding.cmd else { return "\(binding.actionLabel) 至少需要 Option、Control 或 Command，避免拦截普通输入。" }
            guard seen.insert(binding.label).inserted else { return "快捷键 \(binding.label) 重复，请为每项操作选择不同组合。" }
        }
        return nil
    }
    public static func load(from defaults: UserDefaults = .standard) -> [Binding] {
        guard let data = defaults.data(forKey: storageKey),
              let bindings = try? JSONDecoder().decode([Binding].self, from: data), validate(bindings) == nil else { return Binding.defaults }
        return bindings
    }
    public static func save(_ bindings: [Binding], to defaults: UserDefaults = .standard) {
        guard validate(bindings) == nil, let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
