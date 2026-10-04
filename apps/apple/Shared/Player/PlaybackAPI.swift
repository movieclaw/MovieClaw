import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 通知：一场播放的「停止」已被服务端收下（续播点、已看标记已更新）。userInfo["mediaItemId"] 是条目 id。
/// 详情页据此重拉续播点——关掉播放器回来，播放键从「播放」变「继续」、时间跟上刚才看到的位置。
/// 在服务端确认之后才发，避免抢在写入前读到旧进度
nonisolated extension Notification.Name {
    static let playbackStopReported = Notification.Name("MovieClaw.playbackStopReported")
}

/// 播放单元：电影用 (0, 0) 哨兵，与后端台账、playback_state 的约定一致。
struct PlaybackUnit: Hashable {
    var mediaItemId: Int
    var season: Int
    var episode: Int

    var isEpisode: Bool { season > 0 || episode > 0 }

    /// SxxExx（季集号补零是媒体库的通用写法）
    var code: String { String(format: "S%02dE%02d", season, episode) }
}

/// 播放接口的作用域（对应 Web `PlaybackApiScope`，docs/design/media-share.md §5.3）。
///
/// 登录成员走 `/playback/…`；分享访客走 `/share/{slug}/playback/…` 这条按 slug 收窄的公开通道：
/// 访客没有成员身份，进度只记本机、遥测（metrics / client-log）不上报。
/// 播放器其余代码只认这一层，不关心自己在哪个作用域里——这样分享播放与登录播放共用同一套界面与状态机。
struct PlaybackAPI {
    let api: APIClient
    let shareSlug: String?

    var isShare: Bool { shareSlug != nil }
    var telemetry: Bool { !isShare }
    let deviceId = PlayerPreferences.deviceId

    // MARK: 条目与分集

    func item(_ mediaItemId: Int) async throws -> API.PlaybackItemView {
        if let shareSlug { return try await api.sharePlaybackItem(mediaItemId: mediaItemId, slug: shareSlug) }
        return try await api.playbackItemInfo(mediaItemId: mediaItemId)
    }

    func episodes(_ mediaItemId: Int, season: Int) async throws -> [API.EpisodeView] {
        if let shareSlug {
            return try await api.sharePlaybackItemEpisodes(mediaItemId: mediaItemId, slug: shareSlug, seasonNumber: season).episodes
        }
        return try await api.playbackItemEpisodes(mediaItemId: mediaItemId, seasonNumber: season).episodes
    }

    // MARK: 决策与会话
    //
    // 这两个接口标成 nonisolated：起播协商（`negotiate`）要在后台一口气跑完，不能每一步都回主线程排队。

    /// 开会话。登录成员的请求顺带读回响应头 `Server-Timing`（服务端决策 / 准备 / ffmpeg 各段耗时），
    /// 播放记录据此把起播分段拆成「网络往返」与「服务端处理」（docs/design/playback-qoe.md §2）
    nonisolated func startSession(_ body: API.PlaybackSessionRequest) async throws -> (API.PlaybackSessionView, [String: Int]) {
        var body = body
        body.deviceId = deviceId
        if let shareSlug { return (try await api.sharePlaybackSessionStart(slug: shareSlug, body: body), [:]) }
        let (view, headers): (API.PlaybackSessionView, [String: String]) =
            try await api.sendReturningHeaders("POST", "/playback/sessions", body: body)
        return (view, Self.serverTiming(headers["server-timing"]))
    }

    /// `decide;dur=12, prep;dur=30` → ["decide": 12, "prep": 30]
    nonisolated static func serverTiming(_ header: String?) -> [String: Int] {
        guard let header else { return [:] }
        var result: [String: Int] = [:]
        for part in header.split(separator: ",") {
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = fields.first, !name.isEmpty,
                  let duration = fields.dropFirst().first(where: { $0.hasPrefix("dur=") }),
                  let value = Double(duration.dropFirst(4)) else { continue }
            result[name] = Int(value.rounded())
        }
        return result
    }

    /// 起播协商用的引擎模式（由控制器按兜底阶梯算好，见 `PlaybackController` 的类注释）
    nonisolated enum EngineMode: Sendable {
        /// 自研引擎：申报全解码与读光盘，服务端直接给档 0 的原文件地址（或原盘目录清单），不起任何进程
        case native
        /// 服务端流交给系统播放器：用户限了画质，或自研引擎在这台设备上放不了这部片
        case system
    }

    /// 起播协商的全部输入：控制器在主线程一次算好（能力快照要读屏幕与机型），之后整段在后台跑
    struct NegotiationInputs: Sendable {
        var mode: EngineMode
        /// 自研引擎的请求体
        var native: API.PlaybackSessionRequest
        /// 系统播放器（服务端流）的请求体：按 AVPlayer 的能力申报
        var system: API.PlaybackSessionRequest
        /// 服务端流由系统播放器放时才提前建资源；交给自研引擎放就不必
        var prepareSystemAsset = true
    }

