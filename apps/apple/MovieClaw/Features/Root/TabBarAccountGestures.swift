import SwiftUI
import UIKit

extension Notification.Name {
    /// 长按了底部头像页签（由 AccountGestureHub 发，当前主界面收到后弹切换账号抽屉）
    static let avatarTabLongPressed = Notification.Name("movieclaw.avatarTabLongPressed")
    /// 双击了底部头像页签（当前主界面收到后切回上一个账号）
    static let avatarTabDoubleTapped = Notification.Name("movieclaw.avatarTabDoubleTapped")
}

/// 头像页签上的账号手势（仿 Instagram，2026-09-29 用户拍板）：**长按**弹出切换账号抽屉，**双击**切回上一个账号。
/// 家里几个人共用 App、切换账号是高频操作：不用先进「我的」页、不用再点一层，在哪个页签上都能直接切。
///
/// 系统标签栏（iOS 26 液态玻璃的 `UITabBar`）没有给单个页签挂手势的接口，SwiftUI 的 `Tab` 也没有；
/// 用户定过不自己绘制标签栏。做法：
/// - **识别器挂在窗口上，全局只挂一套**，每次触摸开始时系统问「这次触摸要不要」（`shouldReceive`），
///   只要落在**手指下那条标签栏**的头像按钮里的触摸，其余一概不收——不参与、不干扰 App 里别的任何手势，
///   开销只是每次按下时判断一下落点。
/// - **不绑定某一条标签栏**：换账号时整个主界面重建，新旧两套界面（各带一条标签栏）会在窗口里同时待
///   一小会儿，而新界面第一次去挂的时候它自己的标签栏往往还没上屏——按「挂到哪条标签栏」的做法，
///   换几次账号手势就挂到了被丢掉的旧标签栏上、彻底失效（2026-09-29 真机反馈、模拟器诊断日志查实）。
///   现在每次按下都现找手指下的那条，天然跟着屏幕上的走。
/// - **头像按位置认**：标签栏里并排着和页签数一样多的按钮（公开的 `UIControl`），排在最后的那个就是头像
///   （横排的最右；iPhone Duo 上标签栏竖排时是最下，见 `lastTabIndex`）。**不能按读屏名认**：没开读屏等辅助功能时系统不给页签按钮填读屏名——UI 测试
///   运行时辅助功能是开着的，模拟器上全都好使，真机上一个都认不出（同日真机反馈后查实）。
/// - 识别到手势发全局通知，当前主界面收到后动作（旧界面此时已拆掉，不会重复响应）。
///
/// 与系统手势并存：单击照常切页签、在当前页签上再点照常回到顶层；按住时系统照常把选中光圈移到头像上
/// （按压反馈），0.45 秒后弹抽屉，松手后系统会顺带选中「我的」页签、落在抽屉后面；按住再拖是系统的
/// 「滑过页签切换」，手指一动（超过 10pt）长按就不成立。标签栏滑动收起时只剩一个页签按钮，手势不生效。
@MainActor
final class AccountGestureHub: NSObject, UIGestureRecognizerDelegate {
    static let shared = AccountGestureHub()

    private weak var window: UIWindow?
    private var recognizers: [UIGestureRecognizer] = []

    /// 挂到窗口上（同一个窗口只挂一次）
    func install(on window: UIWindow) {
        guard window !== self.window else { return }
        recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
        self.window = window
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.45
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delaysTouchesEnded = false
        recognizers = [longPress, doubleTap]
        for recognizer in recognizers {
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
        }
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        NotificationCenter.default.post(name: .avatarTabLongPressed, object: nil)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        NotificationCenter.default.post(name: .avatarTabDoubleTapped, object: nil)
    }

    /// 只收落在页签栏头像按钮里的触摸
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view, let avatar = Self.avatarButton(touching: view) else { return false }
        return avatar.bounds.contains(touch.location(in: avatar))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// 手指下这颗是页签按钮时，返回同一排里的头像按钮；不是页签按钮返回 nil。
    /// 从手指下往上找第一个「父视图里正好并排着页签数那么多按钮」的按钮。不认 `UITabBar`：
    /// iPhone Duo 的竖排标签栏是另一套系统实现（`_UIFloatingBarContainerView` 里的 `_UITabButton`），
    /// 父链上根本没有 `UITabBar`，按 `UITabBar` 找时长按、双击全失效（2026-11-10 模拟器查实）。
    /// 标签栏收起时只剩一个选中页签的按钮，凑不齐一排，返回 nil
    static func avatarButton(touching view: UIView) -> UIView? {
        guard let count = tabCount(owning: view) else { return nil }
        var current: UIView? = view
        while let candidate = current {
            if candidate is UIControl, let parent = candidate.superview, let row = tabRow(in: parent, count: count),
               row.contains(where: { $0 === candidate }) {
                return avatar(in: row)
            }
            current = candidate.superview
        }
        return nil
    }

    /// 这个视图所在页签栏的页签数：沿响应链先碰到 `UITabBar` 或 `UITabBarController` 才算在页签栏里；
    /// 先碰到别的控制器说明落在页面内容里（内容里并排几个按钮不能误认成页签）
    private static func tabCount(owning view: UIView) -> Int? {
        var responder: UIResponder? = view
        while let current = responder {
            if let bar = current as? UITabBar { return nonEmpty(bar.items?.count) }
            if let tabs = current as? UITabBarController { return nonEmpty(tabs.tabBar.items?.count) }
            if current is UIViewController { return nil }
            responder = current.next
        }
        return nil
    }

    private static func nonEmpty(_ count: Int?) -> Int? {
        guard let count, count > 0 else { return nil }
        return count
    }

    /// 父视图里同尺寸、同轴排列的可见按钮正好 `count` 个时，就是一排页签按钮。
    /// 系统可以在同层插入尺寸不同的辅助 control，不能因此让整排页签失效。
    private static func tabRow(in parent: UIView, count: Int) -> [UIControl]? {
        let controls = parent.subviews.compactMap { $0 as? UIControl }.filter { !$0.isHidden && $0.bounds.width > 0 }
        guard controls.count >= count else { return nil }
        if controls.count == count { return controls }
        for seed in controls {
            let sameSize = controls.filter {
                abs($0.bounds.width - seed.bounds.width) < 1 && abs($0.bounds.height - seed.bounds.height) < 1
            }
            let horizontal = sameSize.filter { abs($0.frame.midY - seed.frame.midY) < 1 }
            if horizontal.count == count { return horizontal }
            let vertical = sameSize.filter { abs($0.frame.midX - seed.frame.midX) < 1 }
            if vertical.count == count { return vertical }
        }
        return nil
    }

    private static func avatar(in row: [UIControl]) -> UIControl? {
        lastTabIndex(row.map(\.frame)).map { row[$0] }
    }

    /// 一排页签按钮里头像那颗的下标：头像页签永远排在最后——横排取最右；竖排（iPhone Duo 外屏和内屏横向，
    /// 系统把标签栏竖着放在右侧，docs/design/iphone-duo.md §1.1）取最下
    nonisolated static func lastTabIndex(_ frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        let vertical = isVertical(frames)
        return frames.indices.max { vertical ? frames[$0].midY < frames[$1].midY : frames[$0].midX < frames[$1].midX }
    }

    /// 这排页签是竖着排的（纵向跨度大于横向）
    nonisolated static func isVertical(_ frames: [CGRect]) -> Bool {
        guard !frames.isEmpty else { return false }
        let xs = frames.map(\.midX), ys = frames.map(\.midY)
        return (ys.max()! - ys.min()!) > (xs.max()! - xs.min()!)
    }

    /// 头像页签在窗口里的位置，及页签栏是不是竖排（首次提示气泡据此摆在头像上方或左边）
    struct AvatarAnchor: Equatable {
        var frame: CGRect
        var vertical: Bool
    }

