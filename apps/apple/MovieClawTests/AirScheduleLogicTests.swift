import Foundation
import Testing
@testable import MovieClaw

/// 播出日历的口径（`AirSchedule`、`AirSummary`、`QuickSubscribe`，iPhone、Mac、Apple TV 共用；issue #547）。
/// 日期都相对 2026-11-05（周四），文案断言不写死语言的部分比结构，写死的只跑中文（默认测试计划是中文）
struct AirScheduleLogicTests {
    private let today = "2026-11-05"

    private func date(_ offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: AirSchedule.date(today)!.addingTimeInterval(TimeInterval(offset) * 86400))
    }

    private func episode(_ number: Int, _ offset: Int?, owned: Bool = false) -> API.EpisodeView {
        API.EpisodeView(episodeNumber: number, name: nil, overview: nil, airDate: offset.map(date), stillUrl: nil, owned: owned,
                        fileIds: owned ? [number] : [], positionMs: 0, played: false, progressPercent: nil)
    }

    private func schedule(missing: [Int] = [], subscription: Int? = nil, weekdays: [Int] = [], last: Int? = nil,
                          arrivals: [API.EpisodeArrivalView] = [], region: String? = nil) -> API.SeasonAirScheduleView {
        API.SeasonAirScheduleView(today: today, region: region, weekdays: weekdays, lastAirDate: last.map(date),
                                  subscriptionId: subscription, missingEpisodes: missing, arrivals: arrivals)
    }

    @Test func unairedEpisodesAreNotMissing() {
        let subscribed = schedule(missing: [7], subscription: 5)
        #expect(AirSchedule.tone(episode(1, -3, owned: true), subscribed) == .owned)
        #expect(AirSchedule.tone(episode(7, -3), subscribed) == .missing)
        #expect(AirSchedule.tone(episode(8, -3), subscribed) == .absent)
        #expect(AirSchedule.tone(episode(9, 0), subscribed) == .today)
        #expect(AirSchedule.tone(episode(9, 0), schedule()) == .todayFree)
        #expect(AirSchedule.tone(episode(10, 2), subscribed) == .upcoming)
        #expect(AirSchedule.tone(episode(11, nil), subscribed) == .upcoming)

        #expect(AirSchedule.isUnaired(episode(9, 0), subscribed))
        #expect(AirSchedule.isUnaired(episode(10, 2), subscribed))
        #expect(AirSchedule.isUnaired(episode(11, nil), subscribed))
        #expect(!AirSchedule.isUnaired(episode(9, 0, owned: true), subscribed), "库里有的不算")
        #expect(!AirSchedule.isUnaired(episode(7, -3), subscribed), "真缺的不算")
        #expect(!AirSchedule.isUnaired(episode(10, 2), nil), "没有日历时库里没有的一律按缺集")
        #expect(AirSchedule.airsToday(episode(9, 0), subscribed))
        #expect(!AirSchedule.airsToday(episode(10, 2), subscribed))
        #expect(!AirSchedule.airsToday(episode(9, 0), nil))
    }

    @Test func rowsInsertGroupsAndGapsInOrder() {
        let weekly = schedule(weekdays: [3, 4])
        let days = AirSchedule.airDays([episode(1, 0), episode(2, 1), episode(3, 7), episode(4, 14), episode(5, 28)], weekly)
        let shape: [String] = AirSchedule.rows(days, weekly, grouped: true).map {
            switch $0 {
            case let .group(group): "group\(group)"
            case .gap: "gap"
            case let .day(day): "day\(day.episodes[0].episodeNumber)"
            }
        }
        // 周四、周五、下周四；再往后都算「之后」；跳过了更新日的两处标停更（周五到下周四之间的周更空档不算）
        #expect(shape == ["group0", "day1", "day2", "group1", "day3", "group2", "gap", "day4", "gap", "day5"])
        #expect(!AirSchedule.rows(days, weekly, grouped: false).contains { if case .group = $0 { true } else { false } }, "已播展开时不分组")
        #expect(Set(AirSchedule.rows(days, weekly, grouped: true).map(\.id)).count == 10, "行的标识不重复（SwiftUI ForEach、焦点都靠它）")
    }

    @Test func gapOnlyMarksSkippedUpdateDays() {
        #expect(AirSchedule.gap(date(0), date(7), weekdays: [3]) == nil, "周更的下一周不算停更")
        #expect(AirSchedule.gap(date(0), date(14), weekdays: [3]) != nil)
        let daily = Array(0...6)
        #expect(AirSchedule.gap(date(0), date(1), weekdays: daily) == nil)
        #expect(AirSchedule.gap(date(0), date(2), weekdays: daily) != nil)
    }

    @Test func statusAndDotFollowDayState() {
        let tracked = schedule(missing: [7], subscription: 5, last: 2)
        func day(_ item: API.EpisodeView) -> AirDay { AirSchedule.airDays([item], tracked)[0] }
        func status(_ item: API.EpisodeView) -> String { String(describing: AirSchedule.status(day(item), tracked)) }
        #expect(status(episode(1, -2, owned: true)) == "owned")
        #expect(AirSchedule.dot(day(episode(1, -2, owned: true)), tracked) == .owned)
        #expect(status(episode(7, -2)) == "missing")
        #expect(AirSchedule.dot(day(episode(7, -2)), tracked) == .missing)
        #expect(status(episode(8, -2)) == "absent")
        #expect(status(episode(9, 1)).hasPrefix("relative"))
        #expect(AirSchedule.dot(day(episode(9, 1)), tracked) == .upcoming)
        #expect(AirSchedule.dot(day(episode(10, 2)), tracked) == .finale)
        #expect(AirSchedule.dot(day(episode(11, 0)), tracked) == .today)
    }

    @Test func canFindNeedsSubscriptionGapAndPermission() {
        let tracked = schedule(missing: [7], subscription: 5)
        #expect(AirSchedule.canFind(tracked, canSubscribe: true))
        #expect(!AirSchedule.canFind(tracked, canSubscribe: false))
        #expect(!AirSchedule.canFind(schedule(missing: [7]), canSubscribe: true))
        #expect(!AirSchedule.canFind(schedule(subscription: 5), canSubscribe: true))
    }

    @Test func pastSummaryFoldsAiredDays() {
        let tracked = schedule(missing: [2], subscription: 5)
        let summary = AirPastSummary(AirSchedule.airDays([episode(1, -3, owned: true), episode(2, -2), episode(3, -1, owned: true)], tracked), tracked)
        #expect(summary.missing == [2])
        #expect(summary.owned == 2)
        #expect(summary.total == 3)
        #expect(!summary.allOwned)
        #expect(AirPastSummary([], tracked).aired.isEmpty)
    }

    @Test func summaryPicksNextDayAndSide() {
        let later = AirSummary(episodes: [episode(1, -7, owned: true), episode(2, 6)], schedule: schedule(weekdays: [2], last: 6, region: "US"))
        #expect(later.next?.date == date(6))
        #expect(later.next?.finale == true)
        #expect(later.side?.caption?.contains(AirSchedule.regionName("US")) == true)
        #expect(later.side?.large == false)
        #expect(later.metaShort != later.metaFull, "写得下时带上节奏与完结日")

        let downloading = AirSummary(episodes: [episode(13, 0), episode(14, 0)],
                                     schedule: schedule(subscription: 5, arrivals: [.init(episodeNumber: 13, stage: "downloading", expectedAt: nil)]))
        #expect(downloading.next?.today == true)
        #expect(downloading.side?.value == String(localized: .libraryItemAirDownloading))

        let owned = AirSummary(episodes: [episode(13, 0, owned: true)], schedule: schedule(subscription: 5))
        #expect(owned.side?.value == String(localized: .libraryItemAirLegendOwned))
    }

    @Test func expectedArrivalIsOnlyForEpisodesStillWaiting() {
        let soon = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(120))
        let tracked = schedule(subscription: 5, arrivals: [.init(episodeNumber: 13, stage: "waiting", expectedAt: soon)])
        #expect(AirSchedule.expectedAt([episode(13, 0)], tracked) == soon)
        #expect(AirSchedule.expectedAt([episode(13, 0, owned: true)], tracked) == nil, "入库了就不预告")
        let inFlight = schedule(subscription: 5, arrivals: [.init(episodeNumber: 13, stage: "waiting", expectedAt: soon), .init(episodeNumber: 14, stage: "organizing", expectedAt: nil)])
        #expect(AirSchedule.expectedAt([episode(13, 0), episode(14, 0)], inFlight) == nil, "有在途的就讲在途")
        #expect(AirSchedule.expectedAt([episode(13, 0)], schedule(arrivals: tracked.arrivals)) == nil, "没订阅不预告")
    }

    @Test func quickSubscribeUsesTheSameDefaultsAsTheSheet() throws {
        let media = API.MediaBrief(mediaItemId: 1, kind: "tv", tmdbId: 42, doubanId: nil, title: "长街夜行", originalTitle: "长街夜行",
                                   englishTitle: nil, year: 2026, posterUrl: nil, backdropUrl: nil, logoUrl: nil, status: "Returning Series")
        let seasons = [
            API.SeasonOverview(seasonNumber: 0, name: "", airDate: nil, episodeCount: 3, airedCount: 3, ownedCount: 0),
            API.SeasonOverview(seasonNumber: 1, name: "", airDate: nil, episodeCount: 10, airedCount: 10, ownedCount: 0),
            API.SeasonOverview(seasonNumber: 2, name: "", airDate: nil, episodeCount: 8, airedCount: 0, ownedCount: 0),
        ]
        let plan = try JSONDecoder().decode(API.SmartPlanView.self, from: Data("""
        {"configured":true,"profile_revision":3,"memory_revision":9,"quality_label":"4K","wait_label":"1d","subtitle_line":"zh","scope_options":[],"can_edit":true}
        """.utf8))
        func prepared(status: String = "ready", media: API.MediaBrief?, seasons: [API.SeasonOverview], suggested: [Int] = [], smart: API.SmartPlanView?) -> API.PrepareView {
            API.PrepareView(status: status, media: media, seasons: seasons, existingSubscriptionId: nil, movieOwned: false,
                            suggestedSeasons: suggested, candidates: [], doubanEpisodes: nil, smart: smart)
        }

        let draft = try #require(QuickSubscribe(prepared(media: media, seasons: seasons, smart: plan)))
        #expect(draft.seasons == [1], "全部已播正季，不带特别篇和没播的季")
        #expect(draft.followFuture, "在播剧自动续订")
        #expect(draft.quality == ["4K", "1d", "zh"])
        let payload = draft.payload(libraryId: 3)
        #expect(payload.titleRef == "tmdb:tv:42")
        #expect(payload.selectedSeasons == [1])
        #expect(payload.followFuture == true)
        #expect(payload.libraryId == 3)
        #expect(payload.selectionMode == "smart")
        #expect(payload.smartProfileRevision == 3)
        #expect(payload.smartMemoryRevision == 9)
        #expect(payload.smartLanguageAnswer == nil, "没有问题时不回答")

        #expect(QuickSubscribe(prepared(media: media, seasons: seasons, suggested: [2], smart: plan))?.seasons == [2], "采信服务端建议的季")
        #expect(QuickSubscribe(prepared(media: media, seasons: seasons, smart: nil))?.payload(libraryId: nil).selectionMode == "rules", "服务器不带智能摘要时按规则模式")

        var unaired = media
        unaired.status = "In Production"
        let future = try #require(QuickSubscribe(prepared(media: unaired, seasons: [seasons[2]], smart: plan)))
        #expect(future.seasons.isEmpty)
        #expect(future.followFuture, "一季都还没播只能从新集追起，否则这里没地方改选项")
        #expect(QuickSubscribe(prepared(status: "not_found", media: nil, seasons: [], smart: nil)) == nil)
    }
}
