import AppKit
import OSLog
import YabaibyeCore

@MainActor final class UpdateController: NSObject {
    private let logger = Logger(subsystem: "com.kenxcomp.yabaibye", category: "updater")
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var progress: NSPanel?
    private var progressLabel: NSTextField?
    private var workingDirectory: URL?
    private var handedOff = false
    var canInstall: () -> Bool = { true }
    var changed: (() -> Void)?
    private(set) var isBusy = false
    private(set) var lastResult = UserDefaults.standard.string(forKey: "updater.lastResult") ?? "尚未检查更新"
    private func record(_ message: String) {
        lastResult = message; UserDefaults.standard.set(message, forKey: "updater.lastResult"); changed?()
    }
    var automaticallyChecks: Bool {
        get { UserDefaults.standard.object(forKey: "updater.automatic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updater.automatic"); changed?() }
    }
    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.checkIfDue()
        }
        if let message = UserDefaults.standard.string(forKey: "updater.installError") {
            UserDefaults.standard.removeObject(forKey: "updater.installError")
            Task { [weak self] in self?.showMessage("更新未完成", message) }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if !handedOff { task?.cancel() }
        progress?.orderOut(nil)
    }
    private func checkIfDue() {
        let last = UserDefaults.standard.double(forKey: "updater.lastCheck")
        guard automaticallyChecks, Date().timeIntervalSince1970 - last >= 24 * 3600 else { return }
        check(manual: false)
    }
    func check(manual: Bool = true) {
        guard !isBusy else { return }
        isBusy = true; changed?()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.progress?.orderOut(nil); self.progress = nil; self.progressLabel = nil
                if !self.handedOff, let root = self.workingDirectory { try? FileManager.default.removeItem(at: root) }
                self.workingDirectory = nil; self.isBusy = false; self.changed?()
            }
            do {
                let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
                    .appendingPathComponent("yabaibye-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                self.workingDirectory = root
                if manual { self.showProgress("正在检查新版本…") }
                let release: UpdateRelease = try await self.readJSON(
                    URL(string: "https://api.github.com/repos/kenxcomp/yabaibye/releases/latest")!, root: root)
                guard let metadataURL = release.asset("release.json"), let sumsURL = release.asset("SHA256SUMS") else {
                    throw AppFailure("最新发布缺少可信的更新信息，请稍后重试。")
                }
                let manifest: UpdateManifest = try await self.readJSON(metadataURL, root: root)
                try Task.checkCancellation()
                guard let current = self.currentVersion else { throw AppFailure("当前版本信息不可用，请安装正式应用包。") }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updater.lastCheck")
                guard let latest = UpdateVersion(version: manifest.version, build: manifest.build), latest > current else {
                    self.record("已是最新版本（\(current.version)）")
                    if manual { self.showMessage("已是最新版本", "当前版本 \(current.version)（\(current.build)）。") }; return
                }
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "x86_64"
                #endif
                guard let update = manifest.archive(release: release, current: current, architecture: architecture,
                                                   os: ProcessInfo.processInfo.operatingSystemVersion) else {
                    self.record("有新版本，暂不支持自动安装")
                    if manual { self.showMessage("有新版本，暂不支持自动安装", "此发布未满足签名、公证、架构或系统版本要求。请在 GitHub Releases 查看详情。") }
                    return
                }
                self.record("发现新版本 \(update.version.version)")
                self.progress?.orderOut(nil)
                // Only release builds signed by the same Developer ID may replace this app.
                let team = try await Task.detached { try UpdateInstaller.currentTeam() }.value
                let installed = Bundle.main.bundleURL
                try await Task.detached { try UpdateInstaller.verify(installed, team: team) }.value
                try Task.checkCancellation()
                guard UpdateInstaller.validDestination(installed) else {
                    throw AppFailure("发现新版本 \(update.version.version)，请先将应用安装到 Applications 后使用自动更新。")
                }
                guard self.canInstall() else { throw AppFailure("请先结束窗口练习或自检，再安装更新。") }
                let alert = NSAlert(); alert.messageText = "发现 Yabaibye \(update.version.version)（\(update.version.build)）"
                alert.informativeText = "当前为 \(current.version)（\(current.build)）。确认后将下载、验证并替换应用，然后重新打开 Yabaibye。其他应用会保持运行。"
                alert.addButton(withTitle: "下载并更新"); alert.addButton(withTitle: "稍后")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.showProgress("正在下载并验证更新…")
                let sumsFile = root.appendingPathComponent("SHA256SUMS")
                try await UpdateNetwork().fetch(sumsURL, to: sumsFile, limit: 64 * 1024)
                let sums = try String(contentsOf: sumsFile, encoding: .utf8)
                guard let checksum = UpdateManifest.checksum(for: update.name, in: sums) else { throw AppFailure("更新包的 SHA-256 校验信息无效。") }
                let archive = root.appendingPathComponent("update.zip")
                try await UpdateNetwork().fetch(update.url, to: archive, limit: 128 * 1024 * 1024)
                try Task.checkCancellation()
                self.progressLabel?.stringValue = "正在验证签名并准备安装…"
                let plan = UpdateInstallPlan(destination: installed.path, version: update.version.version,
                                             build: update.version.build, parentPID: getpid())
                let helper = try await Task.detached {
                    try UpdateInstaller.prepare(archive: archive, root: root, digest: checksum, plan: plan, team: team)
                }.value
                try Task.checkCancellation()
                guard self.canInstall() else { throw AppFailure("请先结束窗口练习或自检，再安装更新。") }
                try UpdateInstaller.launchHelper(helper)
                self.handedOff = true
                NSApp.terminate(nil)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                self.record("更新检查或下载失败：\(error.localizedDescription)")
                self.logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
                if manual || self.progress != nil { self.showMessage("无法完成更新", error.localizedDescription) }
            }
        }
    }
    private var currentVersion: UpdateVersion? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let number = Int(build) else { return nil }
        return UpdateVersion(version: version, build: number)
    }
    private func readJSON<T: Decodable>(_ url: URL, root: URL) async throws -> T {
        let file = root.appendingPathComponent(UUID().uuidString)
        try await UpdateNetwork().fetch(url, to: file, limit: 1024 * 1024)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }
    private func showMessage(_ title: String, _ message: String) {
        progress?.orderOut(nil)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "好"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    private func showProgress(_ message: String) {
        if let progress { progressLabel?.stringValue = message; progress.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 125),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Yabaibye 更新"; panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: message); label.frame = NSRect(x: 22, y: 78, width: 340, height: 20)
        let indicator = NSProgressIndicator(frame: NSRect(x: 22, y: 50, width: 336, height: 18))
        indicator.style = .bar; indicator.isIndeterminate = true; indicator.startAnimation(nil)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelUpdate)); cancel.frame = NSRect(x: 280, y: 10, width: 80, height: 30)
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(indicator); panel.contentView?.addSubview(cancel)
        progress = panel; progressLabel = label; panel.center(); panel.orderFrontRegardless()
    }
    @objc private func cancelUpdate() { task?.cancel() }
}
