import SwiftUI

/// 由分类页右上角进入，清理范围始终限制为打开时的设备分类和成员范围。
struct DeviceCleanupPopover: View {
    let group: DeviceGroup
    let all: Bool
    let onChanged: () -> Void
    let onDone: (String) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var days = 30
    @State private var preview: Loadable<[API.DeviceCleanupItem]> = .loading
    @State private var previewDays: Int?
    @State private var busy = false
    @State private var confirming = false
    @State private var error: String?
    @State private var completed = 0
    @State private var contentHeight: CGFloat?

    private var items: [API.DeviceCleanupItem] { previewDays == days ? preview.value ?? [] : [] }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("清理\(group.title)").font(.headline)
                    Text("仅清理\(all ? "全部成员" : "我的设备")中的\(group.title)，包含当前搜索未显示的设备。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    intervalPicker.disabled(busy)
                    switch preview {
                    case .loading:
                        ProgressView("正在检查设备…")
                    case let .failed(message):
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                    case .loaded:
                        if items.isEmpty {
                            Label("没有需要清理的设备", systemImage: "checkmark.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("\(items.count) 台设备超过 \(days) 天未使用")
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("devices-cleanup-summary")
                            DisclosureGroup("查看待清理设备") {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(items, id: \.id) { item in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name)
                                            if all { Text(item.ownerNickname).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                                .font(.subheadline).padding(.top, 8)
                            }
                        }
                    }
                    Text("当前设备和已连接的转码器不会被清理。清理后需要重新登录或配对。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("devices-cleanup-error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(idealHeight: typeSize.isAccessibilitySize ? nil : contentHeight,
                   maxHeight: typeSize.isAccessibilitySize ? nil : contentHeight)
            Button(role: .destructive) { confirming = true } label: {
                HStack {
                    if busy { ProgressView().tint(.black) }
                    Text(busy ? "正在清理 · \(completed)" : "清理 \(items.count) 台设备")
                }
                .foregroundStyle(items.isEmpty ? Color.secondary : .black).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large)
            .disabled(items.isEmpty || busy)
            .accessibilityIdentifier("devices-cleanup-submit")
            Button("取消") { dismiss() }
                .disabled(busy).accessibilityIdentifier("sheet-cancel")
        }
        .padding(20)
        .frame(idealWidth: 340)
        .presentationCompactAdaptation(.popover)
        .presentationDetents([.large])
        .interactiveDismissDisabled(busy)
        .alert("清理这 \(items.count) 台设备？", isPresented: $confirming) {
            Button("取消", role: .cancel) { }
            Button("清理 \(items.count) 台设备", role: .destructive) { Task { await submit() } }
        } message: {
            Text("仅影响\(group.title)中超过 \(days) 天未使用的设备，它们将立即失去访问权限。")
        }
        .task(id: days) { await load() }
    }

    private var intervalPicker: some View {
        Picker("未使用时间", selection: $days) {
            ForEach([7, 30, 90], id: \.self) { Text("\($0) 天").tag($0) }
        }
        .modifier(CleanupIntervalStyle(accessibility: typeSize.isAccessibilitySize))
        .accessibilityIdentifier("devices-cleanup-days")
    }

    private func load() async {
        let requestedDays = days
        preview = .loading
        previewDays = nil
        do {
            let result = try await api.authDevicesCleanup(body: .init(inactiveDays: requestedDays, all: all, dryRun: true))
            guard !Task.isCancelled, requestedDays == days else { return }
            previewDays = requestedDays
            preview = .loaded(group.cleanupCandidates(result.devices))
        } catch {
            guard !Task.isCancelled, requestedDays == days else { return }
            preview = .failed(error.localizedDescription)
        }
    }

    private func submit() async {
        guard !busy, !items.isEmpty else { return }
        let confirmedIDs = Set(items.map(\.id))
        busy = true
        completed = 0
        error = nil
        defer { busy = false }
        do {
            // 兼容现有服务器：只使用全局清理接口的预览能力，绝不执行全局批量注销。
            // 确认后再检查一次，跳过刚恢复活跃的设备，也不扩大用户已确认的名单。
            let fresh = try await api.authDevicesCleanup(body: .init(inactiveDays: days, all: all, dryRun: true))
            for item in group.cleanupCandidates(fresh.devices) where confirmedIDs.contains(item.id) {
                try await api.authDevicesRevoke(deviceId: item.id)
                completed += 1
            }
            onChanged()
            onDone(completed == 0 ? "没有仍需清理的设备" : "已清理 \(completed) 台\(group.title)设备")
        } catch {
            self.error = "已清理 \(completed) 台，其余未完成：\(error.localizedDescription)"
            if completed > 0 { onChanged() }
            await load()
        }
    }
}

private struct CleanupIntervalStyle: ViewModifier {
    let accessibility: Bool
    func body(content: Content) -> some View {
        if accessibility { content.pickerStyle(.menu) }
        else { content.pickerStyle(.segmented) }
    }
}
