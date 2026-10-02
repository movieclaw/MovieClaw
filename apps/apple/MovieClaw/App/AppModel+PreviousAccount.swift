import Foundation

/// 「双击头像页签切回上一个账号」只有 iPhone 有（Apple TV 用「谁在看」切换），放在 iPhone 界面层。
extension AppModel {
    /// 双击头像页签：切回上一个账号（上一次从它切走的那个，跨服务器也算），在最近用的两个账号之间来回切
    /// ——结果可预期，再双击一次就回来（同 Instagram）。上一个账号已不在本机、或就是当前账号时，改切本机
    /// 另一个还能用的账号。本机只有当前这一个账号时返回 false、什么都不做；登录失效照样抛 `needsPassword`。
    /// 切过去后新主界面会弹「已切换到「某某」」（见 `switchAccount`）。
    func switchToPreviousAccount() async throws -> Bool {
        let others = savedServers.flatMap { saved in
            saved.accounts.map { SavedAccount(server: saved.address, account: $0) }
        }.filter { !($0.server == server && $0.account.username == session?.username) }
        let previous = Self.previousAccount
        guard let target = others.first(where: {
            $0.server.origin == previous?.origin && $0.account.username == previous?.username
        }) ?? others.first(where: { hasToken(for: $0.account.username, on: $0.server) }) ?? others.first
        else { return false }
        try await switchAccount(to: target.account.username, on: target.server, landingOn: .more)
        return true
    }
}
