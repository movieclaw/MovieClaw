import SwiftUI

/// 选集面板：底栏「选集」打开，点一集就换。摆在哪由 `EpisodeStageLayout` 定（横屏靠右、竖屏接在画面下面、
/// iPhone Duo 桌面模式占满折痕以下），这里只管面板里面。
///
/// 层次靠大小拉开：正在播的那一集单独成卡（剧照更大、实时进度、还剩多久，竖屏再加两行简介），其余的集是紧凑的行。
/// 简介只给正在播的这一集——没看过的集放简介就是剧透。状态不用标签：看完的集名变暗、带一个对勾，
/// 看了一半的剧照下有细进度条并写看到哪，缺集置灰点不动（留在列表里，让人知道这一季有多少集）。
///
/// 换季只换列表、不动正在播的；别的季现取（`PlaybackController.loadSeason`）。打开时停在正在播的那一集。
struct PlayerEpisodeDrawer: View {
    enum Style {
        /// 横屏侧栏：剧照小一号，简介不进卡片（写在让位后的画面下方）
        case sidebar
        /// 竖屏接在画面下面：剧照大一号，正在播的那集带两行简介
        case sheet
        /// iPhone Duo 桌面模式的下半屏：列表同竖屏（单列、大剧照、正在播的那集带简介）；收起是回到控制台，头部写「控制台」而不是 ✕
        case console
    }

    let controller: PlaybackController
    let style: Style
    let close: () -> Void

