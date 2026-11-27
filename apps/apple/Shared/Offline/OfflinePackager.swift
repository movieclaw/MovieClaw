#if os(iOS)
import CryptoKit
import Darwin
import Foundation

/// 打包一个单元视频之外的东西（docs/design/offline-download.md §5.4「准备中」）：
/// 展示数据（详情、库、这一季的分集）、播放数据（片段、章节、轨道）、字幕、字体、图片。
/// 都在前台、普通接口会话里拉（体积小）；图片缺了不影响完成，其余失败整次准备失败、对账时重来。
struct OfflinePackager {
    let api: APIClient
    let ownerKey: String
    let manifest: API.OfflineManifestView
    let unit: OfflineUnit

    /// 字幕抽取（内封轨要服务端通读整个容器）、字体抽取可能很慢
    private static let slowTimeout: TimeInterval = 600

    func run() async throws {
        let itemId = manifest.mediaItemId
        let key = ownerKey
        let unitDir = OfflineDisk.unitDir(key, itemId, unit.fileId)
        try await OfflineDisk.perform { [manifest] in
            try OfflineDisk.writeAPI(manifest.item, to: OfflineDisk.detailFile(key, itemId))
            try OfflineDisk.writeAPI(manifest.library, to: OfflineDisk.libraryFile(key, itemId))
            if let season = manifest.season {
                try OfflineDisk.writeAPI(season, to: OfflineDisk.seasonFile(key, itemId, season.seasonNumber))
            }
            try FileManager.default.createDirectory(at: unitDir, withIntermediateDirectories: true)
        }

        // 打包时服务器上的续播点：本机还没有进度时先用它（离线时从这里接着看）
        if let resume = manifest.resumePositionMs, resume > 0,
           OfflineStore.shared.localProgress(itemId: itemId, season: unit.season, episode: unit.episode) == nil {
            OfflineStore.shared.recordProgress(
                itemId: itemId, season: unit.season, episode: unit.episode,
                positionMs: resume, played: false, durationMs: manifest.durationMs, at: .distantPast
            )
        }

        // 字幕：原画档的内封轨在文件里，引擎自己读；外挂轨、转码档的全部文字轨存成旁挂文件
        var subtitles: [OfflinePlaybackSpec.Subtitle] = []
        let original = unit.profile == "original"
        for (index, sub) in manifest.subtitles.enumerated() where !(original && sub.embedded) {
            let name = "\(index)-\(Self.safeName(sub.language ?? "und")).\(sub.format)"
            let data = try await fetch(sub.url, timeout: Self.slowTimeout)
            try await write(data, to: unitDir.appending(path: "subs/\(name)"))
            subtitles.append(.init(
                ref: "external:\(name)", fileName: name, kind: sub.format == "srt" ? "vtt" : "ass",
                language: sub.language, title: sub.title, isDefault: sub.isDefault,
                isForced: sub.isForced, isAi: sub.isAi, sourceRef: sub.trackRef
            ))
        }

        // 字体：有 ASS 轨才要（番剧的特效字幕不配字体会走样）
        var fonts: [String] = []
        if let fontsUrl = manifest.fontsUrl, subtitles.contains(where: { $0.kind == "ass" }) {
            let list = try APIClient.decoder.decode(APIEnvelope<API.PlaybackFontsView>.self, from: try await fetch(fontsUrl, timeout: Self.slowTimeout)).data
            for url in list.fonts {
                let raw = URL(string: url)?.lastPathComponent.removingPercentEncoding ?? "font"
                let name = Self.safeName(raw)
                let data = try await fetch(url, timeout: Self.slowTimeout)
                try await write(data, to: unitDir.appending(path: "fonts/\(name)"))
                fonts.append(name)
            }
        }

        let file = manifest.item.files.first { $0.id == unit.fileId }
        let spec = OfflinePlaybackSpec(
            durationMs: manifest.durationMs,
            chapters: manifest.chapters,
            segments: manifest.segments,
            audioTracks: original ? manifest.audioTracks : manifest.audioTracks.filter { $0.ref == manifest.defaultAudio },
            defaultAudio: manifest.defaultAudio,
            subtitles: subtitles,
            fonts: fonts,
            resolution: original ? file?.resolution : unit.profile,
            videoCodec: original ? file?.videoCodec : "h264",
            container: original ? manifest.container : "mp4"
        )
        try await OfflineDisk.perform {
            try OfflineDisk.write(spec, to: OfflineDisk.playbackFile(key, itemId, unit.fileId))
        }

        await saveImages()
    }

