import Nuke
import TVServices

/// 把「接下来继续」发布到 Top Shelf（数据流见 `TopShelfSnapshot`）：首页拿到最新的这一行时调一次，
/// 下载前 8 部的剧照（带当前账号的令牌，经 Nuke 的磁盘缓存，多半不重新下载）、写进 App Group、通知系统重读。
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
            let raw = isEpisode ? (item.episodeStillUrl ?? item.backdropUrl) : (item.backdropUrl ?? item.posterUrl)
            var imageFile: String?
            if let url = api.image(raw, .reelStill),
               let (data, _) = try? await ImagePipeline.shared.data(for: ImageRequest(url: url)) {
                imageFile = TopShelfStore.writeImage(data, named: "\(item.mediaItemId)-\(item.seasonNumber)-\(item.episodeNumber)")
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
