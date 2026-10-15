import SwiftUI

/// AI 会话页（`/sessions/{id}`，对应 Web `components/agent-conversation-view.tsx`）。
///
/// ChatGPT / Claude 式对话：顶栏会话标题 + 返回 + 右上角「⋯」会话菜单，可滚动消息列（用户右侧气泡 / Agent 整栏正文），
/// 底部贴底输入框随键盘上移。沉浸式：进入时隐藏标签栏（Web 手机端 `/sessions/*` 同样隐藏底栏）。
///
/// 交互要点：
/// - 进入时拉轨迹回放；会话仍在运行则自动接上事件流（离开再回来不重拉，继续跟随）；
/// - 每次进入会话都停在最底部（最新一轮），见 `AgentTranscriptScroll`；
/// - 生成中可继续打字，发送键变停止键；
/// - 自动滚动只在用户本就贴近底部时跟随新内容（上滚查看历史时不打断），离开底部给「回到最新消息」按钮；
/// - 「改写这条提问」只进入本地编辑态，发送时二次确认「替换并重新提问」才调用 retry；
/// - 模型 / 思维链选择器三态：没动过（发送时不传，服务端沿用上一条）/ 显式默认 / 显式值，
///   展示值回落到会话最近一轮的轨迹信封值。
struct AgentConversationView: View {
    let sessionId: String

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback

    @State private var conversation: AgentConversation
    @State private var draft = AgentDraft()
    /// 外层 nil = 没动过选择器；.some(nil) = 显式「默认」
    @State private var thinkingChoice: String??
    @State private var modelChoice: String??
    @State private var modelOptions: [API.LlmModelOptionView] = []
    @State private var knownSkills: Set<String>?
    /// false = 明确未接入模型（锁定追问并引导去设置）
    @State private var llmConfigured: Bool?
    /// 正在改写的提问（message_id）
    @State private var retryTarget: String?
    @State private var retrying = false
    @State private var askingConsent = false
    @State private var latestRequest = 0
    @State private var scroll = AgentTranscriptScroll()
    /// 消息列是否整列排版（见 AgentTranscriptLayout.prefersEagerLayout）：进页面时定一次，流式变长也不中途换容器
    @State private var eagerLayout: Bool?
    @State private var kickoff = AgentLoadKickoff()
    /// 输入框晚一拍建：App 这次运行里第一次建输入框很重（模拟器实测 120～280ms，同一次运行里再建只要约 10ms），
    /// 跟着页面一起建会把页面跳转推迟这么久。首帧先放等高占位，跳转画面出去后马上建——此时正在等轨迹，
    /// 主线程空着（真机上跳转排版约 30ms、轨迹网络 70～100ms），这笔一次性开销被网络等待吸收
    @State private var composerReady = false
    /// 正在输入（小幕抬头倾听）
    @State private var composerAttentive = false
    /// 上次量到的输入区高度，占位按它留空，换成真输入框时底部不跳（初值取 iPhone Air 实测的单行输入区高度）
    private static var composerHeight: CGFloat = 126
    private static let bottomID = "agent-transcript-bottom"

    init(sessionId: String) {
        self.sessionId = sessionId
        _conversation = State(initialValue: AgentConversationRegistry.conversation(sessionId))
    }

