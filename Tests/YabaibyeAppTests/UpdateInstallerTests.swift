import XCTest
import AppKit
@testable import Yabaibye

final class UpdateInstallerTests: XCTestCase {
    func testDestinationRejectsArbitraryAppsAndTraversal() {
        XCTAssertTrue(UpdateInstaller.validDestination(URL(fileURLWithPath: "/Applications/Yabaibye.app")))
        for path in ["/Applications/Other.app", "/tmp/Yabaibye.app", "/Applications/Yabaibye.app/Contents", "/Applications/subfolder/Yabaibye.app"] {
            XCTAssertFalse(UpdateInstaller.validDestination(URL(fileURLWithPath: path)))
        }
    }
    func testReplacementRestoresOldBundleWhenLaunchFails() throws {
        try transaction { old, new in
            var attempts: [String] = []
            var savedFailure = false
            XCTAssertThrowsError(try UpdateInstaller.replace(destination: old, candidate: new, verify: { _ in }, launch: { url in
                let marker = try String(contentsOf: url.appendingPathComponent("marker")); attempts.append(marker)
                if marker == "new" { throw AppFailure("launch failed") }
                XCTAssertTrue(savedFailure, "Save the failure before restarting the old app")
            }, failed: { _ in savedFailure = true }))
            XCTAssertEqual(attempts, ["new", "old"])
            XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("marker")), "old")
        }
    }
    func testVerificationFailureDoesNotTouchInstalledApp() throws {
        try transaction { old, new in
            XCTAssertThrowsError(try UpdateInstaller.replace(destination: old, candidate: new, verify: { _ in throw AppFailure("bad signature") }, launch: { url in XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("marker")), "old") }))
            XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("marker")), "old")
        }
    }
    func testSuccessfulReplacementLaunchesNewBundleAndCleansBackup() throws {
        try transaction { old, new in
            var launched = false
            try UpdateInstaller.replace(destination: old, candidate: new, verify: { _ in }, launch: { url in
                XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("marker")), "new"); launched = true
            })
            XCTAssertTrue(launched)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old.deletingLastPathComponent().path).sorted(), ["candidate.app", "installed.app"])
        }
    }
    func testNetworkRejectsHTTPAndUntrustedRedirectHosts() {
        for value in ["http://github.com/file", "https://evil.example/file", "https://github.com.evil.example/file", "https://user@github.com/file"] {
            XCTAssertFalse(UpdateNetwork.allows(URL(string: value)!))
        }
        XCTAssertTrue(UpdateNetwork.allows(URL(string: "https://release-assets.githubusercontent.com/file")!))
    }
    private func transaction(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("installed.app"), new = root.appendingPathComponent("candidate.app")
        for (url, marker) in [(old, "old"), (new, "new")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try marker.write(to: url.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        try body(old, new)
    }
}
