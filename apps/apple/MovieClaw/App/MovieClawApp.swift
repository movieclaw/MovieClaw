import SwiftUI

@main
struct MovieClawApp: App {
    /// 最先执行（存储属性按声明顺序初始化，早于下面的 AppModel）：AppModel 在初始化里就可能用快照直接进
    /// 主界面、开始把首屏图片解码进内存，图片加载器必须先配好
    private let bootstrap: Void = {
        PerfTrace.markMain()
        ImagePipelineSetup.configure()
    }()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        PlayerCapability.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .toggleStyle(SystemSwitchStyle())
        }
    }
}

/// 应用代理：界面方向锁（见 `OrientationLock`），以及推送的系统回调（交给 `PushCenter`）。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushCenter.shared.start()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCenter.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushCenter.shared.didFailToRegister(error)
    }
}

/// 按 AppModel.phase 切换顶层界面。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var push = PushCenter.shared

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
                    .task { await model.restore() }
            case .needsServer, .needsSetup, .needsLogin, .chooseAccount, .unreachable:
                // 这几种状态共用同一个欢迎页（同一分支 = 同一视图身份），状态之间切换时表单里填的内容不丢
                WelcomeView(mode: .root, phase: model.phase, expired: model.expiredUsername != nil)
            case let .ready(session):
                MainTabView()
                    // 换账号（含换到另一台服务器上的同名账号）时整棵树重建，避免残留上个账号的数据
                    .id("\(model.server?.origin.absoluteString ?? "")#\(session.username)")
            }
        }
        .animation(.default, value: model.phase)
        // 冷启动用会话快照直接进了主界面：身份在后台校验（见 AppModel.revalidate），不和首帧抢主线程
        .task {
            await FirstFrameGate.wait()
            await model.revalidate()
        }
        .onAppear {
            PerfTrace.record("root.appear")
            PerfTrace.afterCommit("root.firstFrame")
            FirstFrameGate.observeNextCommit()
        }
        .onChange(of: model.session != nil) { _, ready in
            if ready { PerfTrace.record("session.ready") }
        }
        // 已经登录着（含冷启动直接进主界面）：还没问过通知权限就补问一次（升级前登录的人）
        .onChange(of: model.session != nil, initial: true) { _, ready in
            if ready { push.sessionReady() }
        }
        // 刚登录进一个账号：马上请求通知权限、登记推送（docs/design/cloud-push.md §9）
        .onChange(of: model.freshLogins) { push.didLogIn() }
        // 点开通知时人在欢迎页（本机没有能直接进的账号）：只是打开 App，不跳转。主界面里的由 MainTabView 处理
        .onChange(of: push.pendingTap, initial: true) { dropPushTapIfSignedOut() }
        .onChange(of: model.phase) { dropPushTapIfSignedOut() }
        .environment(push)
    }

    private func dropPushTapIfSignedOut() {
        switch model.phase {
        case .needsServer, .needsSetup, .needsLogin, .chooseAccount, .unreachable: push.pendingTap = nil
        case .launching, .ready: break
        }
    }
}
