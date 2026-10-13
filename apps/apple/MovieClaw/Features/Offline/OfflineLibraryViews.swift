import SwiftUI

// 离线模式下的媒体库（docs/design/offline-download.md §1、§4）：同一个媒体库页签、同一套海报格，
// 数据换成本机目录。首页只留「接着看」与按库分组的已下载条目，不还原自定义首页。

/// 离线模式顶部的提示条：说明在看的是 iPhone 上的内容，可以手动重连
struct OfflineBanner: View {
    @State private var reachability = ServerReachability.shared
    @State private var store = OfflineStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("离线浏览").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text("显示 iPhone 上已下载的 \(store.downloadedItemIds.count) 部")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Button("重新连接") { reachability.reconnect() }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.glass)
                .accessibilityIdentifier("offline-reconnect")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.warning.opacity(0.08), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.warning.opacity(0.22)))
        .padding(.horizontal, Theme.pagePadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-banner")
    }
}

/// 离线时页签的占位：订阅、发现、活动、搜索这些都要连服务器
struct OfflinePlaceholder: View {
    var title = "离线中"
    @Environment(Router.self) private var router
    @State private var reachability = ServerReachability.shared

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wifi.slash")
        } description: {
            Text("这里需要连接服务器。iPhone 上已下载的影片在「媒体库」里，可以照常播放。")
        } actions: {
            Button("去媒体库") { router.selectTab(.library) }
                .buttonStyle(.glassProminent)
            Button("重新连接") { reachability.reconnect() }
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
                extent: item.kind == "tv" ? "已下载 \(store.units(ofItem: item.mediaItemId).filter(\.playable).count) 集" : nil,
                url: api.image(item.posterUrl, width: ImageWidth.points(width)),
                imageAspect: item.primaryAspect,
                placeholderSymbol: LibraryKindMeta.symbol(item.kind)
            )
            .frame(width: fixedWidth ? width : nil)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除下载", systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog(
            "删除「\(item.title)」的下载？", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("删除下载（\(Formatters.bytes(Int(store.bytes(ofItem: item.mediaItemId)))))", role: .destructive) {
                OfflineDownloader.shared.deleteItem(item.mediaItemId)
            }
        } message: {
            Text("只删 iPhone 上的副本，观看进度会保留。")
        }
        .accessibilityIdentifier("offline-item-\(item.mediaItemId)")
    }
}

/// 离线首页：接着看 + 按库分组的已下载条目
struct OfflineLibraryHomeView: View {
    @State private var store = OfflineStore.shared
    @Environment(\.api) private var api

    var body: some View {
        let items = store.downloadedItems
        VStack(alignment: .leading, spacing: 0) {
            OfflineBanner().padding(.top, 12)
            if items.isEmpty {
                EmptyState(systemImage: "arrow.down.circle", title: "iPhone 上还没有下载",
                           message: "连上服务器后，在影片详情页点「下载」，没网的时候也能看。")
                    .padding(.top, 40)
            } else {
                resumeRow
                ForEach(groups(items), id: \.libraryId) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        LibrarySectionHeader(title: group.name) {
                            NavigationLink(value: AppRoute.library(id: group.libraryId)) { Text("全部") }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(group.items) { OfflinePosterCell(item: $0) }
                            }
                            .padding(.horizontal, Theme.pagePadding)
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
                LibrarySectionHeader(title: "接着看") { EmptyView() }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(entries, id: \.unit.fileId) { entry in
                            OfflineResumeCard(item: entry.item, unit: entry.unit, progress: entry.progress)
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
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
                Text(unit.isMovie ? Formatters.clock(Double(progress.positionMs) / 1000) : "第 \(unit.season) 季第 \(unit.episode) 集 · \(Formatters.clock(Double(progress.positionMs) / 1000))")
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
                    EmptyState(systemImage: "arrow.down.circle", title: "这个库在 iPhone 上没有下载")
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
        .navigationTitle(items.first?.libraryName ?? "媒体库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $sortByTitle) {
                        Text("最近下载").tag(false)
                        Text("片名").tag(true)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("排序")
            }
        }
    }
}

/// 在线首页的「正在下载」行：有排队 / 下载中 / 失败的单元时才出现，下完自动消失
struct OfflineDownloadingRow: View {
    @State private var store = OfflineStore.shared
    @Environment(\.api) private var api

    var body: some View {
        let active = store.activeUnits
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LibrarySectionHeader(title: "正在下载") {
                    NavigationLink(value: AppRoute.offlineStorage) { Text("管理") }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(active) { unit in
                            if let item = store.items[unit.mediaItemId] {
                                NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId,
                                                                           season: unit.isMovie ? nil : unit.season,
                                                                           episode: unit.isMovie ? nil : unit.episode)) {
                                    LibraryPosterCell(
                                        title: item.title, year: unit.isMovie ? item.year : nil,
                                        extent: unit.isMovie ? nil : "第 \(unit.season) 季第 \(unit.episode) 集",
                                        url: api.image(item.posterUrl, width: ImageWidth.points(PhoneCardWidth.homePoster)),
                                        imageAspect: item.primaryAspect,
                                        working: OfflineUnitStatus.text(unit)
                                    )
                                    .frame(width: PhoneCardWidth.homePoster)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                }
                .scrollClipDisabled()
            }
            .padding(.top, 24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-downloading")
        }
    }
}

/// 单元状态的一句话（「正在下载」行、存储页、详情页下载按钮共用）
enum OfflineUnitStatus {
    static func text(_ unit: OfflineUnit) -> String {
        switch unit.state {
        case .preparing: "正在准备…"
        case .queued: "等待下载"
        case .downloading:
            unit.expectedBytes > 0 ? "下载中 \(Int(unit.progressFraction * 100))%" : "下载中 \(Formatters.bytes(Int(unit.receivedBytes)))"
        case .paused: "已暂停"
        case .failed: unit.retryable ? "下载中断，稍后自动重试" : (unit.error ?? "下载失败")
        case .done: unit.damaged ? "文件损坏，请重新下载" : "已下载"
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
                            Text("iPhone 上的副本").font(.caption).foregroundStyle(Theme.textFaint)
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
                                Label(unit.isMovie ? "播放" : "第 \(unit.season) 季第 \(unit.episode) 集", systemImage: "play.fill")
                            }
                            Spacer()
                            Text(Formatters.bytes(Int(unit.receivedBytes))).font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { OfflineDownloader.shared.delete(fileId: unit.fileId) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("offline-minimal-detail")
    }
}
