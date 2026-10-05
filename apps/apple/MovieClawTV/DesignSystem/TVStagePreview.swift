import AetherCore
import SwiftUI

/// 大图预告（docs/design/tvos-app.md §3.5，同 Netflix / 系统 Apple TV App）：首页首屏与详情页的大图停留一会儿，
/// 剧照原地换成一段片段，片名、简介、按钮都不动；放完淡回剧照。
///
/// - **放哪一段**由服务端定（`GET /reels/preview/{id}`）：首页从续播点往前倒 30 秒放到续播点（帮人回忆、不剧透），
///   详情页放刷片挑好的那一段（剧集固定第二集）。放法与刷片一样，用同一个 `ReelPlayer` 从原片中间起播，不写观看记录；
/// - **节奏**：大图换到一部就开始计停留，同时取片段地址、补下起点附近的字节、把播放器装载到起点停着；
///   停满 `dwell` 秒且装好了才开播——画面淡入 0.9 秒，声音 1.5 秒内从 0 渐入（原片中间常是一句对白或一声爆炸）；
/// - **跟着「大图上是哪一部」走，不跟页面走**：从首页按「详情」进同一部，详情页接过同一个播放器，视频不断；
///   换了一部才拆掉重来。同一时刻最多一个预告播放器（4K 杜比视界一个就一百多 MB）；
/// - **看不见就停**：大图滚走（详情页往下看分集、首页往下看别的行）暂停并淡出，回来接着放；
///   进正片播放器、退到后台直接拆掉，回来重新取（续播点变了，首页要回忆的是刚看到的地方）；
/// - 放不了（原盘、strm、读不出索引、出错）就一直是剧照，不提示。
@MainActor
@Observable
final class TVStagePreview {
    static let shared = TVStagePreview()

    /// 停留多久开播（2026-10-05 用户在高保真 Demo 里定的默认值）
    static let dwell: Duration = .seconds(2)
    /// 大图换到一部之后多久才建播放器：一路按方向键划过去时只取地址、不建引擎
    static let engineDelay: Duration = .milliseconds(500)

    enum Source: String {
        /// 首页：续播点往前倒 30 秒放到续播点
        case resume
        /// 详情页：刷片挑好的那一段
        case highlight
    }

    struct Request: Equatable {
        let mediaItemId: Int
        let source: Source
        var season = 0
        var episode = 0
    }

    /// 拆掉播放器、回来重新取的打断
    enum Interruption: Hashable {
        case player
        case background
    }

    /// 大图上是哪一部（条目 id）；nil = 没有页面在用
    private(set) var key: Int?
    /// 预告的画面（引擎视图）；还没建播放器为 nil
    private(set) var engineView: UIView?
    /// 视频该盖在剧照上了：开播且出了画面、没放完、大图看得见
    private(set) var showing = false
    /// 正挂着引擎画面的那一层（`TVStagePreviewLayer`）：首页进详情时两页的大图都在，后出现的接过画面
    private(set) var surfaceOwner: UUID?

    @ObservationIgnored private var api: APIClient?
    /// 这一轮放的是哪一段
    @ObservationIgnored private var current: Request?
    /// 在用大图的页面与各自要放的那一段，最近出现的在后。打断之后按最后那一页的规则重新开始
    @ObservationIgnored private var pages: [(owner: UUID, request: Request)] = []
    @ObservationIgnored private var surfaces: [UUID] = []
    @ObservationIgnored private var hiddenSurfaces: Set<UUID> = []
    @ObservationIgnored private var interruptions: Set<Interruption> = []
    @ObservationIgnored private var player: ReelPlayer?
    @ObservationIgnored private var cycle: Task<Void, Never>?
    @ObservationIgnored private var volumeRamp: Task<Void, Never>?
    @ObservationIgnored private var pendingLeave: Task<Void, Never>?
    @ObservationIgnored private var playerClosedWait: Task<Void, Never>?
    @ObservationIgnored private var prefetches: [Task<Void, Never>] = []
    @ObservationIgnored private var dwellDone = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var framed = false

    private var visible: Bool {
        interruptions.isEmpty && !(surfaceOwner.map(hiddenSurfaces.contains) ?? false)
    }

    // MARK: 页面调用

