import Nuke
import NukeUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 图片宽度阶梯（docs/design/image-sizing.md §5、§6）：客户端只说「这个位置要多少像素宽」，
/// 服务端把 `w` 向上取到同一张阶梯表、等比缩放（不裁切），原图不比那一档大就直接回原图。
///
/// 需要宽 = 有效宽（点）× 屏幕倍率 × 放大系数，再向上取到阶梯：
/// - 有效宽：等比装下（fit）取框宽；铺满（fill）取 `max(框宽, 框高 × 图片宽高比)`——竖框铺满 16:9 背景要按高算；
/// - 屏幕倍率读真实值（`ImageWidth.screenScale`）：iPhone 3 倍屏按 3 倍、Apple TV 接 1080p 是 1、接 4K 是 2；
/// - 放大系数：电视卡片获得焦点放大约 1.1、头像 1.12、首屏慢推 1.06（`TVMetrics`）。
///
/// 客户端先取整再拼地址：同一档就是同一个 URL，Nuke 的内存 / 磁盘缓存可以复用。
/// 旧服务器不认识 `w` 会忽略它、回原图（大但清楚），所以不需要额外兼容
nonisolated enum ImageWidth {
    /// 与后端 `WIDTH_LADDER` 同一张表：相邻两档不超过 1.5 倍，超过 3840 按 3840
    static let ladder = [160, 240, 360, 480, 720, 960, 1280, 1920, 2560, 3840]
    /// 只为量亮度、边缘色这类分析取的小图：不必解码整张大图
    static let analysis = 240

    /// 需要的像素宽向上取到阶梯
    static func snap(_ pixels: CGFloat) -> Int {
        ladder.first { CGFloat($0) >= pixels.rounded(.up) } ?? ladder[ladder.count - 1]
    }

    /// 显示宽（点）× 屏幕倍率 × 放大系数 → 阶梯上的一档
    static func pixels(_ points: CGFloat, scale: CGFloat, zoom: CGFloat = 1) -> Int {
        snap(points * scale * zoom)
    }

    /// 铺满（fill）一个框时图片实际被拉到的宽（点）：图比框扁（如竖框铺 16:9 背景）时按高算
    static func coverPoints(_ frame: CGSize, aspect: CGFloat) -> CGFloat {
        max(frame.width, frame.height * aspect)
    }
}

/// 图片宽高比（宽 ÷ 高）未知时按资产类型兜底（docs/design/image-sizing.md §6）
nonisolated enum ImageAspect {
    /// 海报、头像
    static let poster: CGFloat = 2.0 / 3.0
    /// 背景、剧照
    static let backdrop: CGFloat = 16.0 / 9.0
}

/// 读屏幕的那一半（UIScreen 只能在主线程读）
@MainActor
extension ImageWidth {
    /// 本机屏幕。`UIScreen.main` 在 26 系 SDK 标了弃用，但它在窗口场景连上之前就能读——冷启动的首屏预载
    /// （`SessionPrewarm`）比场景早，要和页面算出同一个地址，所以集中在这一处读，别处一律走 `screenScale` / `screenSize`
    #if canImport(UIKit)
    private static var device: UIScreen { UIScreen.main }

    /// 当前屏幕的真实倍率：iPhone 3 倍屏是 3；Apple TV 接 1080p 电视是 1、接 4K 是 2（tvOS 画布始终 1920×1080 点）
    static var screenScale: CGFloat { max(1, device.scale) }

    /// 屏幕尺寸（点，跟着当前朝向）
    static var screenSize: CGSize { device.bounds.size }
    #else
    /// Mac：主屏的倍率（视网膜屏 2，外接 1080p 显示器 1）。窗口可以拖到别的屏，按主屏取已足够——
    /// 取图宽度本来就向上吸到档位
    static var screenScale: CGFloat { max(1, NSScreen.main?.backingScaleFactor ?? 2) }

