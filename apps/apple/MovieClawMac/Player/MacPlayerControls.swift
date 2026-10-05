import SwiftUI

// 播放器的控制层（docs/design/macos-app.md、Mac 设计调研 SPEC §4.7）：
// - 左上角：返回 + 片名 / 「第 X 季第 Y 集 · 集名」；
// - 底部居中一块两行的液态玻璃面板（排法同 Infuse / QuickTime / IINA 的浮动控制栏）：
//   上行左边音量（滑条常驻）、正中「上一集 · 后退 10 秒 · 播放 / 暂停 · 前进 10 秒 · 下一集」（上一集 / 下一集只在剧集出现）、
//   右边音频与字幕、画质、全屏；下行「已播 — 整条进度条（胶囊滑块常驻）— 剩余」。
//   宽 min(窗口宽 − 96, 720)、高 100、距底 24；材质是标准玻璃（暗画面上略亮、边缘有高光与折射，同 Infuse），
//   下面垫一层淡的黑色渐变托字。图标大而实，播放键最大。
// 开关类按钮的状态不只靠颜色（吸取 Apple Music 胶囊的教训）：字幕开着用实心气泡，关着用空心。

/// 控制层尺寸：胶囊与字幕避让、右下角按钮都按它算
enum MacPlayerMetrics {
    static let panelHeight: CGFloat = 100
    static let panelMaxWidth: CGFloat = 720
    static let panelBottom: CGFloat = 24
    static let panelCorner: CGFloat = 22
    /// 面板两侧至少留的窗口边距（合计 96）
    static let panelSideInset: CGFloat = 48
    /// 面板顶边距窗口底边：字幕要抬到它上面
    static var chromeHeight: CGFloat { panelBottom + panelHeight + 12 }
    /// 播放器的坐标空间（左上角为原点）：指针位置按它记，进度条据此算悬停在哪
    static let space = "mac-player"
}

/// 左上角：返回按钮 + 片名两行
struct MacPlayerTopBar: View {
    let controller: PlaybackController
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("关闭播放器（Esc）")
            .accessibilityLabel("关闭播放器")
            .accessibilityIdentifier("mac-player-close")

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let line = Self.episodeLine(controller) {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mac-player-title")
        }
        .foregroundStyle(.white)
    }

    /// 「第 1 季第 2 集 · 集名」（电影没有这一行）
    static func episodeLine(_ controller: PlaybackController) -> String? {
        let unit = controller.unit
        guard unit.isEpisode else { return nil }
        let code = "第 \(unit.season) 季第 \(unit.episode) 集"
        if let name = controller.currentEpisode?.name, !name.isEmpty { return "\(code) · \(name)" }
        return code
    }
}

/// 底部的玻璃控制面板
struct MacPlayerTransport: View {
    let controller: PlaybackController
    let trickplay: TrickplayImages
    @Bindable var volume: MacPlayerVolume
    let isFullScreen: Bool
    /// 指针位置（播放器坐标空间），进度条的悬停预览用
    let pointer: CGPoint?
    @Binding var scrubMs: Int?
    @Binding var panel: MacPlayerPanelKind?
    let togglePlay: () -> Void
    let skip: (Double) -> Void
    let toggleFullScreen: () -> Void

    /// 时间显示：右边是剩余时间还是总时长（点一下切换，同 QuickTime）
    @AppStorage("movieclaw.mac.player.showsTotal") private var showsTotal = false

