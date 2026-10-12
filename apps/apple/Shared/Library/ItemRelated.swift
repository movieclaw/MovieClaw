import Foundation

/// 条目详情页下面「相似推荐 + 作品系列」两行的数据（iPhone / Apple TV / Mac 同一套规则，同 Web `LibraryRelatedRows`）。
///
/// 顺序是演职员 → 相似推荐 → 系列（2026-10-12 用户定）。电影有系列一行时，相似推荐排除同系列的片——
/// 系列那一行已经按上映顺序列全了，相似推荐留给系列之外的片。
///
/// 系列一行只在拉得到上游档案、且不止一部时才出（本地 NFO 定的系列没有上游档案）。两个请求并行发：
/// 先按「有系列合集」排除同系列，系列一行最后没出来时再拉一次不排除的——否则续集哪儿都看不到。
enum ItemRelated {
    struct Rows {
        var similar: [API.LibraryItemView] = []
        var series: API.CollectionSeriesView?
    }

    static func load(api: APIClient, libraryId: Int, detail: API.LibraryItemDetailView) async -> Rows {
        let seriesId = detail.kind != "tv" ? detail.seriesCollectionId : nil
        async let similarItems = similar(api: api, libraryId: libraryId, itemId: detail.mediaItemId, excludeSeries: seriesId != nil)
        async let seriesRow = series(api: api, collectionId: seriesId)
        let series = await seriesRow
        var items = await similarItems
        if seriesId != nil, series == nil {
            items = await similar(api: api, libraryId: libraryId, itemId: detail.mediaItemId, excludeSeries: false)
        }
        return Rows(similar: items, series: series)
    }

    /// 没有相似的片、接口失败、旧服务端没有这个接口，一律给空：调用方据此整行不出
    private static func similar(api: APIClient, libraryId: Int, itemId: Int, excludeSeries: Bool) async -> [API.LibraryItemView] {
        (try? await api.uiLibraryItemsSimilar(libraryId: libraryId, mediaItemId: itemId, excludeSeries: excludeSeries ? true : nil)) ?? []
    }

    /// 电影所属的作品系列：只有一部、或拉不到上游档案时不出这一行
    private static func series(api: APIClient, collectionId: Int?) async -> API.CollectionSeriesView? {
        guard let collectionId, let fresh = try? await api.collectionSeriesGet(collectionId: collectionId),
              fresh.available, fresh.parts.count > 1 else { return nil }
        return fresh
    }
}