    var body: some View {
        // 抢跑：body 首次求值（点开后约 20ms）就在后台线程发出轨迹请求。`.task` 要等整页首次排版完、
        // 开始滑入才触发，冷启动时晚 100～200ms；提前发出后，网络等待与页面跳转的排版同时进行
        let _ = kickoff.fire { [conversation, api] in
            conversation.prefetch(api: api)
            Task { await conversation.open(api: api) }
        }
        ScrollViewReader { proxy in
            content(proxy: proxy)
        }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(conversation.loaded ? conversation.title : "AI 会话")
            .navigationBarTitleDisplayMode(.inline)
            .background { HidesTabBarWhenPushed() }
            .toolbar {
                // 右上角只留「⋯」，操作的是当前会话；Web 顶栏的搜索与「+」在会话页里用不上（2026-09-26 用户决定去掉）
                if conversation.loaded {
                    ToolbarItem(placement: .topBarTrailing) { sessionMenu }
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                // 站内链接（相对路径或指向当前服务器）走原生路由；外链交给系统浏览器（同 Web 新窗口打开）
                if url.scheme == nil || url.host() == api.server.apiBase.host(), router.open(webPath: url.path() + (url.query().map { "?\($0)" } ?? "")) {
                    return .handled
                }
                return .systemAction
            })
            .tracksSubscriptionIndex()
            .sheet(isPresented: $askingConsent) {
                AgentAIConsentSheet(providers: AgentAIConsent.providers(modelOptions), onAgree: send)
            }
            .task(id: sessionId) {
                // 第一次出现由上面的抢跑负责；之后每次重新出现（从子页面返回）再刷新一次轨迹
                if kickoff.consumeFirstAppearance() { return }
                await conversation.open(api: api)
            }
            .task {
                async let configured = AgentCatalog.llmConfigured(api: api)
                async let options = AgentCatalog.modelOptions(api: api)
                async let skills = AgentCatalog.knownSkills(api: api)
                llmConfigured = await configured
                modelOptions = await options
                knownSkills = await skills
            }
            .task {
                // 页面出现（首帧已排版提交）后的下一轮就换上真输入框，见 composerReady
                guard !composerReady else { return }
                await Task.yield()
                composerReady = true
            }
            // 停在这页时，这个会话的「AI 回复完成」推送不在前台弹出（见 PushCenter.willPresent）
            .onAppear { PushCenter.shared.visibleSessionPath = "/sessions/\(sessionId)" }
            .onDisappear {
                if PushCenter.shared.visibleSessionPath == "/sessions/\(sessionId)" { PushCenter.shared.visibleSessionPath = nil }
                conversation.detachIfIdle()
            }
    }

