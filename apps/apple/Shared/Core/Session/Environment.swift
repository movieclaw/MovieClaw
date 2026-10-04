import SwiftUI

private struct APIClientKey: EnvironmentKey {
    /// 未登录前的占位（不会真的被调用）：避免页面里到处处理可选值
    static let defaultValue = APIClient(server: ServerAddress(origin: URL(string: "http://localhost")!))
}

extension EnvironmentValues {
    /// 当前服务器的接口客户端；由 MainTabView 注入。页面里：
    /// `@Environment(\.api) private var api` → `try await api.librariesList()`
    var api: APIClient {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }
}

extension APIClient {
    /// 图片地址解析的便捷入口：`api.image(item.posterUrl, width: ImageWidth.points(124))`。
    /// 展示用的图一律带 `width`（需要的像素宽，见 `ImageWidth`）；不带 = 原图，只给灯箱放大到 1:1 这类场景
    nonisolated func image(_ raw: String?, width: Int? = nil) -> URL? {
        server.imageURL(raw, width: width)
    }
}

private struct RouteQueryKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    /// 站内链接携带的查询参数（目前用于设置分区的预填与直达，如 `?tab=storage`）
    var routeQuery: [String: String] {
        get { self[RouteQueryKey.self] }
        set { self[RouteQueryKey.self] = newValue }
    }
}

private struct PageWarmupKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 页面正在背后预热（见 MainTabView 的 PageWarmup）：只画出来，不发请求、不轮询、不记打点
    var pageWarmup: Bool {
        get { self[PageWarmupKey.self] }
        set { self[PageWarmupKey.self] = newValue }
    }
}
