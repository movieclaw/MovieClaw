import SwiftUI

/// 我的 → 下载（docs/design/offline-download.md §8）：
/// 下载中（有才出现，每一集一行，下完就移到已下载）→ 清理建议（有已看完的才出现）
/// → 已下载（点进条目、左滑 / 长按删除）→ 其他账号 → 容量条（放最后）；下载设置在右上角菜单。首页的「正在下载」提示条点进这里
struct OfflineStorageView: View {
    var body: some View {
        List { OfflineStorageSections() }
            .listStyle(.plain)
            .listSectionSpacing(8)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .appBackground()
            .navigationTitle(String(localized: .searchDownloadIdle))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { OfflineStorageSettingsMenu() }
            }
            .accessibilityIdentifier("offline-storage")
    }
}

/// 同一份下载管理内容用于独立下载页和「我的」页签，避免在 List 中再嵌套 List。
struct OfflineStorageSections: View {
    var embedded = false
    @State private var store = OfflineStore.shared
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var otherOwners: [(owner: OfflineOwner, bytes: Int64, items: Int)] = []
    @State private var confirm: Confirm?
    /// 容量条的读数：打开页面、下完一集、删除时才取一次（查磁盘余量不便宜，下载中也不该每秒跳）
    @State private var capacity: StorageCapacity?

    private enum Confirm: Identifiable {
        case items([Int])
        case watched
        case owner(OfflineOwner)
        var id: String {
            switch self {
            case let .items(ids): "items-\(ids)"
            case .watched: "watched"
            case let .owner(owner): "owner-\(owner.key)"
            }
        }
    }

