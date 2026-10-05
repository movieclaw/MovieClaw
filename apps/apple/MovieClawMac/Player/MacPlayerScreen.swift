import AppKit
import SwiftUI

/// Mac 版播放器（docs/design/macos-app.md，交互参照 Apple TV App 与 QuickTime 的 Mac 版）。
///
/// 盖在整个主窗口上（`MacMainView` 的 overlay，侧边栏与工具栏一并收起），画面按比例铺满、黑底。
/// 与 iPhone、Apple TV 版共用同一个 `PlaybackController`（会话协议、引擎编排、兜底阶梯、进度上报、选轨记忆、
/// 跳过片头、下一集），这里只有桌面的控制层：
///
/// | 操作 | 行为 |
/// |---|---|
/// | 移动鼠标 | 控制层浮现；静止 3 秒（且没停在控件上、没暂停）淡出，指针一起藏起来 |
/// | 播放键 / 空格 | 播放 / 暂停（空格时画面正中闪一下状态）；单击画面不暂停（拖窗口、切焦点时容易误触） |
/// | 单击画面 | 唤出控制层（面板开着时先收面板） |
/// | 双击画面 / F / ⌃⌘F | 全屏进出 |
/// | 按住画面拖动 | 移动窗口（同 Infuse） |
/// | ← → / ⌥← ⌥→ | 后退 / 前进 10 秒；⌘← ⌘→ 上一集 / 下一集 |
/// | ↑ ↓ / M | 音量 ±10% / 静音 |
/// | Esc | 依次：收起面板 → 退出全屏 → 关闭播放器 |
/// | ⌘. | 关闭播放器 |
///
/// 字幕避让：控制层出现时，若字幕会被底部控制面板压住，就临时把字幕抬到面板上方（同 AVKit 系统播放器的做法），
/// 控制层收起后落回原位；画面上下有黑边、字幕本来就在面板上方时不动。只改这一次显示，不改用户的字幕设置。
struct MacPlayerScreen: View {
    let request: PlayRequest

    var body: some View {
        // 换了一个播放请求（播放中又点了别的片）就是另一个播放器：状态不沿用
        MacPlayerHost(request: request)
            .id(request.id)
    }
}

/// 接管控制器、管窗口与收尾
private struct MacPlayerHost: View {
    let request: PlayRequest

    @Environment(\.api) private var api
    @Environment(MacRouter.self) private var router

    @State private var controller: PlaybackController?
    @State private var window = MacPlayerWindow()
    @State private var volume = MacPlayerVolume()

    var body: some View {
        ZStack {
            Color.black
            if let controller {
                MacPlayerContent(controller: controller, window: window, volume: volume, close: close)
            }
        }
        .ignoresSafeArea()
        .background(MacWindowReader { window.attach($0) })
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-player")
        .onAppear(perform: attach)
        .onDisappear {
            // 仍在呈现同一个播放请求：只是视图被重建，控制器保留
            if router.player?.id == request.id { return }
            finish()
        }
    }

    /// 接过点播放时就建好的控制器（`MacRouter.startPlaybackEarly`），没有就现建
    private func attach() {
        guard controller == nil else { return }
        let created: PlaybackController
        if let early = router.activePlayback, early.request.id == request.id, !early.isClosed {
            created = early
        } else {
            created = PlaybackController(request: request, api: api, requestedAt: router.playRequestedAt)
            router.activePlayback = created
        }
        created.viewAttached = true
        created.noteViewAppeared()
        controller = created
        created.start()
    }

    /// 关闭播放器（返回按钮、Esc、⌘.）：先收尾再撤掉播放器，回到原来的页面
    private func close() {
        finish()
        router.player = nil
    }

