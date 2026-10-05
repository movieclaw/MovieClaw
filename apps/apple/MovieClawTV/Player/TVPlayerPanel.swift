import SwiftUI

/// 面板的三栏（下滑 / 点按下呼出）。打开时焦点落在哪一栏由 `TVPlayerPanel.firstTab` 定
enum TVPlayerPanelTab: String, CaseIterable, Hashable {
    case subtitles = "字幕"
    case audio = "音轨"
    case quality = "画质"
}

/// 播放器的字幕 / 音轨 / 画质面板（2026-10-04 用户选定「压暗三栏 + 焦点即预览」，同 Netflix 电视版的「音频与字幕」）：
///
/// - **画面退后而不熄灭**：整屏由中间向外渐暗（不磨砂，画面清楚可见），播放照常继续；
/// - **对称三栏竖排**：字幕 / 音轨 / 画质，左右换栏、上下选，每栏各自滚动（上下边缘渐隐）。竖排而不是横排：
///   本地片源动辄十几条字幕，横排一屏只放得下五六个、两行信息也放不下（系统播放器、Netflix、Infuse 都是竖排）；
/// - **字幕按语言分组**：关闭 → 正在使用 → 中文 → 英语 → 其他语言（组名与轨道名同用中文）；轨道多时「其他语言」折叠成一行，按确认展开；
/// - **选了就切**：选中后直接在画面上看到效果，不预览、不加提示（试过「焦点即预览」与切换提示，用户要简洁，2026-10-04 去掉）。
///
/// 选中后走共享的 `PlaybackController`（与 iPhone 同一套轨记忆：只记用户亲手选的，按成员存在服务端，三端通用）。
/// 返回键收起面板（由播放器处理）。
struct TVPlayerPanel: View {
    let controller: PlaybackController
    /// 打开时焦点落在哪一栏
    let initial: TVPlayerPanelTab
    var focus: FocusState<TVPlayerFocus?>.Binding

    /// 「其他语言」展开了没有
    @State private var expanded = false
    /// 「正在使用」按打开面板那一刻的字幕固定：面板开着时换字幕只挪对勾、不重排——
    /// 否则选中的那一行被挪进「正在使用」，焦点所在的行没了，焦点落回第一行「关闭」（2026-10-04 用户反馈）
    @State private var pinnedSubtitle: String?

    /// 打开时焦点落在字幕栏（最常用）
    static func firstTab(for controller: PlaybackController) -> TVPlayerPanelTab {
        .subtitles
    }

    /// 显示哪几栏：音轨只有一条以上才有这一栏；访客分享不能选画质（服务端按分享的设定给流）
    static func tabs(for controller: PlaybackController) -> [TVPlayerPanelTab] {
        TVPlayerPanelTab.allCases.filter { tab in
            switch tab {
            case .audio: !controller.audioOptions.isEmpty
            case .quality: controller.scope.shareSlug == nil
            case .subtitles: true
            }
        }
    }

