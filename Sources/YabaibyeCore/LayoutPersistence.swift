import Foundation

/// Window identities are valid only in the current login session. Store trees, not pixel sizes.
public struct LayoutPersistence {
    private struct Archive: Codable {
        var session: String
        var layouts: [String: TileLayout]
        var tilingPolicy: WindowTilingPolicy?
    }
    public static let storageKey = "tiling.layouts.v1"
    private let defaults: UserDefaults
    private var archive: Archive
    public init(session: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Archive.self, from: data), saved.session == session {
            archive = saved
        } else { archive = Archive(session: session, layouts: [:], tilingPolicy: nil) }
    }
    public var tilingPolicy: WindowTilingPolicy? { archive.tilingPolicy }
    public func layout(display: String, space: UInt64) -> TileLayout? { archive.layouts["\(display):\(space)"] }
    public mutating func save(_ layout: TileLayout, display: String, space: UInt64) {
        let key = "\(display):\(space)"
        guard archive.layouts[key] != layout else { return }
        archive.layouts[key] = layout
        persistArchive()
    }
    public mutating func saveTilingPolicy(_ policy: WindowTilingPolicy) {
        guard archive.tilingPolicy != policy else { return }
        archive.tilingPolicy = policy
        persistArchive()
    }
    private func persistArchive() {
        if let data = try? JSONEncoder().encode(archive) { defaults.set(data, forKey: Self.storageKey) }
    }
}
