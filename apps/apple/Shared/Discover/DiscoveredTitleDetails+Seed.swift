import Foundation

// MARK: - 首屏预存

extension API.DiscoveredTitleDetailsView {
    /// 列表字段拼出的半份详情（同 Web 详情页 `detail?.item ?? listItem`）：只有标题区可用，
    /// 演职员、预告片、剧照、推荐等分区为空不渲染，等详情接口返回后整体替换。
    init(seed item: DiscoverPosterItem) {
        self.init(
            title: API.DiscoveredTitleView(
                titleRef: item.resolvedTitleRef,
                provider: item.source,
                externalId: item.externalId,
                mediaType: item.mediaType,
                title: item.title,
                originalTitle: item.originalTitle,
                releaseYear: item.year,
                providerRating: item.rating,
                genres: item.genres,
                extentLabel: item.extent,
                overview: item.overview,
                posterUrl: item.posterUrl ?? "",
                backdropUrl: item.backdropUrl,
                libraryStatus: item.libraryStatus
            ),
            metadata: API.DiscoveredTitleMetadata(
                directors: [], directorCredits: [], cast: [], country: "", language: "", released: "",
                network: nil, aliases: [], sourceUrl: nil
            ),
            backdropOriginalUrl: nil,
            videos: [],
            backdrops: [],
            posters: [],
            collection: nil,
            recommendations: [],
            libraryLinks: []
        )
    }
}
