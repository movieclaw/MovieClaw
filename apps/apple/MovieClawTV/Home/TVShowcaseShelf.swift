import SwiftUI

/// 首页海报行的「选中展开」（同 Netflix 电视版，2026-10-04 用户定）：
///
/// - 平时一排竖海报，不挂字（海报自带片名）；
/// - 焦点停在哪张，它就展开成同高的横版剧照卡（16:9），左下角片名 Logo（没有 Logo 写大字片名），
///   并且停在行首——往右按，上一张收回海报、下一张展开，整行跟着左移；
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
    /// 行末尾的「查看全部」
    @ViewBuilder let trailing: () -> Trailing

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(rowFocused ? .primary : .secondary)
                .animation(.easeOut(duration: 0.2), value: rowFocused)
                .padding(.horizontal, TVMetrics.edge)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVMetrics.cardSpacing) {
                        ForEach(entries) { entry in
                            TVShowcaseCard(entry: entry, detail: store.details[entry.id], expanded: expanded == entry.id) {
                                open(entry)
                            }
                            .focused($focused, equals: entry.id)
                            // 焦点不在这一行时只留「上次停的那张」可选：从上下行按过来，系统只能落到它身上。
                            // （`defaultFocus` 在这里不生效：系统照样按位置挑离得最近的那张）
                            .disabled(!rowFocused && (leftAtTrailing || entry.id != entryPoint))
                            .id(entry.id)
                        }
                        trailing()
                            .disabled(!rowFocused && !leftAtTrailing)
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
                .onChange(of: focused) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(new, anchor: Self.leadingAnchor) }
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
        .onChange(of: focused) { _, new in
            if let new {
                remembered = new
                leftAtTrailing = false
            }
            withAnimation(.easeInOut(duration: 0.3)) { expanded = new }
        }
        .onChange(of: rowFocused) { _, focused in onRowFocus(focused) }
    }
}

/// 海报行里的一部（海报墙条目 / 收藏条目归一成这一种）
struct TVShowcaseEntry: Identifiable {
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

/// 一张卡：平时竖海报，展开时同高的横版剧照 + 左下 Logo。宽度变化带动画，海报与剧照交叉淡入
private struct TVShowcaseCard: View {
    let entry: TVShowcaseEntry
    let detail: API.LibraryItemShowcaseView?
    let expanded: Bool
    let action: () -> Void

    @Environment(\.api) private var api

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: api.image(entry.posterURL, width: ImageWidth.tvCard(TVMetrics.showcasePosterWidth)), placeholderText: entry.title)
                    .frame(width: TVMetrics.showcasePosterWidth, height: TVMetrics.showcaseHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .opacity(expanded ? 0 : 1)
                if expanded {
                    backdrop
                        .transition(.opacity)
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
            RemoteImage(url: api.image(detail?.backdropUrl ?? entry.backdropURL ?? entry.posterURL,
                                  width: ImageWidth.tvCard(TVMetrics.showcaseExpandedWidth)),
                        placeholderText: entry.title)
                .frame(width: TVMetrics.showcaseExpandedWidth, height: TVMetrics.showcaseHeight)
            LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.55)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            TVTitleArt(title: entry.title, logoURL: api.image(detail?.logoUrl),
                       size: CGSize(width: 380, height: 120), textSize: 52)
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
                .overlay {
                    RoundedRectangle(cornerRadius: TVMetrics.cardCorner)
                        .strokeBorder(.white.opacity(isFocused ? 0.9 : 0.14), lineWidth: isFocused ? 4 : 1)
                }
                .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: 26, y: 16)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.2), value: isFocused)
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
