import Testing
import UIKit
@testable import MovieClaw

@MainActor
struct AgentOutsideTapTests {
    @Test func usesNativeEditorAndDismissesOnReadOnlyText() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true }
        let region = AgentOutsideTap.Region(frame: CGRect(x: 0, y: 80, width: 390, height: 80))
        controller.view.addSubview(region)
        let editor = UITextField(frame: CGRect(x: 20, y: 90, width: 300, height: 44))
        controller.view.addSubview(editor)
        #expect(editor.becomeFirstResponder())
        #expect(editor.isFirstResponder)
        let body = UITextView(frame: CGRect(x: 20, y: 200, width: 300, height: 60))
        body.isEditable = false
        controller.view.addSubview(body)
        let textChild = UIView(frame: body.bounds)
        body.addSubview(textChild)
        let outside = CGPoint(x: 40, y: 220)
        // 不提供 SwiftUI FocusState：仅靠真实输入控件的编辑状态即可判断。
        #expect(region.shouldDismiss(at: outside, target: textChild))
        #expect(region.shouldDismiss(at: outside, target: UIButton()))
        #expect(!region.shouldDismiss(at: CGPoint(x: 40, y: 110), target: editor))
        body.isEditable = true
        #expect(!region.shouldDismiss(at: outside, target: textChild))
        #expect(!region.shouldDismiss(at: outside, target: UITextField()))
        // 页面里其他输入框获得焦点时，不能被 AI 输入框的观察器结束编辑。
        #expect(body.becomeFirstResponder())
        #expect(!region.shouldDismiss(at: CGPoint(x: 40, y: 300), target: UILabel()))
        window.endEditing(true)
        #expect(!region.shouldDismiss(at: outside, target: UILabel()))
    }

    @Test func recognizerFollowsItsWindowAndIsRemovedWithComposer() {
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let second = UIWindow(frame: first.frame)
        let region = AgentOutsideTap.Region()
        #expect(!region.tap.isEnabled)
        #expect(!region.tap.cancelsTouchesInView)
        #expect(!region.tap.delaysTouchesEnded)
        first.addSubview(region)
        #expect(region.tap.view === first)
        second.addSubview(region)
        #expect(region.tap.view === second)
        #expect(!(first.gestureRecognizers ?? []).contains(region.tap))
        region.removeFromSuperview()
        #expect(region.tap.view == nil)
        first.addSubview(region)
        AgentOutsideTap.dismantleUIView(region, coordinator: ())
        #expect(region.tap.view == nil)
        #expect(region.onDismiss == nil)
    }
}
