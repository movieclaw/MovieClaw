import SwiftUI

/// 搜索（docs/design/macos-app.md §4.5）：侧边栏顶上的搜索框一有字，内容区就换成这一页（同 Apple Music）；清空回到刚才的页面。
///
/// 与 iPhone、Apple TV 版同一个接口（`searchLibrary`）：片名、别名、拼音首字母、演员导演都能搜，只搜自己的媒体库。
/// - 输入停 0.35 秒才发请求，请求序号保护（旧响应不覆盖新输入），翻页按作品去重、滚到底自动接着取；
/// - 「人物」一行：点一个人，下面换成他在库里的全部作品（「诺兰的库内作品」，可退回搜索结果）；
/// - 「影片」是与海报墙同一套的网格，海报下写年份与命中依据（「别名」「拼音」「导演 诺兰」）；
/// - 搜索框空着时显示最近搜过的词（本机按账号记，点一下再搜一次）和输入提示。
struct MacSearchView: View {
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var appModel
    @Environment(MacRouter.self) private var router
    @State private var model = MacSearchModel()
    @State private var selectedPerson: API.LibrarySearchPerson?
    @State private var recents: [String] = []

    private var trimmed: String { router.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var input: MacSearchInput { .init(query: selectedPerson == nil ? trimmed : "", personId: selectedPerson?.id) }
    private var recentsKey: String { "movieclaw.mac.recent-searches.\(api.server.origin.absoluteString)#\(appModel.session?.username ?? "")" }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let selectedPerson {
                    personBanner(selectedPerson)
                }
                if !model.people.isEmpty, selectedPerson == nil {
                    peopleRow
                }
                if !model.items.isEmpty {
                    itemsGrid
                }
                states
            }
            .padding(.horizontal, MacMetrics.edge)
            .padding(.top, 12)
            .padding(.bottom, 48)
        }
        .background(Color.macPage)
        .navigationTitle("搜索")
        .toolbar(removing: .title)
        .task(id: input) {
            guard model.loadedInput != input else { return }
            await model.search(api: api, input: input)
        }
        // 搜索词变了就退出「某人的库内作品」，回到按词搜
        .onChange(of: trimmed) { _, _ in selectedPerson = nil }
        // 联想词交给侧边栏的搜索框下拉（与正在输入的完全一样的词不再列）
        .onChange(of: model.suggestions) { _, suggestions in
            router.searchSuggestions = suggestions.map(\.text).filter { $0 != trimmed }
        }
        .onDisappear { router.searchSuggestions = [] }
        .onAppear { recents = (UserDefaults.standard.stringArray(forKey: recentsKey) ?? []) }
        .accessibilityIdentifier("mac-search")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(trimmed.isEmpty ? "搜索" : "「\(trimmed)」")
                .font(.system(size: 28, weight: .bold))
                .lineLimit(1)
            if model.searching {
                ProgressView().controlSize(.small)
            } else if !trimmed.isEmpty, model.loadedInput == input, selectedPerson == nil {
                Text(model.nextCursor == nil ? "\(model.items.count) 部" : "\(model.items.count)+ 部")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func personBanner(_ person: API.LibrarySearchPerson) -> some View {
        HStack(spacing: 12) {
            MacAvatar(url: Self.avatarURL(person), name: person.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(person.name)的库内作品").font(.system(size: 17, weight: .semibold))
                Text("库内 \(person.itemCount) 部").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                selectedPerson = nil
            } label: {
                Label("返回搜索结果", systemImage: "chevron.backward")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("mac-search-person-back")
        }
    }

    /// 「人物」一行：头像 + 姓名 + 库内几部，点一下看这个人在库里的全部作品
    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("人物").font(.system(size: 20, weight: .bold))
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.people, id: \.id) { person in
                        MacSearchPersonChip(person: person, avatarURL: Self.avatarURL(person)) {
                            remember(trimmed)
                            selectedPerson = person
                        }
                        .accessibilityIdentifier("mac-search-person-\(person.id)")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
    }

    private var itemsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedPerson == nil {
                Text("影片").font(.system(size: 20, weight: .bold))
            }
            LazyVGrid(columns: MacPosterWall<EmptyView>.columns, alignment: .leading, spacing: 26) {
                ForEach(model.items, id: \.item.mediaItemId) { hit in
                    resultCell(hit)
                        .onAppear {
                            if hit.item.mediaItemId == model.items.last?.item.mediaItemId { Task { await model.loadMore(api: api) } }
                        }
                }
            }
            if model.loadingMore {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
    }

    private func resultCell(_ hit: API.LibrarySearchHit) -> some View {
        let item = hit.item
        let libraryId = item.libraryId ?? hit.libraryIds.first
        return GeometryReader { proxy in
            MacPosterCard(
                title: item.title,
                subtitle: [item.year.map(String.init), hit.match.label.isEmpty ? nil : hit.match.label].compactMap { $0 }.joined(separator: " · "),
                imageURL: api.image(item.posterUrl, width: ImageWidth.macCard(200)),
                width: proxy.size.width,
                play: { router.play(PlayRequest(mediaItemId: item.mediaItemId)) },
                menu: MacItemMenu.actions(item: item, libraryId: libraryId, router: router)
            ) {
                guard let libraryId else { return }
                remember(trimmed)
                router.push(.item(libraryId: libraryId, itemId: item.mediaItemId))
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .padding(.bottom, 38)
        .accessibilityIdentifier("mac-search-item-\(item.mediaItemId)")
    }

    @ViewBuilder
    private var states: some View {
        if let failed = model.failed {
            MacStateView(symbol: "wifi.exclamationmark", title: "搜索失败", message: failed, actionTitle: "重试") {
                Task { await model.search(api: api, input: input, immediately: true) }
            }
            .frame(height: 360)
        } else if model.items.isEmpty, model.people.isEmpty || selectedPerson != nil, !model.searching, model.loadedInput == input,
                  !trimmed.isEmpty || selectedPerson != nil {
            MacStateView(symbol: "magnifyingglass", title: "没有找到相关影片",
                         message: "试试片名、别名、拼音首字母（如 xjcy），或演员、导演的名字。")
                .frame(height: 360)
        } else if trimmed.isEmpty, selectedPerson == nil {
            idle
        }
    }

    /// 搜索框空着：最近搜过的词 + 输入提示
    private var idle: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近搜索").font(.system(size: 20, weight: .bold))
                        Spacer()
                        Button("清除") {
                            recents = []
                            UserDefaults.standard.removeObject(forKey: recentsKey)
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("mac-search-clear-recents")
                    }
                    MacFlowLayout(spacing: 8) {
                        ForEach(recents, id: \.self) { word in
                            Button(word) { router.searchText = word }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
            MacStateView(symbol: "magnifyingglass", title: "搜索你的媒体库",
                         message: "片名、别名、拼音首字母都行：输入 xjcy、星际cy 或诺兰试试。按 ⌘F 随时回到搜索框。")
                .frame(height: 300)
        }
    }

    /// 记下搜过的词（点开结果或人物时记，打一半没点的不记），最多 10 个，新的在前
    private func remember(_ word: String) {
        guard !word.isEmpty else { return }
        recents = Array(([word] + recents.filter { $0 != word }).prefix(10))
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }

    /// 人物头像：搜索接口只给 TMDB 头像路径，按 TMDB 图床的 185 宽档取（断网时退回首字母头像）
    static func avatarURL(_ person: API.LibrarySearchPerson) -> URL? {
        guard let path = person.profilePath, path.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(path)")
    }
}

/// 一个人物：头像 + 姓名 + 库内几部（玻璃胶囊，悬停提亮）
private struct MacSearchPersonChip: View {
    let person: API.LibrarySearchPerson
    let avatarURL: URL?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MacAvatar(url: avatarURL, name: person.name, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([person.match.label.isEmpty ? nil : person.match.label, "库内 \(person.itemCount) 部"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .background(.white.opacity(hovering ? 0.14 : 0.07), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .buttonStyle(MacCardButtonStyle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help("查看\(person.name)在库里的全部作品")
    }
}

/// 简单的流式排版：一行放不下就换行（最近搜索的词）
struct MacFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct MacSearchInput: Hashable {
    let query: String
    let personId: Int?
}

/// 搜索的状态：请求序号同时保护搜索和翻页（取消之外再核验序号，旧响应不能覆盖新输入）；翻页按作品去重
@Observable
final class MacSearchModel {
    var items: [API.LibrarySearchHit] = []
    var people: [API.LibrarySearchPerson] = []
    var suggestions: [API.LibrarySearchSuggestion] = []
    var nextCursor: String?
    var searching = false
    var loadingMore = false
    var failed: String?
    private(set) var loadedInput: MacSearchInput?
    private var generation = 0
    private var input = MacSearchInput(query: "", personId: nil)

    func search(api: APIClient, input: MacSearchInput, immediately: Bool = false) async {
        generation += 1
        let request = generation
        self.input = input
        failed = nil
        nextCursor = nil
        loadingMore = false
        guard !input.query.isEmpty || input.personId != nil else {
            items = []
            people = []
            suggestions = []
            searching = false
            loadedInput = input
            return
        }
        searching = true
        defer { if generation == request { searching = false } }
        do {
            if !immediately { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            let result = try await api.searchLibrary(q: input.query.isEmpty ? nil : input.query, personId: input.personId)
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
            loadedInput = input
        }
    }

    func loadMore(api: APIClient) async {
        guard let cursor = nextCursor, !loadingMore, !searching else { return }
        let request = generation
        loadingMore = true
        defer { if generation == request { loadingMore = false } }
        do {
            let result = try await api.searchLibrary(q: input.query.isEmpty ? nil : input.query, personId: input.personId, cursor: cursor)
            guard generation == request, !Task.isCancelled else { return }
            let existing = Set(items.map(\.item.mediaItemId))
            items.append(contentsOf: result.items.filter { !existing.contains($0.item.mediaItemId) })
            nextCursor = result.nextCursor
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            failed = error.localizedDescription
        }
    }
}
