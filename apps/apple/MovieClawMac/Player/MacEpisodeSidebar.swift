import SwiftUI

/// 选集侧栏（Mac）：控制面板的「选集」键或 E 键开合，点一集就换。
///
/// 和 iPhone 的抽屉同一套规则（打开停在正在播的那一集、简介只给正在播的、换季只换列表、缺集置灰），
/// 按桌面习惯改了两处：
/// - **可以一直开着**：窗口够宽时侧栏和画面并排（画面让到左边），点画面不收；收起要按 ✕、E 或 Esc。
///   窗口窄了放不下就浮在画面上，这时点画面收起（见 `MacPlayerContent`）。
/// - **鼠标悬停**：整行变亮、剧照上浮出播放标记，告诉人点下去就换。
///
/// 季用系统弹出菜单（`Menu` + `Picker`），当前季打勾，是 Mac 用户熟悉的样子。
struct MacEpisodeSidebar: View {
    let controller: PlaybackController
    let close: () -> Void

    static let width: CGFloat = 340
    /// 侧栏离窗口边缘
    static let margin: CGFloat = 10
    /// 窗口比这窄时侧栏改为浮在画面上（并排的话画面只剩不到一半）
    static let dockMinWindowWidth: CGFloat = 900
    static let corner: CGFloat = 18

    @State private var season: Int
    @State private var others: [Int: [API.EpisodeView]] = [:]

    init(controller: PlaybackController, close: @escaping () -> Void) {
        self.controller = controller
        self.close = close
        _season = State(initialValue: controller.unit.season)
    }

    private var playingSeason: Bool { season == controller.unit.season }
    private var episodes: [API.EpisodeView]? { playingSeason ? controller.episodes : others[season] }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: Self.width)
        .clipShape(.rect(cornerRadius: Self.corner))
        // 同字幕与音轨面板的材质：浮在亮画面上时也压得住文字
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: Self.corner))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-player-episodes")
        .task { await controller.refreshEpisodes() }
        .task(id: season) {
            guard !playingSeason, others[season] == nil else { return }
            others[season] = await controller.loadSeason(season) ?? []
        }
        // 换了一集（点了某一行、⌘→、自动连播）：列表跟到新的那一季
        .onChange(of: controller.unit) { _, unit in season = unit.season }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                if controller.seasons.count > 1 {
                    Menu {
                        Picker(String(localized: .playerControlsEpisodes), selection: $season) {
                            ForEach(controller.seasons, id: \.self) { Text(EpisodePicker.seasonName($0)).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 5) {
                            Text(EpisodePicker.seasonName(season))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .contentShape(.rect)
                    }
                    .menuStyle(.button)
                    .buttonStyle(MacPlayerButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityIdentifier("mac-episodes-season")
                } else {
                    Text(EpisodePicker.seasonName(season))
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            Spacer(minLength: 8)
            MacPlayerIconButton(symbol: "xmark", size: 11, diameter: 26, help: String(localized: .playerMacEpisodesShortcut), id: "mac-episodes-close", action: close)
                .accessibilityLabel(String(localized: .commonClose))
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var subtitle: String {
        guard let episodes, !episodes.isEmpty else { return controller.title }
        return "\(controller.title) · \(String(localized: .libraryItemEpisodeCount(episodes.count)))"
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if let episodes, !episodes.isEmpty {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(episodes, id: \.episodeNumber) { episode in
                            entry(episode).id(episode.episodeNumber)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.never)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
                    }
                }
                // 打开、换季回来、换了一集：停在正在播的那一集
                .onAppear { if playingSeason { reader.scrollTo(controller.unit.episode, anchor: .center) } }
                .onChange(of: controller.unit) { _, unit in
                    withAnimation(.easeOut(duration: 0.25)) { reader.scrollTo(unit.episode, anchor: .center) }
                }
                .onChange(of: season) { _, now in
                    if now == controller.unit.season { reader.scrollTo(controller.unit.episode, anchor: .center) }
                }
            }
        } else {
            Group {
                if episodes == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text(String(localized: .libraryItemEpisodesFailed))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func entry(_ episode: API.EpisodeView) -> some View {
        if playingSeason, episode.episodeNumber == controller.unit.episode {
            MacEpisodeHero(controller: controller, episode: episode)
                .padding(.vertical, 4)
        } else {
            MacEpisodeRow(
                episode: episode,
                still: controller.scope.api.image(episode.stillUrl, width: ImageWidth.macCard(MacEpisodeRow.stillWidth))
            ) {
                controller.playEpisode(season: season, episode: episode.episodeNumber, seasonEpisodes: playingSeason ? nil : episodes)
            }
        }
    }
}

/// 正在播的那一集：剧照大一号、两行简介、实时进度与还剩多久
private struct MacEpisodeHero: View {
    let controller: PlaybackController
    let episode: API.EpisodeView

    var body: some View {
        let position = controller.timelineMs(fromFileMs: controller.positionMs)
        let duration = controller.timelineDurationMs
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MacEpisodeStill(url: controller.scope.api.image(episode.stillUrl, width: ImageWidth.macCard(112)), width: 112, corner: 9)
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(localized: .playerControlsPlaying), systemImage: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: !controller.paused)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    MacEpisodeTitle(episode: episode, dimmed: false)
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer(minLength: 0)
            }
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 5) {
                Capsule().fill(.white.opacity(0.22))
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule().fill(.white).frame(width: geo.size.width * EpisodePicker.fraction(position: position, duration: duration))
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
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.12))
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSelected)
        .accessibilityIdentifier("mac-episode-current")
    }
}

