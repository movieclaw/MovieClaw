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
                    Text(String(localized: .settingsCleanupTitle(group.title))).font(.headline)
                    Text(all ? String(localized: .settingsCleanupScopeAll(group.title)) : String(localized: .settingsCleanupScopeMine(group.title)))
                        .font(.subheadline).foregroundStyle(.secondary)
                    intervalPicker.disabled(busy)
                    switch preview {
                    case .loading:
                        ProgressView(String(localized: .settingsCleanupChecking))
                    case let .failed(message):
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                        Button(String(localized: .commonRetry)) { Task { await load() } }
                    case .loaded:
                        if items.isEmpty {
                            Label(String(localized: .settingsCleanupNone), systemImage: "checkmark.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: .settingsCleanupFound(items.count, days)))
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("devices-cleanup-summary")
                            DisclosureGroup(String(localized: .settingsCleanupReview)) {
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
                    Text(String(localized: .settingsCleanupHint))
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
                    Text(busy ? String(localized: .settingsCleanupProgress(completed)) : String(localized: .settingsCleanupAction(items.count)))
                }
                .foregroundStyle(items.isEmpty ? Color.secondary : .black).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.large)
            .disabled(items.isEmpty || busy)
            .accessibilityIdentifier("devices-cleanup-submit")
            Button(String(localized: .commonCancel)) { dismiss() }
                .disabled(busy).accessibilityIdentifier("sheet-cancel")
        }
        .padding(20)
        .frame(idealWidth: 340)
        .presentationCompactAdaptation(.popover)
        .adaptiveDetents([.large])
        .interactiveDismissDisabled(busy)
        .alert(String(localized: .settingsCleanupConfirmTitle(items.count)), isPresented: $confirming) {
            Button(String(localized: .commonCancel), role: .cancel) { }
            Button(String(localized: .settingsCleanupAction(items.count)), role: .destructive) { Task { await submit() } }
        } message: {
            Text(String(localized: .settingsCleanupConfirmHint(group.title, days)))
        }
        .task(id: days) { await load() }
    }

    private var intervalPicker: some View {
        Picker(String(localized: .settingsCleanupInactiveFor), selection: $days) {
            ForEach([7, 30, 90], id: \.self) { Text(String(localized: .settingsSitesDays($0))).tag($0) }
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
            onDone(completed == 0 ? String(localized: .settingsCleanupNoneLeft) : String(localized: .settingsCleanupDoneCount(completed, group.title)))
        } catch {
            self.error = String(localized: .settingsCleanupPartial(completed, error.localizedDescription))
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
