import SwiftUI

/// 字幕行里的「AI 生成字幕」入口（对应 Web `components/subtitle-gen-panel.tsx`）。
///
/// 交互分成两个明确阶段（与 Web 一致）：
/// 1. 点击后先做**预检**（不调用 LLM）：在弹层里讲清参考字幕、目标语言、输出文件与预计成本；
/// 2. 用户确认后才启动后台任务。
///
/// 任务状态的数据源：Web 用全站 JobsProvider（首屏快照 + `/jobs/stream` SSE 即时刷新 +
/// 15 秒低频轮询兜底）。App 没有全站任务仓库，这里就按同一口径只盯「这个文件的字幕生成任务」：
/// SSE 收到 `ready`/`job` 事件后合并成一次查询（120ms 去抖），另挂 15 秒兜底轮询。
/// 因此 Web、CLI、Agent 发起的任务在这里呈现完全一致。
///
/// 可见条件：仅管理员、且文件在盘（Web `!isAdmin || file.missing` 时不渲染）；
/// 未接入任何 AI 模型时，按钮换成「去接入」引导（Web LlmCapabilityGate）。
struct TrackSubtitleGenButton: View {
    let file: API.LibraryFileView
    /// 产物落盘后回调（详情页借此重拉字幕清单，新字幕立刻可见）
    var onChanged: () async -> Void = {}

    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Router.self) private var router
    @State private var model = TrackGenModel()

    var body: some View {
        if permissions.isAdmin, !file.missing {
            entry
                .task(id: file.id) {
                    model.onChanged = onChanged
                    await model.refreshJob(api: api, fileId: file.id)
                    await model.watchJobs(api: api, fileId: file.id)
                }
                .task { await model.checkLlm(api: api) }
                .polling(every: 15) { await model.refreshJob(api: api, fileId: file.id) }
                // 用布尔而非 item 绑定：状态弹层里点「重新预检」会原地切到预检模式，
                // item 身份一变 SwiftUI 就会关掉重开，onDismiss 会把刚发出的预检掐掉
                .sheet(
                    isPresented: Binding(mcGet: { model.mode != nil }, set: { if !$0 { model.mode = nil } }),
                    onDismiss: { model.stopPreview() }
                ) {
                    TrackGenSheet(model: model, file: file)
                }
        }
    }

    /// 入口：运行中 / 未完成时总是显示状态按钮；空闲时受 LLM 能力门禁约束
    @ViewBuilder
    private var entry: some View {
        if model.running || model.hasTerminalIssue {
            badgeButton
        } else {
            switch model.llm {
            case .checking:
                // 检查中不短暂露出触发按钮（同 Web）。用零尺寸占位而不是 EmptyView：
                // EmptyView 不进视图树，挂在它上面的 .task（能力探测、任务跟踪）永远不会启动
                Color.clear.frame(width: 0, height: 0)
            case .missing:
                Button {
                    router.open(.settingsSection(.llm))
                } label: {
                    (Text(String(localized: .librarySubtitleGenerationUnlockWithModel)) + Text(String(localized: .settingsLlmConnectModel)).foregroundStyle(Theme.accent))
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.warning.opacity(0.1), in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.warning.opacity(0.3)))
                        .expandedHitArea(vertical: 10)
                }
                .buttonStyle(.plain)
            case .configured, .unavailable:
                // 探测失败按 fail-open 处理，交给后端预检兜底
                badgeButton
            }
        }
    }

    /// 与语言芯片同一副骨架，只靠描边把「可点的动作」与「只读的标签」区分开
    private var badgeButton: some View {
        let generated = file.subtitleStreams.contains { $0.external && TrackGenText.isAiSubtitle($0.fileName) }
        let style = model.badgeStyle(generated: generated)
        let text = model.badgeLabel(generated: generated)
        return Button {
            model.openAction(api: api, fileId: file.id)
        } label: {
            HStack(spacing: 6) {
                if model.running {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .symbolEffect(.pulse)
                } else {
                    Image(systemName: "wand.and.stars").font(.caption)
                }
                Text(text).lineLimit(1)
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(style.background, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(style.border))
            .expandedHitArea(vertical: 6)
        }
        .buttonStyle(.plain)
        .disabled(model.previewing)
        .opacity(model.previewing ? 0.5 : 1)
        .accessibilityLabel(model.running ? "\(text)，\(model.job?.progress.message.nonEmpty ?? String(localized: .librarySubtitleGenerationRunning))" : text)
    }
}

// MARK: - 状态模型

/// 生成面板的全部状态与动作。按钮与弹层共用一份，弹层关掉再打开时语言选择不丢（同 Web）。
@Observable
private final class TrackGenModel {
    enum Mode: String, Identifiable {
        case preview, status
        var id: String { rawValue }
    }

    enum LlmState { case checking, configured, missing, unavailable }

    struct BadgeStyle {
        var foreground: Color
        var background: Color
        var border: Color
    }

    // 输出选择
    var targetLanguage = "chs"
    var bilingual = false
    var secondaryLanguage = "eng"
    var sourceCandidateKey: String?
    var pgsOcrLanguage = ""

    // 预检
    var preview: API.GenPreviewView?
    var previewing = false
    /// 内封轨正在后台抽取时的等待文案；非空即「还没有结论，不是出错了」
    var pendingNotice: String?
    var requestError: String?

    // 弹层与动作
    var mode: Mode?
    var starting = false
    var stopping = false
    var agentStarting = false

    // 任务
    var job: API.JobView?
    var llm: LlmState = .checking
    var onChanged: () async -> Void = {}

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSeq = 0
    @ObservationIgnored private var refreshScheduled = false

    static let runningStatuses: Set<String> = ["queued", "running", "retry_wait", "cancelling", "waiting"]

    var running: Bool { job.map { Self.runningStatuses.contains($0.status) } ?? false }
    var hasTerminalIssue: Bool { ["blocked", "failed", "cancelled"].contains(job?.status ?? "") }
    var jobSucceeded: Bool { job?.status == "succeeded" }
    var progress: TrackGenProgress? { job.map(TrackGenProgress.init) }

