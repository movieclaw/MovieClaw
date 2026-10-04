import SwiftUI

// 播放器上的各种浮层（Mac 版）：起播封面、转圈、提示、按键反馈、跳过 / 下一集 / 换画质建议、出错与需要转码的对话框。
// 文案与 iPhone、Apple TV 版一一对应（PlayerOverlays.swift、TVPlayerOverlays.swift），尺寸按桌面距离收小，
// 按钮都是可点的玻璃按钮。

/// 起播封面：画面出来之前先铺剧照（剧集用这一集的剧照，电影用海报模糊），中间是片名与转圈，
/// 不让用户对着一块黑屏等。出第一帧后淡出
struct MacPlayerCover: View {
    let controller: PlaybackController

    var body: some View {
        ZStack {
            Color.black
            if let still = controller.currentEpisode?.stillUrl {
                RemoteImage(url: controller.scope.api.image(still, width: ImageWidth.screen), placeholderText: "")
                    .opacity(0.45)
                    .clipped()
                    .transition(.opacity)
            } else if let poster = controller.info?.posterUrl {
                MacBlurredBackdrop(url: controller.scope.api.image(poster, width: ImageWidth.macCard(MacMetrics.blurredBackdropWidth)))
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Text(controller.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let line = MacPlayerTopBar.episodeLine(controller) {
                    Text(line)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 10)
            .padding(.horizontal, 60)
            .offset(y: -110)
        }
        .animation(.easeInOut(duration: 0.4), value: controller.currentEpisode?.stillUrl)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac-player-cover")
    }
}

/// 起播 / 缓冲转圈：说清楚卡在哪一段，下面一行实时加载速度
struct MacPlayerBusyView: View {
    let controller: PlaybackController

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(controller.phase.busyLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            if let speed = controller.speedLabel {
                Text("↓ \(speed)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 18))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac-player-busy")
    }
}

/// 顶部居中的一句话提示（换轨、降档、网络提示）
struct MacPlayerNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(.black.opacity(0.2)), in: .capsule)
            .accessibilityIdentifier("mac-player-notice")
    }
}

/// 按键反馈：空格、←→、↑↓、M 这些操作在画面正中闪一下（图标 + 一行字），控制层收着时也知道按到了
struct MacPlayerFlash: Equatable {
    let symbol: String
    var text: String?
    /// 每次都不同：连按同一个键也重新闪
    let id = UUID()
}

struct MacPlayerFlashView: View {
    let flash: MacPlayerFlash

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: flash.symbol)
                .font(.system(size: 30, weight: .semibold))
            if let text = flash.text {
                Text(text)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .frame(width: 96, height: 96)
        .background(.black.opacity(0.42), in: .rect(cornerRadius: 22))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac-player-flash")
    }
}

/// 「跳过片头 / 片尾」：片头片尾时段右下角浮现，点一下跳到这一段结束处。
/// 不用系统的玻璃按钮样式：窗口不在前台时（边看片边在别的 App 里干活）系统按钮会变成灰字的非激活外观，
/// 压在画面上几乎看不清；这里自己画玻璃胶囊，前后台都是白字
struct MacSkipButton: View {
    let segment: API.PlaybackSegmentView
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(SkipSegments.label(segment), systemImage: "forward.end.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.black.opacity(0.25)).interactive(), in: .capsule)
        .accessibilityIdentifier("mac-player-skip")
        .accessibilityValue(segment.type)
    }
}

/// 片尾「下一集」卡片：剧照 + 集数集名；认出了片尾时卡片底边是倒计时进度，走满自动换集。右上角 ✕ 收起不再提示
struct MacUpNextCard: View {
    let episode: API.EpisodeView
    let still: URL?
    /// 倒计时进度 0～1；nil = 没在倒计时（只提示，不自动换集）
    let countdown: Double?
    let play: () -> Void
    let dismiss: () -> Void

