import CryptoKit
import Foundation
import Security
import Testing
@testable import MovieClaw

/// App 推送（docs/design/cloud-push.md §9，push-payload.md）：密文格式、密钥与登录对照、明文解析、点开通知
struct PushCryptoTests {
    /// push-payload.md §7 的测试向量：实例（Python cryptography）与 App（CryptoKit）逐字节一致
    static let vectorKey = SymmetricKey(data: Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
    static let vectorKeyID = "k7Qm2xP9Hn4"
    static let vectorNonce = Data(hex: "000102030405060708090a0b")
    static let vectorPlaintext = #"{"v":1,"type":"alert","title":"流浪地球 2 已入库","body":"4K · HDR · 已添加到「电影」","image":"/api/push/images/abc123","open":"movieclaw://library/items/123","thread":"library","category":"library.added","sound":"default","server":{"id":"s1","name":"客厅 NAS"},"account":{"id":"u7","name":"爸爸"},"sent_at":1767225600}"#
    static let vectorPayload = "v1.k7Qm2xP9Hn4.AAECAwQFBgcICQoL.PCCgOf_U7jn5OOfuk9NaDO-z9UDSV30IUROJ4D9TIlS0kUhJBSSOKJM0_M26p82PXLzlKL9sMPgTtUh2fJrX1NIIjVoRZgYpWAaKrFiv61-KbH7Zk-nzjXVNfUz0Fy04LkXoBSTM6ja8dVPTLxADRZhIA9uK6lXvPpd4pO-HCWvIfWGk1-b5YCrNas5NvyLgDNaOWkN49ingPp9N1f2Fh_Hl_2eQ0KUKwg6u1e6ytZmx7L5K-c4S2Efl4qsYp8WSYTWo1i--t71SMbyUw2Pjpo0XmgRccsPfEPX-oiVqo9gwTKHBggI5BzYi3mnAfQhzhLHKEO9G7Nc1URxR4vhguzaiw7Kx-CZfGrpQPZXIlKg_Ok_tzsrSjQwDTzBpl9U-b3f8csHnp3OwBhgvPbeM8farNjtrru3wEIn6ni8fOMXr5hpE_z8ZnYHaShdr5C9QpizntOFhYLyzgC4ieMqlItk-6ARo"

    @Test func vectorPlaintextIs341Bytes() {
        #expect(Data(Self.vectorPlaintext.utf8).count == 341)
    }

    @Test func decryptsTestVector() throws {
        let plaintext = try PushCrypto.open(Self.vectorPayload, key: Self.vectorKey)
        #expect(plaintext == Data(Self.vectorPlaintext.utf8), "解密还原的明文逐字节一致")
    }

    @Test func sealsTestVectorByteForByte() throws {
        let nonce = try AES.GCM.Nonce(data: Self.vectorNonce)
        let payload = try PushCrypto.seal(Data(Self.vectorPlaintext.utf8), key: Self.vectorKey, keyID: Self.vectorKeyID, nonce: nonce)
        #expect(payload == Self.vectorPayload, "加密结果与实例逐字节一致")
    }

    @Test func roundTripsWithRandomNonce() throws {
        let key = PushCrypto.generateKey()
        let keyID = PushCrypto.generateKeyID()
        let first = try PushCrypto.seal(Data("hello".utf8), key: key, keyID: keyID)
        let second = try PushCrypto.seal(Data("hello".utf8), key: key, keyID: keyID)
        #expect(first != second, "每条推送的 nonce 都是新的")
        #expect(try PushCrypto.open(first, key: key) == Data("hello".utf8))
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }, "整串只有 base64url 字符和点")
    }

    /// AAD 是 `v1.<key_id>`：把密文挪到别的 key_id 下解不开
    @Test func ciphertextIsBoundToKeyID() {
        let moved = Self.vectorPayload.replacingOccurrences(of: "v1.k7Qm2xP9Hn4.", with: "v1.AAAAAAAAAAA.")
        #expect(throws: PushCrypto.Failure.authentication) { try PushCrypto.open(moved, key: Self.vectorKey) }
    }

    @Test func rejectsWrongKeyAndTampering() {
        #expect(throws: PushCrypto.Failure.authentication) { try PushCrypto.open(Self.vectorPayload, key: PushCrypto.generateKey()) }
        var tampered = Array(Self.vectorPayload)
        tampered[tampered.count - 5] = tampered[tampered.count - 5] == "A" ? "B" : "A"
        #expect(throws: PushCrypto.Failure.authentication) { try PushCrypto.open(String(tampered), key: Self.vectorKey) }
    }

    @Test func rejectsMalformedPayloads() {
        let malformed = [
            "",
            "v1.k7Qm2xP9Hn4.AAECAwQFBgcICQoL",
            "v2.k7Qm2xP9Hn4.AAECAwQFBgcICQoL.PCCgOf_U7jn5OOfuk9NaDO-z9UDSV30IUROJ4D9TIlS0kU",
            "v1..AAECAwQFBgcICQoL.PCCgOf_U7jn5OOfuk9NaDO-z9UDSV30IUROJ4D9TIlS0kU",
            "v1.k7Qm2xP9Hn4.AAECAwQF.PCCgOf_U7jn5OOfuk9NaDO-z9UDSV30IUROJ4D9TIlS0kU",
            "v1.k7Qm2xP9Hn4.AAECAwQFBgcICQoL.PCCg",
            "v1.k7Qm2xP9Hn4.AAECAwQFBgcICQoL.PCCg+f/U7jn5OOfuk9NaDO==",
            "v1.k7Qm2xP9Hn4.AAECAwQFBgcICQoL.PCCgOf_U7jn5OOfuk9NaDO-z9UDSV30IUROJ4D9TIlS0kU.extra",
        ]
        for payload in malformed {
            #expect(throws: PushCrypto.Failure.malformed, "\(payload)") { try PushCrypto.parse(payload) }
        }
    }

    /// key_id：8 字节随机数的 base64url，11 个字符；密钥 32 字节，登记时交 43 个字符的 base64url
    @Test func keyAndKeyIDFormat() {
        let ids = (0 ..< 50).map { _ in PushCrypto.generateKeyID() }
        for id in ids {
            #expect(id.count == 11)
            #expect(Base64URL.decode(id)?.count == 8)
            #expect(id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) })
        }
        #expect(Set(ids).count == ids.count, "随机，不重复")

        let key = PushCrypto.generateKey()
        #expect(key.bitCount == 256)
        #expect(key.base64URL.count == 43)
        #expect(Base64URL.decode(key.base64URL) == key.withUnsafeBytes { Data($0) })
        #expect(Self.vectorKey.base64URL == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "同 cloud-push.md §7.3 登记请求的示例")
    }

    @Test func base64URLRejectsStandardAlphabet() {
        #expect(Base64URL.decode("ab+c") == nil)
        #expect(Base64URL.decode("ab/c") == nil)
        #expect(Base64URL.decode("abc=") == nil)
        #expect(Base64URL.decode("a") == nil)
        #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
    }
}

