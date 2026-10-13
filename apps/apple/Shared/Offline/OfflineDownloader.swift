#if os(iOS)
import Foundation
import UIKit

/// 离线下载（docs/design/offline-download.md §5.4）：系统后台下载会话 + 期望状态与对账。
///
/// - **后台下载会话**：App 被挂起、锁屏都照常下（传输在系统进程里）；一次只下一个
///   （`httpMaximumConnectionsPerHost = 1`：家里上行有限，串行让第一集最早能看）。
/// - **期望状态**：要下什么记在每个单元的 `unit.json`；会话里实际有哪些任务由**对账**补齐——
///   启动、回前台、连上服务器、后台事件唤醒、任务结束、删除、改设置都对一次。崩溃、被系统杀、
///   用户强退（系统会取消全部任务、附续传数据）后都能自愈。
/// - **鉴权**：请求头带这个账号的设备令牌（不过期），不用 12 小时有效的播放签名；切了账号，
///   别的账号的下载照常继续。
/// - **准备**：视频之外的东西（清单、字幕、字体、图片、转码导出）要在线、在前台先拉好。
@MainActor
final class OfflineDownloader {
    static let shared = OfflineDownloader()

    /// 两个后台会话：只用 Wi-Fi 的、蜂窝也可以的。网络策略按会话定（请求本身都放开）：改设置时把进行中的任务
    /// 带续传数据挪到另一个会话，接着下（续传数据里的请求带不了新的网络策略）
    static let wifiSessionIdentifier = "io.movieclaw.offline"
    static let anySessionIdentifier = "io.movieclaw.offline.cellular"
    static let sessionIdentifiers: Set<String> = [wifiSessionIdentifier, anySessionIdentifier]

    /// 系统在后台唤醒 App 交付下载事件时给的收尾回调（按会话标识存，AppDelegate 存进来，事件处理完调用）
    var backgroundCompletions: [String: () -> Void] = [:]

    private let delegate = OfflineSessionDelegate()
    private lazy var wifiSession = makeSession(Self.wifiSessionIdentifier, cellular: false)
    private lazy var anySession = makeSession(Self.anySessionIdentifier, cellular: true)
    private var sessions: [URLSession] { [wifiSession, anySession] }
    /// 新任务建在哪个会话里（按「使用蜂窝网络下载」）
    private var session: URLSession { OfflineSettings.allowCellular ? anySession : wifiSession }

    private func makeSession(_ identifier: String, cellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.allowsCellularAccess = cellular
        config.allowsExpensiveNetworkAccess = cellular
        config.allowsConstrainedNetworkAccess = cellular
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 1
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        // 边转边下时转码一时没产出的空档要扛得住；整个资源允许挂七天（离线前一晚点下、慢慢下完）
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpAdditionalHeaders = ["User-Agent": APIClient.userAgent]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = identifier
        return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
    }

    private var store: OfflineStore { .shared }
    /// 正在准备的单元（一次一个）
    private var preparing: Int?
    private var reconcileTask: Task<Void, Never>?
    private var reconcileAgain = false
    /// 正在暂停（取消任务、存续传数据）的单元：对账先跳过它们
    private var pausing: Set<Int> = []
    /// 到点重试的定时（前台时；后台靠系统的定时开始）
    private var retryTimer: Task<Void, Never>?

    static let signedOutMessage = "这个账号在本机的登录已失效，重新登录后会接着下"

    /// App 启动时调：重建同名的后台会话，系统据此把上次没交付的事件（后台完成的下载）交给我们
    func activate() {
        _ = wifiSession
        _ = anySession
    }

    /// 全部任务（两个会话）
    private func allTasks() async -> [URLSessionTask] {
        var tasks: [URLSessionTask] = []
        for session in sessions { tasks += await session.allTasks }
        return tasks
    }

