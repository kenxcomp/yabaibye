import XCTest
import CoreGraphics
@testable import YabaibyeCore

final class WorkspaceArchiveTests: XCTestCase {
    private let location = WorkspaceLocation(display: "display", space: 2, normalIndex: 1, session: "login")
    private func record(_ id: String, title: String? = nil, document: String? = nil) -> WorkspaceRecord {
        let frame = WorkspaceFrame(frame: CGRect(x: 10, y: 20, width: 500, height: 400), bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))!
        return WorkspaceRecord(id: id, key: WorkspaceWindowKey(bundleID: "test.app", document: document, title: title),
                               location: location, frame: frame, floatingFrame: frame, tiled: true, allowBundleFallback: true)
    }
    func testUniqueDocumentMatchesRebuiltIDsWithoutDependingOnEnumerationOrder() {
        let saved = [record("one", document: "doc1"), record("two", document: "doc2")]
        let keys = ["99:2": WorkspaceWindowKey(bundleID: "test.app", document: "doc2"),
                    "99:1": WorkspaceWindowKey(bundleID: "test.app", document: "doc1")]
        XCTAssertEqual(WorkspaceMatcher.match(keys, records: saved, bindings: [:]), ["99:2": "two", "99:1": "one"])
    }
    func testIndistinguishableMultipleWindowsAreNeverAssignedByArrayOrder() {
        let saved = [record("one", title: "same"), record("two", title: "same")]
        let keys = ["1": WorkspaceWindowKey(bundleID: "test.app", title: "same"), "2": WorkspaceWindowKey(bundleID: "test.app", title: "same")]
        XCTAssertTrue(WorkspaceMatcher.match(keys, records: saved, bindings: [:]).isEmpty)
        XCTAssertTrue(WorkspaceMatcher.match(["1": keys["1"]!], records: saved, bindings: [:]).isEmpty)
    }
    func testLiveBindingSurvivesTitleChangeAndNewAppIsIsolated() {
        let keys = ["live": WorkspaceWindowKey(bundleID: "test.app", title: "changed"),
                    "foreign": WorkspaceWindowKey(bundleID: "other.app", title: "old")]
        XCTAssertEqual(WorkspaceMatcher.match(keys, records: [record("slot", title: "old")], bindings: ["live": "slot"]), ["live": "slot"])
    }
    func testSingleWindowAppCanReopenWithDynamicTitle() {
        XCTAssertEqual(WorkspaceMatcher.match(["new": WorkspaceWindowKey(bundleID: "test.app", title: "new")],
                                              records: [record("slot", title: "old")], bindings: [:]), ["new": "slot"])
    }
    func testMissingSpaceUsesIndexOnlyAfterLoginAndMissingDisplayNeverFallsBack() {
        let changed = [DisplaySpaces(uuid: "display", current: 10, spaces: [Desktop(id: 10), Desktop(id: 11, type: 4), Desktop(id: 12)])]
        XCTAssertNil(location.resolve(in: changed, session: "login"))
        XCTAssertEqual(location.resolve(in: changed, session: "next-login")?.desktop.id, 12)
        XCTAssertNil(location.resolve(in: [DisplaySpaces(uuid: "other", current: 2, spaces: [Desktop(id: 2)])], session: "next-login"))
    }
    func testNewSessionIgnoresReusedNativeSpaceID() {
        let reused = [DisplaySpaces(uuid: "display", current: 2, spaces: [Desktop(id: 2), Desktop(id: 20)])]
        XCTAssertEqual(location.resolve(in: reused, session: "next-login")?.desktop.id, 20)
    }
    func testRelativeGeometryResizesAndClampsToConnectedDisplay() throws {
        let bounds = CGRect(x: 200, y: 100, width: 500, height: 400)
        let frame = try XCTUnwrap(record("one").frame.frame(in: bounds))
        XCTAssertEqual(frame, CGRect(x: 205, y: 110, width: 250, height: 200))
        var invalid = record("one").frame; invalid.x = .infinity
        XCTAssertNil(invalid.frame(in: bounds))
    }
    func testCustomTreeRemapsSlotsAndCollapsesMissingBranches() {
        var tree = TileLayout(ids: ["one", "two", "three"])
        tree.drop("three", onto: "one", zone: .bottom)
        let mapped = tree.remapped(using: ["one": "new1", "two": "new2", "three": "new3"])
        XCTAssertTrue(mapped.customized)
        let a = tree.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let b = mapped.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(a["three"], b["new3"])
        XCTAssertEqual(Set(mapped.remapped(using: ["new1": "one"]).ids), ["one"])
    }
    func testArchiveSurvivesNewStoreAndDoesNotStoreCleartextTitles() throws {
        let name = "Yabaibye.Tests.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var archive = WorkspaceArchive(); archive.records = [record("one", title: "digest")]
        archive.save(to: defaults)
        let firstData = defaults.data(forKey: WorkspaceArchive.storageKey)
        archive.save(to: defaults)
        XCTAssertEqual(defaults.data(forKey: WorkspaceArchive.storageKey), firstData)
        let saved = WorkspaceArchive.load(from: UserDefaults(suiteName: name)!)
        XCTAssertEqual(saved.records, archive.records)
        XCTAssertEqual(saved.salt, archive.salt)
        defaults.set(Data("broken".utf8), forKey: WorkspaceArchive.storageKey)
        XCTAssertTrue(WorkspaceArchive.load(from: defaults).records.isEmpty)
    }
    func testTiledSlotInMultiwindowAppCannotClaimFloatingWindowByBundle() {
        var tiled = record("tiled", title: "tiled-title")
        tiled.allowBundleFallback = false
        XCTAssertTrue(WorkspaceMatcher.match(["float": WorkspaceWindowKey(bundleID: "test.app", title: "float-title")], records: [tiled], bindings: [:]).isEmpty)
        tiled.allowBundleFallback = true
        tiled.key.document = "tiled-document"
        XCTAssertTrue(WorkspaceMatcher.match(["float": WorkspaceWindowKey(bundleID: "test.app", document: "other-document", title: "tiled-title")], records: [tiled], bindings: [:]).isEmpty)
    }

    func testSharedIdentifierDoesNotBecomeUniqueWhenFloatingSlotIsRemoved() {
        var tiled = record("tiled", title: "tiled-title")
        tiled.key.identifier = "generic"
        tiled.allowBundleFallback = false
        tiled.allowIdentifierMatch = false
        XCTAssertTrue(WorkspaceMatcher.match(["float": WorkspaceWindowKey(bundleID: "test.app", identifier: "generic", title: "other-title")], records: [tiled], bindings: [:]).isEmpty)
        tiled.allowIdentifierMatch = true
        XCTAssertEqual(WorkspaceMatcher.match(["new": WorkspaceWindowKey(bundleID: "test.app", identifier: "generic", title: "changed")], records: [tiled], bindings: [:]), ["new": "tiled"])
    }

    func testExplicitFloatStillCompetesWithOtherWindowForIdenticalTitle() {
        let keys = ["float": WorkspaceWindowKey(bundleID: "test.app", title: "same"),
                    "other": WorkspaceWindowKey(bundleID: "test.app", title: "same")]
        XCTAssertTrue(WorkspaceMatcher.match(keys, records: [record("slot", title: "same")], bindings: [:], excluding: ["float"]).isEmpty)
        var shared = record("slot", title: "same")
        shared.allowTitleMatch = false; shared.allowBundleFallback = false
        XCTAssertTrue(WorkspaceMatcher.match(["float": keys["float"]!], records: [shared], bindings: [:]).isEmpty)
    }

}