    // MARK: 徽章

    func badgeStyle(generated: Bool) -> BadgeStyle {
        if previewing { return Self.idleStyle }
        if running {
            return BadgeStyle(foreground: Theme.info, background: Theme.info.opacity(0.12), border: Theme.info.opacity(0.3))
        }
        if generated || jobSucceeded { return Self.idleStyle }
        if hasTerminalIssue {
            let red = Color(red: 1, green: 0.62, blue: 0.62)
            return BadgeStyle(foreground: Color(red: 1, green: 0.71, blue: 0.71), background: red.opacity(0.07), border: red.opacity(0.25))
        }
        return Self.idleStyle
    }

    private static let idleStyle = BadgeStyle(
        foreground: Color.white.opacity(0.75), background: .clear, border: Color.white.opacity(0.16)
    )

    func badgeLabel(generated: Bool) -> String {
        // 已经生成过也不改口称「新建 AI 版本」：用户要的答案始终是同一句「让 AI 给这个片子做字幕」
        var text = String(localized: .mediaSubtitlesGenerateBadge)
        if previewing {
            text = String(localized: .mediaSubtitlesCheckingBadge)
        } else if running {
            text = TrackGenText.runningBadgeText(progress)
        } else if generated || jobSucceeded {
            // 生成成功过的文件即便带着历史失败记录，也不该再顶着红色的未完成态
        } else if hasTerminalIssue {
            text = String(localized: .mediaSubtitlesUnfinishedBadge)
        }
        return running ? "\(activeOutputLabel) · \(text)" : text
    }

    /// 运行中 / 结束态报的目标输出：以任务入参为准（Agent、CLI 发起的任务也看得到）
    var activeOutputLabel: String {
        let target = progress?.targetLanguage.flatMap { $0.isEmpty ? nil : $0 } ?? targetLanguage
        return TrackGenText.outputLabel(target, progress?.secondaryLanguage)
    }

    var currentOutputLabel: String {
        TrackGenText.outputLabel(targetLanguage, bilingual ? secondaryLanguage : nil)
    }

    // MARK: 打开

    func openAction(api: APIClient, fileId: Int) {
        if running || hasTerminalIssue {
            mode = .status
            return
        }
        loadPreview(api: api, fileId: fileId)
    }

    // MARK: 预检

