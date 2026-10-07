import Nuke
import SwiftUI

/// 登录后的主界面：iOS 26 原生液态玻璃标签栏。
///
/// 页签只显示图标（参照 Instagram iOS 底栏，2026-09-26 用户要求）：媒体库（首页）/ 订阅（有订阅权限）/ 发现 /
/// 活动（管理员）/ 头像。最右的头像页签是当前用户头像，点开「更多」页（账号、设置、会话）。
/// 2026-09-30 起媒体库排最左作首页（与 Web 手机底栏 components/glass-tab-bar.tsx 的顺序不再一致）；下滑时标签栏自动收起。
///
/// 搜索不占页签，在各标签根页右上角（见 AppTopBar）：iPhone 标签栏最多放 5 个页签，管理员
/// 四个内容页签加头像已满，再放搜索页签会被系统收进「More」。标签栏的高度与玻璃质感是系统定的
/// （实测去掉文字仍是 62pt，控件尺寸 / 字号也改不动；背景色设置对液态玻璃不生效），不自绘——用户明确要
/// 原生标签栏，也不在玻璃身后垫黑色压暗层（试过，底栏上方多出一条黑带，2026-09-27 用户要求撤掉）：
/// App 全局深色，玻璃透出的本就是暗底。图标统一成正方形见 TabIcon。
///
/// 这里还负责注入全局依赖：Router（导航）、Feedback（提示/确认）、APIClient、权限，
/// 并在根部统一挂载全屏播放器与全局弹层。
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var router = Router()
    @State private var feedback = Feedback()
    @State private var badges = ShellBadges()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    /// 首次落点只定一次（之后权限变化不再抢标签）
    @State private var landed = false
    /// 头像页签的图标（见 AvatarTabIcon）；nil = 还没画好，先用 SF Symbol 顶一下
    @State private var avatarIcon: UIImage?
    /// 正在背后预热的页签（见 PageWarmup）
    @State private var warmupTabs: [MainTab] = []
    /// 主界面出现之后是否已经在前台过：冷启动用快照直接进主界面时，主界面比场景「变成前台」还早，
    /// 那一次激活不是「回到前台」，不补做身份校验与更新检查（冷启动那份由 AppModel.revalidate、角标轮询首轮做）
    @State private var wasActive = false
    /// 头像页签在窗口里的位置（账号手势提示气泡对准它，见 TabBarAccountGestures）
    @State private var avatarTabFrame: CGRect = .zero
    @State private var showAccountTip = false
    /// 成员有没有可见库（搜索的「媒体库」分区要它，见 AppTopBar 的放大镜）；nil = 还没查到。
    /// 只有这一项要异步查：影视 / 资源分区由权限同步得出，超管恒有媒体库分区——放大镜对他们第一帧就在，不闪。
    /// 换账号时整棵主界面按账号重建（见 MovieClawApp），这份状态随之清空，不会串号
    @State private var memberHasLibrary: Bool?
    /// 账号手势提示看过没有（只提示一次）。只在气泡真的显示出来时才记：头像页签的位置还没找到时
    /// 气泡画不出来，照样记下就等于没提示过却再也不提示了（v1 键在测试包里就这样被误记过，换了新键）
    @AppStorage("movieclaw.tips.accountGestures.v2") private var accountTipShown = false
    /// 双击切换进行中：切换要向服务器校验一次令牌，期间再双击不重复发起
    @State private var switchingAccount = false
    /// 标签栏上方的「接着看」条（见 ResumeAccessory）
    @State private var resume = ResumeBarStore()
    /// 点开的推送通知（见 openPushTarget）
    @Environment(PushCenter.self) private var push

    /// 当前停在「片段」页（媒体库页签栈顶）
    private var onReels: Bool {
        router.selectedTab == .library && router.paths[.library]?.last == .reels
    }

    /// 当前停在 AI 会话页（新会话或已有会话）：那页隐藏了标签栏，附件却还会贴在输入框下面，要一起收掉
    private var onAgentSession: Bool {
        switch router.paths[router.selectedTab]?.last {
        case .newSession?, .session?: true
        default: false
        }
    }

    var body: some View {
        let session = model.session
        let permissions = session.map(Permissions.init(session:)) ?? .none
        let api = model.api ?? EnvironmentValues().api

        TabView(selection: Binding(get: { router.selectedTab }, set: { tab in
            // 再点一次当前页签：回到这个页签的根页（iOS 惯例）。「片段」这类不带返回键的二级页靠它回去
            if tab == router.selectedTab { router.popToRoot() }
            router.selectedTab = tab
        })) {
            Tab(value: MainTab.library) {
                TabRoot(tab: .library) { LibraryHomeView() }
            } label: {
                iconLabel(.library)
            }
            .accessibilityLabel(MainTab.library.title)
            if permissions.canSubscribe {
                Tab(value: MainTab.subscriptions) {
                    TabRoot(tab: .subscriptions) { SubscriptionsView() }
                } label: {
                    iconLabel(.subscriptions)
                }
                .accessibilityLabel(MainTab.subscriptions.title)
            }
            Tab(value: MainTab.discover) {
                TabRoot(tab: .discover) { DiscoverView(kind: "movie") }
            } label: {
                iconLabel(.discover)
            }
            .accessibilityLabel(MainTab.discover.title)
            if permissions.isAdmin {
                Tab(value: MainTab.activity) {
                    TabRoot(tab: .activity) { ActivityView() }
                } label: {
                    iconLabel(.activity)
                }
                .accessibilityLabel(MainTab.activity.title)
            }
            Tab(value: MainTab.more) {
                TabRoot(tab: .more) { MorePage() }
            } label: {
                Label {
                    Text(MainTab.more.title)
                } icon: {
                    Image(uiImage: avatarIcon ?? TabIcon.image(MainTab.more.systemImage))
                }
                .labelStyle(.iconOnly)
            }
            .accessibilityLabel(MainTab.more.title)
            .accessibilityIdentifier("open-more")
        }
        // 「片段」上下滑动是在换条，不是在往下读：停在它上面时标签栏不收起（docs/design/reels.md）
        .tabBarMinimizeBehavior(onReels ? .never : .onScrollDown)
        // 「接着看」条：片段页自己占满底部、AI 会话页底部是输入框（2026-09-30 用户反馈条贴在输入框下面很怪），都不显示
        .modifier(ResumeAccessoryModifier(item: resume.visibleItem, enabled: !onReels && !onAgentSession,
                                          onHide: { resume.hide() }))
        // 进主界面、关掉播放器（看过就变了）、回到前台、换账号时重新取最近播放的那一条
        .task(id: "\(router.player == nil)|\(scenePhase == .active)|\(session?.nickname ?? "")|\(api.server.origin)") {
            guard router.player == nil, scenePhase == .active else { return }
            await resume.refresh(api: api)
        }
        .background { PageWarmup(tabs: warmupTabs) }
        // 头像页签：长按弹切换账号抽屉、双击切回上一个账号（仿 Instagram，见 AccountGestureHub）
        .background(TabBarAccountGestures(onAvatarFrame: { if avatarTabFrame != $0 { avatarTabFrame = $0 } }))
        .onReceive(NotificationCenter.default.publisher(for: .avatarTabLongPressed)) { _ in openAccountSwitcher() }
        .onReceive(NotificationCenter.default.publisher(for: .avatarTabDoubleTapped)) { _ in
            Task { await switchToPreviousAccount() }
        }
        .overlay {
            if showAccountTip, avatarTabFrame != .zero {
                AccountGestureTip(avatarFrame: avatarTabFrame) { withAnimation { showAccountTip = false } }
            }
        }
        // 本机账号超过一个时才提示账号手势（一个账号时这两个手势都没意义），只提示一次；
        // 等找到头像页签的位置再提示（气泡要对准它）
        .task(id: "\(model.savedAccountCount)|\(avatarTabFrame != .zero)") {
            guard model.savedAccountCount > 1, !accountTipShown, avatarTabFrame != .zero else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, avatarTabFrame != .zero else { return }
            accountTipShown = true
            withAnimation { showAccountTip = true }
            try? await Task.sleep(for: .seconds(6))
            withAnimation { showAccountTip = false }
        }
        // 活动页签（红 > 绿 > 蓝，同网页）与头像页签（有待安装的更新）的状态点：
        // SwiftUI 的 .badge 只能红底文字，下到 UIKit 画小圆点
        .background(TabBarDotBridge(
            tabs: Self.visibleTabs(permissions),
            dots: [MainTab.activity: badges.activityDot, .more: badges.moreDot].compactMapValues { $0 }
        ))
        // 头像位图：先出首字版（照片下载前不空着），照片到了再换；改昵称 / 换头像后重画
        .task(id: "\(session?.nickname ?? "")|\(session?.avatarUrl ?? "")|\(displayScale)") {
            // 冷启动先让第一帧上屏（这时页签先用 SF Symbol 顶着），再画头像（见 FirstFrameGate）
            await FirstFrameGate.wait()
            avatarIcon = AvatarTabIcon.render(nickname: session?.nickname, photo: nil, scale: displayScale)
            guard let url = api.image(session?.avatarUrl, width: ImageWidth.points(AvatarTabIcon.size)) else { return }
            let request = ImageRequest(url: url, processors: [.resize(size: CGSize(width: AvatarTabIcon.size, height: AvatarTabIcon.size), contentMode: .aspectFill)])
            guard let photo = try? await ImagePipeline.shared.image(for: request) else { return }
            avatarIcon = AvatarTabIcon.render(nickname: session?.nickname, photo: photo, scale: displayScale)
        }
        .sheet(item: $router.sheet) { sheet in
            sheet.content.sheetFeedback()
        }
        .fullScreenCover(item: $router.player) { request in
            PlayerScreen(request: request)
        }
        .fullScreenCover(item: $router.deviceApproval) { launch in
            DeviceApprovalFlow(launch: launch)
        }
        .onAppear {
            #if DEBUG
            // -mcNoEarlyStart YES：播放器视图出现才起播（提前起播之前的行为，真机新旧对照用）
            if UserDefaults.standard.bool(forKey: "mcNoEarlyStart") { return }
            #endif
            // 点播放就开始起播（见 Router.startPlaybackEarly）。API 客户端在点击那一刻取：换过账号用的是新的
            router.startPlaybackEarly = { [router, model] request in
                if let current = router.activePlayback, current.isClosed || (!current.viewAttached && current.request.id != request.id) {
                    current.close()
                    router.activePlayback = nil
                }
                guard router.activePlayback?.request.id != request.id else { return }
                let controller = PlaybackController(
                    request: request, api: model.api ?? EnvironmentValues().api, requestedAt: router.playRequestedAt)
                router.activePlayback = controller
                controller.start()
            }
        }
        .onChange(of: router.player?.id) { _, presented in
            // 提前起播了、播放器却没弹出来就被撤掉（视图从没出现过，不会走它的收尾）：这里关掉，免得会话与引擎空跑
            if let early = router.activePlayback, !early.viewAttached, early.request.id != presented {
                early.close()
                router.activePlayback = nil
            }
        }
        .modifier(FeedbackHost(feedback: feedback))
        #if DEBUG
        .task {
            // 开发期：-mcRoute 直接打开某个站内路径（与网页同路由截图对照）
            guard let path = DebugLaunch.route else { return }
            router.permissions = permissions // 启动路由可能抢在 onChange 同步权限之前
            // -mcRouteDelay <秒>：等落地页的冷启动请求跑完再开（量起播耗时时排除启动期的连接池拥挤）
            if let delay = DebugLaunch.routeDelay, delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            MainThreadProbe.run()  // -mcMainProbe YES：打开播放器后 3 秒内主线程的忙碌段
            router.open(webPath: path)
            // -mcRouteThen <站内路径> -mcRouteThenDelay <秒>：先开 -mcRoute（比如首页），到点再开这个（比如播放页）——
            // 量「在页面上停一会儿再点播放」这种真实动线（页面出现时的预连、空闲后的冷连接都在里面）
            if let then = UserDefaults.standard.string(forKey: "mcRouteThen") {
                try? await Task.sleep(for: .seconds(max(0.5, UserDefaults.standard.double(forKey: "mcRouteThenDelay"))))
                MainThreadProbe.run()  // 同上，从打开播放页起量
                router.open(webPath: then)
            }
            // -mcRouteReopenAfter <秒>：到点关掉播放器、2 秒后原样再打开（验证退出再进同一部片的起播与流量）
            let reopenAfter = UserDefaults.standard.double(forKey: "mcRouteReopenAfter")
            if reopenAfter > 0 {
                try? await Task.sleep(for: .seconds(reopenAfter))
                let request = router.player
                router.player = nil
                FileHandle.standardError.write(Data("[AutoTest] 关闭播放器\n".utf8))
                try? await Task.sleep(for: .seconds(2))
                if let request {
                    FileHandle.standardError.write(Data("[AutoTest] 重新打开播放器\n".utf8))
                    router.play(request)
                }
            }
        }
        .task {
            // 开发期：-mcPerfScript 按时刻依次切页签（量切页耗时，见 PerfTrace）
            for step in DebugLaunch.perfScript {
                let wait = step.at - (PerfTrace.now() - PerfTrace.mainStart) / 1000
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                if let tab = MainTab(rawValue: step.target) {
                    router.selectedTab = tab
                } else {
                    // 站内路径（如 /discover/tv 切到剧集视角）：页面不换，按路径的首段记一次打开
                    PerfTrace.pageBegan(String(step.target.split(separator: "/").first ?? ""), trigger: "route")
                    router.open(webPath: step.target)
                }
            }
        }
        #endif
        .onChange(of: permissions, initial: true) { _, value in
            let tabs = Set(Self.visibleTabs(value))
            router.availableTabs = tabs
            router.permissions = value
            // 权限被收回时（后台重新校验身份后），停在已不可见的标签上要落回媒体库
            if !tabs.contains(router.selectedTab) { router.selectedTab = .library }
            land(permissions: value)
            // 退出 / 移除当前账号后自动换到了下一个账号：这里才弹得出提示（见 AppModel.pendingNotice）
            if let notice = model.takeNotice() { feedback.success(notice) }
        }
        .onChange(of: push.pendingTap, initial: true) { _, target in
            openPushTarget(target, permissions: permissions)
        }
        .onChange(of: router.player == nil) { _, closed in
            // 播放时点开了别的账号的通知：播放器关掉后接着处理
            if closed { openPushTarget(push.pendingTap, permissions: permissions) }
        }
        .onAppear { if scenePhase == .active { wasActive = true } }
        .onDisappear {
            // 会话过期被打回登录页：记下此刻的位置，重新登录后回到这里（Web 401 → /login?next=原路径）
            model.captureResume(tab: router.selectedTab, path: router.paths[router.selectedTab] ?? [])
        }
        .onChange(of: scenePhase) { _, phase in
            // 墙位置的「久别回归」判定全站共用一个时刻（各面墙出现时比较，见 LibraryWallRecall）
            LibraryWallRecall.noteScenePhase(phase)
            // 回到前台：后台静默重新校验身份与权限（Web AuthGate 每次挂载重取 /auth/me），
            // 管理员顺带刷新待更新快照（Web 窗口获得焦点即刷新）
            guard phase == .active else { return }
            guard wasActive else {
                wasActive = true
                return
            }
            Task {
                if let fresh = try? await api.authMe(), fresh.username == session?.username {
                    model.update(session: fresh)
                }
                if permissions.isAdmin { await badges.refreshUpdate(api: api) }
            }
        }
        .task(id: permissions.isAdmin) {
            // 成员的媒体库分区要拉一次可见库列表才知道；每个账号只查一次
            guard !permissions.isAdmin, memberHasLibrary == nil else { return }
            let libraries = try? await api.libraryList(scope: "all")
            guard !Task.isCancelled else { return }
            // 拉取失败先给入口：搜索页进去会自己再核一次分区，别让一次网络抖动把入口藏到下次登录
            memberHasLibrary = libraries.map { !$0.isEmpty } ?? true
        }
        .task(id: permissions.isAdmin) {
            guard permissions.isAdmin else { return }
            await FirstFrameGate.wait()
            await badges.run(api: api)
        }
        .task(id: session?.username) {
            // 空闲预热：落地页（媒体库）先显示完，空闲下来再处理还没打开的媒体库首页、订阅首页——
            // 1. 页面预热：用本机快照在背后不可见地画一遍，消化「第一次上屏」的一次性开销（见 PageWarmup）；
            // 2. 静默刷新：页面第一帧用的是快照，这里让快照在切过去之前就换成最新的，切过去后不会再换一遍内容；
            // 3. 首屏图片解码进内存：第一次切过去不再先出占位底、再渐显（见 FirstScreenImages）。
            // 刷新走常驻数据的连接池，不和当前页面抢连接
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let username = session?.username else { return }
            let pending = [MainTab.library, .subscriptions, .discover].filter { tab in
                tab != router.selectedTab && (tab != .subscriptions || permissions.canSubscribe)
            }
            // 一次只预热一个页签：每个在主线程上是一两百毫秒的一整块，分开做、中间留出空档，
            // 不在用户正滑着落地页时连着卡两下
            for tab in pending {
                guard !Task.isCancelled, tab != router.selectedTab else { continue }
                PerfTrace.record("warmup.begin", ["page": tab.rawValue])
                warmupTabs = [tab]
                PerfTrace.afterCommit("warmup.rendered", ["page": tab.rawValue])
                try? await Task.sleep(for: .milliseconds(250))
                warmupTabs = []
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled else { return }

            let quiet = APIClient(server: api.server, token: api.token, session: APIClient.liveSession)
            if pending.contains(.library) {
                await LibraryHomeStore.shared.prefetch(api: quiet, owner: LibraryHomePrefs.ownerKey(api: api, username: username))
            }
            if pending.contains(.subscriptions) {
                SubscriptionsHomeFeed.shared.adopt(owner: SubscriptionsHomeFeed.ownerKey(api: api, username: username))
                async let index: Void = SubscriptionIndex.shared.ensureLoaded(api: quiet, owner: username)
                async let feed: Void = SubscriptionsHomeFeed.shared.refreshIfStale(api: quiet, isAdmin: permissions.isAdmin)
                _ = await (index, feed)
            }
            SessionPrewarm.warmImages(for: pending.filter { $0 != router.selectedTab }, api: api)
        }
        // 预热中切了页签：马上拆掉预热的那份，不和真正要显示的页面抢主线程
        .onChange(of: router.selectedTab) { if !warmupTabs.isEmpty { warmupTabs = [] } }
        .environment(router)
        .environment(feedback)
        .environment(badges)
        .environment(\.api, api)
        .environment(\.permissions, permissions)
        .environment(\.searchAccess, SearchAccess(
            canMedia: permissions.canSubscribe,
            canTorrent: permissions.canSearch,
            canLibrary: permissions.isAdmin || memberHasLibrary == true,
            ready: permissions.isAdmin || memberHasLibrary != nil
        ))
        .tint(Theme.accentStrong)
    }
}

extension MainTabView {
    /// 长按头像页签：弹出切换账号抽屉（已经有弹层开着时不叠第二个）
    private func openAccountSwitcher() {
        guard router.sheet == nil, router.player == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation { showAccountTip = false }
        router.present(.accountSwitcher)
    }

    /// 双击头像页签：切回上一个账号。本机只有一个账号时什么都不做——那只是两下普通的点选
    private func switchToPreviousAccount() async {
        guard model.savedAccountCount > 1, !switchingAccount, router.player == nil else { return }
        switchingAccount = true
        defer { switchingAccount = false }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        do {
            _ = try await model.switchToPreviousAccount()
        } catch AppModel.AccountError.needsPassword {
            // 那个账号的登录已失效：打开切换抽屉，它在那里标着「需要重新登录」，点一下输密码
            feedback.error("那个账号的登录已失效，点它重新输入密码")
            router.present(.accountSwitcher)
        } catch {
            feedback.error(error)
        }
    }

    /// 点开推送通知（docs/design/cloud-push.md §9）：来自当前账号就按 `open` 打开站内路径；来自本机别的账号
    /// 先切过去——主界面按账号整棵重建，新的主界面接着处理同一条（`pendingTap` 这时还留着）
    private func openPushTarget(_ target: PushTapTarget?, permissions: Permissions) {
        guard let target, let server = model.server, let session = model.session else { return }
        if target.login.login == PushLogin(server: server, username: session.username) {
            push.pendingTap = nil
            guard let path = target.openPath else { return }
            router.permissions = permissions // 冷启动时可能抢在 onChange 同步权限之前
            router.open(webPath: path)
            return
        }
        guard let address = target.login.server else {
            push.pendingTap = nil
            return
        }
        // 正在播放时不切账号（切账号会把主界面连同播放器整个重建）：留着，关掉播放器后再切
        guard router.player == nil, !switchingAccount else { return }
        switchingAccount = true
        Task {
            defer { switchingAccount = false }
            do {
                try await model.switchAccount(to: target.login.username, on: address)
            } catch AppModel.AccountError.needsPassword {
                push.pendingTap = nil
                feedback.error("「\(target.login.accountName)」的登录已失效，点它重新输入密码")
                router.present(.accountSwitcher)
            } catch {
                push.pendingTap = nil
                feedback.error(error)
            }
        }
    }

