import SwiftUI
import UIKit

/// 页面在栈顶时藏起标签栏，并跟着推入 / 返回转场一起动画。
/// SwiftUI 的 `.toolbarVisibility(.hidden, for: .tabBar)` 返回时要等转场结束才把标签栏补回来，
/// 底部先空约 0.5 秒再突然冒出标签栏、附件条跟着跳一截（2026-10-15 录屏逐帧确认）。
///
/// 会话页停稳时仍不显示标签栏（与 Web 手机端 `/sessions/*`、`/new` 一样，避免玻璃胶囊压住输入行，
/// 也避免两层玻璃叠在一起）。重叠只发生在「从会话页返回普通页」：标签栏为了不空底、不淡入，
/// 在转场一开始就整条出现，而正在滑走的输入框还按 Home 指示条贴底，于是中途叠在一起
/// （issue #1153）。这段时间把输入框整段抬到胶囊上方（`composerLift`，页面用它把输入区往上平移；只挪输入框、不改底栏高度，消息列不跟着重排上跳）；
/// 取消则随标签栏收回，完成后会话页已经不在，不再改它。
///
/// 不用 `additionalSafeAreaInsets`：转场期间 UIKit 不把安全区变化应用到正在离开的页面，
/// 真机日志里写成 67 后实际安全区一直停在 34，取消结束才迟到生效（2026-11-08 iPhone Air 实测，#1219 因此没修好）。
struct HidesTabBarWhenPushed: UIViewControllerRepresentable {
    /// 输入区上移的距离；只在返回转场里、标签栏露在这一页上时非 0
    @Binding var composerLift: CGFloat

    func makeUIViewController(context: Context) -> Marker { Marker() }
    func updateUIViewController(_ controller: Marker, context: Context) {
        let lift = $composerLift
        controller.setLift = { lift.wrappedValue = $0 }
    }

    final class Marker: UIViewController {
        /// 挂了标记的导航页（导航控制器的直接子控制器）→ 该页的标记
        private static let pages = NSMapTable<UIViewController, Marker>.weakToWeakObjects()
        fileprivate var setLift: ((CGFloat) -> Void)?
        private var lift: CGFloat = 0

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            var page = parent
            while let current = page, !(current.parent is UINavigationController) { page = current.parent }
            if let page { Self.pages.setObject(self, forKey: page) }
        }

