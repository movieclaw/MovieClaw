import Foundation

/// 跳过片头 / 片尾（docs/design/skip-intro.md）：服务端整季比对认出来的区间随播放会话下发，
/// 客户端只管按播放位置用，**不做任何计算**。逻辑逐条对照 Web `lib/player/timeline.ts`
/// 里的 `activeSkipSegment` / `isInOutro` / `skipLabel`。
///
/// 区间类型：
/// - `intro` 片头：位置在区间里显示「跳过片头」，点了跳到区间结束处；
/// - `outro` 片尾：到起点就提前显示「即将播放下一集」（`toEnd` 为真，片尾一直放到文件结尾）；
///   `toEnd` 为假时片尾后面还有内容（下集预告、彩蛋），按钮是「跳过片尾」；
/// - `other` 其他重复段（片头前的冠名广告、发行许可）：只会出现在片头窗里，观众眼里也是片头，
///   同样显示「跳过片头」（只写「跳过」看不出跳的是什么，用户反馈 2026-10-01）。
enum SkipSegments {
    /// 离区间尾不足这么多毫秒就不再给「跳过」：按下去只省一两秒，还会撞上区间尾的画面切换
    static let tailMs = 3000

    /// 当前位置该给哪个「跳过」按钮；一直放到结尾的片尾不在这里，交给「即将播放」卡片
    /// （`isInOutro`），两个按钮不同时出现。旧服务端没有这个字段（nil）、没有区间时返回 nil
    static func active(_ segments: [API.PlaybackSegmentView]?, at positionMs: Int) -> API.PlaybackSegmentView? {
        segments?.first { segment in
            if segment.type == "outro" && segment.toEnd { return false }
            return positionMs >= segment.startMs && positionMs < segment.endMs - tailMs
        }
    }

    /// 已经进了一直放到结尾的片尾：「即将播放」卡片不必等到最后 40 秒
    static func isInOutro(_ segments: [API.PlaybackSegmentView]?, at positionMs: Int) -> Bool {
        segments?.contains { $0.type == "outro" && $0.toEnd && positionMs >= $0.startMs } ?? false
    }

    /// 「跳过」按钮的文案
    static func label(_ segment: API.PlaybackSegmentView) -> String {
        segment.type == "outro" ? "跳过片尾" : "跳过片头"
    }
}
