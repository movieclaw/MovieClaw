#if os(iOS)
import Foundation
import Observation

/// 本机副本的目录（docs/design/offline-download.md §3、§4）：当前账号有哪些条目、哪些单元、各自的状态与本机进度。
///
/// 只在主线程改，写盘排进 `OfflineDisk.queue`（同一个串行队列，先改先写），界面直接观察它。
/// 海报墙、首页只看 `doneFileIds` / `downloadedItemIds`（完成、删除时才变）：下载进度每秒刷一次 `units`，
/// 不该连带整面墙重算。
@MainActor
@Observable
final class OfflineStore {
    static let shared = OfflineStore()

    private(set) var owner: OfflineOwner?
    private(set) var items: [Int: OfflineItemSummary] = [:]
    private(set) var units: [Int: OfflineUnit] = [:]
    private(set) var progress: [Int: [String: OfflineProgress]] = [:]
    /// 下完、能播的单元
    private(set) var doneFileIds: Set<Int> = []
    /// 至少有一个能播单元的条目
    private(set) var downloadedItemIds: Set<Int> = []
    /// 每个条目还没下完的单元（详情页右上角「取消下载」）：只在开始 / 完成 / 删除时变，下载进度不改它——
    /// 页面读 `units` 的话每次进度刷新都整页重算，开着的菜单被重建，点下去的项落空
    private(set) var activeByItem: [Int: [ActiveUnit]] = [:]

    struct ActiveUnit: Hashable {
        let fileId: Int
        let season: Int
        let episode: Int
    }
    /// 这台服务器支持离线下载（有实例号）：没有时下载入口不出现
    private(set) var serverSupported = false
    /// 读完本机存档了（离线首页据此区分「还在读」和「真的没有」）
    private(set) var loaded = false
    /// 正在下载的单元的实时速度（字节 / 秒，平滑过）：只在内存里
    private(set) var speeds: [Int: Double] = [:]
    @ObservationIgnored private var speedSamples: [Int: (at: Date, bytes: Int64)] = [:]

    @ObservationIgnored private var adoptingKey: String?

    var key: String? { owner?.key }

    // MARK: 账号

    /// 以这个账号的身份使用：找到它的存档（按实例号；还不知道实例号时按地址 + 用户名找），读进内存。
    /// 实例号第一次要向服务器问（`/health`），之后记在本机，离线也认得出
    func adopt(server: ServerAddress, username: String) async {
        let token = "\(server.origin.absoluteString)|\(username)"
        guard adoptingKey != token else { return }
        adoptingKey = token
        let origin = server.origin
        let owners = await Task.detached(priority: .userInitiated) { OfflineOwners.scan() }.value
        var instance = OfflineOwners.instanceId(for: origin)
        // 认得实例号时只按实例号找：同一个地址上换了一台服务器（重装），旧存档不能套到新服务器上
        var match = instance.map { id in owners.first { $0.instanceId == id && $0.username == username } }
            ?? owners.first { $0.origin == origin && $0.username == username }
        if instance == nil {
            instance = await OfflineOwners.fetchInstanceId(server)
            if let instance, let found = owners.first(where: { $0.instanceId == instance && $0.username == username }) {
                match = found
            }
        }
        guard adoptingKey == token else { return }
        if instance == nil, match == nil {
            // 没问到实例号（冷启动时连不上）、本机也没有存档：下次连上时再来（`readoptIfNeeded`）
            adoptingKey = nil
        }
        if var current = match {
            if current.origin != origin {
                current.origin = origin
                let snapshot = current
                OfflineDisk.queue.async { try? OfflineDisk.write(snapshot, to: OfflineDisk.ownerFile(snapshot.key)) }
            }
            apply(owner: current, supported: true)
        } else if let instance {
            apply(owner: OfflineOwner(instanceId: instance, username: username, origin: origin), supported: true)
        } else {
            // 旧服务器（没有实例号）或冷启动时连不上、本机也没有存档：先不开离线下载
            owner = nil
            items = [:]
            units = [:]
            progress = [:]
            refreshDerived()
            serverSupported = false
            loaded = true
            OfflineImages.shared.reset()
        }
    }

