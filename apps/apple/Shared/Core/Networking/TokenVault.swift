import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// 设备令牌的钥匙串存储（docs/design/login-devices.md §8）。
///
/// App 登录不再借用网页的会话 Cookie：`POST /auth/device/login` 用账号密码换一枚**长期有效**的设备令牌，
/// 每个请求带 `Authorization: Bearer`。令牌按「服务器 + 用户名」一枚一条存进钥匙串：
/// - 多账号完全在本机：切换账号就是换一枚令牌，不用联网、没有账号数上限，同一台主机不同端口也互不覆盖；
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：不进 iCloud 钥匙串、不随备份恢复到另一台手机——
///   令牌代表的是「这台设备」，服务端「我的设备」里那一行说的就是它；
/// - 令牌失效（被注销、改了密码）时删掉这一条，账号快照保留，用户点它只需重新输密码；
/// - Apple TV 上存进全家共用的那份钥匙串（`KeychainScope`）：一个人登录一次，「谁在看」里全家都能用。
nonisolated enum TokenVault {
    private static let service = "io.movieclaw.app.tokens"

    static func save(_ token: String, server: ServerAddress, username: String) {
        let query = baseQuery(server, username)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        AuthTokenRegistry.shared.remember(token, server: server, username: username)
    }

    static func token(server: ServerAddress, username: String) -> String? {
        var query = baseQuery(server, username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删掉一个登录的令牌（退出、移除账号、令牌失效）。iPhone 上这个登录的推送密钥一起删
    /// （docs/design/cloud-push.md §9）：之后那台服务器推来的内容解不开，只显示通用文案
    static func delete(server: ServerAddress, username: String) {
        SecItemDelete(baseQuery(server, username) as CFDictionary)
        AuthTokenRegistry.shared.forget(server: server, username: username)
        #if os(iOS)
        PushKeyStore.shared.remove(for: PushLogin(server: server, username: username))
        #endif
    }

    /// 清空全部令牌（UI 测试重置、退出全部账号），推送密钥同上
    static func clearAll() {
        SecItemDelete(KeychainScope.shared([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]) as CFDictionary)
        AuthTokenRegistry.shared.forgetAll()
        #if os(iOS)
        PushKeyStore.shared.removeAll()
        #endif
    }

    private static func baseQuery(_ server: ServerAddress, _ username: String) -> [String: Any] {
        KeychainScope.shared([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(server.origin.absoluteString)#\(username.lowercased())",
        ])
    }

    /// 改用设备令牌之前的版本把会话 Cookie 备份在钥匙串里（`io.movieclaw.app.cookies`）并存在
    /// `HTTPCookieStorage`。那些 Cookie 在服务端仍是有效凭证，新版本不再使用，启动时清掉，不在本机留着
    static func removeLegacyCookies() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.movieclaw.app.cookies"] as CFDictionary)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }
}

/// 本机的 App 安装标识：登录时报给服务端，同一台设备同一个人重新登录时替换旧令牌，而不是在
/// 「我的设备」里越积越多。存钥匙串（`ThisDeviceOnly`）：卸载重装后通常还在，换手机不会跟过去。
nonisolated enum InstallationID {
    private static let service = "io.movieclaw.app.installation"

    static let value: String = {
        // Apple TV 上全家共用一份：同一台电视换了系统用户还是同一台设备
        let query = KeychainScope.shared([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "installation-id",
        ])
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let fresh = "\(ClientPlatform.kind)-" + UUID().uuidString.lowercased()
        var add = query
        add[kSecValueData as String] = Data(fresh.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
        return fresh
    }()
}

/// 登录时报给服务端的这台设备的信息（「我的设备」里显示）
@MainActor
enum DeviceInfo {
    /// 默认设备名：机型的型号名（「iPhone」「iPad」「Apple TV」），Mac 上是电脑名。iOS 16 起读不到用户起的设备名（要特殊权限），
    /// 用户可以在「设置 → 设备」里给它改名
    static var name: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        // Mac 读得到用户起的电脑名（「小明的 MacBook Air」），比型号更好认
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// 「iOS 26.0 · iPhone18,4」「tvOS 26.0 · AppleTV14,1」
    static var platform: String {
        "\(ClientPlatform.osName) \(ClientPlatform.osVersion) · \(APIClient.machineModel)"
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var client: API.DeviceClientInfo {
        API.DeviceClientInfo(kind: ClientPlatform.kind, installationId: InstallationID.value, name: name, platform: platform, clientVersion: appVersion)
    }
}

/// 图片加载用的令牌表。
///
/// 界面各处的图片（海报、背景、头像……）只拿一个 URL 交给 Nuke，不经过 `APIClient`；后端的图片接口又要登录。
/// 这里按服务器记住「当前账号」的令牌，图片加载器（`AuthorizedDataLoader`）据 URL 的主机补上
/// `Authorization` 头。切换账号列表里要显示别的账号的头像：头像地址带 `mc_account=<用户名>`
/// 标记（`AvatarURL.tagged`），加载器据此换用那个账号的令牌。
nonisolated final class AuthTokenRegistry: @unchecked Sendable {
    static let shared = AuthTokenRegistry()

    private let lock = NSLock()
    /// 服务器 → 当前账号的令牌
    private var current: [String: String] = [:]
    /// 服务器#用户名 → 令牌（切换账号列表里的头像）
    private var accounts: [String: String] = [:]

    func setCurrent(_ token: String?, server: ServerAddress) {
        lock.withLock { current[Self.key(server.origin)] = token }
    }

    func remember(_ token: String, server: ServerAddress, username: String) {
        lock.withLock { accounts["\(Self.key(server.origin))#\(username.lowercased())"] = token }
    }

    func forget(server: ServerAddress, username: String) {
        lock.withLock { _ = accounts.removeValue(forKey: "\(Self.key(server.origin))#\(username.lowercased())") }
    }

    func hasToken(server: ServerAddress, username: String) -> Bool {
        lock.withLock { accounts["\(Self.key(server.origin))#\(username.lowercased())"] != nil }
    }

    func forgetAll() {
        lock.withLock {
            current.removeAll()
            accounts.removeAll()
        }
    }

    /// 某个请求该带的令牌：带 `mc_account` 标记的用那个账号的，否则用这台服务器当前账号的
    func token(for url: URL) -> String? {
        let origin = Self.key(url)
        let account = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == AvatarURL.accountParameter })?.value
        return lock.withLock {
            if let account, let token = accounts["\(origin)#\(account.lowercased())"] { return token }
            return current[origin]
        }
    }

    /// scheme://host:port，与 `ServerAddress.origin` 可比
    private static func key(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "http"
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

/// 别的账号的头像地址：带上 `mc_account` 标记，图片加载器据此换用那个账号的令牌（服务端忽略这个参数）
nonisolated enum AvatarURL {
    static let accountParameter = "mc_account"

    static func tagged(_ raw: String?, username: String) -> String? {
        guard let raw, !raw.isEmpty, !raw.contains("\(accountParameter)=") else { return raw }
        let separator = raw.contains("?") ? "&" : "?"
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        return "\(raw)\(separator)\(accountParameter)=\(encoded)"
    }
}
