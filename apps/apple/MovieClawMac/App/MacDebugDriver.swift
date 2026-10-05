#if DEBUG
import AppKit
import SwiftUI

/// 开发期的自动驾驶（只在 Debug 构建里存在）：开发会话没有录屏权限、也开不了系统的 UI 自动化模式（XCUITest 跑不起来），
/// 于是由 App 自己读命令、自己截自己的窗口、往自己的窗口里合成鼠标与键盘事件——相当于进程内的 XCUITest，
/// 逐个功能点击验收用（docs/design/macos-app.md §7）。
///
/// 用法：往 `/tmp/movieclaw-mac-debug/inbox/` 写文件（文件名按顺序处理，处理完删掉），每行一条命令：
///
///     shot home                     截主窗口 → shots/home.png（截自己的窗口不需要录屏权限）
///     size 1440 900                 把主窗口调成这么大（点）
///     tab library-3                 侧边栏选中一项（MainTab 的 rawValue）
///     push item 3 120               压栈一页：item <库> <条目> / person <TMDB id> <姓名> / library <库> / collection <id> <名字>
///     pop                           返回一层
///     search 星际                   往侧边栏搜索框里填字（空 = 清空）
///     play /play/120/s01e02         起播
///     click 640 300                 在窗口里这一点（左上角为原点，点）单击；clickid <无障碍标识> 点那个控件的中心
///     rclick 640 300                右键单击（出右键菜单）
///     hover 640 300                 鼠标移到这一点（触发悬停效果）；hoverid <无障碍标识>
///     key space / key left / key f / key escape / key cmd+f   往窗口发一个按键
///     type 文字                     往当前焦点输入文字
///     dump tree                     控件树（标识、标签、角色、位置）→ mc-debug/shots/tree.txt
///     hscroll 700 300 200           在这一点横向滚动（模拟触控板左右轻扫，正数 = 手指往左划）
///     wait 1.5                      等一会儿再执行下一条
///
/// 结果与出错写进 `mc-debug/log.txt`，每条一行，便于对照。
@MainActor
final class MacDebugDriver {
    static let shared = MacDebugDriver()
    weak var router: MacRouter?