    /// 当前账号能看到的页签，按标签栏上从左到右的顺序（与上面 TabView 的声明顺序一致，
    /// TabBarDotBridge 靠这个顺序找页签）
    static func visibleTabs(_ permissions: Permissions) -> [MainTab] {
        var tabs: [MainTab] = [.library]
        if permissions.canSubscribe { tabs.append(.subscriptions) }
        tabs.append(.discover)
        if permissions.isAdmin { tabs.append(.activity) }
        tabs.append(.more)
        return tabs
    }

    /// 只有图标的页签标签：标题留在 Label 里表明含义，显示时去掉（读屏名字由 Tab 的
    /// `.accessibilityLabel` 给——Label 里的标题不会传给系统标签栏）。图标统一成正方形，见 TabIcon
    private func iconLabel(_ tab: MainTab) -> some View {
        Label { Text(tab.title) } icon: { Image(uiImage: TabIcon.image(tab.systemImage)) }
            .labelStyle(.iconOnly)
    }

    /// 登录 / 切换账号 / 退出后自动切到下一个账号时的首个落点（只定一次）：
    /// - 会话过期前记下的位置（同一身份可进入时）优先还原；
    /// - 否则成员落「媒体库」（Web accessiblePathFor：成员的 / → /library），管理员落「发现」
    ///   （Web 银玻璃手机端 / → /discover/movie）。
    private func land(permissions: Permissions) {
        guard !landed else { return }
        landed = true
        defer { PerfTrace.pageBegan(router.selectedTab.rawValue, trigger: "launch", at: 0) }
        #if DEBUG
        if let tab = DebugLaunch.tab, router.availableTabs.contains(tab) {
            router.selectedTab = tab
            return
        }
        #endif
        // 已经被别处（深链、调试启动路由）导航过就不再抢落点
        guard router.selectedTab == .library, router.paths.values.allSatisfy(\.isEmpty), router.rootParameter == nil else { return }
        if let resume = model.takeResume(), router.availableTabs.contains(resume.tab),
           resume.path.allSatisfy(permissions.allows) {
            router.selectedTab = resume.tab
            router.paths[resume.tab] = resume.path
            return
        }
        // 媒体库是首页：管理员、成员都落在这里（原来管理员落「发现」，2026-09-30 用户调整）
        router.selectedTab = .library
    }
}

