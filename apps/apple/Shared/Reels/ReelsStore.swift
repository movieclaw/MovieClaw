import AetherCore
import SwiftUI

/// 刷片页的状态：翻页、当前这条的播放器、预取窗口、事件上报（docs/design/reels.md §4、§6）。
///
/// **当前这条 + 预起的下一条**：当前这条出画 1 秒后（且下一条的预取已下完），为下一条另建一个引擎，
/// 装载到片段起点停着、不再往前下载（`standby`）。滑过去时只要「播放」：不用现建引擎、打开、探测、
/// 等第一帧。换条时旧引擎先停声、半秒后再拆（拆引擎要在主线程上花几十毫秒，别赶在滑动收尾时）。
/// 往回滑、一次跳过好几条时没有预起，退回现建引擎。代价是同时多一个引擎（4K 杜比视界约 135MB 内存）。
/// 2026-09-30 模拟器实测（软件解码通路、字节都已预取，10 次换条中位数）：停稳到开播 139 → 36 毫秒，
/// 到出画 184 → 79 毫秒（剩下的是软件通路停着时不解第一帧、以及旧引擎停声本身）。
///
/// **预取窗口**：当前这条出第一个画面后（不和它抢起播的线路），后台把接下来几条要读的字节
/// 按服务端给的范围写进引擎的片源字节缓存：下一条全量（文件头 + 索引 + 起点后约 4 秒），
/// 再往后两条只取文件头与索引（都很小）。计费网络只预取下一条。滑走的条目的预取任务直接取消。
///
/// **事件**：曝光、出画面（带等待时长）、滑走（带看了多久）、看完、全屏观看、看详情、放不出，
/// 攒满 10 条或离开页面时批量上报；上报失败直接丢弃（只是统计，不重试）。
///
/// **类型筛选**：顶部「全部 ⌄」换类型时整个信息流重来（新种子、从头抽）。
///
/// **收藏 / 已看**：接口给出每条的初始状态，点按钮走播放器页同一个标记接口，界面先按点击结果
/// 显示、失败再改回去。收藏落在整部（电影 / 整剧），已看电影是整部、剧集是这一集。
///
/// **挂起 / 恢复**：页面被切走（换标签、盖上播放器页）时收掉播放器与预取，回来时当前这条从片段
/// 起点重新起播——引擎不能留在后台占着解码器和内存。
@Observable
@MainActor
final class ReelsStore {
    private(set) var items: [API.ReelItemView] = []
    /// 滚动位置绑定的「当前条」；滑动停稳后由 `settle()` 切换播放器
    var currentID: String?
    private(set) var loading = false
    private(set) var errorMessage: String?
    /// 服务器还没有片段接口（版本比 App 旧，`/reels` 返回 404）：页面提示升级服务器，而不是报「加载失败」
    private(set) var serverOutdated = false
    private(set) var exhausted = false
    private(set) var player: ReelPlayer?
    private(set) var playerState: ReelPlayer.State = .loading
    private(set) var firstFrameShown = false
    /// 当前这条的实时加载速度（「3.2 MB/s」，与播放器页同一文案）；转圈时显示，免得以为卡死了
    private(set) var speedLabel: String?
    private(set) var holdSpeedActive = false
    /// 片段的画质上限（`ReelsQuality`，按家里 / 外网记；nil = 原画）。每条播放器建的时候按它开
    private(set) var quality: Int?
    /// 卡顿换画质的提议（复用正片的 `QualitySuggestion`：长等 8 秒或反复卡、且实测速度跟不上码率）
    private(set) var qualityOffer: QualitySuggestion.Offer?
    /// 转码没开成退回原画这类一次性提示（几秒后收起）
    private(set) var notice: String?
    /// 卡顿判定跨条累计：片段一条几十秒，按条重来永远攒不够「反复卡」；给出一次提议后这次刷片不再提，
    /// 换了画质才重新判
    @ObservationIgnored private var suggestion = QualitySuggestion()
    @ObservationIgnored private var offerHideTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// 上一条的转码会话正在结束：下一条等它结束再开会话（服务端转码有并发上限）
    @ObservationIgnored private var releasing: Task<Void, Never>?
    /// 预起好的下一条：已装载到片段起点、停在第一帧上，滑过去直接播（见 `scheduleStandby`）
    private(set) var standby: ReelPlayer?
    /// 预起的那条出了第一帧
    private(set) var standbyReady = false
    /// 当前筛选条件：与媒体库筛选同一个模型、同一套参数（类型 / 地区 / 年代 / 评分 / 片长 / 观看）
    private(set) var filter = LibraryFilter()
    /// 只刷电影（movie）/ 剧集（tv）；nil = 都刷
    private(set) var kind: String?
    /// 筛选菜单的候选值与计数（当前条件下每个取值还剩几部）；nil = 还没拉到
    private(set) var facets: API.ReelFacetsView?
    /// 点过收藏 / 已看后的最新状态（接口给的是初始状态，条目是不可变的结构体）
    private var favoriteOverrides: [Int: Bool] = [:]
    private var playedOverrides: [String: Bool] = [:]
    /// 回到这一页时重新查到的观看进度（0 = 没有进度）；接口给的是进页面那一刻的
    private var progressOverrides: [String: Int] = [:]

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let metered: Bool
    @ObservationIgnored private var seed: Int?
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var prefetchTasks: [String: Task<Void, Never>] = [:]
    /// 下完了的预取任务（键同 `prefetchTasks`）：出画面事件里据此说明这一条起播时预取到了哪一步
    @ObservationIgnored private var prefetchDone: Set<String> = []
    /// 当前这条是怎么起播的（预起 / 现建、预取状态），出画面时随事件上报
    @ObservationIgnored private var startDetail: [String: API.JSONValue] = [:]
    @ObservationIgnored private var standbyTask: Task<Void, Never>?
    @ObservationIgnored private var speedTicker: Task<Void, Never>?
    /// 从全屏观看、详情页回来时，这一条从哪里接着放（条目 id、秒）；下一次为它现建引擎时用掉
    @ObservationIgnored private var resumeAt: (itemID: String, seconds: Double)?
    @ObservationIgnored private var pendingEvents: [API.ReelEventIn] = []
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    /// 当前这条已经转去全屏观看 / 详情页了：挂起时不算「滑走」
    @ObservationIgnored private var handedOff = false