/// 测试用的隔离存储：独立的 UserDefaults 与钥匙串 service，不碰 App 自己的数据
private struct IsolatedStore {
    let defaults: UserDefaults
    let store: PushKeyStore
    let service = "io.movieclaw.tests.push-keys.\(UUID().uuidString)"
    private let suite = "movieclaw.tests.push.\(UUID().uuidString)"

    init(accessGroup: String? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        store = PushKeyStore(service: service, registry: PushLoginRegistry(defaults: defaults), accessGroup: accessGroup)
    }

    func tearDown() {
        store.removeAll()
        defaults.removePersistentDomain(forName: suite)
    }
}

struct PushKeyStoreTests {
    private let nas = PushLoginInfo(origin: "http://192.168.1.10:3000", username: "Dad", serverName: "192.168.1.10:3000", accountName: "爸爸")
    private let office = PushLoginInfo(origin: "https://movie.example.com", username: "dad", serverName: "movie.example.com", accountName: "爸爸")

    @Test func registryRoundTrip() {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        let registry = PushLoginRegistry(defaults: isolated.defaults)
        registry.set(nas, keyID: "AAAAAAAAAAA")
        registry.set(office, keyID: "BBBBBBBBBBB")
        #expect(registry.count == 2)
        #expect(registry.info(forKeyID: "AAAAAAAAAAA") == nas)

        // 另一个进程（通知扩展）读同一份存储
        let reader = PushLoginRegistry(defaults: isolated.defaults)
        #expect(reader.info(forKeyID: "BBBBBBBBBBB") == office)

        // 同一个登录换了 key_id：旧的去掉；改了称呼：跟着更新
        var renamed = nas
        renamed.accountName = "老爸"
        registry.set(renamed, keyID: "CCCCCCCCCCC")
        #expect(registry.info(forKeyID: "AAAAAAAAAAA") == nil)
        #expect(registry.info(forKeyID: "CCCCCCCCCCC")?.accountName == "老爸")
        #expect(registry.count == 2)

        // 用户名不分大小写（同 TokenVault）
        registry.remove(PushLogin(origin: "http://192.168.1.10:3000", username: "DAD"))
        #expect(registry.count == 1)
        registry.removeAll()
        #expect(registry.count == 0)
    }