    /// 起播协商的结果与各段完成时刻（起播分段计时用）
    struct Negotiation: Sendable {
        var useNative: Bool
        var session: API.PlaybackSessionView
        var startedAt: ContinuousClock.Instant
        var sessionAt: ContinuousClock.Instant
        /// 开会话响应里的服务端各段耗时（毫秒）
        var serverTiming: [String: Int] = [:]
        /// 给系统播放器预先建好、已经在加载的资源（见 `negotiate` 末尾）；自研引擎或没给出计划时为 nil
        var preparedAsset: AVURLAsset?
    }

    /// 起播协商：按模式开会话。
    ///
    /// 整段在后台执行器上跑完、中途不回主线程：播放器刚弹出时主线程忙着排版和转场，
    /// 原来每个网络往返都要回主线程续跑，起播请求光是排队就要一两百毫秒（模拟器实测）。
    @concurrent
    nonisolated func negotiate(_ inputs: NegotiationInputs) async throws -> Negotiation {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let useNative = inputs.mode == .native
        let (session, serverTiming) = try await startSession(useNative ? inputs.native : inputs.system)
        let sessionAt = clock.now
        // 系统播放器要放的地址此刻已经确定：马上建好资源、开始读文件头 / 播放列表。
        // 主线程这时多半还在忙播放器弹出的转场，挂引擎要再等几十毫秒——AVFoundation 先干起来
        var preparedAsset: AVURLAsset?
        if !useNative, inputs.prepareSystemAsset, session.decision.outcome == "plan",
           let url = Self.systemPlayerURL(session, server: api.server) {
            let asset = AVURLAsset(url: url)
            Task { _ = try? await asset.load(.isPlayable) }
            preparedAsset = asset
        }
        return Negotiation(
            useNative: useNative, session: session, startedAt: startedAt, sessionAt: sessionAt,
            serverTiming: serverTiming, preparedAsset: preparedAsset
        )
    }

    /// 系统播放器该吃的地址：VOD 会话吃 master 列表（里面的 WEBVTT 字幕组让画中画 / 隔空播放时由系统渲染字幕），
    /// 其余（原文件直出、旧式会话列表）用 stream_url。与 `PlaybackController.handleSession` 的取址规则一致
    nonisolated static func systemPlayerURL(_ session: API.PlaybackSessionView, server: ServerAddress) -> URL? {
        if session.timeline == "file", let master = session.masterUrl { return server.resolve(master) }
        return server.resolve(session.streamUrl)
    }

    /// 会话续命兼探活。三态必须区分（同 Web `pingPlaybackSession`）：
    /// true = 还在；false = 服务端明确说没了（404），要原地重开；nil = 这次请求本身失败，不能当成没了。
    func ping(_ sessionId: String) async -> Bool? {
        do {
            if let shareSlug {
                _ = try await api.sharePlaybackSessionPing(sessionId: sessionId, slug: shareSlug)
            } else {
                _ = try await api.playbackSessionPing(sessionId: sessionId)
            }
            return true
        } catch let error as APIError where error.status == 404 {
            return false
        } catch {
            return nil
        }
    }

    /// 结束会话（掐断 ffmpeg、清临时分片）。失败无所谓：服务端有心跳超时回收兜底。
    func stop(_ sessionId: String) async {
        if let shareSlug {
            _ = try? await api.sharePlaybackSessionStop(sessionId: sessionId, slug: shareSlug)
        } else {
            _ = try? await api.playbackSessionStop(sessionId: sessionId)
        }
    }

    func diagnostics(_ sessionId: String, token: String) async throws -> API.PlaybackDiagnosticsView {
        if let shareSlug {
            return try await api.sharePlaybackSessionDiagnostics(sessionId: sessionId, slug: shareSlug, token: token)
        }
        return try await api.playbackSessionDiagnostics(sessionId: sessionId, token: token)
    }

    // MARK: 进度

    #if DEBUG
    /// 真机测试用：-mcNoProgress YES 时不上报观看进度——测试播放不写续播点、不进「继续观看」，也不上活动页
    private static var progressDisabled: Bool { UserDefaults.standard.bool(forKey: "mcNoProgress") }
    #endif

    /// 上报观看进度（start / progress / stop 同一入口）。
    /// 分享访客：位置记本机；服务端只收一份「谁在播」的心跳给活动页，靠响应里的 ended_by_admin 退出。
    /// 请求包在后台任务里：切后台、暂停、退出时发出的上报不会因为 App 被挂起而丢在半路。
    @discardableResult
    func progress(_ unit: PlaybackUnit, event: String, positionMs: Int?, durationMs: Int? = nil, paused: Bool? = nil,
                  audio: String?, subtitle: String?, fileId: Int? = nil) async -> API.PlaybackStateView? {
        #if DEBUG
        if Self.progressDisabled { return nil }
        #endif
        let body = progressBody(unit, event: event, positionMs: positionMs, paused: paused, audio: audio, subtitle: subtitle,
                                fileId: fileId)
        #if canImport(UIKit)
        let background = UIApplication.shared.beginBackgroundTask(withName: "playback-progress")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        #endif
        if let shareSlug {
            ShareLocalProgress.write(shareSlug, unit, positionMs: Self.localResume(positionMs, durationMs: durationMs), audio: audio, subtitle: subtitle)
            return try? await api.sharePlaybackProgress(slug: shareSlug, body: body)
        }
        return try? await api.playbackProgress(body: body)
    }

