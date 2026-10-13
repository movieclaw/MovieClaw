#if os(iOS)
import CryptoKit
import Foundation

// 离线下载的本机存档（docs/design/offline-download.md §3）。
//
// 每个条目一个文件夹，文件夹本身就是事实来源：删文件夹即删干净。接口模型（详情、库、分集）原样存，
// 离线时原样喂给同一个页面；下面这几个是自有结构，都带 `format`，不认识的版本跳过、不崩。
//
// ```
// Application Support/Offline/<sha(实例号|用户名)>/
//   owner.json
//   items/<条目>/summary.json · detail.json · library.json · seasons/<季>.json · progress.json · images/
//   items/<条目>/units/<文件>/unit.json · playback.json · media.<扩展名> · subs/ · fonts/
//   viewings/<观看记录>.json
// ```

/// 本机副本属于哪台服务器上的哪个账号：按实例号认服务器（局域网 IP 与域名是同一台）
nonisolated struct OfflineOwner: Codable, Sendable, Hashable {
    var format = 1
    var instanceId: String
    var username: String
    /// 最近一次用的服务器地址（下载、补传都发到这里）
    var origin: URL

    var key: String { OfflineOwner.key(instanceId: instanceId, username: username) }

    static func key(instanceId: String, username: String) -> String {
        let digest = SHA256.hash(data: Data("\(instanceId)|\(username)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// 一个播放单元（一部电影 / 一集）的本机副本：下载状态机
nonisolated struct OfflineUnit: Codable, Sendable, Hashable, Identifiable {
    enum State: String, Codable, Sendable {
        /// 拉清单、字幕、字体、图片（要在线）
        case preparing
        /// 视频下载任务已建、等系统排上
        case queued
        case downloading
        /// 用户暂停（带续传数据取消）
        case paused
        case failed
        case done
    }

    var format = 1
    var fileId: Int
    var mediaItemId: Int
    var season: Int
    var episode: Int
    /// original / 1080p / 720p / 480p
    var profile: String
    var profileLabel: String
    var state: State
    var expectedBytes: Int64
    var receivedBytes: Int64 = 0
    /// 视频存盘的扩展名（原画按原容器，转码档 mp4）
    var fileExtension: String
    var exportId: String?
    /// 失败原因（给人看的中文）
    var error: String?
    /// 失败能不能自动重试（网络类、5xx、排队中能；无权限、文件没了、空间不足不能）
    var retryable = true
    var attempts = 0
    var nextRetryAt: Date?
    var createdAt: Date
    var completedAt: Date?
    /// 本机打不开（引擎读不了）：提示重新下载
    var damaged = false

    var id: Int { fileId }
    var unitKey: String { "\(season)-\(episode)" }
    var isMovie: Bool { season == 0 && episode == 0 }
    var playable: Bool { state == .done && !damaged }
    var isActive: Bool { state != .done }
    var mediaFileName: String { "media.\(fileExtension)" }

    var progressFraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }
}

/// 条目的展示摘要（索引用的小文件）：离线首页、海报墙、存储页只读它
nonisolated struct OfflineItemSummary: Codable, Sendable, Hashable, Identifiable {
    var format = 1
    var mediaItemId: Int
    var libraryId: Int
    var libraryName: String
    var libraryKind: String
    /// movie / tv / video
    var kind: String
    var title: String
    var year: Int?
    var posterUrl: String?
    var backdropUrl: String?
    var primaryAspect: Double
    /// 最近一次加下载的时间（离线海报墙「最近下载」排序）
    var addedAt: Date

    var id: Int { mediaItemId }
}

/// 播放一个本机单元要的数据（与服务端会话里的同名字段一致）
nonisolated struct OfflinePlaybackSpec: Codable, Sendable {
    nonisolated struct Subtitle: Codable, Sendable, Hashable {
        /// 播放器里的轨引用：一律 `external:<存盘文件名>`（转码档里没有内封轨，原画档的内封轨由引擎自己读）
        var ref: String
        var fileName: String
        /// vtt（文本）/ ass
        var kind: String
        var language: String?
        var title: String?
        var isDefault: Bool
        var isForced: Bool
        var isAi: Bool
        /// 服务端的原轨引用（轨记忆、上报用）
        var sourceRef: String
    }

    var format = 1
    var durationMs: Int?
    var chapters: [API.PlaybackChapterMarkView]
    var segments: [API.PlaybackSegmentView]
    var audioTracks: [API.AudioTrackView]
    var defaultAudio: String?
    var subtitles: [Subtitle]
    var fonts: [String]
    var resolution: String?
    var videoCodec: String?
    var container: String?
}

/// 一个单元的本机续播点（离线续播、离线「接着看」）
nonisolated struct OfflineProgress: Codable, Sendable, Hashable {
    var positionMs: Int
    var played: Bool
    var durationMs: Int?
    var updatedAt: Date
}

/// 一次本机播放（docs/design/offline-download.md §7）：先落盘，能连上就发，服务端按编号合并
nonisolated struct OfflineViewing: Codable, Sendable, Hashable {
    var format = 1
    var viewingId: String
    var mediaItemId: Int
    var season: Int
    var episode: Int
    var fileId: Int
    var startedAt: Date
    var updatedAt: Date
    var startPositionMs: Int
    var positionMs: Int
    var watchedMs: Int
    var completed: Bool
    var ended: Bool
    var durationMs: Int?
    /// 有没有还没发出去的更新
    var dirty: Bool
}

/// 离线下载的本机设置
nonisolated enum OfflineSettings {
    private static let cellularKey = "movieclaw.offline.allowCellular"
    private static let profileKey = "movieclaw.offline.defaultProfile"

    /// 用蜂窝网络下载（默认关：只在 Wi-Fi 下）
    static var allowCellular: Bool {
        get { UserDefaults.standard.bool(forKey: cellularKey) }
        set { UserDefaults.standard.set(newValue, forKey: cellularKey) }
    }

    /// 上次选的档位：下次打开选档 sheet 时默认选它
    static var lastProfile: String? {
        get { UserDefaults.standard.string(forKey: profileKey) }
        set { UserDefaults.standard.set(newValue, forKey: profileKey) }
    }

    /// 开始前至少留出的空间（预计大小之外）
    static let reserveBytes: Int64 = 2 * 1024 * 1024 * 1024
}
#endif