    @Test func ensureKeyIsStablePerLogin() throws {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        let store = isolated.store
        let first = try #require(store.ensureKey(for: nas))
        let again = try #require(store.ensureKey(for: nas))
        #expect(first.keyID == again.keyID)
        #expect(first.key == again.key)
        let other = try #require(store.ensureKey(for: office))
        #expect(other.keyID != first.keyID, "每个登录一把自己的密钥")

        let found = try #require(store.lookup(keyID: first.keyID))
        #expect(found.info == nas)
        #expect(found.key == first.key)
        #expect(store.lookup(keyID: "unknownkey1") == nil)
    }

    /// 退出登录、令牌失效时删掉：之后按 key_id 找不到，再登记会换一把新的
    @Test func removeDeletesKeyAndRegistry() throws {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        let store = isolated.store
        let key = try #require(store.ensureKey(for: nas))
        _ = try #require(store.ensureKey(for: office))
        store.remove(for: PushLogin(origin: nas.origin, username: "DAD"))
        #expect(store.lookup(keyID: key.keyID) == nil)
        #expect(store.registry.count == 1)
        let fresh = try #require(store.ensureKey(for: nas))
        #expect(fresh.keyID != key.keyID)

        store.removeAll()
        #expect(store.registry.count == 0)
        #expect(store.lookup(keyID: fresh.keyID) == nil)
    }

    /// 签名里有 App Group 时，密钥写进 App Group 的访问组：通知扩展读得到
    @Test func keysLandInSharedAccessGroup() throws {
        let group = try #require(PushAppGroup.keychainAccessGroup, "模拟器构建带 App Group 权限")
        let isolated = IsolatedStore(accessGroup: group)
        defer { isolated.tearDown() }
        let key = try #require(isolated.store.ensureKey(for: nas))
        #expect(isolated.store.lookup(keyID: key.keyID)?.key == key.key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: isolated.service,
            kSecAttrAccount as String: nas.login.account,
            kSecAttrAccessGroup as String: group,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = result as? [[String: Any]] ?? []
        #expect(items.contains { ($0[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) })
    }
}

struct PushPayloadTests {
    private let nas = PushLoginInfo(origin: "http://192.168.1.10:3000", username: "dad", serverName: "192.168.1.10:3000", accountName: "爸爸")

    private func decode(_ json: String) throws -> PushPlaintext {
        try JSONDecoder().decode(PushPlaintext.self, from: Data(json.utf8))
    }

    @Test func parsesTestVectorPlaintext() throws {
        let plaintext = try decode(PushCryptoTests.vectorPlaintext)
        #expect(plaintext.version == 1)
        #expect(plaintext.type == "alert")
        #expect(plaintext.title == "流浪地球 2 已入库")
        #expect(plaintext.body == "4K · HDR · 已添加到「电影」")
        #expect(plaintext.server?.name == "客厅 NAS")
        #expect(plaintext.account?.name == "爸爸")
        #expect(plaintext.sentAt == 1_767_225_600)
        #expect(!plaintext.isNewer)
    }

