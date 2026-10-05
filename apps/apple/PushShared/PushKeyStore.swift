import CryptoKit
import Foundation
import Security

/// 一个登录：一台服务器 + 它上面的一个账号。与 TokenVault 的钥匙串条目同一个口径：
/// 服务器取 `ServerAddress.origin` 的字符串，用户名不分大小写
nonisolated struct PushLogin: Hashable, Codable, Sendable {
    let origin: String
    let username: String

    init(origin: String, username: String) {
        self.origin = origin
        self.username = username.lowercased()
    }

    /// 钥匙串条目的 account：`<服务器>#<小写用户名>`
    var account: String { "\(origin)#\(username)" }
}

/// 通知扩展要知道的一个登录的信息：配图从哪台服务器下载、副标题里怎么称呼它，点开时切到哪个账号
nonisolated struct PushLoginInfo: Codable, Hashable, Sendable {
    /// 服务器根地址（`http://192.168.1.10:3000`）
    var origin: String
    /// 用户名（保留原样，切换账号用）
    var username: String
    /// 服务器的称呼：推送明文里没带服务器名时用（App 这边只知道地址，取主机和端口）
    var serverName: String
    /// 账号的称呼（昵称）：推送明文里没带账号名时用
    var accountName: String

    var login: PushLogin { PushLogin(origin: origin, username: username) }
}

/// App 与通知扩展共用的 App Group（Info.plist 的 `MCAppGroup`，跟着 Bundle ID 前缀走，见 project.yml）。
///
/// 签名里没有这个 App Group 时（未签名的侧载包、没开 App Group 的自签名）退回 App 自己的存储：App 照常
/// 登记推送，只是通知扩展读不到密钥，推送显示中继的通用文案；点开时 App 自己能解开，照样跳转
nonisolated enum PushAppGroup {
    static let identifier: String? = Bundle.main.object(forInfoDictionaryKey: "MCAppGroup") as? String

    /// 签名里有这个 App Group：拿得到共享容器
    static let isAvailable: Bool = identifier.map {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    } ?? false

    /// 登录对照存在这里（UserDefaults 本身线程安全，只是没标 Sendable）
    nonisolated(unsafe) static let defaults: UserDefaults = (isAvailable ? identifier.flatMap { UserDefaults(suiteName: $0) } : nil) ?? .standard

    /// 钥匙串的共享访问组：App Group 本身就能当访问组用（不带团队前缀）
    static var keychainAccessGroup: String? { isAvailable ? identifier : nil }
}

