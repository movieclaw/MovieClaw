import SwiftUI

/// 信息面板的分页（下滑 / 点按下呼出，同 tvOS 系统播放器的信息面板）
enum TVPlayerPanelTab: String, CaseIterable, Hashable {
    case subtitles = "字幕"
    case audio = "音轨"
    case quality = "画质"
}

/// 播放器顶部滑下来的信息面板：上面一排分页，下面一排选项。
///
/// 数据全部来自共享的 `PlaybackController`（与 iPhone 版的字幕 / 音轨 / 画质菜单同一套模型：`SubtitleTracks`、
/// `AudioOption`、`QualityOption`），这里只是换成电视上的焦点排布。返回键收起面板（由播放器处理）。
struct TVPlayerPanel: View {
    let controller: PlaybackController
    let tab: TVPlayerPanelTab
    var focus: FocusState<TVPlayerFocus?>.Binding
    let select: (TVPlayerPanelTab) -> Void

    /// 面板打开时停在哪一页：有可选的字幕就是字幕页（最常用），音轨只有多条时才有这一页
    static func firstTab(for controller: PlaybackController) -> TVPlayerPanelTab {
        .subtitles
    }

    static func tabs(for controller: PlaybackController) -> [TVPlayerPanelTab] {
        TVPlayerPanelTab.allCases.filter { tab in
            switch tab {
            case .audio: !controller.audioOptions.isEmpty
            // 访客分享不能选画质（服务端按分享的设定给流）
            case .quality: controller.scope.shareSlug == nil
            case .subtitles: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 16) {
                ForEach(Self.tabs(for: controller), id: \.self) { item in
                    Button { select(item) } label: {
                        Text(item.rawValue)
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(TVPanelTabStyle(selected: item == tab))
                    .focused(focus, equals: .panelTab(item))
                    .accessibilityIdentifier("tv-panel-tab-\(item)")
                }
            }
            .focusSection()
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    options
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.horizontal, 80)
        .padding(.top, 50)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .onAppear {
            // 打开时焦点落在当前页已选中的那一项上，按一下返回就收起，不会误改
            focus.wrappedValue = .panelOption(activeOptionID)
        }
        .onChange(of: tab) { _, _ in
            if case .panelTab = focus.wrappedValue { return }
            focus.wrappedValue = .panelOption(activeOptionID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-player-panel")
    }

    @ViewBuilder
    private var options: some View {
        switch tab {
        case .subtitles:
            option(id: "subtitle-off", title: "关闭", detail: nil, active: controller.selectedSubtitle == nil) {
                controller.selectSubtitle(nil)
            }
            ForEach(controller.subtitles.options) { item in
                option(id: "subtitle-\(item.ref)", title: item.label, detail: item.isAI ? "AI 翻译" : nil,
                       active: controller.selectedSubtitle == item.ref) {
                    controller.selectSubtitle(item.ref)
                }
            }
            ForEach(controller.subtitles.unavailable) { item in
                option(id: "subtitle-\(item.ref)", title: item.label, detail: item.reason, active: false, disabled: true) {}
            }
        case .audio:
            ForEach(controller.audioOptions) { item in
                let active = item.ref == controller.currentAudio || (controller.currentAudio == nil && item.isDefault)
                option(id: "audio-\(item.ref)", title: item.label, detail: item.unavailableReason, active: active,
                       disabled: item.unavailableReason != nil) {
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

    /// 当前页已选中那一项的焦点标识
    private var activeOptionID: String {
        switch tab {
        case .subtitles:
            controller.selectedSubtitle.map { "subtitle-\($0)" } ?? "subtitle-off"
        case .audio:
            (controller.currentAudio ?? AudioOption.defaultRef(in: controller.audioOptions)).map { "audio-\($0)" } ?? ""
        case .quality:
            "quality-" + (QualityOption.all.first { $0.maxHeight == controller.quality }?.label ?? "自动")
        }
    }

    private func option(id: String, title: String, detail: String?, active: Bool, disabled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.callout.weight(.bold))
                    .opacity(active ? 1 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .lineLimit(1)
                            .opacity(0.7)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(minWidth: 220, alignment: .leading)
        }
        .buttonStyle(TVPanelOptionStyle())
        .disabled(disabled)
        .focused(focus, equals: .panelOption(id))
        .accessibilityIdentifier("tv-panel-\(id)")
        .accessibilityValue(active ? "已选中" : "")
    }
}

/// 面板分页按钮：选中页白底黑字，获得焦点时放大
private struct TVPanelTabStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected || focused ? .black : .white)
            .background(Capsule().fill(selected || focused ? .white : .white.opacity(0.12)))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// 面板选项：获得焦点时白底放大（同系统播放器信息面板的选项）
private struct TVPanelOptionStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? .black : .white.opacity(enabled ? 1 : 0.4))
            .background(RoundedRectangle(cornerRadius: 16).fill(focused ? .white : .white.opacity(0.1)))
            .scaleEffect(focused ? 1.06 : 1)
            .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 14, y: 8)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
