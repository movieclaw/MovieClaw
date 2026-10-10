import SwiftUI

/// 长剧集的「全部分集」面板（docs/design/long-season-episode-ranges.md §5）：在详情页的段页签上按确认打开，落在那一段。
/// 左栏段列表（锚点所在的段带橙点），焦点移到哪一段右边就换成哪一段；右边 10 列数字宫格，格子标已看 ✓、进度条、缺集虚线、
/// 锚点橙边。在格子上按确认关面板、焦点落到横排的那一集（`onPick`）；返回键关面板回到段页签。
/// 一段最多 50 格（5 排），宫格只画当前这一段
struct TVEpisodeRangePanel: View {
    let seasonLabel: String
    let ranges: [EpisodeRange]
    /// 接着看的那一集（服务端锚点）
    let anchor: Int?
    let ambientURL: URL?
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 右边正摆着的那一段
    @State private var shown: EpisodeRange
    @FocusState private var focus: PanelFocus?
    /// 按集号查分集：格子与底下的说明行用
    private let byNumber: [Int: API.EpisodeView]
    private let ownedCount: Int
    private let total: Int

    private enum PanelFocus: Hashable {
        case range(Int)
        case cell(Int)
    }

    static let columns = 10
    private static let cellSize = CGSize(width: 120, height: 96)
    private static let cellSpacing: CGFloat = 18

    init(seasonLabel: String, episodes: [API.EpisodeView], ranges: [EpisodeRange], start: EpisodeRange, anchor: Int?,
         ambientURL: URL?, onPick: @escaping (Int) -> Void) {
        self.seasonLabel = seasonLabel
        self.ranges = ranges
        self.anchor = anchor
        self.ambientURL = ambientURL
        self.onPick = onPick
        _shown = State(initialValue: start)
        byNumber = Dictionary(episodes.map { ($0.episodeNumber, $0) }, uniquingKeysWith: { first, _ in first })
        ownedCount = episodes.filter(\.owned).count
        total = episodes.count
    }

    private var anchorRange: Int? { anchor.map(EpisodeRanges.index(of:)) }
    /// 当前这一段里的集号（按集号排；缺集也在，置灰）
    private var numbers: [Int] { byNumber.keys.filter { shown.contains($0) }.sorted() }
    /// 进宫格时落在哪一格：段里有锚点就是锚点，否则段首（同横排换段）
    private var entryCell: Int { EpisodeRanges.entry(of: shown, anchor: anchor) }
    private var gridFocused: Bool { if case .cell = focus { true } else { false } }
    private var listFocused: Bool { if case .range = focus { true } else { false } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVBlurredBackdrop(url: ambientURL)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 44) {
                header
                HStack(alignment: .top, spacing: 48) {
                    rangeList
                    // 右边整栏（宫格 + 说明行）是一个焦点区、与左栏等高：从左栏哪一段往右都进得来（只放入口格能接焦点，
                    // 焦点区比宫格矮的话，左栏下面几段往右的那条线碰不到它）
                    VStack(alignment: .leading, spacing: 36) {
                        grid
                        caption
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.top, 40)
            .padding(.bottom, 40)
        }
        // 打开时落在这一段的入口格（锚点或段首）
        .defaultFocus($focus, .cell(entryCell))
        .onChange(of: focus) { _, new in
            // 焦点移到哪一段，右边就换成哪一段
            if case let .range(index) = new, let range = ranges.first(where: { $0.index == index }) { shown = range }
        }
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-range-panel")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text("全部分集")
                .font(.system(size: 44, weight: .bold))
            Text(([seasonLabel, "在库 \(ownedCount) / \(total)"] + (anchor.map { ["接着看第 \($0) 集"] } ?? []))
                .joined(separator: " · "))
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// 左栏：一段一行，锚点所在的段右边一个橙点；正摆着的那一段垫浅底
    private var rangeList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(ranges) { range in
                        Button {
                            // 在段上按确认＝进宫格（同往右）
                            focus = .cell(EpisodeRanges.entry(of: range, anchor: anchor))
                        } label: {
                            HStack {
                                Text(range.label).monospacedDigit()
                                Spacer(minLength: 0)
                                if range.index == anchorRange {
                                    Circle().fill(TVEpisodeRangeStyle.anchorColor).frame(width: 12, height: 12)
                                        .accessibilityLabel("接着看")
                                }
                            }
                        }
                        .buttonStyle(TVRangeListStyle(current: range.index == shown.index))
                        // 从宫格往左回来落在正摆着的那一段，不按位置挑最近的（同首页海报行的入口卡做法）
                        .disabled(!listFocused && range.index != shown.index)
                        .focused($focus, equals: .range(range.index))
                        .id(range.index)
                        .accessibilityIdentifier("tv-panel-range-\(range.first)")
                    }
                }
                // 获得焦点放大一点，四周留出余地（列表要裁边，不然滚上去的段会盖住标题）
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .frame(width: 324)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, -12)
            .focusSection()
            .onAppear { proxy.scrollTo(shown.index, anchor: .center) }
        }
    }

    /// 右边的宫格：一排 10 格、逐排一个焦点区（最后一排不满时从上一排往下也能落进去）
    private var grid: some View {
        let rows = stride(from: 0, to: numbers.count, by: Self.columns).map { Array(numbers[$0 ..< min($0 + Self.columns, numbers.count)]) }
        return VStack(alignment: .leading, spacing: Self.cellSpacing) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: Self.cellSpacing) {
                    ForEach(row, id: \.self) { number in
                        cell(number)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            }
        }
        .frame(width: Self.cellSize.width * CGFloat(Self.columns) + Self.cellSpacing * CGFloat(Self.columns - 1),
               alignment: .topLeading)
        // 换了段（左栏上下移）宫格整个换掉，不让旧格子的焦点身份残留
        .id(shown.index)
    }

    private func cell(_ number: Int) -> some View {
        let episode = byNumber[number]
        return Button {
            onPick(number)
            dismiss()
        } label: {
            Text("\(number)").monospacedDigit()
        }
        .buttonStyle(TVEpisodeCellStyle(
            played: episode?.played ?? false,
            owned: episode?.owned ?? false,
            anchor: number == anchor,
            progress: (episode?.positionMs ?? 0) > 0 ? episode?.progressPercent : nil,
            size: Self.cellSize
        ))
        // 从左栏往右进来落在入口格（锚点或段首）
        .disabled(!gridFocused && number != entryCell)
        .focused($focus, equals: .cell(number))
        .accessibilityIdentifier("tv-panel-cell-\(number)")
    }

    /// 宫格下面一行：焦点那一格是哪一集、看到哪了；焦点在左栏时提示怎么操作
    private var caption: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case let .cell(number) = focus, let episode = byNumber[number] {
                Text("第 \(number) 集 · \(episode.name ?? "第 \(number) 集")")
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                Text(Self.status(episode) + " · 按确认回到详情页，焦点落在这一集")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("上下换段，往右进宫格")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tv-panel-caption")
    }

    static func status(_ episode: API.EpisodeView) -> String {
        if !episode.owned { return "还没有片源" }
        if episode.positionMs > 0, let percent = episode.progressPercent { return "看到 \(percent)%" }
        return episode.played ? "已看完" : "未看"
    }
}

