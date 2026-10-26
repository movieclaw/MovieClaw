import SwiftUI

/// 更新与维护 首页（Web app-update-section.tsx，机制见 docs/design/in-app-update.md）。
///
/// - 状态区：当前版本 + 代码来源；曾启动失败被自动回落的版本、未在运行的已装版本、异常退出横幅（可「知道了」）；
/// - **进页即知**：挂载时读服务端待更新快照（定时检查早就查过），有新版直接摆出版本卡片；
///   「检查更新」保留为「我现在就要重查一次」，手动检查的结论优先于快照；
/// - 更新执行：`POST /app/update/apply` 后 1 秒轮询进度；进入 restarting（或连续 3 次拉不到进度）后
///   改为轮询 `/health` 等服务恢复——先见到不可达、再见到恢复才算一次真实重启，恢复后重新拉取本页数据；
/// - NER 模型独立检查 / 更新；回退选择器（数据兼容三档：直接切换 / 恢复备份 / 无备份）；本地保留版本数 2~20；
/// - 维护：重启应用（二次确认），与更新共用同一套等待流程。
struct AppUpdatePanel<Header: View>: View {
    @ViewBuilder let maintenance: () -> Header
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback

    enum RestartWait { case idle, waiting, timeout }
    enum RestartKind { case version, app }

    /// 新版本卡片的数据：手动检查结果与服务端快照归一到同一形状
    struct AvailableUpdate {
        var version: String
        var compatible: Bool
        var changelog: String
        /// 该版本曾在本机连续启动失败被回落（只有手动检查结果带这一位）
        var knownBad: Bool
    }

    @State private var status: Loadable<API.UpdateStatusView> = .loading
    @State private var check: API.UpdateCheckView?
    @State private var checking = false
    @State private var checkError: String?
    @State private var progress: API.UpdateProgressView?
    @State private var actionError: String?
    @State private var actionBusy = false
    @State private var modelCheck: API.ModelUpdateCheckView?
    @State private var modelChecking = false
    @State private var modelError: String?
    @State private var pendingVersion: AvailableUpdate?
    @State private var pendingModelTag: String?
    @State private var restartWait: RestartWait = .idle
    @State private var restartKind: RestartKind = .version
    @State private var rollback: API.RollbackOptionsView?
    @State private var rollbackOpen = false
    @State private var changelogOpen = false
    @State private var retentionBusy = false
    @State private var pollTask: Task<Void, Never>?
    /// 回退 / 重启 / 进页恢复「重启中」的等待任务：离开页面即取消，不再在后台继续探测 /health（Web unmounted 守卫）
    @State private var restartTask: Task<Void, Never>?
    @State private var restartInfoShown = false

