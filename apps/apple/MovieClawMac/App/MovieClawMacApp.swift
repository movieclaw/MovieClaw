import SwiftUI

/// Mac 版入口（docs/design/macos-app.md）。
///
/// 与 iPhone、Apple TV 版共用 Shared/ 里的一切非界面代码：`AppModel` 决定此刻是欢迎页还是主界面，
/// 接口、令牌、播放逻辑都是同一份；这里只有 Mac 的界面层。版式参照 macOS 上的 Apple Music：
/// 左侧可收起的侧边栏（顶上搜索框）+ 右侧内容区，液态玻璃只用在侧边栏、工具栏与播放器的浮层上。
@main
struct MovieClawMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    /// 最先执行（存储属性按声明顺序初始化，早于下面的 AppModel）：AppModel 在初始化里就可能用快照直接进
    /// 主界面、开始加载图片，图片加载器必须先配好
    private let bootstrap: Void = {
        PerfTrace.markMain()
        ImagePipelineSetup.configure()
    }()
    @State private var model = AppModel()

    init() {
        PlayerCapability.prewarm()
    }

    var body: some Scene {
        WindowGroup("MovieClaw", id: "main") {
            // GitHub 下载的版本没装进「应用程序」时，先引导安装（MacInstallGate.swift），不进主界面
            if let problem = MacInstallLocation.problem {
                MacInstallGateView(problem: problem)
                    .frame(minWidth: 640, minHeight: 480)
                    .preferredColorScheme(.dark)
            } else {
                MacRootView()
                    .environment(model)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 1320, height: 860)
        .windowResizability(.contentMinSize)
        .commands { MacCommands(model: model) }

        // 设置（⌘,）：目前只有「通用 › 软件更新」
        Settings {
            MacSettingsView()
                .preferredColorScheme(.dark)
        }

        // 关于：版本号与开源组件许可（LGPL 合规必需，不能省）
        Window(String(localized: .settingsAboutWindowTitle), id: "about") {
            MacAboutView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // 添加账号：独立的小窗口（同 Apple Music 的登录窗口），不挂在主窗口上——登录成功那一刻主界面按新账号整棵重建，
        // 与它无关；只有红绿灯、系统半透明的窗口底
        Window(String(localized: .authLoginAddAccount), id: MacAddAccountView.windowID) {
            MacAddAccountView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
    }
}

/// 关掉主窗口就退出（单窗口 App，同「系统设置」）：留在程序坞里也没有别的事可做。
/// 正在播放时退出会同步补发一次「停止」（PlaybackController 监听 willTerminate），续播点不丢
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // GitHub 直接分发版的自动更新（商店版、开发版里什么都不做）
        MacUpdater.shared.launch()
    }
}

/// 按 `AppModel.phase` 切换顶层界面：欢迎（连接、登录、选人）或主界面。
struct MacRootView: View {
    /// 主界面的窗口最小尺寸；播放时由播放器换成按画面比例算的小尺寸（`MacWindowMinimumKey`）
    static let minimumSize = CGSize(width: 960, height: 600)

    @Environment(AppModel.self) private var model
    @State private var playerMinimum: CGSize?

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await model.restore() }
            case .needsServer, .needsSetup, .needsLogin, .chooseAccount, .unreachable:
                MacWelcomeView()
            case let .ready(session):
                // 换账号（含换到另一台服务器上的同名账号）：主界面里按账号重建（见 MacMainView.accountKey），
                // 分栏视图本身不重建——在同一个窗口里拆掉重建 NavigationSplitView，系统不恢复标题栏区域的布局，
                // 侧边栏整体顶到标题栏里、搜索框压住红绿灯（从有大图的首页切到另一个账号时实测）
                MacMainView(accountKey: "\(model.server?.origin.absoluteString ?? "")#\(session.username)")
            }
        }
        .onPreferenceChange(MacWindowMinimumKey.self) { playerMinimum = $0 }
        .frame(minWidth: (playerMinimum ?? Self.minimumSize).width, minHeight: (playerMinimum ?? Self.minimumSize).height)
        .background(Theme.background)
        .animation(.default, value: model.phase)
        .task {
            await FirstFrameGate.wait()
            await model.revalidate()
        }
        .onAppear {
            MacPerformance.start()
            FirstFrameGate.observeNextCommit()
            #if DEBUG
            MacDebugDriver.shared.start()
            #endif
        }
    }
}
