import Nuke
import SwiftUI

/// 首页海报行的「选中展开」（同 Netflix 电视版，2026-10-04 用户定）：
///
/// - 平时一排竖海报，不挂字（海报自带片名）；
/// - 焦点所在的那一部在行首展开成同高的横版剧照卡（16:9），左下角片名 Logo（没有 Logo 写大字片名）；
/// - 展开位固定在行首、大小不变（2026-10-11 用户定，同 Netflix）：往右按，展开位里直接换成下一部，后面的海报整体往左
///   平移一格；不再每按一下都让上一张收回、下一张展开。原先两张卡同时做宽度动画，动画的每一帧整行都要重新排版，
///   左右换海报时主线程、GPU 都吃紧；现在宽度与滚动位置在同一帧里直接到位，只有海报平移这一个位移动画；
/// - 行下面写「电影 · 剧情 · 喜剧 · 2006 · 1 小时 49 分钟 · PG-13」与两行简介，只在焦点所在的那一行出现。
///
/// 为什么替换掉「选中时片名浮在卡片下方」：那行字挤在行间空隙里，上下都贴着别的东西，用户看着拥挤；
/// 选中展开把「这是哪部、讲什么」放进卡片本身和行下方的固定位置，既不预留空位、也不挤。
///
/// 展开要的 Logo、简介、类型、片长、分级不在海报墙列表里，由 `TVShowcaseStore` 按行整批取
/// （`GET /libraries/showcase`）；老服务器没有这个接口时只少了这几项——剧照、年份、季数照样有。
struct TVShowcaseShelf<Trailing: View>: View {
    let title: String
    let entries: [TVShowcaseEntry]
    /// 焦点进 / 出这一行（首页据此把这一行滚到屏幕上方，让下面的说明露全）
    var onRowFocus: (Bool) -> Void = { _ in }
    let open: (TVShowcaseEntry) -> Void
    /// 行末尾的「查看全部」：建好存下来（不存闭包），行重算时不跟着重建
    let trailing: Trailing

    init(title: String, entries: [TVShowcaseEntry], onRowFocus: @escaping (Bool) -> Void = { _ in },
         open: @escaping (TVShowcaseEntry) -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.entries = entries
        self.onRowFocus = onRowFocus
        self.open = open
        self.trailing = trailing()
    }

    @Environment(\.api) private var api
    @FocusState private var focused: Int?
    /// 展开的那张：跟着焦点走，焦点离开这一行就收回
    @State private var expanded: Int?
    /// 最后停过的那张：从别的行回到这一行时落回它（它就停在行首），不按位置挑最近的
    @State private var remembered: Int?
    /// 焦点在行末「查看全部」上（它不在 `focused` 里）
    @State private var trailingFocused = false
    /// 最后停在「查看全部」上：从它点进海报墙、返回时焦点要回到它，入口就是它
    @State private var leftAtTrailing = false
    /// 展开位后面那些海报的平移：换一部的那一帧排版已经到位，先把它们放回原来的位置，再滑过来
    @State private var slide: CGFloat = 0

    private var store: TVShowcaseStore { .shared }
    private var rowFocused: Bool { focused != nil || trailingFocused }
    /// 焦点不在这一行时，只有它能拿焦点（最后停在「查看全部」上时是「查看全部」）
    private var entryPoint: Int? { remembered ?? entries.first?.id }

    /// 展开卡停在行首（左边距处）的滚动锚点：`scrollTo` 让卡片上的 x 比例点对齐视口上的同一比例点，
    /// 要让卡片左沿落在 edge 处，比例 a 满足 a × 视口宽 − a × 卡宽 = edge（电视画布固定 1920 点宽）
    private static var leadingAnchor: UnitPoint {
        UnitPoint(x: TVMetrics.edge / (1920 - TVMetrics.showcaseExpandedWidth), y: 0.5)
    }
    /// 行尾留白：最后一部展开后也能滚到行首（同 Netflix），不然最后几部只能挤在右边
    private static var trailingMargin: CGFloat { 1920 - TVMetrics.edge - TVMetrics.showcaseExpandedWidth }
    /// 换一部时后面的海报平移一格的距离
    private static var step: CGFloat { TVMetrics.showcasePosterWidth + TVMetrics.cardSpacing }

