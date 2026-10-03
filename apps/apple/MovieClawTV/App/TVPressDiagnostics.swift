import UIKit

/// 临时诊断：真机上「返回键在任何页面都失灵」查因用（2026-10-03，模拟器复现不出来）。
///
/// 只旁听、不拦截：在 `UIApplication.sendEvent` 前面记一笔再原样交给系统，不改变任何按键行为。
/// 每次按键记下键名、阶段、当时的焦点、焦点所在的响应链、界面控制器层级（含弹出的全屏页）；
/// 每次焦点变化记下新的焦点。写到 `Library/Caches/press-diag.log`（超过 2 MB 截掉前一半），
/// 用 `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier io.movieclaw.app` 拷回来看；
/// 同时打到标准错误，`devicectl device process launch --console` 能实时看到。
/// 查清楚后整个文件连同 `MovieClawTVApp` 里的 `install()` 一起删掉。
@MainActor
enum TVPressDiagnostics {
    private static var installed = false
    /// 主界面挂上来的路由快照（当前页签、各页签的导航栈、播放器），按键时一起记
    static var routerState: (() -> String)?
    private static let fileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "press-diag.log")
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func install() {
        guard !installed else { return }
        installed = true
        if let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
           let spy = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.mcDiagSendEvent(_:))) {
            method_exchangeImplementations(original, spy)
        }
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            let next = context.map { describe($0.nextFocusedItem) } ?? "?"
            MainActor.assumeIsolated { write("焦点 → \(next)") }
        }
        write("==== 启动 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")")
    }

    static func observe(_ event: UIEvent) {
        guard let presses = (event as? UIPressesEvent)?.allPresses, !presses.isEmpty else { return }
        for press in presses {
            let line = "按键 \(name(press.type)) \(phase(press.phase))"
            // 只在按下时把现场整个记下来，松开只记一行
            guard press.phase == .began else { write(line); continue }
            var lines = [line]
            let window = keyWindow
            let focused = window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
            lines.append("  焦点：\(describe(focused))")
            // 焦点环境链：看得出焦点在侧边栏里、页面里还是弹出的全屏页里
            var environments: [String] = []
            var environment: (any UIFocusEnvironment)? = focused?.parentFocusEnvironment
            while let current = environment, environments.count < 40 {
                environments.append(String(describing: type(of: current)).prefix(80).description)
                environment = current.parentFocusEnvironment
            }
            lines.append("  焦点环境链：\(environments.joined(separator: " → "))")
            if let state = routerState?() { lines.append("  路由：\(state)") }
            if let responder = focused as? UIResponder ?? (focused as? UIView) {
                var chain: [String] = []
                var next: UIResponder? = responder
                while let current = next, chain.count < 30 {
                    chain.append(String(describing: type(of: current)))
                    next = current.next
                }
                lines.append("  响应链：\(chain.joined(separator: " → "))")
            }
            lines.append("  场景：\(scenes)")
            if let root = window?.rootViewController {
                lines.append("  控制器：")
                dump(root, depth: 2, into: &lines)
            }
            write(lines.joined(separator: "\n"))
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    private static var scenes: String {
        UIApplication.shared.connectedScenes.map { scene in
            let state = switch scene.activationState {
            case .foregroundActive: "前台活跃"
            case .foregroundInactive: "前台不活跃"
            case .background: "后台"
            default: "未连接"
            }
            let windows = (scene as? UIWindowScene)?.windows.map {
                "\(type(of: $0))\($0.isKeyWindow ? "*" : "")\($0.isHidden ? "(隐藏)" : "")"
            } ?? []
            return "\(state) 窗口[\(windows.joined(separator: ", "))]"
        }.joined(separator: "; ")
    }

    /// 控制器树：子控制器缩进列出，弹出的页面（presented）单独标出；标签栏控制器写选中项与标签栏是否隐藏
    private static func dump(_ controller: UIViewController, depth: Int, into lines: inout [String]) {
        guard depth < 24 else { return }
        var text = String(repeating: "  ", count: depth) + String(describing: type(of: controller))
        if let tabs = controller as? UITabBarController {
            text += " [选中 \(tabs.selectedIndex)，标签栏\(tabs.tabBar.isHidden ? "隐藏" : "显示")]"
        }
        if let navigation = controller as? UINavigationController {
            text += " [栈 \(navigation.viewControllers.count) 层]"
        }
        if controller.view.window == nil, controller.isViewLoaded { text += "（不在窗口里）" }
        lines.append(text)
        for child in controller.children {
            dump(child, depth: depth + 1, into: &lines)
        }
        if let presented = controller.presentedViewController, presented.presentingViewController === controller {
            lines.append(String(repeating: "  ", count: depth + 1) + "▶ 弹出：")
            dump(presented, depth: depth + 2, into: &lines)
        }
    }

    private static func describe(_ item: (any UIFocusItem)?) -> String {
        guard let item else { return "（无）" }
        var parts = [String(describing: type(of: item))]
        if let view = item as? UIView {
            if let id = view.accessibilityIdentifier, !id.isEmpty { parts.append("id=\(id)") }
            parts.append("frame=\(view.convert(view.bounds, to: nil).integral)")
        } else {
            parts.append("frame=\(item.frame.integral)")
        }
        if let element = item as? NSObject, let label = element.accessibilityLabel, !label.isEmpty {
            parts.append("「\(label.prefix(40))」")
        }
        return parts.joined(separator: " ")
    }

    private static func name(_ type: UIPress.PressType) -> String {
        switch type {
        case .menu: "返回(menu)"
        case .select: "确认(select)"
        case .playPause: "播放暂停"
        case .upArrow: "上"
        case .downArrow: "下"
        case .leftArrow: "左"
        case .rightArrow: "右"
        case .pageUp: "pageUp"
        case .pageDown: "pageDown"
        case .tvRemoteOneTwoThree: "123"
        case .tvRemoteFourColors: "四色"
        default: "其他(\(type.rawValue))"
        }
    }

    private static func phase(_ phase: UIPress.Phase) -> String {
        switch phase {
        case .began: "按下"
        case .changed: "变化"
        case .stationary: "保持"
        case .ended: "松开"
        case .cancelled: "取消"
        @unknown default: "未知"
        }
    }

    private static func write(_ text: String) {
        let line = "\(clock.string(from: .now)) \(text)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: fileURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > 2_000_000 {
            // 超过 2 MB：留后一半
            try? handle.seek(toOffset: size / 2)
            let tail = (try? handle.readToEnd()) ?? Data()
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: tail)
        }
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

extension UIApplication {
    /// 与 `sendEvent(_:)` 交换了实现：这里调自己其实是调系统原来的 sendEvent
    @objc func mcDiagSendEvent(_ event: UIEvent) {
        TVPressDiagnostics.observe(event)
        mcDiagSendEvent(event)
    }
}