        private static func isMarked(_ page: UIViewController) -> Bool { pages.object(forKey: page) != nil }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            sync()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            sync()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // 标签栏还盖在会话页上时按它的真实位置补量一次（返回开始时标签栏 frame 可能还没落位）。
            // 栈顶已经回到会话页（停稳或取消结束）时不在这里改，避免和「藏回标签栏」的动画对着抢。
            guard let tabs = tabBarController, !tabs.isTabBarHidden,
                  let navigation = navigationController,
                  navigation.topViewController.map(Self.isMarked) == false else { return }
            updateClearance(tabs: tabs, navigation: navigation, tabBarHidden: false, animated: false)
        }

        /// 按栈顶是不是挂了标记的页决定显隐，不看是谁触发的：新会话页换成会话页这类替换转场里，
        /// 离开与进入两页的回调先后不定，按各自意图设置会被后到的那笔盖掉
        private func sync() {
            guard let tabs = tabBarController, let navigation = navigationController else { return }
            let apply = { [weak self, weak navigation, weak tabs] in
                guard let self, let navigation, let tabs else { return }
                let hidden = navigation.topViewController.map(Self.isMarked) ?? false
                if tabs.isTabBarHidden != hidden { tabs.setTabBarHidden(hidden, animated: true) }
                self.updateClearance(tabs: tabs, navigation: navigation, tabBarHidden: hidden, animated: true)
            }
            // 从标记页返回普通页：标签栏在返回一开始就直接就位，不淡入。淡入时玻璃半透明、还没模糊，
            // 底下列表的白字会透出来，看着闪一下（2026-10-15 真机反馈、录屏逐帧确认）；右滑返回取消时结束后再按栈顶藏回。
            // 输入框同时立刻抬到胶囊上方（不跟手势进度插值），取消动画结束再一起收回。
            if let coordinator = navigation.transitionCoordinator,
               let from = coordinator.viewController(forKey: .from), Self.isMarked(from),
               let top = navigation.topViewController, !Self.isMarked(top) {
                tabs.setTabBarHidden(false, animated: false)
                tabs.view.layoutIfNeeded()
                updateClearance(tabs: tabs, navigation: navigation, tabBarHidden: false, animated: false)
                if !coordinator.animate(alongsideTransition: nil, completion: { _ in apply() }) {
                    DispatchQueue.main.async(execute: apply)
                }
                return
            }
            guard let coordinator = navigation.transitionCoordinator else {
                // 没有转场（如启动直接打开）：排到下一轮。在 viewWillAppear 里同步改标签栏会触发提前排版，
                // SwiftUI 环境还没就绪时直接断言崩溃（模拟器 -mcRoute /new 实测）
                DispatchQueue.main.async(execute: apply)
                return
            }
            // 放进转场的同步动画里：标签栏与页面同一条曲线进出；右滑返回中途松手取消时，结束后按栈顶再校正一次
            if !coordinator.animate(alongsideTransition: { _ in apply() }, completion: { _ in apply() }) {
                DispatchQueue.main.async(execute: apply)
            }
        }

        /// 标签栏盖住仍在屏幕上的会话页时，让那一页 `safeAreaBar` 里的输入框整段上移。
        /// 只改挂了标记的页，底下的普通页自己已经让开标签栏。
        private func updateClearance(tabs: UITabBarController, navigation: UINavigationController, tabBarHidden: Bool, animated: Bool) {
            for page in Self.markedPages(in: navigation) {
                let onScreen = page.viewIfLoaded?.window != nil
                let measured: CGFloat
                if tabBarHidden || !onScreen {
                    measured = 0
                } else if let value = Self.measure(tabs: tabs, page: page) {
                    measured = value
                } else {
                    continue
                }
                let inset = AgentTabBarClearance.appliedInset(tabBarHidden: tabBarHidden, pageOnScreen: onScreen, measured: measured)
                Self.pages.object(forKey: page)?.apply(lift: inset, animated: animated && inset == 0)
            }
        }

        private static func markedPages(in navigation: UINavigationController) -> [UIViewController] {
            var result: [UIViewController] = []
            func add(_ page: UIViewController?) {
                guard let page, isMarked(page), !result.contains(where: { $0 === page }) else { return }
                guard page.navigationController == nil || page.navigationController === navigation else { return }
                result.append(page)
            }
            for page in navigation.viewControllers { add(page) }
            add(navigation.topViewController)
            if let coordinator = navigation.transitionCoordinator {
                add(coordinator.viewController(forKey: .from))
                add(coordinator.viewController(forKey: .to))
            }
            return result
        }

        /// 量不到（标签栏还没落位）时返回 nil，调用方保持原样；侧栏 / 顶栏这类不跟输入框抢底边的返回 0。
        private static func measure(tabs: UITabBarController, page: UIViewController) -> CGFloat? {
            guard let window = page.viewIfLoaded?.window else { return nil }
            let bar = tabs.tabBar.convert(tabs.tabBar.bounds, to: window)
            let pageFrame = page.view.convert(page.view.bounds, to: window)
            let keyboard = keyboardFrame(in: page.view, window: window)
            return AgentTabBarClearance.additionalBottomInset(
                tabBar: bar,
                page: pageFrame,
                windowBottomInset: window.safeAreaInsets.bottom,
                composerPadding: AgentComposerBottomGap.padding(
                    keyboardShown: keyboard != nil,
                    windowBottomInset: window.safeAreaInsets.bottom
                ),
                keyboard: keyboard
            )
        }

        /// 停靠键盘盖住标签栏时输入框已经在键盘上，不再为标签栏加高。没弹出时引导高度为 0。
        private static func keyboardFrame(in view: UIView, window: UIWindow) -> CGRect? {
            let frame = view.convert(view.keyboardLayoutGuide.layoutFrame, to: window)
            guard frame.height > 120 else { return nil }
            return frame
        }

        /// 一次写到位：返回时胶囊不动、页面只横移，转场开始时量的距离整段都对，不用每帧跟。
        /// 收回（取消结束）时随标签栏藏回一起动画。
        private func apply(lift newLift: CGFloat, animated: Bool) {
            guard abs(lift - newLift) > 0.5, let setLift else { return }
            lift = newLift
            var transaction = Transaction(animation: animated ? .easeInOut(duration: 0.35) : nil)
            transaction.disablesAnimations = !animated
            withTransaction(transaction) { setLift(newLift) }
        }
    }
}

