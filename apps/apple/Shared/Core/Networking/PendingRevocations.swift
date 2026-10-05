import Foundation

/// 没注销成功的登录：退出、移除账号时服务器连不上，本机照样退出，令牌记在这里，以后再去服务器上注销。
///
/// 不补注销的话，服务器上「我的设备」里还留着这台、推送登记也还在：手机会一直收到这个账号的通知
/// （本机已经没有密钥，只能显示通用文案），自己还停不掉；同一台手机登着同一台服务器的别的账号时，
/// 服务器还可能拿这个已退出账号的密钥加密大家都收的通知（docs/design/cloud-push.md §4）。
///
/// 令牌是机密，存钥匙串（`KeychainBlob`，Apple TV 上全家共用）。每次启动、回到前台各试一次（`retry`）：
/// 注销成功、令牌已经失效（401）、服务器上已经没有这台设备（404）都算办完，连不上就下次再试。
nonisolated enum PendingRevocations {
    struct Entry: Codable, Equatable, Sendable {
        var origin: String
        var token: String
    }

    private static let service = "io.movieclaw.app.pending-revocations"
    /// 最多记这么多条（只会在一直连不上的服务器上越积越多）
    private static let limit = 50

    /// 服务器上没注销成功：记下来以后再试
    static func add(server: ServerAddress, token: String) {
        var entries = load().filter { $0.token != token }
        entries.append(Entry(origin: server.origin.absoluteString, token: token))
        save(Array(entries.suffix(limit)))
    }

    static func load() -> [Entry] {
        guard let data = KeychainBlob.read(service: service) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [Entry]) {
        if entries.isEmpty {
            KeychainBlob.remove(service: service)
        } else if let data = try? JSONEncoder().encode(entries) {
            KeychainBlob.write(data, service: service)
        }
    }

    /// 把记着的都再试一次。同时只跑一轮
    @MainActor static func retry() async {
        guard !running else { return }
        let entries = load()
        guard !entries.isEmpty else { return }
        running = true
        defer { running = false }
        var done: Set<String> = []
        for entry in entries {
            guard let origin = URL(string: entry.origin) else {
                done.insert(entry.token)
                continue
            }
            if await revoke(APIClient(server: ServerAddress(origin: origin), token: entry.token)) {
                done.insert(entry.token)
            }
        }
        // 重新读一遍再删：重试期间可能又记了新的
        save(load().filter { !done.contains($0.token) })
    }

    /// 在服务器上注销这枚令牌对应的设备。注销了、令牌早就失效了、设备早就没了都返回 true；连不上返回 false
    static func revoke(_ client: APIClient, timeout: TimeInterval = 10) async -> Bool {
        do {
            _ = try await client.send("DELETE", "/auth/devices/current", timeout: timeout, as: API.JSONValue?.self)
            return true
        } catch let error as APIError where error.status == 401 || error.status == 404 {
            return true
        } catch {
            return false
        }
    }

    @MainActor private static var running = false
}