    /// 收掉在途预检：中断请求、停止 pending 轮询。换轨、改语言、关弹层都要真的把上一条掐掉——
    /// 否则拨一下「双语」开关，后端就会对同一个大文件再起一个 ffmpeg（issue #432）。
    /// 后端的抽取任务不受影响，会继续抽完落缓存，下次秒开。
    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewing = false
        pendingNotice = nil
    }

    func loadPreview(api: APIClient, fileId: Int, sourceKey: String? = nil) {
        previewTask?.cancel()
        let target = targetLanguage
        let secondary = bilingual ? secondaryLanguage : nil
        mode = .preview
        preview = nil
        pgsOcrLanguage = ""
        requestError = nil
        pendingNotice = nil
        previewing = true
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await api.trackRowsGenerationPreview(
                        fileId: fileId, targetLanguage: target, secondaryLanguage: secondary, sourceCandidateKey: sourceKey
                    )
                    guard let self, !Task.isCancelled else { return }
                    if let pending = result.pending {
                        // 只有旧版服务端会回 pending（新版预检不读视频，没读过的内封轨
                        // 带 referenceNotice 当场给结论）：保持「正在检查」并按间隔重拉。
                        // 这里**不能**写入 preview——那份快照里 chosen/blocker 都是空的，
                        // 渲染出来就成了「这份片源没有参考字幕」，与事实相反。
                        self.pendingNotice = pending.message
                        try? await Task.sleep(for: .milliseconds(max(1000, pending.retryAfterMs)))
                        continue
                    }
                    self.pendingNotice = nil
                    self.preview = result
                    self.sourceCandidateKey = result.selectedSourceKey
                    self.pgsOcrLanguage = result.pgsConversion?.ocrLanguage ?? ""
                    self.previewing = false
                    return
                } catch {
                    // 主动取消（换轨 / 关弹层 / 离开页面）不是错误，别弹红框
                    guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                    self.pendingNotice = nil
                    self.requestError = error.localizedDescription
                    self.previewing = false
                    return
                }
            }
        }
    }

    func changeTarget(_ target: String, api: APIClient, fileId: Int) {
        targetLanguage = target
        secondaryLanguage = TrackGenText.nextSecondary(target: target, current: secondaryLanguage)
        loadPreview(api: api, fileId: fileId)
    }

    func changeSecondary(_ secondary: String, api: APIClient, fileId: Int) {
        secondaryLanguage = secondary
        loadPreview(api: api, fileId: fileId)
    }

    func changeBilingual(_ enabled: Bool, api: APIClient, fileId: Int) {
        bilingual = enabled
        secondaryLanguage = TrackGenText.nextSecondary(target: targetLanguage, current: secondaryLanguage)
        loadPreview(api: api, fileId: fileId)
    }

    // MARK: 预检结论的派生量

    var chosen: API.SourceCandidateView? {
        preview?.candidates.first { TrackGenText.candidateKey($0) == preview?.chosenKey }
    }

    var selectedCandidate: API.SourceCandidateView? {
        preview?.candidates.first { TrackGenText.candidateKey($0) == preview?.selectedSourceKey }
    }

    var canPreparePgs: Bool {
        preview?.blocker?.code == "pgs_conversion_required" && preview?.pgsConversion?.available == true
    }

    var canConvertPgs: Bool {
        let languageReady = !(preview?.pgsConversion?.languageConfirmationRequired ?? false) || !pgsOcrLanguage.isEmpty
        return canPreparePgs && languageReady
    }

    /// 预检没通过（且不是可转换的 PGS）
    var blockedWithoutPgs: Bool { preview?.blocker != nil && !canPreparePgs }

    // MARK: 启动 / 停止

    func start(api: APIClient, fileId: Int) async {
        starting = true
        requestError = nil
        defer { starting = false }
        let convertPgs = canPreparePgs
        do {
            let started = try await api.librarySubtitlesGenerate(fileId: fileId, body: API.GenStartPayload(
                targetLanguage: targetLanguage,
                secondaryLanguage: bilingual ? secondaryLanguage : nil,
                sourceCandidateKey: sourceCandidateKey,
                convertPgs: convertPgs,
                pgsOcrLanguage: convertPgs && !pgsOcrLanguage.isEmpty ? pgsOcrLanguage : nil
            ))
            apply(started)
            mode = nil
        } catch is CancellationError {
        } catch {
            // 确认到真正入队之间文件可能变化，错误留在弹层里让用户看清
            requestError = error.localizedDescription
        }
    }

    func stop(api: APIClient) async {
        guard let jobId = job?.id else { return }
        stopping = true
        requestError = nil
        defer { stopping = false }
        do {
            apply(try await api.jobsCancel(jobId: jobId).job)
        } catch is CancellationError {
        } catch {
            requestError = error.localizedDescription
        }
    }

    // MARK: 交给 Agent

    /// 「交给 Agent 处理」必须把用户已经做出的选择一起带走（issue #433）：
    /// 除了人话的「期望输出」，再给一行可直接执行的 CLI 参数，别让 Agent 按默认参数重跑。
    /// 成功后返回新会话 id，由调用方跳转。
    func handOffToAgent(api: APIClient, file: API.LibraryFileView, reason: String) async -> String? {
        agentStarting = true
        requestError = nil
        defer { agentStarting = false }
        let conversion = preview?.pgsConversion
        let jobLanguage = mode == .status ? progress?.targetLanguage : nil
        let target = jobLanguage ?? targetLanguage
        let secondary = jobLanguage != nil ? progress?.secondaryLanguage : (bilingual ? secondaryLanguage : nil)
        let sourceKey = jobLanguage != nil ? progress?.sourceCandidateKey : sourceCandidateKey
        var params = "--target-language \(target)"
        if let secondary { params += " --secondary-language \(secondary)" }
        if let sourceKey { params += " --source-candidate-key \(sourceKey)" }
        var lines: [String] = [
            String(localized: .librarySubtitleGenerationAgentIntro),
            String(localized: .librarySubtitleGenerationAgentFile(file.fileName)),
            String(localized: .librarySubtitleGenerationAgentId(String(file.id))),
            String(localized: .librarySubtitleGenerationAgentPath(file.filePath)),
            String(localized: .librarySubtitleGenerationAgentOutput(TrackGenText.outputLabel(target, secondary))),
            String(localized: .librarySubtitleGenerationCliParams(params)),
            String(localized: .librarySubtitleGenerationAgentIssue(reason)),
        ]
        if let conversion {
            lines.append(String(localized: .librarySubtitleGenerationAgentPreflight(conversion.platform, conversion.architecture)) + (conversion.engine.map { " · \($0)" } ?? String(localized: .librarySubtitleGenerationNoEngine)))
            if !conversion.message.isEmpty { lines.append(String(localized: .librarySubtitleGenerationAgentDiagnostic(conversion.message))) }
        }
        lines += (preview?.blocker?.suggestions ?? []).map { String(localized: .librarySubtitleGenerationAgentSuggestion($0)) }
        lines.append(String(localized: .librarySubtitleGenerationAgentInstructions))
        do {
            let accepted = try await api.sessionStart(body: API.SessionStartPayload(content: lines.joined(separator: "\n")))
            mode = nil
            return accepted.sessionId
        } catch is CancellationError {
            return nil
        } catch {
            requestError = String(localized: .librarySubtitleGenerationAgentFailed(error.localizedDescription))
            return nil
        }
    }

    // MARK: 任务跟踪

    /// 合并一条任务快照；只在亲眼看到同一任务从活跃态变为成功时通知详情页重拉
    /// （初次读到历史成功任务不触发多余请求）。
    func apply(_ next: API.JobView?) {
        if let previous = job, let next, previous.id == next.id,
           Self.runningStatuses.contains(previous.status), next.status == "succeeded" {
            Task { await onChanged() }
        }
        job = next
    }

    /// 查这个文件最近的一条字幕生成任务（取 updated_at 最新，同 Web latestFor）
    func refreshJob(api: APIClient, fileId: Int) async {
        refreshSeq += 1
        let seq = refreshSeq
        do {
            let list = try await api.jobsList(
                jobType: "subtitle.generate", resourceType: "library_file", resourceId: String(fileId), limit: 5
            )
            guard seq == refreshSeq else { return }
            let latest = list.items.max { lhs, rhs in
                (Formatters.date(lhs.updatedAt) ?? .distantPast) < (Formatters.date(rhs.updatedAt) ?? .distantPast)
            }
            apply(latest)
        } catch {
            // 瞬时断线保留最近快照；SSE 重连或下一轮轮询会自动校准
        }
    }

    /// 订阅任务中心 SSE：`ready` / `job` 事件只当「有变化」的信号，合并成一次查询。
    /// 流断开（反代不支持流式、网络抖动）3 秒后重连；15 秒兜底轮询另由视图挂载。
    func watchJobs(api: APIClient, fileId: Int) async {
        while !Task.isCancelled {
            do {
                for try await event in api.events("/jobs/stream") where event.event == "ready" || event.event == "job" {
                    scheduleRefresh(api: api, fileId: fileId)
                }
            } catch {}
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func scheduleRefresh(api: APIClient, fileId: Int) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            self.refreshScheduled = false
            await self.refreshJob(api: api, fileId: fileId)
        }
    }

    func checkLlm(api: APIClient) async {
        do {
            llm = try await api.llmProvidersList().isEmpty ? .missing : .configured
        } catch is CancellationError {
        } catch {
            // 探测接口异常不应误锁 AI 功能，保留服务端提交时的错误兜底
            llm = .unavailable
        }
    }
}

// MARK: - 进度快照

