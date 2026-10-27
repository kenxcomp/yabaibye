import AppKit
import OSLog
import YabaibyeCore

struct WorkspaceResult {
    var policy: WindowTilingPolicy
    var originalFrames: [String: CGRect]
    var restoredLayouts: [UInt64: TileLayout] = [:]
    var pendingWindows: Set<String> = []
    var notice: String?
}

/// One owner serializes restore and capture. WindowServer IDs never enter the durable archive.
@MainActor final class WorkspaceMemory {
    static let enabledKey = "workspace.memory.enabled"
    static func defaultsEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
    var enabled: Bool {
        get { Self.defaultsEnabled(from: defaults) }
        set { defaults.set(newValue, forKey: Self.enabledKey); retry() }
    }
    private let defaults: UserDefaults
    private var archive: WorkspaceArchive
    private let session: String
    private let spaces: Spaces
    private var bindings: [String: String] = [:]
    private var restored = Set<String>()
    private var firstSeen: [String: (WorkspaceWindowKey, TimeInterval)] = [:]
    private var failures: [String: (attempts: Int, next: TimeInterval)] = [:]
    private var missingTargets = Set<String>()
    private let logger = Logger(subsystem: "com.kenxcomp.yabaibye", category: "workspace")
    private let snapshot: @MainActor ([DisplaySpaces], String, String, Spaces) -> WorkspaceSnapshot
    private let now: () -> TimeInterval
    private let restore: (ManagedWindow, SpaceTarget, CGRect) async throws -> Bool
    private let bounds: (SpaceTarget) -> CGRect?

    init(defaults: UserDefaults = .standard, session: String? = nil, spaces: Spaces? = nil,
         snapshot: @escaping @MainActor ([DisplaySpaces], String, String, Spaces) -> WorkspaceSnapshot = WorkspaceWindows.snapshot,
         now: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
         bounds: ((SpaceTarget) -> CGRect?)? = nil,
         restore: ((ManagedWindow, SpaceTarget, CGRect) async throws -> Bool)? = nil) {
        let spaces = spaces ?? Spaces()
        self.defaults = defaults; archive = WorkspaceArchive.load(from: defaults)
        self.session = session ?? WorkspaceWindows.loginSession(); self.spaces = spaces
        self.snapshot = snapshot; self.now = now
        self.bounds = bounds ?? { spaces.screen(for: $0.display)?.axVisibleFrame }
        self.restore = restore ?? { window, target, frame in
            try Task.checkCancellation()
            try await spaces.move(window, to: target)
            try Task.checkCancellation()
            return try await AX.applyFrames([(window.element, frame)])
        }
    }
    func clear() {
        archive = WorkspaceArchive(); archive.save(to: defaults)
        bindings.removeAll(); restored.removeAll(); firstSeen.removeAll(); failures.removeAll(); missingTargets.removeAll()
    }
    func retry() { failures.removeAll(); missingTargets.removeAll() }