    // MARK: 图片

    /// 详情页、海报格、分集卡、演职员要的图，每张存一份（按图片键，任何显示宽度都用它）
    private func saveImages() async {
        let itemId = manifest.mediaItemId
        let item = manifest.item
        var wanted: [(raw: String, width: Int)] = []
        func add(_ raw: String?, _ width: Int) {
            if let raw, !raw.isEmpty { wanted.append((raw, width)) }
        }
        add(item.posterUrl, 780)
        add(item.backdropUrl, 1920)
        add(item.logoUrl, 780)
        for actor in item.localMeta?.actors.prefix(20) ?? [] { add(actor.thumbUrl, 300) }
        for director in item.localMeta?.directorCredits.prefix(5) ?? [] { add(director.thumbUrl, 300) }
        for episode in manifest.season?.episodes.prefix(80) ?? [] { add(episode.stillUrl, 600) }

        let dir = OfflineDisk.imagesDir(ownerKey, itemId)
        let indexFile = dir.appending(path: "index.json")
        var index = await Task.detached { OfflineDisk.read([String: String].self, from: indexFile) ?? [:] }.value
        for (raw, width) in wanted {
            guard let url = api.server.imageURL(raw, width: width), let key = OfflineImages.key(for: url),
                  index[key] == nil else { continue }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request = api.authorized(request)
            guard let (data, response) = try? await api.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
            let ext = (response.mimeType?.contains("png") ?? false) ? "png" : (response.mimeType?.contains("webp") ?? false) ? "webp" : "jpg"
            let name = OfflineImages.fileName(for: key, ext: ext)
            let target = dir.appending(path: name)
            guard (try? await write(data, to: target)) != nil else { continue }
            index[key] = name
            OfflineImages.shared.register(key: key, file: target, itemId: itemId)
        }
        let snapshot = index
        OfflineDisk.queue.async { try? OfflineDisk.write(snapshot, to: indexFile) }
    }

    // MARK: 工具

    /// 清单里的地址是 `/api/v1/...` 的绝对路径（字幕、字体带了签名 token）
    private func fetch(_ path: String, timeout: TimeInterval) async throws -> Data {
        try await Self.fetch(path, api: api, timeout: timeout)
    }

    nonisolated static func fetch(_ path: String, api: APIClient, timeout: TimeInterval) async throws -> Data {
        guard let url = api.server.resolve(path) else {
            throw APIError.decoding(String(localized: .offlineErrorInvalidPath(path)))
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request = api.authorized(request)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await api.session.data(for: request)
        } catch let error as URLError {
            throw APIError.network(APIClient.networkMessage(error))
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.http(status: status, message: String(localized: .offlineErrorAttachmentHttp(String(status))), code: nil)
        }
        return data
    }

    private func write(_ data: Data, to url: URL) async throws {
        try await OfflineDisk.perform {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func safeName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(80))
    }

    // MARK: 在线补齐字幕

    private static let syncTimeout: TimeInterval = 30

    /// 一次已完成单元的磁盘快照指纹：用于在拉取 manifest / 字幕期间检测单元是否被删除、换档或同档重下。
    nonisolated struct SyncStamp: Equatable, Sendable {
        struct FileIdentity: Equatable, Sendable {
            var dev: Int32
            var ino: UInt64
            var birthSec: Int
            var birthNsec: Int
            var mtimeSec: Int
            var mtimeNsec: Int

            static func read(_ url: URL, includeMtime: Bool = true) -> FileIdentity? {
                var st = stat()
                guard stat(url.path, &st) == 0 else { return nil }
                return FileIdentity(
                    dev: st.st_dev,
                    ino: st.st_ino,
                    birthSec: st.st_birthtimespec.tv_sec,
                    birthNsec: st.st_birthtimespec.tv_nsec,
                    mtimeSec: includeMtime ? st.st_mtimespec.tv_sec : 0,
                    mtimeNsec: includeMtime ? st.st_mtimespec.tv_nsec : 0
                )
            }
        }

        var profile: String
        var fileExtension: String
        var exportId: String?
        var createdAt: Date
        var completedAt: Date?
        var dirIdentity: FileIdentity
        var playbackIdentity: FileIdentity
        var subtitles: [OfflinePlaybackSpec.Subtitle]
        var fonts: [String]
    }

