#if os(iOS)
import CryptoKit
import Foundation

/// 本机副本里的图片（docs/design/offline-download.md §3.2、§4）：海报、剧照、Logo、分集剧照、演职员头像。
///
/// 同一张图在各处按不同宽度取（`w`），本机每张只存一份。所以按「图片键」认：地址去掉服务器前缀、宽度与尺寸预设参数，
/// TMDB 地址再去掉尺寸段——换了服务器地址（局域网 IP ↔ 域名）、换了显示宽度都还是同一张。
///
/// 图片加载器（`AuthorizedDataLoader`）在两种情况下用本机的：离线模式（不发请求）；在线时请求失败。
nonisolated final class OfflineImages: @unchecked Sendable {
    static let shared = OfflineImages()

    private let lock = NSLock()
    /// 图片键 → 本机文件
    private var files: [String: URL] = [:]
    /// 条目 → 它的图片键（删条目时一起摘掉）
    private var byItem: [Int: Set<String>] = [:]
    private var ownerKey: String?

    /// 图片键：`/images/assets/12/poster.jpg?v=3`、`/images/proxy?url=https://image.tmdb.org/t/p/*/abc.jpg`
    static func key(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if let range = path.range(of: "/api/v1/") { path = "/" + path[range.upperBound...] }
        let dropped: Set<String> = ["w", "variant", "mc_account"]
        var items = (components.queryItems ?? []).filter { !dropped.contains($0.name) }
        items = items.map { item in
            guard item.name == "url", let value = item.value else { return item }
            return URLQueryItem(name: "url", value: value.replacingOccurrences(of: #"/t/p/[^/]+/"#, with: "/t/p/*/", options: .regularExpression))
        }
        items.sort { $0.name < $1.name }
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return path + query
    }

    static func fileName(for key: String, ext: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(digest).\(ext)"
    }

    /// 读一个账号全部条目的图片索引（换账号、启动时在后台）
    func load(ownerKey: String, itemIds: [Int]) {
        var loaded: [String: URL] = [:]
        var items: [Int: Set<String>] = [:]
        for itemId in itemIds {
            let dir = OfflineDisk.imagesDir(ownerKey, itemId)
            guard let index = OfflineDisk.read([String: String].self, from: dir.appending(path: "index.json")) else { continue }
            for (key, name) in index {
                loaded[key] = dir.appending(path: name)
                items[itemId, default: []].insert(key)
            }
        }
        lock.withLock {
            self.ownerKey = ownerKey
            files = loaded
            byItem = items
        }
    }

    func reset() {
        lock.withLock {
            ownerKey = nil
            files = [:]
            byItem = [:]
        }
    }

    /// 打包时存下一张图后登记
    func register(key: String, file: URL, itemId: Int) {
        lock.withLock {
            files[key] = file
            byItem[itemId, default: []].insert(key)
        }
    }

    func forget(itemId: Int) {
        lock.withLock {
            for key in byItem.removeValue(forKey: itemId) ?? [] { files.removeValue(forKey: key) }
        }
    }

    func has(_ url: URL) -> Bool {
        guard let key = Self.key(for: url) else { return false }
        return lock.withLock { files[key] != nil }
    }

    /// 这张图的本机文件（没有为 nil）
    func localData(for url: URL) -> Data? {
        guard let key = Self.key(for: url), let file = lock.withLock({ files[key] }) else { return nil }
        return try? Data(contentsOf: file)
    }
}
#endif
