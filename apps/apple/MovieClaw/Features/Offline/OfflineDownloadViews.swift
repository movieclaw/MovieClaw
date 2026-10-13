import SwiftUI

// 下载入口与删除入口（docs/design/offline-download.md §5、§8）：详情页的下载按钮（主入口）、选档 sheet、
// 一季批量下载 / 删除。删除一律二次确认，写明释放多少空间、「观看进度会保留」；离线时也能删（只动手机）。

/// 详情页播放键旁的下载按钮：下载 → 进度环（暂停 / 继续 / 取消）→ 已下载 ✓（删除 / 改下其他画质）
struct OfflineDownloadControl: View {
    let detail: API.LibraryItemDetailView
    let season: Int
    let episode: Int
    /// 这个单元能下的文件（在位文件，选中的版本在前）
    let files: [API.LibraryFileView]

    @Environment(\.permissions) private var permissions
    @State private var store = OfflineStore.shared
    @State private var reachability = ServerReachability.shared
    @State private var picking: Int?
    @State private var confirmDelete = false

    var body: some View {
        let unit = store.unit(mediaItemId: detail.mediaItemId, season: season, episode: episode)
        if let unit {
            existing(unit)
        } else if permissions.canDownloadVideo, store.serverSupported, !reachability.isOffline, let file = files.first {
            Button { picking = file.id } label: {
                Label("下载", systemImage: "arrow.down.circle").heroActionLabel()
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .accessibilityIdentifier("item-download")
            .sheet(item: Binding(mcGet: { picking.map(PickTarget.init) }, set: { picking = $0?.id })) { target in
                OfflineProfileSheet(fileId: target.id, title: title)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private struct PickTarget: Identifiable { let id: Int }

    private var title: String {
        detail.kind == "tv" ? "\(detail.title) 第 \(season) 季第 \(episode) 集" : detail.title
    }

    @ViewBuilder
    private func existing(_ unit: OfflineUnit) -> some View {
        let downloader = OfflineDownloader.shared
        Menu {
            switch unit.state {
            case .done:
                Text("\(unit.profileLabel) · \(Formatters.bytes(Int(unit.receivedBytes)))")
                if !reachability.isOffline, permissions.canDownloadVideo, files.contains(where: { $0.id == unit.fileId }) {
                    Button("改下其他画质", systemImage: "arrow.triangle.2.circlepath") { picking = unit.fileId }
                }
            case .preparing, .queued, .downloading:
                Text(OfflineUnitStatus.text(unit))
                if unit.state != .preparing {
                    Button("暂停", systemImage: "pause") { downloader.pause(fileId: unit.fileId) }
                }
            case .paused:
                Button("继续下载", systemImage: "play") { downloader.resume(fileId: unit.fileId) }
            case .failed:
                Text(unit.error ?? "下载失败")
                Button("重试", systemImage: "arrow.clockwise") { downloader.resume(fileId: unit.fileId) }
            }
            Divider()
            Button(unit.state == .done ? "删除下载" : "取消下载", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            label(unit).heroActionLabel()
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .accessibilityIdentifier("item-download")
        .accessibilityValue("\(unit.state.rawValue)|\(unit.profile)")
        .confirmationDialog(unit.state == .done ? "删除这份下载？" : "取消下载？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(unit.state == .done ? "删除下载（\(Formatters.bytes(Int(unit.receivedBytes))))" : "取消下载", role: .destructive) {
                downloader.delete(fileId: unit.fileId)
            }
        } message: {
            Text("只删 iPhone 上的副本，观看进度会保留。")
        }
        .sheet(item: Binding(mcGet: { picking.map(PickTarget.init) }, set: { picking = $0?.id })) { target in
            OfflineProfileSheet(fileId: target.id, title: title)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func label(_ unit: OfflineUnit) -> some View {
        switch unit.state {
        case .done:
            Label("已下载", systemImage: "checkmark.circle.fill")
                .foregroundStyle(unit.damaged ? Theme.warning : Theme.success)
        case .preparing, .queued, .downloading:
            HStack(spacing: 6) {
                ProgressRing(fraction: unit.state == .downloading ? unit.progressFraction : nil)
                    .frame(width: 16, height: 16)
                Text(unit.state == .downloading && unit.expectedBytes > 0 ? "\(Int(unit.progressFraction * 100))%" : "下载中")
                    .monospacedDigit()
            }
        case .paused:
            Label("已暂停", systemImage: "pause.circle")
        case .failed:
            Label("下载失败", systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
        }
    }
}

/// 下载进度环：不知道总量时转圈
struct ProgressRing: View {
    var fraction: Double?

    var body: some View {
        if let fraction {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.02, fraction)).stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// 选档 sheet：列出这个文件可用的档位、各档预计大小、本机剩余空间；记住上次的选择
struct OfflineProfileSheet: View {
    let fileId: Int
    let title: String
    /// 一季批量下：选中档位后交给调用方（不在这里开始下载）
    var onPick: ((API.OfflineProfileView, API.OfflineManifestView) -> Void)?

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: API.OfflineManifestView?
    @State private var error: String?
    @State private var startError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let manifest {
                    content(manifest)
                } else if let error {
                    ContentUnavailableView("拿不到下载信息", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("正在读取可下载的画质…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("下载到 iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .task {
            do {
                manifest = try await api.offlineManifest(fileId: fileId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func content(_ manifest: API.OfflineManifestView) -> some View {
        List {
            Section {
                Text(title).font(.headline)
                if let free = OfflineDisk.availableBytes {
                    Text("iPhone 剩余 \(Formatters.bytes(Int(free)))").font(.footnote).foregroundStyle(Theme.textMuted)
                }
            }
            if let reason = manifest.unavailableReason {
                Section { Text(reason).foregroundStyle(Theme.warning) }
            } else {
                Section {
                    ForEach(manifest.profiles, id: \.profile) { profile in
                        Button { pick(profile, manifest) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.label).foregroundStyle(Theme.text)
                                    Text(profile.profile == "original" ? "原文件，画质最好" : "服务器转码后下载，边转边下")
                                        .font(.caption).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                Text("约 \(Formatters.bytes(profile.expectedBytes))").monospacedDigit().foregroundStyle(Theme.textMuted)
                                if profile.profile == preferred(manifest) {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.info)
                                }
                            }
                        }
                        .accessibilityIdentifier("offline-profile-\(profile.profile)")
                    }
                } header: {
                    Text("画质")
                } footer: {
                    Text(OfflineSettings.allowCellular ? "会使用蜂窝网络下载。" : "只在 Wi-Fi 下下载；可在「我的 → 下载与存储」里改。")
                }
            }
            if let startError {
                Section { Text(startError).foregroundStyle(Theme.danger) }
            }
        }
    }

    /// 默认选中上次用的档位（这个文件有的话），否则原画
    private func preferred(_ manifest: API.OfflineManifestView) -> String {
        let last = OfflineSettings.lastProfile
        return manifest.profiles.contains { $0.profile == last } ? last ?? "original" : "original"
    }

    private func pick(_ profile: API.OfflineProfileView, _ manifest: API.OfflineManifestView) {
        if let onPick {
            onPick(profile, manifest)
            dismiss()
            return
        }
        do {
            try OfflineDownloader.shared.start(manifest: manifest, profile: profile)
            dismiss()
        } catch {
            startError = error.localizedDescription
        }
    }
}

/// 一季批量下载：先用第一集的清单选档，其余集按同一档（某集没有这一档就用原画）
@MainActor
enum OfflineSeasonDownload {
    static func start(fileIds: [Int], profile: String, first: API.OfflineManifestView, api: APIClient, feedback: Feedback) {
        Task {
            var started = 0
            var failures: [String] = []
            for fileId in fileIds {
                do {
                    let manifest = fileId == first.fileId ? first : try await api.offlineManifest(fileId: fileId)
                    guard let chosen = manifest.profiles.first(where: { $0.profile == profile }) ?? manifest.profiles.first else { continue }
                    try OfflineDownloader.shared.start(manifest: manifest, profile: chosen)
                    started += 1
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            if let failure = failures.first {
                feedback.error(started > 0 ? "已开始下载 \(started) 集，\(failures.count) 集没能开始：\(failure)" : failure)
            } else {
                feedback.success("已开始下载 \(started) 集")
            }
        }
    }
}

/// 退出登录时问一句要不要连本机下载一起删（docs/design/offline-download.md §8、§9）：
/// 不问就留着——同一账号重新登录就回来；令牌被吊销（别处改了密码）时不自动删
@MainActor
enum OfflineDownloadCleanup {
    static func askOnLogout(feedback: Feedback) async {
        let store = OfflineStore.shared
        guard let owner = store.owner, !store.items.isEmpty else { return }
        let count = store.items.count
        let size = Formatters.bytes(Int(store.totalBytes))
        guard await feedback.confirm("同时删除本机下载的 \(count) 部（\(size)）？",
                                     message: "不删的话，下次登录这个账号还能接着看。",
                                     confirmTitle: "删除下载", cancelTitle: "保留", destructive: true) else { return }
        for item in store.items.keys { OfflineDownloader.shared.deleteItem(item) }
        OfflineOwners.remove(owner)
    }

    static func askOnLogoutEverywhere(feedback: Feedback) async {
        let owners = await Task.detached { OfflineOwners.scan() }.value
        guard !owners.isEmpty else { return }
        guard await feedback.confirm("同时删除这台 iPhone 上的全部下载？",
                                     message: "共用设备交还前建议删除。不删的话，重新登录对应账号还能接着看。",
                                     confirmTitle: "全部删除", cancelTitle: "保留", destructive: true) else { return }
        for item in OfflineStore.shared.items.keys { OfflineDownloader.shared.deleteItem(item) }
        for owner in owners { OfflineOwners.remove(owner) }
    }
}

/// 海报卡长按菜单里的「删除下载」（已下载的条目才有；只进菜单，不加可见控件）
struct OfflineDeleteMenuButton: View {
    let itemId: Int
    let title: String
    @Environment(Feedback.self) private var feedback

    var body: some View {
        let store = OfflineStore.shared
        if store.downloadedItemIds.contains(itemId) || !store.units(ofItem: itemId).isEmpty {
            Button("删除下载", systemImage: "trash", role: .destructive) {
                Task {
                    let size = Formatters.bytes(Int(store.bytes(ofItem: itemId)))
                    guard await feedback.confirm("删除「\(title)」的下载？", message: "释放 \(size)，只删 iPhone 上的副本，观看进度会保留。",
                                                 confirmTitle: "删除下载", destructive: true) else { return }
                    OfflineDownloader.shared.deleteItem(itemId)
                }
            }
        }
    }
}
