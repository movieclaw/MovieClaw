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
            .navigationTitle("下载")
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
                    ForEach(active) { unit in
                        if let item = store.items[unit.mediaItemId] {
                            OfflineDownloadingStorageRow(unit: unit, item: item)
                        }
                    }
                } header: {
                    // 标识只挂在标题上：挂在 Section 上会盖掉每一行自己的标识
                    Text("下载中").font(.headline).foregroundStyle(Theme.text)
                        .accessibilityIdentifier("offline-storage-downloading")
                }
            }
            if !watched.isEmpty {
                Section("建议") {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("删除已看完的").font(.body.weight(.medium))
                            Text("\(watched.count) 个已看完，占用 \(Formatters.bytes(Int(watched.reduce(0) { $0 + $1.receivedBytes })))")
                                .font(.footnote).foregroundStyle(Theme.textMuted)
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
            Section {
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
            } header: {
                HStack(spacing: 8) {
                    Text("已下载").font(.headline).foregroundStyle(Theme.text)
                    if !items.isEmpty {
                        Text("\(items.count) 部").font(.subheadline).foregroundStyle(Theme.textMuted)
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

/// 独立下载页用工具栏，内嵌下载列表用分区标题；共享同一个本机设置菜单。
private struct OfflineStorageSettingsMenu: View {
    @State private var allowCellular = OfflineSettings.allowCellular

    var body: some View {
        Menu {
            Section("关闭时只在 Wi-Fi 下下载") {
                Toggle("使用蜂窝网络下载", systemImage: "antenna.radiowaves.left.and.right", isOn: $allowCellular)
                    .toggleStyle(.automatic)
            }
        } label: {
            Image(systemName: "gearshape")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("下载设置")
        .accessibilityIdentifier("offline-settings")
        .onChange(of: allowCellular) { _, value in
            OfflineSettings.allowCellular = value
            OfflineDownloader.shared.applyNetworkSettings()
        }
    }
}

/// 「下载中」的一行：海报 + 片名 + 哪一集 · 档位 + 状态与速度 + 进度。
/// 点进条目；左滑 / 长按暂停、继续、取消。下完就从这一组消失
private struct OfflineDownloadingStorageRow: View {
    let unit: OfflineUnit
    let item: OfflineItemSummary
    @State private var store = OfflineStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let speed = unit.state == .downloading ? store.speeds[unit.fileId].flatMap { $0 > 0 ? $0 : nil } : nil
        let tint = unit.needsAttention ? Theme.warning : Theme.info
        NavigationLink(value: AppRoute.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId,
                                                   season: unit.isMovie ? nil : unit.season,
                                                   episode: unit.isMovie ? nil : unit.episode)) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 16))
            layout {
                OfflineStoragePoster(item: item)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([unit.isMovie ? nil : "第 \(unit.season) 季第 \(unit.episode) 集", unit.profileLabel]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(OfflineUnitStatus.text(unit)).foregroundStyle(tint)
                        if let speed {
                            Text("\(Formatters.bytes(Int(speed)))/s").foregroundStyle(Theme.textMuted)
                        }
                    }
                    .font(.footnote).monospacedDigit()
                    ProgressView(value: max(0, min(1, unit.progressFraction))).tint(tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .swipeActions { actions }
        .contextMenu { actions }
        .accessibilityIdentifier("offline-downloading-\(unit.fileId)")
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
                Text("本机储存空间").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if let free {
                    Text("可用 \(Formatters.bytes(Int(free)))")
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
                    legend(Theme.info, "下载 \(Formatters.bytes(Int(downloads)))")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    legend(.white.opacity(0.25), "其他已用")
                }
            } else {
                Text("MovieClaw 下载 \(Formatters.bytes(Int(downloads)))").font(.subheadline).monospacedDigit()
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
            Text("只删 iPhone 上的副本，观看进度会保留。")
        }
    }
}
