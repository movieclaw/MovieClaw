import SwiftUI

/// 全站订阅状态索引（对应 Web `components/subscribe-entry.tsx` 的 SubscribeEntryProvider）。
///
/// 海报卡片散落在发现页、详情页、搜索结果、影人页、AI 卡片等多层页面里，
/// 「这部片订阅了没有」不该由每张卡片各自去问后端——这里统一拉一次 `GET /subscriptions`，
/// 建三张查表索引，卡片与按钮用 `subscription(source:externalId:mediaType:)` O(1) 判断。
///
/// 匹配口径与 Web 一致：
/// - 豆瓣来源按 `douban_id` 匹配（从 TMDB 入口建立、未关联豆瓣 ID 的订阅匹配不到——已知限制，不按标题猜）；
/// - TMDB 来源按 `tmdb_id` 匹配；电影与剧集是两个独立号段，带类型时用它消歧，缺类型时仅按 ID。
///
/// 刷新时机：页面首次出现（`ensureLoaded`，30 秒内不重复拉）、订阅弹层关闭后（`.tracksSubscriptionIndex()`
/// 监听 Router.sheet 自动刷新）。拉取失败不覆盖已有数据——状态降级为「都未订阅」，不影响订阅入口本身。
///
/// 账号隔离：索引按「服务器 + 用户名」记主人，切换账号后首次访问自动清空重拉，
/// 不会把上个账号的订阅状态带到下个账号。
///
/// 快照（`PageSnapshots`）：每次拉取成功都把清单存在本机，登录恢复的那一刻（`adopt`）就在后台读出来——
/// 冷启动的订阅首页、发现页海报的「已订阅」角标第一帧就有，随后照常重拉（快照不算「刚拉过」）。
@Observable
final class SubscriptionIndex {
    static let shared = SubscriptionIndex()

    /// 全部订阅；nil = 首次拉取尚未完成
    private(set) var subscriptions: [API.SubscriptionView]?

    @ObservationIgnored private var byDouban: [String: API.SubscriptionView] = [:]
    @ObservationIgnored private var byTmdbTyped: [String: API.SubscriptionView] = [:]
    @ObservationIgnored private var byTmdb: [String: API.SubscriptionView] = [:]
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var inFlight: Task<Bool, Never>?
    /// 上次写盘的清单指纹：没变就不重写快照
    @ObservationIgnored private var savedFingerprint: Int?

    private nonisolated static let snapshotName = "subscriptions"

    /// 以这个账号的身份使用：换了账号就清空旧账号的索引，并读出这个账号的快照。
    /// `synchronously`：冷启动就落在订阅首页时当场读完，保证第一帧就是完整页面；其余情况在后台线程读
    /// 返回值：后台读快照的任务（同步读、没换账号时为 nil）
    @discardableResult
    func adopt(api: APIClient, owner: String?, synchronously: Bool = false) -> Task<Void, Never>? {
        let key = Self.ownerKey(api: api, owner: owner)
        guard key != self.owner else { return nil }
        reset(owner: key)
        if synchronously {
            if let list = PageSnapshots.read([API.SubscriptionView].self, Self.snapshotName, owner: key) { applySnapshot(list, owner: key) }
            return nil
        }
        // 读盘立刻在后台线程开始（不等主线程空下来）；读完交回主线程
        let read = Task.detached(priority: .userInitiated) {
            PageSnapshots.read([API.SubscriptionView].self, Self.snapshotName, owner: key)
        }
        return Task {
            if let list = await read.value { applySnapshot(list, owner: key) }
        }
    }

    private func applySnapshot(_ list: [API.SubscriptionView], owner key: String) {
        // 读盘期间换了账号，或网络已经先一步拿到了清单：快照作废
        guard self.owner == key, subscriptions == nil else { return }
        apply(list, fresh: false)
        PerfTrace.record("snapshot.applied", ["page": "subscriptions-index"])
    }

    /// 距上次成功拉取超过 maxAge 秒（或换了账号）才重新拉取
    func ensureLoaded(api: APIClient, owner: String?, maxAge: TimeInterval = 30) async {
        let key = Self.ownerKey(api: api, owner: owner)
        if key != self.owner {
            adopt(api: api, owner: owner)
        } else if let loadedAt, Date.now.timeIntervalSince(loadedAt) < maxAge {
            return
        }
        _ = await refresh(api: api, owner: owner)
    }

