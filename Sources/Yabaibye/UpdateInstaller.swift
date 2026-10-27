import AppKit
import CryptoKit
import Security
import YabaibyeCore

struct UpdateInstallPlan: Codable {
    let destination: String
    let version: String
    let build: Int
    let parentPID: Int32
}

enum UpdateInstaller {
    static let bundleID = "com.kenxcomp.yabaibye"
    static func validDestination(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        let parents = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return normalized.lastPathComponent == "Yabaibye.app" &&
            parents.contains(normalized.deletingLastPathComponent()) &&
            normalized.resolvingSymlinksInPath() == normalized
    }
    static func currentTeam() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw AppFailure("无法读取当前签名。") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw AppFailure("无法读取当前签名。") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw AppFailure("当前为开发或临时签名版本；请先手动安装已公证的正式版本。")
        }
        return team
    }
    static func verify(_ app: URL, team: String, version: UpdateVersion? = nil) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess,
              let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "YBReleaseBuild") as? Bool == true else {
            throw AppFailure("更新包签名、开发者身份或应用标识验证失败。")
        }
        if let version {
            guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version.version,
                  bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == String(version.build) else {
                throw AppFailure("更新包版本与发布信息不一致。")
            }
        }
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: 90)
    }
    static func prepare(archive: URL, root: URL, digest: String, plan: UpdateInstallPlan, team: String) throws -> URL {
        let destination = URL(fileURLWithPath: plan.destination)
        guard validDestination(destination), FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: destination.path) else {
            throw AppFailure("请先将 Yabaibye 安装到可写的 Applications 文件夹；此位置需要手动更新。")
        }
        try verify(destination, team: team)
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest,
              UpdateArchive.isSafe(data) else { throw AppFailure("更新包校验失败或压缩包结构不安全。") }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, root.path], timeout: 90)
        let candidate = root.appendingPathComponent("Yabaibye.app")
        guard let version = UpdateVersion(version: plan.version, build: plan.build) else { throw AppFailure("更新版本无效。") }
        try verify(candidate, team: team, version: version)
        try JSONEncoder().encode(plan).write(to: root.appendingPathComponent("install.json"), options: .atomic)
        let helper = root.appendingPathComponent("YabaibyeUpdater")
        guard let executable = Bundle.main.executableURL else { throw AppFailure("无法定位更新助手。") }
        try FileManager.default.copyItem(at: executable, to: helper)
        return helper
    }
    static func launchHelper(_ helper: URL) throws {
        let process = Process(); process.executableURL = helper; process.arguments = ["--install-update"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    /// Call first in applicationDidFinishLaunching, before diagnostics and single-instance rejection.
    @MainActor static func handleCommandLine() -> Bool {
        guard CommandLine.arguments.contains("--install-update") else { return false }
        Task.detached {
            let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
            do { try performHelper(in: root); exit(0) }
            catch {
                // Save a small local result for the old app to present on its next launch.
                UserDefaults(suiteName: bundleID)?.set("自动更新未完成，已保留原版本。\(error.localizedDescription)", forKey: "updater.installError")
                if let data = try? Data(contentsOf: root.appendingPathComponent("install.json")),
                   let plan = try? JSONDecoder().decode(UpdateInstallPlan.self, from: data),
                   kill(plan.parentPID, 0) != 0 {
                    let old = URL(fileURLWithPath: plan.destination)
                    if validDestination(old), let team = try? currentTeam(), (try? verify(old, team: team)) != nil {
                        try? run("/usr/bin/open", ["-n", old.path], timeout: 20)
                    }
                }
                exit(1)
            }
        }
        return true
    }
    static func performHelper(in root: URL) throws {
        let files = FileManager.default
        let attributes = try files.attributesOfItem(atPath: root.path)
        guard root.lastPathComponent.hasPrefix("yabaibye-update-"), root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath(),
              attributes[.ownerAccountID] as? UInt32 == getuid(),
              (attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0 else { throw AppFailure("更新助手目录不安全。") }
        let plan = try JSONDecoder().decode(UpdateInstallPlan.self, from: Data(contentsOf: root.appendingPathComponent("install.json")))
        let destination = URL(fileURLWithPath: plan.destination)
        guard validDestination(destination), plan.parentPID > 1, plan.parentPID != getpid(),
              let version = UpdateVersion(version: plan.version, build: plan.build) else { throw AppFailure("更新安装目标无效。") }
        let team = try currentTeam()
        let candidate = root.appendingPathComponent("Yabaibye.app")
        try verify(candidate, team: team, version: version)
        try verify(destination, team: team)
        guard let installed = Bundle(url: destination),
              let oldVersion = installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let oldBuild = installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let oldNumber = Int(oldBuild), let old = UpdateVersion(version: oldVersion, build: oldNumber), version > old else {
            throw AppFailure("更新版本必须高于当前已安装版本。")
        }
        // The app must quit normally (and save its preferences) before replacement.
        let deadline = Date().addingTimeInterval(30)
        while kill(plan.parentPID, 0) == 0 {
            guard Date() < deadline else { throw AppFailure("原应用仍在运行，请退出后重试更新。") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).allSatisfy({ $0.processIdentifier == getpid() }) else {
            throw AppFailure("另一实例正在运行，请退出后重试更新。")
        }
        do {
            try replace(destination: destination, candidate: candidate,
                        verify: { try verify($0, team: team, version: version) },
                        launch: { try run("/usr/bin/open", ["-n", $0.path], timeout: 20) },
                        failed: { recordFailure($0) })
            try? files.removeItem(at: root)
        } catch { throw error }
    }
    private static func recordFailure(_ error: Error) {
        UserDefaults(suiteName: bundleID)?.set("自动更新未完成，已保留原版本。\(error.localizedDescription)", forKey: "updater.installError")
    }
    /// Stage on the destination volume, then use renames so a failed install can restore the old bundle.
    static func replace(destination: URL, candidate: URL, verify: (URL) throws -> Void,
                        launch: (URL) throws -> Void, failed: (Error) -> Void = { _ in }) throws {
        let files = FileManager.default
        let transaction = destination.deletingLastPathComponent().appendingPathComponent(".yabaibye-update-\(UUID().uuidString)")
        try files.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = transaction.appendingPathComponent("new.app"), backup = transaction.appendingPathComponent("previous.app")
        var movedOld = false, movedNew = false, completed = false
        defer { if completed || !movedOld { try? files.removeItem(at: transaction) } }
        do {
            try files.copyItem(at: candidate, to: staged)
            try verify(staged)
            try files.moveItem(at: destination, to: backup); movedOld = true
            try files.moveItem(at: staged, to: destination); movedNew = true
            try launch(destination)
            completed = true
        } catch {
            if movedNew { try files.removeItem(at: destination) }
            if movedOld { try files.moveItem(at: backup, to: destination); movedOld = false }
            failed(error)
            try? launch(destination)
            throw error
        }
    }
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate(); Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw AppFailure("更新校验或安装步骤超时，请重试。")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else { throw AppFailure("更新校验或安装失败（\(URL(fileURLWithPath: executable).lastPathComponent)）。") }
    }
}
