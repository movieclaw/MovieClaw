import Foundation

/// 起播分段计时：从进入播放器（或换集、降档重来）到第一帧上屏，每一段花了多少毫秒。
///
/// 「点了播放多久出画」是播放器最要紧的体感，只有一个首帧总数（QoE 的 ttff）没法知道慢在哪：
/// 服务端决策、开会话（关键帧采样、拉起 ffmpeg）、引擎读文件头 / 播放列表、定位续播点、首帧解码……
/// 这里按发生顺序记下每个点距起点的毫秒数，首帧一出就整条上报服务端日志
/// （`client-log` 的 startup 事件，NAS 按天日志里一行「起播分段」），开发期同时打到控制台。
///
/// 只记第一次出画：之后的 seek、换轨、降档不在这里算（它们有各自的 QoE 口径）。
struct StartupTrace {
    /// 一个计时点：名字 + 距起点的毫秒数
    struct Mark {
        let name: String
        let ms: Int
    }

    private var origin: ContinuousClock.Instant?
    private(set) var marks: [Mark] = []
    /// 已经上报过（每个单元只报一次）
    private(set) var reported = false

    /// 开始计时（重复调用不重置：降档重来也算在同一次起播里）。
    /// `at`：起点时刻，默认此刻；第一个单元传用户点播放的时刻
    mutating func begin(at instant: ContinuousClock.Instant = .now) {
        guard origin == nil else { return }
        origin = instant
    }

    /// 记一个点；同名点只记第一次（引擎事件可能重复到达）。
    /// `at`：事件实际发生的时刻（在后台完成、回到主线程才来记的网络往返用它，不把排队时间算进去）
    mutating func mark(_ name: String, at instant: ContinuousClock.Instant = .now) {
        guard let origin, !reported, !marks.contains(where: { $0.name == name }) else { return }
        marks.append(Mark(name: name, ms: Int((instant - origin) / .milliseconds(1))))
        marks.sort { $0.ms < $1.ms }
    }

    func has(_ name: String) -> Bool { marks.contains { $0.name == name } }

    /// 距起点多少毫秒（开发期细分计时用，不进上报）
    var elapsedMs: Int? {
        origin.map { Int((ContinuousClock.now - $0) / .milliseconds(1)) }
    }

    /// 标记为已上报，返回要上报的计时点（没有起点或已报过时为 nil）
    mutating func finish() -> [Mark]? {
        guard origin != nil, !reported else { return nil }
        reported = true
        return marks
    }

    /// 控制台用的一行摘要：「决策 120 → 会话 480 → 引擎 530 → 就绪 760 → 首帧 1020 毫秒」
    static func summary(_ marks: [Mark]) -> String {
        marks.map { "\($0.name) \($0.ms)" }.joined(separator: " → ") + " 毫秒"
    }
}
