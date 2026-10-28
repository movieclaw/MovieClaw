import SwiftUI

/// 桌面模式（iPhone Duo 竖向半折、下半平放在桌上）控制台里的功能卡片（docs/design/iphone-duo.md §6.4）。
///
/// 下半屏不压画面、手指落在稳定的桌面上，地方也够：照 Netflix 的桌面模式把功能做成一排排大卡片铺满操作区，
/// 平时收在底栏「⋯」二级菜单里的画质、画面、倍速、诊断也拆出来各占一张，每张写着当前值，一眼看清、一下点到。
/// 功能与全屏时完全一样（人机界面指南：别把功能绑在某个姿态上），只是换了排法：
/// - 音轨、字幕：打开与底栏同一张面板（`PlayerMenu`）；
/// - 画质、画面、倍速：系统菜单，选项与底栏「⋯」里同一份（`PlayerSettingsMenu` 的选项列表）；
/// - 下一集（剧集且有下一集时）：直接播；
/// - 播放诊断：开关，开着时卡片高亮。
struct PlayerDeckCards: View {
    let controller: PlaybackController
    @Binding var menu: PlayerMenu

    /// 每行几张：凑成两行（6 张 3×2、7 张 4 + 3、8 张 4×2），至少 3 张一行。669 点宽的内屏一行 4 张时卡片约 150 点宽，
    /// 名称与当前值都放得下
    static func columns(for count: Int) -> Int { max(3, (count + 1) / 2) }

    var body: some View {
        let cards = self.cards
        let columns = Self.columns(for: cards.count)
        let rows = stride(from: 0, to: cards.count, by: columns).map { Array(cards[$0..<min($0 + columns, cards.count)]) }
        // 一行行均分剩余高度：控制台多高，卡片就长多高（最高 120，再高就只是空着的大块）
        VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    ForEach(rows[index]) { card in
                        cardView(card)
                    }
                    // 最后一行不满时补空位，卡片宽度与上一行对齐
                    ForEach(0..<(columns - rows[index].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(minHeight: 72, maxHeight: 120)
            }
        }
    }

    private enum Card: String, Identifiable {
        case audio, subtitles, quality, speed, display, next, diagnostics
        var id: String { rawValue }
    }

    private var cards: [Card] {
        var cards: [Card] = []
        if !controller.audioOptions.isEmpty { cards.append(.audio) }
        cards.append(.subtitles)
        // 访客分享没有画质（服务端按分享的设定给流），同底栏「⋯」
        if controller.scope.shareSlug == nil { cards.append(.quality) }
        cards += [.speed, .display]
        if controller.clip == nil, controller.nextEpisode != nil { cards.append(.next) }
        cards.append(.diagnostics)
        return cards
    }

    @ViewBuilder
    private func cardView(_ card: Card) -> some View {
        switch card {
        case .audio:
            Button { toggle(.audio) } label: {
                DeckCardLabel(title: String(localized: .playerControlsAudio), value: audioValue, symbol: "waveform", active: menu == .audio)
            }
            .buttonStyle(DeckCardStyle())
            .accessibilityIdentifier("deck-audio")
        case .subtitles:
            Button { toggle(.subtitles) } label: {
                DeckCardLabel(title: String(localized: .playerControlsSubtitles), value: subtitleValue,
                              symbol: controller.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill", active: menu == .subtitles)
            }
            .buttonStyle(DeckCardStyle())
            .accessibilityIdentifier("deck-subtitles")
        case .quality:
            Menu { PlayerSettingsMenu.qualityItems(controller).onAppear(perform: closePanel) } label: {
                DeckCardLabel(title: String(localized: .playerControlsQuality), value: PlayerSettingsMenu.qualityLabel(controller), symbol: "sparkles.tv", active: false)
            }
            .menuOrder(.fixed)
            .menuStyle(.button)
            .buttonStyle(DeckCardStyle())
            .accessibilityIdentifier("deck-quality")
        case .speed:
            Menu { PlayerSettingsMenu.speedItems(controller).onAppear(perform: closePanel) } label: {
                DeckCardLabel(title: String(localized: .playerControlsSpeed), value: PlaybackSpeed.label(controller.rate),
                              symbol: "gauge.with.dots.needle.67percent", active: controller.rate != 1)
            }
            .menuOrder(.fixed)
            .menuStyle(.button)
            .buttonStyle(DeckCardStyle())
            .accessibilityIdentifier("deck-speed")
        case .display:
            Menu { PlayerSettingsMenu.displayItems(controller).onAppear(perform: closePanel) } label: {
                DeckCardLabel(title: String(localized: .playerControlsDisplay), value: controller.displayMode.label,
                              symbol: controller.displayMode.symbol, active: false)
            }
            .menuOrder(.fixed)
            .menuStyle(.button)
            .buttonStyle(DeckCardStyle())
            .accessibilityIdentifier("deck-display")
        case .next:
            Button {
                controller.noteUserActivity()
                controller.playNext()
            } label: {
                DeckCardLabel(title: String(localized: .playerControlsNextEpisode),
                              value: controller.nextEpisode.map { String(localized: .mediaEpisodeNumber($0.episodeNumber)) } ?? "",
                              symbol: "forward.end.fill", active: false)
            }
            .buttonStyle(DeckCardStyle())
            .accessibilityIdentifier("deck-next")
        case .diagnostics:
            Button { controller.diagnosticsOpen.toggle() } label: {
                DeckCardLabel(title: String(localized: .playerControlsDiagnostics), value: nil, symbol: "waveform.path.ecg", active: controller.diagnosticsOpen)
            }
            .buttonStyle(DeckCardStyle())
            .accessibilityAddTraits(controller.diagnosticsOpen ? .isSelected : [])
            .accessibilityIdentifier("deck-diagnostics")
        }
    }

    /// 正在放的音轨（同音轨面板的勾选：没选过就是默认那条）
    private var audioValue: String {
        let options = controller.audioOptions
        return (options.first { $0.ref == controller.currentAudio } ?? options.first(where: \.isDefault) ?? options.first)?.label ?? ""
    }

    private var subtitleValue: String {
        guard let selected = controller.selectedSubtitle else { return String(localized: .commonOff) }
        return controller.subtitles.options.first { $0.ref == selected }?.displayTitle ?? ""
    }

    /// 打开画质 / 倍速 / 画面菜单时收起开着的音轨、字幕面板：两样同时开着会叠在一起
    private func closePanel() {
        controller.noteUserActivity()
        if menu != .none { menu = .none }
    }

    private func toggle(_ target: PlayerMenu) {
        controller.noteUserActivity()
        menu = menu == target ? .none : target
    }
}

/// 卡片的内容：左上图标，下面名称与当前值（值可能很长，比如「英语 · 杜比全景声」，一行截断）
private struct DeckCardLabel: View {
    let title: String
    let value: String?
    let symbol: String
    /// 对应面板开着 / 非默认值 / 开关打开：垫一层浅色
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(height: 24)
            Spacer(minLength: 4)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.white.opacity(active ? 0.22 : 0.08), in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// 按下时轻微缩小、变亮（与播放器玻璃按钮的按压反馈同一感觉）
private struct DeckCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(.white.opacity(configuration.isPressed ? 0.12 : 0), in: .rect(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
