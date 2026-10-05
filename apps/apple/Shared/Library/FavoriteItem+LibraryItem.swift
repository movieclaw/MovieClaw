import Foundation

extension API.FavoriteItemView {
    /// 收藏条目与库存条目字段同构（多出的收藏层级不上墙）：转成库存条目以复用海报墙的格子（iPhone 的收藏墙、电视「查看全部」共用）
    var asLibraryItem: API.LibraryItemView {
        API.LibraryItemView(
            mediaItemId: mediaItemId, kind: kind, libraryId: libraryId, source: source, tmdbId: tmdbId,
            title: title, year: year, posterUrl: posterUrl, backdropUrl: backdropUrl, primaryAspect: primaryAspect,
            releaseDate: releaseDate, rating: rating, posterBlur: posterBlur, primaryFileId: primaryFileId,
            fileCount: fileCount, totalSizeBytes: totalSizeBytes, seasons: seasons, episodeCount: episodeCount,
            resolutions: resolutions, missingCount: missingCount, airStatus: airStatus,
            missingEpisodeCount: missingEpisodeCount, addedAt: addedAt, isFavorite: isFavorite,
            recentAddition: recentAddition, inventorySummary: inventorySummary, probePendingCount: probePendingCount
        )
    }
}
