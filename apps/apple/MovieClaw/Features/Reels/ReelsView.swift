import AVFoundation
import SwiftUI

/// 片段：上下整页滑动，每页从一部电影 / 一部剧里挑出的 30～60 秒（docs/design/reels.md）。
///
/// 版式对齐 Instagram Reels / 抖音（2026-09-30 用户给的参照图）：
/// - 媒体库导航栈里压栈打开，**隐藏底部标签栏**（2026-09-30 用户要求：标签栏高度改不了，占着底部；有了返回键
///   就不再需要靠页签回去）；左上是系统的液态玻璃返回键（2026-09-30 用户要求：不带返回键时有人不知道怎么回去）；
///   正中是**在播这一条的片名 + 第二行年份**，一个玻璃胶囊，点了去这部片的详情页（同「照片」App 顶部的
///   地点胶囊；没有在播的条目时只写页名「片段」、不能点）；右上一个玻璃胶囊「全部 ⌄」，点开选「全部」或
///   某个类型；这一页锁竖屏，转手机不会把信息流转横；
/// - 纯黑底，影片居中成一条 16:9 的横带；没出第一帧前横带里放横版剧照（转圈 + 实时加载速度，剧照模糊
///   铺满整页），出画后淡出成视频；没有剧照的片垫服务端抓的起点帧；出过画面后缓冲也转圈并带加载速度；
/// - 手势复用播放器页的 `PlayerGestureLayer`：点页面任意空白处暂停 / 继续（同抖音），双击左右三分之一
///   ∓10 秒，长按 2 倍速；竖滑不调亮度音量，留给翻页；横滑不拖进度（2026-09-30 用户要求：小横带里横滑定位
///   体验很差，拖进度只在「全屏观看」里有）。
///   暂停时横带正中出播放标记，放到片段终点停下、再点重播；
/// - 横带下方一个描边小胶囊「全屏观看」（TikTok 横屏视频的做法）：这一段交给正片播放器的片段模式
///   横屏放（`PlaybackClip`）——手势、控制条、换音轨字幕与正片完全一样，时间轴只算这一段；
///   退出全屏回到这里，从刚才看到的地方接着放；画质胶囊在它左边。这一行**播放时调暗**（2026-09-30 用户要求：
///   播放时不该抢看片的注意力），起播、播放、缓冲都暗，只有暂停、放完、放不出时恢复，见 `ReelPage.controlsDimmed`；
/// - 右下角一列**无底色**的白色图标按钮（不用毛玻璃，和画面融在一起，带投影保证亮画面上也看得清）：
///   收藏、详情、已看、分享；
/// - 左下角只放导演与简介（片名、年份挪到了左上角）：导演（剧集是主创，对应 TikTok / Instagram 的作者行，
///   点了进人物页）、三行简介（剧集前面是「第 N 季第 N 集「集名」」，放不下就「展开」）；
/// - 最底下一条细进度线（按片段算，不按整部片）；不写时间，平时也不显示，只在暂停时出现
///   （2026-09-30 用户要求，同抖音）。
///
/// 「详情」：去媒体库条目页看这部片的详细信息（剧集定位到这一集），返回后这一条接着放。
/// 想看整部：全屏里点「看全片」，或在详情页里播放。
struct ReelsView: View {
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ReelsStore?
    @State private var visible = false
    @State private var sharing: API.ReelItemView?
    /// 最近一次竖屏时的整页尺寸。进播放器页（全屏观看、播放）时整页会跟着转横，翻页区要是按横屏重排，
    /// 转回竖屏后滚动位置对不上原来那一条（模拟器实测从第二条跳到了第三条）。所以每页始终按竖屏尺寸排：
    /// 横屏期间翻页区被播放器页整个盖住，看不出差别
    @State private var portraitPage: PageGeometry?

