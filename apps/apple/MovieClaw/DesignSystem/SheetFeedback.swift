import SwiftUI

/// sheet 内的反馈宿主。
///
/// 全局 `FeedbackHost` 挂在标签栏根部：sheet 盖在上面时，根部的 `.alert` 无法弹出
/// （UIKit 不允许在已呈现 sheet 的控制器上再呈现），`feedback.confirm` 会永远等不到结果。
/// 所以每个 sheet 的内容换上一个自己的 `Feedback` 并就地挂宿主，确认框、输入框在 sheet 里弹。
/// 轻提示则转交根部：根部的提示层是一层独立窗口，盖在 sheet 之上，位置与根部页面完全一致，
/// sheet 关掉后还没消失的提示也照常显示到点（例如「已加入合集」后立刻关窗）。
struct SheetFeedback: ViewModifier {
    @Environment(Feedback.self) private var parent
    @State private var local = Feedback()

    func body(content: Content) -> some View {
        // 每次求值都对齐到当前的上级反馈中心（sheet 套 sheet 时一路转交到根部）
        local.toastOwner = parent
        return content
            .environment(local)
            .modifier(FeedbackHost(feedback: local))
    }
}

extension View {
    /// 所有 sheet / fullScreenCover 的内容都要调用它（全 App 约定），见 `SheetFeedback`
    func sheetFeedback() -> some View { modifier(SheetFeedback()) }
}