    /// 主屏尺寸（点）
    static var screenSize: CGSize { NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900) }
    #endif

    /// 在本机屏幕上显示这么宽（点）要请求的 `w`
    static func points(_ points: CGFloat, zoom: CGFloat = 1) -> Int {
        pixels(points, scale: screenScale, zoom: zoom)
    }

    /// 铺满一个框（点）要请求的 `w`；`aspect` 是图片宽高比，未知时用 `ImageAspect` 按类型兜底
    static func cover(_ frame: CGSize, aspect: CGFloat, zoom: CGFloat = 1) -> Int {
        points(coverPoints(frame, aspect: aspect), zoom: zoom)
    }

    /// 屏宽像素（取屏幕长边，转屏后照样够）：全屏大图、灯箱的屏幕图用它。
    /// Apple TV 接 4K → 3840、1080p → 1920；iPhone 3 倍屏约 2556 → 2560 档
    static var screen: Int {
        points(max(screenSize.width, screenSize.height))
    }
}

/// iPhone 上几种固定宽度的卡片（点）：页面与首屏预载（`FirstScreenImages`，代码在 Shared）按同一个宽度取图，
/// 地址一致才命中同一条缓存。改卡片宽度改这里
enum PhoneCardWidth {
    /// 首页横滑行的海报（收藏、库 / 类型 / 合集行）
    static let homePoster: CGFloat = 124
    /// 发现页横滑行的海报（`DiscoverPosterRow.cardWidth`）
    static let discoverPoster: CGFloat = 126
    /// 首页「接下来继续」横卡（16:9）
    static let upNext: CGFloat = 200
    /// 首页「我的媒体库」库 / 合集封面卡（21:10）
    static let libraryCover: CGFloat = 230
    /// 订阅首页「刚刚入库」横卡（16:9）
    static let recent: CGFloat = 264
    /// 「刚刚入库」卡左下角的小号片名 Logo 最宽
    static let recentLogo: CGFloat = 118
}

@MainActor
extension ImageWidth {
    /// 沉浸 Hero（发现页、订阅首页）：屏宽 × `height` 的竖框铺满 16:9 剧照要按高算，再乘慢推的 1.1 倍
    static func phoneHero(height: CGFloat) -> Int {
        cover(CGSize(width: screenSize.width, height: height), aspect: ImageAspect.backdrop, zoom: 1.1)
    }
}

/// 旧的图片尺寸预设（同 Web `lib/image-proxy.ts` 的 ImageVariant）：按「设备 × 场景」命名，尺寸按网页定，
/// iPhone 3 倍屏、4K 电视上都偏小。客户端已全部改用宽度阶梯（`ImageWidth`），这里只为旧路径保留，新代码不要再用
@available(*, deprecated, message: "改用宽度阶梯：api.image(raw, width: ImageWidth.points(...))")
nonisolated enum ImageVariant: String {
    case landscapeCard = "landscape-card"
    case posterCard = "poster-card"
    case photoTile = "photo-tile"
    case galleryTile = "gallery-tile"
    case photoScreen = "photo-screen"
    /// 刷片等画面时垫在横带里的剧照：720p（横带占满屏宽，横卡的 480 放大发虚）
    case reelStill = "reel-still"
    /// Apple TV 的横卡 / 海报卡：电视画布 1920×1080 点、接 4K 时按 2 倍渲染，手机那两档在电视上会糊
    case tvLandscape = "tv-landscape"
    case tvPoster = "tv-poster"
}