    var body: some View {
        ZStack {
            // 画面退后：只压暗、不磨砂——由中间向外渐暗，四周画面清楚可见、看得出还在播。
            // 不用系统材质：tvOS 的 ultraThinMaterial 比网页 demo 的模糊厚得多，真机上几乎把画面整个盖住（2026-10-04 用户反馈）
            RadialGradient(colors: [.black.opacity(0.66), .black.opacity(0.38)], center: .center, startRadius: 150, endRadius: 1150)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 60) {
                    ForEach(Self.tabs(for: controller), id: \.self) { tab in
                        column(tab)
                    }
                }
                .frame(height: 690)
                .padding(.horizontal, 90)
                .padding(.top, 70)
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            pinnedSubtitle = controller.selectedSubtitle
        }
        .task {
            // 打开时焦点落在这一栏已选中的那一项上，按一下返回就收起，不会误改。
            // 面板刚出现时赋值可能被忽略（真机上更明显）：焦点会悬空——画面已禁用、右下角按钮也禁用了，
            // 返回键没人接，系统直接把整个播放器关掉（2026-10-04 用户反馈）。隔一会儿看一眼，没落进面板就再赋一次
            for delay in [0, 120, 300, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                if case .panelOption = focus.wrappedValue { return }
                focus.wrappedValue = .panelOption(activeOptionID(initial))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-player-panel")
    }

    // MARK: 栏

    private func column(_ tab: TVPlayerPanelTab) -> some View {
        let active = focusedTab == tab
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(tab.rawValue)
                    .font(.system(size: 32, weight: .bold))
                Text("\(count(tab))")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(active ? .white : .white.opacity(0.45))
            .padding(.leading, 28)
            .accessibilityIdentifier("tv-panel-column-\(tab)")
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    rows(tab)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 14)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
            // 上下边缘渐隐：提示还有内容（同 tvOS 的长列表）
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.horizontal, -40)
            }
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: active)
    }

    @ViewBuilder
    private func rows(_ tab: TVPlayerPanelTab) -> some View {
        switch tab {
        case .subtitles:
            ForEach(TVSubtitleSections.build(options: controller.subtitles.options, unavailable: controller.subtitles.unavailable,
                                             selected: pinnedSubtitle, live: controller.selectedSubtitle, expanded: expanded)) { section in
                if let title = section.title {
                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 28)
                        .padding(.top, 16)
                        .padding(.bottom, 2)
                }
                ForEach(section.rows) { row in
                    subtitleRow(row)
                }
            }
        case .audio:
            ForEach(controller.audioOptions) { item in
                let active = item.ref == controller.currentAudio || (controller.currentAudio == nil && item.isDefault)
                let parts = TVTrackText.split(item.label)
                option(id: "audio-\(item.ref)", title: parts.title,
                       detail: [parts.detail, item.isDefault ? "默认" : nil, item.unavailableReason].compactMap { $0 }.joined(separator: " · "),
                       active: active, disabled: item.unavailableReason != nil) {
                    controller.selectAudio(item.ref)
                }
            }
        case .quality:
            ForEach(QualityOption.all) { item in
                option(id: "quality-\(item.label)", title: item.label, detail: item.hint, active: controller.quality == item.maxHeight) {
                    controller.selectQuality(item.maxHeight)
                }
            }
        }
    }

    @ViewBuilder
    private func subtitleRow(_ row: TVSubtitleSections.Row) -> some View {
        switch row {
        case .off:
            option(id: "subtitle-off", title: "关闭", detail: nil, active: controller.selectedSubtitle == nil) {
                controller.selectSubtitle(nil)
            }
        case let .option(item):
            option(id: "subtitle-\(item.ref)", title: TVTrackText.split(item.label).title, detail: TVTrackText.subtitleDetail(item),
                   active: controller.selectedSubtitle == item.ref) {
                controller.selectSubtitle(item.ref)
            }
        case let .unavailable(item):
            option(id: "subtitle-\(item.ref)", title: TVTrackText.split(item.label).title, detail: item.reason, active: false, disabled: true) {}
        case let .more(count, names):
            option(id: "subtitle-more", title: "展开其他 \(count) 条字幕", detail: names, active: false) {
                expanded = true
                // 展开后焦点挪到其他语言的第一条（「展开」这一行没了，焦点不能悬空）
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    if let first = TVSubtitleSections.firstOther(options: controller.subtitles.options, selected: pinnedSubtitle) {
                        focus.wrappedValue = .panelOption("subtitle-\(first.ref)")
                    }
                }
            }
        }
    }

    private func option(id: String, title: String, detail: String?, active: Bool, disabled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Color(red: 1, green: 0.83, blue: 0.47))
                    .frame(width: 26)
                    .opacity(active ? 1 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 30, weight: .semibold))
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 21))
                            .lineLimit(1)
                            .opacity(0.6)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TVPanelOptionStyle())
        .disabled(disabled)
        .focused(focus, equals: .panelOption(id))
        .accessibilityIdentifier("tv-panel-\(id)")
        .accessibilityValue(active ? "已选中" : "")
    }

    // MARK: 焦点

    /// 焦点所在的那一行（栏标题高亮跟着它）
    private var focusedRow: String? {
        if case let .panelOption(id) = focus.wrappedValue { return id }
        return nil
    }

    private var focusedTab: TVPlayerPanelTab? {
        guard let id = focusedRow else { return nil }
        if id.hasPrefix("subtitle-") { return .subtitles }
        if id.hasPrefix("audio-") { return .audio }
        if id.hasPrefix("quality-") { return .quality }
        return nil
    }

    private func count(_ tab: TVPlayerPanelTab) -> Int {
        switch tab {
        case .subtitles: controller.subtitles.options.count + controller.subtitles.unavailable.count
        case .audio: controller.audioOptions.count
        case .quality: QualityOption.all.count
        }
    }

    /// 一栏里已选中那一项的焦点标识
    private func activeOptionID(_ tab: TVPlayerPanelTab) -> String {
        switch tab {
        case .subtitles:
            controller.selectedSubtitle.map { "subtitle-\($0)" } ?? "subtitle-off"
        case .audio:
            (controller.currentAudio ?? AudioOption.defaultRef(in: controller.audioOptions)).map { "audio-\($0)" } ?? ""
        case .quality:
            "quality-" + (QualityOption.all.first { $0.maxHeight == controller.quality }?.label ?? "原画")
        }
    }
}