/// 一个标签页的导航根：独立导航栈 + 路由映射 + 全局顶栏（右上角搜索）
struct TabRoot<Root: View>: View {
    let tab: MainTab
    @ViewBuilder let root: () -> Root
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack(path: router.path(for: tab)) {
            root()
                .appTopBar(tab: tab)
                .navigationDestination(for: AppRoute.self) { route in
                    route.destination
                }
        }
        .environment(\.perfPage, tab.rawValue)
    }
}

/// 标签栏的页签图标：SF Symbol 裁掉自带留白后，按真实字形外框等比放进同一个正方形。
///
/// 系统按字号排 SF Symbol，各图标外框宽窄不一（书签 15×24pt、房子 27×24、头像 26×26），
/// 并排在底栏里显得大小不齐（2026-09-26 用户反馈）。这里统一成最长边 = `side`，与头像页签
/// （AvatarTabIcon）同尺寸；交出去的是模板图，选中 / 未选中照常由系统染色。
enum TabIcon {
    static let side: CGFloat = AvatarTabIcon.size
    @MainActor private static var cache: [String: UIImage] = [:]

    @MainActor static func image(_ name: String) -> UIImage {
        if let cached = cache[name] { return cached }
        let image = render(name)
        cache[name] = image
        return image
    }

