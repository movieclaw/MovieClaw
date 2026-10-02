import Foundation

/// Top Shelf 的数据（docs/design/tvos-app.md §3.1）：在 Apple TV 主屏选中 MovieClaw 图标时，上方大图区显示的「接下来继续」。
///
/// 为什么由 App 写、扩展只读：扩展是另一个进程，要自己联网就得拿到当前服务器与令牌（共享钥匙串访问组）、
/// 还得带令牌下载图片（系统按图片地址直接取，加不了请求头）。改成 App 在刷新首页时把这一行连同剧照一起写进
/// App Group 容器、通知系统重读，扩展只把文件交给系统——不联网、不碰令牌。App 不在前台时显示的是上次的样子。
///
/// 本文件同时编进 App 与 Top Shelf 扩展两个目标（见 project.yml）。
nonisolated struct TopShelfSnapshot: Codable, Sendable {
    nonisolated struct Item: Codable, Sendable {
        var id: String
        var title: String
        /// 「第 1 季 第 3 集 · 剩 23 分钟」
        var subtitle: String?
        /// 容器里剧照的文件名
        var imageFile: String?
        /// 按播放键：直接续播（`movieclaw://play/…`）
        var playURL: String
        /// 按确认键：打开详情（`movieclaw://item/…`）
        var displayURL: String
        /// 0～1 的观看进度
        var progress: Double?
    }

    var items: [Item]
    var updatedAt: Date
}

/// App Group 容器里的 Top Shelf 文件：`TopShelf/snapshot.json` 与剧照
nonisolated enum TopShelfStore {
    /// App Group 的标识写在两个目标的 Info.plist（`MCAppGroup`），跟着 Bundle ID 前缀走
    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "MCAppGroup") as? String
    }

    static var directory: URL? {
        guard let groupID,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return container.appending(path: "TopShelf", directoryHint: .isDirectory)
    }

    static func read() -> TopShelfSnapshot? {
        guard let file = directory?.appending(path: "snapshot.json"),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    static func write(_ snapshot: TopShelfSnapshot) {
        guard let directory, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "snapshot.json"), options: .atomic)
        // 只留这一份快照用到的剧照：换了账号、看完的片下架后，旧图不越积越多
        let keep = Set(snapshot.items.compactMap(\.imageFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasSuffix(".jpg") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }

    static func imageURL(_ file: String?) -> URL? {
        guard let file, let directory else { return nil }
        let url = directory.appending(path: file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 写一张剧照，返回文件名
    static func writeImage(_ data: Data, named name: String) -> String? {
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = "\(name).jpg"
        do {
            try data.write(to: directory.appending(path: file), options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// 清空（退出登录、换了没有内容的账号）
    static func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// App 内部链接（Top Shelf 的动作、将来别的入口）：`movieclaw://play/<条目>?season=&episode=`、`movieclaw://item/<库>/<条目>`
nonisolated enum TVDeepLink: Equatable {
    case play(itemId: Int, season: Int?, episode: Int?)
    case item(libraryId: Int, itemId: Int)

    static let scheme = "movieclaw"

    init?(url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = [components.host].compactMap { $0 } + components.path.split(separator: "/").map(String.init)
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
        switch parts.first {
        case "play":
            guard parts.count >= 2, let id = Int(parts[1]) else { return nil }
            self = .play(itemId: id, season: query["season"].flatMap(Int.init), episode: query["episode"].flatMap(Int.init))
        case "item":
            guard parts.count >= 3, let library = Int(parts[1]), let id = Int(parts[2]) else { return nil }
            self = .item(libraryId: library, itemId: id)
        default:
            return nil
        }
    }

    var url: URL {
        switch self {
        case let .play(itemId, season, episode):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "play"
            components.path = "/\(itemId)"
            if let season, let episode {
                components.queryItems = [URLQueryItem(name: "season", value: "\(season)"), URLQueryItem(name: "episode", value: "\(episode)")]
            }
            return components.url!
        case let .item(libraryId, itemId):
            return URL(string: "\(Self.scheme)://item/\(libraryId)/\(itemId)")!
        }
    }
}