    /// 真正离开播放器：关会话（补一次停止上报，页面收到 `.playbackStopReported` 自己刷新）、退出播放期间进的全屏、
    /// 恢复指针。可重复调用（`close()` 与 `onDisappear` 都会走到）
    private func finish() {
        controller?.close()
        if let controller, router.activePlayback === controller { router.activePlayback = nil }
        window.restoreFrameOnExit()
        window.restoreFullScreenOnExit()
        window.detach()
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

/// 画面与控制层
private struct MacPlayerContent: View {
    let controller: PlaybackController
    let window: MacPlayerWindow
    @Bindable var volume: MacPlayerVolume
    let close: () -> Void

    @State private var chromeVisible = true
    /// 每次有操作就 +1：自动收起的计时从头算
    @State private var chromeActivity = 0
    /// 指针在画面里的位置（不在画面里为 nil）：停在左上角片名一带或底部控制面板一带时控制层不收
    @State private var pointer: CGPoint?
    @State private var size: CGSize = .zero
    @State private var panel: MacPlayerPanelKind?
    @State private var scrubMs: Int?
    @State private var trickplay = TrickplayImages()
    @State private var flash: MacPlayerFlash?
    /// 已经出过画面的播放单元：起播封面只在每个单元（每一集）出第一帧之前显示
    @State private var startedUnit: PlaybackUnit?
    @State private var sleepGuard = MacDisplaySleepGuard()
    @FocusState private var keyFocus: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                video(size: proxy.size)
                surface
                if showCover {
                    MacPlayerCover(controller: controller)
                        .transition(.opacity)
                }
                // 出错时控制层仍在、压在对话框之上：这一档放不出来时（如限了画质而服务端转不了），
                // 用户能直接在控制面板里改回「自动」画质或换音轨，而不只有「重试 / 关闭」
                if chromeVisible, controller.infoError == nil, controller.phase != .consent {
                    chrome(size: proxy.size)
                        .transition(.opacity)
                        .zIndex(controller.phase == .error ? 2 : 0)
                }
                if controller.phase.isBusy, !isModal {
                    MacPlayerBusyView(controller: controller)
                }
                if let flash {
                    MacPlayerFlashView(flash: flash)
                        .id(flash.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                contextualCorner
                if let notice = controller.notice {
                    VStack {
                        MacPlayerNotice(text: notice)
                        Spacer()
                    }
                    .padding(.top, 20)
                    .transition(.opacity)
                }
                dialogs
                    .zIndex(1)
            }
            .background(MacPointerTracker(onMove: pointerMoved))
            .coordinateSpace(.named(MacPlayerMetrics.space))
            .onChange(of: subtitleLiftKey(size: proxy.size)) {
                applySubtitleLift(size: proxy.size)
            }
            .onChange(of: proxy.size, initial: true) { _, new in size = new }
        }
        // 窗口不在前台时第一下点击也直接生效（点画面就暂停、点进度条就跳），同 IINA；不必先点一下激活窗口
        .allowsWindowActivationEvents(true)
        .focusable()
        .focusEffectDisabled()
        .focused($keyFocus)
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .animation(.easeOut(duration: 0.18), value: panel)
        .animation(.easeInOut(duration: 0.2), value: controller.notice)
        .animation(.easeOut(duration: 0.18), value: flash?.id)
        .animation(.easeInOut(duration: 0.45), value: showCover)
        .task(id: autoHideKey) {
            // 控制层 3 秒无操作自动收起，鼠标指针一起藏（指针在本窗口里时）；暂停、拖动、面板开着、停在控件上、出错时一直显示
            guard chromeVisible, !chromeMustStayVisible else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            chromeVisible = false
            if window.pointerInside { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .task(id: flash?.id) {
            guard flash != nil else { return }
            try? await Task.sleep(for: .milliseconds(650))
            if !Task.isCancelled { flash = nil }
        }
        .onChange(of: controller.phase, initial: true) { _, phase in
            if phase == .playing, startedUnit != controller.unit {
                startedUnit = controller.unit
                // 每个单元出画面时窗口贴合它的比例（换集、降档换了片源比例也跟着变）
                if let video = controller.engine?.videoSize { window.fit(to: video) }
            }
            debugLog("状态 \(phase) 位置 \(controller.positionMs / 1000) 秒")
        }
        .onChange(of: controller.paused, initial: true) { _, paused in
            sleepGuard.update(playing: !paused)
        }
        .onChange(of: engineID, initial: true) {
            // 降档、换集都会换一个新引擎：音量设回去
            volume.apply(to: controller.engine)
        }
        .onChange(of: volume.effective) {
            volume.apply(to: controller.engine)
        }
        .onChange(of: controller.session?.segments?.count) {
            debugLog("片段标记 \(controller.session?.segments?.map { "\($0.type) \($0.startMs / 1000)～\($0.endMs / 1000) 秒" } ?? [])")
        }
        .onAppear {
            // 接过键盘：空格、方向键直接给播放器（侧边栏搜索框之前拿着焦点时也一样）
            keyFocus = true
        }
        #if DEBUG
        .onReceive(DistributedNotificationCenter.default().publisher(for: MacPlayerDebug.pointerNotification)) { note in
            // 并行的几个调试实例各认各的：对象末尾「@调试目录」不是本实例的不理
            guard let raw = note.object as? String, raw.hasSuffix("@" + MacPlayerDebug.directory) else { return }
            pointerMoved(MacPlayerDebug.point(from: String(raw.dropLast(MacPlayerDebug.directory.count + 1))))
        }
        #endif
        .onDisappear {
            sleepGuard.update(playing: false)
        }
    }

    // MARK: 画面

    @ViewBuilder
    private func video(size: CGSize) -> some View {
        if let engine = controller.engine {
            EngineSurface(engineView: engine.view)
                .id(ObjectIdentifier(engine))
                .accessibilityIdentifier("mac-player-video")
            // 服务端流的文字字幕由叠加层画（自研引擎直出时字幕由引擎画在画面里，这里地址为空）
            SubtitleOverlay(
                url: controller.overlaySubtitleURL,
                style: liftedSubtitleStyle(size: size),
                videoSize: engine.videoSize,
                time: { Double(controller.originMs) / 1000 + (controller.engine?.currentTime ?? 0) },
                session: controller.scope.api.session
            )
            .allowsHitTesting(false)
        }
    }

    /// 画面这块：单击只唤出控制层（面板开着时先收面板），不切播放 / 暂停——拖窗口、点回窗口时太容易误触，
    /// 播放 / 暂停只走控制栏的按钮与空格；双击 全屏（按 AppKit 事件自带的连击数认，与系统对「双击」的判定一致）
    private var surface: some View {
        Color.clear
            .contentShape(.rect)
            // 按住画面任意处拖动就是拖窗口（同 Infuse）；单击、双击照旧
            .gesture(WindowDragGesture())
            .onTapGesture {
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    toggleFullScreen()
                    return
                }
                panel = nil
                showChrome()
            }
            .accessibilityElement()
            .accessibilityLabel("画面")
            .accessibilityValue(stateSummary)
            .accessibilityIdentifier("mac-player-surface")
    }

    // MARK: 控制层

    private func chrome(size: CGSize) -> some View {
        ZStack {
            // 托字的渐变：顶部压暗给片名，底部由下往上 30%→0 给玻璃面板（HIG：clear 玻璃在亮画面上要垫压暗层）
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack {
                    MacPlayerTopBar(controller: controller, showsWindowControls: !window.isFullScreen, close: close)
                    Spacer(minLength: 0)
                }
                // 窗口模式：红绿灯落在系统标题栏原来的位置（左 19、中线距顶 26），打开播放器时不跳
                .padding(.leading, window.isFullScreen ? 20 : 19)
                .padding(.top, window.isFullScreen ? 16 : 9)
                Spacer(minLength: 0)
                MacPlayerTransport(
                    controller: controller, trickplay: trickplay, volume: volume, isFullScreen: window.isFullScreen,
                    pointer: pointer, scrubMs: $scrubMs, panel: $panel, togglePlay: { togglePlay(flashes: false) },
                    skip: { seek(by: $0, flashes: false) }, toggleFullScreen: toggleFullScreen
                )
                .overlay(alignment: .bottomTrailing) {
                    panelView(maxHeight: max(160, min(380, size.height - 260)))
                        .offset(y: -(MacPlayerMetrics.panelHeight + 10))
                }
                .frame(width: max(360, min(size.width - MacPlayerMetrics.panelSideInset * 2, MacPlayerMetrics.panelMaxWidth)))
                .padding(.bottom, MacPlayerMetrics.panelBottom)
            }
        }
    }

    @ViewBuilder
    private func panelView(maxHeight: CGFloat) -> some View {
        switch panel {
        case .tracks:
            MacTracksPanel(controller: controller, maxHeight: maxHeight) { panel = nil }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
        case .quality:
            MacQualityPanel(controller: controller) { panel = nil }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
        case nil:
            EmptyView()
        }
    }

    /// 右下角：换画质建议 / 跳过片头 / 下一集卡片（同一个角落，同时只出一个）。控制层出现时让到面板上方
    private var contextualCorner: some View {
        // 叠放而不是横排：换下来的那个淡出期间还占着位置，横排会把新来的挤出窗口右边
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .allowsHitTesting(false)
            if let offer = controller.qualityOffer {
                MacQualityOfferCard(offer: offer, accept: controller.acceptQualityOffer, dismiss: controller.dismissQualityOffer)
                    .transition(Self.cornerTransition)
            } else if let segment = controller.skipSegment {
                MacSkipButton(segment: segment, action: controller.skipCurrentSegment)
                    .transition(Self.cornerTransition)
            } else if controller.showsUpNext, let next = controller.nextEpisode {
                MacUpNextCard(
                    episode: next,
                    still: controller.scope.api.image(next.stillUrl, width: ImageWidth.macCard(MacUpNextCard.stillWidth)),
                    countdown: controller.autoNextArmed ? controller.autoNextProgress : nil,
                    play: {
                        controller.noteUserActivity()
                        controller.playNext()
                    },
                    dismiss: {
                        controller.noteUserActivity()
                        controller.nextDismissed = true
                    }
                )
                .transition(Self.cornerTransition)
                // 倒计时的钟：卡片在才走（同 iPhone、Apple TV 版）
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        controller.advanceAutoNext(by: 0.1)
                    }
                }
            }
        }
        .padding(.trailing, 32)
        .padding(.bottom, chromeVisible ? MacPlayerMetrics.chromeHeight + 12 : 32)
        .opacity(isModal ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: cornerKey)
    }

    /// 右下角元素的进出：原地淡入淡出、略微缩放，不跟着换下来的那个滑位置
    private static let cornerTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing))

    @ViewBuilder
    private var dialogs: some View {
        if let infoError = controller.infoError {
            // 条目信息都拿不到（无权访问、已删除）：整页换成原因 +「返回」
            MacPlayerDialog(title: infoError, message: nil, primary: ("返回", close), secondary: nil)
        } else if controller.phase == .error, let message = controller.errorMessage {
            MacPlayerDialog(title: message, message: controller.errorSuggestion, primary: ("重试", controller.retry),
                            secondary: ("关闭", close))
        } else if controller.phase == .consent, let decision = controller.pendingDecision {
            MacConsentDialog(decision: decision, grant: controller.grantConsent, cancel: close)
        }
    }

    // MARK: 状态

    private var isModal: Bool {
        controller.infoError != nil || controller.phase == .error || controller.phase == .consent
    }

    private var showCover: Bool {
        startedUnit != controller.unit && !isModal
    }

    /// 用户自己按的暂停（缓冲、换流时的程序性暂停不算）
    private var userPaused: Bool {
        controller.paused && !controller.wantsPlay && !controller.phase.isBusy && controller.session != nil
    }

    /// 控制层必须常显：暂停时用户在找进度；正在拖；面板开着；鼠标停在控件上；正在起播 / 缓冲（看得到进度与返回键）；播完了
    private var chromeMustStayVisible: Bool {
        userPaused || scrubMs != nil || panel != nil || pointerOnChrome || isModal || controller.phase.isBusy
            || controller.phase == .ended
    }

    /// 指针停在控件一带：左上角片名（顶上 70 点、左半边）或底部控制面板那一条
    private var pointerOnChrome: Bool {
        guard let pointer, size.height > 0 else { return false }
        return (pointer.y < 70 && pointer.x < size.width / 2) || pointer.y > size.height - MacPlayerMetrics.chromeHeight - 4
    }

    private var autoHideKey: String {
        "\(chromeVisible)-\(chromeMustStayVisible)-\(chromeActivity)"
    }

    private var engineID: ObjectIdentifier? {
        controller.engine.map { ObjectIdentifier($0) }
    }

    private var cornerKey: String {
        "\(controller.qualityOffer != nil)-\(controller.skipSegment?.type ?? "")-\(controller.showsUpNext)"
    }

    /// 调试驱动读的状态摘要（控件树里 mac-player-surface 的值）
    private var stateSummary: String {
        "\(controller.phase) \(controller.positionMs / 1000)s \(controller.paused ? "paused" : "playing") "
            + "\(controller.engine?.kind.rawValue ?? "-") fs=\(window.isFullScreen) vol=\(Int(volume.effective * 100))"
    }

    // MARK: 字幕避让

    /// 控制层出现时字幕该抬到多高：字幕底边（距画面底部 bottomPercent%）若会落进面板所在的那一条，
    /// 就抬到面板顶边之上；画面有黑边、本来就够高时不变
    private func liftedSubtitleStyle(size: CGSize) -> SubtitleStyle {
        var style = controller.subtitleStyle
        guard chromeVisible, !isModal, let videoSize = controller.engine?.videoSize, size.height > 0 else { return style }
        let rect = Self.fittedRect(videoSize, in: size)
        guard rect.height > 0 else { return style }
        let chromeTop = size.height - MacPlayerMetrics.chromeHeight
        let needed = (rect.maxY - chromeTop) / rect.height * 100
        if needed > style.bottomPercent { style.bottomPercent = min(40, needed.rounded(.up)) }
        return style
    }

    private func subtitleLiftKey(size: CGSize) -> String {
        "\(engineID.map { "\($0.hashValue)" } ?? "-")-\(liftedSubtitleStyle(size: size).bottomPercent)"
    }

    /// 自研引擎直出时字幕画在引擎里：把抬高后的样式临时交给引擎（不写回用户设置）
    private func applySubtitleLift(size: CGSize) {
        controller.engine?.applySubtitleStyle(liftedSubtitleStyle(size: size))
    }

    private static func fittedRect(_ video: CGSize, in size: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / video.width, size.height / video.height)
        let fitted = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    // MARK: 操作

    /// 指针动了：控制层浮现、自动收起重新计时。只认真的移动——控制层淡入淡出、窗口重绘时系统也会补发移动事件，
    /// 位置没变就不算有人在动
    private func pointerMoved(_ point: CGPoint?) {
        guard point != pointer else { return }
        pointer = point
        if point != nil {
            showChrome()
        } else if chromeVisible, scrubMs == nil, panel == nil, !isModal, !controller.phase.isBusy, controller.phase != .ended {
            // 指针离开播放器：控制层（含左上角返回）立刻淡出，不等 3 秒无操作。
            // 拖进度条拖出窗口、面板或对话框开着、起播中、播完时照旧留着
            chromeVisible = false
        }
    }

    private func showChrome() {
        if !chromeVisible { chromeVisible = true }
        chromeActivity += 1
    }

    private func togglePlay(flashes: Bool = true) {
        controller.noteUserActivity()
        guard !isModal else { return }
        controller.togglePlay()
        showChrome()
        if flashes { flash = MacPlayerFlash(symbol: controller.wantsPlay ? "play.fill" : "pause.fill") }
    }

    private func seek(by seconds: Double, flashes: Bool = true) {
        controller.noteUserActivity()
        guard !isModal, controller.session != nil else { return }
        controller.seek(by: seconds, source: flashes ? .remote : .button)
        showChrome()
        if flashes { flash = MacPlayerFlash(symbol: seconds < 0 ? "gobackward.10" : "goforward.10") }
    }

    private func toggleFullScreen() {
        window.toggleFullScreen()
        showChrome()
    }

    private func changeVolume(by delta: Double) {
        volume.step(by: delta)
        flash = MacPlayerFlash(symbol: volume.symbol, text: "\(Int((volume.level * 100).rounded()))%")
    }

    private func toggleMute() {
        volume.toggleMute()
        flash = MacPlayerFlash(symbol: volume.symbol, text: volume.muted ? "静音" : "\(Int((volume.level * 100).rounded()))%")
    }

    /// Esc：收起面板 → 退出全屏 → 关闭播放器
    private func escape() {
        if panel != nil {
            panel = nil
        } else if window.isFullScreen {
            window.toggleFullScreen()
        } else {
            close()
        }
    }

    // MARK: 键盘

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers.intersection([.command, .control, .option, .shift])
        let once = press.phase == .down
        switch press.key {
        case .space where modifiers.isEmpty:
            if once { togglePlay() }
        case .leftArrow where modifiers.isEmpty || modifiers == .option:
            seek(by: -10)
        case .rightArrow where modifiers.isEmpty || modifiers == .option:
            seek(by: 10)
        case .leftArrow where modifiers == .command:
            if once { controller.playPrevious() }
        case .rightArrow where modifiers == .command:
            if once {
                controller.noteUserActivity()
                controller.playNext()
            }
        case .upArrow where modifiers.isEmpty || modifiers == .command:
            changeVolume(by: 0.1)
        case .downArrow where modifiers.isEmpty || modifiers == .command:
            changeVolume(by: -0.1)
        case .escape where modifiers.isEmpty:
            if once { escape() }
        default:
            let character = press.key.character.lowercased()
            if character == ".", modifiers == .command {
                if once { close() }
            } else if character == "f", modifiers.isEmpty || modifiers == [.control, .command] {
                if once { toggleFullScreen() }
            } else if character == "m", modifiers.isEmpty {
                if once { toggleMute() }
            } else {
                return .ignored
            }
        }
        return .handled
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[MacPlayer] \(message)\n".utf8))
        #endif
    }
}

#if DEBUG
/// 开发期验收用的指针钩子：调试驱动合成的鼠标移动事件到不了 AppKit 追踪区（追踪区只认窗口服务器的真实移动），
/// 又不能为了验收去挪用户的真鼠标。外面的脚本发一条分布式通知（对象是「x,y@调试目录」，窗口坐标、左上角为原点；「none@调试目录」= 指针离开），
/// 播放器当作指针移到了那里：控制层浮现、进度条悬停预览都走与真鼠标同一条路径（`pointerMoved`）
enum MacPlayerDebug {
    static let pointerNotification = Notification.Name("MovieClaw.debug.playerPointer")
    /// 本实例的调试目录（-mcDebugDir，同 MacDebugDriver）
    static let directory = UserDefaults.standard.string(forKey: "mcDebugDir") ?? "/tmp/movieclaw-mac-debug"

    static func point(from raw: String?) -> CGPoint? {
        let parts = (raw ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }
}
#endif