    private static func render(_ name: String) -> UIImage {
        // 系统标签栏会把图标自动换成实心款；自己画的位图要显式取 .fill（没有实心款的用原款）。
        // 字号取成品边长的约 2.5 倍：3 倍屏上仍是缩小绘制、边缘干净；原先按 200pt 画，每个图标要画、扫
        // 四五十万像素，冷启动首帧前五个图标合计约 40ms（模拟器实测）
        let config = UIImage.SymbolConfiguration(pointSize: 64, weight: .medium)
        guard let symbol = UIImage(systemName: "\(name).fill", withConfiguration: config)
                ?? UIImage(systemName: name, withConfiguration: config)
        else { return UIImage() }
        // 先画一张大图，按不透明像素找出字形的真实外框
        let large = UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.withTintColor(.black).draw(at: .zero)
        }
        guard let cg = large.cgImage, let glyph = opaqueBounds(cg).flatMap(cg.cropping(to:)) else { return symbol }
        let width = CGFloat(glyph.width), height = CGFloat(glyph.height)
        let scale = side / max(width, height)
        let rect = CGRect(x: (side - width * scale) / 2, y: (side - height * scale) / 2,
                          width: width * scale, height: height * scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            UIImage(cgImage: glyph).draw(in: rect)
        }.withRenderingMode(.alwaysTemplate)
    }

    /// 位图里不透明像素的外框（像素坐标，原点左上）
    private static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let alpha = data.bindMemory(to: UInt8.self, capacity: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// 标签根页面的顶栏：右上角放大镜，在当前标签里压栈打开搜索首页（结果、详情接着压在同一个栈，
/// 返回一路退回来）。常见 App 的搜索都在右上角（2026-09-26 用户拍板）；原来左上角的头像
/// 挪进了标签栏最右的页签。网页右上角的「+」新建 AI 会话在手机 App 里按用户决定去掉了。
///
/// 在哪个页签搜就先搜那里的内容（同 iOS 音乐的资料库）：发现 / 订阅预选「影视」、媒体库预选「媒体库」、
/// 活动预选「资源」；「我的」不预选，停在搜索页上次停留的模式（2026-09-27 用户拍板）。
///
/// 页面自己的按钮用 `.toolbar` 追加（发现页的筛选、媒体库的 ⋯ 菜单）。
/// 外层注入的 `.topBarTrailing` 会排到页面按钮前面，所以放 `.primaryAction`（固定在最右），
/// 再用固定间隔隔开：页面按钮在左边自成一组，搜索是独立圆钮（媒体库是「▶ ⋯ · 搜索」）。
///
/// 「我的」页只保留扫码钮：
/// 扫电视 / 终端上的登录二维码 → 直达独立的批准页（DeviceApprovalView）。
struct AppTopBar: ViewModifier {
    let tab: MainTab
    @Environment(Router.self) private var router
    @Environment(\.searchAccess) private var searchAccess

    func body(content: Content) -> some View {
        content.toolbar {
            if tab == .more || searchAccess.canOpenSearch {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            if tab == .more {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        router.deviceApproval = DeviceApprovalLaunch(scanFirst: true)
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("扫码批准设备登录")
                    .accessibilityIdentifier("open-scanner")
                }
            }
            // 任一搜索分区可用就给入口（影视 / 资源 / 媒体库，见 SearchAccess.canOpenSearch）
            if tab != .more, searchAccess.canOpenSearch {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        router.push(.searchHome(mode: preferredSearchMode))
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                    .accessibilityIdentifier("open-search")
                }
            }
        }
    }
}

