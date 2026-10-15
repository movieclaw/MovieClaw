import SwiftUI
import UIKit

/// 页面在栈顶时藏起标签栏，并跟着推入 / 返回转场一起动画。
/// SwiftUI 的 `.toolbarVisibility(.hidden, for: .tabBar)` 返回时要等转场结束才把标签栏补回来，
/// 底部先空约 0.5 秒再突然冒出标签栏、附件条跟着跳一截（2026-10-15 录屏逐帧确认）
struct HidesTabBarWhenPushed: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Marker { Marker() }
    func updateUIViewController(_ controller: Marker, context: Context) {}

    final class Marker: UIViewController {
        /// 挂了标记的导航页（导航控制器的直接子控制器）
        private static let pages = NSHashTable<UIViewController>.weakObjects()

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

        /// 按栈顶是不是挂了标记的页决定显隐，不看是谁触发的：新会话页换成会话页这类替换转场里，
        /// 离开与进入两页的回调先后不定，按各自意图设置会被后到的那笔盖掉
        private func sync() {
            guard let tabs = tabBarController, let navigation = navigationController else { return }
            let apply = { [weak navigation] in
                guard let navigation else { return }
                let hidden = navigation.topViewController.map(Self.pages.contains) ?? false
                if tabs.isTabBarHidden != hidden { tabs.setTabBarHidden(hidden, animated: true) }
            }
            // 从标记页返回普通页：标签栏在返回一开始就直接就位，不淡入。淡入时玻璃半透明、还没模糊，
            // 底下列表的白字会透出来，看着闪一下（2026-10-15 真机反馈、录屏逐帧确认）；右滑返回取消时结束后再按栈顶藏回
            if let coordinator = navigation.transitionCoordinator,
               let from = coordinator.viewController(forKey: .from), Self.pages.contains(from),
               let top = navigation.topViewController, !Self.pages.contains(top) {
                tabs.setTabBarHidden(false, animated: false)
                coordinator.animate(alongsideTransition: nil) { _ in apply() }
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
    }
}
