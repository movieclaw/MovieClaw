import SwiftUI

// 离线模式下的媒体库（docs/design/offline-download.md §1、§4）：同一个媒体库页签、同一套海报格，
// 数据换成本机目录。首页只留「接着看」与按库分组的已下载条目，不还原自定义首页。

/// 离线模式顶部的提示条：说明在看的是 iPhone 上的内容，可以手动重连
struct OfflineBanner: View {
    @Environment(\.cardMetrics) private var cards
    @State private var reachability = ServerReachability.shared
    @State private var store = OfflineStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: .offlineBrowseOffline)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(String(localized: .offlineShowingDownloaded(ClientPlatform.deviceName, store.downloadedItemIds.count)))
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Button(String(localized: .settingsCloudConnectReconnect)) { reachability.reconnect() }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.glass)
                .accessibilityIdentifier("offline-reconnect")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.warning.opacity(0.08), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.warning.opacity(0.22)))
        .padding(.horizontal, cards.edge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-banner")
    }
}

/// 离线时页签的占位：订阅、发现、活动、搜索这些都要连服务器
struct OfflinePlaceholder: View {
    var title = String(localized: .offlineOfflineTitle)
    @Environment(Router.self) private var router
    @State private var reachability = ServerReachability.shared

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.slash")
        } description: {
            Text(String(localized: .offlineNeedsServer(ClientPlatform.deviceName)))
        } actions: {
            // App 的 tint 是冷银（近白），裸 .glassProminent 会白底白字看不清
            Button(String(localized: .mediaPersonOpenLibrary)) { router.selectTab(.library) }
                .discoverProminentButton()
            Button(String(localized: .settingsCloudConnectReconnect)) { reachability.reconnect() }
                .buttonStyle(.glass)
        }
        .appBackground()
        .accessibilityIdentifier("offline-placeholder")
    }
}

/// 页签内容的离线闸：离线模式时换成占位
struct OfflineGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var reachability = ServerReachability.shared

    var body: some View {
        if reachability.isOffline {
            OfflinePlaceholder()
        } else {
            content()
        }
    }
}

/// 一张本机条目的海报格（离线首页、离线海报墙共用）：长按「删除下载」
struct OfflinePosterCell: View {
    let item: OfflineItemSummary
    var width: CGFloat = PhoneCardWidth.homePoster
    var fixedWidth = true
    @Environment(\.api) private var api
    @State private var confirmDelete = false

    var body: some View {
        let store = OfflineStore.shared
        NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId)) {
            LibraryPosterCell(
                title: item.title, year: item.year,
                extent: item.kind == "tv" ? String(localized: .offlineDownloadedCount(store.units(ofItem: item.mediaItemId).filter(\.playable).count)) : nil,
                url: api.image(item.posterUrl, width: ImageWidth.points(width)),
                imageAspect: item.primaryAspect,
                placeholderSymbol: LibraryKindMeta.symbol(item.kind)
            )
            .frame(width: fixedWidth ? width : nil)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: .offlineDeleteDownload), systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog(
            String(localized: .offlineDeleteTitleDownload(item.title)), isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button(String(localized: .offlineDeleteWithSize(Formatters.bytes(Int(store.bytes(ofItem: item.mediaItemId))))), role: .destructive) {
                OfflineDownloader.shared.deleteItem(item.mediaItemId)
            }
        } message: {
            Text(String(localized: .offlineDeleteCopyHint(ClientPlatform.deviceName)))
        }
        .accessibilityIdentifier("offline-item-\(item.mediaItemId)")
    }
}

/// 离线首页：接着看 + 按库分组的已下载条目
struct OfflineLibraryHomeView: View {
    @Environment(\.cardMetrics) private var cards
    @State private var store = OfflineStore.shared
    @Environment(\.api) private var api