    var body: some View {
        let items = store.downloadedItems
        let active = store.activeUnits
        let watched = watchedUnits
        Group {
            if !active.isEmpty {
                Section {
                    if store.waitingForWiFi { OfflineWaitingWiFiNotice() }
                    // 顺序就是优先级（§5.5）：按住一行拖动换先后，拖到最前、能马上下的那个立刻开始
                    // 只列有展示摘要的：拖动的序号按画出来的行算
                    let rows = active.filter { store.items[$0.mediaItemId] != nil }.map(OfflineDownloadingRowModel.init)
                    ForEach(rows) { row in
                        if let item = store.items[row.mediaItemId] {
                            OfflineDownloadingStorageRow(row: row, item: item)
                        }
                    }
                    .onMove { from, to in
                        var ids = rows.map(\.fileId)
                        ids.move(fromOffsets: from, toOffset: to)
                        OfflineDownloader.shared.reorder(ids)
                    }
                } header: {
                    // 标识只挂在标题上：挂在 Section 上会盖掉每一行自己的标识
                    Text(String(localized: .downloadStatusDownloading)).font(.headline).foregroundStyle(Theme.text)
                        .accessibilityIdentifier("offline-storage-downloading")
                }
            }
            if !watched.isEmpty {
                Section(String(localized: .offlineSuggestions)) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: .offlineDeleteWatchedAction)).font(.body.weight(.medium))
                            Text(String(localized: .offlineWatchedUsage(watched.count, Formatters.bytes(Int(watched.reduce(0) { $0 + $1.receivedBytes })))))
                                .font(.footnote).foregroundStyle(Theme.textMuted)
                        }
                        Spacer(minLength: 8)
                        Button(String(localized: .commonDelete)) { confirm = .watched }
                            .buttonStyle(.bordered).tint(.red).controlSize(.small)
                            .accessibilityIdentifier("offline-delete-watched")
                            .modifier(confirmation(.watched))
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                if items.isEmpty {
                    Text(active.isEmpty ? String(localized: .offlineStorageEmpty) : String(localized: .offlineFinishedAppearHere))
                        .font(.subheadline).foregroundStyle(Theme.textMuted)
                }
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId)) {
                        row(item)
                    }
                    .swipeActions { deleteAction { confirm = .items([item.mediaItemId]) } }
                    .contextMenu {
                        Button(String(localized: .offlineDeleteDownload), systemImage: "trash", role: .destructive) { confirm = .items([item.mediaItemId]) }
                    }
                    .modifier(confirmation(.items([item.mediaItemId])))
                }
            } header: {
                HStack(spacing: 8) {
                    Text(String(localized: .subscriptionWantedDownloaded)).font(.headline).foregroundStyle(Theme.text)
                    if !items.isEmpty {
                        Text(String(localized: .libraryStatusTitleCount(items.count))).font(.subheadline).foregroundStyle(Theme.textMuted)
                    }
                    if embedded {
                        Spacer()
                        OfflineStorageSettingsMenu()
                    }
                }
                .task { await loadOtherOwners() }
                .task(id: store.doneBytes) { capacity = await StorageCapacity.read(downloads: store.doneBytes) }
            }
            if !otherOwners.isEmpty {
                Section {
                    ForEach(otherOwners, id: \.owner.key) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.owner.username)
                                Text(String(localized: .libraryDetailInitialCount(entry.owner.origin.host() ?? entry.owner.origin.absoluteString, entry.items)))
                                    .font(.caption).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Text(Formatters.bytes(Int(entry.bytes))).monospacedDigit().foregroundStyle(Theme.textMuted)
                        }
                        .swipeActions { deleteAction { confirm = .owner(entry.owner) } }
                        .modifier(confirmation(.owner(entry.owner)))
                    }
                } header: {
                    Text(String(localized: .offlineOtherAccounts))
                } footer: {
                    Text(String(localized: .offlineOtherAccountsHint(ClientPlatform.deviceName)))
                }
            }
            // 容量放最后：这一页先管下载，剩余空间是参考（空间不够时选档面板会直接提示）
            Section {
                StorageUsageBar(capacity: capacity)
                    .accessibilityIdentifier("offline-storage-summary")
                    .padding(.top, 12)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
        .listRowBackground(Color.clear)
        .textCase(nil)
    }

    /// 删除确认挂在触发它的那一行 / 那个按钮上：iOS 26 的确认框以气泡从来源处弹出，挂在整个列表上会浮在页面中间
    private func confirmation(_ target: Confirm) -> ConfirmDelete {
        ConfirmDelete(
            title: title(of: target),
            action: String(localized: .offlineDeleteFreeing(Formatters.bytes(Int(bytes(of: target))))),
            isPresented: Binding(mcGet: { confirm?.id == target.id }, set: { if !$0, confirm?.id == target.id { confirm = nil } }),
            perform: { perform(target) }
        )
    }

    /// 左滑删除：不用 role: .destructive（那会让系统先把行做删除动画移走，这里还要等确认框），显式染成系统红
    private func deleteAction(_ action: @escaping () -> Void) -> some View {
        Button(String(localized: .commonDelete), systemImage: "trash", action: action).tint(.red)
    }

    private func row(_ item: OfflineItemSummary) -> some View {
        let units = store.units(ofItem: item.mediaItemId)
        let done = units.filter(\.playable)
        let active = units.filter(\.isActive)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            OfflineStoragePoster(item: item)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detailLine(item, done: done, active: active))
                    .font(.footnote).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Formatters.bytes(Int(store.doneBytesByItem[item.mediaItemId] ?? 0)))
                    .font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("offline-storage-item-\(item.mediaItemId)")
    }

    private func detailLine(_ item: OfflineItemSummary, done: [OfflineUnit], active: [OfflineUnit]) -> String {
        var parts: [String] = []
        if item.kind == "tv" {
            parts.append(String(localized: .offlineDownloadedCount(done.count)))
        } else if let unit = done.first {
            parts.append(unit.profileLabel)
        }
        if !active.isEmpty { parts.append(String(localized: .offlineStillDownloading(active.count))) }
        return parts.joined(separator: " · ")
    }

    /// 看完了的本机单元（本机进度标了已看）
    private var watchedUnits: [OfflineUnit] {
        store.units.values.filter { unit in
            unit.playable && store.localProgress(itemId: unit.mediaItemId, season: unit.season, episode: unit.episode)?.played == true
        }
    }

    private func title(of target: Confirm) -> String {
        switch target {
        case let .items(ids): ids.count == 1 ? String(localized: .offlineDeleteTitleDownload(store.items[ids[0]]?.title ?? ""))
            : String(localized: .offlineDeleteTitlesDownload(ids.count))
        case .watched: String(localized: .offlineDeleteWatched(watchedUnits.count))
        case let .owner(owner): String(localized: .offlineDeleteOwnerDownloads(owner.username, ClientPlatform.deviceName))
        }
    }

    private func bytes(of target: Confirm) -> Int64 {
        switch target {
        case let .items(ids): ids.reduce(0) { $0 + store.bytes(ofItem: $1) }
        case .watched: watchedUnits.reduce(0) { $0 + $1.receivedBytes }
        case let .owner(owner): otherOwners.first { $0.owner.key == owner.key }?.bytes ?? 0
        }
    }

    private func perform(_ target: Confirm) {
        switch target {
        case let .items(ids):
            for id in ids { OfflineDownloader.shared.deleteItem(id) }
        case .watched:
            for unit in watchedUnits { OfflineDownloader.shared.delete(fileId: unit.fileId) }
        case let .owner(owner):
            OfflineOwners.remove(owner)
            otherOwners.removeAll { $0.owner.key == owner.key }
            // 别的账号的下载不在本账号的目录里，删了容量条读数不会自己变
            Task { capacity = await StorageCapacity.read(downloads: store.doneBytes) }
        }
        confirm = nil
    }

    private func loadOtherOwners() async {
        let current = store.key
        otherOwners = await Task.detached {
            OfflineOwners.scan().filter { $0.key != current }.map { owner in
                let usage = OfflineOwners.usage(owner)
                return (owner, usage.bytes, usage.items)
            }.filter { $0.1 > 0 }
        }.value
    }
}