    private nonisolated static func diskNormalizedDate(_ date: Date) -> Date {
        (try? OfflineDisk.decoder.decode([Date].self, from: OfflineDisk.encoder.encode([date])).first) ?? date
    }

    private nonisolated static func matchesUnitInstance(_ expected: OfflineUnit, diskUnit: OfflineUnit) -> Bool {
        diskUnit.playable
            && diskUnit.profile == expected.profile
            && diskUnit.fileExtension == expected.fileExtension
            && diskUnit.exportId == expected.exportId
            && diskUnit.createdAt == diskNormalizedDate(expected.createdAt)
            && diskUnit.completedAt == expected.completedAt.map(diskNormalizedDate)
    }

    private nonisolated static func readSyncStampLocked(ownerKey: String, unit: OfflineUnit) -> (stamp: SyncStamp, spec: OfflinePlaybackSpec)? {
        let unitDir = OfflineDisk.unitDir(ownerKey, unit.mediaItemId, unit.fileId)
        let unitFile = OfflineDisk.unitFile(ownerKey, unit.mediaItemId, unit.fileId)
        let playbackFile = OfflineDisk.playbackFile(ownerKey, unit.mediaItemId, unit.fileId)
        guard let liveUnit = OfflineDisk.read(OfflineUnit.self, from: unitFile),
              matchesUnitInstance(unit, diskUnit: liveUnit),
              let spec = OfflineDisk.read(OfflinePlaybackSpec.self, from: playbackFile),
              let dirIdentity = SyncStamp.FileIdentity.read(unitDir, includeMtime: false),
              let playbackIdentity = SyncStamp.FileIdentity.read(playbackFile, includeMtime: true) else { return nil }
        let stamp = SyncStamp(
            profile: liveUnit.profile,
            fileExtension: liveUnit.fileExtension,
            exportId: liveUnit.exportId,
            createdAt: liveUnit.createdAt,
            completedAt: liveUnit.completedAt,
            dirIdentity: dirIdentity,
            playbackIdentity: playbackIdentity,
            subtitles: spec.subtitles,
            fonts: spec.fonts
        )
        return (stamp, spec)
    }

    /// 在发出 `/offline/manifest` 请求前先读取一次磁盘快照指纹，防止 manifest 慢网期间单元被删除并同档重下。
    nonisolated static func readSyncStamp(ownerKey: String, unit: OfflineUnit) async throws -> SyncStamp? {
        guard unit.playable else { return nil }
        return try await OfflineDisk.perform {
            readSyncStampLocked(ownerKey: ownerKey, unit: unit)?.stamp
        }
    }

    /// 已完成本机副本的在线字幕补齐（#1336）：
    /// 只补齐服务端外挂文字字幕（含缺失的 ASS 字体），不碰视频文件、不重抽内封轨、不改既有默认选轨。
    /// 先把全部待下字幕与字体拉进内存，任一步失败直接抛出，盘上原有 `subs/` 与 `playback.json` 保持不动；
    /// 全部拉完后再在 `OfflineDisk.queue` 上核对单元快照指纹并原子落盘，最后清理不再引用的旧外挂字幕文件。
    @discardableResult
    nonisolated static func syncSubtitles(
        ownerKey: String,
        unit: OfflineUnit,
        manifest: API.OfflineManifestView,
        api: APIClient,
        expectedStamp: SyncStamp? = nil
    ) async throws -> Bool {
        guard let serverFile = manifest.item.files.first(where: { $0.id == unit.fileId }) else { return false }
        return try await syncSubtitles(
            ownerKey: ownerKey,
            unit: unit,
            manifestFileId: manifest.fileId,
            unavailableReason: manifest.unavailableReason,
            manifestAudioTracks: manifest.audioTracks,
            manifestDefaultAudio: manifest.defaultAudio,
            manifestSubtitles: manifest.subtitles,
            fontsUrl: manifest.fontsUrl,
            serverFile: serverFile,
            expectedStamp: expectedStamp
        ) { path, timeout in
            try await Self.fetch(path, api: api, timeout: timeout)
        }
    }

