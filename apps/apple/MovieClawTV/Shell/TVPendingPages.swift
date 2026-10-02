import SwiftUI

// T1 实现的页面（docs/design/tvos-app.md §7）：先占位让 T0 的播放器链路能编译运行。

struct TVHomeView: View {
    var body: some View { TVPlaceholderPage(title: "首页") }
}

struct TVLibraryView: View {
    let libraryId: Int
    var body: some View { TVPlaceholderPage(title: "媒体库 \(libraryId)") }
}

struct TVAllLibrariesView: View {
    var body: some View { TVPlaceholderPage(title: "全部媒体库") }
}

struct TVSearchView: View {
    var body: some View { TVPlaceholderPage(title: "搜索") }
}

struct TVItemDetailView: View {
    let itemId: Int
    var body: some View { TVPlaceholderPage(title: "条目 \(itemId)") }
}
