import AetherCore
import SwiftUI

/// 刷片的一条：一个自研引擎实例，从原片中间的 `segment.start_ms` 起播，放到 `end_ms` 停下
/// （docs/design/reels.md §6）。
///
/// 为什么不复用播放器页的 `PlaybackController` / `NativeEngine`：
/// - 刷片**不写观看记录**：进度上报、续播点、播放次数都在 PlaybackController 里，刷片一条都不能碰；
/// - 不需要画中画、锁屏信息这些正片才要的东西（卡顿换画质的提示由 `ReelsStore` 复用 `QualitySuggestion`）；
/// - 原画的取流地址由刷片接口直接给出（按文件签发的令牌），不用每条开一次播放会话。
///
/// 片源字节缓存的键与播放器页同一口径（`PlaybackController.sourceCacheKey`，文件 id + 大小）：
/// 刷片预取和播放下过的字节，点「接着看」转到播放器页后直接复用，起播不用重下。
///
/// **限了画质时走服务端转码**（`maxHeight`，见 `ReelsQuality`；外网默认 720p）：开一个播放会话
/// （`POST /playback/sessions`，与正片同一个接口，按系统播放器的能力申报、带片段起点与画质上限），
/// 拿到服务端 HLS 交给同一个自研引擎放。会话不带播放记录编号、不报进度，所以照样不写观看记录；
/// 每 15 秒续一次命，拆播放器时结束会话（掐掉 ffmpeg）。源本来就不超所选档（服务端说视频直通）时
/// 不必转码：释放会话、照旧直出原文件。转码开不起来（要开启软件转码、服务端拒绝、请求失败）也退回原文件，
/// 不让这一条放不出来。服务端流里没有内封字幕轨：图形字幕由服务端压进画面，文字字幕暂不显示。
@MainActor
final class ReelPlayer {
    enum State: Equatable {
        /// loading = 还没出第一帧；buffering = 出过画面后缓冲见底在等数据（转圈 + 实时加载速度）
        case loading, buffering, playing, paused, ended
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let item: API.ReelItemView
    let core: AetherPlayback
    private(set) var state: State = .loading {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    var onFirstFrame: (() -> Void)?
    /// 预起装载好、停在起点了（`start(autoplay: false)`）：这时再 `play()` 立刻起播
    var onPrerolled: (() -> Void)?
    private(set) var hasFirstFrame = false
    /// 预起中：装载到起点停着，等 `play()`（见 `start(server:autoplay:)`）
    private var prerolling = false
    private var subtitleApplied = false
    private var monitor: Task<Void, Never>?
    /// 画质上限；nil = 原画（直出原文件）
    let maxHeight: Int?
    /// 实际在放服务端转码流
    private(set) var transcoding = false
    /// 在放预切片段（`play.mode == "clip"`，docs/design/reels.md §8）：服务端切好的 1080p 小文件，
    /// 第 0 秒就是原片的片段起点；不开转码会话，字幕走片段字幕文件（同转码流）
    var isClip: Bool { item.play.mode == "clip" }
    private var sessionId: String?
    private var scope: PlaybackAPI?
    private var loadTask: Task<Void, Never>?
    private var destroyed = false
    /// 服务端流的时间轴从会话起点算（`timeline == "session"`）时，引擎时间 + 它 = 原片时间；原文件与按原片
    /// 时间切的 HLS 为 0
    private var timeOrigin: Double = 0
    /// 转码没开成、退回原画这类要让用户知道的事
    var onNotice: ((String) -> Void)?
    /// Apple TV 大图预告（`TVStagePreview`）：画面铺满裁切、不切换电视的显示模式
    let stagePreview: Bool

    var startSeconds: Double { Double(item.segment.startMs) / 1000 }
    var endSeconds: Double { Double(item.segment.endMs) / 1000 }
    /// 这次从哪里起播（片段起点，或从全屏观看回来时接着的位置）
    private var loadedFrom: Double?
    /// 装载发出的时刻，以及引擎各起播阶段（打开片源、识别容器、探测轨道……）距它的毫秒数。
    /// 随「出画面」事件上报，慢的那一条能看出卡在哪一步（与播放器页 `PlaybackRecord.noteEngineStage` 同一套阶段名）
    private(set) var loadedAt: ContinuousClock.Instant?
    private(set) var stageMs: [String: Int] = [:]
    /// 实时加载速度：与播放器页同一个量法（`LoadingSpeedMeter`，2 秒窗口），由 `ReelsStore` 每秒采一次
    private var loadingMeter = LoadingSpeedMeter()
    private(set) var holdSpeedActive = false
    /// 当前在原片上的位置（秒）；还没出画面时按起播点算
    var position: Double { hasFirstFrame ? max(fileTime, startSeconds) : loadedFrom ?? startSeconds }
    /// 引擎时间换成原片时间
    private var fileTime: Double { core.currentTime + timeOrigin }
    /// 片段内的进度 0～1
    var progress: Double {
        let span = endSeconds - startSeconds
        guard span > 0 else { return 0 }
        return min(1, max(0, (position - startSeconds) / span))
    }

    init(item: API.ReelItemView, maxHeight: Int? = nil, stagePreview: Bool = false) throws {
        NativeEngine.prepareEngineEnvironment()
        core = try AetherPlayback()
        NativeEngine.sweepStaleCachesOnce()
        self.item = item
        self.maxHeight = maxHeight
        self.stagePreview = stagePreview
        core.fillsFrame = stagePreview
        // 字幕字号按画面高度的百分比：iPhone 竖屏刷片时画面只是屏幕中间一条横带，要放大才看得清；
        // Apple TV 全屏播放，用正片播放器的默认字号（PlayerPreferences.SubtitleStyle 的 5.2%）
        #if os(tvOS)
        core.setTextStyle(.init(fontScale: 5.2, bottomPercent: 8, background: false))
        #else
        core.setTextStyle(.init(fontScale: 8, bottomPercent: 6, background: false))
        #endif
        core.onPhase = { [weak self] phase in self?.handle(phase) }
        core.onFailure = { [weak self] failure in self?.state = .failed(failure.message) }
        core.onTracksChanged = { [weak self] in self?.applySubtitle() }
        core.onStartupStage = { [weak self] stage in self?.markStage(stage) }
        core.onFirstFrame = { [weak self] in
            guard let self, !self.hasFirstFrame else { return }
            self.hasFirstFrame = true
            self.markStage("firstFrame")
            self.onFirstFrame?()
        }
    }

    /// 片源字节缓存的键；刷片预取与播放器页都用它认同一个文件
    static func cacheKey(for item: API.ReelItemView) -> String? {
        item.play.sizeBytes.map { PlaybackController.sourceCacheKey(fileId: item.segment.fileId, size: $0) }
    }

    /// - Parameters:
    ///   - autoplay: false = 预起（装载到起点、停在第一帧，等 `play()`）
    ///   - from: 从哪里起播（秒）；nil = 片段起点
    /// - after: 上一条的转码会话正在结束（`releaseSession()` 返回的任务）：等它结束了再开这条的会话。
    ///   服务端转码有并发上限（纯软件转码按核数算，8 核 NAS 只有 2 路），旧会话没收掉就开新的会被拒
    func start(api: APIClient, autoplay: Bool = true, from: Double? = nil, after previous: Task<Void, Never>? = nil) {
        prerolling = !autoplay
        loadedFrom = from
        loadedAt = .now
        stageMs = [:]
        loadingMeter.reset()
        if isClip {
            // 小文件本身就是 1080p，画质上限不用再转码
            loadClip(api: api, autoplay: autoplay, from: from)
        } else if let maxHeight {
            loadTask = Task {
                await previous?.value
                await startTranscode(api: api, maxHeight: maxHeight, autoplay: autoplay, from: from)
            }
        } else {
            loadOriginal(api: api, autoplay: autoplay, from: from)
        }
        // 到终点就停：引擎没有「放到某处停」的接口，四分之一秒看一次位置足够（片段 30～60 秒）；
        // 顺带给转码会话续命（15 秒一次，服务端 3 分钟没动静就回收：暂停久了也不断）
        monitor = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if self.state == .playing, self.hasFirstFrame, self.fileTime >= self.endSeconds {
                    self.core.pause()
                    self.state = .ended
                }
                ticks += 1
                if ticks % 60 == 0, let scope = self.scope, let sessionId = self.sessionId {
                    Task { _ = await scope.ping(sessionId) }
                }
            }
        }
    }