    /// 固定在 /tmp 下：Debug 构建不开沙盒，外面的脚本直接读写（沙盒容器其他进程读不了）
    /// 并行开发时每个实例各用一个目录：`-mcDebugDir /tmp/xxx`
    private let root = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "mcDebugDir") ?? "/tmp/movieclaw-mac-debug", isDirectory: true)
    private var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    private var shots: URL { root.appendingPathComponent("shots", isDirectory: true) }
    private var started = false
    private var busy = false

    /// 启动：建好目录、每 0.3 秒看一次收件箱
    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        log("调试驱动已启动：\(root.path)")
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(300))
                await drain()
            }
        }
    }

    private func drain() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter({ !$0.lastPathComponent.hasPrefix(".") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }), !files.isEmpty else { return }
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: file)
            for line in text.split(whereSeparator: \.isNewline) {
                let command = line.trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty, !command.hasPrefix("#") else { continue }
                await run(command)
            }
        }
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) && $0.title != "关于 MovieClaw" }
    }

    private func run(_ command: String) async {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        let numbers = arg.split(separator: " ").compactMap { Double($0) }
        switch verb {
        case "shot":
            shot(arg.isEmpty ? "shot" : arg)
        case "shotall":
            // 浮层（popover）、sheet、关于窗口都是独立的窗口：逐个截下来，文件名带序号与窗口标题
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                capture(window, name: "\(arg.isEmpty ? "all" : arg)-\(index)")
                for (sheetIndex, sheet) in window.sheets.enumerated() {
                    capture(sheet, name: "\(arg.isEmpty ? "all" : arg)-\(index)-sheet\(sheetIndex)")
                }
            }
        case "size":
            guard numbers.count == 2, let window else { return log("size 参数不对") }
            var frame = window.frame
            frame.origin.y += frame.height - numbers[1]
            frame.size = CGSize(width: numbers[0], height: numbers[1])
            window.setFrame(frame, display: true, animate: false)
            log("窗口改为 \(Int(numbers[0]))×\(Int(numbers[1]))")
        case "tab":
            guard let tab = MainTab(rawValue: arg) else { return log("不认识的页签 \(arg)") }
            router?.searchText = ""
            router?.select(tab)
            log("选中 \(arg)")
        case "push":
            push(arg)
        case "pop":
            router?.pop()
            log("返回")
        case "search":
            router?.searchText = arg
            log("搜索「\(arg)」")
        case "play":
            if let request = PlayRequest(webPath: arg) { router?.play(request); log("起播 \(arg)") } else { log("播放链接不对 \(arg)") }
        case "click", "rclick", "hover", "dclick":
            guard numbers.count == 2 else { return log("\(verb) 参数不对") }
            mouse(verb, at: CGPoint(x: numbers[0], y: numbers[1]))
        case "wclick":
            // wclick <窗口序号> <x> <y>：点浮层、sheet、关于窗口（序号同 shotall 的文件名）
            guard numbers.count == 3, NSApp.windows.indices.contains(Int(numbers[0])) else { return log("wclick 参数不对") }
            mouse("click", at: CGPoint(x: numbers[1], y: numbers[2]), in: NSApp.windows[Int(numbers[0])])
        case "wtype":
            // wtype <窗口序号> <文字>：往那个窗口的当前输入焦点打字
            let fields = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2, let index = Int(fields[0]), NSApp.windows.indices.contains(index) else { return log("wtype 参数不对") }
            for character in fields[1] { post(keyDown: String(character), keyCode: 0, flags: [], to: NSApp.windows[index]) }
            log("输入「\(fields[1])」→ 窗口 \(index)")
        case "clickid", "hoverid", "rclickid":
            guard let frame = frame(of: arg) else { return log("找不到控件 \(arg)") }
            mouse(String(verb.dropLast(2)), at: CGPoint(x: frame.midX, y: frame.midY))
        case "scroll":
            // scroll <x> <y> <dy>：鼠标在 (x, y) 处滚动 dy 点（正数往下看）
            guard numbers.count == 3 else { return log("scroll 参数不对") }
            scroll(at: CGPoint(x: numbers[0], y: numbers[1]), by: numbers[2])
        case "hscroll":
            // hscroll <x> <y> <dx>：在 (x, y) 处横向滚动 dx 点（触控板左右轻扫；正数 = 手指往左划）
            guard numbers.count == 3 else { return log("hscroll 参数不对") }
            scroll(at: CGPoint(x: numbers[0], y: numbers[1]), by: 0, horizontal: numbers[2])
        case "key":
            key(arg)
        case "type":
            guard let window else { return }
            for character in arg {
                post(keyDown: String(character), keyCode: 0, flags: [], to: window)
            }
            log("输入「\(arg)」")
        case "net":
            // 在 App 进程里直接取一个地址：排查本机网络权限、ATS 这类「只有 App 连不上」的问题
            guard let url = URL(string: arg) else { return log("地址不对") }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                log("net \((response as? HTTPURLResponse)?.statusCode ?? -1) \(String(decoding: data.prefix(200), as: UTF8.self))")
            } catch {
                log("net 失败 \(error)")
            }
        case "windows":
            for (index, window) in NSApp.windows.enumerated() {
                log("窗口 \(index) \(type(of: window)) 「\(window.title)」 可见=\(window.isVisible) \(Int(window.frame.width))×\(Int(window.frame.height)) sheets=\(window.sheets.count) 子窗口=\(window.childWindows?.count ?? 0)")
            }
        case "press":
            // press <标题>：在所有窗口里找这个标题的原生按钮（提醒框、sheet 里的 NSButton）直接触发。
            // 不在前台的 App 里，合成的点击会被原生按钮当成「激活窗口」吞掉
            func find(in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == arg { return button }
                for child in view.subviews { if let hit = find(in: child) { return hit } }
                return nil
            }
            if let button = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(find) }).first {
                button.performClick(nil)
                log("按下「\(arg)」")
            } else {
                log("找不到按钮「\(arg)」")
            }
        case "libs":
            // 列出媒体库与首页「接下来继续」的条目 id（tab / push 命令要用）
            let libs = (LibraryHomeStore.shared.libraries ?? []).map { "\($0.id)=\($0.name)(\($0.kind))" }.joined(separator: " ")
            let next = (LibraryHomeStore.shared.upNext ?? []).map { "\($0.libraryId)/\($0.mediaItemId)=\($0.title)" }.joined(separator: " ")
            log("库：\(libs)")
            log("接下来继续：\(next)")
        case "dump":
            dumpTree()
        case "wait":
            try? await Task.sleep(for: .seconds(numbers.first ?? 1))
        default:
            log("不认识的命令：\(command)")
        }
        // 每条命令之后让界面跑一拍，下一条看到的是更新后的样子
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func push(_ arg: String) {
        let fields = arg.split(separator: " ").map(String.init)
        guard let kind = fields.first else { return }
        switch kind {
        case "item" where fields.count == 3:
            if let lib = Int(fields[1]), let item = Int(fields[2]) { router?.push(.item(libraryId: lib, itemId: item)) }
        case "person" where fields.count >= 3:
            if let id = Int(fields[1]) { router?.push(.person(tmdbId: id, name: fields[2...].joined(separator: " "), avatar: nil, fromItem: nil)) }
        case "library" where fields.count == 2:
            if let id = Int(fields[1]) { router?.push(.library(id)) }
        case "collection" where fields.count >= 3:
            if let id = Int(fields[1]) { router?.push(.collection(id: id, name: fields[2...].joined(separator: " "))) }
        default:
            return log("push 参数不对：\(arg)")
        }
        log("压栈 \(arg)")
    }

    // MARK: 截图

    /// 截自己的主窗口（带标题栏与圆角）。截进程自己的窗口不需要录屏权限
    private func shot(_ name: String) {
        guard let window else { return log("没有可截的窗口") }
        capture(window, name: name)
    }

    private func capture(_ window: NSWindow, name: String) {
        let id = CGWindowID(window.windowNumber)
        // 新 SDK 把 CGWindowListCreateImage 标成不可用（让用 ScreenCaptureKit，那要录屏权限），系统里这个函数仍在：
        // 按符号名取来调用。只在 Debug 构建里，正式包不含这段
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return log("找不到 CGWindowListCreateImage")
        }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let options = CGWindowImageOption([.bestResolution, .boundsIgnoreFraming]).rawValue
        guard let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, id, options)?.takeRetainedValue() else {
            return log("截图失败 \(name)")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let url = shots.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("截图 \(url.path) \(image.width)×\(image.height) 「\(window.title)」\(type(of: window))")
    }

    // MARK: 鼠标与键盘

    /// 在窗口里合成鼠标事件（窗口坐标：左上角为原点，点）。悬停先发 mouseMoved，点击再补按下与抬起
    private func mouse(_ verb: String, at point: CGPoint, in target: NSWindow? = nil) {
        guard let window = target ?? self.window, let content = window.contentView else { return }
        let location = CGPoint(x: point.x, y: content.bounds.height - point.y)
        func event(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
        }
        window.makeKeyAndOrderFront(nil)
        // 悬停：SwiftUI 的 onHover 靠窗口的追踪区，发一个移动事件让它重新算鼠标在哪
        if let moved = event(.mouseMoved) { window.sendEvent(moved) }
        switch verb {
        case "click", "dclick":
            let clicks = verb == "dclick" ? 2 : 1
            if let down = event(.leftMouseDown, clicks: clicks), let up = event(.leftMouseUp, clicks: clicks) {
                // 列表、滑块这类控件按下后会自己开一个跟踪循环、从事件队列里等「抬起」：先把抬起放进队列再发按下，
                // 否则跟踪循环拿不到抬起（SwiftUI 按钮不走跟踪循环，抬起随后由事件循环照常派发）
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            }
        case "rclick":
            if let down = event(.rightMouseDown), let up = event(.rightMouseUp) {
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            }
        default:
            break
        }
        log("\(verb) (\(Int(point.x)), \(Int(point.y)))")
    }

    /// 合成滚轮（像素单位，按触控板的精确滚动处理）：分几下发，SwiftUI 的滚动视图才跟得上
    private func scroll(at point: CGPoint, by delta: Double, horizontal: Double = 0) {
        guard let window, let content = window.contentView else { return }
        let local = CGPoint(x: point.x, y: content.bounds.height - point.y)
        let screen = window.convertPoint(toScreen: local)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let steps = max(1, Int(max(abs(delta), abs(horizontal)) / 40))
        for _ in 0 ..< steps {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(-delta / Double(steps)), wheel2: Int32(-horizontal / Double(steps)),
                                   wheel3: 0) else { continue }
            cg.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
            guard let event = NSEvent(cgEvent: cg) else { continue }
            // 横向（模拟触控板轻扫）走事件队列：页面里的本地事件监听只看得到从队列里取出的事件
            if horizontal != 0 { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
        }
        log("scroll (\(Int(point.x)), \(Int(point.y))) \(Int(delta)) 横 \(Int(horizontal))")
    }

    private func key(_ spec: String) {
        guard let window else { return }
        var flags: NSEvent.ModifierFlags = []
        var name = spec.lowercased()
        for (prefix, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("shift+", .shift), ("ctrl+", .control), ("opt+", .option)] {
            while name.hasPrefix(prefix) {
                flags.insert(flag)
                name.removeFirst(prefix.count)
            }
        }
        let special: [String: (String, UInt16)] = [
            "space": (" ", 49), "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
            "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "escape": ("\u{1b}", 53), "return": ("\r", 36),
            "tab": ("\t", 48), "delete": ("\u{7f}", 51),
        ]
        let (characters, code) = special[name] ?? (name, 0)
        if flags.contains(.command), let menu = NSApp.mainMenu, let keyEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code), menu.performKeyEquivalent(with: keyEvent) {
            log("快捷键 \(spec)（菜单）")
            return
        }
        post(keyDown: characters, keyCode: code, flags: flags, to: window)
        log("按键 \(spec)")
    }

    private func post(keyDown characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                window.sendEvent(event)
            }
        }
    }

    // MARK: 控件树

    /// 按无障碍标识找控件，返回窗口坐标（左上角为原点）里的框
    private func frame(of identifier: String) -> CGRect? {
        enableAccessibilityTree()
        guard let window else { return nil }
        var found: CGRect?
        walk(window) { node, _ in
            guard found == nil, node.identifier == identifier else { return }
            found = self.windowRect(node.frame, in: window)
        }
        return found
    }

    /// 告诉 AppKit「有辅助技术在用」：没人连着时 SwiftUI 不建无障碍树（Electron 等也用这两个属性做同样的事）
    private func enableAccessibilityTree() {
        for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: name))
        }
    }

    private func dumpTree() {
        enableAccessibilityTree()
        guard let window else { return }
        var lines: [String] = []
        walk(window) { node, depth in
            guard ProcessInfo.processInfo.environment["MC_DUMP_ALL"] != nil || !node.identifier.isEmpty || !node.label.isEmpty
                    || !node.title.isEmpty || !node.value.isEmpty else { return }
            let rect = self.windowRect(node.frame, in: window)
            lines.append(String(repeating: "  ", count: min(depth, 30))
                + "[\(node.role)|\(node.className)|\(node.children.count)] id=\(node.identifier) label=\(node.label) title=\(node.title) value=\(node.value.prefix(60)) "
                + "frame=(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)))")
        }
        let url = shots.appendingPathComponent("tree.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        log("控件树 \(lines.count) 项 → \(url.path)")
    }

    /// 一个无障碍节点的读数。SwiftUI 的元素是各种私有类，统一按 NSObject 的无障碍属性读（新旧两套接口都试）
    private struct AXNode {
        let identifier: String
        let label: String
        let title: String
        let value: String
        let role: String
        let frame: CGRect
        let children: [Any]
        let className: String
    }

    private func read(_ object: Any) -> AXNode? {
        guard let node = object as? NSObject else { return nil }
        func attr(_ name: NSAccessibility.Attribute) -> Any? { node.accessibilityAttributeValue(name) }
        let element = node as? NSAccessibilityProtocol
        let identifier = element?.accessibilityIdentifier() ?? (attr(.identifier) as? String) ?? ""
        let label = element?.accessibilityLabel() ?? (attr(.description) as? String) ?? ""
        let title = element?.accessibilityTitle() ?? (attr(.title) as? String) ?? ""
        let value = (element?.accessibilityValue() as? String) ?? (attr(.value) as? String) ?? ""
        let role = element?.accessibilityRole()?.rawValue ?? (attr(.role) as? String) ?? ""
        var frame = element?.accessibilityFrame() ?? .zero
        if frame == .zero, let position = attr(.position) as? NSValue, let size = attr(.size) as? NSValue {
            frame = CGRect(origin: position.pointValue, size: size.sizeValue)
        }
        var children = element?.accessibilityChildren() ?? []
        if children.isEmpty { children = (attr(.children) as? [Any]) ?? [] }
        if children.isEmpty { children = element?.accessibilityVisibleChildren() ?? [] }
        // 没有辅助技术连着时 AppKit 不一定给出子元素：视图的话沿子视图往下找（SwiftUI 的宿主视图会在被问到时现建无障碍树）
        if children.isEmpty, let view = node as? NSView {
            children = view.subviews
        } else if children.isEmpty, let window = node as? NSWindow, let content = window.contentView {
            children = [content]
        }
        return AXNode(identifier: identifier, label: label, title: title, value: value, role: role, frame: frame, children: children,
                      className: String(describing: type(of: node)))
    }

    private func walk(_ root: Any, visit: (AXNode, Int) -> Void) {
        var stack: [(Any, Int)] = [(root, 0)]
        var seen = 0
        while let (object, depth) = stack.popLast(), seen < 30000 {
            seen += 1
            guard let node = read(object) else { continue }
            visit(node, depth)
            for child in node.children.reversed() { stack.append((child, depth + 1)) }
        }
    }

    /// 屏幕坐标（左下角原点）→ 窗口内容区坐标（左上角原点）
    private func windowRect(_ screen: CGRect, in window: NSWindow) -> CGRect {
        let inWindow = window.convertFromScreen(screen)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    // MARK: 日志

    private func log(_ text: String) {
        let line = "[\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime))] \(text)\n"
        let url = root.appendingPathComponent("log.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif
