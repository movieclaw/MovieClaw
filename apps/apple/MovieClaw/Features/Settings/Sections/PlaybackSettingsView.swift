import SwiftUI

/// 即时播放偏好与远程转码分组展示，远程配置在独立草稿中保存。
struct PlaybackSettingsView: View {
    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @State private var policy: API.PlaybackPolicyView?
    @State private var policyError: String?
    @State private var policyBusy = false
    @State private var config: Loadable<API.RemoteTranscodeConfigView> = .loading
    @State private var editing = false
    @State private var showingPairing = false
    @State private var status: SettingsTranscodeWorkerStatus?
    @State private var statusError: String?
    @State private var authorizedWorkers: [API.LoginDeviceView] = []

    var body: some View {
        List {
            policySections
            remoteSections
        }
        .listStyle(.insetGrouped)
        .appBackground()
        .task { await loadPolicy() }
        .task { await loadConfig() }
        .polling(every: 5, immediately: true) { await pollStatus() }
        .sheet(isPresented: $editing) {
            if let value = config.value {
                RemoteTranscodeEditor(config: value) { saved in
                    config = .loaded(saved)
                    Task { await pollStatus() }
                }.sheetFeedback()
            }
        }
        .sheet(isPresented: $showingPairing) {
            SubsSheetScaffold(title: "连接转码器", closeTitle: "完成") {
                SettingsFormSection {
                    Label("在 Mac 上打开 MovieClaw Transcoder，查找局域网服务器或输入服务器地址。", systemImage: "1.circle")
                    Label("选择「连接并配对」，获取配对码。", systemImage: "2.circle")
                    Label("在服务器的「设备」页输入配对码，核对设备后批准。", systemImage: "3.circle")
                } footer: { Text("目前支持 macOS Apple Silicon。配对凭证直接返回 Mac，无需手动复制令牌。") }
                SettingsFormSection {
                    Button("前往设备管理") {
                        showingPairing = false
                        router.push(.settingsSection(.devices))
                    }.accessibilityIdentifier("playback-pairing-devices")
                }
            }.sheetFeedback()
        }
    }

    @ViewBuilder private var policySections: some View {
        if let policyError {
            SettingsFormSection {
                SettingsNotice(text: policyError)
                if policy == nil { Button("重试") { Task { await loadPolicy() } } }
            }
        }
        if let policy {
            SettingsFormSection {
                Toggle("进度条预览", isOn: Binding(mcGet: { policy.trickplayEnabled }, set: { value in
                    Task { await savePolicy(trickplay: value) }
                }))
                .disabled(policyBusy).accessibilityIdentifier("playback-trickplay")
            } footer: {
                Text(policy.trickplayEnabled ? "首次播放时后台生成预览图，拖动进度条即可查看画面。" : "不为新影片生成预览图，已有预览仍可使用。")
            }
            SettingsFormSection {
                Toggle("保留转码缓存", isOn: Binding(mcGet: { policy.transcodeCacheEnabled }, set: { value in
                    Task { await savePolicy(cache: value) }
                }))
                .disabled(policyBusy).accessibilityIdentifier("playback-transcode-cache")
            } footer: {
                Text(policy.transcodeCacheEnabled ? "续播、重看时复用已转码内容。按可用空间自动限额，24 小时未用自动清理，也可在「更新与维护 → 缓存管理」中清空。" : "播放结束后删除分片，再次播放时重新转码。")
            }
        } else if policyError == nil { SettingsFormSection { SettingsLoadingRow() } }
    }

    @ViewBuilder private var remoteSections: some View {
        switch config {
        case .loading: SettingsFormSection("远程转码") { SettingsLoadingRow() }
        case let .failed(message):
            SettingsFormSection("远程转码") {
                SettingsNotice(text: message)
                Button("重试") { Task { await loadConfig() } }
            }
        case let .loaded(config):
            SettingsFormSection {
                Button { editing = true } label: {
                    HStack {
                        Text("远程转码设置").foregroundStyle(.primary)
                        Spacer()
                        Label(config.enabled ? "已启用" : "已关闭", systemImage: config.enabled ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(config.enabled ? Theme.success : Theme.textMuted)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.accessibilityIdentifier("remote-transcode-settings")
                ForEach(config.issues, id: \.self) { issue in SettingsNotice(text: issue, tone: .warn) }
            } header: { Text("远程转码") } footer: {
                Text(config.enabled ? "兼容转码器处理需要远程硬件的任务。没有转码器在线时自动使用服务器本地转码。" : "启用后可使用 Mac 的硬件转码能力，服务器仍负责播放会话与缓存。")
            }
            workerSection(config)
        }
    }

    private func workerSection(_ config: API.RemoteTranscodeConfigView) -> some View {
        let workers = status?.workers ?? []
        let connected = Set(workers.map(\.workerId))
        let offline = authorizedWorkers.filter { !connected.contains($0.name) }
        return SettingsFormSection {
            if let statusError {
                SettingsNotice(text: "无法刷新转码器状态：\(statusError)", tone: .warn)
            }
            if let status {
                ForEach(status.workers, id: \.workerId) { worker in
                    VStack(alignment: .leading, spacing: 5) {
                        ViewThatFits(in: .horizontal) {
                            HStack { Text(worker.workerId); Spacer(); workerState(worker) }
                            VStack(alignment: .leading, spacing: 4) { Text(worker.workerId); workerState(worker) }
                        }
                        Text(worker.summary).font(.caption).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("playback-worker-\(worker.workerId)")
                }
                ForEach(offline, id: \.id) { device in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(device.name)
                            Spacer()
                            Label("未连接", systemImage: "circle").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("已授权 · 最近活跃 \(SettingsTime.deviceRelative(device.lastSeenAt))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if workers.isEmpty && offline.isEmpty {
                    Text(config.ready ? "尚无转码器连接" : "启用远程转码后，可连接兼容的转码器")
                        .foregroundStyle(.secondary)
                }
            } else if statusError == nil { SettingsLoadingRow(text: "正在获取转码器状态…") }
            Button { showingPairing = true } label: { Label("连接转码器", systemImage: "plus") }
                .accessibilityIdentifier("playback-connect-worker")
            Button { router.push(.settingsSection(.devices)) } label: {
                HStack {
                    Text("管理已授权设备")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }.accessibilityIdentifier("playback-manage-workers")
        } header: { Text("转码器") } footer: {
            Text("在线状态每 5 秒刷新。Mac 休眠或断网时显示为未连接。")
        }
    }

    private func workerState(_ worker: SettingsTranscodeWorkerStatus.Worker) -> some View {
        Label(worker.online ? (worker.draining ? "暂停接单" : "在线") : "已离线",
              systemImage: worker.online ? (worker.draining ? "pause.circle.fill" : "circle.fill") : "circle")
            .font(.subheadline)
            .foregroundStyle(worker.online ? (worker.draining ? Theme.warning : Theme.success) : Theme.textMuted)
    }

    private func loadPolicy() async {
        do { policy = try await api.playbackPolicyShow(); policyError = nil }
        catch { policyError = error.localizedDescription }
    }

    private func savePolicy(trickplay: Bool? = nil, cache: Bool? = nil) async {
        guard !policyBusy, let previous = policy else { return }
        var optimistic = previous
        if let trickplay { optimistic.trickplayEnabled = trickplay }
        if let cache { optimistic.transcodeCacheEnabled = cache }
        policy = optimistic; policyBusy = true; policyError = nil
        defer { policyBusy = false }
        do { policy = try await api.playbackPolicySet(body: .init(trickplayEnabled: trickplay, transcodeCacheEnabled: cache)) }
        catch { policy = previous; policyError = error.localizedDescription }
    }

    private func loadConfig() async { await Loadable.load(into: $config) { try await api.transcodeConfigShow() } }

    /// 保留上次成功的状态，刷新失败时明确标记，避免已授权设备凭空消失。
    private func pollStatus() async {
        do {
            let latest = try await api.send("GET", "/transcode-worker/status", as: SettingsTranscodeWorkerStatus.self)
            let authorized = try await api.authDevicesList(all: true).filter { $0.scope == "transcode" }
            status = latest; authorizedWorkers = authorized; statusError = nil
        } catch { statusError = error.localizedDescription }
    }
}

struct RemoteTranscodeDraft: Equatable {
    var enabled: Bool
    var baseURL: String
    init(_ config: API.RemoteTranscodeConfigView) { enabled = config.enabled; baseURL = config.baseUrlOverride }
    var valid: Bool { NetworkSettingsValidation.validURL(baseURL, allowEmpty: true) }
    var payload: API.RemoteTranscodeConfigPayload {
        .init(enabled: enabled, baseUrl: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), maxArtifactBytes: 512 * 1024 * 1024)
    }
}

private struct RemoteTranscodeEditor: View {
    let config: API.RemoteTranscodeConfigView
    let onSaved: (API.RemoteTranscodeConfigView) -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RemoteTranscodeDraft
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false
    @State private var confirmingDisable = false
    private var dirty: Bool { draft != RemoteTranscodeDraft(config) }

    init(config: API.RemoteTranscodeConfigView, onSaved: @escaping (API.RemoteTranscodeConfigView) -> Void) {
        self.config = config; self.onSaved = onSaved
        _draft = State(initialValue: RemoteTranscodeDraft(config))
    }

    var body: some View {
        SubsSheetScaffold(title: "远程转码设置", onClose: {
            if dirty { discarding = true } else { dismiss() }
        }, confirm: .init(title: "保存", enabled: dirty && draft.valid, busy: busy, identifier: "remote-transcode-save") {
            if config.enabled && !draft.enabled { confirmingDisable = true }
            else { Task { await save() } }
        }) {
            SettingsFormSection {
                Toggle("启用远程硬件转码", isOn: $draft.enabled).accessibilityIdentifier("remote-transcode-enabled")
            } footer: {
                Text(draft.enabled ? "保存后立即生效，无需重启。没有兼容转码器在线时自动回到服务器本地转码。" : "关闭后，已配对转码器会断开连接，播放使用服务器本地转码。")
            }
            SettingsFormSection {
                TextField("自动使用转码器连接地址", text: $draft.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("remote-transcode-base-url")
            } header: { Text("取源与回传地址") } footer: {
                Text("留空使用每台转码器连接服务器时的地址。仅当反向代理改写 Host、导致转码器无法取源或回传时，才需要填写转码器可访问的 http(s) 地址。")
            }
            if !draft.valid { SettingsFormSection { Text("请输入完整的 http(s) 地址，或留空使用自动地址。").foregroundStyle(Theme.warning) } }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .alert("关闭远程转码？", isPresented: $confirmingDisable) {
            Button("取消", role: .cancel) { }
            Button("关闭并保存", role: .destructive) { Task { await save() } }
        } message: { Text("已配对的转码器会断开连接，后续播放使用服务器本地转码。") }
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do { onSaved(try await api.transcodeConfigSet(body: draft.payload)); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
/// `GET /transcode-worker/status` 的响应（生成器给的是任意字典，这里按 Web lib/api/transcode-worker.ts 手写）
nonisolated struct SettingsTranscodeWorkerStatus: Decodable, Sendable {
    struct Worker: Decodable, Sendable {
        let workerId: String
        let workerVersion: String?
        let arch: String?
        let platform: String?
        let ffmpegVersion: String?
        let backends: [String]
        let maxJobs: Int
        let activeJobs: Int
        let draining: Bool
        let lastSeenSeconds: Double
        let online: Bool

        enum CodingKeys: String, CodingKey {
            case workerId = "worker_id", workerVersion = "worker_version", arch, platform
            case ffmpegVersion = "ffmpeg_version", backends, maxJobs = "max_jobs", activeJobs = "active_jobs"
            case draining, lastSeenSeconds = "last_seen_seconds", online
        }

        /// 「macOS · arm64 · ffmpeg 7.1 · videotoolbox · 任务 0/2 · 3 秒前活跃」
        var summary: String {
            // 空串与 nil 一样滤掉（Web filter(Boolean)），不会出现「ffmpeg 」这种半截字段
            let ffmpeg = ffmpegVersion.flatMap { $0.isEmpty ? nil : "ffmpeg \($0)" }
            return [
                platform, arch, ffmpeg,
                backends.isEmpty ? nil : backends.joined(separator: "/"),
                "任务 \(activeJobs)/\(maxJobs)", "\(Int(lastSeenSeconds.rounded())) 秒前活跃",
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    let enabled: Bool
    let ready: Bool
    let workers: [Worker]
}