    /// 不认识的字段忽略；某个字段类型变了只丢那一个，标题正文照样在
    @Test func ignoresUnknownAndMistypedFields() throws {
        let plaintext = try decode(#"{"v":1,"type":"alert","title":"T","body":"B","badge":3,"actions":[{"id":"x"}],"open":{"path":"/x"},"server":"s1"}"#)
        #expect(plaintext.title == "T")
        #expect(plaintext.body == "B")
        #expect(plaintext.open == nil)
        #expect(plaintext.server == nil)
    }

    /// 用实例的方式加密一段明文，再像通知扩展那样从 userInfo 解开
    private func push(_ json: String) throws -> DecryptedPush? {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        isolated.store.save(PushCryptoTests.vectorKey, keyID: PushCryptoTests.vectorKeyID, for: nas)
        let payload = try PushCrypto.seal(Data(json.utf8), key: PushCryptoTests.vectorKey, keyID: PushCryptoTests.vectorKeyID)
        return DecryptedPush(userInfo: ["aps": ["mutable-content": 1], "e": payload], store: isolated.store)
    }

    @Test func decryptsUserInfoWithStoredKey() throws {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        #expect(DecryptedPush(userInfo: ["e": PushCryptoTests.vectorPayload], store: isolated.store) == nil, "本机没有这把密钥：保留通用文案")
        isolated.store.save(PushCryptoTests.vectorKey, keyID: PushCryptoTests.vectorKeyID, for: nas)
        let push = try #require(DecryptedPush(userInfo: ["e": PushCryptoTests.vectorPayload], store: isolated.store))
        #expect(push.keyID == PushCryptoTests.vectorKeyID)
        #expect(push.login == nas)
        #expect(push.plaintext.title == "流浪地球 2 已入库")
        #expect(DecryptedPush(userInfo: [:], store: isolated.store) == nil)
        #expect(DecryptedPush(userInfo: ["e": 42], store: isolated.store) == nil)
    }

    /// 明文的 type 要和推送类型一致：别的类型的密文挪进提醒推送里不显示
    @Test func requiresAlertType() throws {
        #expect(try push(#"{"v":1,"type":"background","refresh":["badge"]}"#) == nil)
        #expect(try push(#"{"v":1,"title":"no type"}"#) == nil)
        #expect(try push("not json") == nil)
        #expect(try push(#"{"v":1,"type":"alert","title":"ok"}"#) != nil)
    }

    // 本机登记了推送的登录（key_id 对照里的）：nas 上爸爸，另一台服务器、同一台服务器上的另一个账号
    private var nasMom: PushLoginInfo {
        PushLoginInfo(origin: nas.origin, username: "mom", serverName: nas.serverName, accountName: "妈妈")
    }
    private let office = PushLoginInfo(origin: "https://movie.example.com", username: "dad", serverName: "movie.example.com", accountName: "爸爸")

    private func alert(_ extra: String = "") -> String {
        #"{"v":1,"type":"alert","title":"T","body":"B","server":{"id":"s1","name":"客厅 NAS"},"account":{"id":"u7","name":"爸爸"}"# + extra + "}"
    }

    @Test func presentationOfTestVector() throws {
        let presentation = PushAlertPresentation(try #require(try push(PushCryptoTests.vectorPlaintext)), logins: [nas, office, nasMom])
        #expect(presentation.title == "流浪地球 2 已入库")
        #expect(presentation.body == "4K · HDR · 已添加到「电影」")
        #expect(presentation.subtitle == nil, "没有 source（内容类）：多台服务器、多个账号也不标来源")
        #expect(presentation.thread == "http://192.168.1.10:3000:library", "分组按服务器分开")
        #expect(presentation.category == "library.added")
        #expect(presentation.sound == "default")
        #expect(presentation.imageURL == URL(string: "http://192.168.1.10:3000/api/push/images/abc123"), "配图 = 服务器地址 + 带签名的路径")
        #expect(presentation.openPath == nil, "open 不是站内路径（movieclaw://）不跳")
    }

    /// source = server（管理员告警）：本机连了不止一台服务器才标服务器名
    @Test func serverSourceNeedsSeveralServers() throws {
        let decrypted = try #require(try push(alert(#","source":"server","subtitle":"下载器""#)))
        #expect(PushAlertPresentation(decrypted, logins: [nas]).subtitle == "下载器")
        #expect(PushAlertPresentation(decrypted, logins: [nas, nasMom]).subtitle == "下载器", "同一台服务器上的两个账号不算两台")
        #expect(PushAlertPresentation(decrypted, logins: [nas, office]).subtitle == "下载器 · 客厅 NAS")
        let unnamed = try #require(try push(#"{"v":1,"type":"alert","title":"T","body":"B","source":"server"}"#))
        #expect(PushAlertPresentation(unnamed, logins: [nas, office]).subtitle == "192.168.1.10:3000", "明文没带服务器名时用本机记的")
    }

    /// source = account（新设备登录）：同一台服务器上登了不止一个账号才标账号名；别的服务器上的账号不算
    @Test func accountSourceNeedsSeveralAccountsOnThatServer() throws {
        let decrypted = try #require(try push(alert(#","source":"account""#)))
        #expect(PushAlertPresentation(decrypted, logins: [nas]).subtitle == nil)
        #expect(PushAlertPresentation(decrypted, logins: [nas, office]).subtitle == nil)
        #expect(PushAlertPresentation(decrypted, logins: [nas, nasMom]).subtitle == "爸爸")
        let unnamed = try #require(try push(#"{"v":1,"type":"alert","title":"T","body":"B","source":"account"}"#))
        #expect(PushAlertPresentation(unnamed, logins: [nas, nasMom]).subtitle == "爸爸", "明文没带账号名时用本机记的昵称")
    }

    /// 没有 source、或不认识的 source：不标
    @Test func absentOrUnknownSourceAddsNothing() throws {
        for extra in ["", #","source":"device""#, #","source":3"#] {
            let decrypted = try #require(try push(alert(extra)))
            #expect(PushAlertPresentation(decrypted, logins: [nas, office, nasMom]).subtitle == nil, "\(extra)")
        }
        let withSubtitle = try #require(try push(alert(#","subtitle":"第 7 集""#)))
        #expect(PushAlertPresentation(withSubtitle, logins: [nas, office]).subtitle == "第 7 集")
    }

    /// 分组：「服务器:thread」，没有 thread 时只按服务器
    @Test func threadIsScopedPerServer() throws {
        let threaded = try #require(try push(alert(#","thread":"system""#)))
        #expect(PushAlertPresentation(threaded, logins: [nas]).thread == "http://192.168.1.10:3000:system")
        let bare = try #require(try push(alert()))
        #expect(PushAlertPresentation(bare, logins: [nas]).thread == "http://192.168.1.10:3000")
    }

    /// 更高版本的明文：只尽力显示标题和正文（来源、分组照样按规则来）
    @Test func newerVersionShowsOnlyTitleAndBody() throws {
        let decrypted = try #require(try push(#"{"v":2,"type":"alert","title":"T","body":"B","subtitle":"S","image":"/img","open":"/subscriptions/1","thread":"x","sound":"chime","source":"server","new_field":{"a":1}}"#))
        let presentation = PushAlertPresentation(decrypted, logins: [nas])
        #expect(presentation.title == "T")
        #expect(presentation.body == "B")
        #expect(presentation.subtitle == nil && presentation.sound == nil)
        #expect(presentation.thread == "http://192.168.1.10:3000")
        #expect(presentation.imageURL == nil && presentation.openPath == nil)
        #expect(PushAlertPresentation(decrypted, logins: [nas, office]).subtitle == "192.168.1.10:3000")
    }

    @Test func rejectsOffSiteImagesAndLinks() throws {
        let presentation = PushAlertPresentation(
            try #require(try push(#"{"v":1,"type":"alert","title":"T","body":"B","image":"https://evil.example/x.jpg","open":"//evil.example/x"}"#)),
            logins: [nas])
        #expect(presentation.imageURL == nil)
        #expect(presentation.openPath == nil)
        #expect(PushTapTarget.sitePath(" /library/3/item/7?season=1 ") == "/library/3/item/7?season=1")
        #expect(PushTapTarget.sitePath("movieclaw://library/items/123") == nil)
        #expect(PushTapTarget.sitePath("/\\evil.example") == nil)
    }
}

struct PushTapTargetTests {
    private let nas = PushLoginInfo(origin: "http://192.168.1.10:3000", username: "Dad", serverName: "192.168.1.10:3000", accountName: "爸爸")

    /// 中继能在推送里随便加键：冒充「点开去哪」的键一律不认，只认解得开的密文
    @Test func ignoresKeysTheRelayCouldForge() throws {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        isolated.store.save(PushCryptoTests.vectorKey, keyID: PushCryptoTests.vectorKeyID, for: nas)
        // 密文是乱码、旁边塞了「去批准一台设备」：什么都不做
        #expect(PushTapTarget(userInfo: ["mc_key_id": PushCryptoTests.vectorKeyID, "mc_open": "/activate?code=EVIL-CODE",
                                         "e": "v1.\(PushCryptoTests.vectorKeyID).AAAA.BBBB"], store: isolated.store) == nil)
        // 密文解得开：按明文里的 open 走，旁边塞的键不管
        let payload = try PushCrypto.seal(Data(#"{"v":1,"type":"alert","title":"T","open":"/subscriptions/42"}"#.utf8),
                                          key: PushCryptoTests.vectorKey, keyID: PushCryptoTests.vectorKeyID)
        let target = PushTapTarget(userInfo: ["mc_open": "/activate?code=EVIL-CODE", "e": payload], store: isolated.store)
        #expect(target == PushTapTarget(login: nas, openPath: "/subscriptions/42"))
        #expect(target?.login.server == ServerAddress(origin: URL(string: "http://192.168.1.10:3000")!))
        #expect(AppRoute(webPath: target?.openPath ?? "") == .subscription(id: 42), "用现有的网页路径路由打开")
    }