    /// 面板里正在看的季（不一定是正在播的季）
    @State private var season: Int
    /// 现取的别的季；取不到存空数组
    @State private var others: [Int: [API.EpisodeView]] = [:]
    @State private var position: Int?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: PlaybackController, style: Style, close: @escaping () -> Void) {
        self.controller = controller
        self.style = style
        self.close = close
        _season = State(initialValue: controller.unit.season)
        _position = State(initialValue: controller.unit.episode)
    }

    private var sidebar: Bool { style == .sidebar }
    private var playingSeason: Bool { season == controller.unit.season }
    private var episodes: [API.EpisodeView]? { playingSeason ? controller.episodes : others[season] }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .clipShape(.rect(cornerRadius: EpisodeStageLayout.drawerRadius))
        .glassEffect(PlayerGlass.panel, in: .rect(cornerRadius: EpisodeStageLayout.drawerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-episodes")
        .task { await controller.refreshEpisodes() }
        .task(id: season) {
            guard !playingSeason, others[season] == nil else { return }
            others[season] = await controller.loadSeason(season) ?? []
        }
        .onAppear { appeared = true }
        // 换了一集（点了某一行、自动连播）：列表跟到新的那一集
        .onChange(of: controller.unit) { _, unit in
            season = unit.season
            position = unit.episode
        }
    }

    // MARK: 头部

    /// 剧名与集数是小字，季名是大字；多于一季时点季名换季
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                if controller.seasons.count > 1 {
                    Menu {
                        Picker(String(localized: .playerControlsEpisodes), selection: $season) {
                            ForEach(controller.seasons, id: \.self) { Text(EpisodePicker.seasonName($0)).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(EpisodePicker.seasonName(season))
                                .font(.title3.bold())
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .frame(width: 20, height: 20)
                                .background(.white.opacity(0.16), in: .circle)
                        }
                        .foregroundStyle(.white)
                        .contentShape(.rect)
                    }
                    .accessibilityIdentifier("episodes-season")
                } else {
                    Text(EpisodePicker.seasonName(season))
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 8)
            if style == .console {
                Button(action: close) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                        Text(String(localized: .playerControlsDeck))
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .frame(height: 32)
                    .background(.white.opacity(0.14), in: .capsule)
                    .frame(height: 44)
                    .padding(.trailing, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("episodes-close")
            } else {
                closeButton
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.14), in: .circle)
                // 看得见的圆 32pt，触控区 44pt
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: .commonClose))
        .accessibilityIdentifier("episodes-close")
    }

    private var subtitle: String {
        guard let episodes, !episodes.isEmpty else { return controller.title }
        return "\(controller.title) · \(String(localized: .libraryItemEpisodeCount(episodes.count)))"
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if let episodes, !episodes.isEmpty {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(episodes.enumerated()), id: \.element.episodeNumber) { index, episode in
                        entry(episode)
                            .modifier(RiseIn(shown: appeared || reduceMotion, step: riseStep(index, in: episodes)))
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollPosition(id: $position, anchor: .center)
            .scrollIndicators(.hidden)
            // 列表在上下两端淡出，不被面板的边硬切
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                }
            }
        } else {
            // 别的季还在取 / 没取到
            Group {
                if episodes == nil {
                    ProgressView().tint(.white)
                } else {
                    Text(String(localized: .libraryItemEpisodesFailed))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 弹出时各行从正在播的那一集向两边依次浮现：离它越远越晚，最多错开 8 步
    private func riseStep(_ index: Int, in episodes: [API.EpisodeView]) -> Int {
        let anchor = playingSeason ? (episodes.firstIndex { $0.episodeNumber == controller.unit.episode } ?? 0) : 0
        return min(8, abs(index - anchor))
    }

    @ViewBuilder
    private func entry(_ episode: API.EpisodeView) -> some View {
        if playingSeason, episode.episodeNumber == controller.unit.episode {
            Button(action: close) { hero(episode) }
                .buttonStyle(EpisodeRowStyle(radius: 24, resting: true))
                .padding(.vertical, 4)
                .accessibilityIdentifier("episode-current")
                .accessibilityAddTraits(.isSelected)
        } else {
            Button {
                controller.playEpisode(season: season, episode: episode.episodeNumber, seasonEpisodes: playingSeason ? nil : episodes)
                close()
            } label: {
                row(episode)
            }
            .buttonStyle(EpisodeRowStyle(radius: 18, resting: false))
            .disabled(!episode.owned)
            .opacity(episode.owned ? 1 : 0.36)
            .accessibilityIdentifier("episode-\(episode.episodeNumber)")
        }
    }

    private func hero(_ episode: API.EpisodeView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                still(episode, width: sidebar ? 124 : 144, radius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: !controller.paused && !reduceMotion)
                        Text(String(localized: .playerControlsPlaying))
                            .tracking(0.8)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    title(episode, dimmed: false)
                        .font(.headline)
                }
                Spacer(minLength: 0)
            }
            if !sidebar, let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EpisodeLiveProgress(controller: controller)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .contentShape(.rect)
    }

    private func row(_ episode: API.EpisodeView) -> some View {
        HStack(spacing: 12) {
            still(episode, width: sidebar ? 96 : 112, radius: 10)
                .overlay(alignment: .bottom) {
                    // 看了一半：剧照下沿一条细进度
                    if let partial = EpisodePicker.partial(episode) {
                        Capsule().fill(.white.opacity(0.32))
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule().fill(.white).frame(width: geo.size.width * partial)
                                }
                            }
                            .frame(height: 3)
                            .padding(.horizontal, 5)
                            .padding(.bottom, 4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                title(episode, dimmed: episode.played)
                    .font(.subheadline.weight(.semibold))
                if let meta = EpisodePicker.meta(episode) {
                    HStack(spacing: 4) {
                        if meta.done { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                        Text(meta.text)
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.56))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(.rect)
    }

    /// 集号是灰色数字，集名在后；没有集名就只写「第 N 集」
    private func title(_ episode: API.EpisodeView, dimmed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let name = episode.name, !name.isEmpty {
                Text(verbatim: "\(episode.episodeNumber)")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.42))
                Text(name)
                    .foregroundStyle(.white.opacity(dimmed ? 0.6 : 1))
            } else {
                Text(String(localized: .mediaEpisodeNumber(episode.episodeNumber)))
                    .foregroundStyle(.white.opacity(dimmed ? 0.6 : 1))
            }
        }
        .lineLimit(1)
    }

    private func still(_ episode: API.EpisodeView, width: CGFloat, radius: CGFloat) -> some View {
        Color.white.opacity(0.08)
            .overlay {
                if let url = controller.scope.api.image(episode.stillUrl, width: ImageWidth.points(width)) {
                    RemoteImage(url: url)
                }
            }
            .frame(width: width, height: (width * 9 / 16).rounded())
            .clipShape(.rect(cornerRadius: radius))
    }
}

/// 正在播的那一集的实时进度：细条 + 看到哪、还剩几分钟。单独成一个视图——播放位置每秒都在变，只让这一小块跟着重画
private struct EpisodeLiveProgress: View {
    let controller: PlaybackController

    var body: some View {
        let position = controller.timelineMs(fromFileMs: controller.positionMs)
        let duration = controller.timelineDurationMs
        VStack(spacing: 6) {
            Capsule().fill(.white.opacity(0.22))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * EpisodePicker.fraction(position: position, duration: duration))
                    }
                }
                .frame(height: 3)
            HStack {
                Text(Formatters.clock(Double(position) / 1000))
                Spacer()
                if let duration {
                    Text(String(localized: .libraryRemainingMinutes(EpisodePicker.minutesLeft(position: position, duration: duration))))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 2)
    }
}

/// 行的底：按下时整行亮一下；正在播的那张卡平时就有一层浅底和细边
private struct EpisodeRowStyle: ButtonStyle {
    let radius: CGFloat
    let resting: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.2 : (resting ? 0.12 : 0)))
            }
            .overlay {
                if resting {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                }
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 弹出时的浮现：从下面 12pt 升上来并淡入，按步错开
private struct RiseIn: ViewModifier {
    let shown: Bool
    let step: Int

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(.spring(duration: 0.45, bounce: 0.1).delay(0.06 + Double(step) * 0.03), value: shown)
    }
}