    /// 改了「使用蜂窝网络下载」：进行中的任务带续传数据取消，对账时在对的会话里接着下
    func applyNetworkSettings() {
        guard let key = store.key else { return }
        let other = OfflineSettings.allowCellular ? wifiSession : anySession
        Task {
            for task in await other.allTasks {
                guard let tag = OfflineTaskTag(task.taskDescription), tag.owner == key,
                      let download = task as? URLSessionDownloadTask else { continue }
                let resumeFile = OfflineDisk.resumeDataFile(key, tag.item, tag.file)
                let data = await download.cancelByProducingResumeData()
                if let data { try? data.write(to: resumeFile, options: .atomic) }
            }
            reconcile(reason: "network-settings")
        }
    }


    // MARK: 发起

    enum StartError: LocalizedError {
        case unsupported
        case noSpace(needed: Int64, available: Int64)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: "这台服务器还不支持下载到 iPhone，请先把服务器升级到最新版本"
            case let .noSpace(needed, available):
                "iPhone 空间不足：需要约 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))（含预留 2 GB），只剩 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))"
            case let .unavailable(reason): reason
            }
        }
    }

    /// 下载一个播放单元：清单已拉好（选档 sheet 里拉的），按选中的档位开始。已经在下 / 下完的同档不重复
    func start(manifest: API.OfflineManifestView, profile: API.OfflineProfileView) throws {
        guard let owner = store.owner, store.serverSupported else { throw StartError.unsupported }
        if let reason = manifest.unavailableReason { throw StartError.unavailable(reason) }
        if let existing = store.units[manifest.fileId], existing.profile == profile.profile,
           existing.state != .failed, !existing.damaged {
            return
        }
        let needed = Int64(profile.expectedBytes) + OfflineSettings.reserveBytes
        if let available = OfflineDisk.availableBytes, available < needed {
            throw StartError.noSpace(needed: needed, available: available)
        }
        store.ensureOwnerOnDisk()
        // 换档（比如原画改 720p）：旧的那份连同任务一起去掉，条目的展示数据与本机进度留着
        if let existing = store.units[manifest.fileId] {
            cancelTask(fileId: existing.fileId)
            store.removeUnit(fileId: existing.fileId, keepItem: true)
        }
        let summary = OfflineItemSummary(
            mediaItemId: manifest.mediaItemId,
            libraryId: manifest.libraryId,
            libraryName: manifest.library.name,
            libraryKind: manifest.library.kind,
            kind: manifest.item.kind,
            title: manifest.item.title,
            year: manifest.item.year,
            posterUrl: manifest.item.posterUrl,
            backdropUrl: manifest.item.backdropUrl,
            primaryAspect: manifest.item.primaryAspect,
            addedAt: Date()
        )
        store.upsertSummary(summary)
        let unit = OfflineUnit(
            fileId: manifest.fileId,
            mediaItemId: manifest.mediaItemId,
            season: manifest.seasonNumber,
            episode: manifest.episodeNumber,
            profile: profile.profile,
            profileLabel: profile.label,
            state: .preparing,
            expectedBytes: Int64(profile.expectedBytes),
            fileExtension: profile.profile == "original" ? Self.fileExtension(manifest.container) : "mp4",
            stillUrl: manifest.season?.episodes.first { $0.episodeNumber == manifest.episodeNumber }?.stillUrl,
            createdAt: Date()
        )
        store.upsert(unit)
        OfflineSettings.lastProfile = profile.profile
        Task { await prepare(unit, manifest: manifest, owner: owner) }
    }

    private static func fileExtension(_ container: String?) -> String {
        let raw = (container ?? "").lowercased()
        let known = ["mp4", "mkv", "m4v", "mov", "ts", "m2ts", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "iso", "rmvb"]
        if known.contains(raw) { return raw }
        if raw == "matroska" { return "mkv" }
        return raw.isEmpty ? "mkv" : raw.filter(\.isLetter).prefix(5).description
    }

    // MARK: 准备（在线、前台）

    private func api(for owner: OfflineOwner) -> APIClient? {
        let server = ServerAddress(origin: owner.origin)
        guard let token = TokenVault.token(server: server, username: owner.username) else { return nil }
        return APIClient(server: server, token: token)
    }

    /// 拉齐视频之外的东西：展示数据、字幕、字体、图片；转码档再建导出。都齐了才建视频下载任务
    private func prepare(_ unit: OfflineUnit, manifest given: API.OfflineManifestView?, owner: OfflineOwner) async {
        // 一次只准备一个；同一个单元也不能并发准备（换档时新旧两个打包器会写同一个目录）
        guard preparing == nil else { return }
        preparing = unit.fileId
        defer {
            preparing = nil
            reconcile(reason: "prepared")
        }
        guard let api = api(for: owner) else {
            fail(unit.fileId, Self.signedOutMessage, retryable: true)
            return
        }
        do {
            let manifest: API.OfflineManifestView = if let given { given } else { try await api.offlineManifest(fileId: unit.fileId) }
            guard store.key == owner.key else { return }  // 准备途中换了账号：留给它自己的账号下次对账
            try await OfflinePackager(api: api, ownerKey: owner.key, manifest: manifest, unit: unit).run()
            guard store.key == owner.key, var current = store.units[unit.fileId], current.state == .preparing,
                  current.profile == unit.profile else { return }
            // 整批下载先建的单元没有剧照：拿到完整清单后补上
            if current.stillUrl == nil {
                current.stillUrl = manifest.season?.episodes.first { $0.episodeNumber == manifest.episodeNumber }?.stillUrl
            }
            if current.profile != "original" {
                let export = try await api.offlineExportsCreate(body: .init(fileId: unit.fileId, profile: current.profile, audioTrack: manifest.defaultAudio))
                guard store.key == owner.key, store.units[unit.fileId]?.state == .preparing else { return }
                current.exportId = export.exportId
                if export.expectedBytes > 0 { current.expectedBytes = Int64(export.expectedBytes) }
            }
            current.state = .queued
            current.error = nil
            store.upsert(current)
            createTask(current, owner: owner)
            ServerReachability.shared.catalogChanged()
        } catch let error as APIError {
            guard store.key == owner.key else { return }
            switch error.status {
            case 400, 422: fail(unit.fileId, error.localizedDescription, retryable: false)
            case 403: fail(unit.fileId, "管理员未对你开放下载影片到设备", retryable: false)
            case 404: fail(unit.fileId, "服务器上已没有这个文件", retryable: false)
            default: fail(unit.fileId, error.localizedDescription, retryable: true)
            }
        } catch is CancellationError {
            // 不是这个任务本身被取消（APIClient 把 URLError.cancelled 也映射成它）：按可重试失败退避，
            // 不然对账立刻又来准备一次，原地打转
            if !Task.isCancelled, store.key == owner.key { fail(unit.fileId, "准备下载时被中断", retryable: true) }
        } catch {
            guard store.key == owner.key else { return }
            fail(unit.fileId, error.localizedDescription, retryable: true)
        }
    }

    // MARK: 视频下载任务

    private func contentURL(_ unit: OfflineUnit, origin: URL) -> URL? {
        if unit.profile == "original" {
            return origin.appending(path: "api/v1/offline/files/\(unit.fileId)/content")
        }
        guard let exportId = unit.exportId else { return nil }
        return origin.appending(path: "api/v1/offline/exports/\(exportId)/content")
    }

    private func createTask(_ unit: OfflineUnit, owner: OfflineOwner) {
        let server = ServerAddress(origin: owner.origin)
        guard let token = TokenVault.token(server: server, username: owner.username),
              let url = contentURL(unit, origin: owner.origin) else {
            fail(unit.fileId, Self.signedOutMessage, retryable: true)
            return
        }
        let resumeFile = OfflineDisk.resumeDataFile(owner.key, unit.mediaItemId, unit.fileId)
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeFile) {
            task = session.downloadTask(withResumeData: resume)
            OfflineDisk.queue.async { OfflineDisk.remove(resumeFile) }
        } else {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = OfflineTaskTag(owner: owner.key, item: unit.mediaItemId, file: unit.fileId).encoded
        task.countOfBytesClientExpectsToReceive = unit.expectedBytes
        if let at = unit.nextRetryAt, at > Date() { task.earliestBeginDate = at }
        task.resume()
    }

    /// 取消某个单元的视频任务（删除、换档）。取消后系统还会回调一次「出错」，按标记忽略
    func cancelTask(fileId: Int) {
        for session in sessions {
            session.getAllTasks { tasks in
                for task in tasks where OfflineTaskTag(task.taskDescription)?.file == fileId { task.cancel() }
            }
        }
    }

    // MARK: 用户操作

    func pause(fileId: Int) {
        guard var unit = store.units[fileId], unit.state == .queued || unit.state == .downloading,
              let key = store.key else { return }
        unit.state = .paused
        store.upsert(unit)
        let resumeFile = OfflineDisk.resumeDataFile(key, unit.mediaItemId, fileId)
        // 取消、续传数据落盘都是异步的：完成之前「继续」不能建新任务（会从 0 开始、或撞上还没取消完的旧任务）
        pausing.insert(fileId)
        Task {
            for task in await allTasks() where OfflineTaskTag(task.taskDescription)?.file == fileId {
                if let download = task as? URLSessionDownloadTask, let data = await download.cancelByProducingResumeData() {
                    try? await OfflineDisk.perform { try data.write(to: resumeFile, options: .atomic) }
                }
            }
            pausing.remove(fileId)
            reconcile(reason: "paused")
        }
    }

    /// 整批下载里除第一集外的各集：只凭选档表单的批量结果先建「准备中」单元（目录里马上有、强退也不丢），
    /// 完整清单由 `prepare` 逐集去取。条目的展示数据要已由第一集的 `start` 存好
    func enqueue(_ entry: API.OfflineFileProfilesView, profile: API.OfflineProfileView) throws {
        guard store.owner != nil, store.serverSupported, store.items[entry.mediaItemId] != nil else { throw StartError.unsupported }
        if let reason = entry.unavailableReason { throw StartError.unavailable(reason) }
        if let existing = store.units[entry.fileId], existing.profile == profile.profile,
           existing.state != .failed, !existing.damaged {
            return
        }
        let needed = Int64(profile.expectedBytes) + OfflineSettings.reserveBytes
        if let available = OfflineDisk.availableBytes, available < needed {
            throw StartError.noSpace(needed: needed, available: available)
        }
        if let existing = store.units[entry.fileId] {
            cancelTask(fileId: existing.fileId)
            store.removeUnit(fileId: existing.fileId, keepItem: true)
        }
        store.upsert(OfflineUnit(
            fileId: entry.fileId,
            mediaItemId: entry.mediaItemId,
            season: entry.seasonNumber,
            episode: entry.episodeNumber,
            profile: profile.profile,
            profileLabel: profile.label,
            state: .preparing,
            expectedBytes: Int64(profile.expectedBytes),
            fileExtension: profile.profile == "original" ? Self.fileExtension(entry.container) : "mp4",
            createdAt: Date()
        ))
        OfflineSettings.lastProfile = profile.profile
        reconcile(reason: "enqueue")
    }

    func resume(fileId: Int) {
        guard var unit = store.units[fileId], unit.state == .paused || unit.state == .failed else { return }
        unit.state = unit.profile != "original" && unit.exportId == nil ? .preparing : .queued
        unit.error = nil
        unit.retryable = true
        unit.nextRetryAt = nil
        store.upsert(unit)
        reconcile(reason: "resume")
    }

    /// 删除本机副本（任意状态）：先取消任务，再删目录
    func delete(fileId: Int) {
        cancelTask(fileId: fileId)
        store.removeUnit(fileId: fileId)
    }

    func deleteItem(_ itemId: Int) {
        for unit in store.units(ofItem: itemId) { delete(fileId: unit.fileId) }
    }

    // MARK: 对账

    func reconcile(reason: String) {
        if reconcileTask != nil {
            reconcileAgain = true
            return
        }
        reconcileTask = Task {
            repeat {
                reconcileAgain = false
                await reconcileNow()
            } while reconcileAgain
            reconcileTask = nil
        }
    }

    private func reconcileNow() async {
        guard let owner = store.owner, store.loaded else { return }
        let tasks = await allTasks()
        // 拿任务列表要等一下：这期间换了账号就不对了
        guard store.key == owner.key else { return }
        var running: [Int: URLSessionTask] = [:]
        for task in tasks {
            guard let tag = OfflineTaskTag(task.taskDescription), tag.owner == owner.key else { continue }
            guard task.state != .canceling, task.state != .completed else { continue }
            if pausing.contains(tag.file) { continue }
            if store.units[tag.file] == nil || store.units[tag.file]?.state == .paused {
                // 单元已删 / 已暂停：任务不该在跑
                task.cancel()
            } else if running[tag.file] != nil {
                // 同一个单元有两个任务（两次对账交错）：留一个
                task.cancel()
            } else {
                running[tag.file] = task
            }
        }
        let online = !ServerReachability.shared.isOffline && ServerReachability.shared.status != .unreachable
        let now = Date()
        var nextWake: Date?
        // 下面都是同步的：用的是此刻的状态，不会拿着过期的快照去建任务
        for unit in store.units.values.sorted(by: { $0.createdAt < $1.createdAt }) where !pausing.contains(unit.fileId) {
            switch unit.state {
            case .preparing:
                if online, preparing == nil { Task { await prepare(unit, manifest: nil, owner: owner) } }
            case .queued, .downloading:
                if running[unit.fileId] == nil {
                    createTask(unit, owner: owner)
                }
            case .failed:
                guard unit.retryable, running[unit.fileId] == nil else { continue }
                if let at = unit.nextRetryAt, at > now {
                    nextWake = min(nextWake ?? at, at)
                    continue
                }
                var next = unit
                next.state = unit.profile != "original" && unit.exportId == nil ? .preparing : .queued
                store.upsert(next)
                if next.state == .queued {
                    createTask(next, owner: owner)
                } else if online, preparing == nil {
                    Task { await prepare(next, manifest: nil, owner: owner) }
                }
            case .paused, .done:
                break
            }
        }
        scheduleRetry(at: nextWake)
    }

    /// 前台时到点再对一次账（503 的 Retry-After、失败退避）：没有它，失败的下载要等下次回前台才重试
    private func scheduleRetry(at date: Date?) {
        retryTimer?.cancel()
        retryTimer = nil
        guard let date else { return }
        let delay = max(1, date.timeIntervalSinceNow + 0.5)
        retryTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcile(reason: "retry-timer")
        }
    }

    // MARK: 任务结束（会话代理交回主线程）

    func finished(tag: OfflineTaskTag, size: Int64) {
        updateUnit(tag) { unit in
            unit.state = .done
            unit.receivedBytes = size
            unit.expectedBytes = size
            unit.completedAt = Date()
            unit.error = nil
            unit.attempts = 0
            unit.nextRetryAt = nil
        }
        if tag.owner == store.key {
            ServerReachability.shared.catalogChanged()
            if let exportId = store.units[tag.file]?.exportId, let owner = store.owner, let api = api(for: owner) {
                // 下完了：告诉服务端可以回收导出（尽力而为，服务端另有过期）
                Task { try? await api.offlineExportsRelease(exportId: exportId) }
            }
        }
        reconcile(reason: "finished")
    }

    func failedHTTP(tag: OfflineTaskTag, status: Int, retryAfter: TimeInterval?, message: String?) {
        switch status {
        case 503:
            // 导出还在排队：按服务端说的时间再来（后台会话的定时开始，不用 App 醒着）
            updateUnit(tag) { unit in
                unit.state = .failed
                unit.retryable = true
                unit.error = "服务器正在排队转码"
                unit.nextRetryAt = Date().addingTimeInterval(retryAfter ?? 60)
            }
        case 401:
            // 可重试：重新登录后对账会接着下（退避到最长一小时，不会一直打服务器）
            failTag(tag, Self.signedOutMessage, retryable: true)
        case 403:
            failTag(tag, "管理员未对你开放下载影片到设备", retryable: false)
        case 404, 410:
            failTag(tag, "服务器上已没有这个文件（可能被删除、移动或回收了导出）", retryable: tag.owner == store.key && store.units[tag.file]?.profile != "original")
        case 422:
            failTag(tag, message ?? "服务器转码失败", retryable: false)
        default:
            failTag(tag, "服务器出错了（HTTP \(status)）", retryable: true)
        }
        reconcile(reason: "http-failed")
    }

    func failedTransport(tag: OfflineTaskTag, error: URLError?, noSpace: Bool) {
        if noSpace {
            failTag(tag, "iPhone 空间不足，清理一些空间后点「重试」", retryable: false)
        } else {
            failTag(tag, error.map { APIClient.networkMessage($0) } ?? "下载中断", retryable: true)
        }
        reconcile(reason: "transport-failed")
    }

    func progressed(tag: OfflineTaskTag, received: Int64, expected: Int64?) {
        guard tag.owner == store.key else { return }
        store.updateReceived(fileId: tag.file, received: received, expected: expected)
    }

    private func failTag(_ tag: OfflineTaskTag, _ message: String, retryable: Bool) {
        updateUnit(tag) { unit in
            unit.state = .failed
            unit.error = message
            unit.retryable = retryable
            unit.attempts += 1
            if retryable {
                let steps: [TimeInterval] = [30, 120, 600, 1800, 3600]
                unit.nextRetryAt = Date().addingTimeInterval(steps[min(unit.attempts - 1, steps.count - 1)])
            }
            // 待删的旧档（换档时）在 404 后不会被重试：转码档 404 = 导出被回收，回到准备阶段重建导出
            if retryable, unit.profile != "original", message.contains("没有这个文件") { unit.exportId = nil }
        }
    }

    private func fail(_ fileId: Int, _ message: String, retryable: Bool) {
        guard let key = store.key, let unit = store.units[fileId] else { return }
        failTag(OfflineTaskTag(owner: key, item: unit.mediaItemId, file: fileId), message, retryable: retryable)
    }

    /// 改一个单元：当前账号的走目录（内存 + 写盘），别的账号的（切了账号，它的下载还在后台跑）直接改盘上的文件
    private func updateUnit(_ tag: OfflineTaskTag, _ change: @escaping @Sendable (inout OfflineUnit) -> Void) {
        if tag.owner == store.key, var unit = store.units[tag.file] {
            change(&unit)
            store.upsert(unit)
        } else {
            // 别的账号的，或本机目录还没读进来（启动时后台事件先到）：直接改盘上的文件
            let file = OfflineDisk.unitFile(tag.owner, tag.item, tag.file)
            OfflineDisk.queue.async {
                guard var unit = OfflineDisk.read(OfflineUnit.self, from: file) else { return }
                change(&unit)
                try? OfflineDisk.write(unit, to: file)
            }
        }
    }
}