    /// 点开时在 App 里解密：从明文取是哪个登录、去哪
    @Test func decryptsInTheApp() throws {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        isolated.store.save(PushCryptoTests.vectorKey, keyID: PushCryptoTests.vectorKeyID, for: nas)
        let payload = try PushCrypto.seal(Data(#"{"v":1,"type":"alert","title":"T","body":"B","open":"/settings/cloud"}"#.utf8),
                                          key: PushCryptoTests.vectorKey, keyID: PushCryptoTests.vectorKeyID)
        let target = PushTapTarget(userInfo: ["aps": ["alert": ["title": "MovieClaw"]], "e": payload], store: isolated.store)
        #expect(target == PushTapTarget(login: nas, openPath: "/settings/cloud"))
        #expect(AppRoute(webPath: "/settings/cloud") == .settingsSection(.cloud))

        // 测试向量的 open 是 movieclaw:// 链接，不是站内路径：只切账号
        #expect(PushTapTarget(userInfo: ["e": PushCryptoTests.vectorPayload], store: isolated.store) == PushTapTarget(login: nas, openPath: nil))
    }

    /// 认不出是哪个登录（已退出、通用文案的推送）：只是打开 App
    @Test func unknownLoginsAreIgnored() {
        let isolated = IsolatedStore()
        defer { isolated.tearDown() }
        #expect(PushTapTarget(userInfo: ["mc_open": "/x"], store: isolated.store) == nil)
        #expect(PushTapTarget(userInfo: ["e": PushCryptoTests.vectorPayload], store: isolated.store) == nil)
        #expect(PushTapTarget(userInfo: ["aps": ["alert": "你有一条新通知"]], store: isolated.store) == nil)
    }
}

struct PushRegistrationTests {
    private let key: PushKeyStore.Key = ("k7Qm2xP9Hn4", PushCryptoTests.vectorKey)

