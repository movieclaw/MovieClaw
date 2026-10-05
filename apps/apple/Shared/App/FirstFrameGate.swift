import Observation
import QuartzCore

/// 冷启动首帧闸门：一批「不急」的启动工作等主界面第一帧提交上屏之后再开始。
///
/// 为什么：冷启动时主线程要搭主界面、画落地页；这时若同时处理落地页的十几个接口响应、几十张图片完成、
/// 别的页签的图片预热、角标轮询，主线程一直满载，Core Animation 等不到提交事务的空档——模拟器实测
/// 发现页落地时第一帧要到 main 之后约 1.7 秒才上屏，之前一直是启动画面。先把第一帧（落地页骨架或快照）
/// 送上屏，再做这些事，首帧时间回到几百毫秒（Apple 建议首帧 400ms 内）。
///
/// 判定「提交过」：挂一个 RunLoop 观察者，排在 Core Animation 提交事务（beforeWaiting）之后。
/// 闸门只开一次，之后 `wait()` 立即返回。
enum FirstFrameGate {
    /// 给视图读的开闸状态（可观察）：冷启动落地页据此先画骨架、开闸后下一帧再画完整内容
    @Observable final class State {
        fileprivate(set) var opened = false
    }

    static let state = State()
    private static var opened = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    private static var observing = false

    /// 等主界面第一帧上屏（已上屏则立即返回）。只等不布防：布防由根视图出现时做，
    /// 免得在界面还没搭起来的某个空档里提前开闸
    static func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 根视图出现时调用：下一次事务提交之后开闸
    static func observeNextCommit() {
        guard !opened, !observing else { return }
        observing = true
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { _, _ in
            MainActor.assumeIsolated { open() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func open() {
        guard !opened else { return }
        opened = true
        state.opened = true
        PerfTrace.record("gate.firstFrame")
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
