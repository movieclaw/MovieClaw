import Foundation
import Observation

/// App 顶层状态机：决定此刻显示欢迎页还是主界面，并管理本机登录过的全部服务器与账号。
///
/// **登录设备**（docs/design/login-devices.md）：登录用账号密码换一枚长期有效的设备令牌
/// （`POST /auth/device/login`），存钥匙串（`TokenVault`，按「服务器 + 用户名」一枚一条），每个请求带
/// `Authorization: Bearer`。这台手机因此是服务端「我的设备」里的一台：写明谁在用，可以单独注销；
/// 不会像借用网页 Cookie 那样满 30 天强制重新输密码。
///
/// **多服务器 × 多账号完全在本机**：切换账号就是换一枚令牌，不联网、没有账号数上限。本机登录过哪些
/// 服务器、各有哪些账号记在 `savedServers`（见 `SavedServer`，每台服务器上标出「当前」那一个），
/// 「当前」只有一个：`server` 加上它那边的当前账号（`.ready`）。
///
/// **欢迎页的几种状态**（都渲染同一个 `WelcomeView`，状态之间切换时表单里填的内容不丢）：
/// - `.needsServer`：本机从没登录过任何服务器 → 放片头，再给「服务器地址 + 账号密码」一张卡片；
/// - `.needsSetup`：服务器是全新的 → 同一张卡片补一个确认密码，创建超级管理员（同 Web /setup）；
/// - `.needsLogin`：要输密码——当前账号的令牌失效了（被注销、改了密码，`expiredUsername` 预填用户名），
///   或账号全部退出后（预填最近的服务器）；
/// - `.chooseAccount`：当前服务器上没有登录中的账号了，但别的服务器上还有 → 先让用户选一个，一点即进；
/// - `.unreachable`：冷启动连不上当前服务器 → 重试 / 改地址 / 换账号。令牌还在，服务器恢复后点「重试」就能进。
///
/// 任意接口 401 经 `.apiUnauthorized` 通知把状态打回 `.needsLogin`，对应 Web 端全站的 401 跳登录页兜底；
/// 只认**当前令牌**的 401——刚退出的旧令牌、切换账号时别的账号的请求返回的 401 与当前会话无关。
///
/// **冷启动秒开**：本机有当前账号的令牌和它上次的会话快照（`SessionCache`）时，`init` 里直接进 `.ready`，
/// 第一帧就是主界面（页面数据来自各自的快照，见 `SessionPrewarm`）；身份在后台校验（`revalidate`）。
/// 以前要先等「测服务器 + 问身份」两个来回才出界面，期间只有一个转圈。校验遇到 401 照常回登录页；
/// 服务器连不上时留在主界面，各页面挂自己的「与后端通信失败，显示的是最近一次加载的数据」提示。
///
/// **iPhone 与 Apple TV 共用**（在 Shared/）。它引用的几个界面相关的名字由各平台的界面层各自定义：
/// `MainTab`（主界面的页签 / 侧边栏项）、`AppRoute`（可压栈的页面），以及 `SessionPrewarm`
/// （账号就绪时预热哪些页面）。两个平台的这几个类型同名不同义，共享代码只用到它们的名字。
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// 启动时正在恢复上次的服务器与会话
        case launching
        case needsServer
        case needsSetup
        case needsLogin
        case chooseAccount
        case unreachable
        case ready(API.SessionView)
    }

    private(set) var phase: Phase = .launching
    /// 当前服务器；为空表示本机还没登录过任何服务器
    private(set) var server: ServerAddress?
    /// 当前账号的设备令牌；为空表示当前服务器上没有可用的登录
    private(set) var token: String?
    /// 本机登录过的服务器，最近用过的在前
    private(set) var savedServers: [SavedServer] = []
    /// 连不上服务器的原因：「连不上」卡片与登录卡片顶部的提示
    var launchError: String?
    /// 登录过期的账号：欢迎页据此预填用户名、提示「登录已过期」；重新登录或换了账号后清空
    private(set) var expiredUsername: String?
    /// 自动换了账号时要告诉用户的一句话（「已退出 A，已切换到 B」）。换账号后主界面整棵重建，
    /// 提示条也跟着重建，当场弹的提示会丢，所以先存在这里，新的主界面出现时取走弹出来
    private(set) var pendingNotice: String?

    var api: APIClient? { server.map { APIClient(server: $0, token: token) } }

    var session: API.SessionView? {
        if case let .ready(session) = phase { return session }
        return nil
    }

    /// 别的服务器上已登录的账号（当前服务器除外）：欢迎页「选择账号」与「切换到其他账号」入口用。
    /// 当前服务器上的不算——到了欢迎页，说明当前服务器上已经没有能直接切换的账号了
    var accountsOnOtherServers: [SavedAccount] {
        savedServers.filter { $0.address != server }.flatMap { saved in
            saved.accounts.map { SavedAccount(server: saved.address, account: $0) }
        }
    }

    /// 本机登录过的账号总数（所有服务器）：「退出全部账号」的确认文案用
    var savedAccountCount: Int { savedServers.reduce(0) { $0 + $1.accounts.count } }

    /// 某个账号在本机还有没有可用的令牌（切换账号列表据此标出「需要重新登录」）
    func hasToken(for username: String, on address: ServerAddress) -> Bool {
        AuthTokenRegistry.shared.hasToken(server: address, username: username)
    }

    /// 会话过期时的浏览位置（Web 401 → `/login?next=原路径`）：重新登录后回到这里。
    /// 只记当前标签和它的导航栈；落地前按新身份的权限再过滤一遍（同 Web accessiblePathFor）。
    struct ResumePoint {
        var tab: MainTab
        var path: [AppRoute]
    }

    private var resumePoint: ResumePoint?
    /// 冷启动用会话快照直接进了主界面，身份还没向服务器确认过
    private var needsRevalidation = false
    /// 刚因 401 被打回登录页：主界面拆掉时据此决定要不要记下位置（主动退出、切换账号不记）
    private var expiredPendingCapture = false

    private static let serverKey = "movieclaw.server.origin"
    private var unauthorizedObserver: (any NSObjectProtocol)?

    init() {
        // UI 自动化测试用：以全新安装的状态启动（清掉服务器记录与全部令牌）
        if ProcessInfo.processInfo.arguments.contains("--reset-state") {
            UserDefaults.standard.removeObject(forKey: Self.serverKey)
            SavedServers.clearAll()
            SessionCache.clearAll()
            PageSnapshots.removeAll()
            TokenVault.clearAll()
        }
        // 改用设备令牌之前的版本留下的会话 Cookie：不再使用，也不该在本机留着有效凭证
        TokenVault.removeLegacyCookies()
        var saved = SavedServers.load()
        if let origin = UserDefaults.standard.url(forKey: Self.serverKey) {
            let address = ServerAddress(origin: origin)
            server = address
            if !saved.contains(where: { $0.address == address }) {
                saved = SavedServers.touching(saved, address, accounts: nil)
            }
        }
        savedServers = saved
        // 把本机的令牌读进图片加载器的令牌表（切换账号列表要显示各账号的头像）
        for record in saved {
            for account in record.accounts {
                if let token = TokenVault.token(server: record.address, username: account.username) {
                    AuthTokenRegistry.shared.remember(token, server: record.address, username: account.username)
                }
            }
        }
        if let server, let active = saved.first(where: { $0.address == server })?.activeAccount {
            token = TokenVault.token(server: server, username: active.username)
            AuthTokenRegistry.shared.setCurrent(token, server: server)
            if token != nil, !Self.debugLaunchOverridesSession, let cached = SessionCache.load(server: server, username: active.username) {
                phase = .ready(cached)
                needsRevalidation = true
                SessionPrewarm.start(server: server, session: cached, landing: SessionPrewarm.landingTab(for: cached))
                Self.flushPlaybackReports(APIClient(server: server, token: token))
            }
        }
        unauthorizedObserver = NotificationCenter.default.addObserver(
            forName: .apiUnauthorized, object: nil, queue: .main
        ) { [weak self] note in
            let target = note.object as? ServerAddress
            let rejected = note.userInfo?["token"] as? String
            MainActor.assumeIsolated { self?.sessionExpired(on: target, token: rejected) }
        }
    }

    // MARK: - 启动与重连

    /// 冷启动：有服务器就尝试恢复会话，否则进入欢迎页片头。
    func restore() async {
        #if DEBUG
        if let raw = DebugLaunch.server, let address = try? ServerAddress(parsing: raw) {
            // 这台设备上的令牌仍有效就沿用，免得每次调试启动都在服务器上多登一台设备
            if let user = DebugLaunch.username, let saved = TokenVault.token(server: address, username: user),
               let session = try? await APIClient(server: address, token: saved).authMe() {
                activate(address, session: session, token: saved)
                return
            }
            if let user = DebugLaunch.username, let pass = DebugLaunch.password,
               (try? await signIn(to: address, username: user, password: pass)) == .signedIn {
                return
            }
        }
        #endif
        guard server != nil else {
            phase = .needsServer
            return
        }
        await reconnect()
    }

    /// 冷启动用会话快照进了主界面之后，在后台向服务器确认身份（Web AuthGate 挂载时的 `/auth/me`）：
    /// 拿到最新的昵称、角色、能力开关就更新；401 由 `.apiUnauthorized` 打回登录页；连不上时什么也不做
    func revalidate() async {
        guard needsRevalidation, let server, let token, case let .ready(current) = phase else { return }
        needsRevalidation = false
        guard let fresh = try? await APIClient(server: server, token: token).authMe(),
              fresh.username == current.username, self.token == token else { return }
        update(session: fresh)
    }

    /// 调试启动参数指定了服务器 / 账号时走原来的恢复路径（`restore`），不用会话快照抢先进入
    private static var debugLaunchOverridesSession: Bool {
        #if DEBUG
        DebugLaunch.server != nil
        #else
        false
        #endif
    }

    /// 连当前服务器、恢复它上面的会话：冷启动与「连不上」卡片的「重试」共用
    func reconnect() async {
        guard let server else { return }
        let api = APIClient(server: server, token: token)
        do {
            let status = try await api.bootstrapStatus()
            guard status.initialized else {
                phase = .needsSetup
                return
            }
            guard let token else {
                // 本机没有这台服务器当前账号的令牌（升级前用 Cookie 登录的、或令牌已失效）：输一次密码
                launchError = nil
                expiredUsername = savedServers.first { $0.address == server }?.activeAccount?.username
                phase = .needsLogin
                return
            }
            activate(server, session: try await api.authMe(), token: token)
        } catch let error as APIError where error.isUnauthorized {
            // 当前账号的令牌失效了（被注销、改了密码）：预填快照里它的用户名，让用户只输密码
            forgetCurrentToken()
            launchError = nil
            expiredUsername = savedServers.first { $0.address == server }?.activeAccount?.username
            phase = .needsLogin
        } catch {
            // 服务器连不上：不当成「要重新登录」——令牌还在，恢复后点重试就能进
            launchError = error.localizedDescription
            phase = .unreachable
        }
    }

    // MARK: - 登录

    /// 一步登录的结果：登录成功，或服务器是全新的、需要先创建超级管理员
    enum SignInResult: Equatable {
        case signedIn
        case needsSetup
    }

    /// 欢迎页与「添加账号」的登录：测通服务器后用账号密码换设备令牌，全部成功才记下服务器并进入主界面。
    /// 可以是另一台服务器——登录成功它就成为当前服务器，原来那台的账号照样留在本机，随时切回去。
    /// 服务器尚未初始化时不登录，返回 `.needsSetup`，由界面补一次确认密码后调 `createAdmin(on:)`。
    func signIn(to address: ServerAddress, username: String, password: String) async throws -> SignInResult {
        let api = APIClient(server: address)
        guard try await Self.probe(api) else { return .needsSetup }
        try await deviceLogin(api, username: username, password: password)
        return .signedIn
    }

    /// 全新服务器：用欢迎页填的账号创建超级管理员并直接进入（全生命周期仅一次）
    func createAdmin(on address: ServerAddress, username: String, password: String) async throws {
        let api = APIClient(server: address)
        do {
            _ = try await api.authBootstrapCreate(body: .init(username: username, password: password))
        } catch let error as APIError where error.status == 409 {
            // 一次性初始化锁已闭合（别的设备/浏览器先一步完成了初始化）：界面据此退回普通登录
            throw ConnectError.alreadyInitialized
        }
        try await deviceLogin(api, username: username, password: password)
    }

    /// 配对码登录：设备上显示配对码、人在手机或网页上批准，兑换到的令牌直接进入批准者的账号
    /// （Apple TV 的默认登录方式，docs/design/tvos-app.md §5.1；协议见 device-auth.md §2）。
    /// 令牌与账号密码换来的是同一种登录设备，存储、切换、退出都走同一套
    func signIn(to address: ServerAddress, pairedToken token: String) async throws {
        let session = try await APIClient(server: address, token: token).authMe()
        TokenVault.save(token, server: address, username: session.username)
        activate(address, session: session, token: token)
    }

    /// 用账号密码换这台设备的令牌，存钥匙串并进入该账号
    private func deviceLogin(_ api: APIClient, username: String, password: String) async throws {
        let login: API.DeviceLoginView
        do {
            login = try await api.authDeviceLogin(body: .init(username: username, password: password, client: DeviceInfo.client))
        } catch let error as APIError where error.status == 404 || error.status == 405 {
            // 服务器还没有设备登录接口：App 比服务器新
            throw ConnectError.serverTooOld
        }
        TokenVault.save(login.token, server: api.server, username: login.session.username)
        activate(api.server, session: login.session, token: login.token)
    }

    /// 测通服务器：确认地址上跑的是健康的 MovieClaw，返回它是否已完成初始化
    private static func probe(_ api: APIClient) async throws -> Bool {
        let health: API.HealthResponse
        do {
            health = try await api.health()
        } catch APIError.decoding {
            throw ConnectError.notMovieClaw
        } catch let error as APIError where error.status == 404 {
            throw ConnectError.notMovieClaw
        }
        guard health.status == "ok" else { throw ConnectError.unhealthy(health.status) }
        return try await api.bootstrapStatus().initialized
    }

    // MARK: - 切换账号

    /// 切到某台服务器上一个已登录的账号（可以跨服务器），不用输密码——换用它的令牌即可。
    /// 本机没有它的令牌、或令牌已失效（被注销、改了密码）时抛 `AccountError.needsPassword`，
    /// 界面据此打开登录卡片，服务器与用户名都预填好。
    /// `landingOn` 给了就落在那个页签（主界面整棵重建，不给则落在新账号的默认首页）：从头像页签手势、
    /// 切换抽屉换账号时落在「我的」——人本来就在那儿（同 Instagram 切完停在个人页），也省得切一次账号就
    /// 把发现页这种重页面整页画一遍（2026-09-29 模拟器实测，从双击到新界面首帧：落在发现页 600～930ms，
    /// 落在「我的」100～160ms；其中向服务器确认身份只占 10ms 上下）。
    func switchAccount(to username: String, on address: ServerAddress, landingOn tab: MainTab? = nil) async throws {
        guard let saved = TokenVault.token(server: address, username: username) else {
            throw AccountError.needsPassword(server: address, username: username)
        }
        do {
            let session = try await APIClient(server: address, token: saved).authMe()
            resumePoint = tab.map { ResumePoint(tab: $0, path: []) }
            // 换完弹「已切换到「某某」」（主界面整棵重建，只能经 pendingNotice 带过去）；换到另一台服务器时
            // 写上是哪台——账户卡上不显示服务器，只在切换提示与切换抽屉里出现（2026-09-29 用户决定）
            let changesServer = address != server
            pendingNotice = "已切换到「\(session.nickname)」" + (changesServer ? " · \(address.hostLabel)" : "")
            activate(address, session: session, token: saved)
        } catch let error as APIError where error.isUnauthorized {
            TokenVault.delete(server: address, username: username)
            throw AccountError.needsPassword(server: address, username: username)
        }
    }

    /// 上一个账号（换账号时记下切走的那个）：存本机，冷启动后照样能双击切回去
    static let previousAccountKey = "movieclaw.previousAccount"

    static var previousAccount: (origin: URL, username: String)? {
        guard let stored = UserDefaults.standard.dictionary(forKey: previousAccountKey),
              let origin = (stored["origin"] as? String).flatMap(URL.init(string:)),
              let username = stored["username"] as? String else { return nil }
        return (origin, username)
    }

    /// 从本机移除一个账号：在服务端注销这台设备上它的登录，再删掉本机的令牌与快照。
    /// 移除的是当前账号时处理同「退出登录」，返回自动切到的会话。服务器连不上也照样在本机移除。
    @discardableResult
    func removeAccount(_ username: String, on address: ServerAddress) async throws -> API.SessionView? {
        let isCurrent = address == server && session?.username == username
        if isCurrent { return await logout() }
        if let saved = TokenVault.token(server: address, username: username) {
            await Self.revokeDevice(APIClient(server: address, token: saved))
        }
        TokenVault.delete(server: address, username: username)
        SessionPrewarm.forget(server: address, username: username)
        savedServers = SavedServers.removingAccount(savedServers, username, from: address)
        savedServers = SavedServers.pruned(savedServers, keeping: server)
        persist()
        return nil
    }

    /// 刷新某台服务器上本机各账号的快照（昵称、头像、角色）。令牌失效的账号保留在列表里、删掉令牌，
    /// 点它时要重新输密码；服务器连不上时抛错，快照保持原样
    @discardableResult
    func refreshAccounts(on address: ServerAddress) async throws -> [API.AccountView] {
        guard let saved = savedServers.first(where: { $0.address == address }) else { return [] }
        var refreshed: [API.AccountView] = []
        for account in saved.accounts {
            guard let token = TokenVault.token(server: address, username: account.username) else {
                refreshed.append(account)
                continue
            }
            do {
                let me = try await APIClient(server: address, token: token).authMe()
                refreshed.append(SavedServers.snapshot(of: me, active: account.active))
            } catch let error as APIError where error.isUnauthorized {
                TokenVault.delete(server: address, username: account.username)
                refreshed.append(account)
            }
        }
        savedServers = SavedServers.replacingAccounts(savedServers, address, with: refreshed)
        persist()
        return refreshed
    }

    /// 改昵称、换头像后同步全局会话与本机快照。与当前会话完全一样时什么也不做：回到前台 / 冷启动的
    /// 身份校验每次都会调到这里，照样赋值会让整个主界面按「会话变了」重算一遍
    func update(session: API.SessionView) {
        guard session != self.session else { return }
        phase = .ready(session)
        if let server {
            savedServers = SavedServers.upserting(savedServers, server, account: SavedServers.snapshot(of: session, active: true))
            persist()
            SessionCache.save(session, server: server)
        }
    }

    // MARK: - 退出

    /// 退出当前账号：在服务端注销这台设备上的登录（「我的设备」里那一行随之消失），删掉本机令牌。
    /// 同一台服务器上本机还有别的账号就自动切过去（与网页一致），返回切到的会话；
    /// 这台服务器上没有了：别的服务器上还有账号 → 欢迎页「选择账号」，一个都没有 → 欢迎页登录卡片（预填这台服务器）。
    @discardableResult
    func logout() async -> API.SessionView? {
        resumePoint = nil
        guard let server, let current = session else { return nil }
        if let token { await Self.revokeDevice(APIClient(server: server, token: token)) }
        TokenVault.delete(server: server, username: current.username)
        SessionPrewarm.forget(server: server, username: current.username)
        forgetCurrentToken()
        savedServers = SavedServers.removingAccount(savedServers, current.username, from: server)
        persist()
        if let next = await switchToAnotherAccount(on: server) {
            // 退出后人还在 App 里，很容易以为没退成：明确说出现在换成了谁
            pendingNotice = "已退出「\(current.nickname)」，已切换到「\(next.nickname)」"
            return next
        }
        leaveCurrentServer()
        return nil
    }

    /// 退出本机全部账号（所有服务器上的），共用设备交还前用。
    /// 本机的令牌立即全部删掉；服务端的注销在后台逐台尽力而为——服务器连不上也能在本机退干净。
    func logoutEverywhere() {
        resumePoint = nil
        let targets: [APIClient] = savedServers.flatMap { saved in
            saved.accounts.compactMap { account in
                TokenVault.token(server: saved.address, username: account.username).map { APIClient(server: saved.address, token: $0) }
            }
        }
        Task.detached {
            for client in targets { await Self.revokeDevice(client) }
        }
        TokenVault.clearAll()
        SessionCache.clearAll()
        PageSnapshots.removeAll()
        forgetCurrentToken()
        let emptied = savedServers.map { SavedServer(address: $0.address, accounts: [], lastUsed: $0.lastUsed) }
        savedServers = SavedServers.pruned(emptied, keeping: server)
        persist()
        expiredUsername = nil
        phase = .needsLogin
    }

    /// 同一台服务器上找一个本机还能用的账号切过去（退出 / 移除当前账号后）；一个都没有返回 nil
    private func switchToAnotherAccount(on address: ServerAddress) async -> API.SessionView? {
        let candidates = savedServers.first(where: { $0.address == address })?.accounts ?? []
        for account in candidates {
            guard let saved = TokenVault.token(server: address, username: account.username) else { continue }
            do {
                let session = try await APIClient(server: address, token: saved).authMe()
                activate(address, session: session, token: saved)
                return session
            } catch let error as APIError where error.isUnauthorized {
                TokenVault.delete(server: address, username: account.username)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// 当前服务器上已经没有能用的账号：清空它的快照，去欢迎页
    private func leaveCurrentServer() {
        guard let server else { return }
        for account in savedServers.first(where: { $0.address == server })?.accounts ?? [] {
            TokenVault.delete(server: server, username: account.username)
            SessionPrewarm.forget(server: server, username: account.username)
        }
        savedServers = SavedServers.replacingAccounts(savedServers, server, with: [])
        persist()
        expiredUsername = nil
        phase = accountsOnOtherServers.isEmpty ? .needsLogin : .chooseAccount
    }

    /// 在服务端注销这台设备上某个账号的登录（`DELETE /auth/devices/current`）。尽力而为：
    /// 服务器连不上、令牌已失效都不影响本机退出，5 秒超时，不让用户对着转圈等
    private nonisolated static func revokeDevice(_ client: APIClient) async {
        _ = try? await client.send("DELETE", "/auth/devices/current", timeout: 5, as: API.JSONValue?.self)
    }

    // MARK: - 内部

    /// 进入某台服务器上的某个账号：记下服务器（置顶）与当前令牌、清掉过期 / 连不上的提示，更新本机快照
    private func activate(_ address: ServerAddress, session: API.SessionView, token: String) {
        // 换了账号（含换到另一台服务器）：记下切走的那个，双击头像页签据此切回来
        if case let .ready(current) = phase, let from = server,
           from != address || current.username != session.username {
            UserDefaults.standard.set(["origin": from.origin.absoluteString, "username": current.username],
                                      forKey: Self.previousAccountKey)
        }
        server = address
        self.token = token
        AuthTokenRegistry.shared.setCurrent(token, server: address)
        UserDefaults.standard.set(address.origin, forKey: Self.serverKey)
        launchError = nil
        expiredUsername = nil
        // 置顶这台、把这个账号标为它上面的当前账号；顺手清掉已经一个账号都不剩的旧服务器
        var list = SavedServers.touching(savedServers, address, accounts: nil)
        list = SavedServers.upserting(list, address, account: SavedServers.snapshot(of: session, active: true))
        savedServers = SavedServers.pruned(list, keeping: address)
        persist()
        SessionCache.save(session, server: address)
        SessionPrewarm.start(server: address, session: session)
        Self.flushPlaybackReports(APIClient(server: address, token: token))
        phase = .ready(session)
    }

    /// 补发上次没发出去的播放记录（含上次闪退、被系统杀掉时留下的那一次，docs/design/playback-qoe.md §2）
    private static func flushPlaybackReports(_ api: APIClient) {
        PlaybackReportQueue.recoverAbnormalExit()
        Task.detached(priority: .utility) { await PlaybackReportQueue.flush(api: api) }
    }

    private func forgetCurrentToken() {
        token = nil
        if let server { AuthTokenRegistry.shared.setCurrent(nil, server: server) }
    }

    private func persist() {
        SavedServers.save(savedServers)
    }

    /// 当前令牌收到 401（被注销、改了密码、账号停用）：删掉这枚已经没用的令牌，回登录页并预填用户名。
    /// 带着别的令牌的 401（刚退出的旧令牌还有请求在路上、切换账号时问别的账号）不算。
    private func sessionExpired(on target: ServerAddress?, token rejected: String?) {
        guard case let .ready(current) = phase, target == nil || target == server else { return }
        if let rejected, rejected != token { return }
        if let server { TokenVault.delete(server: server, username: current.username) }
        forgetCurrentToken()
        expiredPendingCapture = true
        expiredUsername = current.username
        phase = .needsLogin
    }

    /// 主界面拆掉时调用：只有因会话过期离开才记下位置
    func captureResume(tab: MainTab, path: [AppRoute]) {
        guard expiredPendingCapture else { return }
        expiredPendingCapture = false
        resumePoint = ResumePoint(tab: tab, path: path)
    }

    /// 取走（并清空）待弹出的提示
    func takeNotice() -> String? {
        defer { pendingNotice = nil }
        return pendingNotice
    }

    /// 取走（并清空）待还原的位置
    func takeResume() -> ResumePoint? {
        defer { resumePoint = nil }
        return resumePoint
    }

    enum ConnectError: LocalizedError {
        case notMovieClaw
        case unhealthy(String)
        case alreadyInitialized
        case serverTooOld

        var errorDescription: String? {
            switch self {
            case .notMovieClaw: "该地址能访问，但不是 MovieClaw 服务器（请填写浏览器打开 MovieClaw 时地址栏里的地址）"
            case let .unhealthy(status): "服务器状态异常：\(status)"
            case .alreadyInitialized: "这台服务器刚刚已在别处完成初始化，请用已有的账号登录"
            case .serverTooOld: "服务器版本太旧，还不支持 App 登录。请先在网页「设置 → 更新与维护」里把服务器升级到最新版"
            }
        }
    }

    enum AccountError: LocalizedError {
        /// 切不过去，要重新输密码
        case needsPassword(server: ServerAddress, username: String)

        var errorDescription: String? {
            switch self {
            case let .needsPassword(_, username): "「\(username)」的登录已失效，请重新输入密码"
            }
        }
    }
}