    var body: some View {
        let duration = controller.timelineDurationMs ?? 0
        let position = controller.timelineMs(fromFileMs: scrubMs ?? controller.positionMs)
        VStack(spacing: 0) {
            // 上行：两侧等宽，播放键永远在正中
            HStack(spacing: 0) {
                MacVolumeControl(volume: volume)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 22) {
                    if controller.unit.isEpisode {
                        MacPlayerIconButton(symbol: "backward.end.fill", size: 17, help: "上一集（⌘←）", id: "mac-player-previous") {
                            controller.playPrevious()
                        }
                        .disabled(controller.previousEpisode == nil)
                    }
                    MacPlayerIconButton(symbol: "gobackward.10", size: 21, help: "后退 10 秒（←）", id: "mac-player-back10") { skip(-10) }
                    MacPlayerIconButton(symbol: playSymbol, size: 30, diameter: 48,
                                        help: controller.paused ? "播放（空格）" : "暂停（空格）",
                                        id: "mac-player-play", action: togglePlay)
                        .accessibilityLabel(controller.paused ? "播放" : "暂停")
                    MacPlayerIconButton(symbol: "goforward.10", size: 21, help: "前进 10 秒（→）", id: "mac-player-fwd10") { skip(10) }
                    if controller.unit.isEpisode {
                        MacPlayerIconButton(symbol: "forward.end.fill", size: 17, help: "下一集（⌘→）", id: "mac-player-next") {
                            controller.noteUserActivity()
                            controller.playNext()
                        }
                        .disabled(controller.nextEpisode == nil)
                    }
                }
                HStack(spacing: 6) {
                    MacPlayerIconButton(symbol: controller.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill",
                                        size: 18, help: "字幕与音轨", id: "mac-player-tracks", active: panel == .tracks) {
                        panel = panel == .tracks ? nil : .tracks
                    }
                    if controller.scope.shareSlug == nil {
                        qualityButton
                    }
                    MacPlayerIconButton(symbol: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                        size: 17, help: isFullScreen ? "退出全屏（F）" : "全屏（F）", id: "mac-player-fullscreen",
                                        action: toggleFullScreen)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 54)

            // 下行：已播 — 进度条（占满）— 剩余
            HStack(spacing: 10) {
                Text(Formatters.clock(Double(position) / 1000))
                    .frame(minWidth: 46, alignment: .leading)
                    .accessibilityIdentifier("mac-player-time")
                    .accessibilityValue("\(position)")
                MacScrubber(controller: controller, trickplay: trickplay, pointer: pointer, scrubMs: $scrubMs)
                Button {
                    showsTotal.toggle()
                } label: {
                    // 片长还不知道（起播中）时显示占位，不显示「-0:00」
                    Text(duration <= 0 ? "--:--" : showsTotal ? Formatters.clock(Double(duration) / 1000)
                         : "-" + Formatters.clock(Double(max(0, duration - position)) / 1000))
                        .frame(minWidth: 46, alignment: .trailing)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(showsTotal ? "显示剩余时间" : "显示总时长")
                .accessibilityIdentifier("mac-player-remaining")
            }
            .frame(height: 30)
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(height: MacPlayerMetrics.panelHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: MacPlayerMetrics.panelCorner))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-player-transport")
    }

    private var playSymbol: String {
        if controller.phase == .ended { return "arrow.counterclockwise" }
        return controller.paused && !controller.wantsPlay ? "play.fill" : "pause.fill"
    }

    /// 画质：一枚小字徽标写着当前档（自动 / 1080p…），点开选档
    private var qualityButton: some View {
        let label = QualityOption.all.first { $0.maxHeight == controller.quality }?.label ?? "原画"
        return Button {
            panel = panel == .quality ? nil : .quality
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .bold))
                .padding(.horizontal, 7)
                .frame(height: 20)
                .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1.4))
                .frame(minWidth: 34, minHeight: 34)
                .contentShape(.rect)
        }
        .buttonStyle(MacPlayerButtonStyle(active: panel == .quality))
        .help("画质")
        .accessibilityLabel("画质：\(label)")
        .accessibilityIdentifier("mac-player-quality")
    }
}

/// 面板里的图标按钮：悬停时浮出一层淡白底，按下略暗
struct MacPlayerIconButton: View {
    let symbol: String
    var size: CGFloat = 15
    /// 点按区域与悬停底的直径
    var diameter: CGFloat = 34
    let help: String
    let id: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .contentShape(.rect)
        }
        .buttonStyle(MacPlayerButtonStyle(active: active))
        .help(help)
        .accessibilityIdentifier(id)
    }
}

struct MacPlayerButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, active: active)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let active: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    Circle()
                        .fill(.white.opacity(!enabled ? 0 : configuration.isPressed ? 0.24 : active ? 0.2 : hovering ? 0.12 : 0))
                }
                // 不可用（没有上一集 / 下一集）时淡下去
                .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.75 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// 音量：喇叭图标（点一下静音）+ 常驻滑条（白色胶囊滑块，同 Infuse）
struct MacVolumeControl: View {
    @Bindable var volume: MacPlayerVolume

    private static let sliderWidth: CGFloat = 100

    var body: some View {
        HStack(spacing: 6) {
            MacPlayerIconButton(symbol: volume.symbol, size: 17, help: volume.muted ? "取消静音（M）" : "静音（M）",
                                id: "mac-player-mute") { volume.toggleMute() }
                .accessibilityValue(volume.muted ? "已静音" : "\(Int(volume.level * 100))%")
            slider
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-player-volume")
    }

    private var slider: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = volume.muted ? 0 : volume.level
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: width * fraction)
            }
            .frame(height: 4)
            .overlay(alignment: .leading) {
                MacSliderKnob(width: 22, height: 13)
                    .offset(x: MacSliderKnob.offset(fraction: fraction, width: width, knob: 22))
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                volume.muted = false
                volume.level = min(1, max(0, value.location.x / width))
            })
        }
        .frame(width: Self.sliderWidth, height: 34)
        .accessibilityElement()
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int(volume.level * 100))%")
        .accessibilityIdentifier("mac-player-volume-slider")
    }
}