    var body: some View {
        List {
            if restartWait != .idle {
                restartWaitingView
            } else {
                switch status {
                case .loading:
                    SettingsFormSection { SettingsLoadingRow(text: String(localized: .settingsUpdateUiLoading)) }
                case .failed:
                    SettingsFormSection {
                        HStack {
                            Text(String(localized: .settingsUpdateUiLoadFailed)).foregroundStyle(Theme.textMuted)
                            Spacer()
                            Button(String(localized: .commonRetry)) { Task { await reloadStatus() } }.buttonStyle(.glass)
                        }
                    }
                case let .loaded(status):
                    content(status)
                    maintenance().disabled(updating)
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: .settingsUpdateUiRestart), systemImage: "arrow.clockwise", role: .destructive) {
                        restartTask?.cancel()
                        restartTask = Task { await doRestart() }
                    }.accessibilityIdentifier("app-restart")
                } label: { Label(String(localized: .settingsUpdateUiMaintenanceActions), systemImage: "ellipsis") }
                .disabled(updating || restartWait != .idle || status.value == nil)
                .accessibilityIdentifier("app-actions")
            }
        }
        .task { await initialLoad() }
        .onDisappear {
            pollTask?.cancel()
            restartTask?.cancel()
        }
        .sheet(isPresented: $rollbackOpen) {
            RollbackSheet(options: rollback, retentionBusy: retentionBusy, error: actionError, onRetention: { await setRetention($0) }) { target in
                rollbackOpen = false
                restartTask?.cancel()
                restartTask = Task { await doRollback(target) }
            }
            .sheetFeedback()
        }
        .sheet(isPresented: $changelogOpen) {
            SubsSheetScaffold(title: String(localized: .settingsPluginMarketChangelog), closeTitle: String(localized: .commonDone)) {
                SettingsFormSection { SettingsMarkdownText(text: available?.changelog ?? "") }
            }
        }
    }

    private var updating: Bool {
        actionBusy || (progress.map { !["idle", "failed"].contains($0.phase) } ?? false)
    }

    private var available: AvailableUpdate? {
        if let check {
            return check.updateAvailable ? AvailableUpdate(version: check.latestVersion, compatible: check.compatible,
                changelog: check.changelog, knownBad: check.latestKnownBad) : nil
        }
        return pendingVersion
    }

    // MARK: 加载

    private func reloadStatus() async {
        await Loadable.load(into: $status) { try await api.appUpdateStatus() }
    }

    private func initialLoad() async {
        await reloadStatus()
        // 恢复进行中的更新跟踪：中途进入本页时后台线程可能正在下载安装
        if let current = try? await api.appUpdateProgress() {
            if ["checking", "downloading", "verifying", "applying"].contains(current.phase) {
                progress = current
                startPollingProgress()
            } else if current.phase == "restarting" {
                progress = current
                restartTask?.cancel()
                restartTask = Task { await waitForRestart(.version) }
            } else if current.phase == "failed", current.error != nil {
                progress = current
            }
        }
        // 回退候选与保留策略（纯本地读盘，大目录统计较慢）与待更新快照并行拉取
        async let rollbackOptions = try? api.appUpdateRollbackOptions()
        // 进页预填：定时检查留下的快照（读库不触网）；读不到就退回「手动点检查更新」
        if let pending = try? await api.appUpdatePending() {
            pendingVersion = pending.appVersion.map {
                AvailableUpdate(version: $0, compatible: pending.appCompatible, changelog: pending.appChangelog, knownBad: false)
            }
            pendingModelTag = pending.modelTag
        }
        rollback = await rollbackOptions
    }

    // MARK: 进度与重启等待

    private func startPollingProgress() {
        pollTask?.cancel()
        pollTask = Task {
            var failStreak = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                do {
                    let current = try await api.appUpdateProgress()
                    failStreak = 0
                    progress = current
                    if current.phase == "failed" { return }
                    if current.phase == "restarting" {
                        await waitForRestart(.version)
                        return
                    }
                    if current.phase == "idle" {
                        // 活跃阶段之后读到 idle = 后端已重启完毕（新进程进度为空）：更新已生效
                        await finishRestart()
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // 连续 3 次失败才认定「后端进入重启」，单次瞬时错误（反代 502、网络抖动）继续轮询
                    failStreak += 1
                    if failStreak >= 3 {
                        await waitForRestart(.version)
                        return
                    }
                }
            }
        }
    }

    /// 先观察到服务不可达（sawDown）、再观察到恢复才算一次真实重启；
    /// 等了约 60 秒都没见到不可达也放行（重启在两次探测间隙内完成）
    private func waitForRestart(_ kind: RestartKind) async {
        restartKind = kind
        restartWait = .waiting
        var sawDown = false
        for attempt in 0 ..< 90 {
            if Task.isCancelled { return }
            do {
                _ = try await api.health()
                if sawDown || attempt >= 30 {
                    await finishRestart()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                sawDown = true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        restartWait = .timeout
    }

    /// 超时页「刷新页面」：Web 整页刷新（服务没起来就是一张打不开的页）。App 先探一次 /health，
    /// 通了才按恢复处理并提示；还没通就留在超时页如实告知，不再无条件报「应用已恢复」
    private func retryAfterTimeout() async {
        guard (try? await api.health()) != nil else {
            feedback.error(String(localized: .settingsUpdateUiStillDown))
            return
        }
        await finishRestart()
    }

    /// 服务恢复：Web 整页刷新，App 重新拉取本页全部数据
    private func finishRestart() async {
        restartWait = .idle
        progress = nil
        check = nil
        modelCheck = nil
        await initialLoad()
        feedback.success(String(localized: .settingsUpdateUiRecovered))
    }

    private static var restartCopy: [RestartKind: [RestartWait: (String, String)]] {
        [
        .version: [
            .waiting: (String(localized: .settingsUpdateUiVersionWaiting), String(localized: .settingsUpdateUiVersionWaitingHint)),
            .timeout: (String(localized: .settingsUpdateUiRestartTimeout), String(localized: .settingsUpdateUiVersionTimeoutHint)),
        ],
        .app: [
            .waiting: (String(localized: .settingsUpdateUiAppWaiting), String(localized: .settingsUpdateUiAppWaitingHint)),
            .timeout: (String(localized: .settingsUpdateUiRestartTimeout), String(localized: .settingsUpdateUiAppTimeoutHint)),
        ],
        ]
    }

    /// 重启等待态：全区替换为状态页，避免服务不可用期间继续操作
    private var restartWaitingView: some View {
        let copy = Self.restartCopy[restartKind]?[restartWait] ?? ("", "")
        return SettingsFormSection {
            VStack(spacing: 10) {
                if restartWait == .waiting { ProgressView() }
                Text(copy.0).font(.body.weight(.medium))
                Text(copy.1).font(.subheadline).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                if restartWait == .timeout {
                    Button(String(localized: .settingsUpdateUiRefresh)) { Task { await retryAfterTimeout() } }.buttonStyle(.glass)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("restart-waiting")
    }

    // MARK: 内容

    @ViewBuilder
    private func content(_ status: API.UpdateStatusView) -> some View {
        let availableModelTag: String? = modelCheck.map { $0.updateAvailable && $0.installable ? $0.latestTag : nil } ?? pendingModelTag
        let sourceLabel = status.codeSource == "overlay"
            ? String(localized: .settingsUpdateUiSourceOverlay)
            : status.codeSource == "baseline" ? String(localized: .settingsUpdateUiBaselineSource) : String(localized: .settingsUpdateUiDevSource)

        SettingsFormSection {
            HStack(spacing: 16) {
                Image("MovieClawLogo").resizable().scaledToFit().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: .settingsUpdateUiServerTitle)).font(.headline)
                    Text("v\(status.currentVersion)").font(.title2.weight(.semibold))
                        .accessibilityIdentifier("app-current-version")
                    Text(sourceLabel).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            if status.canUpdate, !updating {
                Button { Task { await doCheck() } } label: {
                    HStack {
                        Text(checking ? String(localized: .settingsUpdateUiChecking) : String(localized: .settingsUpdateUiCheck))
                        Spacer()
                        if checking { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                }.disabled(checking).accessibilityIdentifier("app-check-update")
            }
            if let check, !check.updateAvailable {
                Label(String(localized: .settingsUpdateUiLatest), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            }
            if let checkError { Text(checkError).font(.subheadline).foregroundStyle(Theme.danger) }
            if !status.canUpdate {
                Text(String(localized: .settingsUpdateUiSourceHint))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let inactive = status.inactiveOverlayVersion {
                Text(String(localized: .settingsUpdateUiInactiveInstalled(inactive)) + (status.inactiveOverlayReason.map { String(localized: .settingsUpdateUiReasonSuffix($0)) } ?? ""))
                    .font(.subheadline).foregroundStyle(Theme.textMuted)
            }
            if !status.badVersions.isEmpty {
                Text(String(localized: .settingsUpdateUiBadVersionsList(AppFormatting.list(status.badVersions.map { "v\($0)" }))))
                    .font(.subheadline).foregroundStyle(Theme.warning)
            }
            if let exit = status.lastAbnormalExit {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: .settingsUpdateUiAbnormalExit(SettingsTime.unix(exit.at), exit.detail, String(exit.exitCode))))
                        .font(.subheadline).foregroundStyle(Theme.warning)
                    HStack {
                        Spacer()
                        Button(String(localized: .settingsLlmUiUnderstood)) { Task { await dismissExit() } }
                            .buttonStyle(.glass).controlSize(.small)
                            .accessibilityIdentifier("app-dismiss-exit")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("app-abnormal-exit")
            }
        }

        if updating, let progress {
            SettingsFormSection {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progress.detail.isEmpty ? String(localized: .settingsUpdateUiUpdating) : progress.detail).font(.body.weight(.medium))
                    if progress.phase == "downloading", let percent = progress.percent {
                        ProgressView(value: min(max(percent, 0), 100), total: 100).tint(Theme.accent)
                    }
                    Text(String(localized: .settingsUpdateUiUpdatingHint)).font(.subheadline).foregroundStyle(Theme.textMuted)
                }
            }
        }

        if !updating, let available {
            SettingsFormSection(String(localized: .settingsUpdateUiAvailable)) {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent(String(localized: .settingsUpdateUiNewVersion), value: "v\(available.version)")
                    if !available.compatible {
                        Text(String(localized: .settingsUpdateUiDependencyHint))
                            .font(.subheadline).foregroundStyle(Theme.warning)
                    }
                    if available.knownBad {
                        Text(String(localized: .settingsUpdateUiFailedBefore))
                            .font(.subheadline).foregroundStyle(Theme.warning)
                    }
                    if !available.changelog.isEmpty {
                        Button { changelogOpen = true } label: {
                            HStack {
                                Text(String(localized: .settingsUpdateUiNotes))
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("app-changelog")
                    }
                    if available.compatible {
                        Button { Task { await doApply() } } label: {
                            Text(String(localized: .settingsUpdateUiUpdateRestart)).frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .settingsProminentButton()
                        .accessibilityIdentifier("app-apply-update")
                    }
                }.padding(.vertical, 8)
            }
        }
        if let actionError {
            SettingsFormSection { SettingsNotice(text: actionError) }
        }

        // 上一次更新（应用或模型）异步失败的统一外显
        if let progress, progress.phase == "failed", let error = progress.error {
            SettingsFormSection {
                Text(progress.targetVersion.map { String(localized: .settingsUpdateUiLastFailedVersion($0, error)) } ?? String(localized: .settingsUpdateUiLastFailed(error)))
                    .font(.subheadline).foregroundStyle(Theme.danger)
            }
        }

        if status.canUpdate {
            SettingsFormSection {
                LabeledContent(String(localized: .settingsUpdateUiCurrentModel), value: status.modelTag ?? String(localized: .settingsUpdateUiUnknownModel))
                if !updating {
                    Button { Task { await doModelCheck() } } label: {
                        HStack {
                            Text(modelChecking ? String(localized: .settingsUpdateUiChecking) : String(localized: .settingsUpdateUiCheckModel))
                            Spacer()
                            if modelChecking { ProgressView() }
                        }
                    }.disabled(modelChecking).accessibilityIdentifier("app-check-model")
                }
                if let availableModelTag {
                    LabeledContent(String(localized: .settingsUpdateUiNewModel), value: availableModelTag)
                    Button(String(localized: .settingsUpdateUiModelRestart)) { Task { await doModelApply() } }
                        .disabled(updating).accessibilityIdentifier("app-apply-model")
                }
                if let modelCheck, availableModelTag == nil {
                    Text(modelCheck.updateAvailable
                         ? String(localized: .settingsUpdateUiModelNotInstallable) : String(localized: .settingsUpdateUiModelLatest))
                        .foregroundStyle(modelCheck.updateAvailable ? Theme.warning : Theme.success)
                }
                if let modelError { Text(modelError).font(.subheadline).foregroundStyle(Theme.danger) }
            } header: { Text(String(localized: .settingsUpdateUiModelSection)) }
              footer: { Text(String(localized: .settingsUpdateUiModelHint)) }
        }
        if status.canUpdate, let rollback {
            SettingsFormSection {
                Button { actionError = nil; rollbackOpen = true } label: {
                    HStack {
                        Label(String(localized: .settingsUpdateUiHistory), systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                        Spacer()
                        Text(String(localized: .settingsMcpControlsCountUnit(rollback.targets.count))).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.disabled(updating).accessibilityIdentifier("app-open-rollback")
            }
        }
    }

    // MARK: 动作

    private func dismissExit() async {
        do {
            try await api.appUpdateLastExitDismiss()
            if case var .loaded(value) = status {
                value.lastAbnormalExit = nil
                status = .loaded(value)
            }
        } catch {
            actionError = String(localized: .settingsUpdateUiDismissFailed)
        }
    }

    private func doCheck() async {
        checking = true
        checkError = nil
        check = nil
        defer { checking = false }
        do { check = try await api.appUpdateCheck() } catch { checkError = error.localizedDescription }
    }

    private func doApply() async {
        guard !updating else { return }
        actionBusy = true
        defer { actionBusy = false }
        actionError = nil
        do {
            progress = try await api.appUpdateApply()
            startPollingProgress()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func doModelCheck() async {
        modelChecking = true
        modelError = nil
        modelCheck = nil
        defer { modelChecking = false }
        do { modelCheck = try await api.appUpdateModelCheck() } catch { modelError = error.localizedDescription }
    }

    private func doModelApply() async {
        guard !updating else { return }
        actionBusy = true
        defer { actionBusy = false }
        modelError = nil
        do {
            progress = try await api.appUpdateModelApply()
            startPollingProgress()
        } catch {
            modelError = error.localizedDescription
        }
    }

    /// 执行回退：restore 由目标的数据兼容判定决定
    private func doRollback(_ target: API.RollbackTargetView) async {
        actionError = nil
        do {
            try await api.appUpdateRollback(body: .init(
                target: target.kind == "baseline" ? "baseline" : (target.version ?? ""),
                restoreBackup: target.schemaAction == "restore"
            ))
            await waitForRestart(.version)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// 重启应用：请求后端优雅停机，随后走与更新同一套等待流程（请求可能因进程退出而中断，属预期）
    private func doRestart() async {
        let ok = await feedback.confirm(
            String(localized: .settingsUpdateUiRestartTitle),
            message: String(localized: .settingsUpdateUiRestartConfirmHint),
            confirmTitle: String(localized: .settingsUpdateUiRestartConfirm),
            destructive: true
        )
        guard ok else { return }
        Task { try? await api.appRestart() }
        await waitForRestart(.app)
    }

    /// 调整本地保留版本数（立即生效并按新策略清理），清理后占用与候选都可能变化，重拉一次
    private func setRetention(_ value: Int) async {
        guard let rollback, !retentionBusy else { return }
        let next = min(20, max(2, value))
        guard next != rollback.keepVersions else { return }
        retentionBusy = true
        actionError = nil
        defer { retentionBusy = false }
        do {
            try await api.appUpdateRetention(body: .init(keepVersions: next))
            self.rollback = try await api.appUpdateRollbackOptions()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - 回退选择器

/// 候选版本（新的在前）→ 选中展开详情（数据后果 + 更新说明）→ 底部写明落点与数据后果的确认按钮
private struct RollbackSheet: View {
    let options: API.RollbackOptionsView?
    let retentionBusy: Bool
    let error: String?
    let onRetention: (Int) async -> Void
    let onConfirm: (API.RollbackTargetView) -> Void
    @State private var selected: Int?

    private func label(_ target: API.RollbackTargetView) -> String {
        target.kind == "baseline" ? String(localized: .settingsUpdateUiBaselineVersion(target.version.map { " v\($0)" } ?? "")) : "v\(target.version ?? "")"
    }

    var body: some View {
        let targets = options?.targets ?? []
        let pick = selected.flatMap { index in targets.indices.contains(index) ? targets[index] : nil }
        SubsSheetScaffold(title: String(localized: .settingsUpdateUiHistory), closeTitle: String(localized: .commonDone)) {
            if let error { SettingsFormSection { Text(error).foregroundStyle(Theme.danger) } }
            if let options {
                SettingsFormSection {
                    Stepper(value: Binding(get: { options.keepVersions }, set: { value in
                        selected = nil
                        Task { await onRetention(value) }
                    }), in: 2 ... 20) {
                        LabeledContent(String(localized: .settingsUpdateUiKeepVersions), value: String(localized: .settingsMcpControlsCountUnit(options.keepVersions)))
                    }.disabled(retentionBusy).accessibilityIdentifier("app-retention")
                } footer: {
                    Text(String(localized: .settingsUpdateUiStorageHint(Formatters.bytes(options.versionsDirBytes))))
                }
            }
            if targets.isEmpty {
                SettingsFormSection { Text(String(localized: .settingsUpdateUiNoHistory)).foregroundStyle(.secondary) }
            }
            SettingsFormSection {
                // 说明在标题下方、列表之前（同 Web 回退弹窗的头部说明）
                Text(String(localized: .settingsUpdateUiRollbackHint))
                    .font(.subheadline).foregroundStyle(Theme.textMuted)
                    .settingsRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            SettingsFormSection {
                ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation { selected = selected == index ? nil : index }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(label(target)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                    schemaBadge(target)
                                    let meta = [target.installedAt.map { String(localized: .settingsUpdateUiInstalledAt(Formatters.dateTime($0))) },
                                                target.sizeBytes.map { Formatters.bytes($0) }].compactMap { $0 }
                                    if !meta.isEmpty {
                                        Text(meta.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textFaint)
                                    }
                                }
                                Spacer()
                                Image(systemName: selected == index ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected == index ? Theme.accentStrong : Theme.textFaint)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("rollback-target-\(index)")
                        if selected == index {
                            Text(consequence(target)).font(.subheadline).foregroundStyle(color(target))
                            if let changelog = target.changelog, !changelog.isEmpty {
                                ScrollView { SettingsMarkdownText(text: changelog) }.frame(maxHeight: 192)
                            }
                        }
                    }
                }
            }
            if let pick {
              SettingsFormSection {
                Button(role: .destructive) {
                    onConfirm(pick)
                } label: {
                    Text(pick.schemaAction == "restore" ? String(localized: .settingsUpdateUiRollbackRestore(label(pick))) : String(localized: .settingsUpdateUiRollbackRestart(label(pick))))
                        .frame(maxWidth: .infinity)
                }
                .disabled(retentionBusy)
                .accessibilityIdentifier("rollback-confirm")
              }
            }
        }
    }

    @ViewBuilder
    private func schemaBadge(_ target: API.RollbackTargetView) -> some View {
        switch target.schemaAction {
        case "switch": Text(String(localized: .settingsUpdateUiSwitchSafe)).font(.caption).foregroundStyle(Theme.success)
        case "restore": Text(String(localized: .settingsUpdateUiRestoreBackup(Formatters.dateTime(target.backupTakenAt)))).font(.caption).foregroundStyle(Theme.warning)
        default: Text(String(localized: .settingsUpdateUiBackupMissing)).font(.caption).foregroundStyle(Theme.danger)
        }
    }

    private func consequence(_ target: API.RollbackTargetView) -> String {
        switch target.schemaAction {
        case "switch": String(localized: .settingsUpdateUiSwitchSafeHint)
        case "restore": String(localized: .settingsUpdateUiRestoreHint(Formatters.dateTime(target.backupTakenAt)))
        default: String(localized: .settingsUpdateUiNoBackup)
        }
    }

    private func color(_ target: API.RollbackTargetView) -> Color {
        switch target.schemaAction {
        case "switch": Theme.success
        case "restore": Theme.warning
        default: Theme.danger
        }
    }
}

// MARK: - 更新说明

/// 更新说明（新版本卡片与回退候选共用）
struct SettingsMarkdownText: View {
    let text: String

    /// 更新说明是 GitHub Release 的 Markdown 原文：与 Web 一样复用全站的 Markdown 渲染器（紧凑档），
    /// 代码块、表格、有序列表都按结构排版，不再退化成纯文本
    var body: some View {
        AgentMarkdownView(text: text, size: 14)
    }
}