extension AppTopBar {
    /// 各页签进搜索时预选的模式；nil = 沿用搜索页上次停留的模式
    private var preferredSearchMode: SearchVertical? {
        switch tab {
        case .discover, .subscriptions: .media
        case .library: .library
        case .activity: .torrent
        case .more: nil
        }
    }
}

extension View {
    func appTopBar(tab: MainTab) -> some View { modifier(AppTopBar(tab: tab)) }
}

/// 头像徽标：有头像显示图片，否则显示昵称首字
struct AvatarBadge: View {
    let session: API.SessionView?
    var avatarUrl: String?
    var nickname: String?
    var size: CGFloat = 32
    @Environment(\.api) private var api

    var body: some View {
        let url = api.image(avatarUrl ?? session?.avatarUrl, width: ImageWidth.points(size))
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.accentStrong, Theme.accent2], startPoint: .top, endPoint: .bottom))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.75))
            if url != nil {
                RemoteImage(url: url, placeholderSymbol: "person.fill")
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let name = (nickname ?? session?.nickname ?? "").trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return "?" }
        if first.unicodeScalars.first.map({ (0x4E00 ... 0x9FFF).contains($0.value) }) == true { return String(first) }
        return String(name.prefix(2)).uppercased()
    }
}

/// 标签栏最右「头像」页签的图标位图。
///
/// 系统标签栏的页签图标只收位图，并且默认当模板图、按选中色染成单色——头像照片要先画成
/// 圆形位图、以原色（`.alwaysOriginal`）交出去才保得住颜色。画法直接复用 `AvatarBadge`
/// （渐变底 + 昵称首字，没设头像或照片还在下载时就是这一版），照片到手后盖在上面。
enum AvatarTabIcon {
    /// 边长：与其他页签图标的正方形同尺寸（TabIcon.side 取的就是它），与 Instagram 底栏里头像和图标的比例相当
    static let size: CGFloat = 26