    /// App 即将被结束：同步补发一次 stop，最多等 1.5 秒（异步任务在进程退出前跑不完）
    func stopBeforeTermination(_ unit: PlaybackUnit, positionMs: Int, durationMs: Int?, audio: String?, subtitle: String?,
                               fileId: Int? = nil) {
        #if DEBUG
        if Self.progressDisabled { return }
        #endif
        let body = progressBody(unit, event: "stop", positionMs: positionMs, paused: nil, audio: audio, subtitle: subtitle,
                                fileId: fileId)
        let path: String
        if let shareSlug {
            ShareLocalProgress.write(shareSlug, unit, positionMs: Self.localResume(positionMs, durationMs: durationMs), audio: audio, subtitle: subtitle)
            path = "/share/\(shareSlug)/playback/progress"
        } else {
            path = "/playback/progress"
        }
        var request = URLRequest(url: api.url(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? APIClient.encoder.encode(body)
        let done = DispatchSemaphore(value: 0)
        api.session.dataTask(with: api.authorized(request)) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 1.5)
    }

    /// `audio` / `subtitle` 只给用户亲手选的轨（见 PlaybackController.audioMemory）；`fileId` 是正在放的版本
    private func progressBody(_ unit: PlaybackUnit, event: String, positionMs: Int?, paused: Bool?,
                              audio: String?, subtitle: String?, fileId: Int?) -> API.PlaybackProgressRequest {
        API.PlaybackProgressRequest(
            mediaItemId: unit.mediaItemId, seasonNumber: unit.season, episodeNumber: unit.episode,
            event: event, positionMs: positionMs, audioTrack: audio, subtitleTrack: subtitle,
            fileId: fileId, deviceId: deviceId, paused: paused
        )
    }

    /// 分享访客的本机续播点：看过 90% 或到了片尾就记 0（下次从头放），同服务端 resolve_progress 的口径
    static func localResume(_ positionMs: Int?, durationMs: Int?) -> Int? {
        guard let positionMs, let durationMs, durationMs > 0 else { return positionMs }
        return positionMs * 10 >= durationMs * 9 || positionMs >= durationMs - 1000 ? 0 : positionMs
    }

    // MARK: 遥测（分享访客一律不报）

    func clientLog(_ event: String, _ detail: [String: API.JSONValue]) {
        guard telemetry else { return }
        let api = self.api
        Task { _ = try? await api.playbackClientLog(body: API.PlaybackClientLogPayload(event: event, detail: detail)) }
    }

    func metric(_ payload: API.PlaybackMetricPayload) {
        guard telemetry else { return }
        let api = self.api
        Task { _ = try? await api.playbackMetricReport(body: payload) }
    }

    // MARK: 取流地址

    /// 后端给的是服务器根相对路径（`/api/v1/playback/...`，token 已在里面）
    func streamURL(_ path: String?) -> URL? {
        #if DEBUG
        // 故障注入测试：-mcStreamProxy http://127.0.0.1:3902 让取原文件字节的请求（原文件、光盘镜像、原盘目录里的文件）
        // 经本机代理转发，由代理按测试脚本注入断线、错误码、挂起、限速；开会话等接口照常直连服务器
        if let proxy = UserDefaults.standard.string(forKey: "mcStreamProxy"), let path,
           path.hasPrefix("/api/v1/playback/files/"), let url = URL(string: proxy + path) {
            return url
        }
        #endif
        return api.server.resolve(path)
    }

    /// 从已签名的地址里取 token（诊断、缩略图、原文件直出复用同一份授权）
    static func token(in path: String?) -> String? {
        guard let path, let components = URLComponents(string: path) else { return nil }
        return components.queryItems?.first { $0.name == "token" }?.value
    }
}

/// 播放前的预连（详情页出现时调）：用户进了详情页多半马上要播，把播放要用的两种连接先连好——
/// 起播协商的独立连接池（`APIClient.playbackSession`）与引擎取片源的连接（引擎补丁 P43），点播放时都已握手完毕。
/// 真机（经反向代理的 HTTPS 域名，2026-09-30）：冷连接开会话约 105 毫秒、热连接约 63 毫秒；取流首个请求多一次握手约 20 毫秒。
/// 20 秒内只预连一次；发的是不要鉴权、不读盘的 HEAD 健康检查，全在后台
enum PlaybackPreconnect {
    private static var lastAt: ContinuousClock.Instant?

    static func warm(api: APIClient) {
        #if DEBUG
        // -mcNoPagePreconnect YES：页面出现时不预连（真机新旧对照用）
        if UserDefaults.standard.bool(forKey: "mcNoPagePreconnect") { return }
        #endif
        if let lastAt, ContinuousClock.now - lastAt < .seconds(20) { return }
        guard let health = api.server.resolve("/api/v1/health") else { return }
        lastAt = .now
        Task.detached(priority: .utility) {
            APIClient.preconnectPlayback(health)
            NativeEngine.preconnect(url: health)
        }
    }
}