    /// 页面的大图换到这一部（首页焦点停稳后、详情页出现时）。已经在放这一部就接着放，不重来
    func show(_ request: Request, owner: UUID, api: APIClient) {
        pendingLeave?.cancel()
        pendingLeave = nil
        self.api = api
        let sameTitle = key == request.mediaItemId
        if !sameTitle { pages.removeAll() }
        pages.removeAll { $0.owner == owner }
        pages.append((owner, request))
        // 同一部：正在放（或正在准备）就接着放；放完了只有换了放法（首页的回忆放完，进详情页放挑好的那段）才再放
        let idle = player == nil && cycle == nil
        if !sameTitle || (idle && (!ended || current?.source != request.source)) { begin(request) }
    }

    /// 页面离开（切页签、返回）。稍等一下再拆：首页压进详情页时两边的出现、消失谁先谁后不一定，
    /// 详情页接着要的是同一部就不拆
    func leave(owner: UUID) {
        pages.removeAll { $0.owner == owner }
        guard pages.isEmpty else { return }
        pendingLeave?.cancel()
        pendingLeave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.pages.isEmpty else { return }
            self.teardown()
            self.key = nil
            self.current = nil
        }
    }

    /// 进正片播放器、退到后台：拆掉播放器（同一时刻只留正片一个引擎）
    func interrupt(_ reason: Interruption) {
        if reason == .player { playerClosedWait?.cancel() }
        interruptions.insert(reason)
        teardown()
    }

    /// 打断结束：按眼前这一页的规则重新取片段、重新计停留（首页的续播点多半刚变过）
    func endInterruption(_ reason: Interruption) {
        guard interruptions.remove(reason) != nil, interruptions.isEmpty, let request = pages.last?.request else { return }
        begin(request)
    }

    /// 正片播放器关掉了：等服务端收下「停止」（续播点刚更新，首页要回忆的是刚看到的地方）再重新开始，最多等 3 秒
    func playerClosed() {
        playerClosedWait?.cancel()
        playerClosedWait = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in NotificationCenter.default.notifications(named: .playbackStopReported) { return }
                }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            self?.endInterruption(.player)
        }
    }

    // MARK: 画面层调用

    func claimSurface(_ token: UUID) {
        surfaces.removeAll { $0 == token }
        surfaces.append(token)
        surfaceOwner = token
        refresh()
    }

    func releaseSurface(_ token: UUID) {
        surfaces.removeAll { $0 == token }
        hiddenSurfaces.remove(token)
        surfaceOwner = surfaces.last
        refresh()
    }

    /// 这一层的大图滚走了 / 滚回来了
    func setSurface(_ token: UUID, visible: Bool) {
        if visible { hiddenSurfaces.remove(token) } else { hiddenSurfaces.insert(token) }
        refresh()
    }

    // MARK: 一轮：取地址 → 装载 → 停满开播 → 放完淡回剧照

    private func begin(_ request: Request) {
        teardown()
        key = request.mediaItemId
        current = request
        guard interruptions.isEmpty, let api else { return }
        cycle = Task { [weak self] in
            await self?.run(request, api: api)
        }
    }

    private func run(_ request: Request, api: APIClient) async {
        let clock = ContinuousClock()
        let shownAt = clock.now
        async let dwell: Void? = try? Task.sleep(for: Self.dwell)
        let fetched = try? await api.reelsPreview(mediaItemId: request.mediaItemId, source: request.source.rawValue,
                                                  season: request.season, episode: request.episode)
        guard !Task.isCancelled, let item = fetched ?? nil else { return }
        prefetch(item, api: api)
        let elapsed = clock.now - shownAt
        if elapsed < Self.engineDelay { try? await Task.sleep(for: Self.engineDelay - elapsed) }
        guard !Task.isCancelled else { return }
        startPlayer(item, api: api)
        _ = await dwell
        guard !Task.isCancelled else { return }
        dwellDone = true
        startIfReady()
    }

    private func startPlayer(_ item: API.ReelItemView, api: APIClient) {
        guard let player = try? ReelPlayer(item: item, stagePreview: true) else { return }
        player.core.volume = 0
        player.onStateChange = { [weak self] state in self?.handle(state) }
        player.onFirstFrame = { [weak self] in
            self?.framed = true
            self?.refresh()
        }
        player.onPrerolled = { [weak self] in
            guard let self, !self.loaded else { return }
            self.loaded = true
            self.startIfReady()
        }
        self.player = player
        engineView = player.core.view
        // 装载到起点停着（预起）：开播时只差「播放」
        player.start(api: api, autoplay: false)
    }

    private func handle(_ state: ReelPlayer.State) {
        switch state {
        case .ended:
            ended = true
            refresh()
            // 等淡回剧照（1.2 秒）走完再拆引擎：拆引擎在主线程上要几十毫秒，别赶在动画中间
            let finished = player
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.player === finished else { return }
                self.teardown(keepEnded: true)
            }
        case let .failed(message):
            NSLog("[TVStagePreview] 预告放不了，保持剧照：%@", message)
            teardown(keepEnded: true)
        default:
            break
        }
    }

    private func startIfReady() {
        guard dwellDone, loaded, !started, !ended, visible, let player else { return }
        started = true
        player.play()
        rampVolume(player)
    }

    /// 声音 1.5 秒内从 0 渐入到原音量
    private func rampVolume(_ player: ReelPlayer) {
        volumeRamp?.cancel()
        volumeRamp = Task { [weak player] in
            for step in 1 ... 15 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let player else { return }
                player.core.volume = Float(step) / 15
            }
        }
    }

    /// 可见性变了：看不见就暂停，回来接着放（还没开播的，回来时停留够了就开播）
    private func refresh() {
        let shouldShow = started && framed && !ended && visible
        if showing != shouldShow { showing = shouldShow }
        guard let player, started, !ended else {
            startIfReady()
            return
        }
        if visible {
            if player.state == .paused { player.play() }
        } else if player.state == .playing || player.state == .buffering {
            player.pause()
        }
    }

    private func prefetch(_ item: API.ReelItemView, api: APIClient) {
        // 和播放器的打开、探测并行，把索引与起点的头 1 MB 先下进片源字节缓存（同刷片的冷起播补字节）；
        // 进正片播放器时同一个文件的字节也直接复用
        guard let raw = item.play.streamUrl, let url = api.server.resolve(raw),
              let key = ReelPlayer.cacheKey(for: item) else { return }
        AetherPlayback.preconnect(url: url, headers: ["User-Agent": APIClient.userAgent])
        for range in item.play.prefetch where range.purpose == "index" || range.purpose == "start" {
            let length = range.purpose == "start" ? min(Int64(range.length), 1 << 20) : Int64(range.length)
            prefetches.append(Task.detached(priority: .userInitiated) {
                _ = await AetherPlayback.prefetchSource(url: url, cacheKey: key, ranges: [(Int64(range.offset), length)],
                                                        headers: ["User-Agent": APIClient.userAgent])
            })
        }
    }

    /// 拆掉这一轮。`keepEnded`：放完 / 放不了的这一部不再重来，直到换一部或被打断后重新开始
    private func teardown(keepEnded: Bool = false) {
        cycle?.cancel()
        cycle = nil
        volumeRamp?.cancel()
        prefetches.forEach { $0.cancel() }
        prefetches = []
        if let old = player {
            old.onStateChange = nil
            old.onFirstFrame = nil
            old.onPrerolled = nil
            old.pause()
            // 先停声、晚一点再拆：拆引擎在主线程上要几十毫秒（同刷片换条）
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                old.destroy()
            }
        }
        player = nil
        engineView = nil
        showing = false
        dwellDone = false
        loaded = false
        started = false
        framed = false
        ended = keepEnded
    }
}