    private func apply(owner: OfflineOwner, supported: Bool) {
        let changed = owner.key != self.owner?.key
        self.owner = owner
        serverSupported = supported
        guard changed else { return }
        items = [:]
        units = [:]
        progress = [:]
        loaded = false
        refreshDerived()
        let key = owner.key
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) { OfflineDisk.loadSnapshot(key) }.value
            guard self.owner?.key == key else { return }
            items = snapshot.items
            units = snapshot.units
            progress = snapshot.progress
            refreshDerived()
            loaded = true
            await Task.detached(priority: .utility) { OfflineImages.shared.load(ownerKey: key, itemIds: Array(snapshot.items.keys)) }.value
            OfflineDownloader.shared.reconcile(reason: "adopt")
        }
    }

    /// 连上服务器 / 回前台时调：上次没认出服务器（离线冷启动、实例号还不知道）就再认一次；
    /// 认得的话顺手核对实例号——地址没变、服务器换了（重装）时改认新的
    func readoptIfNeeded(server: ServerAddress, username: String) async {
        if owner == nil || !serverSupported {
            adoptingKey = nil
            await adopt(server: server, username: username)
            return
        }
        guard let known = owner?.instanceId,
              let fresh = await OfflineOwners.fetchInstanceId(server), fresh != known else { return }
        reset()
        await adopt(server: server, username: username)
    }

    /// 本机目录读完为止（最多等 `timeout` 秒）：冷启动直达播放、详情页秒开要先知道本机有没有副本
    func waitUntilLoaded(timeout: Double = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !loaded, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 换账号 / 退出时清空内存（存档留在盘上，同一账号回来就还在）
    func reset() {
        adoptingKey = nil
        owner = nil
        items = [:]
        units = [:]
        progress = [:]
        loaded = false
        serverSupported = false
        refreshDerived()
        OfflineImages.shared.reset()
    }

    private func refreshDerived() {
        let done = Set(units.values.filter(\.playable).map(\.fileId))
        if done != doneFileIds { doneFileIds = done }
        let itemIds = Set(units.values.filter(\.playable).map(\.mediaItemId))
        if itemIds != downloadedItemIds { downloadedItemIds = itemIds }
        let active = Dictionary(grouping: units.values.filter(\.isActive)) { $0.mediaItemId }
            .mapValues { $0.map { ActiveUnit(fileId: $0.fileId, season: $0.season, episode: $0.episode) }.sorted { $0.fileId < $1.fileId } }
        if active != activeByItem { activeByItem = active }
    }

    // MARK: 查询

    func units(ofItem itemId: Int) -> [OfflineUnit] {
        units.values.filter { $0.mediaItemId == itemId }.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    /// 这个单元有没有能播的本机副本（一集有多个版本时取最新下完的那个）
    func playableUnit(mediaItemId: Int, season: Int, episode: Int) -> OfflineUnit? {
        units.values
            .filter { $0.mediaItemId == mediaItemId && $0.season == season && $0.episode == episode && $0.playable }
            .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }

    /// 这个单元的本机副本（任意状态）：详情页的下载按钮看它
    func unit(mediaItemId: Int, season: Int, episode: Int) -> OfflineUnit? {
        let matches = units.values.filter { $0.mediaItemId == mediaItemId && $0.season == season && $0.episode == episode }
        return matches.first(where: \.playable) ?? matches.max { $0.createdAt < $1.createdAt }
    }

    /// 已下载的条目（离线首页、存储页）：最近下载的在前
    var downloadedItems: [OfflineItemSummary] {
        downloadedItemIds.compactMap { items[$0] }.sorted { $0.addedAt > $1.addedAt }
    }

    /// 还在进行中（含失败、暂停）的单元：首页「正在下载」行
    var activeUnits: [OfflineUnit] {
        units.values.filter(\.isActive).sorted { $0.createdAt < $1.createdAt }
    }

    func localProgress(itemId: Int, season: Int, episode: Int) -> OfflineProgress? {
        progress[itemId]?["\(season)-\(episode)"]
    }

    func mediaURL(_ unit: OfflineUnit) -> URL? {
        guard let key else { return nil }
        return OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId).appending(path: unit.mediaFileName)
    }

    func unitDir(_ unit: OfflineUnit) -> URL? {
        key.map { OfflineDisk.unitDir($0, unit.mediaItemId, unit.fileId) }
    }

    func spec(_ unit: OfflineUnit) async -> OfflinePlaybackSpec? {
        guard let key else { return nil }
        let url = OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId)
        return await Task.detached { OfflineDisk.read(OfflinePlaybackSpec.self, from: url) }.value
    }

    /// 本机存的详情（接口模型原样）；没有或解不开（App 升级改了模型）为 nil
    func detail(itemId: Int) async -> API.LibraryItemDetailView? {
        guard let key, items[itemId] != nil else { return nil }
        let url = OfflineDisk.detailFile(key, itemId)
        return await Task.detached { OfflineDisk.readAPI(API.LibraryItemDetailView.self, from: url) }.value
    }

    func library(itemId: Int) async -> API.LibraryView? {
        guard let key, items[itemId] != nil else { return nil }
        let url = OfflineDisk.libraryFile(key, itemId)
        return await Task.detached { OfflineDisk.readAPI(API.LibraryView.self, from: url) }.value
    }

    func season(itemId: Int, season: Int) async -> API.SeasonEpisodesView? {
        guard let key, items[itemId] != nil else { return nil }
        let url = OfflineDisk.seasonFile(key, itemId, season)
        return await Task.detached { OfflineDisk.readAPI(API.SeasonEpisodesView.self, from: url) }.value
    }

    /// 本机这个条目的副本占了多少空间（存储页）
    func bytes(ofItem itemId: Int) -> Int64 {
        units(ofItem: itemId).reduce(0) { $0 + $1.receivedBytes }
    }

    var totalBytes: Int64 { units.values.reduce(0) { $0 + $1.receivedBytes } }

    // MARK: 离线显示的变换（§4：在线请求失败回落本机时同样做）

    /// 详情：文件只留本机有的，季只留有下载的
    func offlineDetail(_ detail: API.LibraryItemDetailView) -> API.LibraryItemDetailView {
        var result = detail
        let local = Set(units(ofItem: detail.mediaItemId).filter(\.playable).map(\.fileId))
        result.files = detail.files.filter { local.contains($0.id) }
        result.fileCount = result.files.count
        result.totalSizeBytes = result.files.reduce(0) { $0 + $1.sizeBytes }
        if detail.kind == "tv" {
            let seasons = Set(result.files.map(\.seasonNumber))
            result.seasons = detail.seasons.filter { seasons.contains($0) }
        }
        result.scraping = false
        result.chaptersPending = false
        return result
    }

    /// 分集：「在库」改成「本机有没有」（没下的集沿用缺集置灰），进度取本机
    func offlineSeason(_ view: API.SeasonEpisodesView, itemId: Int) -> API.SeasonEpisodesView {
        var result = view
        result.episodes = view.episodes.map { episode in
            var copy = episode
            let unit = playableUnit(mediaItemId: itemId, season: view.seasonNumber, episode: episode.episodeNumber)
            copy.owned = unit != nil
            copy.fileIds = unit.map { [$0.fileId] } ?? []
            if let local = localProgress(itemId: itemId, season: view.seasonNumber, episode: episode.episodeNumber) {
                copy.positionMs = local.positionMs
                copy.played = local.played
                if let duration = local.durationMs, duration > 0, local.positionMs > 0 {
                    copy.progressPercent = min(100, Int(Double(local.positionMs) / Double(duration) * 100))
                }
            }
            return copy
        }
        // 服务端的锚点可能指向一集没下的：交给客户端规则在本机有的集里挑
        if let anchor = result.resumeEpisode, !(result.episodes.first { $0.episodeNumber == anchor }?.owned ?? false) {
            result.resumeEpisode = nil
        }
        return result
    }

    // MARK: 写入

    func upsert(_ unit: OfflineUnit) {
        guard let key else { return }
        units[unit.fileId] = unit
        if unit.state != .downloading { clearSpeed(unit.fileId) }
        refreshDerived()
        OfflineDisk.queue.async { try? OfflineDisk.write(unit, to: OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId)) }
    }

    /// 只改内存里的进度读数（下载进度每秒一次，不值得每次写盘）
    func updateReceived(fileId: Int, received: Int64, expected: Int64?) {
        guard var unit = units[fileId], unit.state == .downloading || unit.state == .queued else { return }
        unit.receivedBytes = received
        if let expected, expected > 0, unit.profile == "original" || unit.expectedBytes == 0 { unit.expectedBytes = expected }
        if unit.state == .queued { unit.state = .downloading }
        units[fileId] = unit
        sampleSpeed(fileId, received)
    }

    /// 速度 = 两次进度读数之间的字节差 / 时间差，再做指数平滑（读数约每秒一次，原始值跳得厉害）
    private func sampleSpeed(_ fileId: Int, _ received: Int64) {
        let now = Date()
        guard let last = speedSamples[fileId] else {
            speedSamples[fileId] = (now, received)
            return
        }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed >= 0.5 else { return }
        let instant = max(0, Double(received - last.bytes) / elapsed)
        speeds[fileId] = speeds[fileId].map { $0 * 0.6 + instant * 0.4 } ?? instant
        speedSamples[fileId] = (now, received)
    }

    private func clearSpeed(_ fileId: Int) {
        speedSamples.removeValue(forKey: fileId)
        if speeds[fileId] != nil { speeds.removeValue(forKey: fileId) }
    }

    func upsertSummary(_ summary: OfflineItemSummary) {
        guard let key else { return }
        items[summary.mediaItemId] = summary
        OfflineDisk.queue.async { try? OfflineDisk.write(summary, to: OfflineDisk.summaryFile(key, summary.mediaItemId)) }
    }

    /// 在线拿到最新详情：本机有这个条目就顺手刷新存档（下次离线看到的是最新的）
    func refresh(detail: API.LibraryItemDetailView) {
        guard let key, var summary = items[detail.mediaItemId] else { return }
        summary.title = detail.title
        summary.year = detail.year
        summary.posterUrl = detail.posterUrl
        summary.backdropUrl = detail.backdropUrl
        summary.primaryAspect = detail.primaryAspect
        if summary != items[detail.mediaItemId] { upsertSummary(summary) }
        OfflineDisk.queue.async { try? OfflineDisk.writeAPI(detail, to: OfflineDisk.detailFile(key, detail.mediaItemId)) }
    }

    func refresh(season view: API.SeasonEpisodesView, itemId: Int) {
        guard let key, items[itemId] != nil else { return }
        OfflineDisk.queue.async { try? OfflineDisk.writeAPI(view, to: OfflineDisk.seasonFile(key, itemId, view.seasonNumber)) }
    }

    /// 记一次本机进度（本机播放时每 10 秒；在线拿到服务器的续播点也写进来）
    func recordProgress(itemId: Int, season: Int, episode: Int, positionMs: Int, played: Bool, durationMs: Int?, at date: Date = Date()) {
        guard let key, items[itemId] != nil else { return }
        var map = progress[itemId] ?? [:]
        map["\(season)-\(episode)"] = OfflineProgress(positionMs: positionMs, played: played, durationMs: durationMs, updatedAt: date)
        progress[itemId] = map
        let snapshot = map
        OfflineDisk.queue.async { try? OfflineDisk.write(snapshot, to: OfflineDisk.progressFile(key, itemId)) }
    }

    /// 删一个单元（取消下载、删本机副本）。条目的单元删光了，整个条目目录一起删；
    /// `keepItem`：换档时只换这个单元，条目的展示数据、图片、本机进度都留着
    func removeUnit(fileId: Int, keepItem: Bool = false) {
        guard let key, let unit = units.removeValue(forKey: fileId) else { return }
        clearSpeed(fileId)
        let itemId = unit.mediaItemId
        let itemEmpty = !keepItem && !units.values.contains { $0.mediaItemId == itemId }
        if itemEmpty {
            items.removeValue(forKey: itemId)
            progress.removeValue(forKey: itemId)
        }
        refreshDerived()
        OfflineDisk.queue.async {
            OfflineDisk.remove(itemEmpty ? OfflineDisk.itemDir(key, itemId) : OfflineDisk.unitDir(key, itemId, fileId))
        }
        if itemEmpty { OfflineImages.shared.forget(itemId: itemId) }
    }

    func removeItem(_ itemId: Int) {
        for unit in units(ofItem: itemId) { OfflineDownloader.shared.cancelTask(fileId: unit.fileId) }
        for unit in units(ofItem: itemId) { removeUnit(fileId: unit.fileId) }
    }

    /// App 升级后第一次在线：按顺序重拉全部副本的展示数据（§3.3）。生成的接口模型加了必有字段时，
    /// 旧存档会解码失败，离线前刷一遍才稳；同一个 App 版本只做一次
    func refreshArchivedMetadataIfNeeded(api: APIClient) async {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let defaultsKey = "movieclaw.offline.metadataVersion.\(key ?? "")"
        guard key != nil, !items.isEmpty, UserDefaults.standard.string(forKey: defaultsKey) != version else { return }
        var complete = true
        for item in items.values {
            guard !ServerReachability.shared.isOffline else { return }
            if let detail = try? await api.libraryItemsGet(libraryId: item.libraryId, mediaItemId: item.mediaItemId) {
                refresh(detail: detail)
            } else {
                complete = false
            }
            guard item.kind == "tv" else { continue }
            for season in Set(units(ofItem: item.mediaItemId).map(\.season)) {
                if let view = try? await api.libraryItemsListEpisodes(libraryId: item.libraryId, mediaItemId: item.mediaItemId, seasonNumber: season) {
                    refresh(season: view, itemId: item.mediaItemId)
                } else {
                    complete = false
                }
            }
        }
        // 有没拉到的（连不上、条目已删）：下次在线再来
        if complete { UserDefaults.standard.set(version, forKey: defaultsKey) }
    }

    /// 首次下载这个账号的东西：建账号目录
    func ensureOwnerOnDisk() {
        guard let owner else { return }
        OfflineDisk.queue.async { try? OfflineDisk.write(owner, to: OfflineDisk.ownerFile(owner.key)) }
    }
}

