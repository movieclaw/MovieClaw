import CryptoKit
import Foundation

/// 页面快照：媒体库首页、订阅首页上一次加载成功的数据存在本机，下次打开**先原样画出来**、再静默刷新
/// （stale-while-revalidate，Apple Music / Netflix 这类 App「秒开」的做法）。
///
/// 为什么要有：页面自己的数据要好几跳请求才齐（媒体库首页 4 段串行 + 十几行条目，订阅首页 2 段串行且
/// 服务端要现算 300 部订阅的进度），冷启动、第一次切过去都要对着骨架等 1～2 秒（模拟器连局域网实测）。
/// 有了快照，页面第一帧就是上次离开时的完整样子，网络只决定「多久之后换成最新的」。
///
/// 约定：
/// - 按「服务器 + 账号」分目录（主人键取 SHA256 当目录名），换账号互不串；退出 / 移除账号时连快照一起删；
/// - 只是缓存：放在 Library/Caches（系统空间吃紧时可以清）；解码失败（App 升级改了模型）、版本不符都直接丢弃，
///   页面照常走网络加载；
/// - 读写都不在主线程：读在登录恢复的那一刻就提前发起（`preload`），页面首帧直接取内存里的结果。
nonisolated enum PageSnapshots {
    /// 快照格式版本：快照结构有不兼容改动时 +1，旧文件自动作废
    static let version = 1

    /// 主人键：服务器 API 地址 + 用户名（同 `SubscriptionIndex` / `LibraryHomePrefs` 的写法）
    static func owner(server: ServerAddress, username: String) -> String {
        "\(server.apiBase.absoluteString)|\(username)"
    }

    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "PageSnapshots")
    }

    private static func directory(owner: String) -> URL {
        let digest = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: String(digest.prefix(32)))
    }

    private static func file(_ name: String, owner: String) -> URL {
        directory(owner: owner).appending(path: "\(name).v\(version).json")
    }

    /// 读一份快照；没有或解不开返回 nil（调用方在后台线程调用）
    static func read<T: Decodable>(_ type: T.Type, _ name: String, owner: String) -> T? {
        guard let data = try? Data(contentsOf: file(name, owner: owner)) else { return nil }
        return try? APIClient.decoder.decode(T.self, from: data)
    }

    /// 写一份快照（后台串行队列里编码落盘，原子替换，不阻塞调用方）
    static func write<T: Encodable & Sendable>(_ value: T, _ name: String, owner: String) {
        queue.async {
            let url = file(name, owner: owner)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? APIClient.encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 删掉一个账号的全部快照（退出、移除账号、令牌失效）
    static func remove(owner: String) {
        let url = directory(owner: owner)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// 删掉本机全部快照（退出全部账号）
    static func removeAll() {
        let url = root
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    private static let queue = DispatchQueue(label: "io.movieclaw.page-snapshots", qos: .utility)
}
