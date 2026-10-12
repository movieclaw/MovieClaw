import SwiftUI

// 播放器上的各种浮层（电视版）：转圈、提示、暂停片名、跳过 / 下一集 / 换画质建议、出错与需要转码的对话框。
// 内容与 iPhone 版一一对应（文案同 PlayerOverlays.swift），尺寸按三米观看距离放大，按钮都是遥控器可聚焦的。

/// 起播 / 缓冲转圈：说清楚卡在哪一段，下面一行实时加载速度
struct TVPlayerBusyView: View {
    let controller: PlaybackController

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.6)
                .tint(.white)
            Text(controller.phase.busyLabel)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            if let speed = controller.speedLabel {
                Text("↓ \(speed)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tv-player-busy")
    }
}

/// 顶部的一句话提示（换轨、降档、网络提示）
struct TVPlayerNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("tv-player-notice")
    }
}

/// 暂停时左上角的片名（同 iPhone 版 PausedOverlay）
struct TVPausedTitle: View {
    let title: String
    let episodeLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已暂停")
                .font(.caption.weight(.semibold))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.6))
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(radius: 8)
            if let episodeLabel {
                Text(episodeLabel)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tv-player-paused")
    }
}

/// 「跳过片头 / 片尾」：出现时自动拿焦点，按一下跳到这一段结束处
struct TVSkipButton: View {
    let segment: API.PlaybackSegmentView
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(SkipSegments.label(segment), systemImage: "forward.end.fill")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("tv-player-skip")
        .accessibilityValue(segment.type)
    }
}

/// 片尾「下一集」卡片：剧照 + 集数集名，底下两颗按钮「下一集」「观看片尾」。
/// 倒计时时「下一集」按钮本身就是进度条（扫过的部分更亮），走满自动换集；焦点移到「观看片尾」就停掉倒计时，
/// 按下去收起卡片（由播放器接焦点变化 / 按键，见 TVPlayerScreen）
struct TVUpNextCard: View {
    let episode: API.EpisodeView
    let still: URL?
    /// 倒计时进度 0～1；nil = 没在倒计时（只提示，不自动换集）
    let countdown: Double?
    let play: () -> Void
    let watchCredits: () -> Void
    /// 播放器的焦点：两颗按钮分别是 `.upNext` / `.watchCredits`
    let focus: FocusState<TVPlayerFocus?>.Binding
    /// 卡片出现时默认焦点落在「下一集」上
    let focusScope: Namespace.ID

    /// 剧照宽（点）：取图按它 × 屏幕倍率 × 焦点放大
    static let stillWidth: CGFloat = 256

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 24) {
                RemoteImage(url: still)
                    .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
                    .clipShape(.rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(countdown == nil ? "下一集" : "即将播放")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("第 \(episode.episodeNumber) 集")
                        .font(.headline)
                    if let name = episode.name, !name.isEmpty {
                        Text(name)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(width: 300, alignment: .leading)
            }
            HStack(spacing: 20) {
                Button(action: play) { Label(nextTitle, systemImage: "play.fill") }
                    .focused(focus, equals: .upNext)
                    .prefersDefaultFocus(true, in: focusScope)
                    .buttonStyle(TVUpNextButtonStyle(progress: countdown))
                    .accessibilityIdentifier("tv-player-upnext")
                Button("观看片尾", action: watchCredits)
                    .focused(focus, equals: .watchCredits)
                    .buttonStyle(TVUpNextButtonStyle(progress: nil))
                    .accessibilityIdentifier("tv-player-upnext-credits")
            }
        }
        .padding(26)
        .frame(width: 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .focusSection()
        .accessibilityElement(children: .contain)
    }

    private var nextTitle: String {
        guard let countdown else { return "下一集" }
        let left = Double(SkipSegments.autoNextMs) * (1 - countdown) / 1000
        return "下一集 · \(max(1, Int(left.rounded(.up))))"
    }
}

/// 卡片上的按钮：获得焦点白底黑字、放大；带进度时底色分两段，扫过的部分更亮
private struct TVUpNextButtonStyle: ButtonStyle {
    let progress: Double?

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, progress: progress)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let progress: Double?
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(focused ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                .background {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(focused ? (progress == nil ? 1 : 0.6) : 0.12))
                            if let progress {
                                Rectangle().fill(.white.opacity(focused ? 1 : 0.3))
                                    .frame(width: proxy.size.width * progress)
                            }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 16))
                .scaleEffect(configuration.isPressed ? 1.02 : focused ? 1.08 : 1)
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20, y: 12)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// 网速跟不上时的换画质建议（同 iPhone 版 PlayerQualityOfferView）
struct TVQualityOfferCard: View {
    let offer: QualitySuggestion.Offer
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("网速跟不上当前画质")
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Button("改用 \(offer.maxHeight)p", action: accept)
                    .accessibilityIdentifier("tv-quality-offer-accept")
                Button("继续当前画质", action: dismiss)
            }
        }
        .padding(32)
        .frame(width: 640, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-quality-offer")
    }

    private var detail: String {
        let measured = PlaybackController.formatBandwidth(offer.measuredBps) ?? "很慢"
        let required = PlaybackController.formatBandwidth(offer.requiredBps) ?? "更快"
        return "实测约 \(measured)，这一版需要约 \(required)。可以暂停攒一会缓冲再看，"
            + "或改用 \(offer.maxHeight)p（服务端转码，画质会降低）。"
    }
}

/// 出错 / 无法播放：后端中文原因 + 建议 + 按钮（焦点落在主按钮上）
struct TVPlayerDialog: View {
    let title: String
    let message: String?
    let primary: (String, () -> Void)
    let secondary: (String, () -> Void)?
    /// 顶部图标；nil 不放（「还在看吗」不是出错）
    var icon: String? = "exclamationmark.triangle"

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 28) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.warning)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 30) {
                    Button(primary.0, action: primary.1)
                        .accessibilityIdentifier("tv-player-dialog-primary")
                    if let secondary {
                        Button(secondary.0, action: secondary.1)
                    }
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: 1000)
            .focusSection()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-player-dialog")
    }
}

/// 需要服务端软件转码才能放：说明原因与代价，能自行开启的给「开启并播放」（文案同 iPhone 版 PlayerConsentView）。
/// 电视上没有设置页，「去设置远程转码」这条提示不给
struct TVConsentDialog: View {
    let decision: API.PlaybackDecisionView
    let grant: () async throws -> Void
    let cancel: () -> Void

    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("这部片需要软件转码才能播放")
                    .font(.title3.weight(.semibold))
                labeled("原因", decision.reason)
                if let cost = decision.costHint { labeled("代价", cost) }
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Theme.danger)
                }
                if decision.canSelfEnable != true {
                    Text("当前未开启软件转码。请联系管理员开启（管理员播放此类影片时会收到开启询问）。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 30) {
                    if decision.canSelfEnable == true {
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
                        .disabled(saving)
                        .accessibilityIdentifier("tv-consent-enable")
                        Button("取消", action: cancel)
                    } else {
                        Button("知道了", action: cancel)
                    }
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .focusSection()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-player-consent")
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}
