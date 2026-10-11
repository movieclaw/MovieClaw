import SwiftUI
import UIKit

/// 遥控器左 / 右方向键的「按下」与「松开」（点按触控板边缘、旧遥控器的方向键都算）。
///
/// SwiftUI 的 `onMoveCommand` 一次按键只报一下，按住不连发，分不出点按和长按，所以播放器的左右键改由这里接：
/// 和 `TVSwipeScrubber` 一样把识别器挂在窗口上（按键总是送给焦点所在的视图，窗口是它的祖先）。
/// 识别器只旁听、从不进入「已识别」状态：不会吞掉按键，焦点引擎照常收到。
struct TVArrowPresses: UIViewRepresentable {
    /// 是否接管
    var enabled: Bool
    /// 按下：true = 右
    var onDown: (Bool) -> Void
    /// 松开（或被系统取消）
    var onUp: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.onDown = onDown
        context.coordinator.onUp = onUp
        context.coordinator.setEnabled(enabled)
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { coordinator?.install(on: window) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDown: (Bool) -> Void = { _ in }
        var onUp: () -> Void = {}
        private var recognizer: Observer?

        func install(on window: UIWindow) {
            guard recognizer == nil else { return }
            let observer = Observer(target: nil, action: nil)
            observer.coordinator = self
            observer.delegate = self
            window.addGestureRecognizer(observer)
            recognizer = observer
        }

        func uninstall() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        func setEnabled(_ enabled: Bool) {
            guard let recognizer, recognizer.isEnabled != enabled else { return }
            recognizer.isEnabled = enabled
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    /// 只看左右键的按下 / 松开。同一时刻只跟一个键：按住右再按左，左键不算
    final class Observer: UIGestureRecognizer {
        weak var coordinator: Coordinator?
        private var held: UIPress.PressType?

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue), NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
            allowedTouchTypes = []
            cancelsTouchesInView = false
            delaysTouchesEnded = false
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            guard held == nil, let press = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow }) else { return }
            held = press.type
            coordinator?.onDown(press.type == .rightArrow)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            release(presses)
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            release(presses)
        }

        override func reset() {
            // 识别器被关掉（焦点离开画面）时按键还按着：照松开处理，不留半截长按
            if held != nil {
                held = nil
                coordinator?.onUp()
            }
            super.reset()
        }

        private func release(_ presses: Set<UIPress>) {
            guard let held, presses.contains(where: { $0.type == held }) else { return }
            self.held = nil
            coordinator?.onUp()
            // 一轮按键结束：回到初始状态等下一次
            state = .failed
        }
    }
}
