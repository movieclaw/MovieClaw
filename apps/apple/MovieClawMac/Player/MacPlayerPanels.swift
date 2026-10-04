import SwiftUI

/// 胶囊上方弹出的两种玻璃面板
enum MacPlayerPanelKind: Hashable {
    /// 字幕与音轨（左右两栏，同 Apple TV App 的「音频与字幕」）
    case tracks
    /// 画质
    case quality
}

/// 字幕与音轨面板：左栏字幕（关闭 → 中文 → 英语 → 其他语言 → 放不了的），右栏音轨（只有一条以上才有这一栏）。
/// 每栏各自滚动，当前项打勾；选了就切、面板收起（同系统菜单）。选择走共享的 `PlaybackController`，
/// 与 iPhone / Apple TV 同一套轨记忆（只记用户亲手选的，按成员存在服务端）。
///
/// 不用系统菜单（NSMenu）而在窗口里自己画：本地片源动辄十几条字幕，两栏并排一眼看全比层层子菜单好找，
/// 每行还能放一行小字（格式、外挂 / 内封、AI 翻译）
struct MacTracksPanel: View {
    let controller: PlaybackController
    let maxHeight: CGFloat
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(title: "字幕", count: controller.subtitles.options.count + controller.subtitles.unavailable.count) {
                subtitleRows
            }
            if !controller.audioOptions.isEmpty {
                Divider().overlay(.white.opacity(0.12)).padding(.vertical, 14)
                column(title: "音轨", count: controller.audioOptions.count) {
                    audioRows
                }
            }
        }
        .macPlayerPanel()
        .accessibilityIdentifier("mac-player-tracks-panel")
    }

    private func column(title: String, count: Int, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .bold))
                Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    rows()
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 286)
    }

    @ViewBuilder
    private var subtitleRows: some View {
        MacPanelRow(id: "mac-panel-subtitle-off", title: "关闭", detail: nil, active: controller.selectedSubtitle == nil) {
            controller.selectSubtitle(nil)
            close()
        }
        ForEach(MacSubtitleGroups.build(controller.subtitles.options)) { group in
            MacPanelHeader(title: group.title)
            ForEach(group.options) { item in
                MacPanelRow(id: "mac-panel-subtitle-\(item.ref)", title: MacTrackText.split(item.label).title,
                            detail: MacTrackText.subtitleDetail(item), active: controller.selectedSubtitle == item.ref) {
                    controller.selectSubtitle(item.ref)
                    close()
                }
            }
        }
        if !controller.subtitles.unavailable.isEmpty {
            MacPanelHeader(title: "暂时放不了")
            ForEach(controller.subtitles.unavailable) { item in
                MacPanelRow(id: "mac-panel-subtitle-\(item.ref)", title: MacTrackText.split(item.label).title,
                            detail: item.reason, active: false, disabled: true) {}
            }
        }
    }

    @ViewBuilder
    private var audioRows: some View {
        ForEach(controller.audioOptions) { item in
            let active = item.ref == controller.currentAudio || (controller.currentAudio == nil && item.isDefault)
            let parts = MacTrackText.split(item.label)
            MacPanelRow(id: "mac-panel-audio-\(item.ref)", title: parts.title,
                        detail: [parts.detail, item.isDefault ? "默认" : nil, item.unavailableReason].compactMap { $0 }
                            .joined(separator: " · "),
                        active: active, disabled: item.unavailableReason != nil) {
                controller.selectAudio(item.ref)
                close()
            }
        }
    }
}

/// 画质面板：自动 / 1080p / 720p / 480p，每档一行说明。访客分享不出这个面板（服务端按分享的设定给流）
struct MacQualityPanel: View {
    let controller: PlaybackController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("画质")
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(QualityOption.all) { item in
                    MacPanelRow(id: "mac-panel-quality-\(item.label)", title: item.label, detail: item.hint,
                                active: controller.quality == item.maxHeight) {
                        controller.selectQuality(item.maxHeight)
                        close()
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 250)
        .macPlayerPanel()
        .accessibilityIdentifier("mac-player-quality-panel")
    }
}

private extension View {
    /// 面板外观：深色液态玻璃圆角卡片（胶囊上方弹出，同心圆角）
    func macPlayerPanel() -> some View {
        self
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            .accessibilityElement(children: .contain)
    }
}

/// 分组标题（小号灰字）
private struct MacPanelHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// 面板里的一行：左边对勾（当前项），主标题 + 一行小字；悬停浮出淡白底
private struct MacPanelRow: View {
    let id: String
    let title: String
    let detail: String?
    let active: Bool
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 14)
                    .opacity(active ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(hovering && !disabled ? 0.14 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(id)
        .accessibilityValue(active ? "已选中" : "")
    }
}

/// 字幕按语言分组：中文 → 英语 → 其他语言（组名中文，轨道多的片子好找）。纯函数
enum MacSubtitleGroups {
    struct Group: Identifiable {
        let id: String
        let title: String
        let options: [SubtitleOption]
    }

    static func build(_ options: [SubtitleOption]) -> [Group] {
        var chinese: [SubtitleOption] = [], english: [SubtitleOption] = [], others: [SubtitleOption] = []
        for option in options {
            switch kind(of: option.language) {
            case .chinese: chinese.append(option)
            case .english: english.append(option)
            case .other: others.append(option)
            }
        }
        return [Group(id: "zh", title: "中文", options: chinese), Group(id: "en", title: "英语", options: english),
                Group(id: "other", title: "其他语言", options: others)].filter { !$0.options.isEmpty }
    }

    private enum Kind { case chinese, english, other }

    /// 语言标记 → 分组（各种写法：zh / chi / zho / chs / cht / zh-Hans / cmn / yue……）
    private static func kind(of language: String?) -> Kind {
        guard let code = language?.lowercased(), !code.isEmpty else { return .other }
        if code.hasPrefix("zh") || ["chi", "zho", "chs", "cht", "cmn", "yue", "chinese"].contains(code) { return .chinese }
        if code.hasPrefix("en") || code == "english" { return .english }
        return .other
    }
}

/// 轨道标签的拆分与说明（标签是「语言 · 编码 · 声道」，拆成主标题 + 一行小字；同 Apple TV 版）
enum MacTrackText {
    static func split(_ label: String) -> (title: String, detail: String?) {
        let parts = label.components(separatedBy: " · ")
        let rest = parts.dropFirst().joined(separator: " · ")
        return (parts.first ?? label, rest.isEmpty ? nil : rest)
    }

    /// 字幕的小字：格式 · 外挂 / 内封 · AI 翻译 · 默认
    static func subtitleDetail(_ item: SubtitleOption) -> String {
        var parts: [String] = []
        if let format = formats[item.kind.lowercased()] { parts.append(format) } else if let fromLabel = split(item.label).detail {
            parts.append(fromLabel)
        }
        if item.ref.hasPrefix("external:") { parts.append("外挂") } else if item.ref.hasPrefix("embedded:") { parts.append("内封") }
        if item.isAI { parts.append("AI 翻译") }
        if item.isDefault { parts.append("默认") }
        return parts.joined(separator: " · ")
    }

    private static let formats = ["srt": "SRT", "subrip": "SRT", "ass": "ASS", "ssa": "ASS", "vtt": "WebVTT", "webvtt": "WebVTT",
                                  "pgs": "PGS 图形", "text": "文本"]
}