    /// 原画：引擎直接读 NAS 上的原片，按交付方式装载（与正片同一套，docs/design/disc-direct-play.md）——
    /// 普通文件与光盘镜像给取流地址；原盘目录先取目录清单，引擎按服务端选的主播放列表逐个剪辑取字节
    private func loadOriginal(api: APIClient, autoplay: Bool, from: Double?) {
        guard let raw = item.play.streamUrl, let url = api.server.resolve(raw) else {
            state = .failed("这一条缺少取流地址")
            return
        }
        transcoding = false
        timeOrigin = 0
        switch item.play.disc {
        case "image":
            load(.discImage(url), autoplay: autoplay, from: from)
        case "folder":
            loadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let disc = try await self.discFolder(api: api, listing: url)
                    guard !self.destroyed, !Task.isCancelled else { return }
                    self.load(disc, autoplay: autoplay, from: from)
                } catch {
                    guard !self.destroyed, !Task.isCancelled else { return }
                    self.state = .failed("原盘目录清单读取失败：\(error.localizedDescription)")
                }
            }
        default:
            load(.file(url), autoplay: autoplay, from: from)
        }
    }

    /// 预切片段：时间原点是片段起点（引擎时间 + 起点 = 原片时间，进度、终点、事件、「接着看」都照原片算）
    private func loadClip(api: APIClient, autoplay: Bool, from: Double?) {
        guard let raw = item.play.clipUrl, let url = api.server.resolve(raw) else {
            state = .failed("这一条缺少片段地址")
            return
        }
        transcoding = false
        timeOrigin = startSeconds
        let subtitles = clipSubtitles(server: api.server)
        subtitleApplied = subtitles.isEmpty
        core.setSubtitleDelay(-timeOrigin)
        core.load(source: .file(url), start: max(0, (from ?? startSeconds) - timeOrigin), autoplay: autoplay,
                  headers: ["User-Agent": APIClient.userAgent], externalSubtitles: subtitles,
                  switchesDisplayMode: !stagePreview)
    }

    private func load(_ source: AetherPlayback.Source, autoplay: Bool, from: Double?) {
        core.load(source: source, start: from ?? startSeconds, autoplay: autoplay,
                  headers: ["User-Agent": APIClient.userAgent],
                  audioOrdinal: item.play.audioOrdinal,
                  sourceCacheKey: Self.cacheKey(for: item), switchesDisplayMode: !stagePreview)
    }

    /// 原盘目录清单（`/playback/files/{id}/disc?token=`，令牌与取流地址同一个）→ 引擎要的文件列表与主播放列表。
    /// 主播放列表由服务端选（诱饵判定与挑点同一口径），片段的时间轴才对得上
    private func discFolder(api: APIClient, listing: URL) async throws -> AetherPlayback.Source {
        guard let token = PlaybackAPI.token(in: listing.absoluteString) else {
            throw APIError.decoding("取流地址缺少令牌")
        }
        // 走播放专用的连接池，不排在页面请求后面（同转码会话）
        let client = APIClient(server: api.server, token: api.token, session: APIClient.playbackSession)
        let view = try await client.playbackFileDiscList(fileId: item.segment.fileId, token: token)
        let files = view.files.compactMap { file in
            api.server.resolve(file.url).map { AetherPlayback.DiscFile(path: file.path, size: Int64(file.size), url: $0) }
        }
        return .discFolder(files: files, playlist: view.playlist)
    }

    /// 限了画质：开服务端转码会话，从片段起点（或接着的位置）转
    private func startTranscode(api: APIClient, maxHeight: Int, autoplay: Bool, from: Double?) async {
        // 播放请求走独立连接池，不排在页面请求后面（同 PlaybackController）
        let scope = PlaybackAPI(api: APIClient(server: api.server, token: api.token, session: APIClient.playbackSession),
                                shareSlug: nil)
        let target = from ?? startSeconds
        // 文字字幕服务端从不压制（只压图形字幕），由引擎画装载时交给它的片段字幕（见 `clipSubtitles`），这里传 off；
        // 没有片段字幕地址的（图形字幕）才请服务端压进画面
        var subtitle = item.play.subtitle.flatMap { $0.url == nil ? "embedded:\($0.ordinal)" : nil } ?? "off"
        for _ in 0..<2 {
            let body = API.PlaybackSessionRequest(
                fileId: item.segment.fileId,
                mediaItemId: item.title.mediaItemId,
                seasonNumber: item.title.episode?.season ?? 0,
                episodeNumber: item.title.episode?.episode ?? 0,
                capability: PlayerCapability.avPlayer(),
                failedTiers: nil,
                audioTrack: item.play.audioOrdinal.map { "embedded:\($0)" },
                subtitleTrack: subtitle,
                maxHeight: maxHeight,
                downlinkBps: nil,
                startMs: Int(target * 1000),
                // 不带播放记录编号：不建「已开始」、不进活动页的播放统计
                attemptId: nil,
                client: nil
            )
            let session: API.PlaybackSessionView
            do {
                session = try await scope.startSession(body).0
            } catch let error as APIError where error.status == 503 && error.localizedDescription.contains("转码会话已满") {
                // 服务端同时转码的路数满了（别人也在转码，或正片播放器占着）：服务端原文带着「请停止其它播放」，
                // 在片段里读着奇怪，换成一句说明
                guard !destroyed else { return }
                fallBackToOriginal(api: api, autoplay: autoplay, from: from, reason: "服务器同时转码的路数满了")
                return
            } catch {
                guard !destroyed else { return }
                fallBackToOriginal(api: api, autoplay: autoplay, from: from, reason: "转码没开起来（\(error.localizedDescription)）")
                return
            }
            guard !destroyed else {
                if let sid = session.sessionId { await scope.stop(sid) }
                return
            }
            let decision = session.decision
            if decision.outcome == "consent", subtitle != "off" {
                // 压字幕撞上「要开启软件转码」：不压字幕再要一次（同正片）
                subtitle = "off"
                continue
            }
            if decision.outcome == "consent" || decision.outcome == "rejected" {
                fallBackToOriginal(api: api, autoplay: autoplay, from: from,
                                   reason: decision.outcome == "consent" ? "服务端没开启软件转码" : "服务端没法转这一条")
                return
            }
            // 源本来就不超所选档（视频直通）：不必转码，释放会话、直出原文件
            if decision.tier == 0 || decision.video?.action == "copy" {
                if let sid = session.sessionId { Task { await scope.stop(sid) } }
                loadOriginal(api: api, autoplay: autoplay, from: from)
                return
            }
            guard let url = scope.streamURL(session.streamUrl) else {
                fallBackToOriginal(api: api, autoplay: autoplay, from: from, reason: "服务端没有给出转码地址")
                return
            }
            self.scope = scope
            sessionId = session.sessionId
            transcoding = true
            timeOrigin = session.timeline == "file" ? 0 : Double(session.startMs) / 1000
            // 转码流里没有内封轨可选：文字字幕用这一段的字幕文件，由引擎画（ASS 样式照样生效）。
            // 片段字幕是原片时间，会话时间轴从 timeOrigin 起算：字幕时钟往后拨 timeOrigin 秒对齐
            let subtitles = clipSubtitles(server: api.server)
            subtitleApplied = subtitles.isEmpty
            core.setSubtitleDelay(-timeOrigin)
            core.load(source: .file(url), start: max(0, target - timeOrigin), autoplay: autoplay,
                      headers: ["User-Agent": APIClient.userAgent], externalSubtitles: subtitles)
            return
        }
    }

    private func fallBackToOriginal(api: APIClient, autoplay: Bool, from: Double?, reason: String) {
        onNotice?("\(reason)，这一条先放原画")
        loadOriginal(api: api, autoplay: autoplay, from: from)
    }

    func play() {
        if prerolling {
            prerolling = false
            core.setPrefetchSuspended(false)
        }
        if state == .ended { replay() } else { core.play() }
    }

    func pause() { core.pause() }

    func togglePause() {
        switch state {
        case .playing, .buffering: pause()
        case .paused, .ended: play()
        default: break
        }
    }

    /// 跳到原片上某处（秒），夹在片段之内（手势双击 ±10 秒、横滑拖进度）；放完停着时跳回去接着放
    func seek(to seconds: Double) {
        let target = min(max(startSeconds, seconds), max(startSeconds, endSeconds - 0.5))
        core.seek(to: max(0, target - timeOrigin))
        if state == .ended {
            core.play()
            state = .playing
        }
    }

    /// 长按 2 倍速（同播放器页 `PlaybackController.beginHoldSpeed`）：暂停、还没出画时不起
    @discardableResult
    func beginHoldSpeed() -> Bool {
        guard state == .playing, hasFirstFrame else { return false }
        holdSpeedActive = true
        core.setRate(2)
        return true
    }

    func endHoldSpeed() {
        guard holdSpeedActive else { return }
        holdSpeedActive = false
        core.setRate(1)
    }

    /// 这条流的码率（卡顿提示比实测速度用）：服务端流取 AVPlayer 报的码率，原文件取容器码率
    var streamBitrate: Double? {
        let readouts = core.readouts()
        return readouts.videoBitrateBps ?? readouts.averageBitrateBps
    }

    /// 现在的画面高度（卡顿提示推荐更低一档用）：限了画质按上限，原画按实际画面
    var currentHeight: Int? {
        maxHeight ?? (core.videoSize.height > 0 ? Int(core.videoSize.height) : nil)
    }

    /// 采一次加载速度（bps）；引擎还没有读数时为 nil
    func sampleLoadingSpeed() -> Double? {
        loadingMeter.sample(bytes: core.readouts().sourceBytesFetched, transferSeconds: 0,
                            at: ProcessInfo.processInfo.systemUptime)
    }

    /// 从片段起点重放
    func replay() {
        core.seek(to: max(0, startSeconds - timeOrigin))
        core.play()
        state = .playing
    }

    /// 马上结束转码会话（掐掉服务端的 ffmpeg），返回结束请求的任务；滑走时先调它，下一条等它完成再开会话。
    /// 开会话的请求还在路上时不取消它：服务端多半已经建好会话，取消了客户端拿不到会话号、结束不了，
    /// 只能等服务端 3 分钟没心跳回收——这 3 分钟一直占着一路转码名额（真机实测撞上「转码会话已满」）。
    /// 那种情况由 `startTranscode` 拿到会话后看见 `destroyed` 自己结束
    @discardableResult
    func releaseSession() -> Task<Void, Never>? {
        destroyed = true
        guard let scope, let sessionId else { return loadTask }
        self.sessionId = nil
        let pending = loadTask
        return Task {
            await scope.stop(sessionId)
            await pending?.value
        }
    }

    func destroy() {
        releaseSession()
        loadTask = nil
        monitor?.cancel()
        monitor = nil
        onNotice = nil
        onStateChange = nil
        onFirstFrame = nil
        onPrerolled = nil
        core.destroy()
    }

    private func handle(_ phase: AetherPlayback.Phase) {
        switch phase {
        case .playing:
            if state != .ended { state = .playing }
        case .paused:
            if state == .playing || state == .buffering { state = .paused }
            // 预起的那条装载好了就停止往前下：滑不滑过去还不知道，别占着当前这条的带宽
            if prerolling {
                core.setPrefetchSuspended(true)
                onPrerolled?()
            }
        case .ended:
            state = .ended
        case .loading, .buffering:
            // 出过画面后再转圈就是缓冲：要显示出来，不然画面停着像卡死了
            if !hasFirstFrame {
                state = .loading
            } else if state == .playing {
                state = .buffering
            }
        }
    }

    /// 每个阶段只记第一次（重建、跳转会再报一遍，那不是起播）
    private func markStage(_ stage: String) {
        guard let loadedAt, stageMs[stage] == nil else { return }
        stageMs[stage] = Self.milliseconds(ContinuousClock.now - loadedAt)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// 这一段的字幕文件：服务端只抽片段前后这一小段（`ReelSubtitleView.url`），不必等 NAS 通读整个文件抽整轨。
    /// 只有能原样拷贝的文字轨才有（srt / ass），图形字幕仍由转码压制
    private func clipSubtitles(server: ServerAddress) -> [AetherPlayback.ExternalSubtitle] {
        guard let subtitle = item.play.subtitle, let raw = subtitle.url, let format = subtitle.format,
              let url = server.resolve(raw) else { return [] }
        return [.init(url: url, language: subtitle.language, format: format)]
    }

    /// 原文件：内封字幕按同类型顺序对位（与播放器页 `NativeEngine.selectSubtitle` 同一口径）；
    /// 转码流、预切片段：选装载时交给引擎的那份片段字幕
    private func applySubtitle() {
        guard !subtitleApplied else { return }
        if transcoding || isClip {
            guard let clip = core.subtitleTracks.filter(\.isExternal).min(by: { $0.id < $1.id }) else { return }
            subtitleApplied = true
            core.selectSubtitleTrack(id: clip.id)
            return
        }
        guard let ordinal = item.play.subtitle?.ordinal else { return }
        let embedded = core.subtitleTracks.filter { !$0.isExternal }.sorted { $0.id < $1.id }
        guard ordinal < embedded.count else { return }
        subtitleApplied = true
        core.selectSubtitleTrack(id: embedded[ordinal].id)
    }
}
