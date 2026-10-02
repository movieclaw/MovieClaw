import Foundation

#if DEBUG
/// 开发期启动参数（仅 Debug 构建生效，Release 里整段不存在）：
///
///     xcrun simctl launch <设备> io.movieclaw.app \
///         -mcServer http://localhost:3000 -mcUser admin -mcPass xxx -mcRoute /library/1
///
/// - `-mcServer/-mcUser/-mcPass`：跳过连接页与登录页，直接以该账号进入；
/// - `-mcRoute`：启动后打开一个 Web 站内路径（与网页地址一一对应），
///   用于和浏览器同一路由截图对照；`/play/{id}` 直接打开播放器。
///   `-mcRouteDelay <秒>` 让它等落地页的冷启动请求跑完再开（量起播耗时用）。
/// - `-mcTab library`：冷启动落在这个页签（代替按身份定的默认落点）；
/// - `-mcPerf YES`：记录页面打开打点（见 PerfTrace）；`-mcPerfScript "library@4,subscriptions@8"`
///   按「页签或站内路径@距 main 的秒数」依次切换，量切页耗时用。
///
/// 参数经 UserDefaults 的命令行域读取（`-key value` 形式）。
enum DebugLaunch {
    static var server: String? { UserDefaults.standard.string(forKey: "mcServer") }
    static var username: String? { UserDefaults.standard.string(forKey: "mcUser") }
    static var password: String? { UserDefaults.standard.string(forKey: "mcPass") }
    static var route: String? { UserDefaults.standard.string(forKey: "mcRoute") }
    static var routeDelay: Double? { UserDefaults.standard.object(forKey: "mcRouteDelay").map { _ in UserDefaults.standard.double(forKey: "mcRouteDelay") } }
    static var tab: MainTab? { UserDefaults.standard.string(forKey: "mcTab").flatMap(MainTab.init(rawValue:)) }
    /// 每步是页签名或站内路径（`/discover/tv` 切到剧集视角）
    static var perfScript: [(target: String, at: Double)] {
        (UserDefaults.standard.string(forKey: "mcPerfScript") ?? "").split(separator: ",").compactMap { step in
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { return nil }
            return (String(parts[0]), at)
        }
    }
}
#endif