    @discardableResult
    nonisolated static func syncSubtitles(
        ownerKey: String,
        unit: OfflineUnit,
        manifestFileId: Int,
        unavailableReason: String? = nil,
        manifestAudioTracks: [API.AudioTrackView] = [],
        manifestDefaultAudio: String? = nil,
        manifestSubtitles: [API.OfflineSubtitleView],
        fontsUrl: String?,
        serverFile: API.LibraryFileView? = nil,
        expectedStamp: SyncStamp? = nil,
        fetch: @Sendable (String, TimeInterval) async throws -> Data
    ) async throws -> Bool {
        guard unit.playable, manifestFileId == unit.fileId else { return false }
        let unitDir = OfflineDisk.unitDir(ownerKey, unit.mediaItemId, unit.fileId)
        let playbackFile = OfflineDisk.playbackFile(ownerKey, unit.mediaItemId, unit.fileId)
        let subsDir = unitDir.appending(path: "subs", directoryHint: .isDirectory)
        let fontsDir = unitDir.appending(path: "fonts", directoryHint: .isDirectory)

        let state: (stamp: SyncStamp, spec: OfflinePlaybackSpec, subFiles: Set<String>, fontFiles: Set<String>)? = try await OfflineDisk.perform {
            guard let current = readSyncStampLocked(ownerKey: ownerKey, unit: unit) else { return nil }
            if let expectedStamp, current.stamp != expectedStamp { return nil }
            let subFiles = Set(OfflineDisk.children(subsDir).map(\.lastPathComponent))
            let fontFiles = Set(OfflineDisk.children(fontsDir).map(\.lastPathComponent))
            return (current.stamp, current.spec, subFiles, fontFiles)
        }
        guard let state else { return false }

        // 服务端无法构建 PlaybackPlan 时仍可能返回 HTTP 200 空清单：此时直接中止，绝不清掉已有字幕
        if OfflineSubtitleSync.isDegradedManifest(
            unavailableReason: unavailableReason,
            audioTracks: manifestAudioTracks,
            defaultAudio: manifestDefaultAudio,
            manifestSubtitles: manifestSubtitles,
            serverFile: serverFile,
            existingSpec: state.spec
        ) {
            return false
        }

        let plan = OfflineSubtitleSync.plan(
            existing: state.spec.subtitles,
            manifestSubtitles: manifestSubtitles,
            existingSubFiles: state.subFiles
        )
        let hasASS = plan.subtitles.contains { $0.kind == "ass" }
        let downloadingASS = plan.downloads.contains {
            let lower = $0.fileName.lowercased()
            return lower.hasSuffix(".ass") || lower.hasSuffix(".ssa")
        }
        let shouldCheckFonts = hasASS && fontsUrl != nil && (state.spec.fonts.isEmpty || downloadingASS)

        guard !plan.downloads.isEmpty || plan.subtitles != state.spec.subtitles || !plan.obsoleteFiles.isEmpty || shouldCheckFonts else {
            return false
        }

        // 先把所有新字幕与缺失字体完整拉进内存；任一步失败都不触碰磁盘
        var fetchedSubs: [(fileName: String, data: Data)] = []
        fetchedSubs.reserveCapacity(plan.downloads.count)
        for download in plan.downloads {
            let data = try await fetch(download.url, syncTimeout)
            fetchedSubs.append((download.fileName, data))
        }

        var fetchedFonts: [(fileName: String, data: Data)] = []
        var syncedFontNames: [String] = []
        if shouldCheckFonts, let fontsUrl {
            let listData = try await fetch(fontsUrl, syncTimeout)
            let list = try APIClient.decoder.decode(APIEnvelope<API.PlaybackFontsView>.self, from: listData).data
            for url in list.fonts {
                let raw = URL(string: url)?.lastPathComponent.removingPercentEncoding ?? "font"
                let name = Self.safeName(raw)
                if !syncedFontNames.contains(name) { syncedFontNames.append(name) }
                if !state.fontFiles.contains(name) {
                    let data = try await fetch(url, syncTimeout)
                    fetchedFonts.append((name, data))
                }
            }
        }

        let initialStamp = state.stamp
        let subsToWrite = fetchedSubs
        let fontsToWrite = fetchedFonts
        let addedFonts = syncedFontNames
        let finalSubtitles = plan.subtitles
        let obsoleteFiles = plan.obsoleteFiles

        return try await OfflineDisk.perform {
            guard let live = readSyncStampLocked(ownerKey: ownerKey, unit: unit),
                  live.stamp == initialStamp else { return false }
            var liveSpec = live.spec

            var writtenNewFiles: [URL] = []
            do {
                if !subsToWrite.isEmpty {
                    try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
                    for item in subsToWrite {
                        let target = subsDir.appending(path: item.fileName)
                        let existed = FileManager.default.fileExists(atPath: target.path)
                        try item.data.write(to: target, options: .atomic)
                        if !existed { writtenNewFiles.append(target) }
                    }
                }
                if !fontsToWrite.isEmpty {
                    try FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
                    for item in fontsToWrite {
                        let target = fontsDir.appending(path: item.fileName)
                        let existed = FileManager.default.fileExists(atPath: target.path)
                        try item.data.write(to: target, options: .atomic)
                        if !existed { writtenNewFiles.append(target) }
                    }
                }

                liveSpec.subtitles = finalSubtitles
                if !addedFonts.isEmpty {
                    var merged = liveSpec.fonts
                    for name in addedFonts where !merged.contains(name) { merged.append(name) }
                    liveSpec.fonts = merged
                }
                try OfflineDisk.write(liveSpec, to: playbackFile)
            } catch {
                for url in writtenNewFiles { OfflineDisk.remove(url) }
                throw error
            }

            let referenced = Set(liveSpec.subtitles.map(\.fileName))
            for obsolete in obsoleteFiles where !referenced.contains(obsolete) {
                OfflineDisk.remove(subsDir.appending(path: obsolete))
            }
            return true
        }
    }
}