    /// 输入区挂在「加载中 / 消息列」的分支之外：跳转首帧后马上建好（加载期间禁用，见 composerReady），
    /// 等轨迹的那段网络时间里顺手完成创建与排版；数据到了只剩消息列要排。放进分支里切换时会被当成新视图重建
    private func content(proxy: ScrollViewProxy) -> some View {
        Group {
            if !conversation.loaded, let error = conversation.loadError {
                VStack(spacing: 8) {
                    Text("无法打开会话").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.text)
                    Text(error).font(.system(size: 14)).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("agent-load-error")
            } else if !conversation.loaded {
                // 居中的转圈 + 文字：长会话在 NAS 上要拉一会儿，原先只有一行忽明忽暗的灰字，
                // 黑底上看着像黑屏（2026-10-13 用户反馈）
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(Theme.textMuted)
                    Text("正在加载会话…")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agent-loading")
            } else {
                transcript(proxy: proxy)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            // 会话打不开时不给输入框（没有可续聊的会话）
            if conversation.loaded || conversation.loadError == nil {
                if composerReady {
                    composerArea
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { Self.composerHeight = $0 }
                } else {
                    Theme.background.frame(height: Self.composerHeight)
                }
            }
        }
        .agentCompanion(.resolve(turn: conversation.turns.last, busy: conversation.running,
                                 unavailable: llmConfigured == false || !conversation.loaded),
                        attentive: composerAttentive)
    }

    // MARK: 消息列

    private func transcript(proxy: ScrollViewProxy) -> some View {
        let running = conversation.running
        let eager = eagerLayout ?? AgentTranscriptLayout.prefersEagerLayout(conversation.turns)
        return ScrollView {
            // 段落级的行（见 AgentTranscriptRows）：长会话懒加载，进页面只构建、排版最底下一屏，不再整轮卡住
            AgentTranscriptStack(eager: eager) {
                ForEach(conversation.rows) { row in
                    // 运行中不给改写入口：服务端会拒绝替换正在写轨迹的会话
                    AgentTranscriptRowView(
                        row: row,
                        sessionId: sessionId,
                        knownSkills: knownSkills,
                        onEdit: running || retrying ? nil : { messageId, input in
                            retryTarget = messageId
                            draft.load(input)
                        }
                    )
                    .equatable()
                    .padding(.top, row.spacing)
                    // 每个定位目标都占满视口并包含左右留白，避免首次按行定位时横向偏移。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                }
                Color.clear.frame(height: 16).id(Self.bottomID)
            }
            .padding(.top, 16)
        }
        .onAppear { if eagerLayout == nil { eagerLayout = eager } }
        .accessibilityIdentifier("agent-transcript")
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(scroll.followsLatest ? .bottom : nil, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            if scroll.update(phase: phase) { scrollToLatest(proxy) }
        }
        .onScrollGeometryChange(for: AgentTranscriptScroll.Viewport.self) { geometry in
            Self.viewport(contentHeight: geometry.contentSize.height, visible: geometry.visibleRect, insets: geometry.contentInsets)
        } action: { _, viewport in
            if scroll.update(viewport: viewport) { scrollToLatest(proxy) }
        }
        .task {
            // 与「回到最新」使用同一个底边定位；懒加载高度变化由几何回调校正。
            // 返回子页面时，保留用户正在阅读的历史位置。
            if scroll.followsLatest { scrollToLatest(proxy) }
        }
        .scrollDismissesKeyboard(.interactively)
        // 只让输入框自身呈现玻璃；系统底部渐隐会在悬浮宠物周围形成黑色遮罩。
        .scrollEdgeEffectHidden(true, for: .bottom)
        // 比行不比轮：思考增量不上屏（处理过程隐藏），不该每 80ms 跟着发一次滚动请求
        .onChange(of: conversation.rows) {
            if scroll.followsLatest { scrollToLatest(proxy) }
        }
        .onChange(of: latestRequest) { scrollToLatest(proxy) }
        .overlay(alignment: .bottom) {
            // 只动画按钮；不要把懒加载行的高度修正也放进弹簧动画。
            ZStack {
                if !scroll.viewport.nearBottom {
                    // 液态玻璃圆形按钮（原先是手画的深色圆 + 描边 + 阴影，与页面其余玻璃控件不是一套）。
                    // 与输入框的加号 / 发送键同为 36pt（2026-10-12 用户要求）：系统 .glass 按钮样式会在内容外再加一圈边距，
                    // 量不准，改成自定尺寸 + 玻璃效果
                    Button {
                        pinToLatest()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: AgentComposer.control, height: AgentComposer.control)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .expandedHitArea(horizontal: 4, vertical: 4)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .padding(.bottom, 10)
                    .accessibilityLabel("回到最新消息")
                    .accessibilityIdentifier("agent-scroll-latest")
                }
            }
            .animation(.snappy, value: scroll.viewport.nearBottom)
        }
    }

    // MARK: 底部输入

    private var composerArea: some View {
        let turns = conversation.turns
        // 会话当前生效的档位 / 模型 = 最近一轮有值的轨迹信封值
        let sessionThinking = turns.last(where: { $0.thinkingLevel != nil })?.thinkingLevel ?? nil
        let sessionModel = turns.last(where: { $0.modelRef != nil })?.modelRef ?? nil
        let displayedThinking = thinkingChoice ?? sessionThinking
        let displayedModel = modelChoice ?? sessionModel
        let locked = llmConfigured == false

        return VStack(alignment: .leading, spacing: 8) {
            if retryTarget != nil {
                HStack {
                    Text("正在改写较早的提问，发送后将替换其后的对话")
                    Spacer()
                    Button("取消改写") {
                        retryTarget = nil
                        draft.clear()
                    }
                    .foregroundStyle(Theme.textFaint)
                    .accessibilityIdentifier("agent-cancel-retry")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 8)
            }
            AgentComposer(
                draft: $draft,
                placeholder: locked ? "请先接入 AI 模型，再继续对话"
                    : retryTarget != nil ? "修改问题后发送，将从这里重新生成回答" : nil,
                busy: conversation.running,
                // 轨迹还没回放完不许发：乐观轮次会被随后到达的完整轨迹覆盖掉
                disabled: locked || !conversation.loaded || (retrying && retryTarget != nil),
                // 改写模式不开图片入口：retry 沿用原消息的图，新加的图无处安放，藏起入口比静默丢弃诚实
                imageUpload: retryTarget == nil,
                onAttentionChange: { composerAttentive = $0 },
                modelOptions: modelOptions,
                modelValue: displayedModel,
                onModelChange: { ref in
                    modelChoice = .some(ref)
                    // 换模型后旧档位可能不在新菜单里，显式清回默认
                    thinkingChoice = .some(nil)
                    AgentComposerPrefs(model: ref, thinking: nil).save()
                },
                thinkingValue: displayedThinking,
                onThinkingChange: { level in
                    thinkingChoice = .some(level)
                    AgentComposerPrefs(model: displayedModel, thinking: level).save()
                },
                onSubmit: submit,
                onStop: stop
            )
            .agentCompanionAnchor()
            if locked { AgentLLMSetupNotice() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .modifier(AgentComposerBottomGap())
    }

    /// 线上值：没动过不传（服务端沿用）；显式默认传 "default"
    private func wire(_ choice: String??) -> String? {
        switch choice {
        case .none: nil
        case .some(.none): "default"
        case let .some(.some(value)): value
        }
    }

    /// 第一次发给 AI 前先说明去向、取得同意（AgentAIConsent）
    private func submit() {
        guard AgentAIConsent.granted else {
            askingConsent = true
            return
        }
        send()
    }

    private func send() {
        let message = draft.message
        let images = draft.images.map { AgentTurnImage(attachmentId: $0.attachmentId, name: $0.name) }
        guard let target = retryTarget else {
            draft.clear()
            conversation.send(api: api, input: message, images: images, thinking: wire(thinkingChoice), model: wire(modelChoice))
            pinToLatest()
            return
        }
        Task {
            let agreed = await feedback.confirm(
                "重新提交这条提问？",
                message: "这条提问及其之后的对话会被新问题替换，原记录无法恢复。",
                confirmTitle: "替换并重新提问",
                destructive: true
            )
            guard agreed else { return }
            retrying = true
            defer { retrying = false }
            do {
                // 改写模式下选择器照常可用：没动过就沿用被重试消息的值
                try await conversation.retry(api: api, messageId: target, content: message, thinking: wire(thinkingChoice), model: wire(modelChoice))
                draft.clear()
                retryTarget = nil
                pinToLatest()
            } catch {
                feedback.error(error)
            }
        }
    }

    /// 滚动几何 → 贴底状态（纯函数，单元测试见 AgentLogicTests）。
    /// `visibleRect` 覆盖整个屏幕，包括顶栏与输入区背后（实测贴底时 maxY = 内容高 + 输入区高），
    /// 要扣掉安全区才是读得到的区域。滚过头（内容缩短后底部留空白）不算贴底，否则页面停在空白处无人校正。
    static func viewport(contentHeight: CGFloat, visible: CGRect, insets: EdgeInsets) -> AgentTranscriptScroll.Viewport {
        let top = visible.minY + insets.top
        let bottom = visible.maxY - insets.bottom
        let gap = contentHeight - bottom
        return .init(
            nearBottom: gap < 120,
            // 内容还没出来（高度 0）不算
            offscreen: contentHeight > 0 && bottom > top && (top >= contentHeight || bottom <= 0),
            // 不满一屏时位置由系统的底部锚点摆放（实测会停在负偏移），不再校正，否则与锚点来回拉扯
            atBottom: abs(gap) <= 1 || contentHeight <= bottom - top,
            contentHeight: contentHeight.rounded(),
            visibleHeight: visible.height.rounded()
        )
    }

    /// 发出新消息或点击「回到最新」时恢复跟随；用户开始拖动立即让出控制。
    private func pinToLatest() {
        scroll.followsLatest = true
        latestRequest += 1
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    // MARK: 会话菜单

    /// 当前会话的操作：从此处创建新会话（聊天记录页最常用，放第一位）/ 重命名 / 删除
    /// （「更多」页最近会话的行尾菜单与此同图标、同顺序）
    private var sessionMenu: some View {
        Menu {
            Button("从此处创建新会话", systemImage: "arrow.triangle.branch") { Task { await fork() } }
            Button("重命名", systemImage: "pencil") { Task { await rename() } }
            Divider()
            Button("删除会话", systemImage: "trash", role: .destructive) { Task { await remove() } }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("会话操作")
        .accessibilityIdentifier("agent-session-menu")
    }

    /// 从此处创建新会话：服务端带上本会话的上下文开一个新会话（同 Web「在新会话中继续」），打开后接着聊
    private func fork() async {
        guard await feedback.confirm(
            "从此处创建新会话？",
            message: "会带上这段对话的上下文开一个新会话接着聊，原会话保留不变。",
            confirmTitle: "创建新会话"
        ) else { return }
        do {
            let forked = try await api.sessionFork(sessionId: sessionId)
            router.open(.session(id: forked.session.id))
        } catch {
            feedback.error("创建新会话失败：\(error.localizedDescription)")
        }
    }

    private func rename() async {
        // 初值是顶栏显示的标题；去空白、截 80 字，没变化就不发请求（同 Web）
        let current = conversation.title
        guard let input = await feedback.prompt("重命名会话", placeholder: "会话标题（最多 80 字）", initial: current, maxLength: 80) else { return }
        let name = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, name != current else { return }
        do {
            let updated = try await api.sessionRename(sessionId: sessionId, body: .init(title: name))
            conversation.title = updated.title ?? name
        } catch {
            feedback.error("重命名失败：\(error.localizedDescription)")
        }
    }

    private func remove() async {
        let title = conversation.title.isEmpty ? "未命名会话" : conversation.title
        guard await feedback.confirm(
            "彻底删除会话「\(title)」？",
            message: "服务器上的完整对话记录将一并删除，此操作不可恢复。",
            confirmTitle: "彻底删除", destructive: true
        ) else { return }
        do {
            _ = try await api.sessionDelete(sessionId: sessionId)
            feedback.success("会话已删除")
            router.pop()
        } catch {
            feedback.error("删除失败：\(error.localizedDescription)")
        }
    }

    private func stop() {
        Task {
            do {
                try await conversation.stop(api: api)
            } catch {
                // 停止失败时 Agent 可能仍在执行，不在客户端伪造终态；真实终态仍会经事件流落到界面
                feedback.error("停止失败，请稍后重试：\(error.localizedDescription)")
            }
        }
    }
}

/// 消息列的容器：短会话整列排版，长会话懒加载
private struct AgentTranscriptStack<Content: View>: View {
    let eager: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if eager {
            VStack(alignment: .leading, spacing: 0) { content }.scrollTargetLayout()
        } else {
            LazyVStack(alignment: .leading, spacing: 0) { content }.scrollTargetLayout()
        }
    }
}

/// 会话页的抢跑加载开关：每个页面实例只在 body 首次求值时发一次轨迹请求（body 会被反复求值，
/// 不能每次都发）；`.task` 第一次触发时据此跳过，免得同一份轨迹拉两遍
final class AgentLoadKickoff {
    private var fired = false
    private var firstAppearanceConsumed = false

    func fire(_ start: () -> Void) {
        guard !fired else { return }
        fired = true
        start()
    }

    /// 第一次调用返回 true（首次加载已由 `fire` 发出），之后都返回 false
    func consumeFirstAppearance() -> Bool {
        defer { firstAppearanceConsumed = true }
        return !firstAppearanceConsumed
    }
}

/// 未接入模型时的公共引导（对应 Web `LlmSetupNotice`）：说明能解锁什么，并给唯一的设置入口
struct AgentLLMSetupNotice: View {
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 4) {
            Text("接入 AI 模型后即可解锁AI 对话能力。")
                .foregroundStyle(Theme.textMuted)
            Button("去接入") { router.push(.settingsSection(.llm)) }
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("agent-llm-setup")
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}
