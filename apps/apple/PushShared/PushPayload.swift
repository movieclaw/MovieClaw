import Foundation

/// 推送明文（docs/design/push-payload.md §3）：UTF-8 JSON。
///
/// 不认识的字段忽略；某个字段类型对不上（更高版本改了结构）时只丢掉那一个字段，不让整条通知退回通用文案
nonisolated struct PushPlaintext: Decodable, Equatable, Sendable {
    /// 来自哪台实例 / 推给哪个账号
    struct Party: Decodable, Equatable, Sendable {
        var id: String?
        var name: String?
    }

    /// 长按通知时的一个快捷操作（`id`：play 播放 / open 打开页面 / mute 这部剧不再提醒）
    struct Action: Decodable, Equatable, Sendable {
        var id: String
        var title: String
        /// play、open：点了打开的站内路径
        var open: String?
        /// mute：静音的条目
        var item: Int?
    }

    /// 长按通知时的集数格子：一季每集一个字符（`s` 看过、`d` 已入库、`w` 下载中、`m` 没找到、`-` 其他），第 1 集起
    struct Grid: Decodable, Equatable, Sendable {
        var season: Int
        var cells: String
    }

    /// 这个版本的 App 认识的明文结构版本
    static let supportedVersion = 1

    var version: Int?
    var type: String?
    var sentAt: Int?
    var server: Party?
    var account: Party?
    var title: String?
    var body: String?
    var subtitle: String?
    var image: String?
    var open: String?
    var thread: String?
    var category: String?
    var sound: String?
    /// 要不要在手机上标出来源：没有 = 不标（内容类，点开会自动切账号）；`server` = 标服务器名；`account` = 标账号名
    var source: String?
    var actions: [Action]?
    var grid: Grid?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case sentAt = "sent_at"
        case server, account, title, body, subtitle, image, open, thread, category, sound, source, actions, grid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func lenient<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        version = lenient(.version)
        type = lenient(.type)
        sentAt = lenient(.sentAt)
        server = lenient(.server)
        account = lenient(.account)
        title = lenient(.title)
        body = lenient(.body)
        subtitle = lenient(.subtitle)
        image = lenient(.image)
        open = lenient(.open)
        thread = lenient(.thread)
        category = lenient(.category)
        sound = lenient(.sound)
        source = lenient(.source)
        actions = lenient(.actions)
        grid = lenient(.grid)
    }

    /// 比这个版本的 App 新的结构：只尽力显示标题和正文
    var isNewer: Bool { (version ?? Self.supportedVersion) > Self.supportedVersion }
}

/// 推送 `userInfo` 里的键
nonisolated enum PushUserInfoKey {
    /// 实例加密的密文（中继原样放在推送的顶层）。推送里别的键都是中继能随便填的，一律不信
    static let ciphertext = "e"
}

/// 解开的一条提醒推送
nonisolated struct DecryptedPush: Sendable {
    var keyID: String
    var login: PushLoginInfo
    var plaintext: PushPlaintext

    /// 解开 `userInfo["e"]`。本机没有这把密钥（已退出那个账号）、认证失败、格式不对、不是提醒推送都返回 nil：
    /// 通知保留中继填的通用文案
    init?(userInfo: [AnyHashable: Any], store: PushKeyStore) {
        guard let payload = userInfo[PushUserInfoKey.ciphertext] as? String,
              let envelope = try? PushCrypto.parse(payload),
              let found = store.lookup(keyID: envelope.keyID),
              let data = try? PushCrypto.open(envelope, key: found.key),
              let plaintext = try? JSONDecoder().decode(PushPlaintext.self, from: data),
              plaintext.type == "alert"
        else { return nil }
        keyID = envelope.keyID
        login = found.info
        self.plaintext = plaintext
    }
}