/// 已下载本机副本的在线字幕补齐调度（按账号+文件实例去重，同一时刻只跑一次）。
@MainActor
final class OfflineSubtitleSync {
    static let shared = OfflineSubtitleSync()

    nonisolated struct Plan: Sendable, Equatable {
        nonisolated struct Download: Sendable, Equatable {
            var fileName: String
            var url: String
        }

        var subtitles: [OfflinePlaybackSpec.Subtitle]
        var downloads: [Download]
        var obsoleteFiles: [String]
    }

    nonisolated static let supportedExternalFormats: Set<String> = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa"]

    private var inFlight: [String: Task<Void, Never>] = [:]

    private init() {}

    /// 详情页服务端文件里的外挂文字字幕 `sourceRef` 集合（跳过图形字幕 `.sup`/`.sub`/`.idx`）。
    nonisolated static func externalSubtitleRefs(in file: API.LibraryFileView) -> Set<String> {
        Set(file.subtitleStreams.compactMap { stream -> String? in
            guard stream.external, let name = stream.fileName, !name.isEmpty else { return nil }
            let ext = (stream.codec ?? (name as NSString).pathExtension).lowercased()
            guard supportedExternalFormats.contains(ext) else { return nil }
            return "external:\(name)"
        })
    }

    /// 详情页在线刷新后快速判断是否需要补齐外挂字幕（内封轨不参与比较，无变化时不发额外请求）。
    nonisolated static func needsSync(localSpec: OfflinePlaybackSpec?, serverFile: API.LibraryFileView) -> Bool {
        guard let localSpec else { return false }
        let localExternal = Set(localSpec.subtitles.map(\.sourceRef).filter { $0.hasPrefix("external:") })
        return localExternal != externalSubtitleRefs(in: serverFile)
    }