    var body: some View {
        let expandedIndex = expanded.flatMap { id in entries.firstIndex { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(rowFocused ? .primary : .secondary)
                .animation(.easeOut(duration: 0.2), value: rowFocused)
                .padding(.horizontal, TVMetrics.edge)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVMetrics.cardSpacing) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            TVShowcaseCard(entry: entry, detail: store.details[entry.id], expanded: expanded == entry.id) {
                                open(entry)
                            }
                            .equatable()
                            .focused($focused, equals: entry.id)
                            // 焦点不在这一行时只留「上次停的那张」可选：从上下行按过来，系统只能落到它身上。
                            // （`defaultFocus` 在这里不生效：系统照样按位置挑离得最近的那张）
                            .disabled(!rowFocused && (leftAtTrailing || entry.id != entryPoint))
                            .offset(x: expandedIndex.map { index > $0 } == true ? slide : 0)
                            .id(entry.id)
                        }
                        trailing
                            .disabled(!rowFocused && !leftAtTrailing)
                            .offset(x: expandedIndex != nil ? slide : 0)
                            .onPreferenceChange(TVRowFocusKey.self) { isFocused in
                                trailingFocused = isFocused
                                if isFocused { leftAtTrailing = true }
                            }
                    }
                    .padding(.vertical, 20)
                    .padding(.leading, TVMetrics.edge)
                    .padding(.trailing, Self.trailingMargin)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .onChange(of: focused) { old, new in
                    if let new {
                        remembered = new
                        leftAtTrailing = false
                    }
                    // 宽度、滚动位置在同一帧里直接到位：展开位停在行首、大小不变，里面换成新的这一部
                    let from = old.flatMap { id in entries.firstIndex { $0.id == id } }
                    let to = new.flatMap { id in entries.firstIndex { $0.id == id } }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        expanded = new
                        if let new { proxy.scrollTo(new, anchor: Self.leadingAnchor) }
                        // 后面的海报先放回原来的位置（往右按是右边一格，往左按是左边一格）
                        if let from, let to, from != to { slide = to > from ? Self.step : -Self.step } else { slide = 0 }
                    }
                    if slide != 0 {
                        // 等放回原位的那一帧画出来再滑：同一次更新里改两遍，中间值画不出来、也就没有动画
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) { slide = 0 }
                        }
                    }
                    if let to { prefetch(around: to) }
                }
            }
            // 新旧两段说明叠在同一个框里交叉淡入：放在 VStack 里会上下并排、把整行撑高一下
            ZStack(alignment: .topLeading) {
                if let id = expanded, let entry = entries.first(where: { $0.id == id }) {
                    TVShowcaseInfo(entry: entry, detail: store.details[id])
                        .id(id)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, TVMetrics.edge)
        }
        .focusSection()
        .task(id: entries.map(\.id)) {
            store.load(entries.map(\.id), api: api)
        }
        .onChange(of: rowFocused) { _, focused in onRowFocus(focused) }
    }

    /// 预载展开位前后几部要用的剧照、Logo（与 `TVShowcaseCard` 取图同一个请求，命中内存缓存）
    private func prefetch(around index: Int) {
        let neighbours = [index - 1, index + 1, index + 2].filter { entries.indices.contains($0) }.map { entries[$0] }
        var requests: [ImageRequest] = []
        for entry in neighbours {
            let detail = store.details[entry.id]
            if let url = TVShowcaseCard.backdropURL(entry, detail, api: api) { requests.append(ImageRequest(url: url)) }
            if let logo = api.image(detail?.logoUrl) { requests.append(TVTitleArt.request(logo, size: TVShowcaseCard.logoSize)) }
        }
        store.prefetcher.startPrefetching(with: requests)
    }
}

/// 海报行里的一部（海报墙条目 / 收藏条目归一成这一种）
struct TVShowcaseEntry: Identifiable, Equatable {
    /// 媒体条目 id
    let id: Int
    let title: String
    /// movie / tv / video
    let kind: String
    let year: Int?
    let posterURL: String?
    /// 列表里带的剧照（展开接口没取到时兜底）
    let backdropURL: String?
    /// 在库的正季数（剧集写「3 季」；特别篇 0 季不算）
    let seasonCount: Int
}

/// 一张卡：平时竖海报，展开时同高的横版剧照 + 左下 Logo（宽度直接到位，见 `TVShowcaseShelf`）。
/// 按值比较、不比按下的动作（它只在按下时调用行给的闭包）：行重算时没变的卡不重画
private struct TVShowcaseCard: View, Equatable {
    let entry: TVShowcaseEntry
    let detail: API.LibraryItemShowcaseView?
    let expanded: Bool
    let action: () -> Void

    @Environment(\.api) private var api

