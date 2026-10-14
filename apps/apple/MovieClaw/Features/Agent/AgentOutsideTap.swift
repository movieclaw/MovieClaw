import SwiftUI
import UIKit

/// 只在输入框编辑期间接收框外轻点，不盖透明按钮，也不吞掉消息、链接或页面按钮的点击。
struct AgentOutsideTap: UIViewRepresentable {
    let enabled: Bool
    var onDismiss: () -> Void

    func makeUIView(context: Context) -> Region {
        let view = Region()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Region, context: Context) {
        view.onDismiss = onDismiss
        view.tap.isEnabled = enabled
    }

    static func dismantleUIView(_ view: Region, coordinator: ()) {
        view.tap.view?.removeGestureRecognizer(view.tap)
        view.onDismiss = nil
    }

    final class Region: UIView, UIGestureRecognizerDelegate {
        var onDismiss: (() -> Void)?
        lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            tap.isEnabled = false
            return tap
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            window?.addGestureRecognizer(tap)
        }

        @objc private func dismiss() {
            window?.endEditing(true)
            onDismiss?()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window else { return false }
            return shouldDismiss(at: touch.location(in: window), target: touch.view)
        }

        func shouldDismiss(at point: CGPoint, target: UIView?) -> Bool {
            guard let window,
                  let editor = editingInput(in: window),
                  bounds.contains(editor.convert(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: self)),
                  !bounds.contains(convert(point, from: window)),
                  !window.keyboardLayoutGuide.layoutFrame.contains(point) else { return false }
            // 点另一个输入控件时由系统转移焦点，不在它刚拿到焦点后又收起键盘。
            var ancestor = target
            while let view = ancestor {
                if let field = view as? UITextField, field.isEnabled { return false }
                if let text = view as? UITextView, text.isEditable { return false }
                ancestor = view.superview
            }
            return true
        }

        // safeAreaBar 中 SwiftUI 的 FocusState 可能与系统编辑状态不同步，以原生输入控件为准。
        private func editingInput(in view: UIView) -> UIView? {
            if view.isFirstResponder, view is UITextField || view is UITextView { return view }
            for child in view.subviews {
                if let editor = editingInput(in: child) { return editor }
            }
            return nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
