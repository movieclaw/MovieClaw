import SwiftUI

/// 订阅首屏只读摘要；编辑在同一张 sheet 的独立导航页完成。
struct SmartProfileSection: View {
    let kind: String
    @Binding var profile: SmartProfile?
    let onNeedsSetup: () -> Void
    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @State private var error: String?
    @State private var reload = 0
    @State private var loadedRequest: String?

    private var kindLabel: String { kind == "movie" ? "电影" : "剧集" }

    var body: some View {
        Section {
            if let error {
                SubsNoticeRow(text: error, tone: .error)
                Button("重新读取设置") { reload += 1 }.accessibilityIdentifier("smart-reload")
            } else if let profile {
                if permissions.isAdmin {
                    NavigationLink(value: SubscribeSheet.Page.smart) { summary(profile.preferences) }
                        .accessibilityIdentifier("smart-edit")
                } else if profile.preferences != nil {
                    summary(profile.preferences)
                } else {
                    Text("请管理员先完成\(kindLabel)智能设置，或选择规则模式。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                HStack { ProgressView(); Text("正在读取智能设置…") }
            }
        }
        .background {
            // 用单个无布局占位的视图承载加载任务，避免空分组标题撑高间距。
            Color.clear.task(id: "\(kind)-\(reload)") { await load() }
        }
    }

    private func summary(_ preferences: SmartPreferences?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("智能选择").font(.subheadline).foregroundStyle(.secondary)
            if let preferences {
                Text("优先 \(preferences.targetLabel)").font(.headline)
                Text("\(preferences.waitLabel) · \(preferences.allowUpgrade ? "允许后续洗版" : "入库后不洗版")")
                    .font(.subheadline).foregroundStyle(.secondary)
                if preferences.strictResolution {
                    Text("只接受 \(preferences.resolutionLabel)").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("设置\(kindLabel)偏好").font(.headline)
                Text("设置一次，之后自动复用").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        let requestKey = "\(kind)-\(reload)"
        guard loadedRequest != requestKey else { return }
        loadedRequest = requestKey
        profile = nil
        error = nil
        do {
            let value = try await api.smartProfile(kind: kind)
            try Task.checkCancellation()
            profile = value
            if value.preferences == nil, permissions.isAdmin { onNeedsSetup() }
        } catch is CancellationError {
            loadedRequest = nil
        } catch {
            self.error = (error as? APIError)?.status == 404
                ? "服务器尚未支持智能选择，请在更多选项中使用规则模式。"
                : error.localizedDescription
        }
    }
}

/// 草稿只在此页编辑；取消不写入，保存成功后更新父页摘要。保存与订阅各有一个明确的提交点。
struct SmartProfileEditor: View {
    let kind: String
    let onUpdated: (SmartProfile) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var profile: SmartProfile
    @State private var draft: SmartPreferences
    @State private var busy = false
    @State private var error: String?
    @State private var waitChoice: String
    @State private var customDays: String
    @State private var legacyWait: Int?

    init(kind: String, profile: SmartProfile, onUpdated: @escaping (SmartProfile) -> Void) {
        self.kind = kind
        self.onUpdated = onUpdated
        let preferences = profile.preferences ?? .defaults(kind: kind)
        _profile = State(initialValue: profile)
        _draft = State(initialValue: preferences)
        _waitChoice = State(initialValue: Self.choice(preferences.waitSeconds))
        _customDays = State(initialValue: Self.days(preferences.waitSeconds))
        _legacyWait = State(initialValue: Self.legacy(preferences.waitSeconds))
    }

    private var kindLabel: String { kind == "movie" ? "电影" : "剧集" }
    private var valid: Bool {
        waitChoice != "custom" || Int(customDays).map { (1...7).contains($0) } == true
    }

    var body: some View {
        Form {
            if let error {
                Section {
                    SubsNoticeRow(text: error, tone: .error)
                    Button("重新读取设置") { Task { await reload() } }.accessibilityIdentifier("smart-reload")
                }
            }
            Section {
                Picker("优先分辨率", selection: $draft.resolution) {
                    Text("4K").tag("2160p"); Text("1080p").tag("1080p")
                }.accessibilityIdentifier("smart-resolution")
                Picker("优先片源", selection: $draft.source) {
                    Text("WEB-DL").tag("web-dl"); Text("蓝光").tag("blu-ray"); Text("Remux").tag("remux")
                }.accessibilityIdentifier("smart-source")
                Picker("等待耐心", selection: $waitChoice) {
                    Text("尽快下载 · 不等待").tag("0")
                    Text("可以等 · 最多 3 小时").tag("10800")
                    Text("更有耐心 · 最多 1 天").tag("86400")
                    Text("自定义").tag("custom")
                    if let legacyWait { Text("原有设置 · \(legacyWait / 3600) 小时").tag(String(legacyWait)) }
                }.accessibilityIdentifier("smart-wait")
                if waitChoice == "custom" {
                    HStack {
                        Text("最多等待")
                        Spacer(minLength: 8)
                        TextField("", text: $customDays)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 44)
                            .accessibilityLabel("自定义等待天数").accessibilityIdentifier("smart-days")
                        Text("天").foregroundStyle(.secondary)
                        Stepper(value: Binding(mcGet: { Int(customDays) ?? 1 }, set: { customDays = String($0) }), in: 1...7) { EmptyView() }
                            .labelsHidden().fixedSize().disabled(!valid)
                            .accessibilityLabel("等待天数").accessibilityValue("\(customDays) 天")
                            .accessibilityIdentifier("smart-days-stepper")
                    }
                }
                Toggle("允许后续洗版", isOn: $draft.allowUpgrade)
                    .toggleStyle(SystemSwitchStyle()).accessibilityIdentifier("smart-upgrade")
            } footer: {
                Text(profile.preferences == nil ? "保存后，之后的\(kindLabel)订阅会自动复用。" : "修改只影响之后新建的\(kindLabel)订阅。")
            }
            Section("最低要求") {
                Toggle("只接受 \(draft.resolutionLabel)", isOn: $draft.strictResolution)
                    .toggleStyle(SystemSwitchStyle()).accessibilityIdentifier("smart-strict-resolution")
            }
        }
        .pickerStyle(.menu)
        .subsFormStyle()
        .disabled(busy)
        .navigationTitle("\(kindLabel)偏好")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", systemImage: "xmark", role: .cancel) { dismiss() }
                    .disabled(busy).accessibilityIdentifier("smart-cancel-edit")
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView().accessibilityLabel("正在保存") }
                else {
                    Button("保存", systemImage: "checkmark", role: .confirm) { Task { await save() } }
                        .discoverProminentButton().disabled(!valid).accessibilityIdentifier("smart-save")
                }
            }
        }
        .onChange(of: waitChoice) { _, value in
            if value == "custom" {
                customDays = Self.days(draft.waitSeconds)
                draft.waitSeconds = (Int(customDays) ?? 1) * 86400
            } else if let seconds = Int(value) { draft.waitSeconds = seconds }
        }
        .onChange(of: customDays) { _, value in
            if let days = Int(value), (1...7).contains(days) { draft.waitSeconds = days * 86400 }
        }
    }

    private static func choice(_ seconds: Int) -> String {
        ![0, 10800, 86400].contains(seconds) && seconds % 86400 == 0 ? "custom" : String(seconds)
    }
    private static func days(_ seconds: Int) -> String { String(min(7, max(1, Int(ceil(Double(seconds) / 86400))))) }
    private static func legacy(_ seconds: Int) -> Int? {
        ![0, 10800, 86400].contains(seconds) && seconds % 86400 != 0 ? seconds : nil
    }
    private func reload() async {
        busy = true
        defer { busy = false }
        do {
            let value = try await api.smartProfile(kind: kind)
            profile = value
            draft = value.preferences ?? .defaults(kind: kind)
            waitChoice = Self.choice(draft.waitSeconds)
            customDays = Self.days(draft.waitSeconds)
            legacyWait = Self.legacy(draft.waitSeconds)
            error = nil
            onUpdated(value)
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard valid, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let value = try await api.saveSmartProfile(kind: kind, body: .init(revision: profile.revision, preferences: draft))
            onUpdated(value)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