    static let logoSize = CGSize(width: 380, height: 120)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.detail == rhs.detail && lhs.expanded == rhs.expanded
    }

    /// 展开时的剧照：展开接口给的优先，列表里带的兜底，再没有用海报
    static func backdropURL(_ entry: TVShowcaseEntry, _ detail: API.LibraryItemShowcaseView?, api: APIClient) -> URL? {
        api.image(detail?.backdropUrl ?? entry.backdropURL ?? entry.posterURL, width: ImageWidth.tvCard(TVMetrics.showcaseExpandedWidth))
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                // 海报一直留着、展开时盖上剧照：收回时不用重建海报
                RemoteImage(url: api.image(entry.posterURL, width: ImageWidth.tvCard(TVMetrics.showcasePosterWidth)), placeholderText: entry.title)
                    .frame(width: TVMetrics.showcasePosterWidth, height: TVMetrics.showcaseHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .opacity(expanded ? 0 : 1)
                if expanded {
                    backdrop
                }
            }
            .frame(width: expanded ? TVMetrics.showcaseExpandedWidth : TVMetrics.showcasePosterWidth,
                   height: TVMetrics.showcaseHeight)
            .clipShape(.rect(cornerRadius: TVMetrics.cardCorner))
        }
        .buttonStyle(TVShowcaseButtonStyle())
        .accessibilityLabel(entry.title)
    }

    /// 展开态：剧照铺满，左下角压一层渐暗再放 Logo（剧照亮的时候 Logo 也看得清）
    private var backdrop: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: Self.backdropURL(entry, detail, api: api), placeholderText: entry.title)
                .frame(width: TVMetrics.showcaseExpandedWidth, height: TVMetrics.showcaseHeight)
            LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.55)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            TVTitleArt(title: entry.title, logoURL: api.image(detail?.logoUrl), size: Self.logoSize, textSize: 52)
                .padding(.leading, 36)
                .padding(.bottom, 32)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        }
        .frame(width: TVMetrics.showcaseExpandedWidth, height: TVMetrics.showcaseHeight)
    }
}

/// 焦点样式：不放大（展开本身就是焦点的表达，再放大会压住两边的卡），亮一圈白边 + 投影，
/// 同 Netflix 电视版的焦点卡
private struct TVShowcaseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                // 焦点动画只管描边与投影：卡片展开、收回的宽度要直接到位（见 `TVShowcaseShelf`），不能被它带着动
                .animation(.easeOut(duration: 0.2)) { content in
                    content
                        .background { TVFocusShadow(focused: isFocused, cornerRadius: TVMetrics.cardCorner, opacity: 0.55, radius: 26, y: 16) }
                        .overlay {
                            RoundedRectangle(cornerRadius: TVMetrics.cardCorner)
                                .strokeBorder(.white.opacity(isFocused ? 0.9 : 0.14), lineWidth: isFocused ? 4 : 1)
                        }
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// 行下方的说明：一行元信息 + 两行简介。字与详情页同一套（`TVInfoText`），两段之间也照详情页隔 20
private struct TVShowcaseInfo: View {
    let entry: TVShowcaseEntry
    let detail: API.LibraryItemShowcaseView?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TVInfoText.meta(Self.meta(entry, detail))
            if let overview = detail?.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                TVInfoText.overview(overview, lines: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「电影 · 剧情 · 喜剧 · 2006 · 1 小时 49 分钟 · PG-13」「剧集 · 剧情 · 2019 · 3 季」：
    /// 类型只取前两个（再多就挤了，同首屏大图）；片长只写电影（剧集给的是单集时长）
    static func meta(_ entry: TVShowcaseEntry, _ detail: API.LibraryItemShowcaseView?) -> String {
        var parts: [String] = []
        switch entry.kind {
        case "movie": parts.append("电影")
        case "tv": parts.append("剧集")
        default: break
        }
        parts += (detail?.genres ?? []).prefix(2)
        if let year = entry.year { parts.append(String(year)) }
        if entry.kind == "tv" {
            if entry.seasonCount > 0 { parts.append("\(entry.seasonCount) 季") }
        } else if let minutes = detail?.runtimeMinutes, minutes > 0 {
            parts.append(TVItemDetailView.runtimeText(minutes))
        }
        if let rating = detail?.contentRating, !rating.isEmpty { parts.append(rating) }
        return parts.joined(separator: " · ")
    }
}

/// 海报行展开要的展示信息：按行整批取一次、全程缓存（Logo、简介这些几乎不变）。
/// 取过的 id 不再取——失败也不重试（老服务器没有这个接口），免得每次刷新首页都白打一轮请求
@MainActor
@Observable
final class TVShowcaseStore {
    static let shared = TVShowcaseStore()

    private(set) var details: [Int: API.LibraryItemShowcaseView] = [:]
    @ObservationIgnored private var requested: Set<Int> = []
    /// 预载展开卡要用的剧照与 Logo（左右相邻的几部）：焦点挪过去时直接从内存出图，换的那一下不露空底
    @ObservationIgnored let prefetcher = ImagePrefetcher()

    /// 取这一行里还没取过的那几部。请求放在自己的任务里，不跟着调用方取消：行在懒加载列表里一滚出屏幕，
    /// 它的 `.task` 就被取消，请求跟着断掉的话这批 id 已记为取过、再也不补取——展开卡没有 Logo、
    /// 行下面只剩「电影 · 2008」（2026-10-04 模拟器实测：服务端回了 200，客户端已经断开）
    func load(_ ids: [Int], api: APIClient) {
        let missing = ids.filter { !requested.contains($0) }
        guard !missing.isEmpty else { return }
        requested.formUnion(missing)
        Task {
            guard let rows = try? await api.uiLibraryShowcase(ids: missing) else { return }
            for row in rows { details[row.mediaItemId] = row }
        }
    }
}
