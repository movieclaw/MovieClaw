import Foundation
import Testing
@testable import MovieClaw

/// 长剧集分段选集的段与锚点（`EpisodeRanges`、`SeasonEpisodesView.anchorEpisode`），口径见
/// docs/design/long-season-episode-ranges.md：超过 50 集才分段、按集号每 50 集一段、空段不出现、段名用段内实际首末集号；
/// 锚点服务端优先，没给才退回客户端规则。
struct EpisodeRangesTests {
    private func episode(_ number: Int, owned: Bool = true, played: Bool = false, positionMs: Int = 0) -> API.EpisodeView {
        API.EpisodeView(episodeNumber: number, name: nil, overview: nil, airDate: nil, stillUrl: nil, owned: owned,
                        fileIds: owned ? [number] : [], positionMs: positionMs, played: played,
                        progressPercent: positionMs > 0 ? 42 : nil)
    }

    private func season(_ numbers: [Int]) -> [API.EpisodeView] { numbers.map { episode($0) } }

    @Test func fiftyOrFewerEpisodesAreNotSegmented() {
        #expect(EpisodeRanges.ranges([]).isEmpty)
        #expect(EpisodeRanges.ranges(season(Array(1...12))).isEmpty)
        #expect(EpisodeRanges.ranges(season(Array(1...50))).isEmpty)
        #expect(EpisodeRanges.ranges(season(Array(1...51))).map(\.label) == ["1–50", "51–51"])
    }

    @Test func longSeasonSplitsEveryFiftyByEpisodeNumber() {
        let ranges = EpisodeRanges.ranges(season(Array(1...1186)))
        #expect(ranges.count == 24)
        #expect(ranges.map(\.index) == Array(0..<24))
        #expect(ranges.first?.label == "1–50")
        #expect(ranges[20].label == "1001–1050")
        #expect(ranges.last?.label == "1151–1186")
        // 集号决定段，与列表里的顺序无关
        #expect(EpisodeRanges.ranges(season(Array(1...120).reversed())).map(\.label) == ["1–50", "51–100", "101–120"])
    }

    @Test func emptyRangesAreSkippedAndLabelsUseActualBounds() {
        let ranges = EpisodeRanges.ranges(season(Array(3...10) + Array(200...260)))
        #expect(ranges.map(\.index) == [0, 3, 4, 5])
        #expect(ranges.map(\.label) == ["3–10", "200–200", "201–250", "251–260"])
    }

    @Test func rangeLookupAndEntry() {
        let ranges = EpisodeRanges.ranges(season(Array(1...1186)))
        #expect(EpisodeRanges.index(of: 1) == 0)
        #expect(EpisodeRanges.index(of: 50) == 0)
        #expect(EpisodeRanges.index(of: 51) == 1)
        #expect(EpisodeRanges.index(of: 0) == 0)
        #expect(EpisodeRanges.range(containing: 1050, in: ranges)?.label == "1001–1050")
        #expect(EpisodeRanges.range(containing: 1051, in: ranges)?.label == "1051–1100")
        #expect(EpisodeRanges.range(containing: 2000, in: ranges) == nil)
        #expect(ranges[20].contains(1001) && ranges[20].contains(1050) && !ranges[20].contains(1051))
        // 手动换段：段里有锚点落锚点，否则段首
        #expect(EpisodeRanges.entry(of: ranges[20], anchor: 1050) == 1050)
        #expect(EpisodeRanges.entry(of: ranges[21], anchor: 1050) == 1051)
        #expect(EpisodeRanges.entry(of: ranges[0], anchor: nil) == 1)
        let sparse = EpisodeRanges.ranges(season(Array(3...10) + Array(200...260)))
        #expect(EpisodeRanges.entry(of: sparse[0], anchor: 120) == 3)
    }

    /// 柯南夹具：1–1049 看完（第 3 集没看、第 120 集看到一半弃了），1050 看到 42% 且最近播放，服务端锚点 1050
    @Test func serverAnchorWinsOverClientScan() {
        let episodes = (1...1186).map { n in
            episode(n, owned: !(n % 97 == 0 || (301...304).contains(n)),
                    played: n < 1050 && n != 3 && n != 120, positionMs: n == 1050 || n == 120 ? 600_000 : 0)
        }
        let withServer = API.SeasonEpisodesView(seasonNumber: 1, episodes: episodes, resumeEpisode: 1050)
        #expect(withServer.anchorEpisode?.episodeNumber == 1050)
        // 服务端没给（本季没播放过 / 旧服务端）：退回客户端规则——第一个看了一半的
        let withoutServer = API.SeasonEpisodesView(seasonNumber: 1, episodes: episodes, resumeEpisode: nil)
        #expect(withoutServer.anchorEpisode?.episodeNumber == 120)
        // 服务端给的集号不在列表里：同样退回客户端规则
        let stale = API.SeasonEpisodesView(seasonNumber: 1, episodes: episodes, resumeEpisode: 5000)
        #expect(stale.anchorEpisode?.episodeNumber == 120)
        // 客户端规则：没有看了一半的 → 第一个没看过的（有片源的优先）→ 第一集
        let fresh = API.SeasonEpisodesView(seasonNumber: 1, episodes: [episode(1, owned: false), episode(2, played: true), episode(3)], resumeEpisode: nil)
        #expect(fresh.anchorEpisode?.episodeNumber == 3)
        #expect(API.SeasonEpisodesView(seasonNumber: 1, episodes: [], resumeEpisode: nil).anchorEpisode == nil)
    }
}