    static let pageSize = 10
    /// 第一页（进页面、换筛选条件）只取 5 条：服务端装配按条数算，少一半第一屏快约 30 ms；
    /// 刷两三条就走的人后台也少预热一页。之后每页 10 条，请求次数不变多
    static let firstPageSize = 5
    /// 剩几条时拉下一页
    static let loadAheadThreshold = 3

    init(api: APIClient, metered: Bool) {
        self.api = api
        self.metered = metered
        quality = ReelsQuality.current(server: api.server)
    }

    // MARK: - 翻页

    func start() async {
        // 上次是服务器太旧：回到这页（比如刚去「更新与维护」升级完）时重新试一次
        if serverOutdated {
            serverOutdated = false
            exhausted = false
        }
        // 第一页还在路上时先和源站建好播放器那条连接（TCP / TLS）：播放器取流用的是引擎自己的连接，
        // 不和接口共用，第一条起播时就不用再握手（外网 HTTPS 省一两百毫秒；与正片点播放时同一做法）
        if items.isEmpty, let health = api.server.resolve("/api/v1/health") {
            AetherPlayback.preconnect(url: health, headers: ["User-Agent": APIClient.userAgent])
        }
        // 筛选菜单的计数只给右上角菜单用：和第一页并行拉，别让它挡在第一条起播前面
        let api = self.api
        let (filter, kind) = (self.filter, self.kind)
        async let counts: API.ReelFacetsView? = facets == nil
            ? (try? await api.reelsFacetsFiltered(filter: filter, kind: kind)) : nil
        if items.isEmpty { await loadMore() }
        if currentID == nil { currentID = items.first?.id }
        settle()
        // 等回来时条件已经又改了：这份计数是旧条件的，丢掉（新条件那次 start 会自己拉）
        if let counts = await counts, filter == self.filter, kind == self.kind { facets = counts }
    }

