import Foundation

/// 字幕外观（对应 Web `lib/player/subtitles.ts` 的 SubtitleStyle）。
/// 时间轴偏移刻意不持久化：它是逐文件的修正，跨片带着只会错（同 Web）。
///
/// 不设「描边」（Web 同）：中文字形由互相重叠的笔画轮廓拼成，文字描边会沿每个轮廓各描一圈，
/// 笔画交叉处全是黑缝（真机实测）。不开背景时白字统一带一层柔和投影，亮画面也读得清。
/// 旧版本存下的 outline 键读的时候直接忽略。
struct SubtitleStyle: Equatable, Codable {
    /// 相对视频高度的字号百分比（默认 5.2%）
    var fontScale: Double = 5.2
    /// 时间轴微调（秒），正数 = 字幕延后
    var offsetSeconds: Double = 0
    /// 距画面底部的百分比（默认 8%）
    var bottomPercent: Double = 8
    var background: Bool = false

    enum CodingKeys: String, CodingKey { case fontScale, bottomPercent, background }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontScale = (try? container.decode(Double.self, forKey: .fontScale)) ?? 5.2
        bottomPercent = (try? container.decode(Double.self, forKey: .bottomPercent)) ?? 8
        background = (try? container.decode(Bool.self, forKey: .background)) ?? false
    }

    /// 时间轴微调步进：0.1 秒是人耳能分辨的最小对不齐量级
    static let offsetStep = 0.1

    /// 超过 ±30 秒基本不是「没对齐」而是拿错了字幕文件；并消掉浮点累加误差
    static func clampOffset(_ seconds: Double) -> Double {
        (min(30, max(-30, seconds)) * 10).rounded() / 10
    }
}

/// 播放器的本机偏好。键名带 `movieclaw.player.` 前缀，与 Web localStorage 的键同名同义。
enum PlayerPreferences {
    private static let defaults = UserDefaults.standard

    static var subtitleStyle: SubtitleStyle {
        get {
            guard let data = defaults.data(forKey: "movieclaw.player.subtitle-style"),
                  let style = try? JSONDecoder().decode(SubtitleStyle.self, from: data) else { return SubtitleStyle() }
            return style
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "movieclaw.player.subtitle-style")
            }
        }
    }

    /// 本机的播放设备标识（活动页「正在播放」按它区分会话；服务端会再加上成员命名空间）
    static var deviceId: String {
        if let stored = defaults.string(forKey: "movieclaw.player.device-id"),
           stored.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil {
            return stored
        }
        let generated = "ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
        defaults.set(generated, forKey: "movieclaw.player.device-id")
        return generated
    }
}

/// 画质档（对应 Web `lib/player/quality.ts`）。语义是**上限**：源不超所选档就照常直通。
struct QualityOption: Identifiable, Hashable {
    let maxHeight: Int?
    let label: String
    let hint: String

    var id: String { label }

    static let all: [QualityOption] = [
        QualityOption(maxHeight: nil, label: "原画", hint: "不限画质：能直通就播原文件，放不了时按原分辨率转码"),
        QualityOption(maxHeight: 1080, label: "1080p", hint: "约 6 Mbps"),
        QualityOption(maxHeight: 720, label: "720p", hint: "约 3 Mbps，网络一般时选它"),
        QualityOption(maxHeight: 480, label: "480p", hint: "约 1.5 Mbps，弱网救急"),
    ]
}

/// 分享访客的本机进度（对应 Web `lib/player/local-progress.ts`）：
/// 访客没有成员身份，进度不落服务端，只记在这台设备上，按分享 slug 分命名空间。
enum ShareLocalProgress {
    struct Record: Codable {
        var positionMs: Int
        var audioTrack: String?
        var subtitleTrack: String?
        var updatedAt: Double
    }

    private static func key(_ slug: String, _ unit: PlaybackUnit) -> String {
        "movieclaw.share.progress.\(slug).\(unit.mediaItemId).\(unit.season)x\(unit.episode)"
    }

    static func read(_ slug: String, _ unit: PlaybackUnit) -> Record? {
        guard let data = UserDefaults.standard.data(forKey: key(slug, unit)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func write(_ slug: String, _ unit: PlaybackUnit, positionMs: Int?, audio: String?, subtitle: String?) {
        let previous = read(slug, unit)
        let record = Record(
            positionMs: max(0, positionMs ?? previous?.positionMs ?? 0),
            audioTrack: audio ?? previous?.audioTrack,
            subtitleTrack: subtitle ?? previous?.subtitleTrack,
            updatedAt: Date().timeIntervalSince1970
        )
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: key(slug, unit))
        }
    }
}

/// 画质按影片、按网络环境记（2026-09-28 用户拍板）：在外面给《哪吒》选了 1080p，回到家打开还是原画；
/// 每部片各记各的，剧集整部剧共用一份（按条目 id）。只存限了画质的选择，选回「自动」就删掉这一条。
/// 原来画质是全局一个值：路上选一次 720p，之后所有片子、回到家也都在转码。
enum QualityMemory {
    private static let key = "movieclaw.player.quality-by-title"
    /// 最多记这么多条，超出按最久没用的先丢
    static let limit = 300

    private static func entryKey(_ mediaItemId: Int, _ network: PlaybackNetwork) -> String {
        "\(network.rawValue):\(mediaItemId)"
    }

    /// [条目键: [画质上限, 记下的时刻]]
    private static var entries: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func quality(mediaItemId: Int, network: PlaybackNetwork) -> Int? {
        guard let height = entries[entryKey(mediaItemId, network)]?.first.map(Int.init),
              QualityOption.all.contains(where: { $0.maxHeight == height }) else { return nil }
        return height
    }

    static func remember(_ maxHeight: Int?, mediaItemId: Int, network: PlaybackNetwork) {
        var all = entries
        let key = entryKey(mediaItemId, network)
        if let maxHeight {
            all[key] = [Double(maxHeight), Date().timeIntervalSince1970]
            if all.count > limit {
                let oldest = all.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(all.count - limit)
                oldest.forEach { all.removeValue(forKey: $0.key) }
            }
        } else {
            all.removeValue(forKey: key)
        }
        entries = all
    }
}

/// 开播提示「已沿用上次的选择」（2026-09-28 用户拍板）：画质、音轨、字幕都按片记，
/// 下次打开这部片时，只有**不是默认**的选择才提示几秒——免得对着 720p 的画面、日语音轨纳闷「怎么是这样」，
/// 默认的就不打扰。
enum RememberedChoices {
    /// 各项传 nil = 这一项是默认（或这次没沿用记忆），不提
    static func notice(quality: Int?, network: PlaybackNetwork, audio: String?, subtitle: String?) -> String? {
        var parts: [String] = []
        if let quality {
            // 画质按网络环境分开记：点明是哪个环境下的选择，回到家看到原画不会以为记忆失灵
            parts.append(network.label.map { "画质 \(quality)p（\($0)）" } ?? "画质 \(quality)p")
        }
        if let audio { parts.append("音轨 \(audio)") }
        if let subtitle { parts.append("字幕 \(subtitle)") }
        return parts.isEmpty ? nil : "已沿用上次的选择：" + parts.joined(separator: "，")
    }

    /// 菜单标签（「日语 · AC3 · 5.1」「简体中文 · 文本」）在提示里只留语言；同语言有好几条时留全称才分得清
    static func shortLabel(_ label: String, among labels: [String]) -> String {
        let name = { (text: String) in text.components(separatedBy: " · ").first ?? text }
        let short = name(label)
        return labels.filter { name($0) == short }.count > 1 ? label : short
    }
}

