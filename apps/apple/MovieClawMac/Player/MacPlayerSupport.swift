import AppKit
import SwiftUI

// 播放器与 AppKit 打交道的几块：拿到所在窗口（全屏）、跟踪指针、音量记忆、播放时不让显示器睡眠。
// 都是 Mac 独有的，iPhone / Apple TV 版没有对应物，所以不放进 Shared。

/// 播放器所在的窗口：全屏进出、置顶。（播放器打开时主界面把窗口工具栏整个藏起，系统标题栏连同红绿灯都不显示；
/// 窗口模式下控制层左上角另画一组原生红绿灯（`MacWindowControls`），关闭播放器靠返回按钮、Esc 与 ⌘.）
///
/// 全屏取舍：退出播放器时「播放期间进的全屏」一并退掉，回到原来的窗口；打开播放器之前窗口就已经是全屏的，
/// 关掉播放器后保持全屏（那是用户自己对整个 App 的选择，不归播放器管）。
///
/// 置顶：播放期间窗口浮在所有窗口（含别的 App）前面，边看边干别的不会被盖住；菜单栏「窗口 › 播放时置顶」可关，默认开、
/// 记在本机。全屏时不置顶（全屏有自己的空间，浮动层级只会让别的 App 的窗口切不过来），关掉播放器回到普通层级。
@MainActor
@Observable
final class MacPlayerWindow {
    private(set) weak var window: NSWindow?
    /// 当前是否全屏（跟随系统通知，用户点绿灯、按 ⌃⌘F 进出也能跟上）
    private(set) var isFullScreen = false
    /// 打开播放器那一刻窗口是不是已经全屏
    private var wasFullScreenBeforePlayer = false
    private var restored = false
    /// 贴合画面之前窗口的样子（关掉播放器时还原）与当前画面尺寸（退出全屏后重新贴合）
    private var frameBeforePlayer: NSRect?
    private var fittedVideo: CGSize?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// 「播放时置顶」开关（菜单栏「窗口」里），播放器读出来设给这里
    static let floatsOnTopKey = "movieclaw.mac.player.floatsOnTop"
    var floatsOnTop = true {
        didSet { updateLevel() }
    }

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        detachObservers()
        self.window = window
        isFullScreen = window.styleMask.contains(.fullScreen)
        wasFullScreenBeforePlayer = isFullScreen
        let center = NotificationCenter.default
        for (name, value) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isFullScreen = value
                    self.updateLevel()
                    // 播放中退出全屏：回到的是进全屏前的窗口，重新贴合画面
                    if !value, let video = self.fittedVideo { self.fit(to: video) }
                }
            })
        }
        updateLevel()
    }

    private func updateLevel() {
        window?.level = floatsOnTop && !isFullScreen ? .floating : .normal
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// 关闭播放器时调：播放期间进的全屏退掉（见类注释）。只退一次：关闭按钮与视图消失都会调到，
    /// 退全屏的动画途中窗口还标着全屏，再切一次就又进去了
    func restoreFullScreenOnExit() {
        guard !restored else { return }
        restored = true
        guard let window, window.styleMask.contains(.fullScreen), !wasFullScreenBeforePlayer else { return }
        window.toggleFullScreen(nil)
    }

    /// 窗口贴合画面（同 Infuse：上下左右不留黑边）。宽度不变按比例定高；高度低于窗口最小高度时加宽，
    /// 超出屏幕时按屏幕反推；左上角不动。之后拖窗口边缘也锁着这个比例。全屏时不动，退出全屏再贴合
    func fit(to video: CGSize) {
        guard let window, video.width > 0, video.height > 0 else { return }
        fittedVideo = video
        guard !window.styleMask.contains(.fullScreen) else { return }
        let aspect = video.width / video.height
        let minimum = NSSize(width: max(window.contentMinSize.width, window.minSize.width),
                             height: max(window.contentMinSize.height, window.minSize.height))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let current = window.contentRect(forFrameRect: window.frame).size
        var size = NSSize(width: max(current.width, minimum.width, minimum.height * aspect), height: 0)
        size.height = size.width / aspect
        let maximum = window.contentRect(forFrameRect: visible).size
        if size.width > maximum.width { size = NSSize(width: maximum.width, height: maximum.width / aspect) }
        if size.height > maximum.height { size = NSSize(width: maximum.height * aspect, height: maximum.height) }
        // 屏幕放不下最小尺寸的这个比例：留黑边，不硬撑
        guard size.width >= minimum.width - 1, size.height >= minimum.height - 1 else { return }
        if frameBeforePlayer == nil { frameBeforePlayer = window.frame }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(Self.constrained(frame, to: visible), display: true, animate: true)
        window.contentAspectRatio = size
    }

    /// 关闭播放器时调：解除比例锁，窗口回到打开播放器前的大小（左上角留在现在的位置）。
    /// 还在全屏（正在退出播放期间进的全屏）时等退出完成再还原
    func restoreFrameOnExit() {
        fittedVideo = nil
        guard let window, let before = frameBeforePlayer else { return }
        frameBeforePlayer = nil
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        guard window.styleMask.contains(.fullScreen) else { return Self.restore(window, to: before) }
        Task { @MainActor [weak window] in
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didExitFullScreenNotification, object: window) {
                if let window { Self.restore(window, to: before) }
                break
            }
        }
    }

    private static func restore(_ window: NSWindow, to before: NSRect) {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - before.height, width: before.width, height: before.height)
        window.setFrame(constrained(frame, to: visible), display: true, animate: true)
    }

    private static func constrained(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    /// 离开播放器：停止观察，窗口回到普通层级
    func detach() {
        detachObservers()
        window?.level = .normal
        window = nil
    }

    /// 鼠标是否正在这个窗口里（只有这时才隐藏指针：鼠标在别的窗口 / 别的 App 上时不能把它藏掉）
    var pointerInside: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.frame.contains(NSEvent.mouseLocation)
    }

    private func detachObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}