    var body: some View {
        let items = store.downloadedItems
        VStack(alignment: .leading, spacing: 0) {
            OfflineBanner().padding(.top, 12)
            if items.isEmpty {
                EmptyState(systemImage: "arrow.down.circle", title: String(localized: .offlineNoneOnDevice(ClientPlatform.deviceName)),
                           message: String(localized: .offlineEmptyHint))
                    .padding(.top, 40)
            } else {
                resumeRow
                ForEach(groups(items), id: \.libraryId) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        LibrarySectionHeader(title: group.name) {
                            NavigationLink(value: AppRoute.library(id: group.libraryId)) { Text(String(localized: .commonFiltersAll)) }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(group.items) { OfflinePosterCell(item: $0) }
                            }
                            .padding(.horizontal, cards.edge)
                        }
                        .scrollClipDisabled()
                    }
                    .padding(.top, 24)
                }
            }
        }
        .accessibilityIdentifier("offline-home")
    }

    private struct Group {
        var libraryId: Int
        var name: String
        var items: [OfflineItemSummary]
    }

    private func groups(_ items: [OfflineItemSummary]) -> [Group] {
        var order: [Int] = []
        var map: [Int: Group] = [:]
        for item in items {
            if map[item.libraryId] == nil {
                order.append(item.libraryId)
                map[item.libraryId] = Group(libraryId: item.libraryId, name: item.libraryName, items: [])
            }
            map[item.libraryId]?.items.append(item)
        }
        return order.compactMap { map[$0] }
    }

    /// 本机进度里有续播点、没看完的单元（续播只看位置 > 0，同服务端口径）
    private var resumeEntries: [(item: OfflineItemSummary, unit: OfflineUnit, progress: OfflineProgress)] {
        var entries: [(OfflineItemSummary, OfflineUnit, OfflineProgress)] = []
        for (itemId, map) in store.progress {
            guard let item = store.items[itemId] else { continue }
            for (key, value) in map where value.positionMs > 0 {
                let parts = key.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2,
                      let unit = store.playableUnit(mediaItemId: itemId, season: parts[0], episode: parts[1]) else { continue }
                entries.append((item, unit, value))
            }
        }
        return entries.sorted { $0.2.updatedAt > $1.2.updatedAt }
    }

    @ViewBuilder
    private var resumeRow: some View {
        let entries = resumeEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LibrarySectionHeader(title: String(localized: .libraryItemContinue)) { EmptyView() }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(entries, id: \.unit.fileId) { entry in
                            OfflineResumeCard(item: entry.item, unit: entry.unit, progress: entry.progress)
                        }
                    }
                    .padding(.horizontal, cards.edge)
                }
                .scrollClipDisabled()
            }
            .padding(.top, 24)
        }
    }
}

/// 「接着看」卡：横版剧照 + 进度条，点了直接从续播点接着放
private struct OfflineResumeCard: View {
    let item: OfflineItemSummary
    let unit: OfflineUnit
    let progress: OfflineProgress
    @Environment(\.api) private var api
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.play(PlayRequest(
                mediaItemId: item.mediaItemId,
                season: unit.isMovie ? nil : unit.season,
                episode: unit.isMovie ? nil : unit.episode,
                startSeconds: Double(progress.positionMs) / 1000
            ))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                LibraryArtwork(url: api.image(item.backdropUrl ?? item.posterUrl, width: ImageWidth.points(260)), frameAspect: 16 / 9)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        if let duration = progress.durationMs, duration > 0 {
                            GeometryReader { proxy in
                                Capsule().fill(.white.opacity(0.85))
                                    .frame(width: proxy.size.width * min(1, CGFloat(progress.positionMs) / CGFloat(duration)), height: 3)
                            }
                            .frame(height: 3)
                            .padding(8)
                        }
                    }
                Text(item.title).font(.footnote.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(unit.isMovie ? Formatters.clock(Double(progress.positionMs) / 1000) : String(localized: .offlineSeasonEpisode(unit.season, unit.episode)) + " · " + Formatters.clock(Double(progress.positionMs) / 1000))
                    .font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            .frame(width: 260)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("offline-resume-\(unit.fileId)")
    }
}

/// 离线时的某个库的海报墙：本机有的条目，按最近下载 / 片名排
struct OfflineLibraryWall: View {
    let libraryId: Int
    @State private var store = OfflineStore.shared
    @AppStorage("movieclaw.offline.wallSort") private var sortByTitle = false

