import Foundation
import Testing
@testable import MovieClaw

/// 跳过片头 / 片尾的客户端逻辑（docs/design/skip-intro.md）。对照 Web `test/player-skip-segments.test.mjs`
/// 的同一组用例，两端行为必须一致；另验证 App 解码带 / 不带 `segments` 的会话响应（旧服务端没有这个字段）。
struct SkipSegmentsTests {
    private func segment(_ type: String, _ start: Int, _ end: Int, toEnd: Bool = false) -> API.PlaybackSegmentView {
        .init(type: type, startMs: start, endMs: end, toEnd: toEnd)
    }

    private var ad: API.PlaybackSegmentView { segment("ad", 0, 20_000) }
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

    @Test func labelsFollowRecognizedType() {
        #expect(SkipSegments.label(SkipSegments.active([ad, intro], at: 5_000)!) == "跳过广告")
        #expect(SkipSegments.label(segment("preview", 0, 20_000)) == "跳过预告")
        #expect(SkipSegments.label(segment("other", 0, 20_000)) == "跳过此段")
        #expect(SkipSegments.label(segment("future-type", 0, 20_000)) == "跳过此段")
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

    @Test func adsAndPreviewsNeverAutoAdvance() {
        for type in ["ad", "preview", "other"] {
            let value = segment(type, 2_550_000, 2_700_000, toEnd: true)
            #expect(SkipSegments.active([value], at: 2_600_000) == value)
            #expect(!SkipSegments.autoNextArmed([value], at: 2_600_000, streak: 0))
        }
    }

    @Test func separatedAdAndIntroPreserveStoryInBetween() {
        #expect(SkipSegments.active([ad, intro], at: 5_000)?.endMs == 20_000)
        #expect(SkipSegments.active([ad, intro], at: 30_000) == nil)
        #expect(SkipSegments.active([ad, intro], at: 70_000)?.endMs == 150_000)
    }

    @Test func manualSkipTakesPriorityOverLastFortySecondsCard() {
        for type in ["preview", "ad", "outro", "other"] {
            let value = segment(type, 2_660_000, 2_690_000)
            #expect(!SkipSegments.shouldShowUpNext([value], at: 2_670_000, durationMs: 2_700_000))
            #expect(SkipSegments.shouldShowUpNext([value], at: 2_690_000, durationMs: 2_700_000))
            #expect(SkipSegments.shouldShowUpNext([value], at: 2_700_000, durationMs: 2_700_000, ended: true))
        }
        #expect(SkipSegments.shouldShowUpNext([], at: 2_670_000, durationMs: 2_700_000))
        #expect(SkipSegments.shouldShowUpNext([credits], at: 2_600_000, durationMs: 2_700_000))
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
        for type in ["ad", "preview", "other", "future-type"] {
            let json = base + ",\"segments\":[{\"type\":\"\(type)\",\"start_ms\":1000,\"end_ms\":9000,\"to_end\":false}]}"
            let decoded = try JSONDecoder().decode(API.PlaybackSessionView.self, from: Data(json.utf8))
            #expect(decoded.segments == [segment(type, 1000, 9000)])
        }
    }
}
