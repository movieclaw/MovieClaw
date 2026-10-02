import Foundation

/// 海报卡片的最小视觉契约（对应 Web `PosterVisualItem`）。
///
/// 发现页、搜索影视结果、影人作品、详情页相似推荐、媒体库搜索结果（以及后续 AI 卡片）
/// 都画成同一种海报卡，数据先各自映射成它。字段缺失就不显示（豆瓣轻量搜索没有年份与类型）。
nonisolated struct DiscoverPosterItem: Identifiable, Hashable, Sendable, Codable {
    /// 服务端签发的稳定引用（`tmdb:movie:550` / `douban:1292052`）；历史快照/本地条目可能没有
    var titleRef: String?
    /// 来源站条目 ID
    var externalId: String
    /// tmdb / douban
    var source: String = "tmdb"
    /// movie / tv；豆瓣轻量结果为空
    var mediaType: String?
    var title: String
    var originalTitle: String = ""
    var year: Int?
    /// 0 表示暂无评分（不渲染徽章，避免读成「0 分」）
    var rating: Double = 0
    var posterUrl: String?
    var backdropUrl: String?
    var genres: [String] = []
    /// 规模：电影片长 / 剧集季数；列表数据常为空
    var extent: String = ""
    var overview: String = ""
    /// 有在位文件时的库存摘要：自动打「已入库」绿斜标
    var libraryStatus: API.MediaLibraryStatus?
    /// 当前观看者已收藏（右上角红心）
    var favorite: Bool = false
    /// 调用方显式指定的斜标（优先于「已入库」「已订阅」的自动派生）
    var ribbon: DiscoverRibbon?
    /// 卡片框宽高比（缺省 2:3；本地抓帧缩略图是 16:9）
    var aspect: CGFloat = 2.0 / 3.0

    var id: String { titleRef ?? "\(source):\(mediaType ?? "-"):\(externalId)" }

    /// 进详情用的引用：优先服务端 titleRef，没有时按 Web `titleRef()` 规则拼
    var resolvedTitleRef: String {
        if let titleRef, !titleRef.isEmpty { return titleRef }
        return source == "douban" ? "douban:\(externalId)" : "tmdb:\(mediaType ?? "movie"):\(externalId)"
    }

    var typeLabel: String? {
        switch mediaType {
        case "movie": "电影"
        case "tv": "剧集"
        default: nil
        }
    }
}

nonisolated extension DiscoverPosterItem {
    /// 发现/搜索接口的条目摘要 → 海报卡
    init(_ dto: API.DiscoveredTitleView) {
        self.init(
            titleRef: dto.titleRef,
            externalId: dto.externalId,
            source: dto.provider,
            mediaType: dto.mediaType,
            title: dto.title,
            originalTitle: dto.originalTitle,
            year: dto.releaseYear,
            rating: dto.providerRating,
            posterUrl: dto.posterUrl.isEmpty ? nil : dto.posterUrl,
            backdropUrl: dto.backdropUrl,
            genres: dto.genres,
            extent: dto.extentLabel,
            overview: dto.overview,
            libraryStatus: dto.libraryStatus
        )
    }
}

/// 海报角上的斜标
nonisolated struct DiscoverRibbon: Hashable, Sendable, Codable {
    enum Tone: Hashable, Codable { case owned, subscribed }
    var label: String
    var tone: Tone
}

/// 详情页首屏预存（同 Web `getMediaSeed`）：站内点海报卡 / Hero 进详情前记下列表字段，
/// 详情页先用它渲染标题、海报、简介等，接口返回后原位替换；有预存时详情接口失败也不打断页面。
enum DiscoverMediaSeed {
    private static var items: [String: DiscoverPosterItem] = [:]

    static func remember(_ item: DiscoverPosterItem) {
        if items.count >= 200 { items.removeAll() }
        items[item.resolvedTitleRef] = item
    }

    static func item(for titleRef: String) -> DiscoverPosterItem? {
        items[titleRef]
    }
}