    /// 判定 `/offline/manifest` 是否为降级 HTTP 200 空清单（如文件缺失、需转码同意、被策略拒绝、原盘等）。
    /// 此类响应缺少完整播放计划，绝对不能拿空 `subtitles` 去清理本机已有字幕。
    nonisolated static func isDegradedManifest(
        unavailableReason: String?,
        audioTracks: [API.AudioTrackView],
        defaultAudio: String?,
        manifestSubtitles: [API.OfflineSubtitleView],
        serverFile: API.LibraryFileView?,
        existingSpec: OfflinePlaybackSpec
    ) -> Bool {
        if let reason = unavailableReason, !reason.isEmpty { return true }
        if audioTracks.isEmpty && defaultAudio == nil && manifestSubtitles.isEmpty { return true }
        if (!existingSpec.audioTracks.isEmpty || existingSpec.defaultAudio != nil)
            && audioTracks.isEmpty && defaultAudio == nil {
            return true
        }
        if let serverFile {
            if serverFile.missing || serverFile.state != "in_place" { return true }
            if !(serverFile.audioStreams ?? []).isEmpty && audioTracks.isEmpty && defaultAudio == nil { return true }
            if !externalSubtitleRefs(in: serverFile).isEmpty && manifestSubtitles.allSatisfy(\.embedded) { return true }
        }
        return false
    }