nonisolated extension ServerAddress {
    /// 后端给出的图片地址 → 可请求的 URL（同 Web `imageUrl()`）：
    /// - http(s) 远程图（TMDB、豆瓣、PT 站截图）一律走后端缓存代理 `/images/proxy`；
    /// - 相对路径（`/images/assets/...`、`/libraries/...`、`/auth/avatar`……）补上 `/api/v1` 直连；
    /// - Windows 刮削器写入的反斜杠统一换成 `/`；
    /// - `width`：需要的像素宽，先取到阶梯再拼进 `w`（同一档同一个 URL）。所有服务端出图路由都认它；
    ///   nil = 要原图（照片灯箱放大到 1:1 这类）
    func imageURL(_ raw: String?, width: Int? = nil) -> URL? {
        guard var components = imageComponents(raw) else { return nil }
        if let width {
            let items = (components.queryItems ?? []).filter { $0.name != "w" }
            components.queryItems = items + [URLQueryItem(name: "w", value: String(ImageWidth.snap(CGFloat(width))))]
        }
        return components.url
    }

    /// 旧的按预设取图（只有刮削资产与代理认）；保留给旧路径
    @available(*, deprecated, message: "改用 imageURL(_:width:)")
    func imageURL(_ raw: String?, variant: ImageVariant?) -> URL? {
        guard var components = imageComponents(raw) else { return nil }
        if let variant, components.path.hasSuffix("/images/proxy") || components.path.contains("/images/assets/") {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "variant", value: variant.rawValue)]
        }
        return components.url
    }

    private func imageComponents(_ raw: String?) -> URLComponents? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard var c = URLComponents(url: apiBase.appending(path: "images/proxy"), resolvingAgainstBaseURL: false) else { return nil }
            c.queryItems = [URLQueryItem(name: "url", value: raw)]
            return c
        }
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/api/v1/") { path = String(path.dropFirst("/api/v1".count)) }
        guard let url = URL(string: apiBase.absoluteString + (path.hasPrefix("/") ? path : "/" + path)) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)
    }

    /// TMDB 图升级到 original 档再经代理按 `width` 缩（发现页 / 订阅页 Hero 用；非 TMDB 图原样）：
    /// 代理不会替你换 TMDB 档位，源图只有 w780 时要 2560 档也只能拿到 780
    func originalTMDBImageURL(_ raw: String?, width: Int?) -> URL? {
        guard let raw else { return nil }
        let upgraded = raw.replacingOccurrences(of: #"/t/p/w\d+/"#, with: "/t/p/original/", options: .regularExpression)
        return imageURL(upgraded, width: width)
    }
}

nonisolated extension URL {
    /// 同一张服务端图换一档宽度（如首屏大图 → 量亮度用的 240 小图）；地址里没有 `w` 也照样加上
    func imageWidth(_ width: Int) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        let items = (components.queryItems ?? []).filter { $0.name != "w" }
        components.queryItems = items + [URLQueryItem(name: "w", value: String(ImageWidth.snap(CGFloat(width))))]
        return components.url ?? self
    }
}

/// 统一的远程图片视图：带占位底色、渐显、失败兜底图标。
/// 后端图片接口需要登录：设备令牌由图片加载器（`AuthorizedDataLoader`）按主机补上。
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// 失败或无图时的兜底图标
    var placeholderSymbol: String = "film"
    /// 失败或无图时改显示这句文字（如「暂无封面」）；nil = 显示图标
    var placeholderText: String? = nil

    var body: some View {
        LazyImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { state in
            Group {
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: contentMode)
                } else if state.error != nil || url == nil {
                    ZStack {
                        Theme.surfaceRaised
                        if let placeholderText {
                            Text(placeholderText)
                                .font(.caption)
                                .foregroundStyle(Theme.textFaint)
                        } else {
                            Image(systemName: placeholderSymbol)
                                .font(.title2)
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                } else {
                    Theme.surfaceRaised
                }
            }
            .perfImage(url, state)
        }
    }
}

/// 按自己实际排出来的尺寸取图：同一张卡片出现在横滑行、各种网格里，宽度事先说不准时用它。
/// 量出框的尺寸 → 有效宽（铺满时 `max(框宽, 框高 × 图片宽高比)`，装下时取装进去的宽）→ 本机像素 → 阶梯档。
/// 框宽在同一档里变化（转屏、分栏微调）地址不变，不会重新取图；还没排出尺寸时不发请求
struct MeasuredRemoteImage: View {
    /// 服务端给的图片地址（原样，未拼 `w`）
    let raw: String?
    /// 图片宽高比（宽 ÷ 高）：未知时按类型给 `ImageAspect.poster` / `.backdrop`
    var aspect: CGFloat = ImageAspect.poster
    var contentMode: ContentMode = .fill
    var placeholderSymbol: String = "film"
    var placeholderText: String? = nil

