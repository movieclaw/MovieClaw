import SwiftUI

/// 完整简介要显示的东西：片名、副标题（剧集写第几季第几集，电影写年份类型那一行）、全文
struct TVOverviewContent: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let text: String
}

/// 完整简介（issue #1238）：详情页首屏的简介、分集卡长按菜单里的「完整简介」打开，盖满整屏，按返回键关掉。
/// 同系统 Apple TV App、Infuse：电视上没有触屏，截断的简介只能这样看全。
///
/// 正文居中一栏、比详情页的字大一号（坐在沙发上读一整段）。极长的简介（英文长剧情、NFO 里的长文）一屏放不下时，
/// 上下键 / 触控板上下滑一次翻约三分之一屏：页面上没有别的焦点，整页自己接焦点、把方向键换成滚动
struct TVOverviewPanel: View {
    let content: TVOverviewContent
    let ambientURL: URL?

    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0
    @FocusState private var focused: Bool

    /// 上下键一次滚多少
    private static let step: CGFloat = 320

    var body: some View {
        ZStack {
            TVBlurredBackdrop(url: ambientURL)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(content.title)
                    .font(.system(size: 52, weight: .bold))
                    .lineLimit(2)
                if let subtitle = content.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.top, 14)
                }
                ScrollView(.vertical) {
                    Text(content.text)
                        .font(.system(size: 30))
                        .lineSpacing(11)
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("tv-overview-text")
                }
                .scrollPosition($position)
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in offset = value }
                .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentSize.height - $0.containerSize.height) } action: { _, value in
                    maxOffset = value
                }
                .padding(.top, 44)
            }
            .frame(width: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 90)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .defaultFocus($focused, true)
        .onMoveCommand { direction in
            switch direction {
            case .down: scroll(by: Self.step)
            case .up: scroll(by: -Self.step)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-overview-panel")
    }

    private func scroll(by delta: CGFloat) {
        guard maxOffset > 0 else { return }
        let target = min(max(offset + delta, 0), maxOffset)
        withAnimation(.easeInOut(duration: 0.25)) { position.scrollTo(y: target) }
    }
}
