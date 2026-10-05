import SwiftUI

/// Apple TV 的全屏播放器（docs/design/tvos-app.md §4）。
///
/// 与 iPhone 版共用同一个 `PlaybackController`（会话协议、引擎编排、兜底阶梯、进度上报、选轨记忆、下一集），
/// 这里只有电视的控制层。交互照搬 tvOS 系统播放器，用户不用重新学：
///
/// | 遥控器 | 行为 |
/// |---|---|
/// | 播放 / 暂停键，按下触控板中心 | 播放 / 暂停（暂停时显示进度条） |
/// | 点按左 / 右 | 后退 / 前进 10 秒 |
/// | 在触控板上左右滑 | 拖动进度，松手跳过去 |
/// | 下滑 / 点按下 | 信息面板：字幕、音轨、画质 |
/// | 返回键 | 依次：取消拖动 → 收起面板 → 收起「下一集」卡片 → 退出播放 |
///
/// 片头片尾时段右下角出现「跳过」按钮、片尾出现「下一集」卡片，焦点自动落在上面，按一下就生效。
struct TVPlayerScreen: View {
    let request: PlayRequest

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var controller: PlaybackController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller {
                TVPlayerContent(controller: controller, exit: exit)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-player")
        .onAppear(perform: attach)
        .onDisappear {
            // 仍在呈现同一个播放请求：只是视图被重建，控制器保留
            if router.player?.id == request.id { return }
            finish()
        }
        .onChange(of: scenePhase) { _, phase in
            controller?.setBackgrounded(phase == .background)
        }
    }

    /// 接过点播放时就建好的控制器（`TVRouter.startPlaybackEarly`），没有就现建
    private func attach() {
        guard controller == nil else { return }
        let created: PlaybackController
        if let early = router.activePlayback, early.request.id == request.id {
            created = early
        } else {
            created = PlaybackController(request: request, api: api, requestedAt: router.playRequestedAt)
            router.activePlayback = created
        }
        created.viewAttached = true
        created.noteViewAppeared()
        controller = created
        created.start()
        UIApplication.shared.isIdleTimerDisabled = true
        #if DEBUG
        TVPlayerDebug.schedule(created, exit: exit)
        #endif
    }

    private func exit() {
        finish()
        dismiss()
    }