/// 面板选项：获得焦点时一块半透明的玻璃胶囊（不反白——压暗的画面上更安静），略微放大
private struct TVPanelOptionStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.38))
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.white.opacity(focused ? 0.17 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(.white.opacity(focused ? 0.22 : 0), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 16, y: 10)
            }
            .scaleEffect(focused ? 1.04 : configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// 轨道标签的拆分与说明（标签是「语言 · 编码 · 声道」，拆成主标题 + 一行小字）
enum TVTrackText {
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

/// 字幕栏的分组：关闭 → 正在使用 → 中文 → 英语 → 其他语言（多时折叠）。纯函数，便于单测
enum TVSubtitleSections {
    enum Row: Identifiable {
        case off
        case option(SubtitleOption)
        case unavailable(UnavailableSubtitle)
        /// 折叠起来的「其他语言」：条数 + 前几种语言名
        case more(count: Int, names: String)

        var id: String {
            switch self {
            case .off: "off"
            case let .option(item): item.ref
            case let .unavailable(item): "x-\(item.ref)"
            case .more: "more"
            }
        }
    }

    struct Section: Identifiable {
        /// 固定的身份（off / current / zh / en / other）：标题会变（「正在使用」↔「之前在用」），身份不能跟着变——
        /// 一变整组就被当成新的一组重建，焦点所在的行没了，焦点落回第一行（2026-10-04 用户反馈）
        let id: String
        let title: String?
        let rows: [Row]
    }

    /// 轨道总数超过这么多、且「其他语言」至少这么多条时才折叠（少的时候全摆出来更直接）
    static let collapseTotal = 8
    static let collapseOthers = 3

    /// `selected`：排在「正在使用」里的那条（面板打开那一刻的选择）；`live`：此刻实际选中的。
    /// 面板开着时换了字幕，这一组不挪位置（焦点不能丢），标题改叫「之前在用」
    static func build(options: [SubtitleOption], unavailable: [UnavailableSubtitle], selected: String?, live: String?,
                      expanded: Bool) -> [Section] {
        var sections = [Section(id: "off", title: nil, rows: [.off])]
        let current = options.first { $0.ref == selected }
        if let current { sections.append(Section(id: "current", title: selected == live ? "正在使用" : "之前在用", rows: [.option(current)])) }
        let rest = options.filter { $0.ref != current?.ref }
        let chinese = rest.filter { group(of: $0.language) == .chinese }
        let english = rest.filter { group(of: $0.language) == .english }
        let others = rest.filter { group(of: $0.language) == .other }
        if !chinese.isEmpty { sections.append(Section(id: "zh", title: "中文", rows: chinese.map(Row.option))) }
        if !english.isEmpty { sections.append(Section(id: "en", title: "英语", rows: english.map(Row.option))) }
        var otherRows: [Row] = others.map(Row.option) + unavailable.map(Row.unavailable)
        let total = options.count + unavailable.count
        if !expanded, total > collapseTotal, otherRows.count >= collapseOthers {
            let names = (others.map { TVTrackText.split($0.label).title } + unavailable.map { TVTrackText.split($0.label).title })
            var unique: [String] = []
            for name in names where !unique.contains(name) { unique.append(name) }
            let shown = unique.prefix(4).joined(separator: " · ")
            otherRows = [.more(count: otherRows.count, names: unique.count > 4 ? shown + " …" : shown)]
        }
        if !otherRows.isEmpty { sections.append(Section(id: "other", title: "其他语言", rows: otherRows)) }
        return sections
    }

    /// 展开后焦点要落的那一条：其他语言的第一条
    static func firstOther(options: [SubtitleOption], selected: String?) -> SubtitleOption? {
        options.first { $0.ref != selected && group(of: $0.language) == .other }
    }

    enum Group { case chinese, english, other }

    /// 语言标记 → 分组（各种写法：zh / chi / zho / chs / cht / zh-Hans / cmn / yue……）
    static func group(of language: String?) -> Group {
        guard let code = language?.lowercased(), !code.isEmpty else { return .other }
        if code.hasPrefix("zh") || ["chi", "zho", "chs", "cht", "cmn", "yue", "chinese"].contains(code) { return .chinese }
        if code.hasPrefix("en") || code == "english" { return .english }
        return .other
    }
}