    var body: some View {
        let items = store.downloadedItems.filter { $0.libraryId == libraryId }
        let sorted = sortByTitle ? items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : items
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OfflineBanner().padding(.top, 8)
                if sorted.isEmpty {
                    EmptyState(systemImage: "arrow.down.circle", title: String(localized: .offlineLibraryNoneOnDevice(ClientPlatform.deviceName)))
                        .padding(.top, 40)
                } else {
                    LibraryPosterGrid(items: sorted) { item in
                        OfflinePosterCell(item: item, width: LibraryGridColumn.width(minimum: 140), fixedWidth: false)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .appBackground()
        .navigationTitle(items.first?.libraryName ?? String(localized: .searchVerticalLibrary))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(String(localized: .mediaFiltersSort), selection: $sortByTitle) {
                        Text(String(localized: .offlineRecent)).tag(false)
                        Text(String(localized: .libraryRowsTitleHint)).tag(true)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel(String(localized: .mediaFiltersSort))
            }
        }
    }
}

/// 在线首页的「正在下载」提示条：有排队 / 下载中 / 暂停 / 失败的单元时才出现，下完自动消失。
/// 只汇总（在下什么、总速度、总进度）；每一集的状态在「我的 → 下载」的「下载中」里，点一下进去
struct OfflineDownloadingRow: View {
    @Environment(\.cardMetrics) private var cards
    @State private var store = OfflineStore.shared

    var body: some View {
        let active = store.activeUnits
        if !active.isEmpty {
            let summary = OfflineDownloadSummary(active, speeds: store.speeds, titles: store.items.mapValues(\.title),
                                                 waitingForWiFi: store.waitingForWiFi)
            NavigationLink(value: AppRoute.offlineStorage) {
                HStack(spacing: 12) {
                    OfflineProgressRing(fraction: summary.fraction, tint: summary.tint, paused: summary.allPaused)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(summary.detail).font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(summary.tint.opacity(0.08), in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(summary.tint.opacity(0.22)))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, cards.edge)
            .padding(.top, 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home-downloading")
        }
    }
}

/// 进行中的下载汇总成一句话（首页提示条）
struct OfflineDownloadSummary {
    let title: String
    let detail: String
    /// 已下字节 ÷ 预计总字节（大小都还不知道时为 nil）
    let fraction: Double?
    let tint: Color
    let allPaused: Bool

    /// - Parameter titles: 条目号 → 片名（只下一部时标题写片名）
    /// - Parameter waitingForWiFi: 只许 Wi-Fi 下、眼下是计费网络：明说在等 Wi-Fi
    init(_ units: [OfflineUnit], speeds: [Int: Double], titles: [Int: String] = [:], waitingForWiFi: Bool = false) {
        let downloading = units.filter { $0.state == .downloading }
        let failed = units.filter(\.needsAttention)
        let waitingTranscode = units.filter(\.waitingForTranscode)
        let speed = downloading.reduce(0) { $0 + (speeds[$1.fileId] ?? 0) }
        let sized = units.filter { $0.expectedBytes > 0 }
        let expected = sized.reduce(Int64(0)) { $0 + $1.expectedBytes }
        let received = sized.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.expectedBytes) }
        fraction = expected > 0 ? Double(received) / Double(expected) : nil
        allPaused = units.allSatisfy { $0.state == .paused }
        tint = !failed.isEmpty && downloading.isEmpty ? Theme.warning : Theme.info
        title = Self.title(units, titles: titles, paused: allPaused)
        var parts: [String] = []
        if waitingForWiFi, !allPaused, units.contains(where: { $0.state == .queued || $0.state == .downloading }) {
            parts.append(String(localized: .offlineWaitingWifi))
        } else if speed > 0 {
            parts.append("\(Formatters.bytes(Int(speed)))/s")
        } else if !failed.isEmpty, downloading.isEmpty {
            parts.append(String(localized: .offlineInterruptedCount(failed.count)))
        } else if !waitingTranscode.isEmpty, downloading.isEmpty {
            parts.append(String(localized: .offlineWaitingTranscode))
        } else if !allPaused, downloading.isEmpty {
            parts.append(String(localized: .offlineWaitingDownload))
        }
        if let fraction { parts.append("\(Int(fraction * 100))%") }
        detail = parts.isEmpty ? String(localized: .offlineTapToView) : parts.joined(separator: " · ")
    }

