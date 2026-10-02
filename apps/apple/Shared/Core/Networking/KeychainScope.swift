import Foundation
import Security

/// 钥匙串条目存在哪一份：Apple TV 上存「全家共用」的那份（docs/design/tvos-app.md §5.2）。
///
/// Apple TV App 声明了「以当前用户运行」的用户管理权限（`com.apple.developer.user-management` =
/// `runs-as-current-user-with-user-independent-keychain`）：`UserDefaults` 与默认钥匙串都按 Apple TV 的系统用户分开，
/// 每位家庭成员记得自己上次选的是哪个账号。但设备令牌、本机登录过的账号列表、安装标识要全家共用——
/// 一个人在这台电视上登录一次，全家「谁在看」里都能看到、点一下就进，所以这些条目显式存进「不分用户」的那份
/// （`kSecUseUserIndependentKeychain`）。
///
/// 没有这项权限时（模拟器、未签名的构建）系统会以「缺少权限」拒绝这个属性：退回普通钥匙串，功能照常，
/// 只是令牌按系统用户分开。iPhone 上没有系统用户之分，什么也不加。
nonisolated enum KeychainScope {
    /// 给一条钥匙串查询补上「不分用户」的属性（可用时）
    static func shared(_ query: [String: Any]) -> [String: Any] {
        #if os(tvOS)
        guard userIndependentAvailable else { return query }
        var scoped = query
        scoped[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue
        return scoped
        #else
        return query
        #endif
    }

    #if os(tvOS)
    /// 进程里只探一次：用这个属性查一条不存在的条目，有权限返回「找不到」，没有权限返回「缺少权限」
    private static let userIndependentAvailable: Bool = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.movieclaw.app.keychain-probe",
            kSecUseUserIndependentKeychain as String: kCFBooleanTrue as Any,
        ]
        return SecItemCopyMatching(probe as CFDictionary, nil) != errSecMissingEntitlement
    }()
    #endif
}

/// 存在钥匙串里的一小块数据（Apple TV 上全家共用，见 `KeychainScope`）：账号列表这类要跨系统用户共享、
/// 又不是机密的数据。iPhone 上仍用 `UserDefaults`，不走这里
nonisolated enum KeychainBlob {
    static func read(service: String) -> Data? {
        var query = KeychainScope.shared(base(service))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, service: String) {
        let query = KeychainScope.shared(base(service))
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func remove(service: String) {
        SecItemDelete(KeychainScope.shared(base(service)) as CFDictionary)
    }

    private static func base(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "blob"]
    }
}
