#if os(iOS)
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
        guard let url = URL(string: path, relativeTo: api.server.origin)?.absoluteURL else {
            throw APIError.decoding("地址无效：\(path)")
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
            throw APIError.http(status: status, message: "下载附带文件失败（HTTP \(status)）", code: nil)
        }
        return data
    }

    private func write(_ data: Data, to url: URL) async throws {
        try await OfflineDisk.perform {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    static func safeName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(80))
    }
}
#endif
