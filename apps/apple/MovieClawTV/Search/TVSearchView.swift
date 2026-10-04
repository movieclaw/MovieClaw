import SwiftUI

/// 电视搜索：系统键盘、听写、iPhone 输入共用名称与人物检索。
/// 输入时更新相关度，进入结果浏览后不主动重搜；分页只追加，详情返回保留焦点。
/// 命中的人物是一排小一号的演职员头像卡，按确认进影人页——与条目详情「演职员」同一个入口、同一个页面。
struct TVSearchView: View {
    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @State private var query = ""
    @State private var model = TVSearchModel()
    @FocusState private var focusedItem: Int?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var input: TVSearchInput { .init(query: trimmed) }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                if model.searching {
                    ProgressView("正在搜索…").padding(.horizontal, TVMetrics.edge)
                }
                if !model.people.isEmpty {
                    TVShelf(title: "人物") {
                        ForEach(model.people, id: \.id) { person in
                            TVPersonCard(name: person.name, role: "库内 \(person.itemCount) 部",
                                         avatarURL: api.image(person.avatarUrl,
                                                              width: TVPersonCard.imageWidth(TVPersonCard.searchAvatarSize)),
                                         avatarSize: TVPersonCard.searchAvatarSize) {
                                // 旧服务端不返回 TMDB 影人 id：没有影人页可进，按确认不跳转
                                guard let tmdbId = person.tmdbPersonId else { return }
                                router.push(.person(tmdbId: tmdbId, name: person.name, avatar: person.avatarUrl, fromItem: nil))
                            }
                            .accessibilityIdentifier("tv-search-person-\(person.id)")
                        }
                    }
                }
                if !model.items.isEmpty {
                    TVShelf(title: "最相关的影片") {
                        ForEach(model.items, id: \.item.mediaItemId) { hit in
                            let item = hit.item
                            // 搜索结果与别处的海报行不同：要一眼确认「是不是我要找的那部」，
                            // 片名、年份·类型、命中原因常显在卡片下面，不等获得焦点才浮出
                            TVPosterCard(title: item.title,
                                         subtitle: [item.year.map(String.init), Self.kindName(item.kind)]
                                            .compactMap { $0 }.joined(separator: " · "),
                                         imageURL: api.image(item.posterUrl,
                                                             width: ImageWidth.tvCard(TVMetrics.posterWidth)),
                                         caption: .always,
                                         note: Self.matchNote(hit.match)) {
                                guard let libraryId = item.libraryId ?? hit.libraryIds.first else { return }
                                router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
                            }
                            .focused($focusedItem, equals: item.mediaItemId)
                        }
                        if model.nextCursor != nil {
                            Button(model.loadingMore ? "正在加载…" : "更多结果") {
                                Task { await model.loadMore(api: api) }
                            }
                            .disabled(model.loadingMore)
                            .accessibilityIdentifier("tv-search-more")
                        }
                    }
                }
                if let failed = model.failed {
                    TVStateView(symbol: "wifi.exclamationmark", title: "搜索失败", message: failed,
                                actionTitle: "重试", action: { Task { await model.search(api: api, input: input, immediately: true) } })
                        .frame(height: 420)
                } else if model.items.isEmpty && !model.searching && !trimmed.isEmpty {
                    TVStateView(symbol: "magnifyingglass", title: "没有找到相关影片",
                                message: "试试片名、别名、拼音首字母或演员、导演姓名。")
                        .frame(height: 420)
                } else if trimmed.isEmpty && !model.searching {
                    TVStateView(symbol: "magnifyingglass", title: "搜索你的媒体库",
                                message: "输入 xjcy、星际cy 或诺兰，也可以使用遥控器听写。")
                        .frame(height: 420)
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .searchable(text: $query, prompt: "片名、拼音首字母、演员或导演")
        .searchSuggestions {
            ForEach(model.suggestions, id: \.self) { suggestion in
                Text(suggestion.text).searchCompletion(suggestion.text)
            }
        }
        .task(id: input) {
            guard model.loadedInput != input else { return }
            focusedItem = nil
            await model.search(api: api, input: input)
        }
        .onSubmit(of: .search) { Task { await model.search(api: api, input: input, immediately: true) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-search")
    }

    private static func kindName(_ kind: String) -> String? {
        switch kind {
        case "movie": "电影"
        case "tv": "剧集"
        case "video": "视频"
        default: nil
        }
    }

    /// 命中原因：人物带出的作品用人像图标（「演员：史蒂芬·朗」），名称类命中用放大镜（「首字母匹配」）
    private static func matchNote(_ match: API.LibrarySearchMatch) -> TVCardNote {
        TVCardNote(symbol: match.personId == nil ? "text.magnifyingglass" : "person.fill", text: match.label)
    }
}

private struct TVSearchInput: Hashable {
    let query: String
}

/// 请求序号同时保护搜索和翻页：取消之外再核验序号，旧响应不能覆盖新输入。
/// 保存一轮浏览状态，不随后台索引刷新换序；翻页按作品 ID 去重。
@Observable
private final class TVSearchModel {
    var items: [API.LibrarySearchHit] = []
    var people: [API.LibrarySearchPerson] = []
    var suggestions: [API.LibrarySearchSuggestion] = []
    var nextCursor: String?
    var searching = false
    var loadingMore = false
    var failed: String?
    private(set) var loadedInput: TVSearchInput?
    private var generation = 0
    private var input = TVSearchInput(query: "")

    func search(api: APIClient, input: TVSearchInput, immediately: Bool = false) async {
        generation += 1
        loadedInput = nil
        let request = generation
        self.input = input
        failed = nil
        nextCursor = nil
        loadingMore = false
        guard !input.query.isEmpty else {
            items = []; people = []; suggestions = []; searching = false
            loadedInput = input
            return
        }
        searching = true
        defer { if generation == request { searching = false } }
        do {
            if !immediately { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            let result = try await api.searchLibrary(q: input.query)
            guard generation == request, !Task.isCancelled else { return }
            items = result.items
            people = result.people
            suggestions = result.suggestions
            nextCursor = result.nextCursor
            loadedInput = input
        } catch is CancellationError {
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            failed = error.localizedDescription
        }
    }

    func loadMore(api: APIClient) async {
        guard let cursor = nextCursor, !loadingMore, !searching else { return }
        let request = generation
        loadingMore = true
        defer { if generation == request { loadingMore = false } }
        do {
            let result = try await api.searchLibrary(q: input.query, cursor: cursor)
            guard generation == request, !Task.isCancelled else { return }
            let existing = Set(items.map(\.item.mediaItemId))
            items.append(contentsOf: result.items.filter { !existing.contains($0.item.mediaItemId) })
            nextCursor = result.nextCursor
            failed = nil
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            failed = error.localizedDescription
        }
    }
}