    static func render(nickname: String?, photo: UIImage?, scale: CGFloat) -> UIImage? {
        let face = AvatarBadge(session: nil, nickname: nickname, size: size)
            .overlay {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                }
            }
            .clipShape(Circle())
        let renderer = ImageRenderer(content: face)
        renderer.scale = scale
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }
}

extension Theme {
    /// 银蓝暗侧 --accent-2
    static let accent2 = Color(red: 0x9F / 255, green: 0xB0 / 255, blue: 0xC9 / 255)
}

/// 外壳上的角标状态（管理员）：待处理更新（头像页签蓝点，10 分钟轮询）、
/// 活动标签提示（需处理任务 > 有人在看 > 任务进行中，同 Web glass-tab-bar `pickActivityDot`）。
///
/// 任务与观看两份数据源（`tasks` / `media`）也挂在这里、由外壳常驻运行：活动页直接读同一个实例，
/// 全 App 只有一条 `/jobs/stream` SSE、一路下载器轮询、一路播放活动轮询（Web 同样是全站 Provider）。
/// 活动标签的状态点与网页一样按状态换色（红 / 绿 / 蓝），画法见 TabBarDotBridge。
@Observable
final class ShellBadges {
    /// 待更新快照（管理员）；nil 表示没有可用更新
    var pendingUpdate: API.PendingUpdateView?
    var updatePending: Bool { pendingUpdate != nil }
    /// 「更多」里更新行的文案（Web app-update-entry）：应用与模型都有更新时只说应用版本
    var updateLabel: String? {
        guard let pendingUpdate else { return nil }
        if let version = pendingUpdate.appVersion { return "新版本 v\(version)" }
        return pendingUpdate.modelTag.map { "新识别模型 \($0)" }
    }
    /// 任务活动（Job SSE + 下载器快照），活动页任务视角共用
    let tasks = TaskActivityStore()
    /// 媒体库实时活动（8 秒轮询），活动页观看视角共用
    let media = MediaActivityStore()

    /// 需要处理的任务数（红）
    var needsAction: Int { tasks.activity.attentionTotal }
    /// 此刻在播 / 在下载的设备数（绿）
    var watching: Int { media.liveCount }
    /// 进行中的任务数（蓝）
    var running: Int { tasks.activity.activeTotal }

    /// 活动标签的状态点（同网页 glass-tab-bar 的优先级）：有需要处理的任务红、有人在看绿、
    /// 只有进行中的任务蓝；都没有不显示。按优先级只表达当前最该被看见的那一件事。
    /// 用户觉得红底「在看」文字太重，改成小圆点；`label` 给读屏用
    var activityDot: TabBarDotBridge.Dot? {
        #if DEBUG
        // 开发期：-mcActivityDot red|green|blue 强制显示状态点（截图核对用）
        switch UserDefaults.standard.string(forKey: "mcActivityDot") {
        case "red": return .init(color: UIColor(Theme.danger), label: "有需要处理的任务")
        case "green": return .init(color: UIColor(Theme.success), label: "有人正在观看")
        case "blue": return .init(color: UIColor(Theme.info), label: "有任务进行中")
        default: break
        }
        #endif
        if needsAction > 0 { return .init(color: UIColor(Theme.danger), label: "有需要处理的任务") }
        if watching > 0 { return .init(color: UIColor(Theme.success), label: "有人正在观看") }
        if running > 0 { return .init(color: UIColor(Theme.info), label: "有任务进行中") }
        return nil
    }