    /// 标题写清在下什么：「正在下载《沙丘》」「正在下载《兰香如故》5 集」「3 部电影正在下载」
    /// 「2 部剧共 5 集正在下载」「3 部电影、5 集剧集正在下载」；全暂停时「正在下载」换成「已暂停」
    static func title(_ units: [OfflineUnit], titles: [Int: String], paused: Bool) -> String {
        let movies = Set(units.filter(\.isMovie).map(\.mediaItemId))
        let episodes = units.filter { !$0.isMovie }
        let shows = Set(episodes.map(\.mediaItemId))
        switch (movies.count, shows.count) {
        case (1, 0):
            if let title = titles[movies.first!] {
                return paused ? String(localized: .offlineRingPausedTitle(title)) : String(localized: .offlineRingDownloadingTitle(title))
            }
        case (0, 1):
            if let title = titles[shows.first!] {
                return paused ? String(localized: .offlineRingPausedEpisodes(title, episodes.count))
                    : String(localized: .offlineRingDownloadingEpisodes(title, episodes.count))
            }
        default: break
        }
        let subject = switch (movies.count, shows.count) {
        case (_, 0): String(localized: .offlineRingMovies(movies.count))
        case (0, 1): String(localized: .offlineRingEpisodes(episodes.count))
        case (0, _): String(localized: .offlineRingShowEpisodes(shows.count, episodes.count))
        default: AppFormatting.list([String(localized: .offlineRingMovies(movies.count)), String(localized: .offlineRingEpisodes(episodes.count))])
        }
        return paused ? String(localized: .offlineRingSubjectPaused(subject)) : String(localized: .offlineRingSubjectDownloading(subject))
    }
}

/// 总进度环：中间是下载箭头（全暂停时是暂停号）
struct OfflineProgressRing: View {
    let fraction: Double?
    let tint: Color
    var paused = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction ?? 0)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            Image(systemName: paused ? "pause.fill" : "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 34, height: 34)
    }
}

/// 剧照上的下载状态（详情页分集卡）：蓝描边 + 底部一条——
/// 左边状态图标、中间「下载中 47%」、右边实时速度，最底下一道进度
struct OfflineDownloadStrip: View {
    let unit: OfflineUnit
    var cornerRadius: CGFloat = Theme.posterRadius
    @State private var store = OfflineStore.shared

    var body: some View {
        let tint = unit.needsAttention ? Theme.warning : Theme.info
        let speed = unit.state == .downloading && !store.waitingForWiFi ? store.speeds[unit.fileId].flatMap { $0 > 0 ? $0 : nil } : nil
        let status = Self.status(unit, ahead: store.queueAhead(of: unit.fileId), waitingForWiFi: store.waitingForWiFi)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(tint, lineWidth: 2)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    icon(tint)
                    Text(status).lineLimit(1)
                    Spacer(minLength: 4)
                    if let speed {
                        Text("\(Formatters.bytes(Int(speed)))/s").monospacedDigit().lineLimit(1)
                            .foregroundStyle(tint.opacity(0.8))
                            .accessibilityIdentifier("download-speed")
                    }
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 6)
                GeometryReader { proxy in
                    Rectangle().fill(tint).frame(width: proxy.size.width * max(0, min(1, unit.progressFraction)))
                }
                .frame(height: 2)
            }
            .background(Color(red: 7 / 255, green: 12 / 255, blue: 20 / 255).opacity(0.92))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speed.map { "\(status)，\(Formatters.bytes(Int($0)))/s" } ?? status)
    }

    @ViewBuilder
    private func icon(_ tint: Color) -> some View {
        switch unit.state {
        case .paused: Image(systemName: "pause.circle.fill")
        case .failed: Image(systemName: unit.waitingForTranscode ? "hourglass" : "exclamationmark.circle.fill")
        default:
            if unit.damaged {
                Image(systemName: "exclamationmark.circle.fill")
            } else {
                ProgressView().controlSize(.mini).tint(tint)
            }
        }
    }

    /// 一行状态（卡片窄，比通用文案短）。`ahead`：下载队列里排在它前面的个数；`waitingForWiFi`：只许 Wi-Fi 下、眼下是计费网络
    static func status(_ unit: OfflineUnit, ahead: Int = 0, waitingForWiFi: Bool = false) -> String {
        let percent = unit.expectedBytes > 0 ? " \(Int(unit.progressFraction * 100))%" : ""
        if unit.damaged { return String(localized: .offlineDamaged) }
        if waitingForWiFi, unit.state == .queued || unit.state == .downloading { return String(localized: .offlineWaitingWifi) }
        return switch unit.state {
        case .preparing: String(localized: .offlinePreparing)
        case .queued:
            ahead == 1 ? String(localized: .offlineQueueNext)
                : ahead > 1 ? String(localized: .offlineQueueAhead(ahead)) : String(localized: .offlineWaitingDownload)
        case .downloading: String(localized: .subscriptionArrivalsStatusDownloading) + percent
        case .paused: String(localized: .subscriptionSectionsPaused) + percent
        case .failed: unit.waitingForTranscode ? unit.transcodeWait ?? String(localized: .offlineWaitingTranscode) : unit.retryable ? String(localized: .offlineInterruptedRetry) : String(localized: .settingsPluginMarketDownloadFailed)
        case .done: String(localized: .subscriptionWantedDownloaded)
        }
    }
}

