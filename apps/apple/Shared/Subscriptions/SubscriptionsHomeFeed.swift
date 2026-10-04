import SwiftUI

/// 订阅首页与「全部」海报墙共用的数据源，以及排好的整页结果。
///
/// 为什么是一个共享对象而不是页面各自的 @State：
/// - 海报墙必须和首页那一排讲同一套顺序与状态签（从首页点「›」进去，顺序不能变），
///   两页读的是同一份算好的结果，口径不可能分叉；
/// - 海报墙不必为此再打一遍预告 / 刚刚入库 / 下载快照三个接口，首页取到的直接复用；
/// - 排序只在数据真的变化时算一次：Hero 每 8 秒换一张、页面底色交叉淡入都会让首页重算 body，
///   `state(for:)` 按输入指纹命中缓存，订阅再多也不会每次重排。
///
/// 单例跨账号存活，所以记着属于谁（服务器地址 + 用户名，同 SubscriptionIndex）：换账号即清空，
/// 刷新期间换了账号的迟到结果直接丢弃，不串到别的账号上。
///
/// 快照（`PageSnapshots`）：整页三份数据每次刷齐都存在本机，登录恢复的那一刻（`adopt`）就在后台读出来，
/// 订阅首页第一帧就是上次的完整样子（Hero、日程、两排海报），随后静默刷新。整周预告按天算
/// （「今天」「周四」），隔天的快照不用它，等网络的新数据。
@MainActor
@Observable
final class SubscriptionsHomeFeed {
    static let shared = SubscriptionsHomeFeed()

    /// 整周预告；nil = 还没取到（与「取到了但一周都没安排」的空数组区分）
    private(set) var week: [API.TodayArrivalView]?
    private(set) var recent: [API.RecentArrivalView] = []
    private(set) var tasks: [API.DownloadTaskView] = []
    /// 算「几点能看」「多久前入库」用的当前时刻，随预告一起刷新
    private(set) var now = Date()
    /// 整页数据至少齐过一次（刷齐了，或来自快照）：页面据此判断是否已是完整的样子
    private(set) var loaded = false

    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var cache: (key: Int, state: SubsHomeState)?

    static func ownerKey(api: APIClient, username: String?) -> String {
        "\(api.server.apiBase.absoluteString)|\(username ?? "")"
    }

    /// 以这个账号的身份使用：换了账号就清掉旧账号的数据与缓存，并读出这个账号的快照。
    /// `synchronously`：冷启动就落在订阅首页时当场读完；其余情况在后台线程读
    /// 返回值：后台读快照的任务（同步读、没换账号时为 nil）
    @discardableResult
    func adopt(owner key: String, synchronously: Bool = false) -> Task<Void, Never>? {
        guard key != owner else { return nil }
        owner = key
        week = nil
        recent = []
        tasks = []
        loaded = false
        refreshedAt = nil
        cache = nil
        savedFingerprint = nil
        savedAt = nil
        if synchronously {
            if let snapshot = PageSnapshots.read(SubscriptionsFeedSnapshot.self, Self.snapshotName, owner: key) { apply(snapshot, owner: key) }
            return nil
        }
        // 读盘立刻在后台线程开始（不等主线程空下来）；读完交回主线程
        let read = Task.detached(priority: .userInitiated) {
            PageSnapshots.read(SubscriptionsFeedSnapshot.self, Self.snapshotName, owner: key)
        }
        return Task {
            if let snapshot = await read.value { apply(snapshot, owner: key) }
        }
    }

    private func apply(_ snapshot: SubscriptionsFeedSnapshot, owner key: String) {
        // 读盘期间换了账号，或网络已经先一步刷齐：快照作废
        guard owner == key, !loaded else { return }
        if Calendar.current.isDateInToday(snapshot.savedAt) { week = snapshot.week }
        recent = snapshot.recent
        tasks = snapshot.tasks
        now = .now
        loaded = true
        PerfTrace.record("snapshot.applied", ["page": "subscriptions"])
    }

    private nonisolated static let snapshotName = "subscriptions-feed"

    /// 上次写盘的内容指纹：没变就不重写
    @ObservationIgnored private var savedFingerprint: Int?

    private func saveSnapshot() {
        guard let owner, let week else { return }
        var hasher = Hasher()
        hasher.combine(week)
        hasher.combine(recent)
        hasher.combine(tasks)
        let fingerprint = hasher.finalize()
        // 预告按天算：跨天后内容没变也要重写一次，快照的日期才对得上「今天」
        guard fingerprint != savedFingerprint || !Calendar.current.isDateInToday(savedAt ?? .distantPast) else { return }
        savedFingerprint = fingerprint
        savedAt = .now
        PageSnapshots.write(SubscriptionsFeedSnapshot(savedAt: .now, week: week, recent: recent, tasks: tasks), Self.snapshotName, owner: owner)
    }

    @ObservationIgnored private var savedAt: Date?