    var body: some View {
        GeometryReader { geo in
            let current = PageGeometry(size: geo.size, insets: geo.safeAreaInsets)
            let page = portraitPage ?? current
            ZStack {
                Color.black
                // 第一页还没挑出来（刚进来、换了筛选、点了重试）：转圈；挑完了还是空、出错、服务器太旧才是空态。
                // 也盖住 store 还没建好、start 还没跑的那一瞬（否则会先闪一下「片库里还没有能刷的片子」）
                if store.map(Self.waitingForFirstPage) ?? true {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在挑片段…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                } else if let store {
                    if store.items.isEmpty {
                        emptyState(store)
                    } else {
                        pager(store, size: page.size, insets: page.insets)
                    }
                }
            }
            .ignoresSafeArea()
            .onChange(of: current, initial: true) { _, now in
                if now.size.height > now.size.width { portraitPage = now }
            }
        }
        .background(Color.black.ignoresSafeArea())
        // 标题不用系统的标题：系统标题只是文字、点不了。正中放一个两行的玻璃胶囊（片名 / 年份），点了去详情页
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        // 返回键带回了 iOS 26 的「页面任意处右滑返回」：刷片时手指稍一偏就退出了，这一页只关掉它，保留左边缘右滑返回
        .background(ContentPopGestureDisabler())
        .toolbar {
            ToolbarItem(placement: .principal) {
                ReelTitle(item: store?.titleItem, width: titleWidth) {
                    if let store, let item = store.titleItem { openDetail(item, store: store) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { ReelFilterMenu(store: store) }
        }
        .preferredColorScheme(.dark)
        .task {
            if store == nil { store = ReelsStore(api: api, metered: NetworkCost.shared.isMetered) }
            await store?.start()
        }
        .onAppear {
            visible = true
            UIApplication.shared.isIdleTimerDisabled = true
            // 音频会话激活在后台线程做（与播放器页同一做法）：主线程上同步激活要几十到上百毫秒，
            // 正好压在第一条建引擎、装载之前
            Task.detached {
                let audio = AVAudioSession.sharedInstance()
                try? audio.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
                try? audio.setActive(true)
            }
            // 信息流锁竖屏：转手机不该把整页转横（横着看走「全屏观看」）
            PlayerOrientation.request(landscape: false)
            // 从全屏观看回来：接着刚才看到的地方放
            let returned = router.clipReturn
            router.clipReturn = nil
            store?.resume(returning: returned)
        }
        .onDisappear {
            visible = false
            // 被播放器页盖住时方向归播放器页管（它关掉时会解锁）；真正离开这一页才解开竖屏锁
            if router.player == nil { PlayerOrientation.release() }
            store?.suspend()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // 播放器页是根部的全屏弹层：盖上来时收掉刷片的引擎，收起后当前这条接着放（onAppear）
        .onChange(of: router.player == nil) { _, closed in
            if closed {
                if visible {
                    PlayerOrientation.request(landscape: false)
                    let returned = router.clipReturn
                    router.clipReturn = nil
                    store?.resume(returning: returned)
                }
            } else {
                store?.suspend()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store?.pause() }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let item = sharing {
                LibraryShareSheet(
                    target: .item(libraryId: item.title.libraryId, mediaItemId: item.title.mediaItemId),
                    title: item.title.name, kind: item.title.kind, year: item.title.year,
                    posterUrl: item.title.posterUrl
                )
                .sheetFeedback()
            }
        }
    }

    /// 正中标题胶囊的宽度（固定）：标题居中，两边各让出右上角筛选键那么宽（它比左边的返回键宽）
    private var titleWidth: CGFloat {
        let width = portraitPage.map { $0.size.width + $0.insets.leading + $0.insets.trailing } ?? 402
        return max(140, width - 2 * 112)
    }

    /// 去这部片的详情页（剧集定位到这一集）：右下角「详情」与顶部标题共用；这一条记为转去详情、回来接着放
    private func openDetail(_ item: API.ReelItemView, store: ReelsStore) {
        store.openDetail(item)
        router.push(.libraryItem(libraryId: item.title.libraryId, itemId: item.title.mediaItemId,
                                 season: item.title.episode?.season, episode: item.title.episode?.episode))
    }

    // MARK: - 翻页

    private func pager(_ store: ReelsStore, size: CGSize, insets: EdgeInsets) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(store.items, id: \.id) { item in
                    ReelPage(
                        item: item, store: store, isCurrent: item.id == store.currentID, insets: insets,
                        canCreateShareLink: permissions.isAdmin,
                        onOpenDetail: { openDetail(item, store: store) },
                        onShare: {
                            store.pause()
                            sharing = item
                        },
                        onOpenPerson: { router.push(.person(tmdbId: $0)) },
                        onFullscreen: { openFullscreen(store) }
                    )
                    .frame(width: size.width + insets.leading + insets.trailing,
                           height: size.height + insets.top + insets.bottom)
                }
                if store.exhausted {
                    endPage(store)
                        .frame(width: size.width + insets.leading + insets.trailing,
                               height: size.height + insets.top + insets.bottom)
                        .id(ReelsStore.endPageID)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding(get: { store.currentID }, set: { store.currentID = $0 }))
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, phase in
            // 滑动停稳才换播放器：拖动途中 currentID 会跟着变，不能每变一次就起一个引擎
            if phase == .idle { store.settle() }
        }
    }

    /// 「全屏观看」：这一段交给播放器页的片段模式，从当前位置接着放，播放器页自己转横。
    /// 不做上滑转场：直接盖上黑底的播放器页再转横，不然转场途中会露出横着排的信息流
    private func openFullscreen(_ store: ReelsStore) {
        guard let request = store.fullscreenRequest() else { return }
        store.suspend()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { router.play(request) }
    }

    // MARK: - 刷到底

    /// 末尾一页：没有更多了；开了片段预切、还没切完时补一句其余的还在切
    private func endPage(_ store: ReelsStore) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("没有更多了")
                .font(.headline)
                .foregroundStyle(.white)
            if let clips = store.clips, clips.state != "done", clips.ready < clips.total {
                Text("其余 \(clips.total - clips.ready) 部的片段还在预切，晚点再来")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - 空态

    /// 服务器版本比 App 旧、还没有片段功能（`/reels` 404）：说清楚是服务器要升级，不是出错。
    /// 超管能直接去「更新与维护」升级；成员没有升级权限，请管理员升级
    private var serverOutdatedNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text("服务器需要升级")
                .font(.headline)
                .foregroundStyle(.white)
            Text(permissions.isAdmin
                 ? "片段是新功能，当前服务器版本还不支持。把服务器升级到最新版后就能使用。"
                 : "片段是新功能，当前服务器版本还不支持。请联系管理员把服务器升级到最新版。")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if permissions.isAdmin {
                Button("去更新服务器") { router.push(.settingsSection(.app)) }
                    .buttonStyle(.glass)
                    .padding(.top, 4)
                    .accessibilityIdentifier("reels-server-update")
            }
        }
        .accessibilityIdentifier("reels-server-outdated")
    }

    private static func waitingForFirstPage(_ store: ReelsStore) -> Bool {
        store.items.isEmpty && !store.serverOutdated && store.errorMessage == nil && !store.exhausted
    }

    private func emptyState(_ store: ReelsStore) -> some View {
        VStack(spacing: 14) {
            if store.serverOutdated {
                serverOutdatedNotice
            } else if let message = store.errorMessage {
                Text(message)
                Button("重试") { Task { await store.retry() } }
                    .buttonStyle(.glass)
            } else if let clips = store.clips, clips.state != "done", clips.ready < clips.total {
                // 开了片段预切、这些条件下一部都还没切好
                Text("片段正在预切，已完成 \(clips.ready) / \(clips.total)")
                Text(clips.state == "paused" ? "有人在观看，预切暂停中，稍后再来" : "稍后再来就能刷了")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            } else if !store.filter.isEmpty || store.kind != nil {
                Text("这些条件下还没有能刷的片子")
                Button("清空条件") { store.applyFilter(LibraryFilter(), kind: nil) }
                    .buttonStyle(.glass)
            } else {
                Text("片库里还没有能刷的片子")
                Text("目前支持 MKV / MP4 的电影与剧集")
                    .font(.caption)
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 停在片段页期间关掉导航栈的「内容区右滑返回」（iOS 26 起整页任意处右滑都能返回）。
///
/// 片段页上下刷片、点按、长按都在画面上，右滑会被系统当成返回、一划就退回媒体库（2026-09-30 模拟器实测）。
/// 左边缘右滑返回（`interactivePopGestureRecognizer`）照常保留，这是 iOS 的惯例。
/// 开关挂在整个导航控制器上，所以离开这一页（返回、压栈进详情）时要还原，别的页面不受影响
private struct ContentPopGestureDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true
        }
    }
}

private struct PageGeometry: Equatable {
    var size: CGSize
    var insets: EdgeInsets
}

/// 片段的一页
private struct ReelPage: View {
    let item: API.ReelItemView
    let store: ReelsStore
    let isCurrent: Bool
    let insets: EdgeInsets
    let canCreateShareLink: Bool
    let onOpenDetail: () -> Void
    let onShare: () -> Void
    let onOpenPerson: (Int) -> Void
    let onFullscreen: () -> Void

    @Environment(\.api) private var api
    /// 简介展开了
    @State private var expanded = false
    /// 简介收起（三行）时的高度与不限行数时的高度：后者更高就是放不下，给「展开」
    @State private var captionShownHeight: CGFloat = 0
    @State private var captionFullHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let bandHeight = width * 9 / 16
            // 横带的中心放在屏幕 46% 高处（参照图：略高于正中，给底部信息留地方）
            let bandCenter = geo.size.height * 0.46
            ZStack(alignment: .bottom) {
                Color.black
                if waitingForFrame, item.title.backdropUrl != nil {
                    stillBackdrop
                        .transition(.opacity)
                }
                videoBand(width: width, height: bandHeight)
                    .position(x: width / 2, y: bandCenter)
                // 手势与播放器页同一个手势层：轻点暂停、双击左右 ∓10 秒、长按 2 倍速；横滑不拖进度（只在全屏里有）；
                // 竖滑不认领（关掉调亮度 / 音量），整次交给外层翻页。垫在按钮、简介下面，它们自己响应点击
                PlayerGestureLayer(
                    enabled: isCurrent,
                    canHold: isCurrent && store.playerState == .playing,
                    adjusts: false,
                    scrubs: false,
                    onTap: { store.handleTap(xRatio: $0, isDouble: $1) },
                    onScrub: { _, _ in },
                    onAdjust: { _, _, _ in },
                    onHold: { store.handleHold(began: $0) }
                )
                if isCurrent {
                    gestureHUD(bandTop: bandCenter - bandHeight / 2)
                        .frame(width: width, height: bandHeight)
                        .position(x: width / 2, y: bandCenter)
                    // 卡顿换画质的提议、转码退回原画的提示：横带上方，不挡画面
                    let promptArea = bandCenter - bandHeight / 2 - 12
                    qualityPrompts
                        .padding(.horizontal, Theme.pagePadding)
                        .frame(width: width, height: promptArea, alignment: .bottom)
                        .position(x: width / 2, y: promptArea / 2)
                }
                if !expanded {
                    // 横带下方一行：画质在左、全屏观看在右（2026-09-30 用户调整：原来画质压在横带右下角，看着怪）
                    HStack(spacing: 10) {
                        qualityMenu
                        fullscreenButton
                    }
                    // 只改亮度不隐藏：按钮始终在原位、暗着也能点。调暗靠降文字与描边的颜色（`controlsAlpha`），
                    // 不能给整行套 .opacity：透明度不是 1 时这行按钮收不到点击，点击全落到下面的手势层变成暂停（模拟器实测）
                    .animation(.easeInOut(duration: 0.3), value: controlsDimmed)
                    .position(x: width / 2, y: bandCenter + bandHeight / 2 + 28)
                }
                VStack(spacing: 12) {
                    HStack(alignment: .bottom, spacing: 12) {
                        info
                        actions
                    }
                    ReelProgressRow(item: item, player: player, visible: isCurrent && store.playerState == .paused)
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, insets.bottom + 10)
            }
            .animation(.easeOut(duration: 0.25), value: waitingForFrame)
        }
        .onChange(of: isCurrent) { _, current in
            if !current { expanded = false }
        }
    }

