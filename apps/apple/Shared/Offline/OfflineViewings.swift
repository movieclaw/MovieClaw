#if os(iOS)
import Foundation

/// 本机播放的观看记录（docs/design/offline-download.md §7）。
///
/// 本机播放一律走这条路，在线离线一样；流式播放保持实时上报。两条不混用，免得一次观看被记两遍。
/// 先落盘再发：每 10 秒、暂停、停止、退后台时写一次；能连上就发最新的快照，连不上攒着，
/// 回来后一批补传。服务端按编号幂等合并、按发生时间判新旧、校正手机时钟偏差。
@MainActor
final class OfflineViewingRecorder {
    private var record: OfflineViewing
    private let ownerKey: String
    private let api: APIClient?
    /// 上一次计时的时刻（在播时才累计观看时长）
    private var lastTick: Date?
    private var lastSave = Date.distantPast

    init?(unit: OfflineUnit, startPositionMs: Int, durationMs: Int?, api: APIClient?) {
        guard let key = OfflineStore.shared.key else { return nil }
        ownerKey = key
        self.api = api
        let now = Date()
        record = OfflineViewing(
            viewingId: UUID().uuidString.lowercased(),
            mediaItemId: unit.mediaItemId, season: unit.season, episode: unit.episode, fileId: unit.fileId,
            startedAt: now, updatedAt: now, startPositionMs: startPositionMs, positionMs: startPositionMs,
            watchedMs: 0, completed: false, ended: false, durationMs: durationMs, dirty: true
        )
    }

    /// 播放读数（播放器每秒调一次）：在播的墙钟时间才算观看时长
    func tick(positionMs: Int, playing: Bool, durationMs: Int?) {
        let now = Date()
        let wasPlaying = lastTick != nil
        if playing, let lastTick { record.watchedMs += max(0, Int(now.timeIntervalSince(lastTick) * 1000)) }
        lastTick = playing ? now : nil
        // 刚暂停：立即落一次盘（暂停后被系统回收也不丢这段进度）
        if wasPlaying, !playing { lastSave = .distantPast }
        record.positionMs = positionMs
        record.updatedAt = now
        if let durationMs { record.durationMs = durationMs }
        record.dirty = true
        if now.timeIntervalSince(lastSave) >= 10 { save(send: true) }
    }

    /// 暂停、退后台：立即落一次盘并尝试发出
    func checkpoint() {
        save(send: true)
    }

    /// 这次播放结束（退出、换集、播完）
    func finish(positionMs: Int, completed: Bool) {
        record.positionMs = positionMs
        record.completed = record.completed || completed
        record.ended = true
        record.updatedAt = Date()
        record.dirty = true
        save(send: true)
    }

    /// App 即将被结束：只落盘（下次启动补发）
    func finishBeforeTermination(positionMs: Int) {
        record.positionMs = positionMs
        record.ended = true
        record.updatedAt = Date()
        record.dirty = true
        let snapshot = record, key = ownerKey
        OfflineDisk.queue.sync { try? OfflineDisk.write(snapshot, to: OfflineDisk.viewingFile(key, snapshot.viewingId)) }
    }

    private func save(send: Bool) {
        lastSave = Date()
        let snapshot = record, key = ownerKey
        let current = OfflineStore.shared.localProgress(itemId: snapshot.mediaItemId, season: snapshot.season, episode: snapshot.episode)
        let outcome = Self.resolve(positionMs: snapshot.completed ? nil : snapshot.positionMs, runtimeMs: snapshot.durationMs,
                                   currentlyPlayed: current?.played ?? false)
        OfflineStore.shared.recordProgress(
            itemId: snapshot.mediaItemId, season: snapshot.season, episode: snapshot.episode,
            positionMs: outcome.positionMs, played: outcome.played, durationMs: snapshot.durationMs
        )
        OfflineDisk.queue.async { try? OfflineDisk.write(snapshot, to: OfflineDisk.viewingFile(key, snapshot.viewingId)) }
        if send, let api { OfflineViewingUploader.shared.flush(api: api, ownerKey: key) }
    }
}