    /// 头像页签的状态点：有待安装的新版本 / 识别模型时亮蓝点（原先画在左上角头像上，同 Web 头像圆点）
    var moreDot: TabBarDotBridge.Dot? {
        updatePending ? .init(color: UIColor(Theme.info), label: "有可用更新") : nil
    }

    func run(api: APIClient) async {
        // 常驻的 SSE 与轮询走专用连接池，不和页面请求抢连接（见 APIClient.liveSession）
        let live = APIClient(server: api.server, token: api.token, session: APIClient.liveSession)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.tasks.run(api: live) }
            group.addTask { await self.media.run(api: live) }
            group.addTask {
                while !Task.isCancelled {
                    await self.refreshUpdate(api: api)
                    try? await Task.sleep(for: .seconds(600))
                }
            }
        }
    }

    /// 拉一次待更新快照；失败保留上次结果（离线/后端重启时下轮自愈，同 Web）
    func refreshUpdate(api: APIClient) async {
        guard let pending = try? await api.appUpdatePending() else { return }
        await MainActor.run {
            self.pendingUpdate = (pending.appVersion != nil || pending.modelTag != nil) ? pending : nil
        }
    }
}

/// 给系统标签栏的页签挂彩色小圆点（与活动页顶部「观看」旁的状态点差不多大）。
///
/// SwiftUI 的 `.badge` 只能是红底数字/文字；UIKit 的系统空角标（`badgeValue = ""`）是约 18pt 的实心圆，
/// 挂在图标右上角太抢眼（用户反馈），而角标尺寸没有公开接口可调。这里借用系统角标的位置、换掉画法：
/// 角标底色设为透明，角标文字是一个小字号的「●」、文字颜色即状态色——画出来就是图标右上角的一颗小圆点，
/// 标签栏收起/展开、横竖屏时的位置仍由系统排布，不碰任何私有视图。
/// 从视图所在窗口找到标签栏控制器后逐个页签设置。页签只显示图标、系统页签对象上没有标题，
/// 也拿不到 SwiftUI 设的读屏名字，所以按先后顺序对应：`tabs` 必须与 TabView 的声明顺序一致。
struct TabBarDotBridge: UIViewRepresentable {
    struct Dot: Equatable {
        var color: UIColor
        /// 读屏念的状态说明（否则会把「●」念出来）
        var label: String
    }

    /// 标签栏上的页签，从左到右（见 MainTabView.visibleTabs）
    let tabs: [MainTab]
    /// 要挂圆点的页签；不在表里的页签清掉圆点
    let dots: [MainTab: Dot]

    /// 「●」的字号：约合 6pt 直径的圆点（活动页顶部状态点是 6pt）
    private static let dotFontSize: CGFloat = 7.5

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let tabs = tabs, dots = dots
        // 等视图进窗口、标签栏建好之后再设（首次更新时窗口可能还是 nil）
        DispatchQueue.main.async {
            guard let root = view.window?.rootViewController,
                  let tabBarController = Self.findTabBarController(from: root),
                  let items = tabBarController.tabBar.items
            else { return }
            for (item, tab) in zip(items, tabs) {
                guard let dot = dots[tab] else {
                    item.badgeValue = nil
                    item.accessibilityValue = nil
                    continue
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: dot.color,
                    .font: UIFont.systemFont(ofSize: Self.dotFontSize),
                ]
                item.setBadgeTextAttributes(attributes, for: .normal)
                item.setBadgeTextAttributes(attributes, for: .selected)
                item.badgeColor = .clear
                item.badgeValue = "●"
                item.accessibilityValue = dot.label
            }
        }
    }

    private static func findTabBarController(from controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = findTabBarController(from: child) { return found }
        }
        return nil
    }
}

/// 页面预热：还没打开过的媒体库首页、订阅首页，在背后不可见地画一遍再拆掉。
///
/// 为什么：一个页面在这次运行里第一次上屏特别重——SwiftUI 第一次实例化这批视图类型、做协议一致性查找、
/// 排版文字，模拟器实测第一次切到订阅首页主线程要忙约 300ms（第二次只要约 60ms）。这笔一次性开销在
/// 落地页空闲时先消化掉（同「我的」页的输入框预热 AgentComposerWarmup），第一次切过去就接近第二次的速度。
/// 预热的那份页面带着 `\.pageWarmup`：不发请求、不轮询、不记打点，只是画出来。
private struct PageWarmup: View {
    let tabs: [MainTab]

    var body: some View {
        if !tabs.isEmpty {
            ZStack {
                if tabs.contains(.library) { LibraryHomeView() }
                if tabs.contains(.subscriptions) { SubscriptionsView() }
                if tabs.contains(.discover) { DiscoverView(kind: "movie") }
            }
            .environment(\.pageWarmup, true)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
