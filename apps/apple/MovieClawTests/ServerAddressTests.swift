import Foundation
import Testing
@testable import MovieClaw

struct ServerAddressTests {
    @Test(arguments: [
        ("192.168.1.10:3000", "http://192.168.1.10:3000"),
        ("  http://192.168.1.10:3000/  ", "http://192.168.1.10:3000"),
        ("http://192.168.1.10:3000/login?next=%2F", "http://192.168.1.10:3000"),
        ("https://Movie.Example.com/library/3", "https://movie.example.com"),
        ("https://movie.example.com:443", "https://movie.example.com"),
        ("http://nas.local:80", "http://nas.local"),
        ("movie.ycy.homes:88", "http://movie.ycy.homes:88"),
    ])
    func normalizes(input: String, expected: String) throws {
        #expect(try ServerAddress(parsing: input).origin.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://host", "http://", "://x"])
    func rejects(input: String) {
        #expect(throws: ServerAddress.ParseError.self) { try ServerAddress(parsing: input) }
    }

    @Test func apiBaseAndResolve() throws {
        let address = try ServerAddress(parsing: "http://nas:3000")
        #expect(address.apiBase.absoluteString == "http://nas:3000/api/v1")
        #expect(address.resolve("/api/v1/images/a.jpg")?.absoluteString == "http://nas:3000/api/v1/images/a.jpg")
        #expect(address.resolve("https://image.tmdb.org/x.jpg")?.absoluteString == "https://image.tmdb.org/x.jpg")
        #expect(address.resolve(nil) == nil)
    }

    @Test func clientURLMergesQuery() throws {
        let client = APIClient(server: try ServerAddress(parsing: "http://nas:3000"))
        let url = client.url("/libraries/1/items?page=2", query: [.init(name: "sort", value: "added")])
        #expect(url.absoluteString == "http://nas:3000/api/v1/libraries/1/items?page=2&sort=added")
    }
}

/// 图片宽度阶梯（docs/design/image-sizing.md §5、§6）：取整与后端同一张表，同一档拼出同一个地址
struct ImageWidthTests {
    @Test(arguments: [
        (1.0, 160), (160.0, 160), (160.5, 240), (523.5, 720), (733.0, 960), (2411.0, 2560), (5000.0, 3840),
    ])
    func snapsUpToLadder(pixels: Double, expected: Int) {
        #expect(ImageWidth.snap(CGFloat(pixels)) == expected)
    }

    @Test func formula() {
        // iPhone 3 倍屏两列海报墙：174.5 点 → 523.5 像素 → 720 档
        #expect(ImageWidth.pixels(174.5, scale: 3) == 720)
        // 4K 电视海报卡 266 点、焦点放大 1.1 → 585 像素 → 720 档；1080p 电视同一张卡 → 360 档
        #expect(ImageWidth.pixels(266, scale: 2, zoom: 1.1) == 720)
        #expect(ImageWidth.pixels(266, scale: 1, zoom: 1.1) == 360)
        // iPhone 详情页 393×452 点的竖框铺满 16:9 背景：按高算约 804 点 → 2411 像素 → 2560 档
        let cover = ImageWidth.coverPoints(CGSize(width: 393, height: 452), aspect: ImageAspect.backdrop)
        #expect(ImageWidth.pixels(cover, scale: 3) == 2560)
    }

    @Test func appendsWidthToAnyServerImage() throws {
        let address = try ServerAddress(parsing: "http://nas:3000")
        #expect(address.imageURL("/libraries/1/cover?v=3", width: 500)?.absoluteString
            == "http://nas:3000/api/v1/libraries/1/cover?v=3&w=720")
        #expect(address.imageURL("/images/assets/9/poster.jpg", width: 720)?.absoluteString
            == "http://nas:3000/api/v1/images/assets/9/poster.jpg?w=720")
        let proxied = try #require(address.imageURL("https://image.tmdb.org/t/p/w500/a.jpg", width: 300))
        let items = URLComponents(url: proxied, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(proxied.path == "/api/v1/images/proxy")
        #expect(items.first { $0.name == "url" }?.value == "https://image.tmdb.org/t/p/w500/a.jpg")
        #expect(items.first { $0.name == "w" }?.value == "360")
        // 不带宽度 = 原图（灯箱放大到 1:1）
        #expect(address.imageURL("/libraries/files/5/original")?.absoluteString == "http://nas:3000/api/v1/libraries/files/5/original")
    }

    @Test func swapsWidthOnExistingURL() throws {
        let url = try #require(URL(string: "http://nas:3000/api/v1/images/assets/9/backdrop.jpg?v=1&w=3840"))
        #expect(url.imageWidth(ImageWidth.analysis).absoluteString == "http://nas:3000/api/v1/images/assets/9/backdrop.jpg?v=1&w=240")
    }
}

struct AppRouteParsingTests {
    @Test(arguments: [
        ("/library/19/item/1019?season=10&episode=1", AppRoute.libraryItem(libraryId: 19, itemId: 1019, season: 10, episode: 1)),
        ("/media/movie/550", AppRoute.mediaDetail(titleRef: "tmdb:movie:550")),
        ("/subscriptions/12?upgrade-run=1", AppRoute.subscription(id: 12, upgradeRun: true)),
        ("/tasks?view=history", AppRoute.activity(view: "history")),
        ("/settings/about", AppRoute.settingsSection(.app)),
        ("/settings/app?tab=remote", AppRoute.settingsSection(.playback)),
        ("/discover/movie/top250", AppRoute.discoverCollection(kind: "movie", provider: "douban", collectionId: "movie_top250")),
        ("/library/c/7", AppRoute.collection(libraryId: nil, collectionId: 7)),
        ("/library/19?view=collections&pending=1", AppRoute.library(id: 19, view: "collections", pending: true)),
        ("/library/manage?tab=duplicates&item=6434", AppRoute.libraryManage(create: false, tab: "duplicates", item: 6434)),
        ("/settings/app?tab=storage", AppRoute.settingsSection(.app, query: ["tab": "storage"])),
        ("/discover/tv?source=douban", AppRoute.discover(kind: "tv?source=douban")),
    ])
    func parses(path: String, expected: AppRoute) {
        #expect(AppRoute(webPath: path) == expected)
    }

    @Test func searchFoldsScopeParams() throws {
        guard case let .search(query)? = AppRoute(webPath: "/search?q=%E5%A5%A5%E6%9C%AC&cats=movie&sites=1,2") else {
            Issue.record("未解析为搜索路由"); return
        }
        #expect(query.q == "奥本")
        #expect(query.scope != nil)
    }
}