/// 下载中与已下载共用同一条海报、文字对齐线。
private struct OfflineStoragePoster: View {
    let item: OfflineItemSummary
    @Environment(\.api) private var api

    var body: some View {
        LibraryArtwork(url: api.image(item.posterUrl, width: ImageWidth.points(60)),
                       imageAspect: item.primaryAspect, frameAspect: Theme.posterAspect)
            .frame(width: 60, height: 90)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

/// 「下载中」顶上的提示：没开「使用蜂窝网络下载」、眼下又是计费网络时，下载会一直等 Wi-Fi——说清楚，并给一键打开
private struct OfflineWaitingWiFiNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.title3).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 8) {
                // 标识挂在文字上：挂在整条上会盖掉按钮自己的标识
                Text(String(localized: .offlineWaitingWifiHint)).font(.subheadline).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("offline-waiting-wifi")
                Button(String(localized: .offlineUseCellular)) { OfflineDownloader.shared.setAllowCellular(true) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("offline-use-cellular")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}

/// 独立下载页用工具栏，内嵌下载列表用分区标题；共享同一个本机设置菜单。
private struct OfflineStorageSettingsMenu: View {
    @State private var store = OfflineStore.shared

    var body: some View {
        Menu {
            Section(String(localized: .offlineCellularFooter)) {
                Toggle(String(localized: .offlineUseCellular), systemImage: "antenna.radiowaves.left.and.right",
                       isOn: Binding(get: { store.allowCellular }, set: { OfflineDownloader.shared.setAllowCellular($0) }))
                    .toggleStyle(.automatic)
            }
        } label: {
            Image(systemName: "gearshape")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: .offlineSettings))
        .accessibilityIdentifier("offline-settings")
    }
}

/// 「下载中」的一行：海报 + 片名 + 哪一集 · 档位 + 状态与速度 + 进度。
/// 点进条目；左滑 / 长按暂停、继续、取消。下完就从这一组消失
/// 「下载中」一行里不随进度变的部分：进度每秒刷新只重绘行里的进度那一块（`OfflineDownloadingProgress`），
/// 行本身不跟着重绘——否则按住拖动 / 长按菜单时行被刷新，菜单里点「暂停」会落空（模拟器实测）
private struct OfflineDownloadingRowModel: Hashable, Identifiable {
    let fileId: Int
    let mediaItemId: Int
    let season: Int
    let episode: Int
    let profileLabel: String
    let state: OfflineUnit.State
    let waitingForTranscode: Bool

    init(_ unit: OfflineUnit) {
        fileId = unit.fileId
        mediaItemId = unit.mediaItemId
        season = unit.season
        episode = unit.episode
        profileLabel = unit.profileLabel
        state = unit.state
        waitingForTranscode = unit.waitingForTranscode
    }

    var id: Int { fileId }
    var isMovie: Bool { season == 0 && episode == 0 }
}