    /// 横带下方按钮该不该暗：只有停下来（暂停、放完、放不出）时亮，其余一律暗——加载、起播、播放、缓冲都算
    /// 「在看」（2026-09-30 用户要求：只要在起播 / 播放就暗，不等出画、不延迟）。不是当前这条的页也暗：
    /// 滑过来时它马上就要起播，亮着滑进来再变暗会闪一下
    private var controlsDimmed: Bool {
        guard isCurrent else { return true }
        switch store.playerState {
        case .paused, .ended, .failed: return false
        case .loading, .buffering, .playing: return true
        }
    }

    /// 横带下方按钮的亮度系数：暗时 30%（2026-09-30 用户定），乘到文字与描边的颜色上
    private var controlsAlpha: Double { controlsDimmed ? 0.3 : 1 }

    /// 这一条的播放器：当前这条，或预起好的下一条（滑动途中下一页就是它的第一帧，不是封面）
    private var player: ReelPlayer? { store.player(for: item) }

    // MARK: 加载中：剧照

    /// 还没出画（2026-09-30 用户要求：片库有剧照，比服务端抓的起点帧更好认）：横带里先放这部片的横版剧照，
    /// 上面转圈 + 实时加载速度，剧照模糊铺满整页；出第一帧后淡出，原地换成视频（剧照也是 16:9，横带不跳）。
    /// 预起好的条目滑过去就有画面，看不到剧照；只有现建引擎、要等的那几条才看到。
    /// 没有剧照的片垫服务端抓的起点帧；放不出来时收起，露出横带里的失败说明
    private var waitingForFrame: Bool {
        !store.frameReady(for: item) && !(isCurrent && store.playerState.isFailed)
    }

