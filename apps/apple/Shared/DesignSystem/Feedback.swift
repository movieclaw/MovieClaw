import SwiftUI

/// 全局反馈中心：轻提示（Toast）、确认框、输入框。对应 Web `components/feedback.tsx`。
///
/// 用法与 Web 端一致，方便逐行移植：
/// ```swift
/// @Environment(Feedback.self) private var feedback
/// feedback.success("已加入合集")
/// if await feedback.confirm("删除这个合集？", message: "…", destructive: true) { … }
/// if let name = await feedback.prompt("重命名", initial: old) { … }
/// ```
/// 确认/输入框用 async 等结果，调用方不用在每个页面各自挂 `.alert` 状态。
@Observable
final class Feedback {
    enum Tone { case success, info, error }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var tone: Tone
        var message: String
        var actionTitle: String?
        var action: (@MainActor () -> Void)?

        /// 停留时长：错误、带操作的多给一点时间读完 / 点到
        var duration: Duration { tone == .error || action != nil ? .seconds(6) : .seconds(4) }

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    struct Confirm: Identifiable {
        let id = UUID()
        var title: String
        var message: String?
        var confirmTitle: String
        /// 取消键文案（网页部分确认框写「先不」）
        var cancelTitle: String = "取消"
        var destructive: Bool
        var resume: (Bool) -> Void
    }

    struct Prompt: Identifiable {
        let id = UUID()
        var title: String
        var message: String?
        var placeholder: String
        var text: String
        var confirmTitle: String
        /// 输入上限（字符数，同网页 prompt 的 maxLength）：超出时「确定」置灰，弹窗里写明上限
        var maxLength: Int?
        var resume: (String?) -> Void
    }

    /// 当前显示的提示。同一时刻只有一条（同系统横幅）：新的顶替旧的
    private(set) var toast: Toast?
    /// sheet 里的反馈中心把提示交给根部（见 SheetFeedback）：全 App 只有根部一处显示提示
    @ObservationIgnored weak var toastOwner: Feedback?
    var confirmRequest: Confirm?
    var promptRequest: Prompt?

    func success(_ message: String) { show(.success, message) }
    func info(_ message: String) { show(.info, message) }
    func error(_ message: String) { show(.error, message) }
    /// 直接展示错误对象（后端中文文案原样透出）
    func error(_ error: Error) {
        if error is CancellationError { return }
        show(.error, error.localizedDescription)
    }

    func show(_ tone: Tone, _ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        if let toastOwner { return toastOwner.show(tone, message, actionTitle: actionTitle, action: action) }
        toast = Toast(tone: tone, message: message, actionTitle: actionTitle, action: action)
    }

    /// 只收起指定那条：旧提示的计时 / 手势晚到时不误伤已经顶上来的新提示
    func dismiss(_ toast: Toast) {
        if self.toast?.id == toast.id { self.toast = nil }
    }

    func confirm(_ title: String, message: String? = nil, confirmTitle: String = "确定", cancelTitle: String = "取消", destructive: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            confirmRequest = Confirm(
                title: title, message: message, confirmTitle: confirmTitle, cancelTitle: cancelTitle, destructive: destructive,
                resume: { continuation.resume(returning: $0) }
            )
        }
    }

    func prompt(_ title: String, message: String? = nil, placeholder: String = "", initial: String = "", confirmTitle: String = "确定", maxLength: Int? = nil) async -> String? {
        await withCheckedContinuation { continuation in
            promptRequest = Prompt(
                title: title, message: message, placeholder: placeholder,
                text: maxLength.map { String(initial.prefix($0)) } ?? initial, confirmTitle: confirmTitle, maxLength: maxLength,
                resume: { continuation.resume(returning: $0) }
            )
        }
    }
}

#if os(iOS)
/// 挂在根视图上，承载 Toast 与全局确认/输入框（只有 iPhone / iPad 用；Mac、TV 不挂）
struct FeedbackHost: ViewModifier {
    @Bindable var feedback: Feedback

