import SwiftUI

/// 我的 → 下载（docs/design/offline-download.md §8）：
/// 下载中（有才出现，每一集一行，下完就移到已下载）→ 清理建议（有已看完的才出现）
/// → 已下载（点进条目、左滑 / 长按删除）→ 其他账号 → 容量条（放最后）；下载设置在右上角菜单。首页的「正在下载」提示条点进这里
struct OfflineStorageView: View {
    @State private var store = OfflineStore.shared
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var model
    @State private var otherOwners: [(owner: OfflineOwner, bytes: Int64, items: Int)] = []
    @State private var allowCellular = OfflineSettings.allowCellular
    @State private var confirm: Confirm?

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
        List {
            if !active.isEmpty {
                Section {
                    ForEach(active) { unit in
                        if let item = store.items[unit.mediaItemId] {
                            OfflineDownloadingStorageRow(unit: unit, item: item)
                        }
                    }
                } header: {
                    // 标识只挂在标题上：挂在 Section 上会盖掉每一行自己的标识
                    Text("下载中").accessibilityIdentifier("offline-storage-downloading")
                }
            }
            if !watched.isEmpty {
                Section("建议") {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("删除已看完的")
                            Text("\(watched.count) 个已看完，占用 \(Formatters.bytes(Int(watched.reduce(0) { $0 + $1.receivedBytes })))")
                                .font(.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer(minLength: 8)
                        Button("删除") { confirm = .watched }
                            .buttonStyle(.bordered).tint(.red).controlSize(.small)
                            .accessibilityIdentifier("offline-delete-watched")
                            .modifier(confirmation(.watched))
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("已下载") {
                if items.isEmpty {
                    Text(active.isEmpty ? "还没有下载。在影片详情页点「下载」，没网的时候也能看。" : "下完的会出现在这里。")
                        .font(.subheadline).foregroundStyle(Theme.textMuted)
                }
                ForEach(items) { item in
                    NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId)) {
                        row(item)
                    }
                    .swipeActions { deleteAction { confirm = .items([item.mediaItemId]) } }
                    .contextMenu {
                        Button("删除下载", systemImage: "trash", role: .destructive) { confirm = .items([item.mediaItemId]) }
                    }
                    .modifier(confirmation(.items([item.mediaItemId])))
                }
            }
            if !otherOwners.isEmpty {
                Section {
                    ForEach(otherOwners, id: \.owner.key) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.owner.username)
                                Text("\(entry.owner.origin.host() ?? entry.owner.origin.absoluteString) · \(entry.items) 部")
                                    .font(.caption).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Text(Formatters.bytes(Int(entry.bytes))).monospacedDigit().foregroundStyle(Theme.textMuted)
                        }
                        .swipeActions { deleteAction { confirm = .owner(entry.owner) } }
                        .modifier(confirmation(.owner(entry.owner)))
                    }
                } header: {
                    Text("其他账号")
                } footer: {
                    Text("这台 iPhone 上其他账号的下载，重新登录那个账号就能看。")
                }
            }
            // 容量放最后：这一页先管下载，剩余空间是参考（空间不够时选档面板会直接提示）
            Section {
                StorageUsageBar(downloads: store.totalBytes, free: OfflineDisk.availableBytes, total: OfflineDisk.totalCapacity)
                    .accessibilityIdentifier("offline-storage-summary")
            }
        }
        .navigationTitle("下载")
        .toolbar {
            // 下载设置只有一项：右上角菜单里直接开关（同「文件」「照片」的显示选项），不单占一个分组
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("关闭时只在 Wi-Fi 下下载") {
                        // 菜单里用系统勾选项：继承 App 全局的 SystemSwitchStyle 滑动开关的话，菜单项会变灰、点不动
                        Toggle("使用蜂窝网络下载", systemImage: "antenna.radiowaves.left.and.right", isOn: $allowCellular)
                            .toggleStyle(.automatic)
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("下载设置")
                .accessibilityIdentifier("offline-settings")
            }
        }
        .onChange(of: allowCellular) { _, value in
            OfflineSettings.allowCellular = value
            OfflineDownloader.shared.applyNetworkSettings()
        }
        .task { await loadOtherOwners() }
        .accessibilityIdentifier("offline-storage")
    }

    /// 删除确认挂在触发它的那一行 / 那个按钮上：iOS 26 的确认框以气泡从来源处弹出，挂在整个列表上会浮在页面中间
    private func confirmation(_ target: Confirm) -> ConfirmDelete {
        ConfirmDelete(
            title: title(of: target),
            action: "删除（释放 \(Formatters.bytes(Int(bytes(of: target))))）",
            isPresented: Binding(mcGet: { confirm?.id == target.id }, set: { if !$0, confirm?.id == target.id { confirm = nil } }),
            perform: { perform(target) }
        )
    }

    /// 左滑删除：不用 role: .destructive（那会让系统先把行做删除动画移走，这里还要等确认框），显式染成系统红
    private func deleteAction(_ action: @escaping () -> Void) -> some View {
        Button("删除", systemImage: "trash", action: action).tint(.red)
    }

    private func row(_ item: OfflineItemSummary) -> some View {
        let units = store.units(ofItem: item.mediaItemId)
        let done = units.filter(\.playable)
        let active = units.filter(\.isActive)
        return HStack(spacing: 12) {
            LibraryArtwork(url: api.image(item.posterUrl, width: ImageWidth.points(44)), imageAspect: item.primaryAspect,
                           frameAspect: Theme.posterAspect)
                .frame(width: 44)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(1)
                Text(detailLine(item, done: done, active: active)).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Formatters.bytes(Int(store.bytes(ofItem: item.mediaItemId)))).font(.subheadline).monospacedDigit()
                .foregroundStyle(Theme.textMuted)
        }
        .accessibilityIdentifier("offline-storage-item-\(item.mediaItemId)")
    }

    private func detailLine(_ item: OfflineItemSummary, done: [OfflineUnit], active: [OfflineUnit]) -> String {
        var parts: [String] = []
        if item.kind == "tv" {
            parts.append("已下载 \(done.count) 集")
        } else if let unit = done.first {
            parts.append(unit.profileLabel)
        }
        if !active.isEmpty { parts.append("还有 \(active.count) 个在下载") }
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
        case let .items(ids): ids.count == 1 ? "删除「\(store.items[ids[0]]?.title ?? "")」的下载？" : "删除 \(ids.count) 部的下载？"
        case .watched: "删除 \(watchedUnits.count) 个已看完的下载？"
        case let .owner(owner): "删除「\(owner.username)」在这台 iPhone 上的全部下载？"
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

/// 「下载中」的一行：小剧照（电影用横幅）+ 片名 + 哪一集 · 档位 + 状态与速度 + 进度。
/// 点进条目；左滑 / 长按暂停、继续、取消。下完就从这一组消失
private struct OfflineDownloadingStorageRow: View {
    let unit: OfflineUnit
    let item: OfflineItemSummary
    @State private var store = OfflineStore.shared
    @Environment(\.api) private var api
    /// 早先开始的下载没记剧照：从本机存的这一季里找
    @State private var archivedStill: String?

    var body: some View {
        let still = unit.isMovie ? item.backdropUrl : (unit.stillUrl ?? archivedStill)
        let speed = unit.state == .downloading ? store.speeds[unit.fileId].flatMap { $0 > 0 ? $0 : nil } : nil
        let tint = unit.needsAttention ? Theme.warning : Theme.info
        NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId,
                                                   season: unit.isMovie ? nil : unit.season,
                                                   episode: unit.isMovie ? nil : unit.episode)) {
            HStack(spacing: 12) {
                LibraryArtwork(url: still.flatMap { api.image($0, width: ImageWidth.points(88)) }
                    ?? (unit.isMovie ? api.image(item.posterUrl, width: ImageWidth.points(88)) : nil),
                    imageAspect: still == nil && unit.isMovie ? item.primaryAspect : nil,
                    frameAspect: 16 / 9,
                    fallbackText: still == nil && !unit.isMovie ? "\(unit.episode)" : nil)
                    .frame(width: 88)
                    .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1)
                    Text([unit.isMovie ? nil : "第 \(unit.season) 季第 \(unit.episode) 集", unit.profileLabel]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(OfflineUnitStatus.text(unit)).foregroundStyle(tint).lineLimit(1)
                        if let speed {
                            Text("\(Formatters.bytes(Int(speed)))/s").foregroundStyle(Theme.textMuted)
                        }
                    }
                    .font(.caption).monospacedDigit()
                    ProgressView(value: max(0, min(1, unit.progressFraction))).tint(tint)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions { actions }
        .contextMenu { actions }
        .accessibilityIdentifier("offline-downloading-\(unit.fileId)")
        .task(id: unit.fileId) {
            guard !unit.isMovie, unit.stillUrl == nil,
                  let season = await OfflineStore.shared.season(itemId: unit.mediaItemId, season: unit.season) else { return }
            archivedStill = season.episodes.first { $0.episodeNumber == unit.episode }?.stillUrl
        }
    }

    @ViewBuilder
    private var actions: some View {
        if unit.waitingForTranscode {
            // 排队等服务器转码：到点自己会再去问，只给取消
        } else if unit.state == .paused || unit.state == .failed {
            Button("继续下载", systemImage: "play") { OfflineDownloader.shared.resume(fileId: unit.fileId) }.tint(Theme.info)
        } else {
            Button("暂停", systemImage: "pause") { OfflineDownloader.shared.pause(fileId: unit.fileId) }.tint(.gray)
        }
        Button("取消下载", systemImage: "xmark") { OfflineDownloader.shared.delete(fileId: unit.fileId) }.tint(.red)
    }
}

