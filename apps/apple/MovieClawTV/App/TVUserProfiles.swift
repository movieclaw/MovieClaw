import Foundation
import TVServices

/// 跟随 Apple TV 的系统用户（docs/design/tvos-app.md §5.2；Apple 示例「Mapping Apple TV users to app profiles」）。
///
/// App 以「当前系统用户」运行（用户管理权限，见 project.yml）：`UserDefaults` 由系统按 Apple TV 用户自动分开，
/// 令牌与账号列表放在全家共用的钥匙串里（`KeychainScope`）。于是：
/// - 每位家庭成员各自记住「我上次选的是哪个账号」（存在自己的 `UserDefaults` 里）；
/// - 按住遥控器的 TV 键换了系统用户再打开 App，直接进入那个人的账号，跳过「谁在看」；
/// - 这台电视只有一个系统用户时（`shouldStorePreferencesForCurrentUser` 为 false）不记，登录过多个账号就每次都问。
enum TVUserProfiles {
    private static let key = "movieclaw.tv.preferredAccount"

    /// 这台电视上有多个系统用户、偏好应当按人记
    static var remembersPerUser: Bool {
        TVUserManager().shouldStorePreferencesForCurrentUser
    }

    /// 当前系统用户上次选的账号（服务器 + 用户名）
    static var preferred: (origin: URL, username: String)? {
        guard remembersPerUser,
              let stored = UserDefaults.standard.dictionary(forKey: key),
              let origin = (stored["origin"] as? String).flatMap(URL.init(string:)),
              let username = stored["username"] as? String
        else { return nil }
        return (origin, username)
    }

    /// 记下当前系统用户选了谁（「谁在看」选人、登录、切换账号之后）
    static func remember(server: ServerAddress, username: String) {
        guard remembersPerUser else { return }
        UserDefaults.standard.set(["origin": server.origin.absoluteString, "username": username], forKey: key)
    }

    /// App 启动、建 `AppModel` 之前：把当前系统用户偏好的账号设为当前账号，`AppModel` 就直接恢复成它。
    /// 返回是否已经替这个人选好了账号（是就不再问「谁在看」）
    @discardableResult
    static func applyPreferredAccount() -> Bool {
        guard let preferred else { return false }
        let list = SavedServers.load()
        guard let saved = list.first(where: { $0.address.origin == preferred.origin }),
              let account = saved.accounts.first(where: { $0.username == preferred.username }),
              TokenVault.token(server: saved.address, username: account.username) != nil
        else { return false }
        // 当前服务器记在 UserDefaults（已按系统用户分开）；这台服务器上的「当前账号」记在共用的账号列表里，改成这个人选的
        UserDefaults.standard.set(saved.address.origin, forKey: "movieclaw.server.origin")
        let active = API.AccountView(username: account.username, nickname: account.nickname, avatarUrl: account.avatarUrl, role: account.role, active: true)
        SavedServers.save(SavedServers.upserting(list, saved.address, account: active))
        return true
    }
}
