import SwiftUI
import UIKit

/// 页面在栈顶时藏起标签栏，并跟着推入 / 返回转场一起动画。
/// SwiftUI 的 `.toolbarVisibility(.hidden, for: .tabBar)` 返回时要等转场结束才把标签栏补回来，
/// 底部先空约 0.5 秒再突然冒出标签栏、附件条跟着跳一截（2026-10-15 录屏逐帧确认）。
///
/// 会话页停稳时仍不显示标签栏（与 Web 手机端 `/sessions/*`、`/new` 一样，避免玻璃胶囊压住输入行，
/// 也避免两层玻璃叠在一起）。重叠只发生在「从会话页返回普通页」：标签栏为了不空底、不淡入，
/// 在转场一开始就整条出现，而正在滑走的输入框还按 Home 指示条贴底，于是中途叠在一起
/// （issue #1153）。这段时间给会话页补上底部安全区，让输入框整段抬到胶囊上方；取消则随标签栏收回，
/// 完成后会话页已经不在，不再改它。
struct HidesTabBarWhenPushed: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Marker { Marker() }
    func updateUIViewController(_ controller: Marker, context: Context) {}

    final class Marker: UIViewController {
        /// 挂了标记的导航页（导航控制器的直接子控制器）
        private static let pages = NSHashTable<UIViewController>.weakObjects()
        /// 正在把安全区写回去，避免 layout 里再次进入
        private var updatingClearance = false
        /// 交互返回那一两秒：转场动画会按手势进度改安全区，这里每帧写回算好的距离。
        /// 链接只留住 Pin，Pin 不留住本页，避免循环引用。
        private let pinTarget = Pin()
        private var pin: CADisplayLink?

        @objc private final class Pin: NSObject {
            weak var marker: Marker?
            @objc func tick() { marker?.pinClearance() }
        }

        deinit { pin?.invalidate() }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            var page = parent
            while let current = page, !(current.parent is UINavigationController) { page = current.parent }
            if let page { Self.pages.add(page) }
        }

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
            // 标签栏还盖在会话页上时，每帧按它的真实位置钉住输入框：交互返回会把同一轮里的
            // 安全区动画跟着手势进度插值，只设一次会被抹掉，中途又叠回去。
            // 栈顶已经回到会话页（停稳或取消结束）时不在这里改，避免和「藏回标签栏」的动画对着抢。
            guard !updatingClearance, let tabs = tabBarController, !tabs.isTabBarHidden,
                  let navigation = navigationController,
                  navigation.topViewController.map(Self.pages.contains) == false else { return }
            updateClearance(tabs: tabs, navigation: navigation, tabBarHidden: false, animated: false)
        }

        /// 按栈顶是不是挂了标记的页决定显隐，不看是谁触发的：新会话页换成会话页这类替换转场里，
        /// 离开与进入两页的回调先后不定，按各自意图设置会被后到的那笔盖掉
        private func sync() {
            guard let tabs = tabBarController, let navigation = navigationController else { return }
            let apply = { [weak self, weak navigation, weak tabs] in
                guard let self, let navigation, let tabs else { return }
                let hidden = navigation.topViewController.map(Self.pages.contains) ?? false
                if tabs.isTabBarHidden != hidden { tabs.setTabBarHidden(hidden, animated: true) }
                self.updateClearance(tabs: tabs, navigation: navigation, tabBarHidden: hidden, animated: true)
            }
            // 从标记页返回普通页：标签栏在返回一开始就直接就位，不淡入。淡入时玻璃半透明、还没模糊，
            // 底下列表的白字会透出来，看着闪一下（2026-10-15 真机反馈、录屏逐帧确认）；右滑返回取消时结束后再按栈顶藏回。
            // 输入框同时立刻抬到胶囊上方（不跟手势进度插值），取消动画结束再一起收回。
            if let coordinator = navigation.transitionCoordinator,
               let from = coordinator.viewController(forKey: .from), Self.pages.contains(from),
               let top = navigation.topViewController, !Self.pages.contains(top) {
                tabs.setTabBarHidden(false, animated: false)
                tabs.view.layoutIfNeeded()
                updateClearance(tabs: tabs, navigation: navigation, tabBarHidden: false, animated: false)
                startPinning()
                let pinned = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.stopPinning()
                    apply()
                }
                if !pinned {
                    stopPinning()
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

        private func startPinning() {
            stopPinning()
            pinTarget.marker = self
            let link = CADisplayLink(target: pinTarget, selector: #selector(Pin.tick))
            link.add(to: .main, forMode: .common)
            pin = link
        }

        private func stopPinning() {
            pin?.invalidate()
            pin = nil
            pinTarget.marker = nil
        }

        private func pinClearance() {
            // 整段交互返回（含松手后、转场结束前）都按「标签栏已经出现」来抬。
            // 停掉留给转场结束回调：那时候再按栈顶把标签栏和这段让位一起收回。
            guard let tabs = tabBarController, let navigation = navigationController else {
                stopPinning()
                return
            }
            updateClearance(tabs: tabs, navigation: navigation, tabBarHidden: false, animated: false)
        }

        /// 标签栏盖住仍在屏幕上的会话页时，把那一页的底部安全区加大，`safeAreaBar` 里的输入框整段上移。
        /// 只改挂了标记的页，底下的普通页自己已经让开标签栏。
        private func updateClearance(tabs: UITabBarController, navigation: UINavigationController, tabBarHidden: Bool, animated: Bool) {
            guard !updatingClearance else { return }
            updatingClearance = true
            defer { updatingClearance = false }
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
                Self.setInset(inset, on: page, animated: animated && inset == 0)
            }
        }

        private static func markedPages(in navigation: UINavigationController) -> [UIViewController] {
            var result: [UIViewController] = []
            func add(_ page: UIViewController?) {
                guard let page, pages.contains(page), !result.contains(where: { $0 === page }) else { return }
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

        private static func setInset(_ inset: CGFloat, on page: UIViewController, animated: Bool) {
            guard abs(page.additionalSafeAreaInsets.bottom - inset) > 0.5 else { return }
            let updates = { page.additionalSafeAreaInsets.bottom = inset }
            guard animated else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                UIView.performWithoutAnimation(updates)
                CATransaction.commit()
                return
            }
            UIView.animate(withDuration: 0.35, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut], animations: updates)
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