    func body(content: Content) -> some View {
        content
            .background {
                // sheet 的反馈中心把提示转交根部，只有根部装提示层
                if feedback.toastOwner == nil { ToastWindowInstaller(feedback: feedback) }
            }
            .alert(
                feedback.confirmRequest?.title ?? "",
                isPresented: Binding(
                    get: { feedback.confirmRequest != nil },
                    set: { if !$0, let request = feedback.confirmRequest { feedback.confirmRequest = nil; request.resume(false) } }
                ),
                presenting: feedback.confirmRequest
            ) { request in
                Button(request.cancelTitle, role: .cancel) { feedback.confirmRequest = nil; request.resume(false) }
                Button(request.confirmTitle, role: request.destructive ? .destructive : nil) {
                    feedback.confirmRequest = nil
                    request.resume(true)
                }
            } message: { request in
                if let message = request.message { Text(message) }
            }
            .alert(
                feedback.promptRequest?.title ?? "",
                isPresented: Binding(
                    get: { feedback.promptRequest != nil },
                    set: { if !$0, let request = feedback.promptRequest { feedback.promptRequest = nil; request.resume(nil) } }
                ),
                presenting: feedback.promptRequest
            ) { request in
                TextField(request.placeholder, text: Binding(
                    get: { feedback.promptRequest?.text ?? "" },
                    // 不在这里截断：系统弹窗的输入框不回显截断后的值，用户看着打满了、提交的却是前 N 个字
                    // （第三轮复核 S-13）。超长改为「确定」置灰，说明写在弹窗里
                    set: { feedback.promptRequest?.text = $0 }
                ))
                Button("取消", role: .cancel) { feedback.promptRequest = nil; request.resume(nil) }
                Button(request.confirmTitle) {
                    let text = feedback.promptRequest?.text ?? request.text
                    feedback.promptRequest = nil
                    request.resume(text)
                }
                .disabled(request.maxLength.map { (feedback.promptRequest?.text.count ?? 0) > $0 } ?? false)
            } message: { request in
                let limit = request.maxLength.map { "最多 \($0) 字，超出时无法确定。" }
                let lines = [request.message, limit].compactMap { $0 }
                if !lines.isEmpty { Text(lines.joined(separator: "\n")) }
            }
    }
}

/// 提示单独放在一层透明窗口里：盖在 sheet、全屏弹层之上，全 App 同一个位置——屏幕底部，
/// 浮在标签栏（和它上面的「接着看」条）之上；没有标签栏的页面贴底部安全区，键盘弹出时浮在键盘上方。
/// 不放顶部：顶部是导航栏（返回键）和系统通知横幅的位置（同 Material Snackbar 的约定）。
/// 窗口只在提示本身的范围内接收触摸，其余一律穿透给下面的 App。
private struct ToastWindowInstaller: UIViewRepresentable {
    let feedback: Feedback

    func makeUIView(context: Context) -> Anchor { Anchor(feedback: feedback) }
    func updateUIView(_ view: Anchor, context: Context) {}

    /// 跟着根视图进出窗口：进来时在同一个场景里建提示窗口，离开（退出登录、换账号）时拆掉。
    /// 提示窗口只在有提示时显示：它在场时系统改听它来定状态栏，App 页面之后再切状态栏（灯箱点画面）
    /// 通知不到它；所以出现时同步一次 App 当前的设置，收起后立刻隐藏，交还给 App 自己的窗口
    final class Anchor: UIView {
        private let feedback: Feedback
        private var overlay: ToastWindow?
        private var hideTask: Task<Void, Never>?
        private var placeTask: Task<Void, Never>?
        private let placement = ToastPlacement()
        private var keyboardTop: CGFloat?

        init(feedback: Feedback) {
            self.feedback = feedback
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                                   name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else {
                hideTask?.cancel()
                placeTask?.cancel()
                overlay?.isHidden = true
                overlay = nil
                return
            }
            guard overlay == nil else { return }
            let overlay = ToastWindow(windowScene: scene)
            let host = ToastHostingController(rootView: ToastLayer(feedback: feedback, placement: placement) { [weak overlay] in overlay?.toastFrame = $0 })
            host.appWindow = window
            host.view.backgroundColor = .clear
            overlay.rootViewController = host
            overlay.overrideUserInterfaceStyle = .dark
            overlay.windowLevel = .normal + 1
            self.overlay = overlay
            sync()
            track()
        }

