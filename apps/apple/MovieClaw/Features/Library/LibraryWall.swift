import SwiftUI

/// 「回到上次浏览的位置」的记录（Web `lib/library-wall-recall.ts`）：
/// 每面墙（scope）只记一条：当前形态（view，排序变了位置就没意义）、第一格的 offset、时间。
/// 太浅（< 24 格）或超过 14 天的不提示。
enum LibraryWallRecall {
    private static let key = "movieclaw.library.wall-recall"
    static let minOffset = 24
    static let maxAge: TimeInterval = 14 * 86400
    /// 挂后台超过这么久再回来算「重新进入」：复位到墙首并重新询问（同 Web library-wall-recall）
    static var reentryGap: TimeInterval {
        #if DEBUG
        // 开发期：-mcReentryGap <秒> 缩短判定，验证「久别回归」不用真等 30 分钟
        let forced = UserDefaults.standard.double(forKey: "mcReentryGap")
        if forced > 0 { return forced }
        #endif
        return 30 * 60
    }
    /// 页首锚点（挂在墙上方的页头上）：久别回归复位要回到页首（连统计行一起），
    /// 只滚到第一张海报会把页头留在视口外（第三轮复核 LD-4）
    static let pageTopID = "wall-page-top"

    static func read(scope: String, view: String) -> Int? {
        guard let all = UserDefaults.standard.dictionary(forKey: key),
              let saved = all[scope] as? [String: Any],
              saved["view"] as? String == view,
              let offset = saved["offset"] as? Int, offset >= minOffset,
              let at = saved["at"] as? Double, Date.now.timeIntervalSince1970 - at <= maxAge else { return nil }
        return offset
    }

    static func write(scope: String, view: String, offset: Int) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[scope] = ["view": view, "offset": offset, "at": Date.now.timeIntervalSince1970]
        UserDefaults.standard.set(all, forKey: key)
    }

    // MARK: 久别回归（全局，同 Web library-wall-recall 的 returnedAt）

    /// 最近一次「挂后台 ≥ 30 分钟再回到前台」的时刻；nil = 本次运行还没发生过
    private(set) static var returnedAt: Date?
    private static var backgroundedAt: Date?
    /// 久别回归发生时广播：正显示着的墙即时复位
    static let returnedNotification = Notification.Name("movieclaw.library.wall-returned")

    /// 根视图按前后台切换调用（所有记位置的墙共用这一个时刻，而不是各墙自己监听——
    /// 墙压在详情页下面时收不到前后台切换，回到墙上时要能补判）
    static func noteScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = .now
        case .active:
            guard let since = backgroundedAt else { return }
            backgroundedAt = nil
            guard Date.now.timeIntervalSince(since) >= reentryGap else { return }
            returnedAt = .now
            NotificationCenter.default.post(name: returnedNotification, object: nil)
        default:
            break
        }
    }

    /// 久别回归是否发生在「上次在这面墙上记录位置」之后——是的话这次算重新进入（同 Web isReentry）。
    /// 用户只要在墙上滚一下，记录时间就会超过它，不会反复复位
    static func isReentry(scope: String) -> Bool {
        guard let returnedAt else { return false }
        let saved = (UserDefaults.standard.dictionary(forKey: key)?[scope] as? [String: Any])?["at"] as? Double ?? 0
        return returnedAt.timeIntervalSince1970 > saved
    }
}

extension View {
    /// 久别回归时执行 `action`（复位到墙首、重新询问「回到上次位置」）：墙正显示时即时触发；
    /// 墙当时压在别的页面下面，就在它下次出现时补触发。同一次回归每面墙只处理一次
    func onWallReentry(scope: String, perform action: @escaping () -> Void) -> some View {
        modifier(LibraryWallReentryModifier(scope: scope, action: action))
    }
}

private struct LibraryWallReentryModifier: ViewModifier {
    let scope: String
    let action: () -> Void
    @State private var handled: Date?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: LibraryWallRecall.returnedNotification)) { _ in check() }
            .onAppear { check() }
    }

    private func check() {
        guard let at = LibraryWallRecall.returnedAt, at != handled, LibraryWallRecall.isReentry(scope: scope) else { return }
        handled = at
        action()
    }
}

/// 进页面时问一句要不要跳回上次位置；不理它、往下滑一屏就自己消失
struct WallRecallPill: View {
    var onJump: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onJump) {
                Label("回到上次浏览的位置", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 10)
            }
            .accessibilityIdentifier("wall-recall")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).padding(10)
            }
            .accessibilityLabel("不用了")
        }
        .foregroundStyle(Theme.text)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 墙尾的加载指示（Web `WallLoadMore`）：**真正滚进视口**才触发下一页，文案报窗口进度。