/// 从任务 progress.details / usage / input_data 里拍平出进度展示所需字段（同 Web subtitleProgress）
private struct TrackGenProgress {
    var phase: String
    var message: String
    var percent: Double?
    var doneBlocks: Int
    var totalBlocks: Int
    var doneEvents: Int
    var totalEvents: Int
    var activeBlocks: [Int]
    var parallelism: Int
    var oldestActiveSeconds: Int
    var validationRetries: Int
    var rateLimitCount: Int
    var modelRequests: Int
    var modelTokens: Int
    var usesOcr: Bool
    /// 读取阶段还在排队等别的文件读完（同一时间只通读一个视频）
    var extractQueued: Bool
    var targetLanguage: String?
    var secondaryLanguage: String?
    var sourceCandidateKey: String?
    var elapsedSeconds: Int

    init(job: API.JobView) {
        let details = job.progress.details
        func number(_ dict: [String: API.JSONValue], _ key: String) -> Int {
            guard let value = dict[key], let double = value.doubleValue, double.isFinite else { return 0 }
            if case .string = value { return 0 }
            return Int(double)
        }
        func string(_ key: String) -> String? {
            if let value = details[key], case let .string(text) = value, !text.isEmpty { return text }
            if let value = job.inputData[key], case let .string(text) = value { return text }
            return nil
        }
        phase = job.progress.phase
        message = job.progress.message
        percent = job.progress.percent
        doneBlocks = number(details, "done_blocks")
        totalBlocks = number(details, "total_blocks")
        doneEvents = number(details, "done_events")
        totalEvents = number(details, "total_events")
        activeBlocks = (details["active_blocks"]?.arrayValue ?? []).compactMap { value in
            switch value {
            case let .int(number): number
            case let .double(number): Int(number)
            default: nil
            }
        }
        parallelism = number(details, "parallelism")
        oldestActiveSeconds = number(details, "oldest_active_seconds")
        validationRetries = number(details, "validation_retries")
        rateLimitCount = number(details, "rate_limit_count")
        modelRequests = number(job.usage, "request_count")
        modelTokens = number(job.usage, "total_tokens")
        usesOcr = details["uses_ocr"]?.boolValue == true
        extractQueued = details["extract_queued"]?.boolValue == true
        targetLanguage = string("target_language")
        secondaryLanguage = string("secondary_language")
        sourceCandidateKey = string("source_candidate_key")
        if let started = Formatters.date(job.startedAt) {
            elapsedSeconds = max(0, Int(Date.now.timeIntervalSince(started)))
        } else {
            elapsedSeconds = 0
        }
    }

    var percentValue: Int? { percent.map { min(100, Int($0.rounded(.down))) } }

    var stageIndex: Int {
        TrackGenText.stages.firstIndex { $0.phases.contains(phase) } ?? 0
    }
}

// MARK: - 文案与格式化（逐字照搬 Web）

private enum TrackGenText {
    static let outputLanguages: [(token: String, label: String)] = [
        ("chs", String(localized: .mediaLanguagesSimplifiedChinese)), ("cht", String(localized: .mediaLanguagesTraditionalChinese)), ("eng", String(localized: .mediaLanguagesEnglish)), ("jpn", String(localized: .mediaLanguagesJapanese)),
        ("kor", String(localized: .mediaLanguagesKorean)), ("fre", String(localized: .mediaLanguagesFrench)), ("ger", String(localized: .mediaLanguagesGerman)), ("spa", String(localized: .mediaLanguagesSpanish)),
        ("ita", String(localized: .mediaLanguagesItalian)), ("por", String(localized: .mediaLanguagesPortuguese)), ("rus", String(localized: .mediaLanguagesRussian)), ("tha", String(localized: .mediaLanguagesThai)),
    ]

    static let stages: [(phases: [String], label: String)] = [
        (["preparing", "extracting", "ocr", "syncing"], String(localized: .librarySubtitleGenerationPrepareStage)),
        (["glossary"], String(localized: .librarySubtitleGenerationGlossaryStage)),
        (["translating"], String(localized: .librarySubtitleGenerationTranslateStage)),
        (["validating", "compressing"], String(localized: .librarySubtitleGenerationQualityStage)),
        (["writing", "refreshing"], String(localized: .librarySubtitleGenerationSaveStage)),
    ]

    static func outputLanguageLabel(_ token: String?) -> String {
        outputLanguages.first { $0.token == token }?.label ?? token ?? String(localized: .librarySubtitleGenerationSubtitle)
    }

    static func outputLabel(_ target: String, _ secondary: String?) -> String {
        let primary = outputLanguageLabel(target)
        guard let secondary else { return primary }
        return String(localized: .librarySubtitleGenerationBilingual(primary, outputLanguageLabel(secondary)))
    }

    static func nextSecondary(target: String, current: String) -> String {
        if target != current { return current }
        return outputLanguages.first { $0.token != target }?.token ?? "eng"
    }

    static func isAiSubtitle(_ filename: String?) -> Bool {
        guard let filename else { return false }
        return filename.lowercased().split(separator: ".").contains { $0 == "ai" || $0.hasPrefix("ai-") }
    }

    static func languageLabel(_ language: String?) -> String {
        let labels = [
            "chi": String(localized: .libraryArtworkLanguageChinese), "chs": String(localized: .mediaLanguagesSimplifiedChinese), "cht": String(localized: .mediaLanguagesTraditionalChinese), "eng": String(localized: .mediaLanguagesEnglish), "fre": String(localized: .mediaLanguagesFrench), "fra": String(localized: .mediaLanguagesFrench),
            "ger": String(localized: .mediaLanguagesGerman), "ita": String(localized: .mediaLanguagesItalian), "jpn": String(localized: .mediaLanguagesJapanese), "kor": String(localized: .mediaLanguagesKorean), "por": String(localized: .mediaLanguagesPortuguese), "rus": String(localized: .mediaLanguagesRussian),
            "spa": String(localized: .mediaLanguagesSpanish), "tha": String(localized: .mediaLanguagesThai),
        ]
        guard let language else { return String(localized: .librarySubtitleGenerationUnknownLanguage) }
        return labels[language] ?? language.uppercased()
    }

