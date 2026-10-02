import Foundation

/// 播放记录的上报队列（docs/design/playback-qoe.md §2）。
///
/// ## 为什么要落盘
/// 最该上报的恰恰是最容易丢的那几次播放：出错退出时网络可能正断着，闪退、被系统杀掉时根本来不及发。
/// 所以每份记录**先写进 App 容器里的队列目录、再发送**，发成功才删；发不出去就留着，下次启动或下一次播放时补发。
///
/// ## 异常退出
/// 播放期间每 10 秒刷新一次「正在播放」标记（`active.json`，内容就是这一刻的完整记录，结局写成「异常退出」；
/// App 在后台且暂停着时写成「中途退出」——那时被系统回收是正常的）。正常收尾会删掉它；下次启动还看得到它，
/// 说明上次这次播放没能收尾（闪退或被杀），把它转进队列补报。服务端按播放编号合并，重复上报只留最后一份。
///
/// 只发给记录产生时的那台服务器（换了服务器的不发，7 天后清掉）。遥测只发给用户自己的服务器（硬边界 3）。
nonisolated enum PlaybackReportQueue {
    private static let queue = DispatchQueue(label: "movieclaw.playback-reports", qos: .utility)
    /// 队列里的记录最多留几天（一直发不出去的，例如服务器已经不用了）
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private struct Envelope: Codable {
        var server: String
        var payload: API.PlaybackMetricPayload
        var savedAt: Date
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("playback-reports", isDirectory: true)
    }

    private static var activeFile: URL { directory.appendingPathComponent("active.json") }

    /// 这次播放收尾：写进队列、删掉「正在播放」标记，然后发送
    static func submit(_ payload: API.PlaybackMetricPayload, api: APIClient) {
        let envelope = Envelope(server: key(api), payload: payload, savedAt: Date())
        queue.async {
            write(envelope, to: file(for: payload))
            try? FileManager.default.removeItem(at: activeFile)
        }
        Task { await flush(api: api) }
    }

    /// 刷新「正在播放」标记（播放中每 10 秒一次；前后台切换时也刷新一次）
    static func markActive(_ payload: API.PlaybackMetricPayload, api: APIClient) {
        let envelope = Envelope(server: key(api), payload: payload, savedAt: Date())
        queue.async { write(envelope, to: activeFile) }
    }

    /// 上次没能收尾的播放（标记还在）转进队列。启动时、每次新建播放记录前调：必须赶在写新标记之前
    static func recoverAbnormalExit() {
        queue.sync {
            guard let data = try? Data(contentsOf: activeFile),
                  let envelope = try? decoder.decode(Envelope.self, from: data) else {
                try? FileManager.default.removeItem(at: activeFile)
                return
            }
            write(envelope, to: file(for: envelope.payload))
            try? FileManager.default.removeItem(at: activeFile)
        }
    }

    /// 发送队列里属于这台服务器的记录：成功或服务端明确拒收（4xx）就删，网络问题留着下次再发
    static func flush(api: APIClient) async {
        let server = key(api)
        let pending: [(URL, Envelope)] = queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" && $0 != activeFile }.compactMap { url in
                guard let data = try? Data(contentsOf: url), let envelope = try? decoder.decode(Envelope.self, from: data) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                if Date().timeIntervalSince(envelope.savedAt) > maxAge {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return envelope.server == server ? (url, envelope) : nil
            }
        }
        for (url, envelope) in pending {
            do {
                _ = try await api.playbackMetricReport(body: envelope.payload)
                queue.async { try? FileManager.default.removeItem(at: url) }
            } catch let error as APIError where (400 ..< 500).contains(error.status ?? 0) {
                // 服务端明确不收（记录格式不对之类）：重发也没用
                queue.async { try? FileManager.default.removeItem(at: url) }
            } catch {
                // 网络问题：留着，下次再发；后面的也先不发了
                return
            }
        }
    }

    // MARK: - 内部

    private static func key(_ api: APIClient) -> String { api.server.origin.absoluteString }

    private static func file(for payload: API.PlaybackMetricPayload) -> URL {
        directory.appendingPathComponent("\(payload.attemptId ?? UUID().uuidString).json")
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// 在 `queue` 上调
    private static func write(_ envelope: Envelope, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
