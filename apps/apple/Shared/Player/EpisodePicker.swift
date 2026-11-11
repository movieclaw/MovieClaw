import SwiftUI

/// 播放器选集面板（iPhone 的抽屉、Mac 的侧栏、Apple TV 的剧照排）共用的文案与计算，三端说法一致
enum EpisodePicker {
    /// 季名：0 是特别篇
    static func seasonName(_ season: Int) -> String {
        season == 0 ? String(localized: .mediaSeasonSpecials) : String(localized: .libraryItemSeason(season))
    }

    /// 集名下面那一行：缺集 / 已看完（带对勾）/ 看到哪；都不是就不写。分集接口不给片长，所以不写时长
    static func meta(_ episode: API.EpisodeView) -> (text: String, done: Bool)? {
        if !episode.owned { return (String(localized: .libraryItemMissingEpisode), false) }
        if episode.played { return (String(localized: .libraryItemWatched), true) }
        if episode.progressPercent != nil, episode.positionMs > 0 {
            return (String(localized: .libraryItemPosition(Formatters.clock(Double(episode.positionMs) / 1000))), false)
        }
        return nil
    }

    /// 看了一半的进度（0...1）；没看、看完、缺集为 nil
    static func partial(_ episode: API.EpisodeView) -> Double? {
        guard episode.owned, !episode.played, let percent = episode.progressPercent else { return nil }
        return Double(percent) / 100
    }

    /// 正在播的那一集播到哪（0...1）
    static func fraction(position: Int, duration: Int?) -> CGFloat {
        guard let duration, duration > 0 else { return 0 }
        return min(1, max(0, CGFloat(position) / CGFloat(duration)))
    }

    /// 还剩几分钟：向上取整，最少写 1（剩 20 秒不写「剩 0 分钟」）
    static func minutesLeft(position: Int, duration: Int) -> Int {
        max(1, Int((Double(max(0, duration - position)) / 60_000).rounded(.up)))
    }

    /// 「第 3 集 · 潮汐表」；没有集名只写集号
    static func caption(_ number: Int, name: String?) -> String {
        let code = String(localized: .mediaEpisodeNumber(number))
        guard let name, !name.isEmpty else { return code }
        return "\(code) · \(name)"
    }
}
