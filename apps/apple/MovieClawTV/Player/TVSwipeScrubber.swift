import SwiftUI
import UIKit

/// Siri Remote 触控板上的滑动（docs/design/tvos-app.md §4.2）。
///
/// tvOS 的 SwiftUI 没有拖动手势（`DragGesture` 不可用），方向键点按（`onMoveCommand`）又收不到连续的滑动，
/// 所以用 UIKit 的平移识别器接住遥控器的间接触摸。识别器挂在窗口上：遥控器的触摸总是送给当前焦点所在的视图，
/// 窗口是所有视图的祖先，焦点落在播放器的哪一层都收得到。只在播放器「没有面板、没有按钮要焦点」时启用，
/// 否则会和焦点引擎抢同一次滑动（面板里左右滑是在选项之间移动焦点）。
///
/// 回调只报「这一次滑动累计移动了多少」（以屏幕宽度为单位）与方向，换算成拖动目标由播放器决定。
struct TVSwipeScrubber: UIViewRepresentable {
    enum Phase {
        case began, changed, ended, cancelled
    }

    /// 是否接管滑动
    var enabled: Bool
    /// 水平拖动：累计位移占屏幕宽度的比例（右为正）
    var onHorizontal: (Phase, CGFloat) -> Void
    /// 一次以竖直为主的滑动结束：true = 向下
    var onVertical: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.onHorizontal = onHorizontal
        context.coordinator.onVertical = onVertical
        context.coordinator.setEnabled(enabled)
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
        var onHorizontal: (Phase, CGFloat) -> Void = { _, _ in }
        var onVertical: (Bool) -> Void = { _ in }
        private var recognizer: UIPanGestureRecognizer?
        /// 这一次滑动判定成了什么：水平拖进度、竖直（上下滑），还没判定
        private var axis: Axis?
        private enum Axis { case horizontal, vertical }

        func install(on window: UIWindow) {
            guard recognizer == nil else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.cancelsTouchesInView = false
            pan.delegate = self
            window.addGestureRecognizer(pan)
            recognizer = pan
        }

        func uninstall() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        func setEnabled(_ enabled: Bool) {
            guard let recognizer, recognizer.isEnabled != enabled else { return }
            // 关掉时正在进行的滑动随之取消（回调 cancelled），不留半截拖动
            recognizer.isEnabled = enabled
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            let width = max(pan.view?.bounds.width ?? 1920, 1)
            let translation = pan.translation(in: pan.view)
            switch pan.state {
            case .began:
                axis = nil
            case .changed:
                if axis == nil {
                    // 手指刚放上去的抖动不算：先走出一小段再按主方向定性，之后整次滑动都按这个方向处理
                    guard hypot(translation.x, translation.y) > 24 else { return }
                    axis = abs(translation.x) >= abs(translation.y) ? .horizontal : .vertical
                    if axis == .horizontal { onHorizontal(.began, 0) }
                }
                if axis == .horizontal { onHorizontal(.changed, translation.x / width) }
            case .ended:
                switch axis {
                case .horizontal: onHorizontal(.ended, translation.x / width)
                case .vertical where abs(translation.y) > 120: onVertical(translation.y > 0)
                default: break
                }
                axis = nil
            case .cancelled, .failed:
                if axis == .horizontal { onHorizontal(.cancelled, 0) }
                axis = nil
            default:
                break
            }
        }
    }
}
