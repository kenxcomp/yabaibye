import Foundation

public struct UpdateVersion: Equatable, Comparable {
    public let version: String
    public let build: Int
    private let components: [Int]
    public init?(version: String, build: Int) {
        let values = version.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3, build > 0, build < 999999999,
              values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && ($0 == "0" || !$0.hasPrefix("0")) }),
              values.allSatisfy({ Int($0) != nil }) else { return nil }
        self.version = version; self.build = build; components = values.map { Int($0)! }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        return lhs.build < rhs.build
    }
}

public struct UpdateRelease: Decodable {
    public struct Asset: Decodable {
        public let name: String
        public let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }
    public let tagName: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case draft, prerelease, assets }
    public func asset(_ name: String) -> URL? {
        let matches = assets.filter { $0.name == name }
        guard !draft, !prerelease, matches.count == 1,
              let url = matches.first?.browserDownloadURL,
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/kenxcomp/yabaibye/releases/download/\(tagName)/\(name)",
              !name.contains("/"), !name.contains("\\"), !name.contains("..") else { return nil }
        return url
    }
}

public struct UpdateManifest: Decodable {
    public let version: String
    public let build: Int
    public let configuration: String
    public let architectures: [String]
    public let signing: String
    public let notarized: Bool
    public let minimumMacOS: String
    public let artifacts: [String]
    public func archive(release: UpdateRelease, current: UpdateVersion, architecture: String,
                        os: OperatingSystemVersion) -> (version: UpdateVersion, name: String, url: URL)? {
        guard let candidate = UpdateVersion(version: version, build: build), candidate > current,
              configuration == "release", signing == "certificate", notarized,
              architectures.contains(architecture), release.tagName == "v\(version)+\(build)" else { return nil }
        let minimum = minimumMacOS.split(separator: ".").compactMap { Int($0) }
        guard !minimum.isEmpty, minimum.count <= 3, minimum.allSatisfy({ $0 >= 0 }),
              minimum.count == minimumMacOS.split(separator: ".", omittingEmptySubsequences: false).count else { return nil }
        let requested = minimum + Array(repeating: 0, count: 3 - minimum.count)
        let installed = [os.majorVersion, os.minorVersion, os.patchVersion]
        guard !installed.lexicographicallyPrecedes(requested) else { return nil }
        let names = artifacts.filter { $0.hasSuffix(".zip") }
        guard names.count == 1, let name = names.first, let url = release.asset(name) else { return nil }
        return (candidate, name, url)
    }
    public static func checksum(for name: String, in sums: String) -> String? {
        let entries = sums.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))
        }.filter { $0.1 == name }
        guard entries.count == 1, let digest = entries.first?.0, digest.count == 64,
              digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return digest.lowercased()
    }
}
