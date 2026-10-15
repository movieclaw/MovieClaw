import SwiftUI

/// iPad 宽窗口里列表类页面（设置、活动、「我的」）的限宽：内容最宽 `maxWidth` 点、左右居中，
/// 不把一行字拉到一千多点宽（HIG「readable width」，同 iPad 设置 App 右栏的版式）。
/// 只在 iPad 宽窗口生效（`CardMetrics.isWide`）；手机与 iPad 窄窗口原样不动（不改系统列表默认的边距）。
struct PadReadableWidth: ViewModifier {
    var maxWidth: CGFloat = 760
    @Environment(\.cardMetrics) private var cards
    @State private var frame = Frame()

    /// 页面宽度（已扣掉安全区）与左右安全区。iPadOS 26 的侧边栏浮在内容上、滚动视图延伸到它底下，
    /// 而 contentMargins 从滚动视图的边算起、与安全区取大：所以边距 = 安全区 + 居中余量
    private nonisolated struct Frame: Equatable, Sendable {
        var width: CGFloat = 0
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    func body(content: Content) -> some View {
        let margin = (frame.width - maxWidth) / 2
        Group {
            if cards.isWide, margin > 20 {
                content
                    .contentMargins(.leading, frame.leading + margin, for: .scrollContent)
                    .contentMargins(.trailing, frame.trailing + margin, for: .scrollContent)
            } else {
                content
            }
        }
        .onGeometryChange(for: Frame.self) {
            Frame(width: $0.size.width, leading: $0.safeAreaInsets.leading, trailing: $0.safeAreaInsets.trailing)
        } action: { frame = $0 }
    }
}

extension View {
    func padReadableWidth(_ maxWidth: CGFloat = 760) -> some View {
        modifier(PadReadableWidth(maxWidth: maxWidth))
    }
}