    static func formatLabel(_ format: String?) -> String {
        guard let format else { return String(localized: .librarySubtitleGenerationUnknownFormat) }
        let labels = [
            "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub", "subrip": "SRT", "srt": "SRT",
            "ass": "ASS", "ssa": "SSA", "webvtt": "VTT", "vtt": "VTT",
        ]
        return labels[format.lowercased()] ?? format.uppercased()
    }

    static func candidateLabel(_ candidate: API.SourceCandidateView) -> String {
        let embedded = candidate.kind == "embedded"
        let location = embedded ? String(localized: .librarySubtitleGenerationEmbedded) : String(localized: .librarySubtitleGenerationExternal)
        let identity = embedded ? String(localized: .librarySubtitleGenerationTrack((Int(candidate.key) ?? 0) + 1)) : candidate.key
        let conversion = candidate.requiresOcr ? String(localized: .librarySubtitleGenerationOcrSuffix) : ""
        let provenance = [
            "original": String(localized: .librarySubtitleGenerationOriginal), "pgs_ocr": String(localized: .librarySubtitleGenerationPgsOcr), "ai": String(localized: .librarySubtitleGenerationAi), "ai_bilingual": String(localized: .librarySubtitleGenerationAiBilingual),
        ][candidate.provenance] ?? candidate.provenance
        return "\(languageLabel(candidate.language)) · \(formatLabel(candidate.format)) · \(provenance) · \(location) \(identity)\(conversion)"
    }

    static func candidateKey(_ candidate: API.SourceCandidateView) -> String {
        "\(candidate.kind):\(candidate.key)"
    }

