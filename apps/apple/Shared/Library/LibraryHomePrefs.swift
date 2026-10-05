import Foundation
import Observation

/// 首页行清单偏好的进程内共享副本。
///
/// Web 把全站界面偏好放在一个 React Context 里（按当前会话加载）；App 里只有媒体库首页、
/// 自定义页与合集页用到 `home.rows`，放一个模块级单例即可：自定义页保存后直接写回这里，
/// 返回首页时立刻按新清单渲染，不必等下一轮轮询。
///
/// 单例跨账号存活，所以副本记着属于谁（服务器地址 + 用户名，同 SubscriptionIndex）：
/// 切换账号后第一次使用就作废旧副本重新拉。否则新账号首页沿用旧布局，更糟的是在新账号的合集页点
/// 「显示在首页」会以旧账号的行清单为底整份保存，覆盖新账号的偏好（第二轮审计 N-04a-1）。
@Observable
final class LibraryHomePrefs {
    static let shared = LibraryHomePrefs()
    /// nil = 还没从服务器拉到
    var rows: [API.HomeRowPref]?
    /// 副本所属账号（`ownerKey`）
    @ObservationIgnored private(set) var owner: String?

    static func ownerKey(api: APIClient, username: String?) -> String {
        "\(api.server.apiBase.absoluteString)|\(username ?? "")"
    }

    /// 以这个账号的身份使用副本：换了账号就清空旧账号的行清单
    func adopt(owner key: String) {
        guard key != owner else { return }
        owner = key
        rows = nil
    }

    /// 接收一次拉取结果：拉取期间换了账号（或已有更新的副本）就丢弃，不串到别的账号上
    func accept(_ fetched: [API.HomeRowPref]?, for key: String) {
        guard key == owner, rows == nil else { return }
        rows = fetched
    }

    /// 确保副本属于这个账号且已拉到（失败保持 nil，下次再拉）
    func ensureLoaded(api: APIClient, owner key: String) async {
        adopt(owner: key)
        guard rows == nil else { return }
        accept((try? await api.uiPrefsShow())?.home.rows, for: key)
    }

    /// 保存首页行清单。后端 PUT `/ui/preferences` 是整体覆盖，所以以当前完整偏好为底只换 home.rows；
    /// 成功后写回共享副本（自定义页、合集页「显示在首页」共用）。
    func save(_ rows: [API.HomeRowPrefInput], api: APIClient) async throws {
        let base = try await api.uiPrefsShow()
        var input = try JSONDecoder().decode(API.UiPreferencesSettingInput.self, from: JSONEncoder().encode(base))
        input.home = API.HomeUiPrefsInput(rows: rows)
        let saved = try await api.uiPrefsUpdate(body: input)
        self.rows = saved.home.rows
    }
}
