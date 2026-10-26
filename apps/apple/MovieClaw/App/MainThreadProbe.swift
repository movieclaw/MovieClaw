#if DEBUG
import Foundation

/// 开发期：主线程占用探针（`-mcMainProbe YES`）。起播路径上引擎有好几跳要回主线程，主线程被别的活占着时
/// 每一跳都要排队（真机：点播放就发请求，会话回来后等了约 50 毫秒才轮到建引擎）。这里从打开播放器起 3 秒内，
/// 每 4 毫秒往主线程投一个空任务，记下它排了多久；排队超过 8 毫秒的打一行 `[MainBusy]`，
/// 与 `[StartupDiag]` 对照就能看出哪一段主线程在忙、忙了多久。
nonisolated enum MainThreadProbe {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "mcMainProbe") }

    /// 排队样本（投出时刻、排了多久，毫秒）；只在主线程上读写，加锁只为让编译器放心跨闭包传递
    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(at: Int, waited: Int)] = []
        func append(at: Int, waited: Int) { lock.lock(); items.append((at, waited)); lock.unlock() }
        var all: [(at: Int, waited: Int)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    static func run(seconds: Double = 3) {
        guard enabled else { return }
        let origin = DispatchTime.now()
        let queue = DispatchQueue(label: "movieclaw.main-probe", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let box = Samples()
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        // 回调在探针自己的后台队列上跑：闭包不能带主线程隔离（工程默认 MainActor，带着就会被运行时断言杀掉）
        timer.setEventHandler { @Sendable in
            let sent = DispatchTime.now()
            DispatchQueue.main.async { @Sendable in
                let waited = Int((DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000)
                guard waited >= 8 else { return }
                let at = Int((sent.uptimeNanoseconds - origin.uptimeNanoseconds) / 1_000_000)
                box.append(at: at, waited: waited)
            }
        }
        timer.resume()
        queue.asyncAfter(deadline: .now() + seconds) { @Sendable in
            timer.cancel()
            DispatchQueue.main.async { @Sendable in
                let all = box.all
                // 相邻的排队样本归成一段：一段从第一个排队任务投出算起，到这一段里最晚被执行的任务为止
                var line: [String] = []
                var start = -1, until = -1
                for s in all.sorted(by: { $0.at < $1.at }) {
                    if start < 0 || s.at > until + 4 {
                        if start >= 0 { line.append("\(start)+\(until - start)") }
                        start = s.at
                    }
                    until = max(until, s.at + s.waited)
                }
                if start >= 0 { line.append("\(start)+\(until - start)") }
                print("[MainBusy] 打开播放器后主线程忙碌段（起点毫秒+持续毫秒）：\(line.joined(separator: " "))") // i18n-ignore: developer diagnostics
            }
        }
    }
}
#endif
