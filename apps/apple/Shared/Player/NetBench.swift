#if DEBUG
import Foundation

/// 真机测原文件的读取吞吐（`-mcNetBench YES`，只在调试包里存在）：起播前对取流地址分别用 1 / 2 / 4 条连接
/// 各读 128 MB，结果打进 `[NetBench]`。用来判断「起播窗口并发按 Range 读」值不值（docs/design/player-engine.md §8.5：
/// 长 GOP 的 4K 第一片要读几十 MB，单连接实测约 380 Mbit/s）。
///
/// 每组读文件的不同区段（总长的 1/5、2/5、3/5 处），免得 NAS 的页缓存让后一组虚快。
enum NetBench {
    static func run(url: URL) async {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let size = await totalSize(url, session: session), size > 1 << 30 else {
            log("拿不到文件总长或文件小于 1 GB，跳过")
            return
        }
        let total: Int64 = 128 << 20
        for (group, connections) in [1, 2, 4].enumerated() {
            let base = size / 5 * Int64(group + 1)
            let part = total / Int64(connections)
            let started = Date()
            let bytes = await withTaskGroup(of: Int64.self) { tasks in
                for index in 0 ..< connections {
                    let start = base + Int64(index) * part
                    tasks.addTask { await fetch(url, from: start, length: part, session: session) }
                }
                var sum: Int64 = 0
                for await bytes in tasks { sum += bytes }
                return sum
            }
            let seconds = Date().timeIntervalSince(started)
            let mbps = Int(Double(bytes) * 8 / seconds / 1e6)
            log("\(connections) 条连接共读 \(bytes >> 20) MB：\(mbps) Mbit/s（\(String(format: "%.2f", seconds)) 秒）")
        }
    }

    private static func totalSize(_ url: URL, session: URLSession) async -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await session.data(for: request),
              let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) })
        else { return nil }
        return total
    }

    private static func fetch(_ url: URL, from start: Int64, length: Int64, session: URLSession) async -> Int64 {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await session.data(for: request) else { return 0 }
        return Int64(data.count)
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("[NetBench] \(line)\n".utf8))
    }
}
#endif