    /// APNs 环境按签名里的 aps-environment：描述文件是 CMS 签名包着的 plist，前后都是二进制
    @Test func apsEnvironmentComesFromTheProvisioningProfile() {
        func profile(_ environment: String) -> Data {
            var data = Data([0x30, 0x82, 0x4E, 0x00, 0xFF, 0x01])
            data.append(Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Name</key><string>MovieClaw Dev</string>
            <key>Entitlements</key><dict><key>aps-environment</key><string>\(environment)</string></dict></dict></plist>
            """.utf8))
            data.append(Data([0xA0, 0x82, 0x0B, 0x00]))
            return data
        }
        #expect(PushCenter.apsEnvironment(provisioningProfile: profile("development")) == "development")
        #expect(PushCenter.apsEnvironment(provisioningProfile: profile("production")) == "production",
                "Ad Hoc / 企业分发的描述文件是 production")
        #expect(PushCenter.apsEnvironment(provisioningProfile: nil) == nil, "App Store、TestFlight 的包里没有描述文件")
        #expect(PushCenter.apsEnvironment(provisioningProfile: Data("garbage".utf8)) == nil)
    }

    @Test func authorizedWithTokenSendsKey() throws {
        let body = API.PushRegistrationRequest.make(permission: .authorized, apnsToken: "a1b2c3", topic: "io.movieclaw.app",
                                             environment: "development", clientVersion: "0.3.0") { key }
        #expect(body == API.PushRegistrationRequest(token: "a1b2c3", topic: "io.movieclaw.app", environment: "development", types: ["alert"],
                                                    keyId: "k7Qm2xP9Hn4", key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", permission: "authorized",
                                                    clientVersion: "0.3.0"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(json?["key_id"] as? String == "k7Qm2xP9Hn4", "字段名同接口契约")
        #expect(Set(json?.keys.map { $0 } ?? []) == ["token", "topic", "environment", "types", "key_id", "key", "permission", "client_version"])
    }

    /// 关掉了通知、或拿不到 APNs 令牌：只报权限，不带令牌，也不为它生成密钥
    @Test func deniedOrTokenlessReportsPermissionOnly() throws {
        var keyRequested = false
        let denied = API.PushRegistrationRequest.make(permission: .denied, apnsToken: "a1b2c3", topic: "t", environment: "production",
                                                      clientVersion: "0.3.0") {
            keyRequested = true
            return key
        }
        #expect(!keyRequested)
        #expect(denied.token == nil && denied.keyId == nil && denied.key == nil)
        #expect(denied.permission == "denied")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(denied)) as? [String: Any]
        #expect(json?["token"] == nil, "没有的字段不发")
        #expect(json?["client_version"] as? String == "0.3.0", "只报权限时也刷新版本")

        let tokenless = API.PushRegistrationRequest.make(permission: .notDetermined, apnsToken: nil, topic: "t", environment: "production",
                                                         clientVersion: nil) { key }
        #expect(tokenless.token == nil && tokenless.key == nil)
        #expect(tokenless.permission == "not_determined")
    }

    @Test func mapsSystemPermission() {
        #expect(PushPermission(.authorized).rawValue == "authorized")
        #expect(PushPermission(.provisional).rawValue == "provisional")
        #expect(PushPermission(.ephemeral).rawValue == "ephemeral")
        #expect(PushPermission(.denied).rawValue == "denied")
        #expect(PushPermission(.notDetermined).rawValue == "not_determined")
    }
}

/// 「媒体库有新片」选哪些库（docs/design/cloud-push.md §7.3）
struct PushLibrarySelectionTests {
    private let all = [1, 2, 3]

    @Test func tappingFromAllRemovesThatLibrary() {
        #expect(NotificationSettingsModel.librarySelection(after: 2, selected: nil, all: all) == .libraries([1, 3]))
    }

    @Test func checkingEveryLibraryGoesBackToAll() {
        #expect(NotificationSettingsModel.librarySelection(after: 2, selected: [3, 1], all: all) == .libraries(nil),
                "全勾上 = 全部（包括以后新建的库）")
        #expect(NotificationSettingsModel.librarySelection(after: 3, selected: [1], all: all) == .libraries([1, 3]), "按库的顺序")
    }

    @Test func uncheckingTheLastOneTurnsTheEventOff() {
        #expect(NotificationSettingsModel.librarySelection(after: 1, selected: [1], all: all) == .turnOff)
    }

    /// 「全部」要明确发 null：生成的请求遇到 nil 不发字段（= 不改）
    @Test func selectionEncodesExplicitNull() throws {
        let all = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NotificationSettingsModel.LibrarySelection(ids: nil))) as? [String: Any]
        #expect(all?.keys.contains("library_ids") == true && all?["library_ids"] is NSNull)
        let some = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NotificationSettingsModel.LibrarySelection(ids: [2]))) as? [String: Any]
        #expect(some?["library_ids"] as? [Int] == [2])
        #expect(some?["events"] == nil, "只改选的库时不碰开关")
        // 一个都不剩：关掉事件，同时回到「全部」（下次打开就是全勾上）
        let off = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            NotificationSettingsModel.LibrarySelection(ids: nil, events: ["library_new": false]))) as? [String: Any]
        #expect(off?["library_ids"] is NSNull)
        #expect((off?["events"] as? [String: Bool]) == ["library_new": false])
        let omitted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(API.PushPreferencesRequest(events: ["library_new": true]))) as? [String: Any]
        #expect(omitted?["library_ids"] == nil, "只改开关时不碰选的库")
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
