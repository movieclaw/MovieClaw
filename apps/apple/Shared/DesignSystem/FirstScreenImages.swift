import Foundation
import Nuke

/// 首屏图片预热：把页面第一屏要显示的图提前解码进内存缓存。
///
/// 为什么：LazyImage 命中内存缓存时当场出图、不做渐显；只在磁盘缓存里时要先显示占位底、读盘解码，
/// 再用 0.2 秒渐显出来。冷启动、第一次切到某个页签时内存缓存是空的，录屏逐帧看，页面出现后还要
/// 再花约 200ms 才「长全」。页面数据（快照）一到就按页面的排版算出第一屏会显示哪些图，交给这里提前解码，
/// 页面第一帧就是图文齐全的样子。
///
/// 请求必须与页面里的写法完全一致（同一个 URL、不加处理器），才会命中同一条内存缓存。
enum FirstScreenImages {
    /// 马上要显示的页面（冷启动的落点）：高优先级
    private static let urgent: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(pipeline: .shared, destination: .memoryCache, maxConcurrentRequestCount: 6)
        prefetcher.priority = .high
        return prefetcher
    }()

    /// 还没打开的页签（空闲预取）：低优先级，不和当前页面的图抢
    private static let idle = ImagePrefetcher(pipeline: .shared, destination: .memoryCache, maxConcurrentRequestCount: 3)

    static func warm(_ urls: [URL], urgent isUrgent: Bool) {
        guard !urls.isEmpty else { return }
        (isUrgent ? urgent : idle).startPrefetching(with: urls)
    }
}
