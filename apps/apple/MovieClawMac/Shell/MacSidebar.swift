import SwiftUI

/// 侧边栏（同 Apple Music 的 Mac 版：顶上搜索框，下面分组列出去处，最底下是账号）。
///
/// - 首页、我的收藏：固定的两项；
/// - 「媒体库」：当前账号能看的每个库一项（图标按库类型），顺序同服务端（管理页里排的顺序）；
/// - 「合集」：网页上设了「显示在首页」的合集，同首页「我的媒体库」行里接在库后面的那些；
/// - 底部：当前账号头像与名字，点开切换账号 / 添加账号 / 关于 / 退出登录。
/// 再点一次当前项退回它的根页面（`MacRouter.select`）。
struct MacSidebar: View {
    @Environment(MacRouter.self) private var router
    @Environment(MacLibraryDirectory.self) private var directory

    private var store: LibraryHomeStore { .shared }

    /// 显示在首页的合集（与首页「我的媒体库」一行同一套判定）
    private var pinnedCollections: [API.CollectionView] {
        guard let libraries = store.libraries else { return [] }
        let rows = HomeRows.build(prefs: LibraryHomePrefs.shared.rows ?? store.snapshotRows ?? [], libraries: libraries,
                                  collections: store.collections)
        return HomeRows.pinnedCollections(rows)
    }

    var body: some View {
        List(selection: Binding<MainTab?>(get: { router.isSearching ? nil : router.selection },
                                          set: { if let tab = $0 { router.searchText = ""; router.select(tab) } })) {
            // 顶上两项也放进一个（无标题）分组：列表里只有散行、没有任何分组时（新服务器还没建库），
            // 侧边栏的内容会顶到标题栏里、搜索框压住红绿灯（实测）；有分组就排得正常
            Section {
                Label("首页", systemImage: "house")
                    .tag(MainTab.home)
                    .accessibilityIdentifier("mac-sidebar-home")
                Label("我的收藏", systemImage: "heart")
                    .tag(MainTab.favorites)
                    .accessibilityIdentifier("mac-sidebar-favorites")
            }
            if !directory.browsable.isEmpty {
                Section("媒体库") {
                    ForEach(directory.browsable, id: \.id) { library in
                        Label(library.name, systemImage: MacLibraryDirectory.symbol(for: library.kind))
                            .badge(library.stats.itemCount)
                            .tag(MainTab.library(library.id))
                            .accessibilityIdentifier("mac-sidebar-library-\(library.id)")
                    }
                }
            }
            if !pinnedCollections.isEmpty {
                Section("合集") {
                    ForEach(pinnedCollections, id: \.id) { collection in
                        Label(collection.name, systemImage: "rectangle.stack")
                            .tag(MainTab.collection(collection.id))
                            .accessibilityIdentifier("mac-sidebar-collection-\(collection.id)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 账号钉在底下，列表从它底下滚过去时带滚动边缘的玻璃虚化（同 Apple Music 侧边栏底部的账号）
        .safeAreaBar(edge: .bottom, spacing: 0) {
            MacAccountButton()
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .accessibilityIdentifier("mac-sidebar")
    }
}
