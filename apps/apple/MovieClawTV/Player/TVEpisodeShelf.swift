import SwiftUI

/// 选集剧照排（Apple TV）：上滑或点按「上」从底部升起，返回或往下收起。
///
/// 「下」已经是字幕 / 音轨 / 画质 / 倍速面板（`TVPlayerPanel`），上下各管一件事：下面调怎么放，上面挑放哪集。
/// 电视离得远，剧照比文字列表好认，所以是一排横卡（尺寸、焦点放大与详情页的分集横排一致），画面不缩、下半压暗、照常在播。
///
/// - 打开时焦点落在正在播的那一集：看下一集就是「上、右、确认」；
/// - 再往上是季页签，焦点移到哪一季，下面就换成哪一季（同详情页，不用按确认）；
/// - 缺集置灰，按钮不可用，焦点直接跳过；
/// - 简介只给正在播的那一集（写在卡片排下面），没看过的集不剧透。
struct TVEpisodeShelf: View {
    let controller: PlaybackController
    var focus: FocusState<TVPlayerFocus?>.Binding
    let close: () -> Void

    @State private var season: Int
    @State private var others: [Int: [API.EpisodeView]] = [:]

    private let cardWidth = TVMetrics.landscapeWidth

    init(controller: PlaybackController, focus: FocusState<TVPlayerFocus?>.Binding, close: @escaping () -> Void) {
        self.controller = controller
        self.focus = focus
        self.close = close
        _season = State(initialValue: controller.unit.season)
    }

    private var playingSeason: Bool { season == controller.unit.season }
    private var episodes: [API.EpisodeView]? { playingSeason ? controller.episodes : others[season] }