/// 本机存过哪些账号（存储页的「其他账号」、按实例号认服务器）
nonisolated enum OfflineOwners {
    private static let instanceKey = "movieclaw.offline.instanceIds"

    static func scan() -> [OfflineOwner] {
        OfflineDisk.children(OfflineDisk.root).compactMap { dir in
            OfflineDisk.read(OfflineOwner.self, from: dir.appending(path: "owner.json"))
        }
    }

    /// 服务器地址 → 实例号（问过一次就记下：离线时也认得出是哪台）
    static func instanceId(for origin: URL) -> String? {
        (UserDefaults.standard.dictionary(forKey: instanceKey) as? [String: String])?[origin.absoluteString]
    }

    static func remember(_ id: String, for origin: URL) {
        var map = (UserDefaults.standard.dictionary(forKey: instanceKey) as? [String: String]) ?? [:]
        map[origin.absoluteString] = id
        UserDefaults.standard.set(map, forKey: instanceKey)
    }

    static func fetchInstanceId(_ server: ServerAddress) async -> String? {
        guard let health = try? await APIClient(server: server).health(), let id = health.instanceId, !id.isEmpty else { return nil }
        remember(id, for: server.origin)
        return id
    }

    /// 某个账号存档占的空间与条目数（存储页「其他账号」一节）
    static func usage(_ owner: OfflineOwner) -> (bytes: Int64, items: Int) {
        let dir = OfflineDisk.ownerDir(owner.key)
        return (OfflineDisk.size(of: dir), OfflineDisk.children(OfflineDisk.itemsDir(owner.key)).count)
    }

    static func remove(_ owner: OfflineOwner) {
        OfflineDisk.queue.async { OfflineDisk.remove(OfflineDisk.ownerDir(owner.key)) }
    }
}
#endif
