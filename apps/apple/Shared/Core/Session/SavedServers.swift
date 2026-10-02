import Foundation

/// 本机登录过的一台服务器，以及它上面已登录账号的本地快照。
///
/// 登录态是每个账号一枚设备令牌（钥匙串 `TokenVault`，docs/design/login-devices.md），这里只记展示用的东西：
/// - 有哪些服务器（地址 + 最近使用时间）；
/// - 每台上有哪些账号（昵称、头像、角色，`active` 标出这台上的当前账号）：服务器连不上、令牌失效时，
///   切换账号列表和欢迎页「选择账号」照样要能把人列出来。快照在登录、切换、刷新时更新；
///   真正能不能切，以那枚令牌向服务器问 `/auth/me` 的结果为准。
///
/// 头像地址带 `mc_account` 标记（`AvatarURL.tagged`）：切换账号列表里同一台服务器上的几个账号
/// 各用各的令牌取自己的头像。
nonisolated struct SavedServer: Codable, Hashable, Sendable, Identifiable {
    var address: ServerAddress
    var accounts: [API.AccountView]
    var lastUsed: Date

    var id: URL { address.origin }

    /// 快照里标为「当前」的账号：冷启动发现会话过期时，据此预填用户名
    var activeAccount: API.AccountView? { accounts.first(where: \.active) ?? accounts.first }
}

/// 服务器记录的读写与增删（纯函数部分有单元测试）
nonisolated enum SavedServers {
    private static let key = "movieclaw.savedServers"

    static func load() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedServer].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [SavedServer]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// 记一次使用：这台服务器置顶；给了账号列表就一并覆盖快照（`nil` 表示只更新时间）
    static func touching(_ list: [SavedServer], _ address: ServerAddress, accounts: [API.AccountView]?, at date: Date = .now) -> [SavedServer] {
        var result = list
        if let index = result.firstIndex(where: { $0.address == address }) {
            result[index].lastUsed = date
            if let accounts { result[index].accounts = accounts }
        } else {
            result.append(SavedServer(address: address, accounts: accounts ?? [], lastUsed: date))
        }
        return result.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// 只覆盖某台服务器的账号快照，不动排序（后台刷新别的服务器时用）
    static func replacingAccounts(_ list: [SavedServer], _ address: ServerAddress, with accounts: [API.AccountView]) -> [SavedServer] {
        list.map { $0.address == address ? SavedServer(address: $0.address, accounts: accounts, lastUsed: $0.lastUsed) : $0 }
    }

    /// 登录 / 切换 / 刷新后写入一个账号的快照：同名的替换；`active` 为真时它成为这台服务器的当前账号
    /// （排到最前、其余账号取消「当前」）
    static func upserting(_ list: [SavedServer], _ address: ServerAddress, account: API.AccountView) -> [SavedServer] {
        let base = list.contains(where: { $0.address == address }) ? list : touching(list, address, accounts: nil)
        return base.map { saved in
            guard saved.address == address else { return saved }
            var copy = saved
            var others = copy.accounts.filter { $0.username.lowercased() != account.username.lowercased() }
            if account.active {
                others = others.map { API.AccountView(username: $0.username, nickname: $0.nickname, avatarUrl: $0.avatarUrl, role: $0.role, active: false) }
                copy.accounts = [account] + others
            } else if let index = copy.accounts.firstIndex(where: { $0.username.lowercased() == account.username.lowercased() }) {
                copy.accounts[index] = account
            } else {
                copy.accounts = others + [account]
            }
            return copy
        }
    }

    /// 会话视图 → 本机快照（头像地址带上这个账号的标记，见 `AvatarURL`）
    static func snapshot(of session: API.SessionView, active: Bool) -> API.AccountView {
        API.AccountView(
            username: session.username,
            nickname: session.nickname,
            avatarUrl: AvatarURL.tagged(session.avatarUrl, username: session.username),
            role: session.role,
            active: active
        )
    }

    /// 从某台服务器的快照里去掉一个账号
    static func removingAccount(_ list: [SavedServer], _ username: String, from address: ServerAddress) -> [SavedServer] {
        list.map { saved in
            guard saved.address == address else { return saved }
            var copy = saved
            copy.accounts.removeAll { $0.username == username }
            return copy
        }
    }

    /// 没有账号、也不是当前服务器的记录不再保留：它既不会出现在账号列表里，也没有令牌需要恢复
    static func pruned(_ list: [SavedServer], keeping current: ServerAddress?) -> [SavedServer] {
        list.filter { !$0.accounts.isEmpty || $0.address == current }
    }
}

/// 某台服务器上的一个已登录账号：跨服务器的账号列表（欢迎页「选择账号」）用
nonisolated struct SavedAccount: Identifiable, Hashable, Sendable {
    let server: ServerAddress
    let account: API.AccountView

    var id: String { "\(server.origin.absoluteString)#\(account.username)" }
}

/// 各账号上次的会话快照（`/auth/me` 的结果：昵称、角色、能力开关），冷启动秒开用。
///
/// 本机有当前账号的令牌、也有它上次的会话快照时，冷启动直接用快照进主界面，身份在后台校验
/// （`AppModel.revalidate`）：不必先等「测服务器 + 问身份」两个来回才出界面。校验得到 401 照常回登录页。
/// 退出、移除账号时一并删除。
nonisolated enum SessionCache {
    private static let key = "movieclaw.sessionCache"

    private static func entry(_ server: ServerAddress, _ username: String) -> String {
        "\(server.origin.absoluteString)#\(username.lowercased())"
    }

    static func load(server: ServerAddress, username: String) -> API.SessionView? {
        guard let data = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[entry(server, username)] else { return nil }
        return try? JSONDecoder().decode(API.SessionView.self, from: data)
    }

    static func save(_ session: API.SessionView, server: ServerAddress) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
        all[entry(server, session.username)] = data
        UserDefaults.standard.set(all, forKey: key)
    }

    static func remove(server: ServerAddress, username: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data]) ?? [:]
        all[entry(server, username)] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
