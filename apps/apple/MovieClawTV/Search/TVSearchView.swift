import SwiftUI

/// 搜索（docs/design/tvos-app.md §3.1）：系统搜索页——屏幕键盘、Siri 听写、附近 iPhone 的键盘都能输入，
/// **只搜媒体库**（站点资源搜索与下载在电视上不做）。结果按库分行，选中直接进详情。
///
/// 打字停 0.4 秒才搜（同网页的防抖）：屏幕键盘一个字一个字地点，每点一下都搜一次是白费请求。
struct TVSearchView: View {
    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @State private var query = ""
    @State private var groups: [API.LibrarySearchGroupView]?
    @State private var searching = false
    @State private var failed: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if let groups {
                    if groups.isEmpty, !trimmed.isEmpty, !searching {
                        TVStateView(symbol: "magnifyingglass", title: "媒体库里没有找到「\(trimmed)」",
                                    message: "换个关键词试试，片名、原名、拼音首字母都可以。")
                            .frame(height: 420)
                    }
                    ForEach(groups, id: \.libraryId) { group in
                        TVShelf(title: group.libraryName, detail: "\(group.items.count) 部") {
                            ForEach(group.items, id: \.mediaItemId) { item in
                                TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                             imageURL: api.image(item.posterUrl, .posterCard)) {
                                    router.push(.item(libraryId: item.libraryId ?? group.libraryId, itemId: item.mediaItemId))
                                }
                            }
                        }
                    }
                } else if let failed {
                    TVStateView(symbol: "wifi.exclamationmark", title: "搜索失败", message: failed)
                        .frame(height: 420)
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .searchable(text: $query, prompt: "片名、原名或拼音首字母")
        .task(id: trimmed) { await search() }
        .accessibilityIdentifier("tv-search")
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func search() async {
        let keyword = trimmed
        guard !keyword.isEmpty else {
            groups = nil
            failed = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let result = try await api.searchLibraryItems(keyword: keyword)
            guard !Task.isCancelled else { return }
            groups = result.filter { !$0.items.isEmpty }
            failed = nil
        } catch is CancellationError {
        } catch {
            groups = nil
            failed = error.localizedDescription
        }
    }
}
