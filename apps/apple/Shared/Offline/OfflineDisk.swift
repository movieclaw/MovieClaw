#if os(iOS)
import Foundation

/// 离线存档的路径与读写（不在主线程）。写一律原子（临时文件 + 改名），所有写都排在同一个串行队列上：
/// 下载回调、删除、元数据刷新、进度写入不会互相踩。
nonisolated enum OfflineDisk {
    static let queue = DispatchQueue(label: "io.movieclaw.offline.disk", qos: .utility)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Application Support/Offline：不进 iCloud 备份（视频动辄几个 GB，展示数据回来能重拉）。
    /// 文件保护用系统默认（首次解锁后可读写）：锁屏时后台下载完成也要能写进来
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "Offline", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var copy = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? copy.setResourceValues(values)
        }
        return url
    }

    static func ownerDir(_ key: String) -> URL { root.appending(path: key, directoryHint: .isDirectory) }
    static func itemsDir(_ key: String) -> URL { ownerDir(key).appending(path: "items", directoryHint: .isDirectory) }
    static func itemDir(_ key: String, _ itemId: Int) -> URL { itemsDir(key).appending(path: String(itemId), directoryHint: .isDirectory) }
    static func unitDir(_ key: String, _ itemId: Int, _ fileId: Int) -> URL {
        itemDir(key, itemId).appending(path: "units/\(fileId)", directoryHint: .isDirectory)
    }
    static func imagesDir(_ key: String, _ itemId: Int) -> URL { itemDir(key, itemId).appending(path: "images", directoryHint: .isDirectory) }
    static func viewingsDir(_ key: String) -> URL { ownerDir(key).appending(path: "viewings", directoryHint: .isDirectory) }

    // MARK: 读写

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// 接口模型原样存（与 APIClient 同一个编解码器：生成的模型自带 CodingKeys）
    static func writeAPI<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try APIClient.encoder.encode(value).write(to: url, options: .atomic)
    }

    static func readAPI<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? APIClient.decoder.decode(T.self, from: data)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 目录下全部文件的大小（存储页的「占用」）
    static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    /// 本机还剩多少空间（「重要用途」口径：系统会为它清缓存）
    static var availableBytes: Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: 存档里的几类文件

    static func ownerFile(_ key: String) -> URL { ownerDir(key).appending(path: "owner.json") }
    static func summaryFile(_ key: String, _ itemId: Int) -> URL { itemDir(key, itemId).appending(path: "summary.json") }
    static func detailFile(_ key: String, _ itemId: Int) -> URL { itemDir(key, itemId).appending(path: "detail.json") }
    static func libraryFile(_ key: String, _ itemId: Int) -> URL { itemDir(key, itemId).appending(path: "library.json") }
    static func seasonFile(_ key: String, _ itemId: Int, _ season: Int) -> URL {
        itemDir(key, itemId).appending(path: "seasons/\(season).json")
    }
    static func progressFile(_ key: String, _ itemId: Int) -> URL { itemDir(key, itemId).appending(path: "progress.json") }
    static func unitFile(_ key: String, _ itemId: Int, _ fileId: Int) -> URL { unitDir(key, itemId, fileId).appending(path: "unit.json") }
    static func playbackFile(_ key: String, _ itemId: Int, _ fileId: Int) -> URL {
        unitDir(key, itemId, fileId).appending(path: "playback.json")
    }
    static func resumeDataFile(_ key: String, _ itemId: Int, _ fileId: Int) -> URL {
        unitDir(key, itemId, fileId).appending(path: "resume.data")
    }
    static func viewingFile(_ key: String, _ id: String) -> URL { viewingsDir(key).appending(path: "\(id).json") }

    /// 一个账号存档的全部内容（启动时在后台读一遍，每个文件都很小）
    struct Snapshot: Sendable {
        var items: [Int: OfflineItemSummary] = [:]
        var units: [Int: OfflineUnit] = [:]
        var progress: [Int: [String: OfflineProgress]] = [:]
    }

    static func loadSnapshot(_ key: String) -> Snapshot {
        var snapshot = Snapshot()
        for itemDir in children(itemsDir(key)) {
            guard let itemId = Int(itemDir.lastPathComponent) else { continue }
            guard let summary = read(OfflineItemSummary.self, from: itemDir.appending(path: "summary.json")),
                  summary.format == 1 else { continue }
            var hasUnit = false
            for unitDir in children(itemDir.appending(path: "units")) {
                guard let unit = read(OfflineUnit.self, from: unitDir.appending(path: "unit.json")), unit.format == 1 else { continue }
                var loaded = unit
                // 下完了却没来得及标（移动文件与写状态之间被杀）：视频文件只在下载任务完整结束后才移进来，
                // 文件在就是下完了
                if loaded.state != .done {
                    let media = unitDir.appending(path: loaded.mediaFileName)
                    if let size = (try? media.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
                        loaded.state = .done
                        loaded.receivedBytes = Int64(size)
                        loaded.expectedBytes = Int64(size)
                        loaded.completedAt = loaded.completedAt ?? Date()
                        try? write(loaded, to: unitDir.appending(path: "unit.json"))
                    }
                }
                snapshot.units[loaded.fileId] = loaded
                hasUnit = true
            }
            guard hasUnit else {
                // 单元都删光了还剩个空条目（删除中途被杀）：收拾掉
                remove(itemDir)
                continue
            }
            snapshot.items[itemId] = summary
            if let progress = read([String: OfflineProgress].self, from: itemDir.appending(path: "progress.json")) {
                snapshot.progress[itemId] = progress
            }
        }
        return snapshot
    }
}
#endif
