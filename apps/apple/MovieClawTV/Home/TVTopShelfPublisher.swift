import Nuke
import TVServices
import UIKit

/// 把「接下来继续」发布到 Top Shelf（数据流见 `TopShelfSnapshot`）：首页拿到最新的这一行时调一次，
/// 下载前 8 部的背景图（带当前账号的令牌，经 Nuke 的磁盘缓存，多半不重新下载）、写进 App Group、通知系统重读。
/// 内容没变就不重写，免得系统反复刷新主屏。
enum TVTopShelfPublisher {
    private static let limit = 8
    private static var lastFingerprint: Int?

    static func publish(_ items: [API.UpNextItemView], api: APIClient) async {
        let picked = Array(items.prefix(limit))
        var hasher = Hasher()
        hasher.combine(api.server.origin)
        for item in picked {
            hasher.combine(item.mediaItemId)
            hasher.combine(item.seasonNumber)
            hasher.combine(item.episodeNumber)
            hasher.combine(item.progressPercent)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint

        var entries: [TopShelfSnapshot.Item] = []
        for item in picked {
            let isEpisode = item.kind == "tv"
            // 统一取条目的背景图（剧集也用整部剧的）：Top Shelf 横幅约 1920 宽，单集剧照常常没那么大，也容易剧透；
            // 没有背景图再退回分集剧照、海报。固定取 1920 档（docs/design/image-sizing.md §6）
            let raw = item.backdropUrl ?? (isEpisode ? item.episodeStillUrl : nil) ?? item.posterUrl
            var imageFile: String?
            if let url = api.image(raw, width: 1920),
               let (data, _) = try? await ImagePipeline.shared.data(for: ImageRequest(url: url)) {
                // 派生图是 WebP，而快照里的文件名是 .jpg：转成真 JPEG 再写，扩展名与内容一致，
                // 系统读图不必靠嗅探兜底（解不开就原样写，与改动前一致）
                let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) ?? data
                imageFile = TopShelfStore.writeImage(jpeg, named: "\(item.mediaItemId)-\(item.seasonNumber)-\(item.episodeNumber)")
            }
            entries.append(TopShelfSnapshot.Item(
                id: "\(item.mediaItemId)-\(item.seasonNumber)-\(item.episodeNumber)",
                title: item.title,
                subtitle: TVHomeView.upNextSubtitle(item),
                imageFile: imageFile,
                playURL: TVDeepLink.play(itemId: item.mediaItemId, season: isEpisode ? item.seasonNumber : nil,
                                         episode: isEpisode ? item.episodeNumber : nil).url.absoluteString,
                displayURL: TVDeepLink.item(libraryId: item.libraryId, itemId: item.mediaItemId).url.absoluteString,
                progress: item.progressPercent.map { Double($0) / 100 }
            ))
        }
        TopShelfStore.write(TopShelfSnapshot(items: entries, updatedAt: .now))
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// 退出登录后清掉，主屏不再露出上一个人在看什么
    static func clear() {
        lastFingerprint = nil
        TopShelfStore.clear()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}