    /// 焦点该落在哪一集：本季是正在播的那集，别的季是第一个有片源的
    private var anchor: Int? {
        if playingSeason { return controller.unit.episode }
        return episodes?.first(where: \.owned)?.episodeNumber
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 画面退后而不熄灭：下半压暗托住卡片，上半照常看得清
            LinearGradient(stops: [
                .init(color: .black.opacity(0.1), location: 0),
                .init(color: .black.opacity(0.25), location: 0.4),
                .init(color: .black.opacity(0.82), location: 0.62),
                .init(color: .black.opacity(0.92), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 30) {
                header
                cards
                Text(detail)
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .frame(maxWidth: 1300, alignment: .leading)
                    .frame(height: 34, alignment: .topLeading)
                    .padding(.horizontal, TVMetrics.edge)
            }
            .padding(.bottom, 50)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-player-episodes")
        .task { await controller.refreshEpisodes() }
        .task(id: season) {
            guard !playingSeason, others[season] == nil else { return }
            others[season] = await controller.loadSeason(season) ?? []
        }
        .task {
            // 刚升起时卡片还没进焦点系统，直接赋值可能被忽略（同播放器里跳过按钮的处理）：稍等再交焦点
            try? await Task.sleep(for: .milliseconds(150))
            if let anchor { focus.wrappedValue = .episode(anchor) }
        }
        .onChange(of: focus.wrappedValue) { _, now in
            if case let .season(number) = now, number != season { season = number }
        }
    }

    // MARK: 季

    private var header: some View {
        HStack(spacing: 28) {
            Text(controller.title)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            if controller.seasons.count > 1 {
                HStack(spacing: 6) {
                    ForEach(controller.seasons, id: \.self) { number in
                        Button(EpisodePicker.seasonName(number)) { focus.wrappedValue = anchor.map(TVPlayerFocus.episode) }
                            .buttonStyle(TVSeasonTabStyle(selected: number == season))
                            .focused(focus, equals: .season(number))
                            .accessibilityIdentifier("tv-episodes-season-\(number)")
                    }
                }
                .focusSection()
                // 从卡片往上进来落在正在看的这一季，不按位置挑
                .defaultFocus(focus, .season(season), priority: .userInitiated)
            } else {
                Text(EpisodePicker.seasonName(season))
                    .font(.system(size: 28, weight: .semibold))
            }
        }
        .padding(.horizontal, TVMetrics.edge)
        .frame(height: 64)
    }

    // MARK: 剧照

    @ViewBuilder
    private var cards: some View {
        if let episodes, !episodes.isEmpty {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: TVMetrics.cardSpacing) {
                        ForEach(episodes, id: \.episodeNumber) { episode in
                            card(episode).id(episode.episodeNumber)
                        }
                    }
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .focusSection()
                .defaultFocus(focus, anchor.map(TVPlayerFocus.episode), priority: .userInitiated)
                // 卡片排最下面再往下：收起
                .onMoveCommand { direction in
                    if direction == .down { close() }
                }
                .onAppear { if let anchor { reader.scrollTo(anchor, anchor: .center) } }
                .onChange(of: season) {
                    if let anchor { reader.scrollTo(anchor, anchor: .center) }
                }
            }
            .frame(height: cardWidth * 9 / 16 + 140)
        } else {
            Group {
                if episodes == nil {
                    ProgressView()
                } else {
                    Text(String(localized: .libraryItemEpisodesFailed))
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cardWidth * 9 / 16 + 140)
        }
    }

    private func card(_ episode: API.EpisodeView) -> some View {
        let current = playingSeason && episode.episodeNumber == controller.unit.episode
        let focused = focus.wrappedValue == .episode(episode.episodeNumber)
        return Button {
            if current {
                close()
            } else {
                controller.playEpisode(season: season, episode: episode.episodeNumber, seasonEpisodes: playingSeason ? nil : episodes)
                close()
            }
        } label: {
            VStack(alignment: .leading, spacing: TVMetrics.captionSpacing) {
                RemoteImage(url: controller.scope.api.image(episode.stillUrl, width: ImageWidth.tvCard(cardWidth)),
                            placeholderText: String(localized: .mediaEpisodeNumber(episode.episodeNumber)))
                    .frame(width: cardWidth, height: cardWidth * 9 / 16)
                    .overlay(alignment: .topLeading) {
                        if current { playingBadge }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = current ? Double(EpisodePicker.fraction(position: controller.timelineMs(fromFileMs: controller.positionMs),
                                                                                     duration: controller.timelineDurationMs))
                            : EpisodePicker.partial(episode) {
                            TVProgressStrip(value: progress, track: .white.opacity(0.3))
                                .padding(.horizontal, 16)
                                .padding(.bottom, 14)
                        }
                    }
                    .clipShape(.rect(cornerRadius: TVMetrics.cardCorner))
                    // 焦点效果点名套在图上：图是 LazyImage 包出来的，`.borderless` 自己找不到它（同详情页的分集卡）
                    .hoverEffect(.highlight)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        if let name = episode.name, !name.isEmpty {
                            Text(verbatim: "\(episode.episodeNumber)")
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.45))
                            Text(name)
                        } else {
                            Text(String(localized: .mediaEpisodeNumber(episode.episodeNumber)))
                        }
                    }
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.white.opacity(focused || current ? 1 : 0.72))
                    .lineLimit(1)
                    Text(subline(episode, current: current))
                        .font(.system(size: 23).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.borderless)
        .disabled(!episode.owned)
        .opacity(episode.owned ? 1 : 0.34)
        .focused(focus, equals: .episode(episode.episodeNumber))
        .accessibilityIdentifier(current ? "tv-episode-current" : "tv-episode-\(episode.episodeNumber)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var playingBadge: some View {
        Label(String(localized: .playerControlsPlaying), systemImage: "waveform")
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: !controller.paused)
            .font(.system(size: 21, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(14)
    }

    /// 卡片下的小字：正在播的写还剩多久，其余写缺集 / 已看完 / 看到哪
    private func subline(_ episode: API.EpisodeView, current: Bool) -> String {
        if current {
            guard let duration = controller.timelineDurationMs else { return "" }
            let position = controller.timelineMs(fromFileMs: controller.positionMs)
            return String(localized: .libraryRemainingMinutes(EpisodePicker.minutesLeft(position: position, duration: duration)))
        }
        return EpisodePicker.meta(episode)?.text ?? ""
    }

    /// 卡片排下面那一行：焦点在正在播的那一集上时写它的简介
    private var detail: String {
        guard playingSeason, focus.wrappedValue == .episode(controller.unit.episode) else { return "" }
        return controller.currentEpisode?.overview ?? ""
    }
}