    /// 算好的整页结果。输入（订阅清单、预告、刚刚入库、下载快照、时刻）没变就直接复用上一次
    func state(for subscriptions: [API.SubscriptionView]) -> SubsHomeState {
        var hasher = Hasher()
        hasher.combine(subscriptions)
        hasher.combine(week)
        hasher.combine(recent)
        hasher.combine(tasks)
        hasher.combine(now)
        let key = hasher.finalize()
        if let cache, cache.key == key { return cache.state }
        let state = SubscriptionsHome.state(
            subscriptions: subscriptions, week: week ?? [], recent: recent, tasks: tasks, now: now
        )
        cache = (key, state)
        return state
    }

    // MARK: 刷新

    /// 海报墙打开时用：首页刚刷过就不再打接口（首页自己有 10 秒轮询）
    func refreshIfStale(api: APIClient, isAdmin: Bool, maxAge: TimeInterval = 30) async {
        if let refreshedAt, Date.now.timeIntervalSince(refreshedAt) < maxAge { return }
        await refreshAll(api: api, isAdmin: isAdmin)
    }

    func refreshAll(api: APIClient, isAdmin: Bool) async {
        let key = owner
        async let arrivals: Void = refreshArrivals(api: api)
        async let arrived: Void = refreshRecent(api: api)
        async let snapshot: Void = refreshTasks(api: api, isAdmin: isAdmin)
        _ = await (arrivals, arrived, snapshot)
        guard key == owner else { return }
        loaded = true
        saveSnapshot()
    }

    /// 整周预告：已有快照时瞬时失败继续保留，不闪成空
    func refreshArrivals(api: APIClient) async {
        let key = owner
        do {
            let list = try await api.subscriptionsListTodayArrivals(window: "week")
            guard key == owner else { return }
            week = list
            now = .now
            refreshedAt = .now
        } catch is CancellationError {
        } catch {
            if key == owner, week == nil { week = [] }
        }
    }

    /// 刚刚入库：老版本服务端没有这个接口（404）或瞬时失败时保持原样，这一行不出现 / 不闪
    func refreshRecent(api: APIClient) async {
        let key = owner
        if let list = try? await api.subscriptionsListRecentArrivals(), key == owner {
            recent = list
        }
    }

    /// 下载任务快照（管理员）：「下载中」的进度与预计时间用下载器实时数据修正
    func refreshTasks(api: APIClient, isAdmin: Bool) async {
        guard isAdmin else { return }
        let key = owner
        if let list = try? await api.dlTasks(), key == owner {
            tasks = list.items
        }
    }
}

/// 订阅首页的快照（`PageSnapshots`）：整周预告、刚刚入库、下载快照（订阅清单本身在 SubscriptionIndex 的快照里）
nonisolated struct SubscriptionsFeedSnapshot: Codable, Sendable {
    var savedAt: Date
    var week: [API.TodayArrivalView]
    var recent: [API.RecentArrivalView]
    var tasks: [API.DownloadTaskView]
}

extension SubscriptionsHomeFeed {
    /// 订阅首页首屏会显示的图（与页面排版同一口径，交给 `FirstScreenImages` 提前解码进内存）：
    /// Hero 第一张的剧照与片名 Logo、「刚刚入库」前两张卡的剧照与 Logo
    func firstScreenImageURLs(subscriptions: [API.SubscriptionView], api: APIClient) -> [URL] {
        var urls: [URL?] = []
        if let slide = state(for: subscriptions).slides.first {
            urls.append(SubsHomeHeroImage.url(slide, api: api))
            urls.append(SubsHomeHeroImage.logoURL(slide, api: api))
        }
        for card in recent.prefix(2) {
            urls.append(api.image(card.stillUrl ?? card.media.backdropUrl ?? card.media.posterUrl,
                                  width: ImageWidth.points(PhoneCardWidth.recent)))
            urls.append(api.image(card.media.logoUrl, width: ImageWidth.points(PhoneCardWidth.recentLogo)))
        }
        return urls.compactMap { $0 }
    }
}

/// 订阅首页 Hero 的取图口径（iPhone 与 Apple TV 同一套；页面显示、氛围取色、轮播预载与首屏预载共用同一个地址）
enum SubsHomeHeroImage {
    /// 剧照：TMDB 图先换成 original 档再经代理按 Hero 需要的宽度缩（Hero 把 16:9 横图放大裁切铺满大区域，
    /// 发现接口给的 w1280 会糊）；没有剧照（老条目还没刷新到）退回海报铺满
    static func url(_ slide: SubsHomeHeroSlide, api: APIClient) -> URL? {
        api.server.originalTMDBImageURL(slide.media.backdropUrl, width: width) ?? api.image(slide.media.posterUrl, width: width)
    }

    /// 片名 Logo：iPhone Hero 里等比装进 240×88 的框
    static func logoURL(_ slide: SubsHomeHeroSlide, api: APIClient) -> URL? {
        api.image(slide.media.logoUrl, width: ImageWidth.points(logoWidth))
    }

    static let logoWidth: CGFloat = 240

    /// 电视 Hero 铺满整屏宽（1920×760 点，按宽算）→ 屏宽像素；iPhone 是屏宽 × 500 的竖框，铺满 16:9 要按高算
    private static var width: Int {
        #if os(tvOS) || os(macOS)
        ImageWidth.screen
        #else
        ImageWidth.phoneHero(height: SubsHomeHero.height)
        #endif
    }
}