    static let stillWidth: CGFloat = 136
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 14) {
                ZStack {
                    RemoteImage(url: still)
                        .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
                        .clipShape(.rect(cornerRadius: 8))
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .shadow(radius: 6)
                        .opacity(hovering ? 1 : 0.85)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(countdown == nil ? "下一集" : "即将播放")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("第 \(episode.episodeNumber) 集")
                        .font(.system(size: 14, weight: .semibold))
                    if let name = episode.name, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                }
                .frame(width: 170, alignment: .leading)
            }
            .padding(12)
            .overlay(alignment: .bottom) {
                if let countdown {
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white)
                            .frame(width: proxy.size.width * countdown)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 5)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.regular.tint(.black.opacity(0.2)).interactive(), in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.5), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .offset(x: 6, y: -6)
            .help("不看下一集")
            .accessibilityLabel("收起下一集")
            .accessibilityIdentifier("mac-player-upnext-dismiss")
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-player-upnext")
    }
}

/// 网速跟不上时的换画质建议（同 iPhone 版 PlayerQualityOfferView）
struct MacQualityOfferCard: View {
    let offer: QualitySuggestion.Offer
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("网速跟不上当前画质")
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("改用 \(offer.maxHeight)p", action: accept)
                    .buttonStyle(MacPlayerDialogButtonStyle(prominent: true))
                    .accessibilityIdentifier("mac-quality-offer-accept")
                Button("继续当前画质", action: dismiss)
                    .buttonStyle(MacPlayerDialogButtonStyle(prominent: false))
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-quality-offer")
    }

    private var detail: String {
        let measured = PlaybackController.formatBandwidth(offer.measuredBps) ?? "很慢"
        let required = PlaybackController.formatBandwidth(offer.requiredBps) ?? "更快"
        return "实测约 \(measured)，这一版需要约 \(required)。可以暂停攒一会缓冲再看，"
            + "或改用 \(offer.maxHeight)p（服务端转码，画质会降低）。"
    }
}

/// 出错 / 无法播放：后端中文原因 + 建议 + 按钮（回车 = 主按钮）
struct MacPlayerDialog: View {
    let title: String
    let message: String?
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.warning)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    if let secondary {
                        Button(secondary.0, action: secondary.1)
                            .buttonStyle(MacPlayerDialogButtonStyle(prominent: false))
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("mac-player-dialog-secondary")
                    }
                    Button(primary.0, action: primary.1)
                        .buttonStyle(MacPlayerDialogButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("mac-player-dialog-primary")
                }
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(width: 420)
            .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: 24))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-player-dialog")
    }
}

/// 需要服务端软件转码才能放：说明原因与代价，能自行开启的给「开启并播放」（文案同 iPhone 版 PlayerConsentView）
struct MacConsentDialog: View {
    let decision: API.PlaybackDecisionView
    let grant: () async throws -> Void
    let cancel: () -> Void

    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(alignment: .leading, spacing: 12) {
                Text("这部片需要软件转码才能播放")
                    .font(.system(size: 15, weight: .semibold))
                labeled("原因", decision.reason)
                if let cost = decision.costHint { labeled("代价", cost) }
                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                }
                if decision.canSelfEnable != true {
                    Text("当前未开启软件转码。请联系管理员开启（管理员播放此类影片时会收到开启询问）。")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 12) {
                    Spacer()
                    if decision.canSelfEnable == true {
                        Button("取消", action: cancel)
                            .buttonStyle(MacPlayerDialogButtonStyle(prominent: false))
                            .keyboardShortcut(.cancelAction)
                        Button(saving ? "正在开启…" : "开启并播放") {
                            Task {
                                saving = true
                                error = nil
                                do {
                                    try await grant()
                                } catch {
                                    self.error = error.localizedDescription
                                    saving = false
                                }
                            }
                        }
                        .buttonStyle(MacPlayerDialogButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving)
                        .accessibilityIdentifier("mac-consent-enable")
                    } else {
                        Button("知道了", action: cancel)
                            .buttonStyle(MacPlayerDialogButtonStyle(prominent: true))
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(width: 460, alignment: .leading)
            .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: 24))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-player-consent")
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 播放器浮层里的按钮（对话框、换画质建议）：主按钮白底黑字，次按钮深色玻璃白字。
/// 不用系统玻璃按钮样式的原因同 `MacSkipButton`：窗口在后台时系统按钮变成灰字，压在画面上看不清
struct MacPlayerDialogButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 18)
            .frame(minWidth: 84, minHeight: 32)
            .background {
                if prominent {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.75 : 0.95))
                } else {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.24 : 0.14))
                }
            }
            .contentShape(.capsule)
            .opacity(enabled ? 1 : 0.5)
    }
}