///
/// 不能用 onAppear / task：墙外层是普通 VStack，子视图一创建就算「出现」，
/// 会一页接一页把整库拉完。这里按滚动可见性判断（等价 Web 的 IntersectionObserver）；
/// 加载完仍在视口里（一页不满一屏）就接着要下一页。
struct WallLoadMoreFooter: View {
    let hasMore: Bool
    let start: Int
    let loaded: Int
    var total: Int?
    var onReach: () async -> Void
    @State private var visible = false

    var body: some View {
        if hasMore {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("加载中…（第 \(start + 1)–\(start + loaded) 部 / 共 \(max(total ?? 0, start + loaded))）")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textFaint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .task(id: "\(visible)|\(start + loaded)") {
                if visible { await onReach() }
            }
            .accessibilityIdentifier("wall-load-more")
        }
    }
}

/// 墙顶的向上补页哨兵（Web `WallLoadPrev`）：窗口不从 0 开始时，滚到顶才把上一页接回来
struct WallLoadPreviousSentinel: View {
    let start: Int
    var onReach: () async -> Void
    @State private var visible = false

    var body: some View {
        if start > 0 {
            Color.clear
                .frame(height: 1)
                .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
                .task(id: "\(visible)|\(start)") {
                    if visible { await onReach() }
                }
        }
    }
}

/// 海报墙网格：手机上最小列宽 140pt（竖版）/ 160pt（横版），列距 12、行距 20，与 Web 同口径
struct LibraryPosterGrid<Item: Identifiable, Cell: View>: View {
    @Environment(\.cardMetrics) private var cards
    let items: [Item]
    var wide = false
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        LazyVGrid(columns: cards.wallColumns(extra: wide ? 20 : 0), alignment: .leading, spacing: 20) {
            ForEach(items) { item in
                cell(item)
            }
        }
        .padding(.horizontal, cards.edge)
    }
}

/// 海报墙一列有多宽（点），取图用：同 SwiftUI 自适应列的算法，列数 = ⌊(可用宽 + 列距) ÷ (最小列宽 + 列距)⌋。
/// iPhone 竖屏两列约 174.5 点（3 倍屏 523 像素 → 720 档）。格子量到自己的实际宽度之前先按它估
enum LibraryGridColumn {
    static func width(minimum: CGFloat, spacing: CGFloat = 12) -> CGFloat {
        let available = ImageWidth.screenSize.width - Theme.pagePadding * 2
        let count = max(1, ((available + spacing) / (minimum + spacing)).rounded(.down))
        return (available - (count - 1) * spacing) / count
    }
}

/// 库存条目 → 海报格（Web `InventoryCell`）：缺失提示、死条目置灰、后台处理中点亮、剧集长按看库存概况与订阅动作
struct LibraryInventoryCell: View {
    let item: API.LibraryItemView
    let libraryId: Int
    var frameAspect: CGFloat?
    /// 按评分排序 / 筛选时副行常显评分
    var showRating = false
    var working: String?
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Router.self) private var router
    /// 格子实际排出来的宽：各面墙的最小列宽不一样（140 / 160 / 200），取图按量出来的宽算
    @State private var cellWidth: CGFloat?

    var body: some View {
        let dead = item.fileCount > 0 && item.missingCount >= item.fileCount
        let rating = (item.rating ?? 0) > 0 ? "★ " + String(format: "%.1f", item.rating ?? 0) : nil
        let aspect = frameAspect ?? (item.primaryAspect >= 1 ? 16 / 9 : Theme.posterAspect)
        let width = cellWidth ?? LibraryGridColumn.width(minimum: aspect >= 1 ? 160 : 140)
        NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId ?? libraryId, itemId: item.mediaItemId)) {
            LibraryPosterCell(
                title: item.title, year: item.year, extent: showRating ? rating : nil,
                url: api.image(item.posterUrl, width: ImageWidth.points(width)),
                imageAspect: item.primaryAspect, frameAspect: aspect,
                favorite: item.isFavorite, dead: dead,
                abnormal: dead ? "文件已全部缺失" : item.missingCount > 0 ? "\(item.missingCount) 个文件缺失" : nil,
                working: working,
                placeholderSymbol: LibraryKindMeta.symbol(item.kind)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.kind == "tv", let summary = item.inventorySummary {
                Text(formatInventorySummary(summary))
            }
            if let rating, !showRating { Text(rating) }
            if permissions.canSubscribe, let tmdb = item.tmdbId,
               let action = LibraryInventoryAction.of(kind: item.kind, summary: item.inventorySummary) {
                Button {
                    router.present(.subscribe(SubscribeRequest(titleRef: "tmdb:tv:\(tmdb)", title: item.title)))
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
            }
            OfflineDeleteMenuButton(itemId: item.mediaItemId, title: item.title)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cellWidth = $0 }
        .id(item.mediaItemId)
    }
}


