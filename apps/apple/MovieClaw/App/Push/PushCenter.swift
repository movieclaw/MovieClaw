import os
import UIKit
import UserNotifications

/// App 推送的 App 这一侧（docs/design/cloud-push.md §9）：通知权限、APNs 令牌、给本机每个登录登记推送、点开通知。
///
/// - **权限**：新登录（账号密码登录、创建管理员、配对码登录、添加账号）后马上请求——推送不止订阅，
///   还有账号安全、管理员告警，等第一次订阅再问就晚了。系统只会弹一次，之后每次启动只读取当前状态。
/// - **登记**：给本机保存的每一个登录（每台服务器 × 每个账号）各登记一次：每个登录一把自己的密钥
///   （`PushKeyStore`），用那个登录自己的设备令牌调 `PUT /push/me/registration`。每次启动、每次新登录、
///   APNs 令牌变化、回到前台都登记一遍：内容没变、今天已经登记过的不重复发，没登记成功的下次接着登——
///   每天至少一次，服务器据此认出哪些账号还在这台手机上。APNs 回话（拿到令牌或失败）之前不登记：
///   上次的令牌存在本机先用着，冷启动抢在令牌前只报权限会让服务器以为这台设备没有令牌。用户关掉了通知、
///   拿不到 APNs 令牌（模拟器、没有推送权限的侧载包）时只上报权限。服务器说这个登录已失效（401）就删掉
///   它的令牌和推送密钥；别的失败只记日志，不打扰用户。
/// - **点开**：在 App 里重新解密，从明文认出是哪个登录、打开哪里，记进 `pendingTap`；主界面出来后由它切账号、
///   打开 `open`（见 MainTabView.openPushTarget）。人在欢迎页时不跳转（见 RootView）。
@Observable
final class PushCenter: NSObject {
    static let shared = PushCenter()

    /// 系统通知权限
    private(set) var permission: PushPermission = .notDetermined
    /// 点开了、还没处理完的通知：冷启动时主界面还没出来；要先切账号时，等主界面按新账号重建后接着处理
    var pendingTap: PushTapTarget?
    /// 每登记完一轮加一：「通知」页据此刷新「我的设备」
    private(set) var registrationRound = 0

    /// APNs 令牌：上次拿到的存在本机，这次启动拿到新的再换
    @ObservationIgnored private var apnsToken: String? = UserDefaults.standard.string(forKey: PushCenter.apnsTokenKey)
    /// 这次启动里 APNs 回过话了（拿到令牌或失败）。回话之前不登记
    @ObservationIgnored private var apnsAnswered = false
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    /// 这次运行里每个登录最近一次登记成功的内容（设备令牌 + 登记内容的摘要）：没变就不重复登记
    @ObservationIgnored private var registered: [String: Int] = [:]
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?

    private nonisolated static let log = Logger(subsystem: "io.movieclaw.push", category: "registration")
    private static let apnsTokenKey = "movieclaw.push.apnsToken"

    // MARK: - 启动

