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

/// 剧集下载的一个范围（选中的这一集 / 未看的集 / 全部）：分段选择里一段
struct OfflineDownloadScope: Identifiable {
    let id: String
    /// 分段上的字，如「第 3 集」「未看 8 集」
    let label: String
    let fileIds: [Int]
    /// 打开时默认选中
    var preferred = false
}

/// 选档 sheet：列出这个文件可用的档位、各档预计大小、本机剩余空间；记住上次的选择
/// 下载选档（docs/design/offline-download.md §5）：点一行只是选中（打勾），右上角「下载」才开始——同系统的选择类表单。
/// 一次下多集时先把每一集的下载信息都取回来，每一档显示整批的总大小，空间不够时说明并禁用「下载」。
/// 剧集从右上角菜单进来时顶部多一排范围（§8）：切范围时大小跟着变，取过的下载信息不重取
struct OfflineProfileSheet: View {
    let title: String
    private let loadScopes: () async throws -> [OfflineDownloadScope]

    init(fileId: Int, title: String) {
        self.title = title
        loadScopes = { [OfflineDownloadScope(id: "file", label: title, fileIds: [fileId])] }
    }

    init(title: String, scopes: @escaping () async throws -> [OfflineDownloadScope]) {
        self.title = title
        loadScopes = scopes
    }

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(Feedback.self) private var feedback
    @State private var scopes: [OfflineDownloadScope]?
    @State private var scopeId: String?
    @State private var loaded: [Int: API.OfflineManifestView] = [:]
    /// 取不到下载信息的文件（批量时其余照下）
    @State private var failedIds: Set<Int> = []
    @State private var error: String?
    @State private var startError: String?
    @State private var choice: String?

    private var fileIds: [Int] { scopes?.first { $0.id == scopeId }?.fileIds ?? [] }
    private var batch: Bool { fileIds.count > 1 }
    private var attempted: Bool { fileIds.allSatisfy { loaded[$0] != nil || failedIds.contains($0) } }
    private var missing: Int { fileIds.filter(failedIds.contains).count }

    /// 当前范围的下载信息：每个文件都取过了才算到手
    private var manifests: [API.OfflineManifestView]? {
        guard !fileIds.isEmpty, attempted else { return nil }
        let ordered = fileIds.compactMap { loaded[$0] }
        return ordered.isEmpty ? nil : ordered
    }

