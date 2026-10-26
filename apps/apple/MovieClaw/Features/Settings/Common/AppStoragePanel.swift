import SwiftUI

/// 更新与维护 →「缓存管理」（Web app-storage-section.tsx）。
///
/// 这一页是后端登记表（services/storage/registry.py）的视图：每个 data/ 目录的名称、一句话用途、完整说明、
/// 占用、能否清理都由后端给出，前端只负责分组渲染与确认交互——业务新增一种缓存不需要改这里。
///
/// 打开页面**不会**触发实时统计（遍历 data/ 在大库上要几十秒）：后端给「上一次的快照 + 是否正在重算」，
/// 页面秒开并标出「统计于 N 分钟前」；点「刷新」才重算，统计期间每 2 秒轮询，旧数据留在页面上直到新快照落地。
/// 点目录行打开详情抽屉，清理动作与用途、占用放在一起，二次确认，重建代价高的目录用红色确认键加重提醒。
struct AppStoragePanel: View {
    @Environment(\.api) private var api

    @State private var usage: API.StorageUsageView?
    @State private var computing = false
    @State private var error: String?
    @State private var busyKey: String?
    @State private var notice: (key: String, text: String, ok: Bool)?
    @State private var loaded = false
    @State private var selectedKey: String?

    var body: some View {
        List {
            overviewSection
            if let usage, !usage.unregistered.isEmpty {
                SettingsFormSection(String(localized: .settingsStorageUiUnregistered)) {
                    Text(String(localized: .settingsStorageUiUnregisteredHint))
                        .font(.subheadline).foregroundStyle(Theme.warning)
                    ForEach(usage.unregistered, id: \.path) { entry in
                        HStack {
                            Text(relative(entry.path, usage.dataRoot)).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Formatters.bytes(entry.bytes)).font(.footnote).monospacedDigit()
                        }
                        .foregroundStyle(Theme.warning.opacity(0.8))
                    }
                }
            }
            dirSection(
                title: String(localized: .settingsStorageUiCaches), group: "cache",
                trailing: usage.map { String(localized: .settingsStorageUiTotal(Formatters.bytes($0.cacheBytes))) }
            )
            dirSection(
                title: String(localized: .settingsStorageUiData), group: "data",
                trailing: usage.map { String(localized: .settingsStorageUiDataTotal(Formatters.bytes($0.dataBytes))) }
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: .settingsStorageRefreshUsage), systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }
                    .disabled(computing).accessibilityIdentifier("storage-refresh")
            }
        }
        .sheet(isPresented: Binding(get: { selectedKey != nil }, set: { if !$0 { selectedKey = nil } })) {
            if let dir = usage?.dirs.first(where: { $0.key == selectedKey }) {
                StorageDirectorySheet(dir: dir, busy: busyKey != nil,
                    notice: notice.flatMap { $0.key == dir.key ? ($0.text, $0.ok) : nil }) { mode in
                    await clean(dir, mode: mode)
                }
                .sheetFeedback()
            }
        }
        .task { await load(refresh: false) }
        .polling(every: 2) { if computing { await load(refresh: false) } }
    }

    /// 读一次状态：拿到新快照才替换页面数据，没算完就只更新「统计中」标记
    private func load(refresh: Bool) async {
        do {
            let state = try await api.appStorageUsage(refresh: refresh ? true : nil)
            if let next = state.usage { usage = next }
            computing = state.computing
            error = state.error
        } catch is CancellationError {
        } catch {
            computing = false
            self.error = error.localizedDescription
        }
        loaded = true
    }

    // MARK: 磁盘概览

    private var statusText: String {
        if let usage {
            let time = Formatters.relative(Date(timeIntervalSince1970: TimeInterval(usage.computedAt)).ISO8601Format())
            return computing ? String(localized: .settingsStorageComputedUpdating(time)) : String(localized: .settingsStorageComputedAt(time))
        }
        return computing ? String(localized: .settingsStorageUiFirstComputing) : String(localized: .settingsStorageUiNotComputed)
    }

    private var overviewSection: some View {
        let total = usage?.diskTotal ?? 0
        let cache = usage?.cacheBytes ?? 0
        let data = usage?.dataBytes ?? 0
        let free = usage?.diskFree ?? 0
        // data/ 之外的其它占用（系统、其它应用）= 已用 − 本应用数据 − 缓存，负数按 0
        let other = max(0, (usage?.diskUsed ?? 0) - cache - data)
        let segments: [(label: String, value: Int, color: Color)] = [
            (String(localized: .settingsStorageUiData), data, Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.85)),
            (String(localized: .settingsStorageUiReclaimable), cache, Color(red: 0.98, green: 0.75, blue: 0.14).opacity(0.85)),
            (String(localized: .settingsStorageUiOther), other, Color.white.opacity(0.2)),
            (String(localized: .settingsStorageUiFree), free, Color.white.opacity(0.07)),
        ]
        return SettingsFormSection {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: .settingsStorageUiDisk)).font(.subheadline.weight(.medium))
                        Text(usage?.dataRoot ?? "…").font(.caption.monospaced()).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(usage.map { _ in Formatters.bytes(free) } ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
                        Text(String(localized: .settingsStorageUiFreeTotal(usage.map { _ in Formatters.bytes(total) } ?? "—"))).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        ForEach(segments.prefix(3), id: \.label) { segment in
                            Rectangle().fill(segment.color)
                                .frame(width: total > 0 ? proxy.size.width * CGFloat(segment.value) / CGFloat(total) : 0)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 8)
                .background(Color.white.opacity(0.07))
                .clipShape(.capsule)
                DiscoverFlowLayout(spacing: 16, lineSpacing: 6) {
                    ForEach(segments, id: \.label) { segment in
                        HStack(spacing: 6) {
                            SettingsStatusDot(color: segment.color)
                            Text(segment.label).font(.caption).foregroundStyle(Theme.textMuted)
                            Text(usage.map { _ in Formatters.bytes(segment.value) } ?? "—").font(.subheadline.weight(.medium)).monospacedDigit()
                        }
                    }
                }
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(Theme.danger)
                }
            }
            .padding(.vertical, 4)
        } header: { Text(String(localized: .settingsStorageUiOverview)) }
          footer: { Text(statusText) }
    }

    // MARK: 目录行

    private func dirSection(title: String, group: String, trailing: String?) -> some View {
        SettingsFormSection {
            if let usage {
                ForEach(usage.dirs.filter { $0.group == group }, id: \.key) { dir in
                    dirRow(dir)
                }
            } else if !loaded || computing {
                SettingsLoadingRow()
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if let trailing { Text(trailing).textCase(nil).monospacedDigit() }
            }
        }
    }

    private func dirRow(_ dir: API.DirUsageView) -> some View {
        Button { selectedKey = dir.key } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dir.title).foregroundStyle(.primary)
                    Text(dir.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(dir.exists ? Formatters.bytes(dir.bytes) : "—")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.accessibilityIdentifier("storage-dir-\(dir.key)")
    }

    private func clean(_ dir: API.DirUsageView, mode: String) async {
        busyKey = dir.key
        notice = nil
        defer { busyKey = nil }
        do {
            let result = try await api.appStorageClean(key: dir.key, body: .init(mode: mode))
            let removed = AppLanguage.identifier == "zh-Hans" ? String(result.removed) : AppFormatting.number(result.removed)
            let skipped = AppLanguage.identifier == "zh-Hans" ? String(result.skippedBusy) : AppFormatting.number(result.skippedBusy)
            let text = result.skippedBusy > 0
                ? String(localized: .settingsStorageCleanedSkipped(Formatters.bytes(result.freedBytes), removed, skipped))
                : String(localized: .settingsStorageCleaned(Formatters.bytes(result.freedBytes), removed))
            notice = (dir.key, text, true)
            // 清理让后端快照标脏：这一次读取会拉起后台重算，占用数字随后被轮询替换
            await load(refresh: false)
        } catch {
            notice = (dir.key, error.localizedDescription, false)
        }
    }

    /// 未登记条目只显示相对 data/ 的短路径
    private func relative(_ path: String, _ root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

/// 确认由抽屉自己的反馈宿主承载，取消后留在当前目录。
private struct StorageDirectorySheet: View {
    let dir: API.DirUsageView
    let busy: Bool
    let notice: (text: String, ok: Bool)?
    let onClean: (String) async -> Void
    @Environment(Feedback.self) private var feedback

    var body: some View {
        SubsSheetScaffold(title: dir.title, closeTitle: String(localized: .commonDone)) {
            SettingsFormSection {
                LabeledContent(String(localized: .settingsStorageSpaceUsed), value: dir.exists ? Formatters.bytes(dir.bytes) : "—")
                Text(dir.description).font(.subheadline).foregroundStyle(.secondary)
            }
            SettingsFormSection(String(localized: .settingsStorageLocation)) {
                Text(dir.path).font(.footnote.monospaced()).textSelection(.enabled)
            }
            if dir.group == "cache", dir.exists {
                SettingsFormSection {
                    if dir.orphanAware {
                        Button(String(localized: .settingsStorageCleanUnused)) { Task { await askClean("orphans") } }
                            .accessibilityIdentifier("storage-clean-orphans")
                    }
                    if dir.clearable {
                        Button(String(localized: .settingsStorageClearCache), role: .destructive) { Task { await askClean("all") } }
                            .accessibilityIdentifier("storage-clean-all")
                    }
                } footer: {
                    if dir.rebuildCost == "expensive" { Text(String(localized: .settingsStorageRebuildHint)) }
                }
            }
            if let notice {
                SettingsFormSection {
                    Text(notice.text).foregroundStyle(notice.ok ? Theme.success : Theme.danger)
                        .accessibilityIdentifier("storage-clean-notice")
                }
            }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy)
    }

    private func askClean(_ mode: String) async {
        let ok: Bool
        if mode == "orphans" {
            ok = await feedback.confirm(String(localized: .settingsStorageUiOrphansTitle(dir.title)),
                message: String(localized: .settingsStorageUiOrphansHint), confirmTitle: String(localized: .settingsStorageUiOrphans))
        } else {
            ok = await feedback.confirm(String(localized: .settingsStorageUiClearTitle(dir.title)), message: dir.description,
                confirmTitle: dir.bytes > 0 ? String(localized: .settingsStorageUiClearBytes(Formatters.bytes(dir.bytes))) : String(localized: .settingsStorageUiClear), destructive: true)
        }
        if ok { await onClean(mode) }
    }
}