/// `key_id` → 登录信息的对照：存 App Group 的 UserDefaults，通知扩展读。里面没有机密，密钥在钥匙串里
nonisolated final class PushLoginRegistry: @unchecked Sendable {
    static let shared = PushLoginRegistry(defaults: PushAppGroup.defaults)

    private static let key = "movieclaw.push.logins"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 全部对照（`key_id` → 登录）
    var entries: [String: PushLoginInfo] {
        lock.withLock { read() }
    }

    /// 本机登记了推送的登录数：不止一个时通知副标题要标出「服务器 · 账号」
    var count: Int { entries.count }

    func info(forKeyID keyID: String) -> PushLoginInfo? {
        entries[keyID]
    }

    /// 记下（或更新称呼）一个登录的 `key_id`；同一个登录原来的 `key_id` 一并去掉
    func set(_ info: PushLoginInfo, keyID: String) {
        lock.withLock {
            let current = read()
            var next = current.filter { $0.value.login != info.login }
            next[keyID] = info
            if next != current { write(next) }
        }
    }

    func remove(_ login: PushLogin) {
        lock.withLock {
            let current = read()
            let next = current.filter { $0.value.login != login }
            if next.count != current.count { write(next) }
        }
    }

    func removeAll() {
        lock.withLock { defaults.removeObject(forKey: Self.key) }
    }

    private func read() -> [String: PushLoginInfo] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: PushLoginInfo].self, from: data)) ?? [:]
    }

    private func write(_ entries: [String: PushLoginInfo]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// 每个登录一把推送密钥（docs/design/cloud-push.md §9，push-payload.md §1）。
///
/// - 存钥匙串，访问组用 App Group：通知扩展读得到；
/// - `AfterFirstUnlockThisDeviceOnly`（同 TokenVault）：开机解锁过一次后锁屏也能解密，不进 iCloud、
///   不随备份到别的手机；
/// - 退出登录、令牌失效时删掉（TokenVault.delete / clearAll 里一起删）：之后那台服务器推来的内容解不开，
///   只显示通用文案。
///
/// 钥匙串条目按登录存（account 同 TokenVault），内容是 `key_id` 和密钥；`key_id` → 登录的对照在
/// `PushLoginRegistry`。通知扩展按 `key_id` 找到登录，再按登录取密钥。
nonisolated final class PushKeyStore: @unchecked Sendable {
    typealias Key = (keyID: String, key: SymmetricKey)

    static let shared = PushKeyStore()

    let registry: PushLoginRegistry
    private let service: String
    private let accessGroup: String?
    private let lock = NSLock()

    init(service: String = "io.movieclaw.app.push-keys", registry: PushLoginRegistry = .shared,
         accessGroup: String? = PushAppGroup.keychainAccessGroup) {
        self.service = service
        self.registry = registry
        self.accessGroup = accessGroup
    }

    /// 钥匙串里存的一条
    private struct Stored: Codable {
        var keyID: String
        /// 密钥的 base64url
        var key: String
    }

    /// 这个登录的密钥，没有就生成一把（同时记下 `key_id` → 登录，顺带更新称呼）。钥匙串写不进去返回 nil
    func ensureKey(for info: PushLoginInfo) -> Key? {
        lock.withLock {
            if let existing = read(info.login) {
                registry.set(info, keyID: existing.keyID)
                return existing
            }
            let created: Key = (PushCrypto.generateKeyID(), PushCrypto.generateKey())
            guard write(created, for: info.login) else { return nil }
            registry.set(info, keyID: created.keyID)
            return created
        }
    }

    /// 存一把指定的密钥（测试向量、调试用；平时用 `ensureKey`）
    @discardableResult
    func save(_ key: SymmetricKey, keyID: String, for info: PushLoginInfo) -> Bool {
        lock.withLock {
            guard write((keyID, key), for: info.login) else { return false }
            registry.set(info, keyID: keyID)
            return true
        }
    }

    /// 按 `key_id` 找到登录与密钥（通知扩展解密、App 点开通知时用）
    func lookup(keyID: String) -> (info: PushLoginInfo, key: SymmetricKey)? {
        guard let info = registry.info(forKeyID: keyID), let stored = read(info.login), stored.keyID == keyID else { return nil }
        return (info, stored.key)
    }

    func remove(for login: PushLogin) {
        lock.withLock {
            SecItemDelete(baseQuery(login) as CFDictionary)
            registry.remove(login)
        }
    }

    func removeAll() {
        lock.withLock {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
            registry.removeAll()
        }
    }

    private func read(_ login: PushLogin) -> Key? {
        var query = baseQuery(login)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let raw = Base64URL.decode(stored.key), raw.count == 32
        else { return nil }
        return (stored.keyID, SymmetricKey(data: raw))
    }

    private func write(_ entry: Key, for login: PushLogin) -> Bool {
        guard let data = try? JSONEncoder().encode(Stored(keyID: entry.keyID, key: entry.key.base64URL)) else { return false }
        SecItemDelete(baseQuery(login) as CFDictionary)
        var add = baseQuery(login)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let accessGroup {
            add[kSecAttrAccessGroup as String] = accessGroup
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecMissingEntitlement else { return status == errSecSuccess }
            // 签名里其实没有这个访问组：退回 App 自己的钥匙串（扩展读不到，推送显示通用文案）
            add.removeValue(forKey: kSecAttrAccessGroup as String)
        }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// 查询与删除不指定访问组：在这个进程能用的全部访问组里找（包括退回 App 自己钥匙串的那种）
    private func baseQuery(_ login: PushLogin) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: login.account,
        ]
    }
}
