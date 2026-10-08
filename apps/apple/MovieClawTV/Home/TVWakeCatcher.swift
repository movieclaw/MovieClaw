import SwiftUI
import UIKit

/// 「第一下只唤醒」：首页卡片行给大图预告让位时，遥控器的第一下（按键、在触控板上滑）只把卡片行叫回来，
/// 不移动焦点、不触发按钮（2026-10-06 用户定：不然想换下一张时直接跳走了，或者误按确认就进了正片）。
///
/// 识别器挂在窗口上（同 `TVSwipeScrubber`：遥控器的事件总是送给焦点所在的视图，窗口是所有视图的祖先）。
/// 按键用最短按压时长为 0 的长按识别器：按下那一刻就识别，`delaysTouchesBegan`（对按键同样生效）让按键先不交给视图，
/// 识别之后视图收到的是取消，焦点系统不动。只在让位期间启用
struct TVWakeCatcher: UIViewRepresentable {
    /// 是否拦截
    var active: Bool
    var onWake: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.onWake = onWake
        context.coordinator.setActive(active)
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    /// 不占地方、不可聚焦的占位视图：进了窗口就把识别器挂到窗口上
    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { coordinator?.install(on: window) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onWake: () -> Void = {}
        private var recognizers: [UIGestureRecognizer] = []
        private var active = false

        func install(on window: UIWindow) {
            guard recognizers.isEmpty else { return }
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            press.minimumPressDuration = 0
            press.allowedPressTypes = [UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow, .select, .menu, .playPause]
                .map { NSNumber(value: $0.rawValue) }
            press.allowedTouchTypes = []
            let swipe = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            for recognizer in [press, swipe] {
                recognizer.delaysTouchesBegan = true
                recognizer.delegate = self
                recognizer.isEnabled = false
                window.addGestureRecognizer(recognizer)
            }
            recognizers = [press, swipe]
            setActive(active)
        }

        func uninstall() {
            recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
            recognizers = []
        }

        func setActive(_ active: Bool) {
            self.active = active
            // 正在被按住的那一下不中途关掉：关掉会把扣下的按键放给视图，焦点照样移动。等这一下松开再关（见 handle）
            for recognizer in recognizers where recognizer.state != .began && recognizer.state != .changed {
                recognizer.isEnabled = active
            }
        }

        /// 焦点系统自己也在窗口上挂着识别器（方向键、触控板滑动）：让它们都等这边先失败——这边一识别，它们就不动焦点
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            !recognizers.contains(other)
        }

        @objc private func handle(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onWake()
            case .ended, .cancelled, .failed:
                if !active { recognizer.isEnabled = false }
            default:
                break
            }
        }
    }
}
