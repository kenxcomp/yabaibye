import Foundation

/// Explicit tiling membership for window identities in one login session.
/// Visibility changes do not remove members; unknown windows remain floating.
public struct WindowTilingPolicy: Equatable, Codable {
    private var tiledWindowIDs: Set<String>

    public init(initialWindowIDs: Set<String>) {
        tiledWindowIDs = initialWindowIDs
    }

    public func isTiled(_ id: String) -> Bool {
        tiledWindowIDs.contains(id)
    }

    public mutating func setTiled(_ tiled: Bool, for id: String) {
        if tiled { tiledWindowIDs.insert(id) }
        else { tiledWindowIDs.remove(id) }
    }
}
