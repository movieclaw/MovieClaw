import SwiftUI

/// 我的 → 下载与存储（docs/design/offline-download.md §8）：本机副本占了多少、还剩多少，按条目列出，
/// 左滑删除、编辑多选删除、「删除已看完的」一键清理；别的账号在这台 iPhone 上的下载也能删；下载设置。
struct OfflineStorageView: View {
    @State private var store = OfflineStore.shared
    @Environment(\.api) private var api
    @Environment(AppModel.self) private var model
    @State private var otherOwners: [(owner: OfflineOwner, bytes: Int64, items: Int)] = []
    @State private var allowCellular = OfflineSettings.allowCellular
    @State private var confirm: Confirm?
    @State private var selection: Set<Int> = []
    @Environment(\.editMode) private var editMode

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
        let items = store.items.values.sorted { $0.addedAt > $1.addedAt }
        List(selection: $selection) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已用 \(Formatters.bytes(Int(store.totalBytes)))")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                    if let free = OfflineDisk.availableBytes {
                        Text("iPhone 剩余 \(Formatters.bytes(Int(free)))").font(.footnote).foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("offline-storage-summary")
            }
            if items.isEmpty {
                Section {
                    Text("还没有下载。在影片详情页点「下载」，没网的时候也能看。")
                        .font(.subheadline).foregroundStyle(Theme.textMuted)
                }
            } else {
                Section("已下载") {
                    ForEach(items) { item in
                        row(item).tag(item.mediaItemId)
                            .swipeActions {
                                Button("删除", role: .destructive) { confirm = .items([item.mediaItemId]) }
                            }
                    }
                }
                Section {
                    Button("删除已看完的", role: .destructive) { confirm = .watched }
                        .disabled(watchedUnits.isEmpty)
                        .accessibilityIdentifier("offline-delete-watched")
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
                        .swipeActions {
                            Button("删除", role: .destructive) { confirm = .owner(entry.owner) }
                        }
                    }
                } header: {
                    Text("其他账号")
                } footer: {
                    Text("这台 iPhone 上其他账号的下载，重新登录那个账号就能看。")
                }
            }
            Section {
                Toggle("使用蜂窝网络下载", isOn: $allowCellular)
                    .onChange(of: allowCellular) { _, value in
                        OfflineSettings.allowCellular = value
                        OfflineDownloader.shared.applyNetworkSettings()
                    }
            } footer: {
                Text("关闭时只在 Wi-Fi 下下载。")
            }
        }
        .navigationTitle("下载与存储")
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                if editMode?.wrappedValue.isEditing == true, !selection.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("删除所选（\(selection.count)）", role: .destructive) { confirm = .items(Array(selection)) }
                    }
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(mcGet: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { target in
            Button("删除（释放 \(Formatters.bytes(Int(bytes(of: target)))))", role: .destructive) { perform(target) }
        } message: { _ in
            Text("只删 iPhone 上的副本，观看进度会保留。")
        }
        .task { await loadOtherOwners() }
        .accessibilityIdentifier("offline-storage")
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
        if let first = active.first { parts.append(active.count > 1 ? "\(active.count) 个进行中" : OfflineUnitStatus.text(first)) }
        return parts.joined(separator: " · ")
    }

    /// 看完了的本机单元（本机进度标了已看）
    private var watchedUnits: [OfflineUnit] {
        store.units.values.filter { unit in
            unit.playable && store.localProgress(itemId: unit.mediaItemId, season: unit.season, episode: unit.episode)?.played == true
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case let .items(ids)?: ids.count == 1 ? "删除「\(store.items[ids[0]]?.title ?? "")」的下载？" : "删除 \(ids.count) 部的下载？"
        case .watched?: "删除 \(watchedUnits.count) 个已看完的下载？"
        case let .owner(owner)?: "删除「\(owner.username)」在这台 iPhone 上的全部下载？"
        case nil: ""
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
            selection = []
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
