import SwiftUI

/// 条目详情页的「相似推荐」行（Web `LibrarySimilarRow`）：只推观看者自己库里有的片，
/// 点进去是库内详情。卡片与首页库行同一张海报格。数据由详情页按条目拉一次
/// （``load``）：刮削期间详情接口在轮询，推荐不跟着重拉。
struct LibrarySimilarSection: View {
    let libraryId: Int
    let items: [API.LibraryItemView]

    @Environment(\.api) private var api

    /// 没有相似的片、接口失败、旧服务端没有这个接口，一律给空：调用方据此整段不出
    static func load(api: APIClient, libraryId: Int, itemId: Int) async -> [API.LibraryItemView] {
        (try? await api.uiLibraryItemsSimilar(libraryId: libraryId, mediaItemId: itemId)) ?? []
    }

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