    /// 新增外挂字幕的稳定落盘文件名：与初始打包的 `0-chi.srt` 不冲突，同一 `trackRef` 幂等。
    nonisolated static func syncedSubtitleFileName(trackRef: String, language: String?, format: String) -> String {
        let digest = SHA256.hash(data: Data(trackRef.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let lang = OfflinePackager.safeName(language ?? "und")
        let ext = OfflinePackager.safeName(format.lowercased())
        return "sync-\(hash)-\(lang).\(ext)"
    }

    /// 计算在线补齐计划（纯逻辑）：
    /// - 转码档原本存盘的内封轨（`sourceRef` 以 `embedded:` 开头）原样保留，不重抽、不删除；
    /// - 已有外挂字幕保留原 `ref` / `fileName` / `isDefault`（若盘上文件缺失则重新拉回）；
    /// - 新增外挂字幕一律 `isDefault = false`（不改变既有默认选轨）；
    /// - 服务端已删的外挂字幕进入 `obsoleteFiles`，等新 `playback.json` 落盘后再清理。
    nonisolated static func plan(
        existing: [OfflinePlaybackSpec.Subtitle],
        manifestSubtitles: [API.OfflineSubtitleView],
        existingSubFiles: Set<String>
    ) -> Plan {
        let preservedEmbedded = existing.filter { $0.sourceRef.hasPrefix("embedded:") }
        var existingExternalByRef: [String: OfflinePlaybackSpec.Subtitle] = [:]
        for sub in existing where !sub.sourceRef.hasPrefix("embedded:") && existingExternalByRef[sub.sourceRef] == nil {
            existingExternalByRef[sub.sourceRef] = sub
        }

        var seenRefs: Set<String> = []
        var nextExternal: [OfflinePlaybackSpec.Subtitle] = []
        var downloads: [Plan.Download] = []

        for sub in manifestSubtitles where !sub.embedded {
            guard seenRefs.insert(sub.trackRef).inserted else { continue }
            let fmt = sub.format.lowercased()
            let kind = (fmt == "ass" || fmt == "ssa") ? "ass" : "vtt"
            if let prev = existingExternalByRef[sub.trackRef] {
                nextExternal.append(.init(
                    ref: prev.ref,
                    fileName: prev.fileName,
                    kind: kind,
                    language: sub.language,
                    title: sub.title,
                    isDefault: prev.isDefault,
                    isForced: sub.isForced,
                    isAi: sub.isAi,
                    sourceRef: sub.trackRef
                ))
                if !existingSubFiles.contains(prev.fileName) {
                    downloads.append(.init(fileName: prev.fileName, url: sub.url))
                }
            } else {
                let fileName = syncedSubtitleFileName(trackRef: sub.trackRef, language: sub.language, format: fmt)
                nextExternal.append(.init(
                    ref: "external:\(fileName)",
                    fileName: fileName,
                    kind: kind,
                    language: sub.language,
                    title: sub.title,
                    isDefault: false,
                    isForced: sub.isForced,
                    isAi: sub.isAi,
                    sourceRef: sub.trackRef
                ))
                downloads.append(.init(fileName: fileName, url: sub.url))
            }
        }

        let finalSubtitles = preservedEmbedded + nextExternal
        let referenced = Set(finalSubtitles.map(\.fileName))
        var obsoleteSeen: Set<String> = []
        let obsoleteFiles = existing.compactMap { sub -> String? in
            guard !sub.sourceRef.hasPrefix("embedded:"), !referenced.contains(sub.fileName),
                  obsoleteSeen.insert(sub.fileName).inserted else { return nil }
            return sub.fileName
        }
        return Plan(subtitles: finalSubtitles, downloads: downloads, obsoleteFiles: obsoleteFiles)
    }

    /// 等待一个独立后台任务最多 `timeout` 秒：超时或调用方被取消时立即返回（不取消 `task` 本身，留后台收尾）。
    /// 注意：不能用 `withTaskGroup` 包 `await task.value`，因为 `await task.value` 不响应子任务取消，
    /// `withTaskGroup` 会一直阻塞到慢网任务结束。
    nonisolated static func awaitBounded(_ task: Task<Void, Never>, timeout: TimeInterval) async {
        guard timeout > 0 else { return }
        final class WaitState: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            private var finished = false
            private var timer: Task<Void, Never>?
            private var observer: Task<Void, Never>?

            func install(
                continuation: CheckedContinuation<Void, Never>,
                task: Task<Void, Never>,
                timeout: TimeInterval
            ) {
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                timer = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    self.finish()
                }
                observer = Task {
                    _ = await task.value
                    self.finish()
                }
                lock.unlock()
            }

            func finish() {
                let cont: CheckedContinuation<Void, Never>?
                let t: Task<Void, Never>?
                let o: Task<Void, Never>?
                lock.lock()
                if finished {
                    cont = nil; t = nil; o = nil
                } else {
                    finished = true
                    cont = continuation
                    continuation = nil
                    t = timer
                    timer = nil
                    o = observer
                    observer = nil
                }
                lock.unlock()
                t?.cancel()
                o?.cancel()
                cont?.resume()
            }
        }

        let state = WaitState()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation: continuation, task: task, timeout: timeout)
            }
        } onCancel: {
            state.finish()
        }
    }

    /// 后台触发一次字幕补齐（同账号同文件实例已有任务在跑时直接复用，不重复请求）。
    func sync(unit: OfflineUnit, ownerKey: String, api: APIClient) {
        _ = startTask(unit: unit, ownerKey: ownerKey, api: api)
    }

    /// 触发字幕补齐并最多等待 `timeout` 秒；超时或调用方取消时立即结束等待、不取消后台同步，失败静默保留原字幕。
    func syncWaiting(unit: OfflineUnit, ownerKey: String, api: APIClient, timeout: Double = 2) async {
        guard let task = startTask(unit: unit, ownerKey: ownerKey, api: api) else { return }
        await Self.awaitBounded(task, timeout: timeout)
    }

    private func startTask(unit: OfflineUnit, ownerKey: String, api: APIClient) -> Task<Void, Never>? {
        guard unit.playable else { return nil }
        let key = "\(ownerKey)|\(unit.fileId)|\(unit.profile)|\(unit.createdAt.timeIntervalSince1970)|\(unit.completedAt?.timeIntervalSince1970 ?? -1)"
        if let existing = inFlight[key] { return existing }
        let task = Task<Void, Never> {
            defer { self.inFlight.removeValue(forKey: key) }
            do {
                guard let expectedStamp = try await OfflinePackager.readSyncStamp(ownerKey: ownerKey, unit: unit) else { return }
                let manifest = try await api.offlineManifest(fileId: unit.fileId)
                try await OfflinePackager.syncSubtitles(
                    ownerKey: ownerKey,
                    unit: unit,
                    manifest: manifest,
                    api: api,
                    expectedStamp: expectedStamp
                )
            } catch {
                // 失败保留本机原有字幕与 playback.json，不阻断播放或浏览
            }
        }
        inFlight[key] = task
        return task
    }
}
#endif