    static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "zh_CN")))
    }

    static func tokenEstimate(_ tokens: Int) -> String {
        if tokens < 1000 { return String(localized: .librarySubtitleGenerationTokenEstimate(grouped(tokens))) }
        let k = Double(tokens) / 1000
        return tokens < 10_000 ? String(localized: .librarySubtitleGenerationTokenEstimateDecimalK(String(format: "%.1f", k))) : String(localized: .librarySubtitleGenerationTokenEstimateK(String(Int(k.rounded()))))
    }

    /// 确认区的成本行：读过的字幕按实际对白估算；内封轨还没读过时按片长粗估（同 Web）
    static func costLine(_ preview: API.GenPreviewView) -> String {
        if preview.referenceNotice != nil {
            return preview.estimatedTokens > 0
                ? String(localized: .librarySubtitleGenerationRuntimeEstimate(tokenEstimate(preview.estimatedTokens)))
                : String(localized: .librarySubtitleGenerationAfterReadEstimate)
        }
        return String(localized: .librarySubtitleGenerationDialogueEstimateText(grouped(preview.eventCount), tokenEstimate(preview.estimatedTokens)))
    }

    static func elapsed(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        if safe < 60 { return String(localized: .librarySubtitleGenerationElapsedSeconds(safe)) }
        let minutes = safe / 60
        if minutes < 60 { return String(localized: .librarySubtitleGenerationElapsedMinutes(minutes, safe % 60)) }
        return String(localized: .librarySubtitleGenerationElapsedHours(minutes / 60, minutes % 60))
    }

    static func sourceKeyLabel(_ key: String?) -> String? {
        guard let key else { return nil }
        if key.hasPrefix("embedded:") {
            if let index = Int(key.dropFirst("embedded:".count)) { return String(localized: .librarySubtitleGenerationSourceTrack(String(index + 1))) }
            return String(localized: .librarySubtitleGenerationSourceEmbedded)
        }
        return key.hasPrefix("external:") ? String(key.dropFirst("external:".count)) : key
    }

    static func runningBadgeText(_ progress: TrackGenProgress?) -> String {
        let phaseLabels = [
            "preparing": String(localized: .librarySubtitleGenerationPreparing), "ocr": String(localized: .librarySubtitleGenerationRecognizing), "syncing": String(localized: .librarySubtitleGenerationSyncing), "glossary": String(localized: .librarySubtitleGenerationGlossary),
            "validating": String(localized: .librarySubtitleGenerationValidating), "compressing": String(localized: .librarySubtitleGenerationCompressing), "writing": String(localized: .librarySubtitleGenerationWriting), "refreshing": String(localized: .librarySubtitleGenerationRefreshing),
        ]
        if progress?.phase == "translating" {
            if let percent = progress?.percentValue { return "AI \(percent)%" }
            return String(localized: .librarySubtitleGenerationTranslating)
        }
        if let progress, progress.phase == "extracting" {
            if progress.extractQueued { return String(localized: .librarySubtitleGenerationQueuedRead) }
            if let percent = progress.percentValue { return String(localized: .librarySubtitleGenerationReadPercent(String(percent))) }
            return String(localized: .librarySubtitleGenerationReading)
        }
        return phaseLabels[progress?.phase ?? "preparing"] ?? String(localized: .librarySubtitleGenerationGenerating)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 弹层

/// 预检 / 任务状态弹层（Web 的同一个 Modal 两种模式）。
///
/// 与订阅类弹层同一套骨架（`SubsSheetScaffold`）：不自设背景、高度贴合内容，停在贴合高度时是系统悬浮的液态玻璃；
/// 左上 ✕ 关闭，唯一的主动作（确认生成 / 开始识别并生成）放右上 ✓；
/// 其余动作（重新检查、交给 Agent、停止生成）是列表末尾的一组行按钮，停止是红色——与「取消订阅」同一形态。
private struct TrackGenSheet: View {
    @Bindable var model: TrackGenModel
    let file: API.LibraryFileView

    @Environment(\.api) private var api
    @Environment(Router.self) private var router

    var body: some View {
        SubsSheetScaffold(
            title: title,
            subtitle: subtitle,
            closeTitle: closeTitle,
            onClose: { model.mode = nil },
            // 启动中关掉弹层会让用户以为没发出去，✕ 暂时收起（下拉关闭同理被禁用）
            closable: !(model.starting || model.agentStarting),
            confirm: confirm,
            // 预检加载中停在半高，免得先缩成一条再随结果涨回来
            ready: model.mode == .status || !model.previewing
        ) {
            if model.mode == .status {
                statusContent
            } else {
                previewContent
            }
            actionRows
        }
        .interactiveDismissDisabled(model.starting || model.agentStarting)
    }

    private var title: String {
        if model.mode == .status {
            return model.running ? String(localized: .librarySubtitleGenerationGeneratingOutput(model.activeOutputLabel)) : String(localized: .librarySubtitleGenerationTaskTitle)
        }
        return String(localized: .librarySubtitleGenerationGenerateTitle)
    }

    private var subtitle: String {
        if model.mode == .status {
            return model.running ? String(localized: .librarySubtitleGenerationBackgroundHint) : String(localized: .librarySubtitleGenerationResultHint)
        }
        return String(localized: .librarySubtitleGenerationConfirmHint)
    }

    private var closeTitle: String {
        if model.mode == .status { return String(localized: .commonClose) }
        return model.blockedWithoutPgs || model.requestError != nil ? String(localized: .commonClose) : String(localized: .commonCancel)
    }

    /// 右上 ✓：只在预检通过（或图片字幕可以先识别）时出现，读屏名说清楚要生成哪种语言
    private var confirm: SubsSheetConfirm? {
        guard model.mode != .status, !model.previewing else { return nil }
        if model.canPreparePgs {
            return SubsSheetConfirm(
                title: String(localized: .librarySubtitleGenerationStartOutput(model.currentOutputLabel)),
                enabled: model.canConvertPgs,
                busy: model.starting,
                identifier: "track-gen-start"
            ) { Task { await model.start(api: api, fileId: file.id) } }
        }
        if let preview = model.preview, preview.blocker == nil, model.chosen != nil {
            return SubsSheetConfirm(
                title: String(localized: .librarySubtitleGenerationConfirmOutput(model.currentOutputLabel)),
                busy: model.starting,
                identifier: "track-gen-start"
            ) { Task { await model.start(api: api, fileId: file.id) } }
        }
        return nil
    }

    // MARK: 状态模式

    @ViewBuilder
    private var statusContent: some View {
        if model.running, let progress = model.progress {
            Section {
                TrackGenProgressView(progress: progress)
                    .padding(.vertical, 4)
            }
        } else {
            let succeeded = model.jobSucceeded
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        // 结束态也报一句目标输出：Agent、CLI 发起的任务用户没在这里选过语言
                        Text(succeeded ? String(localized: .librarySubtitleGenerationCompleted(model.activeOutputLabel)) : String(localized: .librarySubtitleGenerationIncomplete(model.activeOutputLabel)))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Text(resultMessage)
                            .font(.subheadline)
                            .foregroundStyle(Theme.text.opacity(0.8))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                        .foregroundStyle((succeeded ? SubsTone.ok : SubsTone.error).color)
                }
            }
        }
        errorSection
    }

    private var resultMessage: String {
        guard let job = model.job else { return String(localized: .librarySubtitleGenerationEnded) }
        if let message = job.error?["message"]?.stringValue { return message }
        if case let .string(message)? = job.result?["message"] { return message }
        return String(localized: .librarySubtitleGenerationEnded)
    }

    // MARK: 预检模式

    @ViewBuilder
    private var previewContent: some View {
        outputLanguageSection

        if model.previewing {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.pendingNotice ?? String(localized: .librarySubtitleGenerationChecking))
                            .font(.subheadline)
                            .foregroundStyle(Theme.text)
                        // 内封字幕要把整个视频通读一遍，大文件是分钟级；说清楚为什么慢
                        if model.pendingNotice != nil {
                            Text(String(localized: .librarySubtitleGenerationFirstReadContinue))
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
        } else {
            if let preview = model.preview, !preview.candidates.isEmpty {
                sourceSection(preview)
            }
            if model.requestError != nil { errorSection }
            if model.canPreparePgs, let conversion = model.preview?.pgsConversion {
                pgsSections(conversion)
            }
            if model.blockedWithoutPgs, let blocker = model.preview?.blocker {
                blockerSections(blocker)
            }
            if let preview = model.preview, preview.blocker == nil, let chosen = model.chosen {
                chosenSections(preview, chosen: chosen)
            }
        }
    }

    private var outputLanguageSection: some View {
        Section {
            Picker(model.bilingual ? String(localized: .librarySubtitleGenerationFirstLanguage) : String(localized: .librarySubtitleGenerationTargetLanguage), selection: Binding(
                get: { model.targetLanguage },
                set: { model.changeTarget($0, api: api, fileId: file.id) }
            )) {
                ForEach(TrackGenText.outputLanguages, id: \.token) { Text($0.label).tag($0.token) }
            }
            if model.bilingual {
                Picker(String(localized: .librarySubtitleGenerationSecondLanguage), selection: Binding(
                    get: { model.secondaryLanguage },
                    set: { model.changeSecondary($0, api: api, fileId: file.id) }
                )) {
                    ForEach(TrackGenText.outputLanguages.filter { $0.token != model.targetLanguage }, id: \.token) {
                        Text($0.label).tag($0.token)
                    }
                }
            }
            Toggle(String(localized: .librarySubtitleGenerationGenerateBilingual), isOn: Binding(
                get: { model.bilingual },
                set: { model.changeBilingual($0, api: api, fileId: file.id) }
            ))
        } header: {
            Text(String(localized: .librarySubtitleGenerationOutputLanguage))
        } footer: {
            if model.bilingual {
                Text(String(localized: .librarySubtitleGenerationBilingualHint))
            }
        }
        .pickerStyle(.menu)
        .tint(Theme.textMuted)
        .disabled(model.starting)
    }

    /// 参考字幕用 Menu 而不是 Picker：不可用的候选也要列出来并说明原因，Picker 做不到逐项禁用
    private func sourceSection(_ preview: API.GenPreviewView) -> some View {
        let anySelectable = preview.candidates.contains { $0.selectable }
        let current = preview.candidates.first { TrackGenText.candidateKey($0) == model.sourceCandidateKey }
        return Section {
            Menu {
                ForEach(preview.candidates, id: \.self) { candidate in
                    let key = TrackGenText.candidateKey(candidate)
                    Button {
                        model.loadPreview(api: api, fileId: file.id, sourceKey: key)
                    } label: {
                        let text = TrackGenText.candidateLabel(candidate)
                            + (candidate.selectable ? "" : String(localized: .librarySubtitleGenerationUnavailableCandidate(candidate.excluded ?? String(localized: .librarySubtitleGenerationUnsupported))))
                        if key == model.sourceCandidateKey {
                            Label(text, systemImage: "checkmark")
                        } else {
                            Text(text)
                        }
                    }
                    .disabled(!candidate.selectable)
                }
            } label: {
                HStack {
                    Text(current.map(TrackGenText.candidateLabel) ?? String(localized: .librarySubtitleGenerationNoReference))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                .contentShape(.rect)
            }
            .disabled(model.starting || !anySelectable)
            if model.selectedCandidate?.requiresOcr == true {
                SubsNoticeRow(text: String(localized: .librarySubtitleGenerationImageSelected), tone: .warn)
            }
        } header: {
            Text(String(localized: .librarySubtitleGenerationReferenceLanguage))
        } footer: {
            Text(String(localized: .librarySubtitleGenerationSourceHint))
        }
    }

    @ViewBuilder
    private func pgsSections(_ conversion: API.PgsConversionView) -> some View {
        Section {
            SubsNoticeRow(
                text: String(localized: .librarySubtitleGenerationImageHint(model.currentOutputLabel)),
                tone: .warn
            )
        } header: {
            Text(conversion.languageConfirmationRequired ? String(localized: .librarySubtitleGenerationChooseOriginal) : String(localized: .librarySubtitleGenerationRecognizeFirst))
        }
        Section {
            if conversion.languageConfirmationRequired {
                Picker(String(localized: .librarySubtitleGenerationOriginalLanguage), selection: $model.pgsOcrLanguage) {
                    if !conversion.languageOptions.contains(where: { $0.code == model.pgsOcrLanguage }) {
                        Text(String(localized: .librarySubtitleGenerationChoose)).tag(model.pgsOcrLanguage)
                    }
                    ForEach(conversion.languageOptions, id: \.code) { Text($0.label).tag($0.code) }
                }
                .pickerStyle(.menu)
                .tint(Theme.textMuted)
            } else {
                LabeledContent(String(localized: .librarySubtitleGenerationOriginalLanguage), value: conversion.ocrLanguageLabel ?? String(localized: .librarySubtitleGenerationAutoDetected))
            }
        } footer: {
            Text((conversion.languageConfirmationRequired ? String(localized: .librarySubtitleGenerationActualLanguageHint) : "")
                + String(localized: .librarySubtitleGenerationOcrHint))
        }
    }

    @ViewBuilder
    private func blockerSections(_ blocker: API.GenPreviewBlockerView) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(blocker.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(blocker.message).font(.subheadline).foregroundStyle(Theme.text.opacity(0.8))
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(SubsTone.error.color)
            }
        }
        if !blocker.suggestions.isEmpty {
            Section(String(localized: .librarySubtitleGenerationSuggestions)) {
                ForEach(blocker.suggestions, id: \.self) { suggestion in
                    Text(suggestion)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text.opacity(0.85))
                }
            }
        }
        if let conversion = model.preview?.pgsConversion {
            Section {
                DisclosureGroup(String(localized: .librarySubtitleGenerationDiagnostics)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: .librarySubtitleGenerationRuntimeEnvironment(conversion.platform, conversion.architecture)) + (conversion.engine.map { " · \($0)" } ?? String(localized: .librarySubtitleGenerationNoEngine)))
                        if conversion.message != blocker.message {
                            Text(conversion.message)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(Theme.textMuted)
            }
        }
    }

    @ViewBuilder
    private func chosenSections(_ preview: API.GenPreviewView, chosen: API.SourceCandidateView) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text(TrackGenText.candidateLabel(chosen)).foregroundStyle(Theme.text))\(Text("  →  ").foregroundStyle(Theme.textFaint))\(Text(model.currentOutputLabel).foregroundStyle(Theme.info))")
                    .font(.subheadline.weight(.semibold))
                Text(TrackGenText.costLine(preview))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        } footer: {
            Text(String(localized: .librarySubtitleGenerationOutputNamed(preview.outputFilename ?? String(localized: .librarySubtitleGenerationDefaultOutputName))))
        }
        // 内封字幕首次使用：说清楚任务第一步要通读整个视频、可能要几分钟、这一步不花钱
        if let notice = preview.referenceNotice {
            Section {
                SubsNoticeRow(text: notice, tone: .info)
            }
        }
        if preview.alreadyGenerated {
            Section {
                SubsNoticeRow(text: String(localized: .librarySubtitleGenerationOverwrite), tone: .warn)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = model.requestError {
            Section {
                SubsNoticeRow(text: error, tone: .error)
            }
        }
    }

    // MARK: 列表末尾的行按钮（主动作在右上 ✓，关闭在左上 ✕）

    @ViewBuilder
    private var actionRows: some View {
        if model.mode == .status {
            if model.running {
                Section {
                    Button(role: .destructive) {
                        Task { await model.stop(api: api) }
                    } label: {
                        busyLabel(model.stopping ? String(localized: .librarySubtitleGenerationStopping) : String(localized: .librarySubtitleGenerationStop), busy: model.stopping)
                    }
                    .disabled(model.stopping)
                }
            } else if !model.jobSucceeded {
                Section {
                    Button(String(localized: .librarySubtitleGenerationRetryPreview)) { model.loadPreview(api: api, fileId: file.id) }
                    agentRow(reason: resultMessage)
                }
            }
        } else if !model.previewing {
            let blocked = model.blockedWithoutPgs
            let recheck = blocked || (model.preview == nil && model.requestError != nil)
            let agent = blocked || model.requestError != nil
            if recheck || agent {
                Section {
                    if recheck {
                        Button(String(localized: .librarySubtitleGenerationRecheck)) { model.loadPreview(api: api, fileId: file.id) }
                    }
                    if agent {
                        agentRow(reason: model.requestError ?? model.preview?.blocker?.message ?? String(localized: .librarySubtitleGenerationPreflightFailed))
                    }
                }
            }
        }
    }

    private func agentRow(reason: String) -> some View {
        Button {
            Task {
                if let sessionId = await model.handOffToAgent(api: api, file: file, reason: reason) {
                    router.open(.session(id: sessionId))
                }
            }
        } label: {
            busyLabel(model.agentStarting ? String(localized: .librarySubtitleGenerationHandingOff) : String(localized: .librarySubtitleGenerationHandoff), busy: model.agentStarting)
        }
        .disabled(model.agentStarting)
    }

    private func busyLabel(_ text: String, busy: Bool) -> some View {
        HStack {
            Text(text)
            Spacer()
            if busy { ProgressView() }
        }
    }
}