/// 存储页顶部的容量条（同系统「iPhone 储存空间」）：MovieClaw 下载 / 其他已用 / 剩余
private struct StorageUsageBar: View {
    let downloads: Int64
    let free: Int64?
    let total: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("iPhone").font(.headline)
                Spacer()
                if let total, let free {
                    Text("已用 \(Formatters.bytes(Int(total - free))) / \(Formatters.bytes(Int(total)))")
                        .font(.subheadline).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
            }
            if let total, total > 0, let free {
                let other = max(0, total - free - downloads)
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        Rectangle().fill(Theme.info).frame(width: max(downloads > 0 ? 3 : 0, proxy.size.width * CGFloat(downloads) / CGFloat(total)))
                        Rectangle().fill(.white.opacity(0.35)).frame(width: proxy.size.width * CGFloat(other) / CGFloat(total))
                        Rectangle().fill(.white.opacity(0.08))
                    }
                    .clipShape(.rect(cornerRadius: 4))
                }
                .frame(height: 14)
                HStack(spacing: 14) {
                    legend(Theme.info, "MovieClaw 下载 \(Formatters.bytes(Int(downloads)))")
                    legend(.white.opacity(0.35), "其他")
                    Spacer(minLength: 0)
                    Text("剩余 \(Formatters.bytes(Int(free)))").font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
            } else {
                Text("MovieClaw 下载 \(Formatters.bytes(Int(downloads)))").font(.subheadline).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted)
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
            Text("只删 iPhone 上的副本，观看进度会保留。")
        }
    }
}
