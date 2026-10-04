import SwiftUI

/// Mac 版入口（docs/design/macos-app.md）。
///
/// 与 iPhone、Apple TV 版共用 Shared/ 里的一切非界面代码：`AppModel` 决定此刻是欢迎页还是主界面，
/// 接口、令牌、播放逻辑都是同一份；这里只有 Mac 的界面层。版式参照 macOS 上的 Apple Music：
/// 左侧可收起的侧边栏（顶上搜索框）+ 右侧内容区，液态玻璃只用在侧边栏、工具栏与播放器的浮层上。
@main
struct MovieClawMacApp: App {
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
            MacRootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 860)
        .windowResizability(.contentMinSize)
        .commands { MacCommands(model: model) }

        // 关于：版本号与开源组件许可（LGPL 合规必需，不能省）
        Window("关于 MovieClaw", id: "about") {
            MacAboutView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// 按 `AppModel.phase` 切换顶层界面：欢迎（连接、登录、选人）或主界面。
struct MacRootView: View {
    @Environment(AppModel.self) private var model

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
                MacMainView()
                    // 换账号（含换到另一台服务器上的同名账号）时整棵树重建，避免残留上个账号的数据
                    .id("\(model.server?.origin.absoluteString ?? "")#\(session.username)")
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Theme.background)
        .animation(.default, value: model.phase)
        .task {
            await FirstFrameGate.wait()
            await model.revalidate()
        }
        .onAppear {
            FirstFrameGate.observeNextCommit()
            #if DEBUG
            MacDebugDriver.shared.start()
            #endif
        }
    }
}