    /// 窗口里在屏的页签栏上头像按钮的位置（首次提示气泡对准它）。从页签控制器的视图往下找一排页签按钮，
    /// 跳过各页面自己的视图（同 `tabCount(owning:)`）。新旧界面交替的那一小会儿两套页签栏叠在同一个位置，取哪套都一样
    static func avatarAnchor(in window: UIWindow) -> AvatarAnchor? {
        guard let tabs = tabBarController(from: window.rootViewController), let count = nonEmpty(tabs.tabBar.items?.count) else {
            return nil
        }
        var queue: [UIView] = [tabs.view]
        var index = 0
        while index < queue.count {
            let view = queue[index]
            index += 1
            if view !== tabs.view, let owner = view.next as? UIViewController, owner !== tabs { continue }
            if let row = tabRow(in: view, count: count), let button = avatar(in: row), button.window != nil {
                return AvatarAnchor(frame: button.convert(button.bounds, to: nil), vertical: isVertical(row.map(\.frame)))
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func tabBarController(from controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = tabBarController(from: child) { return tabs }
        }
        return tabBarController(from: controller.presentedViewController)
    }
}

/// 把 AccountGestureHub 挂到主界面所在的窗口上，并报告头像按钮的位置（首次提示用）。
/// 冷启动时主界面可能比系统标签栏先上屏：找不到头像就隔 0.3 秒再找，最多找 10 次
struct TabBarAccountGestures: UIViewRepresentable {
    let onAvatar: (AccountGestureHub.AvatarAnchor) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let report = onAvatar
        DispatchQueue.main.async { Self.install(from: view, report: report, attempt: 0) }
    }

    private static func install(from view: UIView, report: @escaping (AccountGestureHub.AvatarAnchor) -> Void, attempt: Int) {
        guard let window = view.window else { return }
        AccountGestureHub.shared.install(on: window)
        if let anchor = AccountGestureHub.avatarAnchor(in: window) {
            report(anchor)
        } else if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in
                if let view { install(from: view, report: report, attempt: attempt + 1) }
            }
        }
    }
}

/// 第一次提示账号手势：本机登录了不止一个账号时才有用，所以只在账号数超过一个、且没提示过时出现一次
/// （刚添加第二个账号时立刻出现；更新前就有多个账号的，更新后第一次打开也出现一次）。
/// 气泡悬在头像页签正上方、右边与头像对齐；竖排标签栏（iPhone Duo）时摆在头像左边、底边与头像对齐，
/// 不压住栏里别的页签（不画小尖角：实心尖角压在液态玻璃上对不上质感，挨着头像本身就说明了指的是它），
/// 点一下或 6 秒后收起。
struct AccountGestureTip: View {
    /// 头像页签在窗口里的位置，及页签栏是不是竖排
    let avatar: AccountGestureHub.AvatarAnchor
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let avatarFrame = avatar.frame
            // 横排：气泡右边对齐头像右边、底边在头像上方 10pt；竖排：右边在头像左侧 12pt、底边对齐头像底边。
            // 两边至少留 12pt
            let trailing = min(proxy.size.width - 12, avatar.vertical ? avatarFrame.minX - origin.x - 12 : avatarFrame.maxX - origin.x)
            let bottom = max(0, avatar.vertical ? avatarFrame.maxY - origin.y : avatarFrame.minY - origin.y - 10)
            AccountGestureTipBubble()
            .onTapGesture(perform: dismiss)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(String(localized: .navAccountGestureTapToClose))
            .accessibilityIdentifier("account-gesture-tip")
            .frame(width: trailing, height: bottom, alignment: .bottomTrailing)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

/// 接受外层给出的窄宽度，让较长的英文提示换行；高度仍按完整文案展开。
struct AccountGestureTipBubble: View {
    let longPress: String
    let doubleTap: String

    init(
        longPress: String = String(localized: .navAccountGestureLongPress),
        doubleTap: String = String(localized: .navAccountGestureDoubleTap)
    ) {
        self.longPress = longPress
        self.doubleTap = doubleTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(longPress, systemImage: "hand.tap")
            Label(doubleTap, systemImage: "arrow.left.arrow.right")
        }
        .font(.subheadline)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .fixedSize(horizontal: false, vertical: true)
    }
}
