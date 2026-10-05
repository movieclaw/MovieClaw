import Foundation

/// 掉帧看门狗（对应 Web `lib/player/framedrop.ts`，阈值逐一照搬）。
///
/// 决策层不预测「这台设备放不放得动」，由这里的**真实证据**回答：视频直通期间持续掉帧超阈值，
/// 就把当前档报废，走既有的 failed_tiers 降档回路换转码重来。
/// - 窗口 10 秒（每秒一个样本，所以要 11 个样本才构成 10 秒的首尾差）：瞬时掉帧（seek 落点、解码起步）几秒就摊平了；
/// - 窗口内至少 100 帧：挡住「刚起播 3 掉 1 就算 33%」这类样本不足的误判；
/// - 比率 ≥ 10%：肉眼已明显卡顿，降档的代价（整路转码 + 一次换流）才值得付。
///
/// 调用方契约（否则会算出假掉帧）：后台、暂停、seek、换会话时 `reset()`；只在视频直通（copy）时喂样本。
struct FrameDropTracker {
    static let windowSamples = 10
    static let minFrames = 100
    static let ratio = 0.1

    private var history: [(dropped: Int, total: Int)] = []

    /// 喂一个累计样本；返回 nil = 没到判定条件，否则是窗口掉帧率（≥ 阈值时应降档）
    mutating func sample(dropped: Int, total: Int) -> Double? {
        if let last = history.last, total < last.total || dropped < last.dropped {
            // 累计计数变小 = 引擎换了流，旧窗口作废（调用方漏 reset 的兜底）
            history.removeAll()
        }
        history.append((dropped, total))
        if history.count > Self.windowSamples + 1 { history.removeFirst() }
        guard history.count == Self.windowSamples + 1, let first = history.first else { return nil }
        let totalDelta = total - first.total
        guard totalDelta >= Self.minFrames else { return nil }
        return Double(dropped - first.dropped) / Double(totalDelta)
    }

    mutating func reset() { history.removeAll() }
}

/// 卡顿归因看门狗（起源于 Web `lib/player/stall.ts` + `engine.ts` 的 watchStall）。
///
/// 只看「播放头不动」会把处置完全不同的几件事混为一谈：
/// - **解码卡死**：缓冲里明明还有 ≥3 秒却不走——先原地推两把（AVPlayer 会在换流 + seek 后楞住，
///   微调一下就能踢活），推不动 8 秒判「解不了」，走兜底阶梯（`FailurePolicy`）；
/// - **线路慢**：前方缓冲见底，但字节还在进来——这不是失败，一直等（转圈下显示实时加载速度，用户可以暂停攒缓冲）。
///   原来等 15 秒就判「缺粮」，进而换引擎 / 自动转码，2026-09-28《哪吒》在外网因此被一路降到系统播放器；
/// - **连接断了**：缓冲见底且连续十几秒一个字节都没收到——报 `.dead`，同引擎原地重开。
///   原文件直出 15 秒；服务端流（转码器赶片时本来就会一阵阵没有字节）给足 45 秒。
///
/// 每秒喂一次；暂停、结束、定位中、播放头前进都不算停顿。
struct StallWatch {
    static let decodeStallSeconds = 8
    static let decodeStallMinBuffer = 3.0
    static let serverDeadSeconds = 45
    static let directDeadSeconds = 15
    static let nudgeAtSeconds = 3
    static let maxNudges = 2
    static let nudgeStep = 0.1

    enum Verdict: Equatable {
        case ok
        /// 推一把：跳到当前位置 + 0.1 秒重新触发解码管线
        case nudge
        case decodeStalled
        /// 缓冲见底且持续没有字节：连接断了
        case dead
    }

    private var lastTime: Double?
    private var stalledFor = 0
    /// 缓冲见底期间连续没收到字节的秒数
    private var silentFor = 0
    private var nudges = 0
    private var sinceNudge = 99
    private var everAdvanced = false

    mutating func reset() { self = StallWatch() }

    /// - receiving: 这一秒有没有从源收到字节（引擎加载速度读数 > 0）
    /// - deadLimit: 缓冲见底后连续多少秒没字节算断线（`directDeadSeconds` / `serverDeadSeconds`）
    mutating func sample(time: Double, bufferedAhead: Double, paused: Bool, ended: Bool, seeking: Bool,
                         receiving: Bool, deadLimit: Int) -> Verdict {
        let advanced = lastTime.map { time > $0 } ?? false
        // 「真正播起来过」只认小步前进：起播定位、用户拖动是一次大跳，不算
        if advanced, !seeking, let lastTime, time - lastTime < 5 { everAdvanced = true }
        lastTime = time
        sinceNudge += 1
        if paused || ended || seeking || advanced {
            stalledFor = 0
            silentFor = 0
            // 只有远离上次推动的真实前进才算恢复——推动自己造成的播放头变化不作数
            if advanced, sinceNudge > 3 { nudges = 0 }
            return .ok
        }
        stalledFor += 1
        if bufferedAhead >= Self.decodeStallMinBuffer {
            silentFor = 0
            if stalledFor >= Self.decodeStallSeconds {
                stalledFor = 0
                nudges = 0
                return .decodeStalled
            }
            // 有数据却不动：先推一把（起播预滚阶段不推，否则会把预滚冲掉重来）
            if everAdvanced, stalledFor >= Self.nudgeAtSeconds, nudges < Self.maxNudges {
                nudges += 1
                sinceNudge = 0
                stalledFor = 0
                return .nudge
            }
            return .ok
        }
        // 缓冲见底：只看字节还在不在进来。在进来就是线路慢，不算失败
        silentFor = receiving ? 0 : silentFor + 1
        if silentFor >= deadLimit {
            stalledFor = 0
            silentFor = 0
            nudges = 0
            return .dead
        }
        return .ok
    }

