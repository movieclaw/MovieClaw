import SwiftUI

/// 桌面模式（iPhone Duo 竖向半折、下半平放在桌上）的控制台主体：顶栏与进度条以下的部分（docs/design/iphone-duo.md §6.4）。
///
/// 下半屏不压画面、手指落在稳定的桌面上，地方也够，所以不照搬底栏，而是按主次排成「便当盒」
/// （2026-10-28 用户在真机桌面模式下逐版挑过，定稿为这一版，其余试过的样式见设计稿 §10）：
/// - 左边**播放卡**只管播放：白色播放键，两侧前进后退只留图标，下面是时间；
/// - 右边 2×2 方块：音轨、字幕、画质、画面，每块写着当前值（音轨字幕打开与底栏同一张面板，画质画面是系统菜单，
///   选项与底栏「⋯」同一份）；
/// - **倍速**是一排直接可点的分段条（不用再进菜单），选中项是滑过去的白色药丸；
/// - 剧集最底下一行是**选集胶囊**：中间一整条写着正在播的这一集（剧照、集号集名），点开选集面板（面板换掉控制台、占满下半屏）；
///   上一集 / 下一集退成两端的小方键（2026-11-11 用户在 Demo 里挑定；原来的「上一集卡 · 下一集卡」加不进选集，三格太挤）；
/// - 播放诊断在顶栏右上角的网速胶囊里（`PlayerTopBar.speedOpensDiagnostics`）。
/// 功能与全屏时完全一样（人机界面指南：别把功能绑在某个姿态上），只是换了排法。底下垫的氛围背景见 `DeckAmbience`
struct PlayerTabletopDeck: View {
    let controller: PlaybackController
    @Binding var menu: PlayerMenu
    /// 打开选集面板
    let onEpisodes: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                DeckTransportCard(controller: controller)
                tileGrid
            }
            .frame(maxHeight: 240)
            DeckSpeedBar(controller: controller)
            if controller.unit.isEpisode, controller.clip == nil {
                DeckEpisodeBar(controller: controller, onEpisodes: onEpisodes)
            }
        }
    }

    // MARK: 右侧方块

    private enum Tile: String, Identifiable {
        case audio, subtitles, quality, display
        var id: String { rawValue }
    }

    private var tiles: [Tile] {
        var tiles: [Tile] = []
        if !controller.audioOptions.isEmpty { tiles.append(.audio) }
        tiles.append(.subtitles)
        // 访客分享没有画质（服务端按分享的设定给流），同底栏「⋯」
        if controller.scope.shareSlug == nil { tiles.append(.quality) }
        tiles.append(.display)
        return tiles
    }

    /// 两两一行；单出来的一块占满整行
    static func pairs<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    private var tileGrid: some View {
        VStack(spacing: 12) {
            ForEach(Array(Self.pairs(tiles).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    ForEach(row) { tileView($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tileView(_ tile: Tile) -> some View {
        switch tile {
        case .audio:
            Button { toggle(.audio) } label: {
                DeckTile(title: String(localized: .playerControlsAudio), value: audioValue, symbol: "waveform", active: menu == .audio)
            }
            .buttonStyle(DeckPressStyle())
            .accessibilityIdentifier("deck-audio")
        case .subtitles:
            Button { toggle(.subtitles) } label: {
                DeckTile(title: String(localized: .playerControlsSubtitles), value: subtitleValue,
                         symbol: controller.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill", active: menu == .subtitles)
            }
            .buttonStyle(DeckPressStyle())
            .accessibilityIdentifier("deck-subtitles")
        case .quality:
            Menu { PlayerSettingsMenu.qualityItems(controller).onAppear(perform: closePanel) } label: {
                DeckTile(title: String(localized: .playerControlsQuality), value: PlayerSettingsMenu.qualityLabel(controller),
                         symbol: "sparkles.tv", active: false)
            }
            .menuOrder(.fixed)
            .menuStyle(.button)
            .buttonStyle(DeckPressStyle())
            .accessibilityIdentifier("deck-quality")
        case .display:
            Menu { PlayerSettingsMenu.displayItems(controller).onAppear(perform: closePanel) } label: {
                DeckTile(title: String(localized: .playerControlsDisplay), value: controller.displayMode.label,
                         symbol: controller.displayMode.symbol, active: false)
            }
            .menuOrder(.fixed)
            .menuStyle(.button)
            .buttonStyle(DeckPressStyle())
            .accessibilityIdentifier("deck-display")
        }
    }

    // MARK: 当前值

    /// 正在放的音轨（同音轨面板的勾选：没选过就是默认那条）
    private var audioValue: String {
        let options = controller.audioOptions
        return (options.first { $0.ref == controller.currentAudio } ?? options.first(where: \.isDefault) ?? options.first)?.label ?? ""
    }

    private var subtitleValue: String {
        guard let selected = controller.selectedSubtitle else { return String(localized: .commonOff) }
        return controller.subtitles.options.first { $0.ref == selected }?.displayTitle ?? ""
    }

    /// 打开画质 / 画面菜单时收起开着的音轨、字幕面板：两样同时开着会叠在一起
    private func closePanel() {
        controller.noteUserActivity()
        if menu != .none { menu = .none }
    }

    private func toggle(_ target: PlayerMenu) {
        controller.noteUserActivity()
        menu = menu == target ? .none : target
    }
}

/// 播放卡：只管播放——中间白色播放键，两侧前进后退只留图标（没有圆底），下面是时间。拖进度用上面的进度条。
/// 起播、缓冲时整块换成转圈（同平时控制层：转圈与播放键同一个位置）
private struct DeckTransportCard: View {
    let controller: PlaybackController
    @State private var backTaps = 0
    @State private var forwardTaps = 0

    var body: some View {
        Group {
            if controller.phase.isBusy {
                PlayerBusyView(controller: controller)
            } else {
                VStack(spacing: 14) {
                    HStack(spacing: 30) {
                        seekButton(back: true)
                        playButton
                        seekButton(back: false)
                    }
                    Text(timeText)
                        .font(.footnote.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular.tint(.black.opacity(0.15)), in: .rect(cornerRadius: 26))
    }

    private var playButton: some View {
        Button {
            controller.noteUserActivity()
            controller.togglePlay()
        } label: {
            Image(systemName: PlayerCenterControls.playSymbol(controller))
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 76, height: 76)
                .background(.white, in: .circle)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        }
        .buttonStyle(DeckPressStyle())
        .accessibilityLabel(PlayerCenterControls.playLabel(controller))
        .accessibilityIdentifier("player-play-pause")
    }

    private func seekButton(back: Bool) -> some View {
        Button {
            if back { backTaps += 1 } else { forwardTaps += 1 }
            controller.seek(by: back ? -10 : 10, source: .button)
        } label: {
            Image(systemName: back ? "gobackward.10" : "goforward.10")
                .symbolEffect(back ? .rotate.counterClockwise.byLayer : .rotate.clockwise.byLayer, value: back ? backTaps : forwardTaps)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 48, height: 48)
                .contentShape(.rect)
        }
        .buttonStyle(DeckPressStyle())
        .accessibilityLabel(back ? String(localized: .playerControlsSeekBack) : String(localized: .playerControlsSeekForward))
    }

    /// 「已播 / 总长」（片段模式按这一段算，同底栏的时间）
    private var timeText: String {
        let position = controller.timelineMs(fromFileMs: controller.positionMs)
        let total = controller.timelineDurationMs.map { Formatters.clock(Double($0) / 1000) } ?? Formatters.clock(nil)
        return "\(Formatters.clock(Double(position) / 1000)) / \(total)"
    }
}

/// 倍速分段条：选项与底栏「⋯ › 倍速」同一份，一字排开直接点；选中项是一枚滑过去的白色药丸
private struct DeckSpeedBar: View {
    let controller: PlaybackController
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40)
                .accessibilityHidden(true)
            ForEach(PlaybackSpeed.all, id: \.self) { rate in
                let selected = controller.rate == rate
                Button {
                    controller.noteUserActivity()
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { controller.selectRate(rate) }
                } label: {
                    Text(PlaybackSpeed.short(rate))
                        .font(.subheadline.weight(selected ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(selected ? .black : .white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selected {
                                Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PlaybackSpeed.label(rate))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: 44)
        .glassEffect(.regular.tint(.black.opacity(0.15)), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: .playerControlsSpeed))
        .accessibilityIdentifier("deck-speed")
    }
}

/// 右侧小方块：左上图标，下面名称与当前值（值可能很长，比如「英语 · 杜比全景声」，一行截断）
private struct DeckTile: View {
    let title: String
    let value: String
    let symbol: String
    /// 对应面板开着：反白
    let active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(height: 22)
            Spacer(minLength: 0)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(value.isEmpty ? " " : value)
                .font(.caption)
                .foregroundStyle(active ? .black.opacity(0.6) : .white.opacity(0.6))
        }
        .lineLimit(1)
        .foregroundStyle(active ? .black : .white)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.white.opacity(active ? 0.92 : 0), in: .rect(cornerRadius: 22))
        .glassEffect(.regular.tint(.black.opacity(0.15)).interactive(), in: .rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

/// 按下时轻微缩小（玻璃本身另有系统的按压形变）
private struct DeckPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 选集胶囊（播放区外最底下一行）：中间一整条是正在播的这一集——剧照、「选集 · 第 1 季 · 12 集」与集号集名、向上的箭头，
/// 点它打开选集面板；两端是上一集 / 下一集的小方键，没有上一集（第一集）或下一集（最后一集、缺集）时置灰。
/// 选集是主角、换集是顺手：主次靠宽窄拉开，整条都能点，手指落在桌面上不容易点偏
private struct DeckEpisodeBar: View {
    let controller: PlaybackController
    let onEpisodes: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            stepButton(previous: true)
            Button {
                controller.noteUserActivity()
                onEpisodes()
            } label: {
                HStack(spacing: 11) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(EpisodePicker.caption(controller.unit.episode, name: controller.currentEpisode?.name))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .padding(.leading, 9)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .glassEffect(.regular.tint(.black.opacity(0.15)).interactive(), in: .rect(cornerRadius: 20))
                .contentShape(.rect(cornerRadius: 20))
            }
            .buttonStyle(DeckPressStyle())
            .accessibilityLabel(String(localized: .playerControlsEpisodes))
            .accessibilityValue(EpisodePicker.caption(controller.unit.episode, name: controller.currentEpisode?.name))
            .accessibilityIdentifier("deck-episodes")
            stepButton(previous: false)
        }
    }

    /// 「选集 · 第 1 季 · 12 集」：分集还没取到时只写「选集 · 第 1 季」
    private var summary: String {
        var parts = [String(localized: .playerControlsEpisodes), EpisodePicker.seasonName(controller.unit.season)]
        if !controller.episodes.isEmpty { parts.append(String(localized: .libraryItemEpisodeCount(controller.episodes.count))) }
        return parts.joined(separator: " · ")
    }

    private func stepButton(previous: Bool) -> some View {
        let episode = previous ? controller.previousEpisode : controller.nextEpisode
        let title = previous ? String(localized: .playerControlsPreviousEpisode) : String(localized: .playerControlsNextEpisode)
        return Button {
            controller.noteUserActivity()
            if previous { controller.playPrevious() } else { controller.playNext() }
        } label: {
            Image(systemName: previous ? "backward.end.fill" : "forward.end.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 60)
                .glassEffect(.regular.tint(.black.opacity(0.15)).interactive(), in: .rect(cornerRadius: 20))
                .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(DeckPressStyle())
        .disabled(episode == nil)
        .opacity(episode == nil ? 0.35 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(episode.map { EpisodePicker.caption($0.episodeNumber, name: $0.name) } ?? "")
        .accessibilityIdentifier(previous ? "deck-previous" : "deck-next")
    }

    private var thumbnail: some View {
        Color.white.opacity(0.08)
            .overlay {
                if let url = controller.scope.api.image(controller.currentEpisode?.stillUrl, width: ImageWidth.points(66)) {
                    RemoteImage(url: url)
                }
            }
            .frame(width: 66, height: 37)
            .clipShape(.rect(cornerRadius: 8))
    }
}
