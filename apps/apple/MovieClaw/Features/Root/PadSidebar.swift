import SwiftUI

/// iPad 侧边栏里「首页」下面那几组（docs/design/ipad.md §3，照 Mac 版 `MacSidebar`）：
/// 我的收藏；「媒体库」逐个列库（带部数，顺序同服务端）；「合集」列网页上设了「显示在首页」的合集。
/// 它们只在侧边栏里出现（`defaultVisibility(.hidden, for: .tabBar)`，要配合 `tabViewCustomization` 才生效），
/// 顶部标签栏仍是固定的几个页签。
/// 数据取首页同一份（`LibraryHomeStore`，冷启动有快照），口径同首页「我的媒体库」一行。
struct PadSidebarLibraryTabs: @MainActor TabContent {
    private var store: LibraryHomeStore { .shared }

    /// 能浏览的库（没有访问权限的不列）
    private var libraries: [API.LibraryView] {
        (store.libraries ?? []).filter(\.viewerAccess)
    }

    /// 显示在首页的合集（与首页「我的媒体库」一行同一套判定）
    private var pinnedCollections: [API.CollectionView] {
        guard let libraries = store.libraries else { return [] }
        let rows = HomeRows.build(prefs: LibraryHomePrefs.shared.rows ?? store.snapshotRows ?? [], libraries: libraries,
                                  collections: store.collections)
        return HomeRows.pinnedCollections(rows)
    }

    var body: some TabContent<ShellTab> {
        Tab("我的收藏", systemImage: "heart", value: ShellTab.favorites) {
            TabRoot(item: .favorites) { FavoritesView() }
        }
        .customizationID("pad.favorites")
        .defaultVisibility(.hidden, for: .tabBar)
        TabSection("媒体库") {
            ForEach(libraries, id: \.id) { library in
                Tab(library.name, systemImage: Self.symbol(for: library.kind), value: ShellTab.mediaLibrary(library.id)) {
                    TabRoot(item: .mediaLibrary(library.id)) { LibraryDetailView(libraryId: library.id) }
                }
                .badge(library.stats.itemCount)
                .accessibilityIdentifier("pad-sidebar-library-\(library.id)")
                .customizationID("pad.library.\(library.id)")
            }
        }
        .customizationID("pad.libraries")
        .defaultVisibility(.hidden, for: .tabBar)
        TabSection("合集") {
            ForEach(pinnedCollections, id: \.id) { collection in
                Tab(collection.name, systemImage: "rectangle.stack", value: ShellTab.collection(collection.id)) {
                    TabRoot(item: .collection(collection.id)) { CollectionDetailView(libraryId: nil, collectionId: collection.id) }
                }
                .badge(collection.itemCount)
                .accessibilityIdentifier("pad-sidebar-collection-\(collection.id)")
                .customizationID("pad.collection.\(collection.id)")
            }
        }
        .customizationID("pad.collections")
        .defaultVisibility(.hidden, for: .tabBar)
    }

    /// 侧边栏图标：电影 / 剧集 / 照片 / 其他视频（同 Mac 版）
    static func symbol(for kind: String) -> String {
        switch kind {
        case "movie": "film"
        case "tv": "tv"
        case "photo": "photo.on.rectangle"
        default: "play.rectangle"
        }
    }
}
