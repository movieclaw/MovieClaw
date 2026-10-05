import Foundation

/// 发现页的本机快照（同媒体库 / 订阅首页的做法，见 `PageSnapshots`）：每个视角（类型 × 数据源）刷新成功后
/// 存下版面、Hero 与各行，下次冷启动落在发现页、或第一次切到这个视角时，先原样画出上次的完整页面再刷新。
///
/// 发现页的数据来自 TMDB（经后端），NAS 上一次冷启动要二十来个请求、排队加服务端近 1 秒；片单一天之内
/// 变化不大，先看上次的、再换成最新的，比对着骨架等更好。按「服务器 + 账号」隔离，账号退出时随
/// `PageSnapshots.remove(owner:)` 一起删掉。
enum DiscoverSnapshots {
    private static var owner: String?
    private static var loaded: [String: DiscoverFeedSnapshot] = [:]

    private static func key(_ mediaType: String, _ provider: String) -> String { "discover-\(mediaType)-\(provider)" }

    /// 账号就绪时调用：读出这个账号的快照。`synchronously` 用于冷启动就落在发现页（电影 · TMDB）
    static func adopt(owner key: String, synchronously: Bool) {
        guard key != owner else { return }
        owner = key
        loaded = [:]
        var names = [Self.key("movie", "tmdb"), Self.key("tv", "tmdb")]
        if synchronously {
            // 落地页只有电影视角，当场读它；剧集视角照样在后台读
            loaded[names[0]] = PageSnapshots.read(DiscoverFeedSnapshot.self, names[0], owner: key)
            names.removeFirst()
        }
        let pending = names
        Task {
            let read = await Task.detached(priority: .utility) {
                pending.reduce(into: [String: DiscoverFeedSnapshot]()) { result, name in
                    result[name] = PageSnapshots.read(DiscoverFeedSnapshot.self, name, owner: key)
                }
            }.value
            guard owner == key else { return }
            loaded.merge(read) { current, _ in current }
        }
    }

    static func snapshot(mediaType: String, provider: String) -> DiscoverFeedSnapshot? {
        loaded[key(mediaType, provider)]
    }

    static func save(_ snapshot: DiscoverFeedSnapshot, mediaType: String, provider: String) {
        guard let owner else { return }
        let name = key(mediaType, provider)
        guard loaded[name] != snapshot else { return }
        loaded[name] = snapshot
        PageSnapshots.write(snapshot, name, owner: owner)
    }
}

/// 一个视角的发现页快照
nonisolated struct DiscoverFeedSnapshot: Codable, Hashable, Sendable {
    var layout: API.DiscoveryPageView
    var hero: [DiscoverPosterItem]?
    var rows: [String: [DiscoverPosterItem]]
}
