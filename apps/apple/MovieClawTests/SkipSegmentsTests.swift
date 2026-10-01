import Foundation
import Testing
@testable import MovieClaw

/// 跳过片头 / 片尾的客户端逻辑（docs/design/skip-intro.md）。对照 Web `test/player-skip-segments.test.mjs`
/// 的同一组用例，两端行为必须一致；另验证 App 解码带 / 不带 `segments` 的会话响应（旧服务端没有这个字段）。
struct SkipSegmentsTests {
    private func segment(_ type: String, _ start: Int, _ end: Int, toEnd: Bool = false) -> API.PlaybackSegmentView {
        .init(type: type, startMs: start, endMs: end, toEnd: toEnd)
    }

    private var ad: API.PlaybackSegmentView { segment("other", 0, 20_000) }
    private var intro: API.PlaybackSegmentView { segment("intro", 60_000, 150_000) }
    private var credits: API.PlaybackSegmentView { segment("outro", 2_550_000, 2_700_000, toEnd: true) }
    private var midOutro: API.PlaybackSegmentView { segment("outro", 2_400_000, 2_500_000) }

    @Test func introRangeGivesSkipIntroAndNothingOutside() {
        #expect(SkipSegments.active([intro], at: 59_999) == nil)
        #expect(SkipSegments.active([intro], at: 60_000) == intro)
        #expect(SkipSegments.label(SkipSegments.active([intro], at: 100_000)!) == "跳过片头")
        #expect(SkipSegments.active([intro], at: 150_000) == nil)
    }

    @Test func buttonHidesInLastThreeSeconds() {
        #expect(SkipSegments.active([intro], at: 150_000 - SkipSegments.tailMs - 1) == intro)
        #expect(SkipSegments.active([intro], at: 150_000 - SkipSegments.tailMs) == nil)
    }

    @Test func sponsorAdIsSkipIntroAndMidOutroIsSkipOutro() {
        #expect(SkipSegments.label(SkipSegments.active([ad, intro], at: 5_000)!) == "跳过片头")
        #expect(SkipSegments.label(SkipSegments.active([midOutro], at: 2_450_000)!) == "跳过片尾")
    }

    @Test func autoNextOnlyCountsDownInDetectedCreditsAndStopsAfterStreak() {
        #expect(SkipSegments.autoNextMs == 8000)
        #expect(!SkipSegments.autoNextArmed([credits], at: 2_549_999, streak: 0))
        #expect(SkipSegments.autoNextArmed([credits], at: 2_560_000, streak: 0))
        #expect(SkipSegments.autoNextArmed([credits], at: 2_560_000, streak: SkipSegments.autoNextMaxStreak - 1))
        #expect(!SkipSegments.autoNextArmed([credits], at: 2_560_000, streak: SkipSegments.autoNextMaxStreak))
        #expect(!SkipSegments.autoNextArmed([midOutro], at: 2_450_000, streak: 0))
        #expect(!SkipSegments.autoNextArmed(nil, at: 2_690_000, streak: 0))
    }

    @Test func creditsToEndGoToUpNextCardNotSkipButton() {
        #expect(SkipSegments.active([credits], at: 2_600_000) == nil)
        #expect(!SkipSegments.isInOutro([credits], at: 2_549_999))
        #expect(SkipSegments.isInOutro([credits], at: 2_550_000))
        #expect(!SkipSegments.isInOutro([midOutro], at: 2_450_000))
    }

    @Test func missingSegmentsGiveNothing() {
        #expect(SkipSegments.active(nil, at: 1_000) == nil)
        #expect(SkipSegments.active([], at: 1_000) == nil)
        #expect(!SkipSegments.isInOutro(nil, at: 1_000))
    }

    @Test func sessionDecodesWithAndWithoutSegments() throws {
        // 最小的会话响应：旧服务端没有 segments 字段，新 App 也要能解开（否则整个起播都失败）
        let base = """
        {"decision":{"outcome":"rejected","audio_tracks":[],"subtitles":[],"reason":"x"},
         "start_ms":0,"timeline":"session","subtitle_urls":[],"chapters":[]
        """
        let old = try JSONDecoder().decode(API.PlaybackSessionView.self, from: Data((base + "}").utf8))
        #expect(old.segments == nil)
        let new = try JSONDecoder().decode(
            API.PlaybackSessionView.self,
            from: Data((base + ##","segments":[{"type":"intro","start_ms":1000,"end_ms":9000,"to_end":false}]}"##).utf8)
        )
        #expect(new.segments == [segment("intro", 1000, 9000)])
    }
}