enum TVEpisodeRangeStyle {
    /// 锚点（接着看的那一集）的橙色：段页签与左栏的橙点、宫格的橙边、横排卡上的「接着看」标签（同原型 #FFB340）
    static let anchorColor = Color(red: 1, green: 0xB3 / 255, blue: 0x40 / 255)
}

/// 面板左栏的一段：正摆着的那段垫浅底；获得焦点白底黑字
private struct TVRangeListStyle: ButtonStyle {
    let current: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, current: current)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let current: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .semibold))
                .padding(.horizontal, 26)
                .frame(height: 68)
                .foregroundStyle(focused ? .black : .white.opacity(current ? 1 : 0.6))
                .background(RoundedRectangle(cornerRadius: 16).fill(focused ? .white : .white.opacity(current ? 0.12 : 0)))
                .scaleEffect(focused ? 1.04 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// 宫格里的一格：已看 ✓（字变暗）、看了一半压橙色进度条、缺集虚线框、锚点橙边；获得焦点白底黑字、放大
private struct TVEpisodeCellStyle: ButtonStyle {
    let played: Bool
    let owned: Bool
    let anchor: Bool
    let progress: Int?
    let size: CGSize

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let style: TVEpisodeCellStyle
        @Environment(\.isFocused) private var focused

        private var textColor: Color {
            if focused { return .black }
            if !style.owned { return .white.opacity(0.35) }
            return .white.opacity(style.played ? 0.55 : 1)
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16)
            configuration.label
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(width: style.size.width, height: style.size.height)
                .background(shape.fill(focused ? .white : .white.opacity(!style.owned ? 0 : style.played ? 0.05 : 0.09)))
                .overlay(alignment: .topTrailing) {
                    if style.played {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.success)
                            .padding(.top, 8)
                            .padding(.trailing, 10)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let progress = style.progress {
                        GeometryReader { proxy in
                            Rectangle().fill(TVEpisodeRangeStyle.anchorColor)
                                .frame(width: proxy.size.width * CGFloat(progress) / 100, height: 6)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .clipShape(shape)
                .overlay {
                    if !style.owned {
                        shape.strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    } else if style.anchor {
                        shape.strokeBorder(TVEpisodeRangeStyle.anchorColor, lineWidth: 4)
                    }
                }
                .scaleEffect(focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 16, y: 10)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}
