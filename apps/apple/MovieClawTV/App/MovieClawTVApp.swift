import SwiftUI

/// Apple TV 版入口（docs/design/tvos-app.md）。
///
/// 与 iPhone 版共用 Shared/ 里的一切非界面代码：`AppModel` 决定此刻是欢迎页还是主界面，
/// 接口、令牌、播放逻辑都是同一份；这里只有电视的界面层。
@main
struct MovieClawTVApp: App {
    /// 最先执行（存储属性按声明顺序初始化，早于下面的 AppModel）：AppModel 在初始化里就可能用快照直接进
    /// 主界面、开始加载图片，图片加载器必须先配好
    private let bootstrap: Void = {
        PerfTrace.markMain()
        ImagePipelineSetup.configure()
        // 换了 Apple TV 的系统用户：先把这个人上次选的账号设为当前账号，AppModel 直接恢复成他
        MovieClawTVApp.profileApplied = TVUserProfiles.applyPreferredAccount()
    }()
    /// 启动时已经按系统用户选好了账号（不再问「谁在看」）
    nonisolated(unsafe) static var profileApplied = false
    @State private var model = AppModel()

    init() {
        PlayerCapability.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

/// 按 `AppModel.phase` 切换顶层界面：欢迎（连接、登录、选人）或主界面。
struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @State private var gate = TVProfileGate(picked: MovieClawTVApp.profileApplied)

    private var currentAccountKey: String {
        "\(model.server?.origin.absoluteString ?? "")#\(model.session?.username ?? "")"
    }

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
                    .task { await model.restore() }
            case .needsServer, .needsSetup, .needsLogin, .chooseAccount, .unreachable:
                TVWelcomeView()
            case let .ready(session):
                if !gate.picked, model.savedAccountCount > 1 {
                    // 这台电视上登录过不止一个账号：先问「谁在看」（docs/design/tvos-app.md §5.2）
                    TVWhoIsWatchingView()
                } else {
                    TVMainView()
                        // 换账号（含换到另一台服务器上的同名账号）时整棵树重建，避免残留上个账号的数据
                        .id("\(model.server?.origin.absoluteString ?? "")#\(session.username)")
                }
            }
        }
        .environment(gate)
        .animation(.default, value: model.phase)
        // 当前账号变了（登录、「谁在看」选人、切换、退出后自动切过去）：记成这位系统用户的偏好
        .onChange(of: currentAccountKey) { _, _ in
            if let server = model.server, let username = model.session?.username {
                TVUserProfiles.remember(server: server, username: username)
            }
        }
        .task {
            await FirstFrameGate.wait()
            await model.revalidate()
        }
        .onAppear {
            FirstFrameGate.observeNextCommit()
        }
    }
}
