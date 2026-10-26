import SwiftUI

/// 即时播放偏好与远程转码分组展示，远程配置在独立草稿中保存。
struct PlaybackSettingsView: View {
    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @State private var policy: API.PlaybackPolicyView?
    @State private var policyError: String?
    @State private var policyBusy = false
    /// 关「片段预切」前查到的已切片段；非空时弹「要不要一并删除」
    @State private var clipsToDrop: API.ReelClipStatsView?
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
        .polling(every: 15) { await refreshClipProgress() }
        .confirmationDialog(String(localized: .settingsPlaybackControlsDisableClipsTitle), isPresented: Binding(mcGet: { clipsToDrop != nil }, set: { if !$0 { clipsToDrop = nil } }),
                            titleVisibility: .visible, presenting: clipsToDrop) { stats in
            Button(String(localized: .settingsPlaybackClipsOffKeep)) { Task { await savePolicy(clips: false) } }
            Button(String(localized: .settingsPlaybackClipsOffPurge(stats.count, Formatters.bytes(stats.bytes))), role: .destructive) {
                Task { await savePolicy(clips: false, purgeClips: true) }
            }
            Button(String(localized: .commonCancel), role: .cancel) { }
        } message: { _ in Text(String(localized: .settingsPlaybackClipsOffHint)) }
        .sheet(isPresented: $editing) {
            if let value = config.value {
                RemoteTranscodeEditor(config: value) { saved in
                    config = .loaded(saved)
                    Task { await pollStatus() }
                }.sheetFeedback()
            }
        }
        .sheet(isPresented: $showingPairing) {
            SubsSheetScaffold(title: String(localized: .settingsPlaybackWorkerConnect), closeTitle: String(localized: .commonDone)) {
                SettingsFormSection {
                    Label(String(localized: .settingsPlaybackWorkerStep1), systemImage: "1.circle")
                    Label(String(localized: .settingsPlaybackWorkerStep2), systemImage: "2.circle")
                    Label(String(localized: .settingsPlaybackWorkerStep3), systemImage: "3.circle")
                } footer: { Text(String(localized: .settingsPlaybackWorkerFooter)) }
                SettingsFormSection {
                    Button(String(localized: .settingsPlaybackWorkerOpenDevices)) {
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
                if policy == nil { Button(String(localized: .commonRetry)) { Task { await loadPolicy() } } }
            }
        }
        if let policy {
            SettingsFormSection {
                Toggle(String(localized: .settingsPlaybackTrickplayTitle), isOn: Binding(mcGet: { policy.trickplayEnabled }, set: { value in
                    Task { await savePolicy(trickplay: value) }
                }))
                .disabled(policyBusy).accessibilityIdentifier("playback-trickplay")
            } footer: {
                Text(policy.trickplayEnabled ? String(localized: .settingsPlaybackTrickplayOn) : String(localized: .settingsPlaybackTrickplayOff))
            }
            SettingsFormSection {
                Toggle(String(localized: .settingsPlaybackCacheTitle), isOn: Binding(mcGet: { policy.transcodeCacheEnabled }, set: { value in
                    Task { await savePolicy(cache: value) }
                }))
                .disabled(policyBusy).accessibilityIdentifier("playback-transcode-cache")
            } footer: {
                Text(policy.transcodeCacheEnabled ? String(localized: .settingsPlaybackCacheOn) : String(localized: .settingsPlaybackCacheOff))
            }
            SettingsFormSection {
                Toggle(String(localized: .settingsPlaybackControlsClipsTitle), isOn: Binding(mcGet: { policy.reelClipsEnabled ?? false }, set: { value in
                    Task { await toggleClips(value) }
                }))
                .disabled(policyBusy).accessibilityIdentifier("playback-reel-clips")
            } footer: {
                Text(Self.clipsFooter(enabled: policy.reelClipsEnabled ?? false, progress: policy.reelClipsProgress))
            }
        } else if policyError == nil { SettingsFormSection { SettingsLoadingRow() } }
    }

    @ViewBuilder private var remoteSections: some View {
        switch config {
        case .loading: SettingsFormSection(String(localized: .settingsPlaybackControlsRemoteTitle)) { SettingsLoadingRow() }
        case let .failed(message):
            SettingsFormSection(String(localized: .settingsPlaybackControlsRemoteTitle)) {
                SettingsNotice(text: message)
                Button(String(localized: .commonRetry)) { Task { await loadConfig() } }
            }
        case let .loaded(config):
            SettingsFormSection {
                Button { editing = true } label: {
                    HStack {
                        Text(String(localized: .settingsPlaybackRemoteSettings)).foregroundStyle(.primary)
                        Spacer()
                        Label(config.enabled ? String(localized: .settingsMembersUiEnabled) : String(localized: .settingsPlaybackControlsOff), systemImage: config.enabled ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(config.enabled ? Theme.success : Theme.textMuted)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.accessibilityIdentifier("remote-transcode-settings")
                ForEach(config.issues, id: \.self) { issue in SettingsNotice(text: issue, tone: .warn) }
            } header: { Text(String(localized: .settingsPlaybackControlsRemoteTitle)) } footer: {
                Text(config.enabled ? String(localized: .settingsPlaybackRemoteOnHint) : String(localized: .settingsPlaybackRemoteOffHint))
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
                SettingsNotice(text: String(localized: .settingsPlaybackRemoteStatusFailed(statusError)), tone: .warn)
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
                            Label(String(localized: .settingsPlaybackControlsDisconnected), systemImage: "circle").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(String(localized: .settingsPlaybackRemoteAuthorizedSeen(SettingsTime.deviceRelative(device.lastSeenAt)))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if workers.isEmpty && offline.isEmpty {
                    Text(config.ready ? String(localized: .settingsPlaybackRemoteNoneConnected) : String(localized: .settingsPlaybackRemoteEnableFirst))
                        .foregroundStyle(.secondary)
                }
            } else if statusError == nil { SettingsLoadingRow(text: String(localized: .settingsPlaybackRemoteLoading)) }
            Button { showingPairing = true } label: { Label(String(localized: .settingsPlaybackWorkerConnect), systemImage: "plus") }
                .accessibilityIdentifier("playback-connect-worker")
            Button { router.push(.settingsSection(.devices)) } label: {
                HStack {
                    Text(String(localized: .settingsPlaybackRemoteManageDevices))
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }.accessibilityIdentifier("playback-manage-workers")
        } header: { Text(String(localized: .settingsDevicesLabelsWorker)) } footer: {
            Text(String(localized: .settingsPlaybackRemoteStatusHint))
        }
    }

    private func workerState(_ worker: SettingsTranscodeWorkerStatus.Worker) -> some View {
        Label(worker.online ? (worker.draining ? String(localized: .settingsPlaybackControlsDraining) : String(localized: .settingsDevicesUiOnline)) : String(localized: .settingsPlaybackControlsOffline),
              systemImage: worker.online ? (worker.draining ? "pause.circle.fill" : "circle.fill") : "circle")
            .font(.subheadline)
            .foregroundStyle(worker.online ? (worker.draining ? Theme.warning : Theme.success) : Theme.textMuted)
    }

    private func loadPolicy() async {
        do { policy = try await api.playbackPolicyShow(); policyError = nil }
        catch { policyError = error.localizedDescription }
    }

    private func savePolicy(trickplay: Bool? = nil, cache: Bool? = nil, clips: Bool? = nil, purgeClips: Bool = false) async {
        guard !policyBusy, let previous = policy else { return }
        var optimistic = previous
        if let trickplay { optimistic.trickplayEnabled = trickplay }
        if let cache { optimistic.transcodeCacheEnabled = cache }
        if let clips { optimistic.reelClipsEnabled = clips }
        policy = optimistic; policyBusy = true; policyError = nil
        defer { policyBusy = false }
        do { policy = try await api.playbackPolicySet(body: .init(trickplayEnabled: trickplay, transcodeCacheEnabled: cache, reelClipsEnabled: clips)) }
        catch { policy = previous; policyError = error.localizedDescription; return }
        if purgeClips {
            do { _ = try await api.reelsClipsClear() } catch { policyError = error.localizedDescription }
        }
    }

    /// 关闭时若已有切好的片段，先问要不要一并删除（同 Web reel-clips-toggle-section）
    private func toggleClips(_ next: Bool) async {
        guard !next else { return await savePolicy(clips: true) }
        do {
            let stats = try await api.reelsClipsStats()
            if stats.count > 0 { clipsToDrop = stats } else { await savePolicy(clips: false) }
        } catch { policyError = error.localizedDescription }
    }

    /// 开着且还在切时刷新进度
    private func refreshClipProgress() async {
        guard !policyBusy, let current = policy, current.reelClipsEnabled == true,
              current.reelClipsProgress?.state != "done" else { return }
        if let latest = try? await api.playbackPolicyShow(), !policyBusy { policy = latest }
    }

    /// 片段预切的说明：关着讲开启的好处，开着写进度（文案同 Web reel-clips-toggle-section）
    static func clipsFooter(enabled: Bool, progress: API.ReelClipProgressView?) -> String {
        guard enabled else {
            return String(localized: .settingsPlaybackClipsOffPitch)
        }
        guard let progress else { return String(localized: .settingsPlaybackControlsPreparing) }
        switch progress.state {
        case "done":
            let skipped = progress.total - progress.ready
            return skipped > 0
                ? String(localized: .settingsPlaybackClipsDoneSkipped(progress.ready, skipped))
                : String(localized: .settingsPlaybackControlsClipsDone(progress.ready))
        case "paused": return String(localized: .settingsPlaybackControlsClipsPaused(progress.ready, String(progress.total)))
        default: return String(localized: .settingsPlaybackControlsClipsRunning(progress.ready, String(progress.total)))
        }
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
        SubsSheetScaffold(title: String(localized: .settingsPlaybackRemoteSettings), onClose: {
            if dirty { discarding = true } else { dismiss() }
        }, confirm: .init(title: String(localized: .commonSave), enabled: dirty && draft.valid, busy: busy, identifier: "remote-transcode-save") {
            if config.enabled && !draft.enabled { confirmingDisable = true }
            else { Task { await save() } }
        }) {
            SettingsFormSection {
                Toggle(String(localized: .settingsPlaybackControlsEnableRemote), isOn: $draft.enabled).accessibilityIdentifier("remote-transcode-enabled")
            } footer: {
                Text(draft.enabled ? String(localized: .settingsPlaybackRemoteSaveOnHint) : String(localized: .settingsPlaybackRemoteSaveOffHint))
            }
            SettingsFormSection {
                TextField(String(localized: .settingsPlaybackRemoteAutoAddress), text: $draft.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("remote-transcode-base-url")
            } header: { Text(String(localized: .settingsPlaybackControlsAddress)) } footer: {
                Text(String(localized: .settingsPlaybackRemoteAddressHint))
            }
            if !draft.valid { SettingsFormSection { Text(String(localized: .settingsPlaybackRemoteAddressInvalid)).foregroundStyle(Theme.warning) } }
            if let error { SettingsFormSection { SettingsNotice(text: error) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || dirty)
        .alert(String(localized: .settingsFormDiscardTitle), isPresented: $discarding) {
            Button(String(localized: .settingsFormKeepEditing), role: .cancel) { }
            Button(String(localized: .settingsScrapeDiscardChanges), role: .destructive) { dismiss() }
        }
        .alert(String(localized: .settingsPlaybackRemoteDisableTitle), isPresented: $confirmingDisable) {
            Button(String(localized: .commonCancel), role: .cancel) { }
            Button(String(localized: .settingsPlaybackRemoteDisableSave), role: .destructive) { Task { await save() } }
        } message: { Text(String(localized: .settingsPlaybackRemoteDisableHint)) }
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
                String(localized: .settingsPlaybackControlsJobs(activeJobs, maxJobs)), String(localized: .settingsPlaybackControlsSeen(Int(lastSeenSeconds.rounded()))),
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    let enabled: Bool
    let ready: Bool
    let workers: [Worker]
}