        private func track() {
            withObservationTracking { _ = feedback.toast?.id } onChange: { [weak self] in
                // onChange 在赋值之前触发：先把窗口亮出来，让提示的布局发生在可见窗口里
                // （隐藏窗口里排出来的位置不对，上报的触摸范围会落空）；值落定后再决定要不要藏
                if Thread.isMainThread { MainActor.assumeIsolated { self?.reveal() } }
                Task { @MainActor in
                    guard let self, self.overlay != nil else { return }
                    self.sync()
                    self.track()
                }
            }
        }

        private func reveal() {
            hideTask?.cancel()
            guard let overlay, overlay.isHidden else { return }
            place()
            overlay.isHidden = false
            overlay.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            // 显示期间跟着底下变：先弹提示再关 sheet、页面收起标签栏时，提示随之落到新位置
            placeTask?.cancel()
            placeTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.place()
                }
            }
        }

        /// 提示底边离窗口底边的距离：当前页面底部安全区（含标签栏、「接着看」条）与键盘取高者
        private func place() {
            guard let window else { return }
            var top = window.rootViewController
            while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
            // 标签页：看选中页的安全区（页面隐藏了标签栏时它自然变小）；sheet、全屏页：它自己的底部安全区
            let page = top.flatMap(Self.tabBarController(in:))?.selectedViewController ?? top
            var clear = window.bounds.maxY - window.safeAreaInsets.bottom
            if let view = page?.view, view.window === window {
                clear = view.convert(view.bounds, to: window).maxY - view.safeAreaInsets.bottom
            }
            if let keyboardTop { clear = min(clear, keyboardTop) }
            let bottom = max(0, window.bounds.maxY - clear)
            if placement.bottom != bottom { placement.bottom = bottom }
        }

        private static func tabBarController(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let found = tabBarController(in: child) { return found }
            }
            return nil
        }

        @objc private func keyboardWillChange(_ note: Notification) {
            guard let window, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = window.convert(frame, from: nil)
            keyboardTop = local.minY < window.bounds.maxY ? local.minY : nil
            if overlay?.isHidden == false { place() }
        }

        private func sync() {
            guard let overlay else { return }
            hideTask?.cancel()
            if feedback.toast != nil {
                reveal()
            } else if !overlay.isHidden {
                // 等收起动画放完再藏
                hideTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, let self, self.feedback.toast == nil else { return }
                    self.placeTask?.cancel()
                    self.overlay?.isHidden = true
                }
            }
        }
    }
}

private final class ToastWindow: UIWindow {
    /// 提示在窗口里的范围；没有提示时为空，整窗穿透
    var toastFrame: CGRect = .null

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        toastFrame.contains(point) ? super.hitTest(point, with: event) : nil
    }
}

/// 提示窗口在最上层，系统会改听它的根控制器来定状态栏、主屏指示条：一律转交给 App 窗口里最上层的页面，
/// 否则播放器、灯箱隐藏状态栏 / 指示条的设置全部失效（横竖屏由应用代理按窗口统一返回，不用转交）
private final class ToastHostingController: UIHostingController<ToastLayer> {
    weak var appWindow: UIWindow?

    private var appTop: UIViewController? {
        var top = appWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    override var childForStatusBarHidden: UIViewController? { appTop }
    override var childForStatusBarStyle: UIViewController? { appTop }
    override var childForHomeIndicatorAutoHidden: UIViewController? { appTop }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { appTop }
}

/// 提示底边离窗口底边的距离（由 `ToastWindowInstaller.Anchor` 按当前页面与键盘算出）
@Observable
private final class ToastPlacement {
    var bottom: CGFloat = 0
}

private struct ToastLayer: View {
    let feedback: Feedback
    let placement: ToastPlacement
    let onFrame: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正在显示的提示。晚一轮跟上 `feedback.toast`：窗口刚从隐藏切到显示的那一轮里插入的视图
    /// 会被当成首次出现、不放入场动画，等窗口先以空状态上屏再插入
    @State private var shown: Feedback.Toast?