    /// 真正离开播放器：关会话、恢复屏保
    private func finish() {
        controller?.close()
        if router.activePlayback === controller { router.activePlayback = nil }
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

/// 播放器里能拿焦点的东西。平时焦点在「画面」上（一块看不见的全屏按钮，收遥控器的按键）；
/// 面板、跳过按钮、下一集卡片、出错 / 同意弹窗出现时，焦点移到它们身上
enum TVPlayerFocus: Hashable {
    case surface
    case skip
    case upNext
    case qualityOffer
    case panelOption(String)
    case dialog
}

/// 画面与控制层
private struct TVPlayerContent: View {
    let controller: PlaybackController
    let exit: () -> Void

    @FocusState private var focus: TVPlayerFocus?
    /// 焦点范围：右下角的按钮出现时让焦点引擎重新挑一次默认焦点（`resetFocus`），它们声明了「优先」
    @Namespace private var focusScope
    @Environment(\.resetFocus) private var resetFocus
    @State private var chromeVisible = true
    @State private var chromeActivity = 0
    @State private var panel: TVPlayerPanelTab?
    @State private var scrubMs: Int?
    @State private var scrubBase = 0
    @State private var trickplay = TrickplayImages()

    var body: some View {
        ZStack {
            video

            if showPaused {
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            surface

            // 面板打开时进度条让位：面板底部是字幕预览，两者都在屏幕下方
            if chromeVisible, panel == nil {
                chrome
                    .transition(.opacity)
            }

            if controller.phase.isBusy {
                TVPlayerBusyView(controller: controller)
            }

            contextualCorner

            if let notice = controller.notice {
                VStack {
                    TVPlayerNotice(text: notice)
                    Spacer()
                }
                .padding(.top, 40)
                .transition(.opacity)
            }

            if let panel {
                TVPlayerPanel(controller: controller, initial: panel, focus: $focus)
                    .transition(.opacity)
            }

            dialogs
        }
        .background {
            TVSwipeScrubber(enabled: scrubEnabled, onHorizontal: handleScrub, onVertical: handleVerticalSwipe)
                .frame(width: 0, height: 0)
        }
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .animation(.easeInOut(duration: 0.25), value: panel)
        .animation(.easeInOut(duration: 0.2), value: controller.notice)
        .onPlayPauseCommand(perform: togglePlay)
        // 播放器在放时 App 是系统的「正在播放」应用，遥控器的播放 / 暂停键先交给系统远程命令
        // （NowPlayingBridge 直接暂停控制器），到不了上面的 onPlayPauseCommand，控制层就不出来：
        // 画面停住却没有片名和进度条（2026-10-05 模拟器走查发现）。以「用户暂停了」这个状态为准补上
        .onChange(of: showPaused) { _, shown in
            if shown { showChrome() }
        }
        .onExitCommand(perform: back)
        // 面板开着时不许系统拿返回键直接关掉播放器：焦点万一悬空，返回键也只该收起面板（由 back 处理），不能退出播放
        .interactiveDismissDisabled(panel != nil)
        .focusScope(focusScope)
        .task(id: contextualFocusTarget) {
            // 跳过按钮、下一集卡片出现时焦点自动落上去（按一下就生效），消失时回到画面。
            // 直接给 FocusState 赋值在 tvOS 上不可靠（按钮刚出现、还没进焦点系统时会被静默忽略）：
            // 改用系统的做法——它们声明「优先默认焦点」，这里请焦点引擎在这个范围里重新挑一次
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if contextualFocusTarget != nil || focus == nil || focus == .skip || focus == .upNext || focus == .qualityOffer {
                resetFocus(in: focusScope)
            }
            // 兜底：重挑之后还没落上（与下面「回到画面」那一步挨得太近、主线程一忙先后就会颠倒，实测），
            // 这时按钮早已进了焦点系统，直接赋值是可靠的
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let target = contextualFocusTarget, focus != target,
                  focus == nil || focus == .surface else { return }
            focus = target
        }
        .task(id: isModal) {
            // 出错 / 要用户同意的对话框同理。没有对话框时回到画面——但跳过片头、下一集这类按钮正露着的话焦点给它，
            // 不能把它刚拿到的焦点抢回画面
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            focus = isModal ? .dialog : (contextualFocusTarget ?? .surface)
        }
        .task(id: autoHideKey) {
            // 控制层 4 秒无操作自动收起；暂停、拖动、面板打开、出错时一直显示
            guard chromeVisible, !chromeMustStayVisible else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { chromeVisible = false }
        }
    }

    // MARK: 画面

    @ViewBuilder
    private var video: some View {
        if let engine = controller.engine {
            EngineSurface(engineView: engine.view)
                .id(ObjectIdentifier(engine))
                .ignoresSafeArea()
                .accessibilityIdentifier("tv-player-video")
            // 服务端流的文字字幕由叠加层画（自研引擎直出时字幕由引擎画在画面里，这里地址为空）
            SubtitleOverlay(
                url: controller.overlaySubtitleURL,
                style: controller.subtitleStyle,
                videoSize: engine.videoSize,
                time: { Double(controller.originMs) / 1000 + (controller.engine?.currentTime ?? 0) },
                session: controller.scope.api.session
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// 平时拿焦点的「画面」：一块全屏、看不见的按钮。按下触控板中心 = 播放 / 暂停，点按方向键 = 快退快进 / 面板
    private var surface: some View {
        Button(action: togglePlay) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(TVInvisibleButtonStyle())
        .focused($focus, equals: .surface)
        .prefersDefaultFocus(contextualFocusTarget == nil, in: focusScope)
        .disabled(panel != nil || isModal)
        .onMoveCommand(perform: handleMove)
        .ignoresSafeArea()
        .accessibilityLabel(controller.paused ? "播放" : "暂停")
        .accessibilityIdentifier("tv-player-surface")
    }

    // MARK: 控制层

    private var chrome: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 220)
                .overlay(alignment: .topLeading) {
                    if showPaused, panel == nil {
                        TVPausedTitle(title: controller.title, episodeLabel: controller.episodeLabel(controller.currentEpisode))
                            .padding(.top, 60)
                            .padding(.horizontal, 80)
                    }
                }
            Spacer(minLength: 0)
            TVTransportBar(controller: controller, trickplay: trickplay, scrubMs: scrubMs)
                .padding(.horizontal, 80)
                .padding(.bottom, 60)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 360)
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 右下角：跳过片头 / 下一集卡片 / 换画质建议（同一个角落，同时只出一个）
    @ViewBuilder
    private var contextualCorner: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let offer = controller.qualityOffer {
                    TVQualityOfferCard(offer: offer, accept: controller.acceptQualityOffer, dismiss: controller.dismissQualityOffer)
                        .focused($focus, equals: .qualityOffer)
                        .prefersDefaultFocus(true, in: focusScope)
                } else if let segment = controller.skipSegment {
                    TVSkipButton(segment: segment, action: controller.skipCurrentSegment)
                        .focused($focus, equals: .skip)
                        .prefersDefaultFocus(true, in: focusScope)
                } else if controller.showsUpNext, let next = controller.nextEpisode {
                    TVUpNextCard(
                        episode: next,
                        still: controller.scope.api.image(next.stillUrl, width: ImageWidth.tvCard(TVUpNextCard.stillWidth)),
                        countdown: controller.autoNextArmed ? controller.autoNextProgress : nil
                    ) {
                        controller.noteUserActivity()
                        controller.playNext()
                    }
                    .focused($focus, equals: .upNext)
                    .prefersDefaultFocus(true, in: focusScope)
                    // 倒计时的钟：卡片在才走（同 iPhone 版）
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                            controller.advanceAutoNext(by: 0.1)
                        }
                    }
                }
            }
        }
        // 进度条显示时让出它的位置
        .padding(.bottom, chromeVisible ? 200 : 80)
        .padding(.horizontal, 80)
        .ignoresSafeArea()
        .opacity(isModal || panel != nil ? 0 : 1)
        // 面板打开时这些按钮只是看不见、还能拿焦点（且声明了「优先默认焦点」）：面板里的焦点一旦落空，
        // 系统会把它落到看不见的按钮上。面板开着时整块禁用
        .disabled(panel != nil)
        .animation(.easeInOut(duration: 0.25), value: contextualFocusTarget)
    }

    @ViewBuilder
    private var dialogs: some View {
        if let infoError = controller.infoError {
            // 条目信息都拿不到（无权访问、已删除）：整页换成原因 +「返回」
            TVPlayerDialog(title: infoError, message: nil, primary: ("返回", exit), secondary: nil)
                .focused($focus, equals: .dialog)
        } else if controller.phase == .error, let message = controller.errorMessage {
            TVPlayerDialog(title: message, message: controller.errorSuggestion, primary: ("重试", controller.retry), secondary: ("返回", exit))
                .focused($focus, equals: .dialog)
        } else if controller.phase == .consent, let decision = controller.pendingDecision {
            TVConsentDialog(decision: decision, grant: controller.grantConsent, cancel: exit)
                .focused($focus, equals: .dialog)
        }
    }

    // MARK: 状态

    private var isModal: Bool {
        controller.infoError != nil || controller.phase == .error || controller.phase == .consent
    }

    /// 暂停遮罩只跟「用户意图」走：缓冲、换流时的程序性暂停不压暗（同 iPhone 版）
    private var showPaused: Bool {
        controller.paused && !controller.wantsPlay && !controller.phase.isBusy && !isModal && controller.positionMs > 0
    }

    /// 控制层必须常显：暂停时用户在找进度；正在拖；面板开着
    private var chromeMustStayVisible: Bool {
        let userPaused = controller.paused && !controller.phase.isBusy && controller.session != nil
        return userPaused || scrubMs != nil || panel != nil
    }

    private var autoHideKey: String {
        "\(chromeVisible)-\(chromeMustStayVisible)-\(chromeActivity)"
    }

    /// 该自动拿焦点的右下角元素
    private var contextualFocusTarget: TVPlayerFocus? {
        guard !isModal, panel == nil else { return nil }
        if controller.qualityOffer != nil { return .qualityOffer }
        if controller.skipSegment != nil { return .skip }
        if controller.showsUpNext, controller.nextEpisode != nil { return .upNext }
        return nil
    }

    /// 滑动拖进度只在焦点在画面上时接管：面板、按钮拿着焦点时滑动是在挪焦点
    private var scrubEnabled: Bool {
        focus == .surface && panel == nil && !isModal && controller.session != nil
    }

    // MARK: 遥控器

    private func showChrome() {
        chromeVisible = true
        chromeActivity += 1
    }

    private func togglePlay() {
        controller.noteUserActivity()
        guard !isModal else { return }
        controller.togglePlay()
        showChrome()
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        controller.noteUserActivity()
        switch direction {
        case .left:
            controller.seek(by: -10, source: .remote)
            showChrome()
        case .right:
            controller.seek(by: 10, source: .remote)
            showChrome()
        case .down:
            openPanel()
        case .up:
            showChrome()
        @unknown default:
            break
        }
    }

    private func handleVerticalSwipe(_ down: Bool) {
        if down { openPanel() } else { showChrome() }
    }

    private func openPanel() {
        guard !isModal, controller.session != nil else { return }
        panel = TVPlayerPanel.firstTab(for: controller)
        showChrome()
    }

    /// 触控板左右滑：满屏宽一划 = 片长的 1/5（夹在 1～15 分钟之间），松手才跳（同 iPhone 版的横滑定位）
    private func handleScrub(_ phase: TVSwipeScrubber.Phase, _ fraction: CGFloat) {
        guard let duration = controller.timelineDurationMs else { return }
        let start = controller.timelineStartMs
        let sweepMs = min(15 * 60_000, max(60_000, duration / 5))
        switch phase {
        case .began:
            controller.noteUserActivity()
            scrubBase = controller.positionMs
            scrubMs = scrubBase
            showChrome()
        case .changed:
            let target = min(max(start, scrubBase + Int(fraction * CGFloat(sweepMs))), start + duration)
            scrubMs = target
            controller.scrubFollow(toFileMs: target)
        case .ended:
            if let scrubMs { controller.seek(toFileMs: scrubMs, source: .scrub) }
            scrubMs = nil
            showChrome()
        case .cancelled:
            scrubMs = nil
        }
    }

    /// 返回键：取消拖动 → 收起面板 → 收起下一集卡片 → 退出播放
    private func back() {
        controller.noteUserActivity()
        if scrubMs != nil {
            scrubMs = nil
            controller.seek(toFileMs: scrubBase, source: .scrub)
            return
        }
        if panel != nil {
            panel = nil
            focus = .surface
            return
        }
        if focus == .upNext {
            controller.nextDismissed = true
            focus = .surface
            return
        }
        if focus == .qualityOffer {
            controller.dismissQualityOffer()
            focus = .surface
            return
        }
        exit()
    }
}

