import SwiftUI

/// 桌面模式（iPhone Duo 竖向半折、下半平放在桌上）的控制台主体：顶栏与进度条以下的部分（docs/design/iphone-duo.md §6.4）。
///
/// 下半屏不压画面、手指落在稳定的桌面上，地方也够，所以不照搬底栏，而是按主次排成「便当盒」
/// （2026-10-28 用户在真机桌面模式下逐版挑过，定稿为这一版，其余试过的样式见设计稿 §10）：
/// - 左边**播放卡**只管播放：白色播放键，两侧前进后退只留图标，下面是时间；
/// - 右边 2×2 方块：音轨、字幕、画质、画面，每块写着当前值（音轨字幕打开与底栏同一张面板，画质画面是系统菜单，
///   选项与底栏「⋯」同一份）；
/// - **倍速**是一排直接可点的分段条（不用再进菜单），选中项是滑过去的白色药丸；
/// - 剧集最底下一行**上一集 / 下一集**两张卡片，带那一集的剧照与集号集名，与播放区分开；
/// - 播放诊断在顶栏右上角的网速胶囊里（`PlayerTopBar.speedOpensDiagnostics`）。
/// 功能与全屏时完全一样（人机界面指南：别把功能绑在某个姿态上），只是换了排法。底下垫的氛围背景见 `DeckAmbience`
struct PlayerTabletopDeck: View {
    let controller: PlaybackController
    @Binding var menu: PlayerMenu

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                DeckTransportCard(controller: controller)
                tileGrid
            }
            .frame(maxHeight: 240)
            DeckSpeedBar(controller: controller)
            if controller.unit.isEpisode, controller.clip == nil {
                HStack(spacing: 12) {
                    DeckEpisodeCard(controller: controller, previous: true)
                    DeckEpisodeCard(controller: controller, previous: false)
                }
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

/// 控制台底下的氛围背景：这一集的剧照（电影是海报）放大、重度模糊、提饱和、压暗，铺满折痕以下——
/// 控制台跟着片子换颜色，玻璃卡片也有东西可折射（同 Apple TV、Netflix 播放页的氛围色做法）。
/// 取很小的一张图（宽 120 点档）再模糊：图是静态的，合成一次就不再变，没有逐帧开销
struct DeckAmbience: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.black
            if let url {
                // 图挂在一个不占尺寸的框上：图片自带的尺寸不能参与布局，否则整块控制台会被撑出屏幕（内屏实测）
                Color.clear
                    .overlay {
                        RemoteImage(url: url)
                            .scaleEffect(1.4)
                            .blur(radius: 40)
                            .saturation(1.5)
                            .opacity(0.55)
                    }
            }
            // 上缘淡进黑色：和折痕、上半屏画面的黑边接上，不出现一条硬边
            LinearGradient(colors: [.black, .black.opacity(0.2), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 上一集 / 下一集卡片（播放区外最底下一行，左右各一张）：那一集的剧照缩略图、「上一集 / 下一集」与集号集名，
/// 上一集的箭头与缩略图在左、下一集的在右，两张镜像对称（试过去掉箭头，用户 2026-10-28 定还是带箭头）。没有上一集（第一集）或下一集（最后一集、缺集）时那张置灰
private struct DeckEpisodeCard: View {
    let controller: PlaybackController
    let previous: Bool

    var body: some View {
        let episode = previous ? controller.previousEpisode : controller.nextEpisode
        let title = previous ? String(localized: .playerControlsPreviousEpisode) : String(localized: .playerControlsNextEpisode)
        let number = episode.map { String(localized: .mediaEpisodeNumber($0.episodeNumber)) }
        Button {
            controller.noteUserActivity()
            if previous { controller.playPrevious() } else { controller.playNext() }
        } label: {
            HStack(spacing: 10) {
                if previous {
                    icon
                    thumbnail(episode)
                }
                VStack(alignment: previous ? .leading : .trailing, spacing: 2) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(subtitle(number: number, episode: episode))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: previous ? .leading : .trailing)
                if !previous {
                    thumbnail(episode)
                    icon
                }
            }
            .lineLimit(1)
            .padding(8)
            .frame(height: 56)
            .glassEffect(.regular.tint(.black.opacity(0.15)).interactive(), in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(DeckPressStyle())
        .disabled(episode == nil)
        .opacity(episode == nil ? 0.35 : 1)
        .accessibilityLabel([title, number].compactMap { $0 }.joined(separator: "，"))
        .accessibilityIdentifier(previous ? "deck-previous" : "deck-next")
    }

    private var icon: some View {
        Image(systemName: previous ? "backward.end.fill" : "forward.end.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20)
    }

    /// 「第 3 集 · 潮汐之下」；没有集名只写集号，没有这一集写「—」
    private func subtitle(number: String?, episode: API.EpisodeView?) -> String {
        guard let number else { return "—" }
        guard let name = episode?.name, !name.isEmpty else { return number }
        return "\(number) · \(name)"
    }

    private func thumbnail(_ episode: API.EpisodeView?) -> some View {
        Color.white.opacity(0.08)
            .overlay {
                if let url = controller.scope.api.image(episode?.stillUrl, width: ImageWidth.points(64)) {
                    RemoteImage(url: url)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(.rect(cornerRadius: 8))
    }
}
