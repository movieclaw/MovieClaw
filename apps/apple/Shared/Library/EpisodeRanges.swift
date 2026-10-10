import Foundation

/// 长剧集分段选集的一段（docs/design/long-season-episode-ranges.md）：按集号每 50 集一段，段名用段内实际首末集号
struct EpisodeRange: Hashable, Identifiable, Sendable {
    let index: Int
    let first: Int
    let last: Int

    var id: Int { index }
    var label: String { "\(first)–\(last)" }

    func contains(_ episodeNumber: Int) -> Bool { EpisodeRanges.index(of: episodeNumber) == index }
}

enum EpisodeRanges {
    static let size = 50

    static func index(of episodeNumber: Int) -> Int { max(0, episodeNumber - 1) / size }

    /// 一季的段：超过 50 集才分段，否则为空（界面保持改版前的样子）；空段不出现
    static func ranges(_ episodes: [API.EpisodeView]) -> [EpisodeRange] {
        guard episodes.count > size else { return [] }
        var result: [EpisodeRange] = []
        for number in episodes.map(\.episodeNumber).sorted() {
            let index = index(of: number)
            if let last = result.last, last.index == index {
                result[result.count - 1] = EpisodeRange(index: index, first: last.first, last: number)
            } else {
                result.append(EpisodeRange(index: index, first: number, last: number))
            }
        }
        return result
    }

    /// 某集所在的段
    static func range(containing episodeNumber: Int, in ranges: [EpisodeRange]) -> EpisodeRange? {
        ranges.first { $0.contains(episodeNumber) }
    }

    /// 进某一段时落在哪一集：段里有锚点就是锚点，否则段首
    static func entry(of range: EpisodeRange, anchor: Int?) -> Int {
        if let anchor, range.contains(anchor) { return anchor }
        return range.first
    }
}

extension API.SeasonEpisodesView {
    /// 本季接着看的那一集：服务端给的锚点优先（同首页「接下来继续」的规则）；本季没播放过、或旧服务端没给时退回客户端规则
    var anchorEpisode: API.EpisodeView? {
        if let number = resumeEpisode, let episode = episodes.first(where: { $0.episodeNumber == number }) {
            return episode
        }
        return episodes.resumeEpisode
    }
}
