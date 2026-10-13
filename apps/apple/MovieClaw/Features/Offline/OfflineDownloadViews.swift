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

    /// 只在本机有副本（下载中 / 暂停 / 失败 / 已下载）时出现；开始下载在右上角「⋯」
    var body: some View {
        if let unit = store.unit(mediaItemId: detail.mediaItemId, season: season, episode: episode) {
            existing(unit)
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
            // 只有操作：状态、进度、速度都在这条上
            switch unit.state {
            case .done:
                if !reachability.isOffline, permissions.canDownloadVideo, files.contains(where: { $0.id == unit.fileId }) {
                    Button("改下其他画质", systemImage: "arrow.triangle.2.circlepath") { picking = unit.fileId }
                }
            case .preparing, .queued, .downloading:
                if unit.state != .preparing {
                    Button("暂停", systemImage: "pause") { downloader.pause(fileId: unit.fileId) }
                }
            case .paused:
                Button("继续下载", systemImage: "play") { downloader.resume(fileId: unit.fileId) }
            case .failed:
                Button("重试", systemImage: "arrow.clockwise") { downloader.resume(fileId: unit.fileId) }
            }
            Button(unit.state == .done ? "删除下载" : "取消下载", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            OfflineDownloadStatusBar(unit: unit)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("item-download")
        .accessibilityValue("\(unit.state.rawValue)|\(unit.profile)")
        .confirmationDialog(unit.state == .done ? "删除这份下载？" : "取消下载？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(unit.state == .done ? "删除下载（\(Formatters.bytes(Int(unit.receivedBytes)))）" : "取消下载", role: .destructive) {
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
}

/// 电影详情页播放键下方的下载状态条（与分集卡上的 `OfflineDownloadStrip` 同一套样子）：
/// 下载中蓝字「下载中 47%」+ 右侧实时速度 + 底边进度；下完一行「已下载 · 原画 · 1.4 GB」，绿箭头
struct OfflineDownloadStatusBar: View {
    let unit: OfflineUnit
    @State private var store = OfflineStore.shared

    var body: some View {
        let done = unit.playable
        let warning = unit.state == .failed || unit.damaged
        let tint = warning ? Theme.warning : done ? Theme.textMuted : Theme.info
        let speed = unit.state == .downloading ? store.speeds[unit.fileId].flatMap { $0 > 0 ? $0 : nil } : nil
        let text = done
            ? "已下载 · \(unit.profileLabel) · \(Formatters.bytes(Int(unit.receivedBytes)))"
            : unit.state == .failed ? "\(OfflineDownloadStrip.status(unit))，点按重试" : OfflineDownloadStrip.status(unit)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                icon(done: done, tint: tint)
                Text(text).lineLimit(1)
                Spacer(minLength: 6)
                if let speed {
                    Text("\(Formatters.bytes(Int(speed)))/s").foregroundStyle(tint.opacity(0.8))
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
            }
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 36)
            if !done {
                GeometryReader { proxy in
                    Rectangle().fill(tint).frame(width: proxy.size.width * max(0, min(1, unit.progressFraction)))
                }
                .frame(height: 2)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(done ? Color.white.opacity(0.08) : tint.opacity(0.5), lineWidth: 1))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speed.map { "\(text)，\(Formatters.bytes(Int($0)))/s" } ?? text)
    }

    @ViewBuilder
    private func icon(done: Bool, tint: Color) -> some View {
        if done {
            Image(systemName: unit.damaged ? "exclamationmark.circle.fill" : "arrow.down").fontWeight(.heavy)
                .foregroundStyle(unit.damaged ? Theme.warning : Theme.success)
        } else {
            switch unit.state {
            case .paused: Image(systemName: "pause.circle.fill")
            case .failed: Image(systemName: "exclamationmark.circle.fill")
            default: ProgressView().controlSize(.mini).tint(tint)
            }
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
    /// 分段上的字，如「第 3 集」「接下来 5 集」「未看 8 集」「剩余 40 集」
    let label: String
    let fileIds: [Int]
    /// 范围下方的说明：「第 4～8 集，共 5 集」
    var detail: String?
    /// 打开时默认选中
    var preferred = false
}

/// 剧集右上角「下载」的可选范围，加一句为什么有些集不在里面（「第 3 集已下载 · 已下载 3 集，不会重复下载」）
struct OfflineDownloadChoices {
    var scopes: [OfflineDownloadScope]
    var note: String?

    /// 一集在库的集与它在本机的状态
    struct Episode {
        enum Local { case done, active }
        let season: Int
        let episode: Int
        let file: Int?
        let played: Bool
        let local: Local?
    }

    /// 范围规则（docs/design/offline-download.md §8）。候选 = 有文件、手机上还没有的集（下完的、在下的都不算）：
    /// - 选中的集没下过：「第 N 集」；选中的集已下 / 在下：换成「接下来 5 集」（它之后还没下的 5 集，追剧边看边下）
    /// - 「未看 N 集」：有没看的、且比剩余的少时才有，有它就默认选它
    /// - 「全部 N 集」（这部剧一集都没下过）/「剩余 N 集」（下过一些）
    /// 内容相同的范围只留一个；只剩一个时面板不显示分段。`episodes` 按季、集排好序
    static func make(
        episodes: [Episode], selected: (season: Int, episode: Int)?, selectedFile: Int?, multiSeason: Bool, nextCount: Int = 5
    ) -> OfflineDownloadChoices {
        func name(_ season: Int, _ episode: Int) -> String { multiSeason ? "第 \(season) 季第 \(episode) 集" : "第 \(episode) 集" }
        /// 范围下方的说明：哪几集、共几集
        func describe(_ list: [Episode]) -> String {
            guard let first = list.first, let last = list.last else { return "" }
            if list.count == 1 { return name(first.season, first.episode) }
            if first.season == last.season, last.episode - first.episode + 1 == list.count {
                return "\(multiSeason ? "第 \(first.season) 季" : "")第 \(first.episode)～\(last.episode) 集，共 \(list.count) 集"
            }
            return "\(name(first.season, first.episode)) 起，共 \(list.count) 集"
        }
        let candidates = episodes.filter { $0.file != nil && $0.local == nil }
        let done = episodes.filter { $0.local == .done }.count, active = episodes.filter { $0.local == .active }.count
        var scopes: [OfflineDownloadScope] = []
        var notes: [String] = []
        if let selected, let index = episodes.firstIndex(where: { $0.season == selected.season && $0.episode == selected.episode }) {
            let current = episodes[index]
            if let local = current.local {
                notes.append("\(name(current.season, current.episode))\(local == .done ? "已下载" : "正在下载")")
                let next = Array(episodes[(index + 1)...].filter { $0.file != nil && $0.local == nil }.prefix(nextCount))
                if !next.isEmpty, next.count < candidates.count {  // 正好是剩下的全部：只留「剩余」
                    scopes.append(.init(id: "next", label: "接下来 \(next.count) 集", fileIds: next.compactMap(\.file), detail: describe(next)))
                }
            } else if let file = selectedFile ?? current.file {
                scopes.append(.init(id: "selected", label: name(current.season, current.episode), fileIds: [file],
                                    detail: name(current.season, current.episode)))
            }
        }
        if done + active > 0 {
            let parts = [done > 0 ? "已下载 \(done) 集" : nil, active > 0 ? "正在下载 \(active) 集" : nil].compactMap { $0 }
            notes.append(parts.joined(separator: "、") + "，不会重复下载")
        }
        let unwatched = candidates.filter { !$0.played }
        if !unwatched.isEmpty, unwatched.count < candidates.count {
            scopes.append(.init(id: "unwatched", label: "未看 \(unwatched.count) 集", fileIds: unwatched.compactMap(\.file),
                                detail: describe(unwatched), preferred: true))
        }
        if !candidates.isEmpty {
            let label = done + active == 0 ? "全部 \(candidates.count) 集" : "剩余 \(candidates.count) 集"
            scopes.append(.init(id: "all", label: label, fileIds: candidates.compactMap(\.file), detail: describe(candidates)))
        }
        // 内容相同的只留前一个（比如只剩选中的这一集）
        var seen: Set<[Int]> = []
        scopes = scopes.filter { seen.insert($0.fileIds).inserted }
        // 默认：有「未看」选未看；否则「接下来」；剩下的都没看过时选全部 / 剩余；都不是就第一个
        if !scopes.contains(where: \.preferred) {
            let fallback = scopes.firstIndex { $0.id == "next" }
                ?? (unwatched.count == candidates.count ? scopes.firstIndex { $0.id == "all" } : nil)
            if let fallback { scopes[fallback].preferred = true }
        }
        return OfflineDownloadChoices(scopes: scopes, note: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }
}

/// 下载选档（docs/design/offline-download.md §5）：点一行只是选中（打勾），右上角「下载」才开始——同系统的选择类表单。
/// 每一档显示整批的总大小，空间不够时说明并禁用「下载」。剧集从右上角菜单进来时顶部多一排范围（§8）。
///
/// 大小来自批量接口 `POST /offline/profiles`：打开时把所有范围的文件一次问完，切范围只是换个算法，不再发请求。
/// （逐集取完整清单时，43 集要十几秒：每份清单带整部剧详情与整季分集，服务端串行 0.3 秒一份。）
/// 点「下载」才取第一集的完整清单（存条目的展示数据），其余集先建「准备中」单元，由下载器逐集取清单。
/// 旧服务器没有批量接口：退回逐集取清单
struct OfflineProfileSheet: View {
    let title: String
    private let loadChoices: () async throws -> OfflineDownloadChoices
    /// 剧集按范围下（有「下载范围」分组）；单个文件（电影、分集长按）没有
    private let ranged: Bool

    init(fileId: Int, title: String) {
        self.title = title
        ranged = false
        loadChoices = { OfflineDownloadChoices(scopes: [OfflineDownloadScope(id: "file", label: title, fileIds: [fileId])]) }
    }

    init(title: String, choices: @escaping () async throws -> OfflineDownloadChoices) {
        self.title = title
        ranged = true
        loadChoices = choices
    }

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(Feedback.self) private var feedback
    @State private var scopes: [OfflineDownloadScope]?
    @State private var note: String?
    @State private var scopeId: String?
    /// 每个文件的可选档位（批量接口；旧服务器由逐集清单换算）
    @State private var entries: [Int: API.OfflineFileProfilesView] = [:]
    /// 已经问过的文件（问过却不在 `entries` 里 = 看不到 / 取不到，会跳过）
    @State private var asked: Set<Int> = []
    /// 旧服务器逐集取到的完整清单（开始下载时直接用）
    @State private var manifests: [Int: API.OfflineManifestView] = [:]
    @State private var legacy = false
    @State private var error: String?
    @State private var startError: String?
    @State private var choice: String?
    @State private var starting = false

    private var fileIds: [Int] { scopes?.first { $0.id == scopeId }?.fileIds ?? [] }
    private var batch: Bool { fileIds.count > 1 }
    private var ready: Bool { !fileIds.isEmpty && fileIds.allSatisfy(asked.contains) }
    private var missing: Int { fileIds.filter { entries[$0] == nil }.count }
    /// 当前范围里取到了的文件（按集的顺序）
    private var current: [API.OfflineFileProfilesView] { fileIds.compactMap { entries[$0] } }

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
                    if starting {
                        ProgressView()
                    } else {
                        Button("下载") { Task { await start() } }
                            .fontWeight(.semibold)
                            .disabled(!canStart)
                            .accessibilityIdentifier("offline-profile-confirm")
                    }
                }
            }
        }
        .task {
            do {
                let choices = try await loadChoices()
                let scopes = choices.scopes
                note = choices.note
                scopeId = (scopes.first(where: \.preferred) ?? scopes.first)?.id
                self.scopes = scopes
                // 所有范围的文件一次问完：切范围不再发请求
                var all: [Int] = []
                for scope in scopes { for id in scope.fileIds where !all.contains(id) { all.append(id) } }
                await loadProfiles(all)
            } catch {
                self.error = error.localizedDescription
            }
        }
        // 只有旧服务器才按范围逐集取清单。闭包捕获的是这一次的范围：首次渲染时为空直接返回，
        // 范围定下来后才真正去取（不捕获的话首次那趟会读到刚设好的范围、马上又被取消重发）
        .task(id: "\(scopeId ?? "")|\(legacy)") { [scopeId, legacy] in
            guard legacy, let scopeId, let ids = scopes?.first(where: { $0.id == scopeId })?.fileIds else { return }
            await loadManifests(ids)
        }
    }

    @ViewBuilder
    private func content(_ scopes: [OfflineDownloadScope]) -> some View {
        let free = OfflineDisk.availableBytes
        let scope = scopes.first { $0.id == scopeId }
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(Theme.textMuted)
                            .accessibilityIdentifier("offline-download-note")
                    }
                }
                .padding(.vertical, 2)
            }
            if ranged, let scope {
                Section("下载范围") {
                    if scopes.count > 1 {
                        Picker("下载范围", selection: Binding(mcGet: { scopeId ?? "" }, set: { scopeId = $0; startError = nil })) {
                            ForEach(scopes) { Text($0.label).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("offline-scope")
                    } else {
                        Text(scope.label).accessibilityIdentifier("offline-scope-only")
                    }
                    if let detail = scope.detail {
                        let skipped = ready && missing > 0 ? "（其中 \(missing) 集取不到下载信息，会跳过）" : ""
                        Text(detail + skipped).font(.footnote).foregroundStyle(Theme.textMuted).monospacedDigit()
                            .accessibilityIdentifier("offline-scope-detail")
                    }
                }
            }
            if ready, let first = current.first {
                profiles(first, current, free: free)
            } else if ready {
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
    private func profiles(_ first: API.OfflineFileProfilesView, _ files: [API.OfflineFileProfilesView], free: Int64?) -> some View {
        if let reason = first.unavailableReason, !batch {
            Section { Text(reason).foregroundStyle(Theme.warning) }
        } else {
            Section {
                ForEach(first.profiles ?? [], id: \.profile) { profile in
                    let total = Self.totalBytes(profile.profile, files)
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
                if let free, needed(first, files) > free {
                    Text("空间不够：需要约 \(Formatters.bytes(Int(needed(first, files))))（含预留 2 GB），iPhone 只剩 \(Formatters.bytes(Int(free)))。换个小一点的画质，或先清理空间。")
                        .foregroundStyle(Theme.danger)
                } else {
                    let network = OfflineSettings.allowCellular ? "会使用蜂窝网络下载" : "只在 Wi-Fi 下下载，可在「我的 → 下载与存储」里改"
                    Text(free.map { "iPhone 剩余 \(Formatters.bytes(Int($0))) · \(network)" } ?? network)
                }
            }
        }
    }

    private var canStart: Bool {
        guard ready, let first = current.first, !starting else { return false }
        if !batch, first.unavailableReason != nil { return false }
        if let free = OfflineDisk.availableBytes, needed(first, current) > free { return false }
        return true
    }

    /// 选中的档位：用户点过的 → 上次用的（这个文件有的话）→ 原画
    private func selected(_ first: API.OfflineFileProfilesView) -> String {
        if let choice { return choice }
        let last = OfflineSettings.lastProfile
        return (first.profiles ?? []).contains { $0.profile == last } ? last ?? "original" : "original"
    }

    private func needed(_ first: API.OfflineFileProfilesView, _ files: [API.OfflineFileProfilesView]) -> Int64 {
        Self.totalBytes(selected(first), files) + OfflineSettings.reserveBytes
    }

    /// 某一集按这一档的档位：没有这一档就用它的原画（开始下载时同样退回）
    private static func pick(_ profile: String, in entry: API.OfflineFileProfilesView) -> API.OfflineProfileView? {
        let options = entry.profiles ?? []
        return options.first { $0.profile == profile } ?? options.first
    }

    /// 整批按这一档的总大小
    static func totalBytes(_ profile: String, _ files: [API.OfflineFileProfilesView]) -> Int64 {
        files.reduce(0) { sum, entry in
            guard entry.unavailableReason == nil else { return sum }
            return sum + Int64(pick(profile, in: entry)?.expectedBytes ?? 0)
        }
    }

    /// 一次问完一批文件的档位（每次最多 500 个）。旧服务器（没有这个接口）改走逐集清单
    private func loadProfiles(_ ids: [Int]) async {
        do {
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0 ..< min($0 + 500, ids.count)]) }) {
                let result = try await api.offlineProfiles(body: .init(fileIds: chunk))
                for entry in result.files ?? [] { entries[entry.fileId] = entry }
                asked.formUnion(chunk)
            }
        } catch let failure as APIError where failure.status == 404 || failure.status == 405 {
            legacy = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            asked.formUnion(ids)
        }
    }

    /// 旧服务器：逐集取完整清单（并发 6 个，取过的不重取），换算成档位
    private func loadManifests(_ ids: [Int]) async {
        let pending = ids.filter { !asked.contains($0) }
        let api = self.api
        for chunk in stride(from: 0, to: pending.count, by: 6).map({ Array(pending[$0 ..< min($0 + 6, pending.count)]) }) {
            await withTaskGroup(of: (Int, Result<API.OfflineManifestView, Error>).self) { group in
                for id in chunk {
                    group.addTask {
                        do { return (id, .success(try await api.offlineManifest(fileId: id))) } catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    switch result {
                    case let .success(manifest):
                        manifests[id] = manifest
                        entries[id] = API.OfflineFileProfilesView(
                            fileId: manifest.fileId, mediaItemId: manifest.mediaItemId, seasonNumber: manifest.seasonNumber,
                            episodeNumber: manifest.episodeNumber, container: manifest.container,
                            profiles: manifest.profiles, unavailableReason: manifest.unavailableReason
                        )
                    case let .failure(failure):
                        error = failure.localizedDescription
                    }
                }
            }
            // 切范围取消的不算取不到：下次切回来再取
            if Task.isCancelled { return }
            asked.formUnion(chunk)
        }
    }

    /// 第一集取完整清单开始下载（顺带存条目的展示数据），其余集先建「准备中」单元
    private func start() async {
        guard let first = current.first else { return }
        let profile = selected(first)
        let files = current.filter { $0.unavailableReason == nil }
        guard let lead = files.first else {
            startError = first.unavailableReason ?? "没能开始下载"
            return
        }
        starting = true
        defer { starting = false }
        let manifest: API.OfflineManifestView
        do {
            if let known = manifests[lead.fileId] {
                manifest = known
            } else {
                manifest = try await api.offlineManifest(fileId: lead.fileId)
            }
        } catch {
            startError = error.localizedDescription
            return
        }
        guard let leadProfile = manifest.profiles.first(where: { $0.profile == profile }) ?? manifest.profiles.first else {
            startError = manifest.unavailableReason ?? "没能开始下载"
            return
        }
        do {
            try OfflineDownloader.shared.start(manifest: manifest, profile: leadProfile)
        } catch {
            startError = error.localizedDescription
            return
        }
        if !batch {
            dismiss()
            return
        }
        var started = 1
        var failures: [String] = []
        for entry in files.dropFirst() {
            guard let chosen = Self.pick(profile, in: entry) else { continue }
            do {
                if let full = manifests[entry.fileId] {
                    try OfflineDownloader.shared.start(manifest: full, profile: full.profiles.first { $0.profile == chosen.profile } ?? chosen)
                } else {
                    try OfflineDownloader.shared.enqueue(entry, profile: chosen)
                }
                started += 1
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        let skipped = failures.count + missing + (current.count - files.count)
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

