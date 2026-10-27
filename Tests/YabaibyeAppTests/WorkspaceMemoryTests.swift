import XCTest
import AppKit
import YabaibyeCore
@testable import Yabaibye

final class WorkspaceMemoryTests: XCTestCase {
    private let displays = [DisplaySpaces(uuid: "screen", current: 1, spaces: [Desktop(id: 1), Desktop(id: 2)])]
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    @MainActor private func observation(_ id: UInt32, pid: pid_t = 42, title: String = "digest", bundle: String = "test.app", space: UInt64 = 1,
                                        frame: CGRect = CGRect(x: 10, y: 10, width: 500, height: 400)) -> WorkspaceObservation {
        WorkspaceObservation(window: ManagedWindow(id: id, pid: pid, element: AXUIElementCreateApplication(pid), frame: frame),
            key: WorkspaceWindowKey(bundleID: bundle, title: title),
            location: WorkspaceLocation(display: "screen", space: space, normalIndex: Int(space - 1), session: "login"), bounds: bounds)
    }
    private func defaults() -> (String, UserDefaults) {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"; return (name, UserDefaults(suiteName: name)!)
    }
    @MainActor func testRebuiltWindowRestoresSpaceFrameMembershipAndOriginalFloatingFrame() async throws {
        let (name, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let old = observation(1, space: 2); var observations = [old]; var time = 0.0
        let original = CGRect(x: 100, y: 100, width: 600, height: 500)
        let memory = WorkspaceMemory(defaults: defaults, session: "login", snapshot: { _,_,_,_ in WorkspaceSnapshot(observations: observations, complete: true) },
            now: { time }, bounds: { _ in self.bounds }, restore: { _,_,_ in XCTFail("Baseline should not restore"); return true })
        let policy = WindowTilingPolicy(initialWindowIDs: [old.window.identity])
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [old.window.identity: original], layouts: [:])
        time = 1
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [old.window.identity: original], layouts: [:])
        observations = [observation(99, pid: 66)]
        var moves: [(UInt64, CGRect)] = []
        let restarted = WorkspaceMemory(defaults: defaults, session: "login", snapshot: { _,_,_,_ in WorkspaceSnapshot(observations: observations, complete: true) },
            now: { time }, bounds: { _ in self.bounds }, restore: { _, target, frame in moves.append((target.desktop.id, frame)); return true })
        let new = observations[0].window.identity
        let initial = await restarted.reconcile(displays: displays, policy: WindowTilingPolicy(initialWindowIDs: []), originalFrames: [:], layouts: [:])
        XCTAssertEqual(initial.pendingWindows, [new]); time = 2
        let result = await restarted.reconcile(displays: displays, policy: WindowTilingPolicy(initialWindowIDs: []), originalFrames: [:], layouts: [:])
        XCTAssertEqual(moves.count, 1); XCTAssertEqual(moves.first?.0, 2)
        XCTAssertEqual(moves.first?.1, old.window.frame)
        XCTAssertTrue(result.policy.isTiled(new)); XCTAssertEqual(result.originalFrames[new], original)
        XCTAssertTrue(result.pendingWindows.isEmpty)
    }
    @MainActor func testFailedRestoreCannotOverwriteSavedDestinationAndStopsAfterThreeAttempts() async {
        let (name, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let old = observation(1, space: 2)
        var archive = WorkspaceArchive()
        let saved = WorkspaceFrame(frame: old.window.frame, bounds: bounds)!
        archive.records = [WorkspaceRecord(id: "slot", key: old.key, location: old.location, frame: saved, floatingFrame: saved, tiled: true)]
        archive.save(to: defaults)
        let new = observation(99); var time = 0.0; var attempts = 0
        let memory = WorkspaceMemory(defaults: defaults, session: "login", snapshot: { _,_,_,_ in WorkspaceSnapshot(observations: [new], complete: true) },
            now: { time }, bounds: { _ in self.bounds }, restore: { _,_,_ in attempts += 1; return false })
        let policy = WindowTilingPolicy(initialWindowIDs: [])
        for moment in [0.0, 1, 2, 4, 8, 16, 32] {
            time = moment
            let result = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
            XCTAssertEqual(result.pendingWindows, [new.window.identity])
        }
        XCTAssertEqual(attempts, 3)
        memory.captureOnly(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
        XCTAssertEqual(WorkspaceArchive.load(from: defaults).records.first?.location.space, 2)
        memory.retry(); time = 33
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
        XCTAssertEqual(attempts, 4)
    }
    @MainActor func testPartialSnapshotDoesNotInferUniquenessOrSave() async {
        let (name, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let window = observation(1); var time = 0.0
        let memory = WorkspaceMemory(defaults: defaults, session: "login", snapshot: { _,_,_,_ in WorkspaceSnapshot(observations: [window], complete: false) },
            now: { time }, bounds: { _ in self.bounds }, restore: { _,_,_ in XCTFail("Partial snapshot"); return true })
        for moment in [0.0, 1.0] {
            time = moment
            _ = await memory.reconcile(displays: displays, policy: WindowTilingPolicy(initialWindowIDs: []), originalFrames: [:], layouts: [:])
        }
        XCTAssertNil(defaults.data(forKey: WorkspaceArchive.storageKey))
    }
    @MainActor func testClosedTileKeepsDurableBranchAndRestoresWithNewIdentity() async {
        let (name, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let one = observation(1, title: "one"), two = observation(2, title: "two")
        var observations = [one, two]; var time = 0.0
        let memory = WorkspaceMemory(defaults: defaults, session: "login", snapshot: { _,_,_,_ in WorkspaceSnapshot(observations: observations, complete: true) },
            now: { time }, bounds: { _ in self.bounds }, restore: { _,_,_ in true })
        let policy = WindowTilingPolicy(initialWindowIDs: [one.window.identity, two.window.identity])
        var tree = TileLayout(ids: [one.window.identity, two.window.identity]); tree.drop(two.window.identity, onto: one.window.identity, zone: .bottom)
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [1: tree]); time = 1
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [1: tree])
        let before = WorkspaceArchive.load(from: defaults).layouts[0].layout
        observations = [one]; time = 2
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [1: TileLayout(ids: [one.window.identity])])
        XCTAssertEqual(WorkspaceArchive.load(from: defaults).layouts[0].layout, before)
        let reopened = observation(9, title: "two"); observations = [one, reopened]; time = 3
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [1: TileLayout(ids: [one.window.identity])]); time = 4
        let result = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [1: TileLayout(ids: [one.window.identity])])
        XCTAssertEqual(Set(result.restoredLayouts[1]?.ids ?? []), [one.window.identity, reopened.window.identity])
        XCTAssertTrue(result.restoredLayouts[1]?.customized == true)
        XCTAssertEqual(WorkspaceArchive.load(from: defaults).layouts[0].layout, before)
    }
    @MainActor func testClearResetsBindingsAndDefaultPreferenceIsEnabled() async {
        let (name, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: name) }
        var time = 0.0; let one = observation(1)
        let memory = WorkspaceMemory(defaults: defaults, session: "login", snapshot: { _,_,_,_ in WorkspaceSnapshot(observations: [one], complete: true) }, now: { time })
        XCTAssertTrue(memory.enabled)
        let policy = WindowTilingPolicy(initialWindowIDs: [])
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:]); time = 1
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
        XCTAssertEqual(WorkspaceArchive.load(from: defaults).records.count, 1)
        memory.clear()
        let result = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
        XCTAssertEqual(result.pendingWindows, [one.window.identity]); XCTAssertTrue(WorkspaceArchive.load(from: defaults).records.isEmpty)
        memory.enabled = false; XCTAssertFalse(WorkspaceMemory.defaultsEnabled(from: defaults))
    }
    @MainActor func testHiddenIdenticalWindowsAndPartialSnapshotsKeepLiveBindings() async {
        let (name, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let one = observation(1), two = observation(2)
        var observations = [one, two]; var time = 0.0; var complete = true
        let alive: Set<String> = [one.window.identity, two.window.identity]
        var restores = 0
        let memory = WorkspaceMemory(defaults: defaults, session: "login", snapshot: { _,_,_,_ in
            WorkspaceSnapshot(observations: observations, complete: complete, aliveIdentities: alive)
        }, now: { time }, bounds: { _ in self.bounds }, restore: { _,_,_ in restores += 1; return true })
        let policy = WindowTilingPolicy(initialWindowIDs: alive)
        for moment in [0.0, 1] { time = moment; _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:]) }
        XCTAssertEqual(WorkspaceArchive.load(from: defaults).records.count, 2)
        observations = []; time = 2; complete = false
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
        complete = true; time = 3
        _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
        observations = [one, two]; time = 4
        let result = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:])
        XCTAssertTrue(result.pendingWindows.isEmpty)
        XCTAssertEqual(WorkspaceArchive.load(from: defaults).records.count, 2)
        XCTAssertEqual(restores, 0)
    }
    @MainActor func testUnavailableAppDoesNotBlockOtherAppCaptureOrRestore() async {
        let (name, defaults) = defaults(); defer { defaults.removePersistentDomain(forName: name) }
        let reliable = observation(1, bundle: "reliable.app"), failing = observation(2, bundle: "failing.app")
        var observations = [reliable, failing]; var time = 0.0; var restores = 0
        let provider: @MainActor ([DisplaySpaces], String, String, Spaces) -> WorkspaceSnapshot = { _,_,_,_ in
            WorkspaceSnapshot(observations: observations, complete: true, unavailableBundles: ["failing.app"])
        }
        let policy = WindowTilingPolicy(initialWindowIDs: [])
        let memory = WorkspaceMemory(defaults: defaults, session: "login", snapshot: provider, now: { time })
        for moment in [0.0, 1] { time = moment; _ = await memory.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:]) }
        XCTAssertEqual(WorkspaceArchive.load(from: defaults).records.map(\.key.bundleID), ["reliable.app"])
        observations = [observation(99, bundle: "reliable.app"), failing]
        let restarted = WorkspaceMemory(defaults: defaults, session: "login", snapshot: provider, now: { time }, bounds: { _ in self.bounds }, restore: { _,_,_ in restores += 1; return true })
        for moment in [2.0, 3] { time = moment; _ = await restarted.reconcile(displays: displays, policy: policy, originalFrames: [:], layouts: [:]) }
        XCTAssertEqual(restores, 1)
    }
    func testIdentityDigestIsSaltedAndDoesNotContainSensitiveText() {
        let text = "file:///Users/private/document.txt"
        let digest = WorkspaceWindows.digest(text, salt: "one")!
        XCTAssertEqual(digest.count, 64); XCTAssertFalse(digest.contains("private"))
        XCTAssertNotEqual(digest, WorkspaceWindows.digest(text, salt: "two"))
    }
}
