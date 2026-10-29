import Foundation
import CoreGraphics

/// Persist only salted digests of accessibility identity strings, never document paths or titles.
public struct WorkspaceWindowKey: Equatable, Codable {
    public var bundleID: String
    public var document: String?
    public var identifier: String?
    public var title: String?
    public init(bundleID: String, document: String? = nil, identifier: String? = nil, title: String? = nil) {
        self.bundleID = bundleID; self.document = document; self.identifier = identifier; self.title = title
    }
}

public struct WorkspaceLocation: Equatable, Codable {
    public var display: String
    public var space: UInt64
    public var normalIndex: Int
    public var session: String
    public init(display: String, space: UInt64, normalIndex: Int, session: String) {
        self.display = display; self.space = space; self.normalIndex = normalIndex; self.session = session
    }
    public func resolve(in displays: [DisplaySpaces], session currentSession: String) -> SpaceTarget? {
        guard let display = displays.first(where: { $0.uuid.caseInsensitiveCompare(self.display) == .orderedSame }) else { return nil }
        if currentSession == session, let index = display.spaces.firstIndex(where: { $0.id == space && $0.type == 0 }) {
            return SpaceTarget(display: display, desktop: display.spaces[index], missionControlIndex: index)
        }
        // During this login, a missing ID means a deleted Space. Never substitute its neighbor.
        guard currentSession != session, normalIndex >= 0 else { return nil }
        let normal = display.spaces.enumerated().filter { $0.element.type == 0 }
        guard normal.indices.contains(normalIndex) else { return nil }
        let target = normal[normalIndex]
        return SpaceTarget(display: display, desktop: target.element, missionControlIndex: target.offset)
    }
}

public struct WorkspaceFrame: Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init?(frame: CGRect, bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0, !frame.isNull, !frame.isInfinite,
              frame.width > 0, frame.height > 0 else { return nil }
        x = (frame.minX - bounds.minX) / bounds.width; y = (frame.minY - bounds.minY) / bounds.height
        width = frame.width / bounds.width; height = frame.height / bounds.height
        guard [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
    }
    public func frame(in bounds: CGRect) -> CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: min(bounds.width, max(80, width * bounds.width)),
                          height: min(bounds.height, max(60, height * bounds.height)))
        return CGRect(x: min(bounds.maxX - size.width, max(bounds.minX, bounds.minX + x * bounds.width)),
                      y: min(bounds.maxY - size.height, max(bounds.minY, bounds.minY + y * bounds.height)),
                      width: size.width, height: size.height)
    }
}

public struct WorkspaceRecord: Equatable, Codable {
    public var id: String
    public var key: WorkspaceWindowKey
    public var location: WorkspaceLocation
    public var frame: WorkspaceFrame
    public var floatingFrame: WorkspaceFrame
    public var tiled: Bool
    public var allowTitleMatch: Bool?
    public var allowIdentifierMatch: Bool?
    public var allowBundleFallback: Bool?
    public var updated: Date
    public init(id: String = UUID().uuidString, key: WorkspaceWindowKey, location: WorkspaceLocation,
                frame: WorkspaceFrame, floatingFrame: WorkspaceFrame, tiled: Bool, updated: Date = Date(), allowBundleFallback: Bool = false, allowIdentifierMatch: Bool = false, allowTitleMatch: Bool = true) {
        self.id = id; self.key = key; self.location = location; self.frame = frame
        self.floatingFrame = floatingFrame; self.tiled = tiled; self.updated = updated
        self.allowBundleFallback = allowBundleFallback
        self.allowIdentifierMatch = allowIdentifierMatch
        self.allowTitleMatch = allowTitleMatch
    }
}

public struct WorkspaceSavedLayout: Equatable, Codable {
    public var location: WorkspaceLocation
    public var layout: TileLayout
    public init(location: WorkspaceLocation, layout: TileLayout) { self.location = location; self.layout = layout }
}

public enum WorkspaceMatcher {
    /// Only one-to-one matches are accepted. An app with multiple indistinguishable windows is left alone.
    public static func match(_ windows: [String: WorkspaceWindowKey], records: [WorkspaceRecord],
                             bindings: [String: String], excluding: Set<String> = [], allowBundleFallback: Bool = true) -> [String: String] {
        var result = bindings.filter { binding in windows[binding.key] != nil && records.contains(where: { $0.id == binding.value && $0.key.bundleID == windows[binding.key]?.bundleID }) }
        var remaining = records.filter { !Set(result.values).contains($0.id) }
        var pending = windows.filter { result[$0.key] == nil }
        for field: KeyPath<WorkspaceWindowKey, String?> in [\.document, \.identifier, \.title] {
            let candidates = pending.reduce(into: [String: [String]]()) { output, entry in
                guard let token = entry.value[keyPath: field], !token.isEmpty else { return }
                let matches = remaining.filter { $0.key.bundleID == entry.value.bundleID && $0.key[keyPath: field] == token &&
                    (field != \.identifier || $0.allowIdentifierMatch == true) &&
                    (field != \.title || $0.allowTitleMatch != false) &&
                    ($0.key.document == nil || entry.value.document == nil || $0.key.document == entry.value.document) }
                if matches.count == 1 { output[matches[0].id, default: []].append(entry.key) }
            }
            for (record, identities) in candidates where identities.count == 1 && !excluding.contains(identities[0]) {
                result[identities[0]] = record; pending.removeValue(forKey: identities[0])
                remaining.removeAll { $0.id == record }
            }
        }
        // A single-window app may change its title on startup. Never use this fallback for multiwindow apps.
        for bundle in Set(pending.values.map(\.bundleID)) {
            let current = windows.filter { $0.value.bundleID == bundle }
            let saved = records.filter { $0.key.bundleID == bundle }
            if allowBundleFallback, current.count == 1, saved.count == 1, let identity = current.keys.first,
               result[identity] == nil, !excluding.contains(identity), !result.values.contains(saved[0].id), saved[0].allowBundleFallback == true,
               (saved[0].key.document == nil || current[identity]?.document == nil || saved[0].key.document == current[identity]?.document) { result[identity] = saved[0].id }
        }
        return result
    }
}

public struct WorkspaceArchive: Codable {
    public static let storageKey = "workspace.memory.v1"
    public var salt = UUID().uuidString
    public var records: [WorkspaceRecord] = []
    public var layouts: [WorkspaceSavedLayout] = []
    public var displays: [DisplaySpaces] = []
    public init() {}
    public static func load(from defaults: UserDefaults) -> WorkspaceArchive {
        guard let data = defaults.data(forKey: storageKey), data.count < 8_000_000,
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.records.count <= 2048,
              Set(saved.records.map(\.id)).count == saved.records.count else { return Self() }
        var tiled = saved
        for index in tiled.records.indices where tiled.records[index].allowTitleMatch == nil {
            let key = tiled.records[index].key
            tiled.records[index].allowTitleMatch = key.title != nil && saved.records.filter {
                $0.key.bundleID == key.bundleID && $0.key.title == key.title
            }.count == 1
        }
        tiled.removeRecords(Set(saved.records.filter { !$0.tiled }.map(\.id)))
        return tiled
    }
    public mutating func removeRecords(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        records.removeAll { ids.contains($0.id) }
        let retained = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.id) })
        layouts = layouts.map { WorkspaceSavedLayout(location: $0.location, layout: $0.layout.remapped(using: retained)) }
            .filter { !$0.layout.ids.isEmpty }
    }
    public func save(to defaults: UserDefaults) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return }
        if defaults.data(forKey: Self.storageKey) != data { defaults.set(data, forKey: Self.storageKey) }
    }
}