    /// 换筛选条件：整个信息流重来，菜单计数也跟着重算
    func applyFilter(_ filter: LibraryFilter, kind: String?) {
        guard filter != self.filter || kind != self.kind else { return }
        suspend()
        self.filter = filter
        self.kind = kind
        facets = nil
        items = []
        currentID = nil
        seed = nil
        nextOffset = 0
        exhausted = false
        errorMessage = nil
        Task { await start() }
    }

    func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        defer { loading = false }
        do {
            let limit = items.isEmpty ? Self.firstPageSize : Self.pageSize
            let page = try await api.reelsFeedFiltered(seed: seed, offset: nextOffset, limit: limit,
                                                       filter: filter, kind: kind)
            seed = page.seed
            nextOffset = page.nextOffset
            exhausted = !page.hasMore
            let known = Set(items.map(\.id))
            let fresh = page.items.filter { $0.play.mode == "seek" && !known.contains($0.id) }
            // 第一条的剧照马上要显示：随列表一起拉（服务端返回这一页时已在后台压好前 3 张）
            if items.isEmpty, let first = fresh.first, let url = stillURL(for: first) {
                FirstScreenImages.warm([url], urgent: true)
            }
            items += fresh
            errorMessage = nil
        } catch let error as APIError where error.status == 404 {
            // 片段接口本身没有「查无此条」的 404：只会是服务器还没这个接口
            serverOutdated = true
            exhausted = true
        } catch {
            errorMessage = "片段加载失败：\(error.localizedDescription)"
        }
    }

    func retry() async {
        errorMessage = nil
        await start()
    }

    // MARK: - 当前条

    /// 滑动停稳：当前条变了就换播放器。下一条预起好了（`standby`）就直接接着放，否则现建引擎
    func settle() {
        guard let id = currentID, player?.item.id != id,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        // 旧的先停声、稍后再拆：拆引擎要在主线程上花几十毫秒，正赶在滑动收尾时会顿一下
        leaveCurrent(deferTeardown: true)
        let item = items[index]
        shownAt = .now
        record(item, kind: "impression", positionMs: item.segment.startMs)
        startDetail = ["prefetch": .string(prefetchStatus(of: id)), "quality": .string(quality.map { "\($0)p" } ?? "original")]
        if let ready = standby, ready.item.id == id, !ready.state.isFailed {
            standby = nil
            startDetail["start"] = .string("standby")
            standbyReady = false
            adopt(ready, item: item, index: index)
            ready.play()
            // 第一帧早就出了，引擎不会再报：这里补上「出画面」的记录与后续预取
            if ready.hasFirstFrame { firstFrame(of: item, index: index) }
        } else {
            dropStandby()
            startDetail["start"] = .string("cold")
            if startDetail["prefetch"] == .string("none") { boostColdStart(item) }
            do {
                let player = try ReelPlayer(item: item, maxHeight: quality)
                adopt(player, item: item, index: index)
                let from = resumeAt?.itemID == id ? resumeAt?.seconds : nil
                resumeAt = nil
                player.start(api: api, from: from, after: releasing)
            } catch {
                playerState = .failed("播放器创建失败")
                record(item, kind: "fail", detail: ["reason": .string("engine_init")])
                schedulePrefetch(after: index)
            }
        }
        // 边看边把下一条的剧照拉进内存：滑过去时预起没好（要现建引擎）的那条，先有剧照垫着
        if index + 1 < items.count, let url = stillURL(for: items[index + 1]) {
            FirstScreenImages.warm([url], urgent: false)
        }
        if items.count - index <= Self.loadAheadThreshold {
            Task { await loadMore() }
        }
    }

    /// 让一个播放器成为当前这条（新建的，或预起好的）
    private func adopt(_ player: ReelPlayer, item: API.ReelItemView, index: Int) {
        player.onStateChange = { [weak self] state in self?.stateChanged(state, of: item) }
        player.onFirstFrame = { [weak self] in self?.firstFrame(of: item, index: index) }
        player.onNotice = { [weak self] message in self?.flash(message) }
        suggestion.restartGrace()
        self.player = player
        firstFrameShown = player.hasFirstFrame
        playerState = .loading
        speedLabel = nil
        startSpeedTicker()
    }

    /// 每秒采一次当前这条的加载速度（速度计要连续采样才准，所以不转圈时也采，只是界面不显示）
    private func startSpeedTicker() {
        guard speedTicker == nil else { return }
        speedTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let player = self.player else { continue }
                let bps = player.sampleLoadingSpeed()
                self.speedLabel = PlaybackController.formatLoadingSpeed(bps)
                self.feedQualitySuggestion(player: player, loadingBps: bps)
            }
        }
    }

    // MARK: - 画质

    /// 选画质：记到当前网络环境下（竖屏与全屏共用），当前这条从刚才的位置按新画质重开
    func selectQuality(_ maxHeight: Int?) {
        ReelsQuality.remember(maxHeight, server: api.server)
        qualityOffer = nil
        guard maxHeight != quality else { return }
        quality = maxHeight
        suggestion = QualitySuggestion()
        // 预起、预取的都是按旧画质准备的：作废
        dropStandby()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        guard let player, let id = currentID, player.item.id == id else { return }
        if player.position < player.endSeconds - 1 { resumeAt = (id, player.position) }
        // 不是滑走：不记「离开」
        handedOff = true
        leaveCurrent(deferTeardown: false)
        settle()
    }

    func acceptQualityOffer() {
        guard let offer = qualityOffer else { return }
        selectQuality(offer.maxHeight)
    }

    func dismissQualityOffer() { qualityOffer = nil }

    /// 每秒一次（同正片 `PlaybackController.feedQualitySuggestion`）：只在用户想看时喂——暂停、放完不算；
    /// 等首帧、缓冲都算「在等」，一次等太久或反复卡、且实测速度跟不上码率，就给一次提议（20 秒没理会自动收起）
    private func feedQualitySuggestion(player: ReelPlayer, loadingBps: Double?) {
        switch player.state {
        case .loading, .buffering, .playing: break
        default: return
        }
        suggestion.tick(stalled: player.state != .playing, loadingBps: loadingBps)
        guard qualityOffer == nil,
              let offer = suggestion.offer(streamBitrate: player.streamBitrate, currentHeight: player.currentHeight) else { return }
        qualityOffer = offer
        offerHideTask?.cancel()
        offerHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.qualityOffer = nil
        }
    }

    private func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - 手势（与播放器页同一个手势层 `PlayerGestureLayer`，竖滑留给翻页）

    /// 轻点暂停 / 继续（同抖音），不为等双击延迟；双击左右三分之一 = ∓10 秒，第一下切换过的暂停先恢复
    func handleTap(xRatio: CGFloat, isDouble: Bool) {
        guard let player else { return }
        guard isDouble, xRatio < 1 / 3 || xRatio > 2 / 3 else {
            player.togglePause()
            return
        }
        player.togglePause()
        suggestion.restartGrace()
        player.seek(to: player.position + (xRatio < 1 / 3 ? -10 : 10))
    }

    /// 长按 2 倍速，抬手恢复
    func handleHold(began: Bool) {
        if began {
            holdSpeedActive = player?.beginHoldSpeed() ?? false
        } else {
            player?.endHoldSpeed()
            holdSpeedActive = false
        }
    }

    /// 等画面时垫的图：这部片的横版剧照，没有剧照是服务端抓的起点帧。720p 小图（`reel-still`）；
    /// 页面与预取用同一个 URL 才命中同一条图片缓存
    func stillURL(for item: API.ReelItemView) -> URL? {
        api.image(item.title.backdropUrl ?? item.coverUrl, .reelStill)
    }

    /// 左上角标题跟的那一条：在播的这一条（滑过去、换了播放器才换）；还没有播放器时（刚进来、挂起中）按滚动位置
    var titleItem: API.ReelItemView? {
        if let player { return player.item }
        return items.first { $0.id == currentID }
    }

    /// 某一条现在由哪个播放器出画：当前这条，或预起好的下一条
    func player(for item: API.ReelItemView) -> ReelPlayer? {
        if let player, player.item.id == item.id { return player }
        if let standby, standby.item.id == item.id { return standby }
        return nil
    }

    /// 这一条的画面能不能直接显示（出了第一帧）；不能时页面先垫封面
    func frameReady(for item: API.ReelItemView) -> Bool {
        if player?.item.id == item.id { return firstFrameShown }
        if standby?.item.id == item.id { return standbyReady }
        return false
    }

    func togglePause() { player?.togglePause() }

    func pause() { player?.pause() }

    /// 「全屏观看」：这一段交给播放器页的片段模式放（`PlaybackClip`：手势、控制、换音轨字幕与正片一致，
    /// 时间轴只算这一段、放到终点停下、不写观看记录），从当前位置接着放
    func fullscreenRequest() -> PlayRequest? {
        guard let player else { return nil }
        let item = player.item
        let position = player.position
        record(item, kind: "fullscreen", positionMs: Int(position * 1000), watchedMs: watchedMs(player))
        // 不是滑走：挂起时不记「离开」
        handedOff = true
        return PlayRequest(mediaItemId: item.title.mediaItemId, season: item.title.episode?.season,
                           episode: item.title.episode?.episode, startSeconds: position,
                           fileId: item.segment.fileId,
                           clip: PlaybackClip(startMs: item.segment.startMs, endMs: item.segment.endMs, maxHeight: quality))
    }

    /// 「详情」：去媒体库条目页看这部片（路由由页面压栈）。记一条「看详情」——刷到感兴趣的片最直接的信号；
    /// 回来时这一条从刚才的位置接着放，不从片段起点重来
    func openDetail(_ item: API.ReelItemView) {
        guard let player, player.item.id == item.id else {
            record(item, kind: "detail")
            return
        }
        let position = player.position
        record(item, kind: "detail", positionMs: Int(position * 1000), watchedMs: watchedMs(player))
        handedOff = true
        if position < player.endSeconds - 1 { resumeAt = (item.id, position) }
    }

    /// 页面被切走（换标签、返回、盖上播放器页）：收掉播放器与预取，把攒着的事件报上去
    func suspend() {
        leaveCurrent(deferTeardown: false)
        speedTicker?.cancel()
        speedTicker = nil
        dropStandby()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        Task { await flush() }
    }

    /// 回到页面：当前这条重新起播。从全屏观看回来（`returning` 是片段播放器关掉时停的位置）且还在这一段里，
    /// 就从那里接着放；从详情页回来接着去之前的位置（`openDetail` 记下的）；否则从片段起点放
    func resume(returning: ClipReturn? = nil) {
        guard player == nil else { return }
        // 全屏里可能改了画质（与竖屏共用一份记忆）、也可能换了网络环境：按现在的重新取
        let latest = ReelsQuality.current(server: api.server)
        if latest != quality {
            quality = latest
            suggestion = QualitySuggestion()
        }
        if let returning, let id = currentID, let item = items.first(where: { $0.id == id }),
           item.segment.fileId == returning.fileId,
           returning.positionMs >= item.segment.startMs, returning.positionMs < item.segment.endMs - 1000 {
            resumeAt = (id, Double(returning.positionMs) / 1000)
        }
        if let id = currentID, let item = items.first(where: { $0.id == id }) {
            Task { await refreshMarks(item) }
        }
        settle()
    }

    // MARK: - 收藏 / 已看

    func isFavorite(_ item: API.ReelItemView) -> Bool {
        favoriteOverrides[item.title.mediaItemId] ?? item.title.favorite
    }

    func isPlayed(_ item: API.ReelItemView) -> Bool {
        playedOverrides[item.id] ?? item.title.played
    }

    /// 看了一半时的进度（1～99）；没看过、看完了为 nil
    func progressPercent(_ item: API.ReelItemView) -> Int? {
        guard let override = progressOverrides[item.id] else { return item.title.progressPercent }
        return override > 0 ? override : nil
    }

    /// 从全屏观看（可能点了「看全片」一路看完）、详情页（可能点了已看、收藏）回来：
    /// 重新查这一条的收藏、已看与进度，按钮按真实状态画
    private func refreshMarks(_ item: API.ReelItemView) async {
        let title = item.title
        let api = self.api
        async let marks = try? api.playbackMarksGet(mediaItemId: title.mediaItemId)
        async let state = try? api.playbackResume(mediaItemId: title.mediaItemId,
                                                  seasonNumber: title.episode?.season,
                                                  episodeNumber: title.episode?.episode)
        if let marks = await marks { favoriteOverrides[title.mediaItemId] = marks.isFavorite }
        if let state = await state {
            playedOverrides[item.id] = state.played
            progressOverrides[item.id] = state.played ? 0 : Self.percent(state.positionMs, of: state.durationMs)
        }
    }

    /// 与服务端「继续观看」同一口径：1～99，0 表示没有进度
    private static func percent(_ position: Int, of duration: Int?) -> Int {
        guard position > 0, let duration, duration > 0 else { return 0 }
        return max(1, min(99, Int((Double(position) * 100 / Double(duration)).rounded())))
    }

    /// 收藏：落在整部（电影 / 整剧）上
    func toggleFavorite(_ item: API.ReelItemView) async {
        let target = !isFavorite(item)
        favoriteOverrides[item.title.mediaItemId] = target
        do {
            let state = try await api.playbackMarksSet(body: API.PlaybackMarksRequest(
                mediaItemId: item.title.mediaItemId, favorite: target
            ))
            favoriteOverrides[item.title.mediaItemId] = state.isFavorite
        } catch {
            favoriteOverrides[item.title.mediaItemId] = !target
        }
    }

    /// 已看：电影标整部，剧集标这一集
    func togglePlayed(_ item: API.ReelItemView) async {
        let target = !isPlayed(item)
        playedOverrides[item.id] = target
        do {
            let state = try await api.playbackMarksSet(body: API.PlaybackMarksRequest(
                mediaItemId: item.title.mediaItemId, seasonNumber: item.title.episode?.season,
                episodeNumber: item.title.episode?.episode, played: target
            ))
            playedOverrides[item.id] = state.played
            // 标记已看 / 取消已看都会清掉续播点：进度圈不再画
            progressOverrides[item.id] = 0
        } catch {
            playedOverrides[item.id] = !target
        }
    }

    /// - Parameter deferTeardown: 先停声，拆引擎放到半秒后（滑动收尾时不占主线程）；
    ///   挂起页面时要立刻拆，把解码器与内存让给播放器页
    private func leaveCurrent(deferTeardown: Bool) {
        guard let player else { return }
        // 转去全屏观看 / 详情页了：不是滑走
        if player.state != .ended, !handedOff {
            record(player.item, kind: "leave", positionMs: Int(player.position * 1000), watchedMs: watchedMs(player))
        }
        player.onStateChange = nil
        player.onFirstFrame = nil
        // 转码会话马上结束（拆引擎可以晚半秒，名额不能晚）
        releasing = player.releaseSession()
        if deferTeardown {
            player.pause()
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                player.destroy()
            }
        } else {
            player.destroy()
        }
        self.player = nil
        handedOff = false
        speedLabel = nil
        holdSpeedActive = false
    }

    private func watchedMs(_ player: ReelPlayer) -> Int {
        Int(max(0, player.position - player.startSeconds) * 1000)
    }

    private func stateChanged(_ state: ReelPlayer.State, of item: API.ReelItemView) {
        guard player?.item.id == item.id else { return }
        playerState = state
        switch state {
        case .ended:
            if let player { record(item, kind: "complete", positionMs: item.segment.endMs, watchedMs: watchedMs(player)) }
        case let .failed(message):
            record(item, kind: "fail", detail: ["reason": .string(message)])
            if let index = items.firstIndex(where: { $0.id == item.id }) { schedulePrefetch(after: index) }
        default:
            break
        }
    }

    private func firstFrame(of item: API.ReelItemView, index: Int) {
        guard player?.item.id == item.id else { return }
        firstFrameShown = true
        let waited = shownAt.map { ContinuousClock.now - $0 } ?? .zero
        // 现建引擎的一条带上起播分段：停稳到发出装载多久，装载后各阶段各在第几毫秒
        var detail = startDetail
        if detail["start"] == .string("cold"), let player, let shownAt, let loadedAt = player.loadedAt {
            detail["load_ms"] = .int(ReelPlayer.milliseconds(loadedAt - shownAt))
            detail["stages"] = .object(player.stageMs.mapValues { .int($0) })
        }
        record(item, kind: "first_frame", positionMs: item.segment.startMs,
               waitMs: ReelPlayer.milliseconds(waited), detail: detail)
        schedulePrefetch(after: index)
        scheduleStandby(after: index)
    }

    // MARK: - 预取

    private func schedulePrefetch(after index: Int) {
        // 转码时下一条也是现开转码会话，预取原文件的字节用不上
        guard quality == nil else { return }
        let window = metered ? 1 : 3
        let targets = Array(items.dropFirst(index + 1).prefix(window))
        let keep = Set(targets.map(\.id))
        for (taskKey, task) in prefetchTasks where !keep.contains(String(taskKey.split(separator: "#")[0])) {
            task.cancel()
            prefetchTasks[taskKey] = nil
        }
        for (position, item) in targets.enumerated() {
            // 下一条全量；再往后只取文件头与索引（起点后几秒那段动辄几十 MB，滑不到就白下了）。
            // 任务按「条目 + 全量/轻量」分开记：一条从后排挪到下一条时，要补上起点那一段——
            // 已经下过的文件头与索引由引擎按缓存覆盖跳过，不会重下
            let full = position == 0
            let taskKey = "\(item.id)#\(full ? "full" : "light")"
            guard prefetchTasks[taskKey] == nil, prefetchTasks["\(item.id)#full"] == nil,
                  let raw = item.play.streamUrl, let url = api.server.resolve(raw),
                  let key = ReelPlayer.cacheKey(for: item) else { continue }
            let ranges = item.play.prefetch
                .filter { full || $0.purpose != "start" }
                .map { (offset: Int64($0.offset), length: Int64($0.length)) }
            prefetchTasks[taskKey] = Task.detached(priority: .utility) { [weak self] in
                _ = await AetherPlayback.prefetchSource(url: url, cacheKey: key, ranges: ranges,
                                                        headers: ["User-Agent": APIClient.userAgent])
                guard !Task.isCancelled else { return }
                await self?.markPrefetchDone(taskKey)
            }
        }
    }

    private func markPrefetchDone(_ taskKey: String) { prefetchDone.insert(taskKey) }

    /// 冷起播（进页面的第一条、滑得太快预取没赶上的）：和播放器的打开、探测并行，补下索引和起点的头 1 MB。
    ///
    /// 播放器是「文件头 → 探测 → 索引 → 起点」一段一段串行读的，索引和起点要等前面几步走完才开始下；
    /// 这两段在它打开、探测的同时各开一个请求下进片源字节缓存，它读到时直接走本机（第一个画面多在起点的
    /// 头 1 MB 里）。只补这么多：预取和播放器互不等待，补得比播放器快才有用，补多了反而和它重复下同一段；
    /// 文件头播放器一上来就自己读，也不补。转码时放的不是原文件，不补（同 `schedulePrefetch`）。
    private func boostColdStart(_ item: API.ReelItemView) {
        guard quality == nil, let raw = item.play.streamUrl, let url = api.server.resolve(raw),
              let key = ReelPlayer.cacheKey(for: item) else { return }
        for range in item.play.prefetch where range.purpose == "index" || range.purpose == "start" {
            let taskKey = "\(item.id)#boost-\(range.purpose)"
            let length = range.purpose == "start" ? min(Int64(range.length), 1 << 20) : Int64(range.length)
            let ranges = [(offset: Int64(range.offset), length: length)]
            guard prefetchTasks[taskKey] == nil else { continue }
            prefetchTasks[taskKey] = Task.detached(priority: .userInitiated) {
                _ = await AetherPlayback.prefetchSource(url: url, cacheKey: key, ranges: ranges,
                                                        headers: ["User-Agent": APIClient.userAgent])
            }
        }
    }

    /// full / light = 全量 / 只有文件头与索引已下完；*_running = 还在下；none = 没预取过
    private func prefetchStatus(of id: String) -> String {
        for kind in ["full", "light"] {
            let taskKey = "\(id)#\(kind)"
            if prefetchDone.contains(taskKey) { return kind }
            if prefetchTasks[taskKey] != nil { return "\(kind)_running" }
        }
        return "none"
    }

    // MARK: - 预起下一条

    /// 当前这条放稳（出画 1 秒后，且下一条的预取已下完）再预起下一条：装载到片段起点、停在第一帧，
    /// 之后不再往前下载。滑过去时只要「播放」，不用再建引擎、打开、探测、出第一帧。
    /// 等 1 秒是让开滑动收尾：旧引擎半秒后才拆，新引擎也要在主线程上建
    private func scheduleStandby(after index: Int) {
        standbyTask?.cancel()
        // 转码时不预起：预起要为下一条再开一个转码会话，服务端转码有并发上限、NAS 也吃不消
        guard quality == nil, index + 1 < items.count else { return }
        let next = items[index + 1]
        guard standby?.item.id != next.id else { return }
        let prefetch = prefetchTasks["\(next.id)#full"]
        standbyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await prefetch?.value
            guard let self, !Task.isCancelled, self.player != nil, self.currentID != next.id else { return }
            self.prepareStandby(next)
        }
    }

    private func prepareStandby(_ item: API.ReelItemView) {
        dropStandby()
        guard let standby = try? ReelPlayer(item: item, maxHeight: quality) else { return }
        standby.onFirstFrame = { [weak self, weak standby] in
            guard let self, let standby, self.standby === standby else { return }
            self.standbyReady = true
        }
        self.standby = standby
        standbyReady = false
        standby.start(api: api, autoplay: false)
    }

    private func dropStandby() {
        standbyTask?.cancel()
        standbyTask = nil
        guard let standby else { return }
        standby.onFirstFrame = nil
        standby.destroy()
        self.standby = nil
        standbyReady = false
    }

    // MARK: - 事件

    private func record(_ item: API.ReelItemView, kind: String, positionMs: Int? = nil, watchedMs: Int? = nil,
                        waitMs: Int? = nil, detail: [String: API.JSONValue]? = nil) {
        var detail = detail ?? [:]
        detail["network"] = .string(NetworkCost.shared.interface)
        pendingEvents.append(API.ReelEventIn(
            reelId: item.id, kind: kind, mode: item.play.mode, mediaItemId: item.title.mediaItemId,
            fileId: item.segment.fileId, positionMs: positionMs, watchedMs: watchedMs, waitMs: waitMs,
            detail: detail
        ))
        if pendingEvents.count >= 10 { Task { await flush() } }
    }

    private func flush() async {
        let batch = pendingEvents
        pendingEvents.removeAll()
        guard !batch.isEmpty else { return }
        _ = try? await api.reelsEvents(body: API.ReelEventBatch(events: batch))
    }
}
