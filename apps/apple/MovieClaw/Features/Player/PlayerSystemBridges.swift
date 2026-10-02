import AVKit
import Combine
import MediaPlayer
import SwiftUI

/// 隔空播放（AirPlay）路由按钮：系统的 AVRoutePickerView
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        picker.accessibilityLabel = "隔空播放"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// 系统音量：iOS 不允许直接改音量，唯一的公开途径是 MPVolumeView 里的滑杆。
/// 这个视图常驻在播放器里（几乎透明），同时也把系统音量 HUD 压掉，由我们自己的胶囊显示——
/// 竖滑和侧键都是：系统 HUD 压掉后侧键若不接，按了音量会变、屏幕上却什么都没有。
@MainActor
final class SystemVolume {
    static let shared = SystemVolume()
    let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))

    private var slider: UISlider? { volumeView.subviews.compactMap { $0 as? UISlider }.first }

    /// 当前音量（0~1）
    var value: Float { AVAudioSession.sharedInstance().outputVolume }

    /// 系统音量每次变化（侧键、控制中心、我们自己拨滑杆都算），不含订阅那一刻的当前值；
    /// KVO 可能在音频线程上发，切回主线程再交给界面
    let changes = AVAudioSession.sharedInstance().publisher(for: \.outputVolume, options: [.new])
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()

    /// 能否由 App 调节（模拟器上没有真实的音量滑杆）
    var isAdjustable: Bool { slider != nil }

    func set(_ volume: Float) {
        slider?.setValue(min(1, max(0, volume)), animated: false)
        slider?.sendActions(for: .valueChanged)
    }
}

struct SystemVolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = SystemVolume.shared.volumeView
        view.alpha = 0.01
        // 外面只给 1×1 点，里面的系统滑杆却不跟着缩：iOS 26 的胶囊圆钮会按原尺寸溢出来画，
        // 暗场里能看出一个若隐若现的椭圆。裁到自身边界内，滑动时、滑完后都看不见
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// 全局界面方向锁：应用代理的 supportedInterfaceOrientationsFor 返回它。
///
/// 为什么需要锁：只调 `requestGeometryUpdate` 是一次性的「请转过去」，App 允许的方向里仍有竖屏，
/// 手机实际竖着拿时，系统在任何一次重新评估方向（控制条显隐改状态栏、视频输出重建等）时
/// 都会把界面转回竖屏，接着又被转横——真机播 4K《抓特务》实测横竖来回跳、画面位置错乱。
/// 锁住允许的方向后，系统就不会再自作主张转回去。
@MainActor
enum OrientationLock {
    /// 默认跟随手机方向（不含倒置）
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
}

/// 界面方向：播放器的「横屏」键与退出时的归还
@MainActor
enum PlayerOrientation {
    /// 横屏键：锁到横屏（左右都允许，跟随手机横放的方向）；再按锁回竖屏
    static func request(landscape: Bool) {
        apply(mask: landscape ? .landscape : .portrait, prefer: landscape ? .landscapeRight : .portrait)
    }

    /// 离开播放器：回竖屏并解除锁定，其它页面恢复跟随手机方向
    static func release() {
        apply(mask: .portrait, prefer: .portrait)
        OrientationLock.mask = .allButUpsideDown
        updateSupported()
    }

    private static func apply(mask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        OrientationLock.mask = mask
        updateSupported()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // 手机已经横着拿时用它当前的横向，避免左右颠倒
        let current = scene.effectiveGeometry.interfaceOrientation
        let target: UIInterfaceOrientationMask = mask == .landscape && current.isLandscape ? (current == .landscapeLeft ? .landscapeLeft : .landscapeRight) : prefer
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
    }

    /// 通知当前所有控制器（含全屏呈现的播放器）重新读取允许的方向
    private static func updateSupported() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
        }
    }
}

/// 播放器里的屏幕亮度（左半屏竖滑）：调的是系统屏幕亮度（与控制中心的亮度条是同一个），
/// 手势开始调节前记下原亮度，退出播放器时恢复——看片时调暗/调亮只影响这次观看（Infuse、B 站同款）。
@MainActor
enum ScreenBrightness {
    private static var original: CGFloat?

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var current: Double { Double(screen?.brightness ?? 1) }

    static func set(_ value: Double) {
        guard let screen else { return }
        if original == nil { original = screen.brightness }
        screen.brightness = CGFloat(min(1, max(0, value)))
    }

    /// 恢复进入播放器前的亮度（没调过就什么都不做）
    static func restore() {
        guard let original, let screen else { return }
        screen.brightness = original
        self.original = nil
    }
}