    /// 立即重拉；返回是否成功。并发调用合并为同一次请求。
    @discardableResult
    func refresh(api: APIClient, owner: String?) async -> Bool {
        let key = Self.ownerKey(api: api, owner: owner)
        if key != self.owner { adopt(api: api, owner: owner) }
        if let inFlight { return await inFlight.value }
        let task = Task { () -> Bool in
            do {
                let list = try await api.subscriptionsList()
                guard self.owner == key else { return false }
                apply(list, fresh: true)
                let fingerprint = list.hashValue
                if fingerprint != savedFingerprint {
                    savedFingerprint = fingerprint
                    PageSnapshots.write(list, Self.snapshotName, owner: key)
                }
                return true
            } catch {
                return false
            }
        }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        return ok
    }

    /// 查找某部作品已存在的订阅；未订阅或尚未加载返回 nil
    func subscription(source: String?, externalId: String, mediaType: String?) -> API.SubscriptionView? {
        // 查表本身不参与观察：先读一次可观察的 subscriptions，让调用它的视图在索引到达/刷新后重绘
        _ = subscriptions
        if (source ?? "tmdb") == "douban" { return byDouban[externalId] }
        if let mediaType, mediaType == "movie" || mediaType == "tv" {
            return byTmdbTyped["\(externalId):\(mediaType)"]
        }
        return byTmdb[externalId]
    }

    func subscription(for item: DiscoverPosterItem) -> API.SubscriptionView? {
        subscription(source: item.source, externalId: item.externalId, mediaType: item.mediaType)
    }

    /// `fresh = false`：来自快照，不算「刚拉过」，下一次 ensureLoaded 照常重拉
    private func apply(_ list: [API.SubscriptionView], fresh: Bool) {
        var douban: [String: API.SubscriptionView] = [:]
        var typed: [String: API.SubscriptionView] = [:]
        var plain: [String: API.SubscriptionView] = [:]
        // 同键保留首条（与 Web 一致）
        for sub in list {
            if let doubanId = sub.media.doubanId, !doubanId.isEmpty, douban[doubanId] == nil {
                douban[doubanId] = sub
            }
            let id = String(sub.media.tmdbId)
            let typedKey = "\(id):\(sub.media.kind)"
            if typed[typedKey] == nil { typed[typedKey] = sub }
            if plain[id] == nil { plain[id] = sub }
        }
        byDouban = douban
        byTmdbTyped = typed
        byTmdb = plain
        loadedAt = fresh ? .now : nil
        subscriptions = list
    }

    private func reset(owner key: String) {
        owner = key
        loadedAt = nil
        inFlight = nil
        byDouban = [:]
        byTmdbTyped = [:]
        byTmdb = [:]
        subscriptions = nil
    }

    static func ownerKey(api: APIClient, owner: String?) -> String {
        "\(api.server.apiBase.absoluteString)|\(owner ?? "")"
    }
}

/// 订阅状态的展示元数据与进度文案（同 Web `lib/subscription-ui.ts`）
enum SubscriptionStatusMeta {
    static func label(_ status: String) -> String {
        switch status {
        case "completed": "已收齐"
        case "paused": "已暂停"
        default: "追踪中"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "completed": Theme.success
        case "paused": Theme.warning
        default: Color(red: 0x6A / 255, green: 0xA7 / 255, blue: 1)
        }
    }

    /// 进度说明：回答「还缺多少 / 入库了多少」
    static func progressNote(_ sub: API.SubscriptionView) -> String {
        let p = sub.progress
        if sub.status == "paused" { return "暂停追踪" }
        let inPipeline = p.grabbed + p.downloaded
        let isMovie = sub.media.kind == "movie"
        if p.wanted == 0 {
            if isMovie { return p.imported > 0 ? "已入库" : inPipeline > 0 ? "下载安排中" : "已收齐" }
            if inPipeline > 0 { return "\(inPipeline) 集下载中 · 已入库 \(p.imported)" }
            if sub.status == "active" { return "等待新集播出" }
            return p.imported > 0 ? "全部 \(p.total) 集已入库" : "全部 \(p.total) 集已安排"
        }
        if isMovie { return "正在寻找资源" }
        let detail = [
            inPipeline > 0 ? "\(inPipeline) 集下载中" : nil,
            p.imported > 0 ? "已入库 \(p.imported)" : nil,
        ].compactMap { $0 }
        return detail.isEmpty ? "缺 \(p.wanted) 集" : "缺 \(p.wanted) 集 · \(detail.joined(separator: " · "))"
    }
}