    @Environment(\.api) private var api

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if size.width > 0, size.height > 0 {
                let points = contentMode == .fill
                    ? ImageWidth.coverPoints(size, aspect: aspect)
                    : min(size.width, size.height * aspect)
                RemoteImage(url: api.image(raw, width: ImageWidth.points(points)), contentMode: contentMode,
                            placeholderSymbol: placeholderSymbol, placeholderText: placeholderText)
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}

/// App 启动时配置 Nuke：300MB 磁盘缓存 + 与 APIClient 同一套设备令牌（不收发 Cookie）
enum ImagePipelineSetup {
    static func configure() {
        var configuration = ImagePipeline.Configuration.withDataCache(name: "io.movieclaw.images", sizeLimit: 300 * 1024 * 1024)
        let urlConfig = DataLoader.defaultConfiguration
        urlConfig.httpCookieStorage = nil
        urlConfig.httpShouldSetCookies = false
        let loader = DataLoader(configuration: urlConfig)
        if PerfTrace.enabled { loader.delegate = PerfTrace.NetworkMetrics.shared }
        configuration.dataLoader = AuthorizedDataLoader(base: loader)
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }
}

/// 给图片请求补上设备令牌：海报、头像这些地址只是一个 URL，经 Nuke 直接加载、不经过 `APIClient`，
/// 令牌按 URL 的主机从 `AuthTokenRegistry` 取（当前账号的；带 `mc_account` 标记的头像用那个账号的）。
/// 非 MovieClaw 的主机（TMDB 直链等）取不到令牌，原样放行。
///
/// 尺寸预设兜底：服务器不认识请求里的 `variant`（App 比服务器新，如电视的 `tv-poster` 是后加的两档），
/// 会按参数校验失败回 422，海报整张空着（2026-10-04 NAS 换回不含这两档的版本时，媒体库里一片空卡）。
/// 这时去掉 `variant` 再取一次原图：大一点，但一定有图
private nonisolated struct AuthorizedDataLoader: DataLoading {
    let base: DataLoader

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        var request = request
        if let url = request.url, request.value(forHTTPHeaderField: "Authorization") == nil,
           let token = AuthTokenRegistry.shared.token(for: url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let fallback = Self.withoutVariant(request) else {
            return base.loadData(with: request, didReceiveData: didReceiveData, completion: completion)
        }
        let task = RetryingTask()
        task.current = base.loadData(with: request, didReceiveData: didReceiveData) { [base] error in
            if case let DataLoader.Error.statusCodeUnacceptable(code)? = error as? DataLoader.Error, code == 422,
               !task.isCancelled {
                task.current = base.loadData(with: fallback, didReceiveData: didReceiveData, completion: completion)
            } else {
                completion(error)
            }
        }
        return task
    }

    /// 带 `variant` 的请求去掉这个参数；不带的返回 nil（不需要兜底）
    private static func withoutVariant(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.contains(where: { $0.name == "variant" }) else { return nil }
        let rest = items.filter { $0.name != "variant" }
        components.queryItems = rest.isEmpty ? nil : rest
        guard let plain = components.url else { return nil }
        var copy = request
        copy.url = plain
        return copy
    }

    /// 可能换过一次请求的加载任务：取消时取消眼下这一个
    private final class RetryingTask: Cancellable, @unchecked Sendable {
        private let lock = NSLock()
        private var _current: (any Cancellable)?
        private var _cancelled = false

        var current: (any Cancellable)? {
            get { lock.withLock { _current } }
            set { lock.withLock { _current = newValue } }
        }

        var isCancelled: Bool { lock.withLock { _cancelled } }

        func cancel() {
            let task = lock.withLock { () -> (any Cancellable)? in
                _cancelled = true
                return _current
            }
            task?.cancel()
        }
    }
}
