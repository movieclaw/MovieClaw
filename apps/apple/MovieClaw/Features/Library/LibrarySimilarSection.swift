import SwiftUI

/// 条目详情页的「相似推荐」行（Web `LibrarySimilarRow`）：只推观看者自己库里有的片，
/// 点进去是库内详情。卡片与首页库行同一张海报格。数据由详情页按条目拉一次（`ItemRelated`）：
/// 刮削期间详情接口在轮询，推荐不跟着重拉
struct LibrarySimilarSection: View {
    let libraryId: Int
    let items: [API.LibraryItemView]

    @Environment(\.api) private var api

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibrarySectionHeader(title: "相似推荐")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.mediaItemId) { item in
                        NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId ?? libraryId, itemId: item.mediaItemId)) {
                            LibraryPosterCell(title: item.title, year: item.year,
                                              url: api.image(item.posterUrl, width: ImageWidth.points(PhoneCardWidth.homePoster)),
                                              imageAspect: item.primaryAspect)
                                .frame(width: PhoneCardWidth.homePoster)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library-similar-\(item.mediaItemId)")
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
            .scrollClipDisabled()
        }
    }
}

/// 电影的作品系列一行（排在相似推荐下面，同 Apple TV / Mac / Web）：整个系列按上映顺序，标题旁写「已有 7 / 共 8」。
/// 这一部标「本片」；库里有的点进库内详情；缺的那部与合集页同一张缺片卡（压暗，点进 TMDB 详情、长按订阅）
struct LibrarySeriesSection: View {
    let series: API.CollectionSeriesView
    let libraryId: Int
    let itemId: Int

    @Environment(\.api) private var api

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibrarySectionHeader(title: series.seriesName ?? "系列") {
                Text("已有 \(series.ownedCount) / 共 \(series.total)")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(series.parts, id: \.tmdbId) { part in
                        cell(part).frame(width: PhoneCardWidth.homePoster)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func cell(_ part: API.SeriesPartView) -> some View {
        if let id = part.mediaItemId {
            let poster = LibraryPosterCell(title: part.title, year: part.releaseDate.flatMap { Int($0.prefix(4)) },
                                           url: api.image(part.posterUrl, width: ImageWidth.points(PhoneCardWidth.homePoster)),
                                           cornerLabel: id == itemId ? "本片" : nil)
            if id == itemId {
                poster
            } else {
                NavigationLink(value: AppRoute.libraryItem(libraryId: libraryId, itemId: id)) { poster }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library-series-\(id)")
            }
        } else {
            MissingPartCell(part: part, imageWidth: PhoneCardWidth.homePoster)
        }
    }
}