/// 下载任务认的是哪个单元（写在 `taskDescription` 里：App 重启后靠它把系统里的任务对回单元）
nonisolated struct OfflineTaskTag: Codable, Sendable, Hashable {
    var owner: String
    var item: Int
    var file: Int

    var encoded: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }

    init(owner: String, item: Int, file: Int) {
        self.owner = owner
        self.item = item
        self.file = file
    }

    init?(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let tag = try? JSONDecoder().decode(OfflineTaskTag.self, from: data) else { return nil }
        self = tag
    }
}

/// 后台下载会话的代理：回调在会话自己的串行队列上。下完的文件必须在回调返回前移走（系统随后就删临时文件），
/// 所以移动在这里同步做，状态再交回主线程
nonisolated final class OfflineSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress: [Int: Date] = [:]
    /// didFinishDownloading 已处理过的任务（之后的 didCompleteWithError 是 nil，或是 HTTP 错误已处理）
    private var handled: Set<Int> = []


    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let tag = OfflineTaskTag(downloadTask.taskDescription) else { return }
        let now = Date()
        let due = lock.withLock { () -> Bool in
            if let last = lastProgress[tag.file], now.timeIntervalSince(last) < 1 { return false }
            lastProgress[tag.file] = now
            return true
        }
        guard due else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        Task { @MainActor in OfflineDownloader.shared.progressed(tag: tag, received: totalBytesWritten, expected: expected) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = OfflineTaskTag(downloadTask.taskDescription) else { return }
        lock.withLock { _ = handled.insert(downloadTask.taskIdentifier) }
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            let body = (try? Data(contentsOf: location)).flatMap { String(data: $0.prefix(2000), encoding: .utf8) }
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            Task { @MainActor in
                OfflineDownloader.shared.failedHTTP(tag: tag, status: status, retryAfter: retryAfter, message: body)
            }
            return
        }
        let unitFile = OfflineDisk.unitFile(tag.owner, tag.item, tag.file)
        let size = Int64((try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let expected = downloadTask.countOfBytesExpectedToReceive
        // 续传（206）时「预期字节」是这一段的长度、落下的却是整个文件，比不了；只核对整段下载
        if status == 200, expected > 0, size != expected {
            // 有长度却没收全：不当成完成
            Task { @MainActor in OfflineDownloader.shared.failedTransport(tag: tag, error: nil, noSpace: false) }
            return
        }
        // 读单元、挪文件和删除走同一个磁盘队列：不然删到一半挪进来，会在删掉的目录里留下孤儿文件
        let outcome: Result<Bool, Error> = OfflineDisk.queue.sync {
            guard let unit = OfflineDisk.read(OfflineUnit.self, from: unitFile) else { return .success(false) } // 单元已删
            let target = OfflineDisk.unitDir(tag.owner, tag.item, tag.file).appending(path: unit.mediaFileName)
            return Result {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                return true
            }
        }
        switch outcome {
        case .success(false):
            return
        case .failure(let error):
            let noSpace = (error as NSError).code == NSFileWriteOutOfSpaceError
            Task { @MainActor in OfflineDownloader.shared.failedTransport(tag: tag, error: nil, noSpace: noSpace) }
            return
        case .success(true):
            break
        }
        Task { @MainActor in OfflineDownloader.shared.finished(tag: tag, size: size) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let tag = OfflineTaskTag(task.taskDescription) else { return }
        let wasHandled = lock.withLock { handled.remove(task.taskIdentifier) != nil }
        lock.withLock { _ = lastProgress.removeValue(forKey: tag.file) }
        guard let error else { return }
        let nsError = error as NSError
        if let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            // 能续传：留着续传数据，重试时接着下（暂停时由 pause 自己存）
            let file = OfflineDisk.resumeDataFile(tag.owner, tag.item, tag.file)
            if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) {
                try? resume.write(to: file, options: .atomic)
            }
        }
        let urlError = error as? URLError
        guard !wasHandled else { return }
        if urlError?.code == .cancelled,
           (nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int) == nil {
            return
        }
        let noSpace = urlError?.code == .cannotWriteToFile || nsError.code == NSFileWriteOutOfSpaceError
        Task { @MainActor in OfflineDownloader.shared.failedTransport(tag: tag, error: urlError, noSpace: noSpace) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        Task { @MainActor in
            OfflineDownloader.shared.backgroundCompletions.removeValue(forKey: identifier)?()
        }
    }
}
#endif
