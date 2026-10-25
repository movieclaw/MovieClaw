import AppKit
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// 软件更新（docs/design/macos-app.md §7）：GitHub 直接分发版（MovieClawMacDirect 目标，链接了 Sparkle）才有，
/// 商店版由 TestFlight / App Store 负责，开发版不检查。
///
/// 体验：启动 30 秒后再开始（不跟启动抢网络），之后 Sparkle 每 24 小时查一次；默认自动下载、退出时安装，
/// 全程没有弹窗。下好之后只在两处安静地提示：侧边栏底部的胶囊、菜单「重新启动以更新…」。
/// 关了自动下载的人，有新版时 Sparkle 弹更新窗口问一次；正在播放就不弹，改成胶囊，点了再弹。
/// 更新完第一次打开，主界面顶上提示一句「已更新到 x」。
@Observable
final class MacUpdater {
    static let shared = MacUpdater()

    /// 这份 App 的更新由谁负责
    enum Channel: Equatable {
        /// 开发版、没装进「应用程序」的：不显示任何更新入口
        case none
        /// TestFlight / App Store 装的
        case store
        /// GitHub 直接分发版：Sparkle
        case sparkle
    }

    enum Phase: Equatable {
        case idle
        /// 有新版没下（关了自动下载，或者播放中推迟了更新窗口），点了才弹 Sparkle 的更新窗口
        case available(version: String)
        /// 已下载并校验，退出时安装；也可以立即重启安装
        case ready(version: String)
    }

    let channel: Channel
    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?
    /// 主窗口在播放时为 true（MacMainView 同步）：这期间不弹任何更新窗口，胶囊也收起来
    var isPlaying = false
    /// 设置里的两个开关（存在 Sparkle 自己的偏好设置里，这里是镜像）。各自只写回自己那一项：
    /// 启动时先后从 Sparkle 读进来，读第一个时另一个还是初始值，一起写回会把用户的设置冲掉
    var automaticallyChecks = false {
        didSet { syncAutomaticallyChecks() }
    }
    var automaticallyDownloads = false {
        didSet { syncAutomaticallyDownloads() }
    }

    private init() {
        #if canImport(Sparkle) && !DEBUG
        channel = MacInstallLocation.problem == nil ? .sparkle : .none
        #else
        let receipt = Bundle.main.appStoreReceiptURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        channel = receipt ? .store : .none
        #endif
    }

    // MARK: 给界面用

    /// 菜单栏「MovieClaw」里那一项的文字
    var menuTitle: String {
        if case let .ready(version) = phase { return "重新启动以更新到 \(version)…" }
        return "检查更新…"
    }

    /// 关于窗口、设置里的按钮文字
    var primaryTitle: String {
        switch phase {
        case .ready: "重新启动以更新"
        case .available: "查看新版本"
        case .idle: "检查更新"
        }
    }

    /// 关于窗口、设置里的一行状态
    var statusText: String {
        switch phase {
        case let .ready(version): return "\(version) 已下载，退出时安装"
        case let .available(version): return "有新版本 \(version)"
        case .idle:
            guard let lastCheck else { return "还没有检查过更新" }
            return "已是最新 · 上次检查：" + lastCheck.formatted(.relative(presentation: .named))
        }
    }

    /// 菜单、关于窗口里的主按钮：下好了就重启安装，有新版就打开更新窗口，否则检查一次
    func primaryAction() {
        switch phase {
        case .ready: installNow()
        case .available, .idle: checkForUpdates()
        }
    }

    /// 主界面第一次出现时取一次：刚更新过就返回提示语（只返回一次）
    func takeUpdatedNotice() -> String? {
        guard channel == .sparkle else { return nil }
        let key = "mc.update.lastLaunchedVersion"
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        guard let previous, previous != current else { return nil }
        return "已更新到 MovieClaw \(current)"
    }

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private let bridge = SparkleBridge()
    private var started = false
    private var installNowHandler: (() -> Void)?

    /// 启动时调一次（MacAppDelegate）：建好 Sparkle，30 秒后再开始定时检查
    func launch() {
        guard channel == .sparkle, controller == nil else { return }
        bridge.owner = self
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: bridge, userDriverDelegate: bridge)
        self.controller = controller
        lastCheck = controller.updater.lastUpdateCheckDate
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        Task {
            try? await Task.sleep(for: .seconds(30))
            startIfNeeded()
        }
    }

    func checkForUpdates() {
        guard let controller else { return }
        startIfNeeded()
        controller.checkForUpdates(nil)
    }

    func installNow() {
        if let installNowHandler {
            installNowHandler()
        } else {
            checkForUpdates()
        }
    }

    private func startIfNeeded() {
        guard let controller, !started else { return }
        started = true
        controller.startUpdater()
    }

    fileprivate func readyToInstall(version: String, handler: @escaping () -> Void) {
        installNowHandler = handler
        phase = .ready(version: version)
    }

    fileprivate func available(version: String) {
        if case .ready = phase { return }
        phase = .available(version: version)
    }

    fileprivate func clearAvailable() {
        if case .available = phase { phase = .idle }
    }

    fileprivate func finishedCheck() {
        lastCheck = controller?.updater.lastUpdateCheckDate
    }

    private func syncAutomaticallyChecks() {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
        updater.automaticallyChecksForUpdates = automaticallyChecks
    }

    private func syncAutomaticallyDownloads() {
        guard let updater = controller?.updater, updater.automaticallyDownloadsUpdates != automaticallyDownloads else { return }
        updater.automaticallyDownloadsUpdates = automaticallyDownloads
    }
    #else
    private func syncAutomaticallyChecks() {}
    private func syncAutomaticallyDownloads() {}
    func launch() {}
    func checkForUpdates() {}
    func installNow() {}
    #endif
}

#if canImport(Sparkle)
/// Sparkle 的两个代理（要求 NSObject），转给 MacUpdater
private final class SparkleBridge: NSObject, @preconcurrency SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    weak var owner: MacUpdater?

    // 首次就开启自动检查，不弹「要不要自动检查更新」（设置里能关）
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    // 自动下载好、校验过：退出时安装。返回 true 表示由我们提供「立即重启」的入口（胶囊、菜单、关于窗口）
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        owner?.readyToInstall(version: item.displayVersionString, handler: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        owner?.finishedCheck()
    }

    // 定时检查到的新版（关了自动下载时才会走到这里）：在前台且没在播放才由 Sparkle 弹窗，否则只亮胶囊
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus && owner?.isPlaying != true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            owner?.available(version: update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        owner?.clearAvailable()
    }

    func standardUserDriverWillFinishUpdateSession() {
        owner?.clearAvailable()
    }
}
#endif