    /// App 启动时调用（AppDelegate 的 didFinishLaunching 返回前：点通知冷启动时，系统要在那之前拿到代理）
    func start() {
        UNUserNotificationCenter.current().delegate = self
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnedToForeground() }
        }
        Task {
            await refreshPermission()
            // 每次启动都向 APNs 注册（不弹任何框）：令牌可能变了；拒绝了通知也照样拿，以后打开就能直接收到
            UIApplication.shared.registerForRemoteNotifications()
            // 上次退出、移除账号时没能在服务器上注销的，再试一次
            await FirstFrameGate.wait()
            await PendingRevocations.retry()
        }
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsToken = token
        apnsAnswered = true
        UserDefaults.standard.set(token, forKey: Self.apnsTokenKey)
        Task { await sync() }
    }

    /// 拿不到令牌：模拟器、没有推送权限的包从来就没有，只上报权限；以前拿到过的（这次只是一时连不上 APNs）
    /// 接着用上次的
    func didFailToRegister(_ error: any Error) {
        Self.log.info("APNs 注册失败：\(error.localizedDescription, privacy: .public)")
        apnsAnswered = true
        Task { await sync() }
    }

    /// 这次启动里问过权限没有（新登录、或进入主界面时补问）
    @ObservationIgnored private var askedThisLaunch = false

    /// 新登录之后（见 AppModel.freshLogins）：请求通知权限，再给新登录登记
    func didLogIn() {
        askedThisLaunch = true
        Task { await requestAuthorization(prompt: Self.promptAllowed) }
    }

    /// 进入主界面（本机有登录中的账号）：升级前就登录着的人从没被问过，这次启动补问一次。
    /// 系统只在还没问过时弹框，问过的直接返回现状
    func sessionReady() {
        guard !askedThisLaunch else { return }
        askedThisLaunch = true
        Task { await requestAuthorization(prompt: Self.promptAllowed) }
    }

    /// 请求通知权限（提醒、声音、角标；系统只在还没问过时弹框），然后向 APNs 注册、给本机每个登录登记。
    /// 不管允不允许都注册：拒绝了令牌照样有用，以后在系统设置里打开就能直接收到
    func requestAuthorization(prompt: Bool = true) async {
        await refreshPermission()
        if prompt, permission == .notDetermined {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                Self.log.info("请求通知权限失败：\(error.localizedDescription, privacy: .public)")
            }
            await refreshPermission()
        }
        UIApplication.shared.registerForRemoteNotifications()
        await sync()
    }

    /// 回到前台：再登记一遍（权限在系统设置里改过要告诉服务器；上次没登记成功的接着登；内容没变的不重复发），
    /// 没能在服务器上注销的再试一次
    private func returnedToForeground() {
        Task {
            let before = permission
            await refreshPermission()
            if permission != before { UIApplication.shared.registerForRemoteNotifications() }
            await sync()
            await PendingRevocations.retry()
        }
    }

    private func refreshPermission() async {
        let status = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
        let current = PushPermission(status)
        if current != permission { permission = current }
    }

    // MARK: - 登记

    /// 给本机每个登录登记一次。正在登记时又来的请求合并成「这轮完了再来一轮」
    func sync() async {
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        defer { syncing = false }
        // 冷启动先让第一帧上屏，不和落地页抢主线程与连接（见 FirstFrameGate）
        await FirstFrameGate.wait()
        repeat {
            syncAgain = false
            await registerAll()
        } while syncAgain
        registrationRound += 1
    }

    private func registerAll() async {
        // APNs 还没回话：等它（回话时会再来一轮）。用户关了通知不用等，只报权限
        guard apnsAnswered || permission == .denied else { return }
        let store = PushKeyStore.shared
        // 每天至少登记一次：服务器按「最近一次登记」认出哪些账号还在这台手机上（cloud-push.md §5）
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        var jobs: [Job] = []
        for login in Self.savedLogins() {
            let body = API.PushRegistrationRequest.make(permission: permission, apnsToken: apnsToken, topic: Self.topic,
                                                        environment: Self.environment, clientVersion: DeviceInfo.appVersion) {
                store.ensureKey(for: login.info)
            }
            var hasher = Hasher()
            hasher.combine(login.token)
            hasher.combine(body)
            hasher.combine(day)
            let fingerprint = hasher.finalize()
            guard registered[login.info.login.account] != fingerprint else { continue }
            jobs.append(Job(account: login.info.login.account, server: login.server, username: login.info.username,
                            client: APIClient(server: login.server, token: login.token), body: body, fingerprint: fingerprint))
        }
        guard !jobs.isEmpty else { return }
        // 各台服务器同时登记：一台连不上不耽误别的
        let results = await withTaskGroup(of: (Job, Outcome).self) { group in
            for job in jobs {
                group.addTask {
                    do {
                        _ = try await job.client.pushMeRegistrationSet(body: job.body)
                        return (job, .registered)
                    } catch let error as APIError where error.isUnauthorized {
                        return (job, .loginExpired)
                    } catch {
                        // 只记日志：服务器还不支持推送（404）、连不上都不打扰用户，回到前台再试
                        Self.log.info("推送登记失败 \(job.server.hostLabel, privacy: .public)：\(error.localizedDescription, privacy: .public)")
                        return (job, .failed)
                    }
                }
            }
            var results: [(Job, Outcome)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (job, outcome) in results {
            switch outcome {
            case .registered:
                registered[job.account] = job.fingerprint
            case .loginExpired:
                // 这个登录在服务器上已经失效（被注销、改了密码）：令牌和推送密钥一起删掉，账号快照留着，
                // 点它时重新输密码（同 AppModel.refreshAccounts）
                Self.log.info("推送登记：\(job.server.hostLabel, privacy: .public) 上的登录已失效，删掉本机令牌")
                TokenVault.delete(server: job.server, username: job.username)
            case .failed:
                break
            }
        }
    }

    private enum Outcome: Sendable {
        case registered, loginExpired, failed
    }

    private struct Job: Sendable {
        var account: String
        var server: ServerAddress
        var username: String
        var client: APIClient
        var body: API.PushRegistrationRequest
        var fingerprint: Int
    }

    /// 本机保存的、钥匙串里还有令牌的全部登录（不只当前账号）
    private static func savedLogins() -> [(server: ServerAddress, token: String, info: PushLoginInfo)] {
        SavedServers.load().flatMap { saved in
            saved.accounts.compactMap { account in
                TokenVault.token(server: saved.address, username: account.username).map { token in
                    (saved.address, token, PushLoginInfo(origin: saved.address.origin.absoluteString, username: account.username,
                                                         serverName: saved.address.hostLabel, accountName: account.nickname))
                }
            }
        }
    }

    /// 推送的 Bundle ID（自己打包的 App 是自己的 Bundle ID，实例据此选通道）
    static var topic: String { Bundle.main.bundleIdentifier ?? "" }

    /// APNs 环境：按这个包签名里的 `aps-environment` 定，不按编译配置——Release 配置用开发证书签名的包
    /// （Xcode 的 Profile、自己用开发方式导出的包）拿到的是沙盒令牌，报成 production 苹果会说令牌无效。
    /// App Store 和 TestFlight 的包里没有描述文件，是 production；模拟器是 development
    static let environment: String = {
        #if targetEnvironment(simulator)
        return "development"
        #else
        return apsEnvironment(provisioningProfile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }) ?? "production"
        #endif
    }()

    /// 从描述文件（`embedded.mobileprovision`，CMS 签名包着一份 plist）里读 `aps-environment`
    nonisolated static func apsEnvironment(provisioningProfile data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex),
              let plistData = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return nil }
        return environment == "development" ? "development" : "production"
    }

    /// 包里有通知扩展：未签名的侧载包（scripts/build-unsigned-ipa.sh）去掉了它，也没有推送权限，收不到推送
    static let hasNotificationService: Bool = {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appending(path: "MovieClawNotificationService.appex").path)
    }()

    /// 登录后自动弹权限框的条件：收不到推送的包不弹（允许了也什么都收不到）；自动化测试不弹（系统弹窗会挡住
    /// 测试要点的界面：UI 测试带 --ui-testing，调试启动参数 -mcServer 直接登录），要验证这个权限框的测试带
    /// -mcPushPrompt YES
    private static var promptAllowed: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "mcPushPrompt") { return hasNotificationService }
        if DebugLaunch.server != nil { return false }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return false }
        return hasNotificationService
    }
}

// MARK: - 前台展示与点开

extension PushCenter: UNUserNotificationCenterDelegate {
    /// 在前台也照常横幅、进通知列表、响铃
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let target = PushTapTarget(userInfo: response.notification.request.content.userInfo, store: .shared) {
            Task { @MainActor in PushCenter.shared.pendingTap = target }
        }
        completionHandler()
    }
}