    func reconcile(displays: [DisplaySpaces], policy: WindowTilingPolicy,
                   originalFrames: [String: CGRect], layouts: [UInt64: TileLayout], excluded: Set<String> = []) async -> WorkspaceResult {
        var result = WorkspaceResult(policy: policy, originalFrames: originalFrames)
        guard enabled, !Task.isCancelled else { return result }
        let captured = snapshot(displays, session, archive.salt, spaces)
        let eligible = captured.observations.filter { !excluded.contains($0.window.identity) }
        let observations = eligible.filter { !captured.unavailableBundles.contains($0.key.bundleID) }
        let keys = Dictionary(uniqueKeysWithValues: observations.map { ($0.window.identity, $0.key) })
        let identities = Set(keys.keys)
        result.pendingWindows = Set(eligible.map { $0.window.identity }).subtracting(restored)
        // A partial AX snapshot cannot prove absence, uniqueness, or replace durable geometry.
        guard captured.complete else { return result }
        let alive = captured.aliveIdentities ?? identities
        bindings = bindings.filter { alive.contains($0.key) }
        restored.formIntersection(alive)
        firstSeen = firstSeen.filter { alive.contains($0.key) }
        failures = failures.filter { alive.contains($0.key) }
        missingTargets.formIntersection(alive)
        // Hidden/minimized windows still own their slots even though they cannot be restored now.
        let invisible = bindings.filter { keys[$0.key] == nil }
        let occupied = Set(invisible.values)
        let matched = WorkspaceMatcher.match(keys, records: archive.records.filter { !occupied.contains($0.id) }, bindings: bindings)
        bindings = matched.merging(invisible) { visible, _ in visible }
        restored = restored.filter { bindings[$0] != nil }
        var justRestored = Set<String>()
        for observation in observations {
            let identity = observation.window.identity
            guard !restored.contains(identity) else { continue }
            let time = now()
            guard let seen = firstSeen[identity], seen.0 == observation.key, time - seen.1 >= 0.5 else {
                firstSeen[identity] = (observation.key, time); continue
            }
            if let failure = failures[identity], failure.attempts >= 3 || failure.next > time { continue }
            if let recordID = bindings[identity], let record = archive.records.first(where: { $0.id == recordID }) {
                guard let target = record.location.resolve(in: displays, session: session),
                      let targetBounds = bounds(target), let frame = record.frame.frame(in: targetBounds) else {
                    if missingTargets.insert(identity).inserted { result.notice = "部分窗口的原显示器或 Space 不可用；保留记忆，连接显示器后重试恢复。" }
                    continue
                }
                do {
                    try Task.checkCancellation()
                    guard try await restore(observation.window, target, frame) else { throw AppFailure("应用未接受已保存的窗口位置") }
                    try Task.checkCancellation()
                    result.policy.setTiled(record.tiled, for: identity)
                    if let floating = record.floatingFrame.frame(in: targetBounds) { result.originalFrames[identity] = floating }
                    restored.insert(identity); justRestored.insert(identity); failures.removeValue(forKey: identity)
                } catch is CancellationError { return result }
                catch {
                    let attempts = (failures[identity]?.attempts ?? 0) + 1
                    failures[identity] = (attempts, time + pow(2, Double(attempts)))
                    if attempts == 1 { result.notice = "部分窗口布局暂时无法恢复；将有限重试，可从菜单重新尝试。" }
                    if attempts == 3 { result.notice = "部分窗口布局恢复已停止重试；可从菜单选择‘重试恢复窗口布局’。" }
                    logger.error("窗口布局恢复失败；attempt=\(attempts), bundle=\(observation.key.bundleID, privacy: .public)")
                }
            } else {
                // Unknown or ambiguous windows retain their current state. Do not guess an old slot.
                if let record = makeRecord(observation, policy: result.policy, originalFrames: result.originalFrames) {
                    archive.records.append(record); bindings[identity] = record.id; restored.insert(identity)
                }
            }
        }
        result.pendingWindows = Set(eligible.map { $0.window.identity }).subtracting(restored)
        let liveBySlot = Dictionary(uniqueKeysWithValues: bindings.filter { restored.contains($0.key) }.map { ($0.value, $0.key) })
        for saved in archive.layouts {
            guard let target = saved.location.resolve(in: displays, session: session),
                  saved.layout.ids.contains(where: { id in justRestored.contains(liveBySlot[id] ?? "") }) else { continue }
            let layout = saved.layout.remapped(using: liveBySlot)
            if !layout.ids.isEmpty { result.restoredLayouts[target.desktop.id] = layout }
        }
        // A restored frame was read before the write. Wait for a fresh snapshot before recording it.
        for observation in observations where restored.contains(observation.window.identity) && !justRestored.contains(observation.window.identity) {
            guard let id = bindings[observation.window.identity], let index = archive.records.firstIndex(where: { $0.id == id }),
                  var record = makeRecord(observation, policy: result.policy, originalFrames: result.originalFrames) else { continue }
            record.id = id
            // Avoid a UserDefaults write every poll when the logical geometry has not changed.
            record.updated = archive.records[index].updated
            if record != archive.records[index] { record.updated = Date(); archive.records[index] = record }
        }
        captureLayouts(layouts.filter { result.restoredLayouts[$0.key] == nil }, displays: displays, liveBySlot: liveBySlot, pending: result.pendingWindows)
        archive.displays = displays
        prune()
        archive.save(to: defaults)
        return result
    }
    /// Final synchronous capture on pause/quit; pending or failed restores never overwrite their slots.
    func captureOnly(displays: [DisplaySpaces], policy: WindowTilingPolicy,
                     originalFrames: [String: CGRect], layouts: [UInt64: TileLayout], excluded: Set<String> = []) {
        guard enabled else { return }
        let captured = snapshot(displays, session, archive.salt, spaces)
        guard captured.complete else { return }
        for observation in captured.observations where restored.contains(observation.window.identity) && !excluded.contains(observation.window.identity) && !captured.unavailableBundles.contains(observation.key.bundleID) {
            guard let id = bindings[observation.window.identity], let index = archive.records.firstIndex(where: { $0.id == id }),
                  var record = makeRecord(observation, policy: policy, originalFrames: originalFrames) else { continue }
            record.id = id; archive.records[index] = record
        }
        let liveBySlot = Dictionary(uniqueKeysWithValues: bindings.filter { restored.contains($0.key) && !excluded.contains($0.key) }.map { ($0.value, $0.key) })
        captureLayouts(layouts, displays: displays, liveBySlot: liveBySlot, pending: [])
        archive.displays = displays; prune(); archive.save(to: defaults)
    }
    private func makeRecord(_ observation: WorkspaceObservation, policy: WindowTilingPolicy,
                            originalFrames: [String: CGRect]) -> WorkspaceRecord? {
        guard let frame = WorkspaceFrame(frame: observation.window.frame, bounds: observation.bounds),
              let floating = WorkspaceFrame(frame: (policy.isTiled(observation.window.identity) ? originalFrames[observation.window.identity] : nil) ?? observation.window.frame, bounds: observation.bounds) else { return nil }
        return WorkspaceRecord(key: observation.key, location: observation.location, frame: frame,
                               floatingFrame: floating, tiled: policy.isTiled(observation.window.identity))
    }
    private func captureLayouts(_ layouts: [UInt64: TileLayout], displays: [DisplaySpaces],
                                liveBySlot: [String: String], pending: Set<String>) {
        let slotsByLive = Dictionary(uniqueKeysWithValues: liveBySlot.map { ($0.value, $0.key) })
        for (space, layout) in layouts where !layout.ids.isEmpty && !layout.ids.contains(where: { pending.contains($0) }) {
            guard layout.ids.allSatisfy({ slotsByLive[$0] != nil }),
                  let display = displays.first(where: { $0.spaces.contains(where: { $0.id == space && $0.type == 0 }) }),
                  let index = display.spaces.filter({ $0.type == 0 }).firstIndex(where: { $0.id == space }) else { continue }
            let mapped = layout.remapped(using: slotsByLive)
            let location = WorkspaceLocation(display: display.uuid, space: space, normalIndex: index, session: session)
            if let savedIndex = archive.layouts.firstIndex(where: { $0.location.resolve(in: displays, session: session)?.desktop.id == space }) {
                let saved = archive.layouts[savedIndex]
                // Preserve inactive slots. Closing a window must not erase its branch in the durable tree.
                let missing = saved.layout.ids.filter { id in
                    guard !mapped.ids.contains(id), let record = archive.records.first(where: { $0.id == id }) else { return false }
                    return record.tiled && record.location.resolve(in: displays, session: session)?.desktop.id == space
                }
                guard missing.isEmpty else { continue }
                archive.layouts[savedIndex] = WorkspaceSavedLayout(location: location, layout: mapped)
            } else { archive.layouts.append(WorkspaceSavedLayout(location: location, layout: mapped)) }
        }
    }
    private func prune() {
        guard archive.records.count > 1024 else { return }
        let active = Set(bindings.values)
        let removed = Set(archive.records.filter { !active.contains($0.id) }.sorted { $0.updated < $1.updated }
            .prefix(archive.records.count - 1024).map(\.id))
        archive.records.removeAll { removed.contains($0.id) }
        let retained = Dictionary(uniqueKeysWithValues: archive.records.map { ($0.id, $0.id) })
        archive.layouts = archive.layouts.map { WorkspaceSavedLayout(location: $0.location, layout: $0.layout.remapped(using: retained)) }.filter { !$0.layout.ids.isEmpty }
    }
}