/// 完全不画焦点效果的按钮样式：给「画面」这块全屏按钮用（获得焦点时不能放大、不能高亮）
struct TVInvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

#if DEBUG
/// 开发期的自动操作（同 iPhone 版 PlayerScreen 的 -mcAuto* 启动参数，模拟器验收用）：
/// - `-mcAutoSeek "<秒>:<目标>[,…]"`：到点跳转，目标是片内秒数，带 +/- 则相对当前位置；
/// - `-mcAutoPause <秒>`：到点暂停；`-mcAutoCloseAfter <秒>`：到点像按返回键一样退出播放器
enum TVPlayerDebug {
    static func schedule(_ controller: PlaybackController, exit: @escaping () -> Void) {
        for (at, spec) in steps("mcAutoSeek") {
            Task {
                try? await Task.sleep(for: .seconds(at))
                guard let value = Double(spec) else { return }
                let relative = spec.hasPrefix("+") || spec.hasPrefix("-")
                let target = relative ? controller.positionMs + Int(value * 1000) : Int(value * 1000)
                log("跳转 → \(target / 1000) 秒")
                controller.seek(toFileMs: target, source: .auto)
            }
        }
        let pauseAt = UserDefaults.standard.double(forKey: "mcAutoPause")
        if pauseAt > 0 {
            Task {
                try? await Task.sleep(for: .seconds(pauseAt))
                log("暂停")
                controller.pause()
            }
        }
        let closeAt = UserDefaults.standard.double(forKey: "mcAutoCloseAfter")
        if closeAt > 0 {
            Task {
                try? await Task.sleep(for: .seconds(closeAt))
                log("自动退出播放器")
                exit()
            }
        }
    }

    private static func steps(_ key: String) -> [(Double, String)] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").compactMap { step in
            guard let colon = step.firstIndex(of: ":"), let at = Double(step[..<colon]) else { return nil }
            return (at, String(step[step.index(after: colon)...]))
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[AutoTest] \(message)\n".utf8))
    }
}
#endif