/// 滑条上的白色胶囊滑块（音量、进度条共用）
struct MacSliderKnob: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(.white)
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    /// 滑块左边缘的横坐标：滑块整个落在滑条里（两端不出头）
    static func offset(fraction: CGFloat, width: CGFloat, knob: CGFloat) -> CGFloat {
        min(max(0, width * fraction - knob / 2), max(0, width - knob))
    }
}

/// 进度条：已缓冲 / 已播放 / 胶囊滑块。悬停时变粗、滑块略放大，上方显示那一点的缩略图（服务端雪碧图）与时间
/// （悬停按播放器统一跟踪的指针位置算，见 `MacPointerTracker`）；
/// 按下即跳、按住拖动时画面跟着走（`scrubFollow`），松手精确跳到落点。时间一律按时间轴算（片段模式下是这一段）
struct MacScrubber: View {
    let controller: PlaybackController
    let trickplay: TrickplayImages
    let pointer: CGPoint?
    @Binding var scrubMs: Int?

    /// 缩略图宽（点）：雪碧图格子按它缩放
    private static let previewWidth: CGFloat = 192

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = controller.timelineDurationMs ?? 0
            let position = controller.timelineMs(fromFileMs: scrubMs ?? controller.positionMs)
            let buffered = controller.bufferedEndMs.map { controller.timelineMs(fromFileMs: $0) } ?? 0
            let playedX = width * fraction(position, of: duration)
            let hoverX = hoverX(in: proxy.frame(in: .named(MacPlayerMetrics.space)))
            let thick = hoverX != nil || scrubMs != nil
            let knob: CGFloat = thick ? 26 : 22
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.32))
                    .frame(width: width * fraction(buffered, of: duration))
                Capsule().fill(.white)
                    .frame(width: playedX)
            }
            .frame(height: thick ? 7 : 5)
            .overlay(alignment: .leading) {
                // 胶囊滑块常驻（同 Infuse），悬停 / 拖动时略放大
                MacSliderKnob(width: knob, height: thick ? 15 : 13)
                    .offset(x: MacSliderKnob.offset(fraction: width > 0 ? playedX / width : 0, width: width, knob: knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .overlay(alignment: .bottom) {
                // 悬停 / 拖动时的预览：拖动时跟着播放头，单纯悬停时跟着鼠标；底边在进度条上方 26 点
                if duration > 0, let x = scrubMs != nil ? playedX : hoverX {
                    preview(fileMs: fileMs(at: x, width: width, duration: duration))
                        .fixedSize()
                        .offset(x: x - width / 2, y: -(proxy.size.height / 2 + 26))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0 else { return }
                controller.noteUserActivity()
                let target = fileMs(at: value.location.x, width: width, duration: duration)
                scrubMs = target
                controller.scrubFollow(toFileMs: target)
            }.onEnded { value in
                guard duration > 0 else { return }
                controller.seek(toFileMs: fileMs(at: value.location.x, width: width, duration: duration), source: .scrub)
                scrubMs = nil
            })
            .animation(.easeOut(duration: 0.12), value: thick)
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(Formatters.clock(Double(controller.timelineMs(fromFileMs: controller.positionMs)) / 1000))
        .accessibilityIdentifier("mac-player-scrubber")
    }

    /// 指针悬停处在进度条上的横坐标（不在进度条一带为 nil）
    private func hoverX(in frame: CGRect) -> CGFloat? {
        guard let pointer, frame.insetBy(dx: -4, dy: 0).contains(pointer) else { return nil }
        return min(max(0, pointer.x - frame.minX), frame.width)
    }

    private func fraction(_ value: Int, of total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(max(0, value), total)) / CGFloat(total)
    }

    /// 横坐标 → 文件时间
    private func fileMs(at x: CGFloat, width: CGFloat, duration: Int) -> Int {
        let ratio = width > 0 ? min(max(0, x / width), 1) : 0
        return controller.timelineStartMs + Int(ratio * CGFloat(duration))
    }

    /// 缩略图（雪碧图还没下完 / 服务端没有时只显示时间）+ 时间
    private func preview(fileMs: Int) -> some View {
        VStack(spacing: 6) {
            if let image = trickplay.tile(controller.trickplay, atMs: fileMs, resolve: controller.scope.streamURL,
                                          session: controller.scope.api.session) {
                Image(native: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.previewWidth)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
            }
            Text(Formatters.clock(Double(controller.timelineMs(fromFileMs: fileMs)) / 1000))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: .capsule)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac-player-preview")
    }
}