    /// 判定 → 给用户看的中文原因
    static func reason(_ verdict: Verdict, deadLimit: Int) -> String {
        if verdict == .decodeStalled {
            return "播放停滞超过 \(decodeStallSeconds) 秒，这一档的码流播放器吃不下"
        }
        return deadLimit < serverDeadSeconds
            ? "连续 \(deadLimit) 秒没有收到数据——连接可能中断了"
            : "连续 \(deadLimit) 秒没有收到服务端的数据——转码可能中断了"
    }
}

/// 拖动跟随的节奏（对应 Web `lib/player/scrub-follow.ts`）：后沿落地 + 连续扫动 10Hz 兜底。
///
/// 跳转便宜（落点已在缓冲里）时，拖动途中画面跟着手指走；原文件直出拖出缓冲时只在**手指停住**
/// 60ms 后跟一次（每次 seek 都是一条新的 Range 请求，扫动途中跟只会一路抽）；其余情况松手才跳。
enum ScrubFollow {
    static let settleMs = 60
    static let maxWaitMs = 100

    enum Plan: Equatable {
        case skip
        case follow
        case deferred(ms: Int)
    }

    static func plan(nowMs: Int, lastFollowMs: Int, cheap: Bool, reachable: Bool, settleOnly: Bool) -> Plan {
        guard reachable else { return .skip }
        guard cheap else { return settleOnly ? .deferred(ms: settleMs) : .skip }
        let waited = nowMs - lastFollowMs
        if waited >= maxWaitMs { return .follow }
        return .deferred(ms: max(0, min(settleMs, maxWaitMs - waited)))
    }
}

/// 取流失败的同档重开预算（对应 Web engine.ts：hls.js 网络错误先重试几次，仍不行才 onNetworkDead）。
///
/// 「网络」归因的失败走同档原地重开（新会话 = 新 token），不降档。但归因可能出错——某档格式
/// AVPlayer 根本放不了，却被报成网络类错误——无上限地重开就会无限循环「正在准备视频流…」、
/// 反复起停服务端会话。所以：连续重开 `limit` 次都没能真正出画，就不再信「网络」归因，
/// 交给调用方按「这一档放不了」降档。任何一次进入播放态都把计数清零。
struct NetworkRestartBudget {
    static let limit = 2

    private(set) var consecutive = 0

    /// 又一次网络类失败：还能同档重开返回 true（并记一次），预算用完返回 false
    mutating func allowRestart() -> Bool {
        guard consecutive < Self.limit else { return false }
        consecutive += 1
        return true
    }

    /// 真正放起来了：之前的失败不再算「连续」
    mutating func reachedPlaying() { consecutive = 0 }

    /// 换单元 / 用户手动重试：从头计
    mutating func reset() { consecutive = 0 }
}

/// 引擎报「播完」时离片尾还远：是取流断了，不是真播完，不能弹「即将播放下一集」。
///
/// 典型现场（2026-09-27 真机，当时的 MPV 播放器）：直出放到一半，服务端重启约 20 秒，反向代理回 502，重连失败就把
/// 断流当成文件结尾，放完缓存后报 eof，播放器随即弹出「即将播放下一集」、紧跟着换到下一集。
/// 这种「播完」一律从当前位置重开（新会话、新 token），观众只看到一次短暂的缓冲。
///
/// 片长信息本身可能不准（个别文件容器里写的时长偏长）：重开后在原地附近又报播完，就认定真到了结尾，
/// 不在片尾反复重开。
struct PrematureEndGuard {
    /// 离片尾超过这么远才算「没播完」；也是「原地附近」的判定半径
    static let marginMs = 30000

    private var resumedAtMs: Int?

    /// 该当作断流、从当前位置重开时返回 true（并记下重开点）；真播完返回 false
    mutating func shouldResume(positionMs: Int, durationMs: Int?) -> Bool {
        guard let durationMs, durationMs - positionMs > Self.marginMs else { return false }
        if let resumedAtMs, abs(positionMs - resumedAtMs) < Self.marginMs { return false }
        resumedAtMs = positionMs
        return true
    }

    /// 换单元：从头计
    mutating func reset() { resumedAtMs = nil }
}

/// 播放中重开（断线、服务端重启）时服务端暂时连不上：退避自动重试，累计约 1 分钟仍连不上才落到错误页。
///
/// 服务端重启（应用内更新、重新部署）要停机二三十秒；引擎自己的断线重连扛不住更久的停机时，控制器会原地重开，
/// 这一刻服务端多半还没起来——不重试就直接报错，观众得自己点「重试」，而服务端几秒后其实就回来了。
/// 只在「已经播起来过」的单元上用；起播就连不上照旧立刻报错（多半是地址或网络本身不对）。
struct ReconnectBackoff {
    static let delays: [Double] = [2, 4, 8, 15, 15, 15]

    private var index = 0

    /// 下一次重试前等多少秒；用完返回 nil
    mutating func nextDelay() -> Double? {
        guard index < Self.delays.count else { return nil }
        defer { index += 1 }
        return Self.delays[index]
    }

    /// 重新播起来了 / 换单元 / 用户手动重试：从头计
    mutating func reset() { index = 0 }
}