/// 其余各集：一行剧照 + 集号集名 + 状态。悬停整行变亮、剧照上浮出播放标记；缺集置灰点不动
private struct MacEpisodeRow: View {
    let episode: API.EpisodeView
    let still: URL?
    let action: () -> Void

    static let stillWidth: CGFloat = 96

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MacEpisodeStill(url: still, width: Self.stillWidth, corner: 7)
                    .overlay(alignment: .bottom) {
                        if let partial = EpisodePicker.partial(episode) {
                            Capsule().fill(.white.opacity(0.32))
                                .overlay(alignment: .leading) {
                                    GeometryReader { geo in Capsule().fill(.white).frame(width: geo.size.width * partial) }
                                }
                                .frame(height: 3)
                                .padding(.horizontal, 5)
                                .padding(.bottom, 4)
                        }
                    }
                    .overlay {
                        if hovering, episode.owned {
                            ZStack {
                                Color.black.opacity(0.4)
                                Image(systemName: "play.fill").font(.system(size: 18))
                            }
                            .clipShape(.rect(cornerRadius: 7))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    MacEpisodeTitle(episode: episode, dimmed: episode.played)
                        .font(.system(size: 13, weight: .semibold))
                    if let meta = EpisodePicker.meta(episode) {
                        HStack(spacing: 4) {
                            if meta.done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                            Text(meta.text)
                        }
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.56))
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(hovering && episode.owned ? 0.09 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!episode.owned)
        .opacity(episode.owned ? 1 : 0.36)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityIdentifier("mac-episode-\(episode.episodeNumber)")
    }
}

private struct MacEpisodeStill: View {
    let url: URL?
    let width: CGFloat
    let corner: CGFloat

    var body: some View {
        Color.white.opacity(0.08)
            .overlay { if let url { RemoteImage(url: url) } }
            .frame(width: width, height: (width * 9 / 16).rounded())
            .clipShape(.rect(cornerRadius: corner))
    }
}

/// 灰色集号 + 集名；没有集名只写「第 N 集」
private struct MacEpisodeTitle: View {
    let episode: API.EpisodeView
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let name = episode.name, !name.isEmpty {
                Text(verbatim: "\(episode.episodeNumber)")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.42))
                Text(name).foregroundStyle(.white.opacity(dimmed ? 0.6 : 1))
            } else {
                Text(String(localized: .mediaEpisodeNumber(episode.episodeNumber)))
                    .foregroundStyle(.white.opacity(dimmed ? 0.6 : 1))
            }
        }
        .lineLimit(1)
    }
}