/// 大图上挂预告画面的那一层（放在 `TVStageImage` 里剧照之上、压暗之下）。
/// 只有讲的正是在放的那一部、并且是最后出现的那一层时才把引擎画面挂上来
struct TVStagePreviewLayer: View {
    let key: Int
    /// 大图还在屏幕上（没被滚走）
    let visible: Bool

    @State private var token = UUID()
    private var preview: TVStagePreview { .shared }

    var body: some View {
        ZStack {
            if preview.key == key, let view = preview.engineView {
                TVPreviewHost(engineView: view, attached: preview.surfaceOwner == token)
                    .opacity(preview.showing ? 1 : 0)
                    .animation(.easeInOut(duration: preview.showing ? 0.9 : 1.2), value: preview.showing)
            }
        }
        .allowsHitTesting(false)
        .onAppear { preview.claimSurface(token) }
        .onDisappear { preview.releaseSurface(token) }
        .onChange(of: visible, initial: true) { _, visible in preview.setSurface(token, visible: visible) }
    }
}

/// 引擎视图的宿主：只有轮到这一层（`attached`）才把视图挂过来——首页与详情页的大图同时在时，
/// 两边都抢着挂会来回挪
private struct TVPreviewHost: UIViewRepresentable {
    let engineView: UIView
    let attached: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true
        update(container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        update(container)
    }

    private func update(_ container: UIView) {
        guard attached, engineView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        engineView.frame = container.bounds
        engineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(engineView)
    }
}