    var body: some View {
        NavigationStack {
            Group {
                if let scopes, scopes.isEmpty {
                    ContentUnavailableView("都已下载", systemImage: "checkmark.circle", description: Text("这部剧能下的集都已在 iPhone 上"))
                } else if let scopes {
                    content(scopes)
                } else if let error {
                    ContentUnavailableView("拿不到下载信息", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("正在读取可下载的集").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("下载到 iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") { start() }
                        .fontWeight(.semibold)
                        .disabled(!canStart)
                        .accessibilityIdentifier("offline-profile-confirm")
                }
            }
        }
        .task {
            do {
                let scopes = try await loadScopes()
                scopeId = (scopes.first(where: \.preferred) ?? scopes.first)?.id
                self.scopes = scopes
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: scopeId) { await load(fileIds) }
    }

    @ViewBuilder
    private func content(_ scopes: [OfflineDownloadScope]) -> some View {
        let free = OfflineDisk.availableBytes
        List {
            Section {
                Text(title).font(.headline)
                if scopes.count > 1 {
                    Picker("下载范围", selection: Binding(mcGet: { scopeId ?? "" }, set: { scopeId = $0; startError = nil })) {
                        ForEach(scopes) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("offline-scope")
                }
                if batch {
                    Text(missing > 0 ? "共 \(fileIds.count - missing) 集（另有 \(missing) 集取不到下载信息，会跳过）" : "共 \(fileIds.count) 集")
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                }
                if let free {
                    Text("iPhone 剩余 \(Formatters.bytes(Int(free)))").font(.footnote).foregroundStyle(Theme.textMuted)
                }
            }
            if let manifests, let first = manifests.first {
                profiles(first, manifests, free: free)
            } else if attempted {
                Section { Text(error ?? "拿不到下载信息").foregroundStyle(Theme.warning) }
            } else {
                Section {
                    ProgressView(batch ? "正在计算 \(fileIds.count) 集的大小" : "正在读取可下载的画质")
                        .frame(maxWidth: .infinity)
                }
            }
            if let startError {
                Section { Text(startError).foregroundStyle(Theme.danger) }
            }
        }
    }

    @ViewBuilder
    private func profiles(_ first: API.OfflineManifestView, _ manifests: [API.OfflineManifestView], free: Int64?) -> some View {
        if let reason = first.unavailableReason, !batch {
            Section { Text(reason).foregroundStyle(Theme.warning) }
        } else {
            Section {
                ForEach(first.profiles, id: \.profile) { profile in
                    let total = Self.totalBytes(profile.profile, manifests)
                    Button { choice = profile.profile } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.label).foregroundStyle(Theme.text)
                                Text(profile.profile == "original" ? "原文件，画质最好" : "服务器转码后下载，边转边下")
                                    .font(.caption).foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Text("\(batch ? "共" : "")约 \(Formatters.bytes(Int(total)))").monospacedDigit().foregroundStyle(Theme.textMuted)
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.info)
                                .opacity(profile.profile == selected(first) ? 1 : 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(profile.profile == selected(first) ? .isSelected : [])
                    .accessibilityIdentifier("offline-profile-\(profile.profile)")
                }
            } header: {
                Text("画质")
            } footer: {
                if let free, needed(first, manifests) > free {
                    Text("空间不够：需要约 \(Formatters.bytes(Int(needed(first, manifests))))（含预留 2 GB），iPhone 只剩 \(Formatters.bytes(Int(free)))。换个小一点的画质，或先清理空间。")
                        .foregroundStyle(Theme.danger)
                } else {
                    Text(OfflineSettings.allowCellular ? "会使用蜂窝网络下载。" : "只在 Wi-Fi 下下载；可在「我的 → 下载与存储」里改。")
                }
            }
        }
    }

    private var canStart: Bool {
        guard let manifests, let first = manifests.first else { return false }
        if !batch, first.unavailableReason != nil { return false }
        if let free = OfflineDisk.availableBytes, needed(first, manifests) > free { return false }
        return true
    }

    /// 选中的档位：用户点过的 → 上次用的（这个文件有的话）→ 原画
    private func selected(_ first: API.OfflineManifestView) -> String {
        if let choice { return choice }
        let last = OfflineSettings.lastProfile
        return first.profiles.contains { $0.profile == last } ? last ?? "original" : "original"
    }

    private func needed(_ first: API.OfflineManifestView, _ manifests: [API.OfflineManifestView]) -> Int64 {
        Self.totalBytes(selected(first), manifests) + OfflineSettings.reserveBytes
    }

    /// 整批按这一档的总大小：某一集没有这一档就按它的原画算（开始下载时同样退回原画）
    static func totalBytes(_ profile: String, _ manifests: [API.OfflineManifestView]) -> Int64 {
        manifests.reduce(0) { sum, manifest in
            guard manifest.unavailableReason == nil else { return sum }
            let chosen = manifest.profiles.first { $0.profile == profile } ?? manifest.profiles.first
            return sum + Int64(chosen?.expectedBytes ?? 0)
        }
    }

    /// 取每一集的下载信息：并发 6 个，取过的不重取；批量时取不到的集跳过并计数，全都取不到才报错。
    /// 切范围会取消进行中的请求：被取消的不算取不到
    private func load(_ ids: [Int]) async {
        let pending = ids.filter { loaded[$0] == nil && !failedIds.contains($0) }
        let api = self.api
        for chunk in stride(from: 0, to: pending.count, by: 6).map({ Array(pending[$0 ..< min($0 + 6, pending.count)]) }) {
            var failures: [Int: Error] = [:]
            await withTaskGroup(of: (Int, Result<API.OfflineManifestView, Error>).self) { group in
                for id in chunk {
                    group.addTask {
                        do { return (id, .success(try await api.offlineManifest(fileId: id))) } catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    switch result {
                    case let .success(manifest): loaded[id] = manifest
                    case let .failure(failure): failures[id] = failure
                    }
                }
            }
            if Task.isCancelled { return }
            failedIds.formUnion(failures.keys)
            if let failure = failures.values.first { error = failure.localizedDescription }
        }
    }

    private func start() {
        guard let manifests, let first = manifests.first else { return }
        let profile = selected(first)
        if !batch {
            guard let chosen = first.profiles.first(where: { $0.profile == profile }) else { return }
            do {
                try OfflineDownloader.shared.start(manifest: first, profile: chosen)
                dismiss()
            } catch {
                startError = error.localizedDescription
            }
            return
        }
        var started = 0
        var failures: [String] = []
        for manifest in manifests {
            if let reason = manifest.unavailableReason {
                failures.append(reason)
                continue
            }
            guard let chosen = manifest.profiles.first(where: { $0.profile == profile }) ?? manifest.profiles.first else { continue }
            do {
                try OfflineDownloader.shared.start(manifest: manifest, profile: chosen)
                started += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        let skipped = failures.count + missing
        if started == 0 {
            startError = failures.first ?? "没能开始下载"
            return
        }
        feedback.success(skipped > 0 ? "已开始下载 \(started) 集，\(skipped) 集没能开始" : "已开始下载 \(started) 集")
        dismiss()
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