    var body: some View {
        ZStack {
            if let toast = shown {
                ToastView(toast: toast) { feedback.dismiss(toast) }
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 在外层量触摸范围：过渡的位移不算进布局，量提示本身会量到入场动画起点那一帧的位置。
        // 这层随提示收拢，最宽 440pt 的限制放在它外面——不然整条都拦触摸，短提示旁边的返回键点不动
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0.isEmpty ? .null : $0) }
        .frame(maxWidth: 440)
        .padding(.horizontal, 16)
        .padding(.bottom, placement.bottom + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .animation(.spring(duration: 0.35), value: placement.bottom)
        .onChange(of: feedback.toast?.id, initial: true) {
            Task { @MainActor in
                withAnimation(.spring(duration: 0.45, bounce: 0.2)) { shown = feedback.toast }
            }
        }
        .sensoryFeedback(trigger: shown?.id) { _, _ in
            switch shown?.tone {
            case .success: .success
            case .error: .error
            case .info, nil: nil
            }
        }
    }
}

/// 底部轻提示（iOS 26 液态玻璃，位置约定同 Material Snackbar）：
/// - 液态玻璃（可交互：按下有系统的高光与回弹），单行时是胶囊、多行时是同半径的圆角矩形；
///   宽度随文字收拢、居中（最宽 440pt），最低 52pt 高，触控区不小于 44pt
/// - 浮在标签栏 / 键盘 / 底部安全区上方 8pt，下滑或点按收起；往上拖有阻尼、松手回弹
/// - 拖动途中暂停计时，松手后重新计时；VoiceOver 播报内容，并提供「关闭」操作
private struct ToastView: View {
    let toast: Feedback.Toast
    let onDismiss: () -> Void

    @State private var offset: CGFloat = 0
    /// 手指是否还按着：手势被系统取消（比如滑出屏幕底边）时它会自动复位，`onEnded` 却不会来
    @GestureState private var touching = false
    @State private var leaving = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let title = toast.actionTitle, let action = toast.action {
                Button {
                    action()
                    onDismiss()
                } label: {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentStrong)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, toast.action == nil ? 20 : 10)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .offset(y: offset)
        .onTapGesture(perform: onDismiss)
        .gesture(swipe)
        .onChange(of: touching) { _, now in
            // 手势被取消：弹回原位、恢复计时（不然停在半空、计时也一直停着）
            if !now, !leaving, offset != 0 { withAnimation(.spring(duration: 0.35, bounce: 0.3)) { offset = 0 } }
        }
        .task(id: touching) {
            guard !touching else { return }
            try? await Task.sleep(for: toast.duration)
            if !Task.isCancelled { onDismiss() }
        }
        .onAppear { AccessibilityNotification.Announcement(toast.message).post() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "关闭", onDismiss)
        .accessibilityIdentifier("toast")
    }

    /// 下滑收起：拖过 44pt 当场收（贴着屏幕底边时手指常滑出边缘、等不到松手），松手时拖过 24pt 或甩得够快也收；
    /// 往上拖只给一点阻尼位移，松手弹回
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                guard !leaving else { return }
                let dy = value.translation.height
                offset = dy > 0 ? dy : -6 * sqrt(-dy)
                if dy > 44 { leave() }
            }
            .onEnded { value in
                guard !leaving else { return }
                if value.translation.height > 24 || value.predictedEndTranslation.height > 80 {
                    leave()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { offset = 0 }
                }
            }
    }

    private func leave() {
        leaving = true
        onDismiss()
    }

    private var icon: String {
        switch toast.tone {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch toast.tone {
        case .success: Theme.success
        case .info: Theme.info
        case .error: Theme.danger
        }
    }
}
#endif