    /// 铺底必须按页面尺寸裁：填满模式的图比屏幕宽，直接放进 ZStack 会把整页撑宽，
    /// 右下角那列按钮被挤出屏幕（真机上看就是「加载时按钮不见了」）
    private var stillBackdrop: some View {
        Color.clear
            .overlay {
                // opaque：边缘按原图延展再模糊。默认模糊在图的边缘渐隐成透明，剧照上下边正好是页面上下边，
                // 底部简介区会透出一圈黑底（真机上看是「黑边、黑色暗影」）
                RemoteImage(url: store.stillURL(for: item))
                    .blur(radius: 40, opaque: true)
                    .overlay(Color.black.opacity(0.5))
            }
            .clipped()
            .allowsHitTesting(false)
    }

    /// 横带里的占位图：剧照铺满横带；没有剧照时是起点帧（按原比例放）
    @ViewBuilder
    private var still: some View {
        RemoteImage(url: store.stillURL(for: item), contentMode: item.title.backdropUrl == nil ? .fit : .fill)
    }

    /// 转圈 + 实时加载速度（同播放器页 `PlayerBusyView` 的「↓ 3.2 MB/s」）
    private var loadingIndicator: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            if let speed = store.speedLabel {
                Text("↓ \(speed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
        .accessibilityIdentifier("reels-loading")
    }

    // MARK: 手势读数

    /// 长按倍速在横带上方（与播放器页同一种玻璃胶囊 `PlayerHUD`）
    @ViewBuilder
    private func gestureHUD(bandTop: CGFloat) -> some View {
        ZStack {
            if store.holdSpeedActive {
                PlayerHUD {
                    Text("2× 快进中").monospacedDigit()
                    Image(systemName: "forward.fill")
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
                .accessibilityIdentifier("reels-hold-speed")
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 画面

    private func videoBand(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color.black
            // 等画面时垫剧照（见 `waitingForFrame`）；出画后收掉，免得从视频的黑边里透出来
            if waitingForFrame {
                still
                    .overlay(Color.black.opacity(isCurrent ? 0.3 : 0))
                    .transition(.opacity)
            }
            if let player {
                EngineSurface(engineView: player.core.view)
                    .id(ObjectIdentifier(player))
                    .opacity(store.frameReady(for: item) ? 1 : 0)
            }
            overlay
        }
        .frame(width: width, height: height)
        .clipped()
        // 读屏：横带就是暂停 / 继续键（明眼用户点页面任意处，见 body）
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isCurrent && store.playerState == .playing ? "暂停" : "播放")
        .accessibilityAction { if isCurrent { store.togglePause() } }
        .accessibilityIdentifier("reels-video")
    }

    @ViewBuilder
    private var overlay: some View {
        if isCurrent {
            switch store.playerState {
            case .loading where !store.firstFrameShown, .buffering:
                loadingIndicator
            case .paused:
                ReelCenterGlyph(symbol: "play.fill")
            case .ended:
                ReelCenterGlyph(symbol: "arrow.counterclockwise")
            case let .failed(message):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("这一段放不出来，往下滑换一条")
                        .font(.footnote)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(2)
                }
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 24)
            default:
                EmptyView()
            }
        }
    }

    // MARK: 画质

    /// 画质胶囊：与「全屏观看」同一行、同一种描边样式，写着当前档（原画 / 720p），点开选档。
    /// 按家里 / 外网记（`ReelsQuality`），竖屏与全屏共用；选了当前这条从刚才的位置按新画质重开
    private var qualityMenu: some View {
        Menu {
            Picker("画质", selection: Binding(get: { store.quality }, set: { store.selectQuality($0) })) {
                ForEach(ReelsQuality.options) { option in
                    Text(option.label).tag(option.maxHeight)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(ReelsQuality.label(store.quality))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92 * controlsAlpha))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .overlay(Capsule().stroke(.white.opacity(0.35 * controlsAlpha), lineWidth: 1))
            .contentShape(Capsule())
        }
        .accessibilityLabel("画质：\(ReelsQuality.label(store.quality))")
        .accessibilityIdentifier("reels-quality")
    }

    @ViewBuilder
    private var qualityPrompts: some View {
        if let offer = store.qualityOffer {
            PlayerQualityOfferView(offer: offer, accept: { store.acceptQualityOffer() },
                                   dismiss: { store.dismissQualityOffer() })
                .transition(.opacity)
        } else if let notice = store.notice {
            PlayerHUD { Text(notice) }
                .transition(.opacity)
        }
    }

    /// 横带下方的「全屏观看」：描边小胶囊（不用毛玻璃，与右下角按钮同一种「融在画面里」的做法）
    private var fullscreenButton: some View {
        Button(action: onFullscreen) {
            Label("全屏观看", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92 * controlsAlpha))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(Capsule().stroke(.white.opacity(0.35 * controlsAlpha), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 加载中、滑动途中也照常显示（2026-09-30 用户要求：按钮别忽隐忽现）；还没有播放器时点了不动
        // （`ReelsStore.fullscreenRequest` 没有当前播放器返回 nil）
        .accessibilityIdentifier("reels-fullscreen-button")
    }

    // MARK: 右下角按钮

    private var actions: some View {
        let favorite = store.isFavorite(item)
        let played = store.isPlayed(item)
        let progress = played ? nil : store.progressPercent(item)
        return VStack(spacing: 18) {
            ReelActionButton(symbol: favorite ? "heart.fill" : "heart", title: "收藏",
                             tint: favorite ? Color(red: 1, green: 0.27, blue: 0.35) : .white) {
                Task { await store.toggleFavorite(item) }
            }
            .accessibilityValue(favorite ? "已收藏" : "未收藏")
            .accessibilityIdentifier("reels-favorite")
            // 详情：刷到感兴趣的片，最常做的是去条目页看看详细信息（2026-09-30 用户要求，替换原来的「播放」）。
            // 图标用胶片：info.circle 在手机上像叹号，读成「提示」。胶片是横向宽矩形，同字号下比心形、
            // 对勾圈、箭头都显大，缩到 21pt 视觉上才一样重（2026-09-30 用户确认）
            ReelActionButton(symbol: "film", title: "详情", symbolSize: 21, action: onOpenDetail)
                .accessibilityIdentifier("reels-detail")
            // 已看跟着真实观看进度画（2026-09-30 用户要求）：没看完时是暗圈，看了多少白色弧就描多少
            // （没看过 = 一圈暗的）；看完是绿色实心。没看过不用亮白整圈：那样和「快看完」分不开
            ReelActionButton(symbol: "checkmark.circle.fill", title: "已看",
                             tint: played ? Theme.success : .white,
                             progress: played ? nil : Double(progress ?? 0) / 100) {
                Task { await store.togglePlayed(item) }
            }
            .accessibilityValue(played ? "已看过" : progress.map { "看到 \($0)%" } ?? "没看过")
            .accessibilityIdentifier("reels-played")
            if canCreateShareLink {
                ReelActionButton(symbol: "arrowshape.turn.up.right", title: "分享", action: onShare)
                    .accessibilityIdentifier("reels-share")
            } else {
                ShareLink(item: shareText) {
                    ReelActionLabel(symbol: "arrowshape.turn.up.right", title: "分享", tint: .white)
                }
                .accessibilityIdentifier("reels-share")
            }
        }
    }

    private var shareText: String {
        var text = "《\(item.title.name)》"
        if let year = item.title.year { text += "（\(year)）" }
        if let episode = item.title.episode { text += " 第 \(episode.season) 季第 \(episode.episode) 集" }
        return text
    }

    // MARK: 左下角信息

    /// 只放导演与简介（片名、年份在左上角）：导演一行、简介三行
    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.title.directors.isEmpty { directorRow }
            if let caption { captionView(caption) }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            // 简介展开后可能往上压到画面：垫一层渐暗，字才看得清。等画面时底下是已经压暗的模糊剧照，
            // 不用再垫（垫了就是一块黑影）；出画后底下是黑底，渐暗只在压到视频的那一截看得出来
            if expanded, !waitingForFrame {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .padding(.horizontal, -Theme.pagePadding)
                    .padding(.top, -40)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 导演（剧集是主创）：头像 + 名字 + 身份，对应 Instagram「头像 · 作者名」那一行
    private var directorRow: some View {
        let people = item.title.directors
        let lead = people[0]
        let role = item.title.kind == "tv" ? "主创" : "导演"
        return Button {
            if let id = lead.tmdbPersonId { onOpenPerson(id) }
        } label: {
            HStack(spacing: 8) {
                // 32pt（原来 24pt 只比名字那行字高一点，显小，2026-09-30 用户反馈；同 Instagram Reels 作者头像）
                RemoteImage(url: api.image(lead.avatarUrl, width: ImageWidth.points(32)), placeholderSymbol: "person.fill")
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                Text(people.map(\.name).joined(separator: " / "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(role)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .disabled(lead.tmdbPersonId == nil)
        .accessibilityLabel("\(role)：\(people.map(\.name).joined(separator: "、"))")
        .accessibilityIdentifier("reels-director")
    }

    /// 简介：剧集前面是「第 1 季第 2 集「集名」」（季集放在这里，左上角只写片名和年份），优先用分集简介
    private var caption: (text: Text, plain: String)? {
        let body = (item.title.episode?.overview ?? item.title.overview).flatMap { $0.isEmpty ? nil : $0 }
        guard let episode = item.title.episode else {
            return body.map { (Text($0), $0) }
        }
        var head = "第 \(episode.season) 季第 \(episode.episode) 集"
        if let name = episode.name, !name.isEmpty { head += "「\(name)」" }
        guard let body else { return (Text(head).fontWeight(.semibold), head) }
        return (Text("\(Text(head).fontWeight(.semibold))\(body)"), head + body)
    }

    /// 简介收起时的行数
    private static let captionLines = 3

    /// 三行放不下（不限行数时更高）
    private var truncated: Bool { captionFullHeight > captionShownHeight + 1 }

    /// 收起时三行（2026-09-30 用户要求：隐藏标签栏后底部空出来了，原来两行）；放不下才在最后一行末尾盖一个
    /// 「展开」（放得下就原样显示），点开最多八行
    private func captionView(_ caption: (text: Text, plain: String)) -> some View {
        Group {
            if expanded {
                Text("\(caption.text)  \(Text("收起").fontWeight(.semibold))")
                    .lineLimit(8)
            } else {
                caption.text
                    .lineLimit(Self.captionLines)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { captionShownHeight = $0 }
                    // 不限行数时有多高：比三行高就是放不下
                    .background(alignment: .topLeading) {
                        caption.text
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { captionFullHeight = $0 }
                    }
                    // 放不下时最后一行末尾让出一段：原文在这段渐隐成透明（不是盖一块渐黑的底——加载时底下是
                    // 模糊剧照，黑块会露出来），「展开」写在让出的位置上
                    .mask {
                        ZStack(alignment: .bottomTrailing) {
                            Rectangle()
                            if truncated {
                                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 76, height: captionShownHeight / CGFloat(Self.captionLines))
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if truncated {
                            Text("展开").fontWeight(.semibold)
                        }
                    }
            }
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
        // 三行放得下就没什么可展开的：点在简介上与点页面别处一样是暂停 / 继续
        .allowsHitTesting(expanded || truncated)
        .accessibilityElement()
        .accessibilityLabel(caption.plain)
        .accessibilityHint(expanded ? "收起简介" : "展开简介")
        .accessibilityIdentifier("reels-caption")
    }
}

/// 顶部正中的标题胶囊：第一行在播这一条的片名、第二行年份（2026-09-30 用户要求，参照「照片」App 选中照片后
/// 顶部的地点胶囊），点了去详情页。没有在播的条目（加载中、空态）时只写「片段」、不能点。
/// 胶囊**固定宽度**、占满返回键与筛选键之间：宽度跟着片名走的话，换条时短名到长名胶囊一下撑开还带回弹
/// （2026-09-30 用户反馈），固定后换条只换文字，长片名在里面截断
private struct ReelTitle: View {
    let item: API.ReelItemView?
    let width: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 1) {
                Text(item?.title.name ?? "片段")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if let year = item?.title.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: item?.id)
            .padding(.horizontal, 14)
            // 固定尺寸：工具栏里不固定的话胶囊会被按内容挤窄
            .frame(width: width, height: 44)
            // 工具栏正中的位置系统不给玻璃底，自己套一个，高度与两侧的返回键、筛选胶囊一致
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
        .accessibilityLabel([item?.title.name ?? "片段", item?.title.year.map(String.init)].compactMap { $0 }.joined(separator: "，"))
        .accessibilityHint(item == nil ? "" : "查看详情")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("reels-title")
    }
}

/// 细线与时间都按**这一段**算：「这一段放到哪 / 这一段多长」（0:12 / 0:45），与全屏播放器的片段模式一致——
/// 显示整部片的片长会让人以为在看整部（2026-09-30 用户要求）
struct ReelProgressRow: View {
    let item: API.ReelItemView
    let player: ReelPlayer?
    /// 显示与否：平时不显示，只在暂停时淡入（2026-09-30 用户要求，同抖音）
    var visible = true

    var body: some View {
        // 只留一条细进度线，不写时间（2026-09-30 用户要求：竖屏刷片看个大概进度就够了）；时间只给读屏。进度用计时器的时刻显式重算、按比例横向缩放画出来：原来靠旁边
        // 那行时间文字每 0.25 秒一变带着整行重画，去掉文字后 GeometryReader 里的宽度不再跟着刷新
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let value = progress(at: context.date)
            Capsule().fill(.white.opacity(0.22))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.9))
                        .scaleEffect(x: max(0.001, value), y: 1, anchor: .leading)
                        .opacity(value > 0.002 ? 1 : 0)
                }
                .frame(height: 2)
                .accessibilityElement()
            .accessibilityLabel("片段进度")
                .accessibilityValue(timeText)
                .accessibilityIdentifier("reels-time")
        }
        .frame(height: 14)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: visible)
        .allowsHitTesting(false)
    }

    /// `date` 只用来让每个计时刻都重算一次（值取自播放器的当前位置）
    private func progress(at date: Date) -> Double {
        _ = date
        return player?.progress ?? 0
    }

    private var timeText: String {
        let start = Double(item.segment.startMs) / 1000
        let total = Double(item.segment.endMs - item.segment.startMs) / 1000
        let elapsed = min(max(0, (player?.position ?? start) - start), total)
        return "\(Formatters.clock(elapsed)) / \(Formatters.clock(total))"
    }
}

/// 画面正中的暂停 / 重播标记
struct ReelCenterGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 36, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.5), radius: 8)
    }
}

