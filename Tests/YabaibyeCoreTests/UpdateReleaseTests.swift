import XCTest
@testable import YabaibyeCore

final class UpdateReleaseTests: XCTestCase {
    func testVersionOrderingAndMalformedVersions() {
        XCTAssertGreaterThan(UpdateVersion(version: "1.10.0", build: 2)!, UpdateVersion(version: "1.9.9", build: 50)!)
        XCTAssertGreaterThan(UpdateVersion(version: "1.0.0", build: 3)!, UpdateVersion(version: "1.0.0", build: 2)!)
        for version in ["1.0", "01.0.0", "1.0.-1", "1.0.0-beta", "１.0.0", "1..0"] {
            XCTAssertNil(UpdateVersion(version: version, build: 2))
        }
    }
    func testChecksumRejectsDuplicatesAndInvalidDigests() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdateManifest.checksum(for: "app.zip", in: "\(digest)  app.zip\n"), digest)
        XCTAssertNil(UpdateManifest.checksum(for: "app.zip", in: "\(digest)  app.zip\n\(digest)  app.zip"))
        XCTAssertNil(UpdateManifest.checksum(for: "app.zip", in: "bad  app.zip"))
    }
    func testReleaseOnlyAcceptsExactRepositoryAssetURLs() throws {
        for url in ["http://github.com/kenxcomp/yabaibye/releases/download/v1.0.1+2/app.zip",
                    "https://github.com/other/repo/releases/download/v1.0.1+2/app.zip",
                    "https://github.com@evil.example/kenxcomp/yabaibye/releases/download/v1.0.1+2/app.zip",
                    "https://github.com/kenxcomp/yabaibye/releases/download/v1.0.1+2/app.zip?raw=1"] {
            XCTAssertNil(try release(url: url).asset("app.zip"))
        }
        XCTAssertNotNil(try release().asset("app.zip"))
    }
    func testCandidateRequiresNotarizationArchitectureAndMatchingTag() throws {
        let current = UpdateVersion(version: "1.0.0", build: 1)!
        let os = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let good: [String: Any] = ["version": "1.0.1", "build": 2, "configuration": "release", "architectures": ["arm64"],
                                   "signing": "certificate", "notarized": true, "minimumMacOS": "14.0", "artifacts": ["app.zip"]]
        func candidate(_ data: [String: Any]) throws -> URL? {
            try JSONDecoder().decode(UpdateManifest.self, from: JSONSerialization.data(withJSONObject: data))
                .archive(release: release(), current: current, architecture: "arm64", os: os)?.url
        }
        XCTAssertNotNil(try candidate(good))
        for (key, value) in [("notarized", false as Any), ("signing", "ad-hoc"), ("architectures", ["x86_64"]),
                             ("minimumMacOS", "15.0"), ("version", "1.0.2")] {
            var changed = good; changed[key] = value
            XCTAssertNil(try candidate(changed))
        }
    }
    private func release(url: String = "https://github.com/kenxcomp/yabaibye/releases/download/v1.0.1+2/app.zip") throws -> UpdateRelease {
        let object: [String: Any] = ["tag_name": "v1.0.1+2", "draft": false, "prerelease": false,
                                   "assets": [["name": "app.zip", "browser_download_url": url]]]
        return try JSONDecoder().decode(UpdateRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testArchiveRejectsTraversalSymlinksLocalMismatchAndZipBombs() {
        XCTAssertTrue(UpdateArchive.isSafe(zip()))
        XCTAssertFalse(UpdateArchive.isSafe(zip(extra: "Yabaibye.app/../../escape")))
        XCTAssertFalse(UpdateArchive.isSafe(zip(extra: "Yabaibye.app/link", mode: 0xa000)))
        XCTAssertFalse(UpdateArchive.isSafe(zip(expanded: 600 * 1024 * 1024)))
        var mismatched = zip(); mismatched[30] = Character("X").asciiValue!
        XCTAssertFalse(UpdateArchive.isSafe(mismatched))
    }
    func testPackagerDittoArchiveIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Yabaibye.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Yabaibye"))
        let archive = root.appendingPathComponent("release.zip")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(UpdateArchive.isSafe(try Data(contentsOf: archive)))
    }
    func testRejectsFileTypeAndUnknownExtrasInEitherHeader() {
        // ASi Unix mode=S_IFLNK and a traversal link target, with regular-file
        // central attributes. The extraction tool must never see this metadata.
        let asiUnix = Data([0x6e, 0x75, 0x1b, 0x00, 0xbf, 0xe9, 0x89, 0x85, 0xff, 0xa1, 0x0d, 0x00, 0x00, 0x00, 0xf5, 0x01, 0x14, 0x00, 0x2e, 0x2e, 0x2f, 0x2e, 0x2e, 0x2f, 0x6f, 0x75, 0x74, 0x73, 0x69, 0x64, 0x65])
        for extensionData in [asiUnix, Data([0x0d, 0x00, 0x00, 0x00]), Data([0xff, 0xff, 0x00, 0x00]), Data([0x55, 0x58, 0xff, 0xff])] {
            XCTAssertFalse(UpdateArchive.isSafe(zip(localExtraData: extensionData)))
            XCTAssertFalse(UpdateArchive.isSafe(zip(centralExtraData: extensionData)))
        }
        let localTimestamps = Data([0x55, 0x58, 0x0c, 0x00] + Array(repeating: UInt8(0), count: 12))
        let centralTimestamps = Data([0x55, 0x58, 0x08, 0x00] + Array(repeating: UInt8(0), count: 8))
        XCTAssertTrue(UpdateArchive.isSafe(zip(localExtraData: localTimestamps, centralExtraData: centralTimestamps)))
    }
    private func zip(extra: String? = nil, mode: UInt32 = 0x8000, expanded: UInt32 = 1,
                     localExtraData: Data = Data(), centralExtraData: Data = Data()) -> Data {
        var local = Data(), directory = Data()
        func append(_ value: UInt32, bytes: Int, to data: inout Data) {
            for index in 0..<bytes { data.append(UInt8((value >> (index * 8)) & 255)) }
        }
        let names = ["Yabaibye.app/Contents/Info.plist", "Yabaibye.app/Contents/MacOS/Yabaibye"] + (extra.map { [$0] } ?? [])
        for name in names {
            let offset = local.count, bytes = Data(name.utf8)
            append(0x04034b50, bytes: 4, to: &local)
            local.append(Data(repeating: 0, count: 22)); append(UInt32(bytes.count), bytes: 2, to: &local)
            append(UInt32(localExtraData.count), bytes: 2, to: &local); local.append(bytes); local.append(localExtraData)
            append(0x02014b50, bytes: 4, to: &directory)
            directory.append(Data(repeating: 0, count: 20)); append(expanded, bytes: 4, to: &directory)
            append(UInt32(bytes.count), bytes: 2, to: &directory)
            append(UInt32(centralExtraData.count), bytes: 2, to: &directory)
            directory.append(Data(repeating: 0, count: 6)); append(mode << 16, bytes: 4, to: &directory)
            append(UInt32(offset), bytes: 4, to: &directory); directory.append(bytes); directory.append(centralExtraData)
        }
        var result = local; result.append(directory)
        append(0x06054b50, bytes: 4, to: &result); result.append(Data(repeating: 0, count: 4))
        append(UInt32(names.count), bytes: 2, to: &result); append(UInt32(names.count), bytes: 2, to: &result)
        append(UInt32(directory.count), bytes: 4, to: &result); append(UInt32(local.count), bytes: 4, to: &result)
        append(0, bytes: 2, to: &result); return result
    }
}
