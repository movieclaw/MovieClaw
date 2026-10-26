import UIKit

/// 豆瓣直接唤起词条；未安装或唤起失败时回到原网页。其他站点交给系统处理 Universal Link。
enum ExternalMediaLink {
    static func doubanAppURL(for url: URL) -> URL? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["movie.douban.com", "m.douban.com", "www.douban.com", "douban.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/")
        let id: Substring
        if parts.count == 2, parts[0] == "subject" {
            id = parts[1]
        } else if parts.count == 3, parts[0] == "movie", parts[1] == "subject" {
            id = parts[2]
        } else {
            return nil
        }
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        // 豆瓣的电影、电视剧词条共用 movie 路径。
        return URL(string: "douban://douban.com/movie/\(id)")
    }

    static func open(_ url: URL, using opener: (URL) async -> Bool = { await UIApplication.shared.open($0) }) async {
        if let appURL = doubanAppURL(for: url), await opener(appURL) { return }
        _ = await opener(url)
    }
}