/// 读出 SwiftUI 视图所在的 NSWindow（视图挂进窗口时回调一次）
struct MacWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 挂窗口发生在 AppKit 布局途中：推到下一拍再改 SwiftUI 状态
            let window = self.window
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}

/// 播放器音量（0～1）与静音，记在本机：下次打开播放器还是这个音量（同 QuickTime、Apple TV App）。
///
/// 音量设在引擎上（`PlayerEngine.volume`，Mac 专有）；控制器降档、换集会换一个新引擎，
/// 界面在引擎换了之后重新设一次（`apply`）
@MainActor
@Observable
final class MacPlayerVolume {
    private static let levelKey = "movieclaw.mac.player.volume"
    private static let mutedKey = "movieclaw.mac.player.muted"

    var level: Double {
        didSet { UserDefaults.standard.set(level, forKey: Self.levelKey) }
    }
    var muted: Bool {
        didSet { UserDefaults.standard.set(muted, forKey: Self.mutedKey) }
    }

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.levelKey) as? Double
        level = min(1, max(0, stored ?? 1))
        muted = UserDefaults.standard.bool(forKey: Self.mutedKey)
    }

    /// 实际给引擎的音量：静音或拖到 0 都是无声
    var effective: Float { muted ? 0 : Float(level) }

    /// 喇叭图标：按音量分档（同系统菜单栏的音量图标）
    var symbol: String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func apply(to engine: (any PlayerEngine)?) {
        engine?.volume = effective
    }

    /// ↑ ↓ 键调音量：一格 10%，调音量即解除静音
    func step(by delta: Double) {
        muted = false
        level = min(1, max(0, ((level + delta) * 10).rounded() / 10))
    }

    func toggleMute() {
        // 音量在 0 时「取消静音」没有意义：给回一个能听见的音量
        if muted || level <= 0.001 {
            muted = false
            if level <= 0.001 { level = 0.5 }
        } else {
            muted = true
        }
    }
}

/// 播放时不让显示器睡眠（暂停、关闭后恢复系统默认），对应 iPhone 版的 `isIdleTimerDisabled`
@MainActor
final class MacDisplaySleepGuard {
    private var activity: NSObjectProtocol?

    func update(playing: Bool) {
        if playing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "正在播放视频"
            )
        } else if !playing, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// 跟踪指针位置（视图内坐标，左上角为原点；离开视图时回调 nil）。
///
/// 不用 SwiftUI 的 onHover / onContinuousHover：它们只在 App 处于前台时才报，窗口在后台时（一边看片一边在别的 App 里
/// 干活）把鼠标移到画面上，控制层不会出来。这里用 AppKit 的追踪区（`.activeAlways`），前后台都报。
/// 追踪区不参与点击命中，垫在内容下面不挡任何按钮
struct MacPointerTracker: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?) -> Void)?

        override var isFlipped: Bool { true }

        /// 只跟踪、不接点击：点击穿过它落到 SwiftUI 的内容上
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }

        private func report(_ event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }
    }
}