/// 右下角的按钮：白色图标 + 小字，无底色（不用毛玻璃，和画面融在一起），带投影保证亮画面上也看得清
private struct ReelActionButton: View {
    let symbol: String
    let title: String
    var tint: Color = .white
    /// 0～1：图标画成描出进度弧的对勾圈（「已看」按钮没看完时），nil = 照常画 `symbol`
    var progress: Double?
    /// 图标字号：宽扁的符号要小一号，一列按钮视觉上才一样重
    var symbolSize: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ReelActionLabel(symbol: symbol, title: title, tint: tint, progress: progress, symbolSize: symbolSize)
        }
        .buttonStyle(.plain)
    }
}

private struct ReelActionLabel: View {
    let symbol: String
    let title: String
    let tint: Color
    var progress: Double?
    var symbolSize: CGFloat = 26

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let progress {
                    // 与 checkmark.circle 同尺寸：暗圈打底，白色弧从 12 点方向顺时针描到看到的位置
                    ZStack {
                        Circle().stroke(.white.opacity(0.35), lineWidth: 2)
                        Circle().trim(from: 0, to: progress)
                            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(width: 24, height: 24)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize, weight: .regular))
                }
            }
            .frame(height: 30)
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(tint)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        .frame(width: 52)
        .contentShape(Rectangle())
    }
}