/// 单元状态的一句话（存储页「下载中」、详情页下载按钮共用）
enum OfflineUnitStatus {
    /// `ahead`：下载队列里排在它前面的个数（「下一个下载」「等待下载，前面还有 N 个」）；
    /// `waitingForWiFi`：只许 Wi-Fi 下、眼下是计费网络，排队和下着的都在等 Wi-Fi
    static func text(_ unit: OfflineUnit, ahead: Int = 0, waitingForWiFi: Bool = false) -> String {
        if waitingForWiFi, unit.state == .queued || unit.state == .downloading { return String(localized: .offlineWaitingWifi) }
        return switch unit.state {
        case .preparing: String(localized: .offlinePreparingEllipsis)
        case .queued:
            ahead == 1 ? String(localized: .offlineQueueNext)
                : ahead > 1 ? String(localized: .offlineQueueWaitingAhead(ahead)) : String(localized: .offlineWaitingDownload)
        case .downloading:
            unit.expectedBytes > 0 ? String(localized: .subscriptionArrivalsStatusDownloading) + " \(Int(unit.progressFraction * 100))%" : String(localized: .offlineDownloadingBytes(Formatters.bytes(Int(unit.receivedBytes))))
        case .paused: String(localized: .playerControlsPaused)
        case .failed:
            unit.waitingForTranscode ? unit.transcodeWait ?? String(localized: .offlineWaitingTranscode)
                : unit.retryable ? String(localized: .offlineInterruptedAutoRetry) : (unit.error ?? String(localized: .settingsPluginMarketDownloadFailed))
        case .done: unit.damaged ? String(localized: .offlineDamaged) : String(localized: .subscriptionWantedDownloaded)
        }
    }
}

/// 极简离线详情（docs/design/offline-download.md §3.3）：本机存的详情解不开时，只靠摘要也能播、能删
struct OfflineMinimalDetail: View {
    let itemId: Int
    @State private var store = OfflineStore.shared
    @Environment(\.api) private var api
    @Environment(Router.self) private var router

    var body: some View {
        let units = store.units(ofItem: itemId).filter(\.playable)
        List {
            if let item = store.items[itemId] {
                Section {
                    HStack(spacing: 14) {
                        LibraryArtwork(url: api.image(item.posterUrl, width: ImageWidth.points(90)), imageAspect: item.primaryAspect,
                                       frameAspect: Theme.posterAspect)
                            .frame(width: 90)
                            .clipShape(.rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.title3.weight(.semibold))
                            if let year = item.year { Text(String(year)).foregroundStyle(Theme.textMuted) }
                            Text(String(localized: .offlineCopyOnDevice(ClientPlatform.deviceName))).font(.caption).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                Section {
                    ForEach(units) { unit in
                        HStack {
                            Button {
                                router.play(PlayRequest(mediaItemId: itemId, season: unit.isMovie ? nil : unit.season,
                                                        episode: unit.isMovie ? nil : unit.episode, startSeconds: nil))
                            } label: {
                                Label(unit.isMovie ? String(localized: .libraryHeroPlay) : String(localized: .offlineSeasonEpisode(unit.season, unit.episode)), systemImage: "play.fill")
                            }
                            Spacer()
                            Text(Formatters.bytes(Int(unit.receivedBytes))).font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        .swipeActions {
                            Button(String(localized: .commonDelete), role: .destructive) { OfflineDownloader.shared.delete(fileId: unit.fileId) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("offline-minimal-detail")
    }
}