private struct OfflineDownloadingStorageRow: View {
    let row: OfflineDownloadingRowModel
    let item: OfflineItemSummary
    @State private var store = OfflineStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId,
                                                   season: row.isMovie ? nil : row.season,
                                                   episode: row.isMovie ? nil : row.episode)) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 16))
            layout {
                OfflineStoragePoster(item: item)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([row.isMovie ? nil : String(localized: .offlineSeasonEpisode(row.season, row.episode)), row.profileLabel]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    OfflineDownloadingProgress(fileId: row.fileId)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 长按出菜单，按住拖动换顺序；轻扫同样能操作（行首一侧优先下载，另一侧暂停 / 继续 / 取消）。行上不放按钮。
        // 菜单的预览用一张不随进度变的小卡：拿正在刷新进度的行当预览，菜单一直处在动画里、点「暂停」会落空
        .swipeActions(edge: .leading) { prioritize }
        .swipeActions { actions }
        .contextMenu {
            prioritize
            actions
        } preview: {
            HStack(spacing: 12) {
                OfflineStoragePoster(item: item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    Text([row.isMovie ? nil : String(localized: .offlineSeasonEpisode(row.season, row.episode)), row.profileLabel]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
            .background(Color(red: 30 / 255, green: 33 / 255, blue: 43 / 255))
        }
        .accessibilityIdentifier("offline-downloading-\(row.fileId)")
    }

    @ViewBuilder
    private var prioritize: some View {
        if store.canPrioritize(fileId: row.fileId) {
            Button(String(localized: .offlinePrioritize), systemImage: "arrow.up.to.line") {
                OfflineDownloader.shared.prioritize([row.fileId])
            }
            .tint(Theme.info)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if row.waitingForTranscode {
            // 排队等服务器转码：到点自己会再去问，只给取消
        } else if row.state == .paused || row.state == .failed {
            Button(String(localized: .offlineResumeDownload), systemImage: "play") { OfflineDownloader.shared.resume(fileId: row.fileId) }.tint(Theme.info)
        } else {
            Button(String(localized: .playerControlsPause), systemImage: "pause") { OfflineDownloader.shared.pause(fileId: row.fileId) }.tint(.gray)
        }
        Button(String(localized: .offlineCancelDownload), systemImage: "xmark") { OfflineDownloader.shared.delete(fileId: row.fileId) }.tint(.red)
    }
}

/// 「下载中」一行的状态、速度与进度条：只有这一块跟着进度每秒刷新
private struct OfflineDownloadingProgress: View {
    let fileId: Int
    @State private var store = OfflineStore.shared

    var body: some View {
        if let unit = store.units[fileId] {
            let speed = unit.state == .downloading && !store.waitingForWiFi ? store.speeds[fileId].flatMap { $0 > 0 ? $0 : nil } : nil
            let tint = unit.needsAttention ? Theme.warning : Theme.info
            HStack(spacing: 6) {
                Text(OfflineUnitStatus.text(unit, ahead: store.queueAhead(of: fileId), waitingForWiFi: store.waitingForWiFi))
                    .foregroundStyle(tint)
                if let speed {
                    Text("\(Formatters.bytes(Int(speed)))/s").foregroundStyle(Theme.textMuted)
                }
            }
            .font(.footnote).monospacedDigit()
            ProgressView(value: max(0, min(1, unit.progressFraction))).tint(tint)
        }
    }
}

/// 容量条的一次读数。磁盘余量的查询（含可清理空间的估算）放到后台线程，不卡主线程
struct StorageCapacity: Equatable, Sendable {
    let downloads: Int64
    let free: Int64?
    let total: Int64?

    static func read(downloads: Int64) async -> StorageCapacity {
        await Task.detached(priority: .utility) {
            StorageCapacity(downloads: downloads, free: OfflineDisk.availableBytes, total: OfflineDisk.totalCapacity)
        }.value
    }
}

/// 容量条（同系统「iPhone 储存空间」）：MovieClaw 下载 / 其他已用 / 剩余。读数是快照，不跟下载进度变
private struct StorageUsageBar: View {
    let capacity: StorageCapacity?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let downloads = capacity?.downloads ?? 0
        let free = capacity?.free
        let total = capacity?.total
        VStack(alignment: .leading, spacing: 12) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            layout {
                Text(String(localized: .offlineDeviceStorage)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if let free {
                    Text(String(localized: .offlineAvailable(Formatters.bytes(Int(free)))))
                        .font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
            }
            if let total, total > 0, let free {
                let other = max(0, total - free - downloads)
                GeometryReader { proxy in
                    // 最小可见下载段仍计入总宽，不能把右侧可用空间挤出面板。
                    let downloadedWidth = min(proxy.size.width, max(downloads > 0 ? 3 : 0,
                        proxy.size.width * CGFloat(downloads) / CGFloat(total)))
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.info).frame(width: downloadedWidth)
                        Rectangle().fill(.white.opacity(0.25))
                            .frame(width: min(proxy.size.width - downloadedWidth, proxy.size.width * CGFloat(other) / CGFloat(total)))
                        Rectangle().fill(.white.opacity(0.06))
                    }
                    .clipShape(.capsule)
                }
                .frame(height: 6)
                layout {
                    legend(Theme.info, String(localized: .offlineDownloadsLegend(Formatters.bytes(Int(downloads)))))
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    legend(.white.opacity(0.25), String(localized: .offlineOtherUsed))
                }
            } else {
                Text(String(localized: .offlineMovieclawDownloads(Formatters.bytes(Int(downloads))))).font(.subheadline).monospacedDigit()
            }
        }
        .padding(16)
        .background(Theme.surfaceInset, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted)
        }
    }
}

/// 存储页的删除确认（挂在来源上，见 `OfflineStorageView.confirmation`）
private struct ConfirmDelete: ViewModifier {
    let title: String
    let action: String
    let isPresented: Binding<Bool>
    let perform: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(action, role: .destructive, action: perform)
        } message: {
            Text(String(localized: .offlineDeleteCopyHint(ClientPlatform.deviceName)))
        }
    }
}