/// 会话页输入框与底部液态玻璃标签栏在返回转场中的让位（纯几何，单元测试见 AgentTabBarClearanceTests）。
///
/// 消失中的那一页拿不到标签栏的安全区（所以才会重叠），这里按窗口坐标补上。
/// `composerPadding` 为负表示输入框还往 Home 指示条里收（见 AgentComposerBottomGap），要一并补回来，
/// 否则会伸进胶囊 10pt。结果是输入框可视底边落在胶囊顶边之上 `gap` pt。
struct AgentTabBarClearance {
    /// 与「我的」页快捷输入贴在标签栏上方的间距一致（AgentQuickInput.bottomGap）
    static let gap: CGFloat = 8

    /// 标签栏还没布局好时返回 nil。不跟底部输入框抢位置（侧栏、顶部标签栏、已经滑出屏幕）时返回 0。
    static func additionalBottomInset(
        tabBar: CGRect,
        page: CGRect,
        windowBottomInset: CGFloat,
        composerPadding: CGFloat,
        keyboard: CGRect? = nil
    ) -> CGFloat? {
        guard tabBar.width > 1, tabBar.height > 1, page.width > 1, page.height > 1 else { return nil }
        if tabBar.minY >= page.maxY - 0.5 { return nil }
        guard competesWithBottomComposer(tabBar: tabBar, page: page) else { return 0 }
        if let keyboard, keyboardCovers(keyboard, tabBar: tabBar, page: page) { return 0 }
        let overlap = (page.maxY - windowBottomInset) - tabBar.minY
        // 取整，避免标签栏 frame 的亚像素来回跳、每帧都触发布局
        return max(0, (overlap - composerPadding + gap).rounded())
    }

    /// 停稳或取消：标签栏藏着，不抬。返回完成：会话页已经离开窗口，不抬。
    /// 只有标签栏露在仍可见的会话页上（左边缘返回中途）才用量到的距离。
    static func appliedInset(tabBarHidden: Bool, pageOnScreen: Bool, measured: CGFloat) -> CGFloat {
        guard pageOnScreen, !tabBarHidden else { return 0 }
        return max(0, measured)
    }

    /// 底边那一条短胶囊，而不是通高的侧栏或贴在顶上的标签栏。
    private static func competesWithBottomComposer(tabBar: CGRect, page: CGRect) -> Bool {
        let horizontal = tabBar.maxX > page.minX + 1 && tabBar.minX < page.maxX - 1
        let bottomBandTop = page.maxY - min(page.height * 0.35, 220)
        let inBottomBand = tabBar.midY >= bottomBandTop && tabBar.minY < page.maxY && tabBar.maxY > bottomBandTop
        let shortBar = tabBar.height < page.height * 0.5
        return horizontal && inBottomBand && shortBar
    }

    private static func keyboardCovers(_ keyboard: CGRect, tabBar: CGRect, page: CGRect) -> Bool {
        // 停靠键盘的矩形盖住胶囊；悬浮键盘停在屏幕中部、碰不到标签栏时不算盖住
        keyboard.height > 120 && keyboard.minY < tabBar.minY + 1 && keyboard.maxY > tabBar.minY
            && keyboard.maxX > page.minX && keyboard.minX < page.maxX
    }
}
