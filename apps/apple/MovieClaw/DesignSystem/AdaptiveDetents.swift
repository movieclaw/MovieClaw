import SwiftUI

/// 弹层的高度档。手机照给的档（半屏 / 贴合内容 / 全屏）从底部升起；
/// iPad 宽窗口统一用系统的居中表单（`.form`，同 iPad 设置、邮件里的弹层），不用这些档：
/// 带半屏档的弹层在 iPad 上会被画成一块窄窄的半高面板，既不居中也不贴底，背景还半透明（真机反馈，模拟器复现）。
/// 判断按当前窗口（`CardMetrics.current`）：弹层里的尺寸类别是弹层自己的，不能用。
struct AdaptiveDetents: ViewModifier {
    let detents: Set<PresentationDetent>
    var selection: Binding<PresentationDetent>?

    func body(content: Content) -> some View {
        if CardMetrics.current.isWide {
            content
                .presentationDetents([.large])
                .presentationSizing(.form)
        } else if let selection {
            content.presentationDetents(detents, selection: selection)
        } else {
            content.presentationDetents(detents)
        }
    }
}

extension View {
    /// 代替 `presentationDetents`：手机按档、iPad 宽窗口居中表单（见 `AdaptiveDetents`）
    func adaptiveDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(AdaptiveDetents(detents: detents))
    }

    func adaptiveDetents(_ detents: Set<PresentationDetent>, selection: Binding<PresentationDetent>) -> some View {
        modifier(AdaptiveDetents(detents: detents, selection: selection))
    }
}