extension OfflineViewingRecorder {
    /// 本机续播点与服务端同一套阈值（movieclaw_playback/progress.py `resolve_progress`）：
    /// 不足 5% 不记续播点、超过 90% 或离结尾 1 秒内算看完、短于 5 分钟的片过了开头就算看完。
    /// 不同口径的话，离线时显示「继续 0:12」，连上之后服务端却说没看过
    nonisolated static func resolve(positionMs: Int?, runtimeMs: Int?, currentlyPlayed: Bool) -> (positionMs: Int, played: Bool) {
        guard let positionMs else { return (0, true) }
        if positionMs <= 0 { return (0, currentlyPlayed) }
        guard let runtimeMs, runtimeMs > 0 else { return (0, true) }
        let pct = Double(positionMs) / Double(runtimeMs) * 100
        if pct < 5 { return (0, currentlyPlayed) }
        if pct > 90 || positionMs >= runtimeMs - 1000 { return (0, true) }
        if runtimeMs < 300_000 { return (0, true) }
        return (positionMs, currentlyPlayed)
    }
}

/// 把攒着的观看记录发给服务器：同一时刻只有一个在途请求；确认后、且这次播放已结束的才删
@MainActor
final class OfflineViewingUploader {
    static let shared = OfflineViewingUploader()

    private var inFlight = false
    private var again = false

    func flush(api: APIClient, ownerKey: String) {
        if inFlight {
            again = true
            return
        }
        inFlight = true
        Task {
            repeat {
                again = false
                await send(api: api, ownerKey: ownerKey)
            } while again
            inFlight = false
        }
    }

    private func send(api: APIClient, ownerKey: String) async {
        let dir = OfflineDisk.viewingsDir(ownerKey)
        let records = await Task.detached {
            OfflineDisk.children(dir).compactMap { OfflineDisk.read(OfflineViewing.self, from: $0) }.filter(\.dirty)
        }.value
        guard !records.isEmpty else { return }
        for batch in stride(from: 0, to: records.count, by: 100).map({ Array(records[$0 ..< min($0 + 100, records.count)]) }) {
            let body = API.PlaybackViewingsRequest(
                sentAt: Self.iso(Date()),
                records: batch.map { record in
                    API.PlaybackViewingRecordIn(
                        viewingId: record.viewingId, mediaItemId: record.mediaItemId,
                        seasonNumber: record.season, episodeNumber: record.episode, fileId: record.fileId,
                        startedAt: Self.iso(record.startedAt), updatedAt: Self.iso(record.updatedAt),
                        startPositionMs: record.startPositionMs, positionMs: record.positionMs,
                        watchedMs: record.watchedMs, completed: record.completed, ended: record.ended,
                        durationMs: record.durationMs
                    )
                }
            )
            guard let result = try? await api.playbackViewings(body: body) else { return }
            let acknowledged = Set(result.results.map(\.viewingId))
            await Task.detached {
                for record in batch where acknowledged.contains(record.viewingId) {
                    let file = OfflineDisk.viewingFile(ownerKey, record.viewingId)
                    // 发出去之后又有了新快照（还在播）：留着下次发
                    guard let current = OfflineDisk.read(OfflineViewing.self, from: file) else { continue }
                    if current.updatedAt > record.updatedAt { continue }
                    if current.ended {
                        OfflineDisk.remove(file)
                    } else {
                        var clean = current
                        clean.dirty = false
                        try? OfflineDisk.write(clean, to: file)
                    }
                }
            }.value
        }
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// 是否还有没确认的记录（在线拿到服务器的续播点时，有待发的本机记录就不拿服务器的覆盖本机进度）
    func hasPending(ownerKey: String, itemId: Int, season: Int, episode: Int) -> Bool {
        let dir = OfflineDisk.viewingsDir(ownerKey)
        return OfflineDisk.children(dir).contains { url in
            guard let record = OfflineDisk.read(OfflineViewing.self, from: url) else { return false }
            return record.mediaItemId == itemId && record.season == season && record.episode == episode && record.dirty
        }
    }
}
#endif
