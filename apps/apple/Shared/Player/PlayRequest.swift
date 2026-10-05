import Foundation

/// 播放请求：对应 Web `/play/{mediaItemId}/{sXXeYY}?t=` 与分享页 `/s/{slug}/play/...`。
struct PlayRequest: Identifiable, Hashable {
    var mediaItemId: Int
    var season: Int?
    var episode: Int?
    /// 指定起播秒数（仅对第一个播放单元生效，同 Web `?t=`）
    var startSeconds: Double?
    /// 访客分享播放：走 `/share/{slug}/playback` 接口族，进度只存本地
    var shareSlug: String?
    /// 播放器内切换文件版本时指定
    var fileId: Int?
    /// 片段模式（刷片的「全屏观看」）：只放这一段，见 `PlaybackClip`
    var clip: PlaybackClip?

    var id: String {
        "\(shareSlug ?? "")-\(mediaItemId)-\(season ?? -1)-\(episode ?? -1)" + (clip.map { "-clip\($0.startMs)" } ?? "")
    }
}

/// 播放器的片段模式（docs/design/reels.md §6）：刷片页点「全屏观看」时，这一段交给正片播放器放。
/// 手势、控制条、换音轨字幕、画质、倍速与正片完全一样，区别只在时间轴：
/// - 进度条、时间、锁屏进度都按片段算，**总时长是这一段的长度**，不是整部片的，免得以为在看整部；
/// - 跳转夹在片段之内，放到终点停下（可重播，或点「看全片」原地转成正常播放）；
/// - 不写观看记录：不报进度（不写续播点、不进「继续观看」、不上活动页），也不留播放质量记录。
/// 起止都是文件时间（毫秒），与服务端刷片接口的 `segment` 同一口径
struct PlaybackClip: Hashable {
    var startMs: Int
    var endMs: Int
    /// 片段的画质（`ReelsQuality`，竖屏与全屏共用一份）：片段模式按它开、改了也记回它，不动正片的按片画质记忆
    var maxHeight: Int?
}

/// 片段播放器关掉时的位置：哪个文件、停在文件的第几毫秒
struct ClipReturn {
    let fileId: Int
    let positionMs: Int
}

extension PlayRequest {
    /// 解析站内播放链接（同 Web `lib/player/play-links.ts` 的地址约定）：
    /// - `/play/{mediaItemId}[/sXXeYY][?t=秒]`
    /// - `/s/{slug}/play[/sXXeYY][?t=秒]`（访客播放；条目 id 要等分享页读到影片才知道，这里记 0）
    /// 不是播放链接返回 nil。
    init?(webPath raw: String) {
        guard let components = URLComponents(string: raw.hasPrefix("/") ? raw : "/\(raw)") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        var unitSegment: String?
        if parts.count >= 2, parts[0] == "play", let id = Int(parts[1]), id > 0 {
            self.init(mediaItemId: id)
            unitSegment = parts.count >= 3 ? parts[2] : nil
        } else if parts.count >= 3, parts[0] == "s", parts[2] == "play" {
            self.init(mediaItemId: 0, shareSlug: parts[1])
            unitSegment = parts.count >= 4 ? parts[3] : nil
        } else {
            return nil
        }
        // sXXeYY 之外的写法（含 s00e00 = 电影）一律当电影 / 由服务端定起点
        if let segment = unitSegment, let match = segment.lowercased().wholeMatch(of: /s(\d+)e(\d+)/),
           let season = Int(match.1), let episode = Int(match.2), season > 0 || episode > 0 {
            self.season = season
            self.episode = episode
        }
        // ?t= 只接受单个非负整数（同 Web queryNumber）
        if let t = components.queryItems?.first(where: { $0.name == "t" })?.value, t.wholeMatch(of: /\d+/) != nil, let seconds = Double(t) {
            startSeconds = seconds
        }
        #if DEBUG
        // 开发期语料测试：`?file=<文件 id>` 指定版本——同一条目有多个版本时，服务端挑的未必是要测的那个
        if let raw = components.queryItems?.first(where: { $0.name == "file" })?.value, let id = Int(raw), id > 0 {
            fileId = id
        }
        #endif
    }
}