/// 解开的提醒推送最终怎么显示（通知扩展照着改通知内容）
nonisolated struct PushAlertPresentation: Equatable, Sendable {
    var title: String?
    var subtitle: String?
    var body: String?
    var thread: String?
    var category: String?
    var sound: String?
    /// 配图：服务器地址 + 实例给的带签名的相对路径，不用登录就能下载
    var imageURL: URL?
    /// 点开后打开的站内路径
    var openPath: String?

    /// - Parameter logins: 本机登记了推送的全部登录（`PushLoginRegistry`）。按明文的 `source` 决定副标题要不要标来源
    ///   （docs/design/push-payload.md §3.1）：`server` 时本机连了不止一台服务器才标服务器名，`account` 时同一台服务器上
    ///   登了不止一个账号才标账号名，没有（内容类通知）就不标。原来有副标题就接在后面
    init(_ push: DecryptedPush, logins: [PushLoginInfo]) {
        let plaintext = push.plaintext
        title = plaintext.title.nonEmpty
        body = plaintext.body.nonEmpty
        let source = Self.sourceLabel(push, logins: logins)
        // 分组按服务器分开：两台服务器各自的「入库」不混在一组
        let server = push.login.origin
        guard !plaintext.isNewer else {
            subtitle = source
            thread = server
            return
        }
        subtitle = [plaintext.subtitle.nonEmpty, source].compactMap { $0 }.joined(separator: " · ").nonEmpty
        thread = plaintext.thread.nonEmpty.map { "\(server):\($0)" } ?? server
        category = plaintext.category.nonEmpty
        sound = plaintext.sound.nonEmpty
        imageURL = PushTapTarget.sitePath(plaintext.image).flatMap { URL(string: push.login.origin + $0) }
        openPath = PushTapTarget.sitePath(plaintext.open)
    }

    static func sourceLabel(_ push: DecryptedPush, logins: [PushLoginInfo]) -> String? {
        switch push.plaintext.source {
        case "server":
            guard Set(logins.map(\.origin)).count > 1 else { return nil }
            return push.plaintext.server?.name.nonEmpty ?? push.login.serverName
        case "account":
            guard Set(logins.filter { $0.origin == push.login.origin }.map(\.login)).count > 1 else { return nil }
            return push.plaintext.account?.name.nonEmpty ?? push.login.accountName
        default:
            return nil
        }
    }
}

/// 点开一条通知：来自本机哪个登录、要打开哪个站内路径
nonisolated struct PushTapTarget: Equatable, Sendable {
    var login: PushLoginInfo
    /// 站内路径（`/subscriptions/42`）；没有时只切到那个账号
    var openPath: String?

    init(login: PushLoginInfo, openPath: String?) {
        self.login = login
        self.openPath = openPath
    }

    /// 点开时在 App 里重新解一次密文，从明文里取是哪个登录、打开哪个页面：推送里密文以外的键都是中继
    /// 能随便填的（中继不可信，见 push-payload.md §1），拿它们来切账号、跳页面，等于让中继替用户点链接。
    /// 认不出是哪个登录（已退出、解不开、通用文案的推送）返回 nil
    init?(userInfo: [AnyHashable: Any], store: PushKeyStore) {
        guard let push = DecryptedPush(userInfo: userInfo, store: store) else { return nil }
        self.init(login: push.login, openPath: push.plaintext.isNewer ? nil : Self.sitePath(push.plaintext.open))
    }

    /// 点了长按菜单里的快捷操作（play、open）：同样在 App 里重新解密，按明文里这个操作的 `open` 打开
    init?(userInfo: [AnyHashable: Any], store: PushKeyStore, action: String) {
        guard let push = DecryptedPush(userInfo: userInfo, store: store), !push.plaintext.isNewer,
              let found = push.plaintext.actions?.first(where: { $0.id == action }),
              let path = Self.sitePath(found.open)
        else { return nil }
        self.init(login: push.login, openPath: path)
    }

    /// 只认站内路径（`/` 开头）：外部地址、`//主机` 形式、自定义协议一律不认
    static func sitePath(_ raw: String?) -> String? {
        guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\")
        else { return nil }
        return path
    }
}

private nonisolated extension Optional where Wrapped == String {
    /// 空串当没有
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private nonisolated extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