/// 运行中的进度详情：消息 + 百分比条 + 计数 + 五个阶段（同 Web ProgressDetails）
private struct TrackGenProgressView: View {
    let progress: TrackGenProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(progress.message.isEmpty ? String(localized: .librarySubtitleGenerationPreparingTask) : progress.message)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if let percent = progress.percentValue {
                    Text("\(percent)%").font(.callout.weight(.semibold).monospacedDigit())
                }
            }
            .foregroundStyle(Theme.info)

            if let percent = progress.percentValue {
                ProgressView(value: Double(percent), total: 100).tint(Theme.info)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Theme.info)
            }

            TrackFlowLayout(spacing: 14, lineSpacing: 4) {
                if progress.totalBlocks > 0 { Text(String(localized: .librarySubtitleGenerationBlocks(progress.doneBlocks, progress.totalBlocks))) }
                if progress.totalEvents > 0 { Text(String(localized: .librarySubtitleGenerationEvents(progress.doneEvents, progress.totalEvents))) }
                if let reference = TrackGenText.sourceKeyLabel(progress.sourceCandidateKey) {
                    Text(String(localized: .librarySubtitleGenerationReference(reference))).lineLimit(1).truncationMode(.middle)
                }
                if progress.modelRequests > 0 {
                    Text(String(localized: .librarySubtitleGenerationCalls(progress.modelRequests)) + (progress.modelTokens > 0 ? " · \(TrackGenText.grouped(progress.modelTokens)) token" : ""))
                }
                Text(String(localized: .librarySubtitleGenerationElapsed(TrackGenText.elapsed(progress.elapsedSeconds))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.textMuted)

            if !progress.activeBlocks.isEmpty {
                Text((progress.parallelism > 1 ? String(localized: .librarySubtitleGenerationParallelLimit(progress.parallelism)) : "")
                    + String(localized: .librarySubtitleGenerationActiveBlockList(progress.activeBlocks.map(String.init)
                        .joined(separator: AppLanguage.identifier == "zh-Hans" ? "、" : ", ")))
                    + (progress.oldestActiveSeconds > 0 ? String(localized: .librarySubtitleGenerationOldestWait(TrackGenText.elapsed(progress.oldestActiveSeconds))) : ""))
                    .font(.caption)
                    .foregroundStyle(Theme.info.opacity(0.85))
            }
            if progress.rateLimitCount > 0 || progress.validationRetries > 0 {
                Text((progress.rateLimitCount > 0 ? String(localized: .librarySubtitleGenerationRateLimits(progress.rateLimitCount)) : "")
                    + (progress.validationRetries > 0 ? String(localized: .librarySubtitleGenerationValidationRetries(progress.validationRetries)) : ""))
                    .font(.caption)
                    .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.6))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(TrackGenText.stages.enumerated()), id: \.offset) { index, stage in
                    let completed = index < progress.stageIndex
                    let current = index == progress.stageIndex
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(current ? Theme.info.opacity(0.15) : completed ? Theme.success.opacity(0.1) : .clear)
                            Circle()
                                .strokeBorder(current ? Theme.info : completed ? Theme.success.opacity(0.6) : Color.white.opacity(0.15))
                            Text(completed ? "✓" : "\(index + 1)")
                                .font(.system(size: 9))
                                .foregroundStyle(completed ? Color(red: 0.49, green: 0.94, blue: 0.64) : Color.primary)
                        }
                        .frame(width: 16, height: 16)
                        Text(index == 0 && progress.usesOcr ? String(localized: .librarySubtitleGenerationOcrStage) : stage.label)
                        if current {
                            Spacer(minLength: 8)
                            Text(String(localized: .librarySubtitleGenerationInProgress)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .font(current ? .caption.weight(.medium) : .caption)
                    .foregroundStyle(current ? Theme.info : completed ? Color.white.opacity(0.7) : Color.white.opacity(0.35))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: .librarySubtitleGenerationStages))
        }
    }
}

nonisolated extension APIClient {
    /// 生成预检（`GET /libraries/files/{id}/subtitles/generation-preview`）。
    ///
    /// 与生成函数同参，但带 20 秒超时（同 Web `PREVIEW_TIMEOUT_MS`）：后端保证预检只读数据库
    /// 与现成产物、不读视频（没读过的内封轨交给任务第一步；旧版服务端则回 pending），
    /// 超过 20 秒就是真的不对劲。
    fileprivate func trackRowsGenerationPreview(
        fileId: Int, targetLanguage: String, secondaryLanguage: String?, sourceCandidateKey: String?
    ) async throws -> API.GenPreviewView {
        var query = [URLQueryItem(name: "target_language", value: targetLanguage)]
        if let secondaryLanguage { query.append(URLQueryItem(name: "secondary_language", value: secondaryLanguage)) }
        if let sourceCandidateKey { query.append(URLQueryItem(name: "source_candidate_key", value: sourceCandidateKey)) }
        return try await send(
            "GET", "/libraries/files/\(fileId)/subtitles/generation-preview", query: query, timeout: 20
        )
    }
}
