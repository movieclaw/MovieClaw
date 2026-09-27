import AppKit

/// 任务卡片上的海报。
///
/// NAS 下发任务时带一个海报地址（``RunningJob/posterURL``）：它用这次任务的取源令牌
/// 签发，Worker 令牌进不了业务接口，转码器只拿得到正在转的那一部片的海报（NAS 侧见
/// transcode_worker 路由的 `sessions/{id}/poster`）。这里按需下载一次、交给面板显示；
/// 这部片没有海报、下载失败，就维持卡片上的占位图标。
///
/// - 按「海报地址去掉查询串」缓存：拖进度条会换任务号和令牌，但还是同一个播放会话的
///   同一张海报，不重复下载；
/// - 只留正在转的任务的海报，任务一结束就丢，连下载用的 URLSession 也一并释放——
///   空闲时不多占内存（App 的空闲内存是实测压过的）；
/// - 下载失败的这一轮任务里不再重试：状态每秒推好几次，失败就重试会变成请求风暴。
@MainActor
final class JobPosterCache {
    /// 有新海报下好了，面板要重画。
    var onChange: (() -> Void)?

    private var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []
    private var wanted: Set<String> = []
    private var session: URLSession?

    /// 跟上最新的任务列表：给新出现的海报开下载，丢掉已结束任务的海报。
    func sync(_ jobs: [RunningJob]) {
        var urls: [String: URL] = [:]
        for job in jobs {
            if let url = job.posterURL, urls[Self.key(url)] == nil {
                urls[Self.key(url)] = url
            }
        }
        wanted = Set(urls.keys)
        images = images.filter { wanted.contains($0.key) }
        failed.formIntersection(wanted)
        if wanted.isEmpty, inFlight.isEmpty {
            session?.finishTasksAndInvalidate()
            session = nil
            return
        }
        for (key, url) in urls where images[key] == nil && !inFlight.contains(key) && !failed.contains(key) {
            inFlight.insert(key)
            let session = session ?? Self.makeSession()
            self.session = session
            Task { [weak self] in
                let image = await Self.download(url, with: session)
                guard let self else { return }
                self.inFlight.remove(key)
                guard self.wanted.contains(key) else { return }  // 下载期间任务已经结束
                guard let image else {
                    self.failed.insert(key)
                    return
                }
                self.images[key] = image
                self.onChange?()
            }
        }
    }

    /// 任务号 → 已经下好的海报。
    func images(for jobs: [RunningJob]) -> [String: NSImage] {
        var result: [String: NSImage] = [:]
        for job in jobs {
            if let url = job.posterURL, let image = images[Self.key(url)] {
                result[job.id] = image
            }
        }
        return result
    }

    /// 缓存键：海报地址去掉查询串（令牌）。
    static func key(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        return components.string ?? url.absoluteString
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    private nonisolated static func download(_ url: URL, with session: URLSession) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return NSImage(data: data)
    }
}
