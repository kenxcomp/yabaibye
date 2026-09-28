import Foundation

public struct LayoutSpacing: Equatable {
    public static let standard = LayoutSpacing()
    public let padding: Int
    public let gap: Int
    public init(padding: Int = 10, gap: Int = 10) {
        self.padding = min(100, max(0, padding))
        self.gap = min(100, max(0, gap))
    }
    public static func load(from defaults: UserDefaults = .standard) -> LayoutSpacing {
        func number(_ key: String) -> Int {
            guard let number = defaults.object(forKey: key) as? NSNumber, number.doubleValue.isFinite else { return 10 }
            return Int(min(100, max(0, number.doubleValue)).rounded())
        }
        return LayoutSpacing(padding: number("tiling.outerPadding"), gap: number("tiling.windowGap"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(padding, forKey: "tiling.outerPadding")
        defaults.set(gap, forKey: "tiling.windowGap")
    }
}
