import SwiftUI

// 订阅模块的纯展示逻辑：把后端模型压成页面要说的「一句话」。
//
// 这里的每个函数都逐行对应 Web 端的同名实现（lib/subscription-ui.ts、
// components/subscription-inspector-view.tsx 里的 wantedPresentation / milestonesOf 等），
// 文案与判定口径一字不改——两端对同一台服务器必须讲同一句话。
// 视图层只负责排版，不在视图里拼文案，改口径时只动这一个文件。

// MARK: - 颜色（取自 Web 银玻璃 :root 语义色）

/// 订阅页用到的语义色。Theme 里的 warning/info 是通用档，订阅页的状态色要与
/// Web `--warn / --info / --info-soft` 同值，否则两端并排看会觉得「不是一个颜色」。
enum SubsColor {
    /// --ok #4ade80（已入库 / 收尾）
    static let ok = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
    /// --info #7fb0ff（下载中 / 排队 / 常规动作）
    static let info = Color(red: 0x7F / 255, green: 0xB0 / 255, blue: 1)
    /// --info-soft #6aa7ff（进度条「下载中」段、追踪中状态点）
    static let infoSoft = Color(red: 0x6A / 255, green: 0xA7 / 255, blue: 1)
    /// --warn #f5c451（等待资源 / 预测窗口 / 待播出）
    static let warn = Color(red: 0xF5 / 255, green: 0xC4 / 255, blue: 0x51 / 255)
    /// --danger #ff6b6b
    static let danger = Color(red: 1, green: 0x6B / 255, blue: 0x6B / 255)
    /// 洗版专属青色 #2dd4bf（洗版徽标、进度条洗版段、洗版站）
    static let upgrade = Color(red: 0x2D / 255, green: 0xD4 / 255, blue: 0xBF / 255)
    /// 「洗版中」报告徽标 #34d399
    static let upgradeInFlight = Color(red: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255)
    /// 未定档 / 无法确认 #9ca3af
    static let neutral = Color(red: 0x9C / 255, green: 0xA3 / 255, blue: 0xAF / 255)
    /// 错误文字 #ff8a8a（链上的红色注解）
    static let reason = Color(red: 1, green: 0x8A / 255, blue: 0x8A / 255)
}

// MARK: - 时间与数字格式（同 Web lib/time.ts、lib/format.ts）

enum SubsFormat {
    /// 后端时间 → Date。纯日期（`2026-07-22`）按 UTC 零点解析，与浏览器 `new Date("2026-07-22")` 同口径。
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.count == 10, raw.dropFirst(4).first == "-" {
            return dayFormatter.date(from: raw)
        }
        return Formatters.date(raw)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = AppLanguage.locale
        if AppLanguage.identifier == "zh-Hans" { f.dateFormat = "yyyy/MM/dd HH:mm" }
        else { f.setLocalizedDateFormatFromTemplate("yyyyMMMdHHmm") }
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate("HHmm")
        return f
    }()

    /// 「2026/07/09 18:00」；空值「—」（Web formatDateTime）
    static func dateTime(_ raw: String?) -> String {
        guard let date = date(raw) else { return "—" }
        return dateTimeFormatter.string(from: date)
    }

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// 相对时间，与 dayjs zh-cn `fromNow()` 同一套阈值与措辞（「几秒前 / 3 分钟前 / 2 天前 / 3 天内」）；
    /// 空值「从未」（Web formatRelativeTime）。算法统一在 `Formatters.fromNow`（R-3：全 App 一套口径）。
    static func relative(_ raw: String?, now: Date = .now) -> String {
        guard let date = date(raw) else { return String(localized: .commonNever) }
        return Formatters.fromNow(date, now: now)
    }

    /// 秒数 → 「15 分钟」「1.5 小时」（Web formatDuration）
    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "—" }
        if AppLanguage.identifier == "en" { return AppFormatting.duration(seconds: seconds) }
        if seconds < 60 { return String(localized: .librarySubtitleGenerationElapsedSeconds(seconds)) }
        if seconds < 3600 { return String(localized: .libraryCloudReportMinutes(Int((Double(seconds) / 60).rounded()))) }
        let hours = Double(seconds) / 3600
        return hours == hours.rounded() ? String(localized: .libraryRecycleShortHours(Int(hours))) : String(format: "%.1f 小时", hours) // i18n-ignore: Chinese-only branch; English returns earlier
    }

    /// 选中的季：「第 1、2 季」/「Seasons 1, 2」
    static func seasonList(_ seasons: [Int]) -> String {
        let list = AppFormatting.list(seasons.sorted().map(String.init))
        return seasons.count == 1 ? String(localized: .subscriptionSeasonListOne(list)) : String(localized: .subscriptionSeasonListMany(list))
    }

    /// 完结季「从第 N 集起」（issue #950）的说明：收录范围之外，前面的集为什么不算进进度。
    /// 只认服务端明确标了完结（airing == false）的不设上界窗口；旧服务端不标，不显示
    static func fromWindowNotes(_ windows: [API.EpisodeWindowView]?) -> [String] {
        (windows ?? [])
            .filter { $0.end == nil && $0.airing == false }
            .map { String(localized: .subscriptionWindowFromNote(seasonName($0.seasonNumber), $0.start)) }
    }

    /// 字节 → 「1.46 GB」（Web formatBytes：1024 进制、两位小数、≥100 取整）
    static func bytes(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var number = Double(value)
        var index = 0
        while number >= 1024, index < units.count - 1 {
            number /= 1024
            index += 1
        }
        let rounded = (number * 100).rounded() / 100
        let text = rounded >= 100 || index == 0 ? String(format: "%.0f", rounded) : String(format: "%.2f", rounded)
        return "\(text) \(units[index])"
    }

    /// 「S01」式两位补零
    static func pad(_ value: Int) -> String { String(format: "%02d", value) }

    /// 「第 1、3 季」/「特别篇」
    static func seasonName(_ season: Int) -> String { season == 0 ? String(localized: .subscriptionInspectorSpecials) : String(localized: .subscriptionCollectionSeason(season)) }
}

// MARK: - 海报墙摘要（同 Web lib/subscription-ui.ts）

/// 海报内部底栏：「第 2 季 · ● 3 / 10」
struct SubscriptionCollectionMeta: Equatable {
    var label: String
    var value: String
    /// 启用中的未完结追更：数量前亮静态绿点
    var tracking: Bool
    /// 有单元在洗版：无绿点时亮青点
    var upgrading: Bool
    /// 洗版中的单元数（右上角「洗版 N」徽标）
    var upgradingCount: Int?
}

enum SubscriptionSummary {
    /// 连续季压成 S1–S3，离散季保留为 S1 · S3
    static func compactSeasonRange(_ seasons: [Int]) -> String? {
        let values = Array(Set(seasons)).sorted()
        guard var start = values.first else { return nil }
        var end = start
        var ranges: [String] = []
        func flush() { ranges.append(start == end ? "S\(start)" : "S\(start)–S\(end)") }
        for value in values.dropFirst() {
            if value == end + 1 { end = value; continue }
            flush()
            start = value
            end = value
        }
        flush()
        return ranges.joined(separator: " · ")
    }

    /// 是否已经全部到手：电影二元（入库即到手）；剧集要求 completed 且有入库
    static func fullyCollected(_ sub: API.SubscriptionView) -> Bool {
        if sub.media.kind == "movie" { return sub.progress.imported > 0 }
        return sub.status == "completed" && sub.progress.imported > 0
    }

    /// 海报斜标：状态优先于能力（已入库/已收齐 > 自动续订）
    static func ribbon(_ sub: API.SubscriptionView) -> DiscoverRibbon? {
        if fullyCollected(sub) {
            return DiscoverRibbon(label: sub.media.kind == "movie" ? String(localized: .subscriptionProgressImported) : String(localized: .subscriptionSectionsCollected), tone: .owned)
        }
        if sub.media.kind == "tv", sub.followFuture {
            return DiscoverRibbon(label: String(localized: .subscriptionRibbonFollowFuture), tone: .subscribed)
        }
        return nil
    }

    /// 把按季库存压成海报内的一行：在播剧只看最新一季，完结剧聚合订阅季；特别季不计入
    static func collectionMeta(_ sub: API.SubscriptionView) -> SubscriptionCollectionMeta? {
        guard sub.media.kind == "tv" else { return nil }
        let upgradingCount = sub.status != "paused" ? sub.progress.upgrading : 0
        let upgrading = upgradingCount > 0

        let allSeasons = sub.seasonCollection.filter { $0.seasonNumber > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }
        guard !allSeasons.isEmpty else { return nil }
        let selected = Set(sub.selectedSeasons.filter { $0 > 0 })
        var scoped = selected.isEmpty ? allSeasons : allSeasons.filter { selected.contains($0.seasonNumber) }
        let mediaStatus = sub.media.status?.lowercased() ?? ""
        let ended = sub.status == "completed" || ["ended", "canceled"].contains(mediaStatus)

        if !ended, sub.followFuture, let latest = allSeasons.last,
           !scoped.contains(where: { $0.seasonNumber == latest.seasonNumber }) {
            scoped = (scoped + [latest]).sorted { $0.seasonNumber < $1.seasonNumber }
        }
        guard !scoped.isEmpty else { return nil }

        func totalOf(_ season: API.SeasonOverview) -> Int {
            max(season.episodeCount ?? 0, season.airedCount, season.ownedCount)
        }

        if !ended {
            guard let latest = scoped.last else { return nil }
            let total = totalOf(latest)
            return SubscriptionCollectionMeta(
                label: String(localized: .subscriptionCollectionSeason(latest.seasonNumber)),
                value: latest.airedCount == 0 && latest.ownedCount == 0 ? String(localized: .subscriptionCollectionUnaired) : "\(latest.ownedCount) / \(total)",
                tracking: sub.status == "active",
                upgrading: upgrading,
                upgradingCount: upgrading ? upgradingCount : nil
            )
        }

        let total = scoped.reduce(0) { $0 + totalOf($1) }
        guard total > 0 else { return nil }
        let owned = scoped.reduce(0) { $0 + $1.ownedCount }
        let coversAll = scoped.count == allSeasons.count
        return SubscriptionCollectionMeta(
            label: scoped.count == 1 ? String(localized: .subscriptionCollectionSeason(scoped[0].seasonNumber)) : (coversAll ? String(localized: .subscriptionCollectionAllSeasons(scoped.count)) : String(localized: .subscriptionCollectionSeasons(scoped.count))),
            value: owned >= total ? String(localized: .subscriptionCollectionAllEpisodes(total)) : "\(owned) / \(total)",
            tracking: false,
            upgrading: upgrading,
            upgradingCount: upgrading ? upgradingCount : nil
        )
    }
}

// MARK: - 资源发布预测（release_forecast 是自由结构，按 Web ReleaseForecast 取需要的字段）

struct ReleaseForecast {
    var version: Int?
    var targetAirDate: String?
    var predictedAt: String?
    var windowStart: String?
    var windowEnd: String?
    var confidence: String?
    var siteIds: [String]

    init?(_ raw: [String: API.JSONValue]?) {
        guard let raw else { return nil }
        version = raw["version"]?.intValue
        targetAirDate = raw["target_air_date"]?.stringValue
        predictedAt = raw["predicted_at"]?.stringValue
        windowStart = raw["window_start"]?.stringValue
        windowEnd = raw["window_end"]?.stringValue
        confidence = raw["confidence"]?.stringValue
        siteIds = raw["sites"]?.arrayValue?.compactMap { $0["site_id"]?.stringValue } ?? []
    }
}

// MARK: - 今日到货时间轴（同 Web lib/subscription-ui.ts + lib/use-today-arrivals.ts）

struct TodayArrivalPresentation: Equatable {
    enum Stage { case expected, waiting, downloading, organizing }

    var stage: Stage
    var timeLabel: String
    var estimatedAt: Date?

    var statusLabel: String {
        switch stage {
        case .expected: String(localized: .subscriptionArrivalsStatusExpected)
        case .waiting: String(localized: .subscriptionArrivalsStatusWaiting)
        case .downloading: String(localized: .subscriptionArrivalsStatusDownloading)
        case .organizing: String(localized: .subscriptionArrivalsStatusOrganizing)
        }
    }

    var stageOrder: Int {
        switch stage {
        case .downloading: 1
        case .organizing: 2
        default: 0
        }
    }
}

enum TodayArrivals {
    private static func localDayKey(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    /// 首页只展示一个结果时间：同日写时刻，跨到次日写「明日」
    static func formatEstimated(_ date: Date, now: Date) -> String {
        let clock = SubsFormat.clock(date)
        if localDayKey(date) == localDayKey(now) { return String(localized: .subscriptionArrivalsApproximateTime(clock)) }
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now), localDayKey(date) == localDayKey(tomorrow) {
            return String(localized: .subscriptionArrivalsTomorrowTime(clock))
        }
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        let day = String(localized: .subscriptionFeedCalendarDay(parts.month ?? 0, parts.day ?? 0))
        return String(localized: .subscriptionArrivalsDateTime(day, clock))
    }

    /// 站点日历日 YYYY-MM-DD → 「M月D日」（按字段切分，不做时区换算）
    static func formatCalendarDay(_ day: String) -> String? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return String(localized: .subscriptionFeedCalendarDay(parts[1], parts[2]))
    }

    private static func estimatedWantedArrival(_ arrival: API.TodayArrivalView, predictedAt: Date, now: Date) -> Date? {
        let delay = TimeInterval(arrival.estimatedReleaseToImportMinutes * 60)
        let initial = predictedAt.addingTimeInterval(delay)
        if initial >= now { return initial }
        guard let nextProbe = SubsFormat.date(arrival.nextProbeAt) else { return nil }
        return max(nextProbe, now).addingTimeInterval(delay)
    }

    private static func pendingTimeLabel(_ arrival: API.TodayArrivalView) -> String {
        if arrival.daysAhead > 0, let day = formatCalendarDay(arrival.expectedDay) {
            return String(localized: .subscriptionArrivalsAirDate(day))
        }
        if let probe = SubsFormat.date(arrival.nextProbeAt) { return String(localized: .subscriptionArrivalsProbeTime(SubsFormat.clock(probe))) }
        return String(localized: .subscriptionArrivalsTimePending)
    }

    /// 后台阶段 + 出种预测 + 下载器 ETA → 「状态 + 一个入库时间」
    static func presentation(_ arrival: API.TodayArrivalView, task: API.DownloadTaskView?, now: Date) -> TodayArrivalPresentation {
        if arrival.status == "downloaded" || task?.state == "completed" {
            return TodayArrivalPresentation(stage: .organizing, timeLabel: String(localized: .subscriptionArrivalsFinishing), estimatedAt: now)
        }
        if arrival.status == "grabbed" {
            let eta = task?.state == "downloading" ? task?.etaSeconds : nil
            let estimated = eta.flatMap { $0 >= 0 ? now.addingTimeInterval(TimeInterval($0 + arrival.estimatedDownloadToImportMinutes * 60)) : nil }
            return TodayArrivalPresentation(
                stage: .downloading,
                timeLabel: estimated.map { formatEstimated($0, now: now) } ?? String(localized: .subscriptionArrivalsTimePending),
                estimatedAt: estimated
            )
        }
        let forecast = ReleaseForecast(arrival.releaseForecast)
        let predicted = SubsFormat.date(forecast?.predictedAt)
        let usable = forecast?.confidence != "volatile"
        let estimated = predicted.flatMap { usable ? estimatedWantedArrival(arrival, predictedAt: $0, now: now) : nil }
        return TodayArrivalPresentation(
            stage: predicted.map { $0 <= now } == true ? .waiting : .expected,
            timeLabel: estimated.map { formatEstimated($0, now: now) } ?? pendingTimeLabel(arrival),
            estimatedAt: estimated
        )
    }

    /// 集号压成区间：[1,2,3,5] →「E01–E03、E05」（订阅首页的 Hero / 日程同用）
    static func episodeRanges(_ episodes: [Int]) -> String {
        var ranges: [(Int, Int)] = []
        for episode in Array(Set(episodes)).sorted() {
            if let last = ranges.last, episode == last.1 + 1 {
                ranges[ranges.count - 1].1 = episode
            } else {
                ranges.append((episode, episode))
            }
        }
        return ranges.map { $0.0 == $0.1 ? "E\(SubsFormat.pad($0.0))" : "E\(SubsFormat.pad($0.0))–E\(SubsFormat.pad($0.1))" }
            .joined(separator: "、")
    }
}

// MARK: - 追踪项（工单）呈现（同 Web subscription-inspector-view.tsx）

/// 里程碑链的一站
struct Milestone: Identifiable {
    enum State { case done, now, todo, fail }
    var label: String
    var state: State
    /// 右侧时间列（发生时刻、搜索次数等）
    var time: String = ""
    var detail: String
    /// 红色补充行：被拒原因 / 投递失败 / 入库失败
    var why: String?
    /// 弱化补充行：投递种子名 / 资源时间链
    var sources: [String] = []
    var id: String { label }
}

/// 工单一行的状态：胶囊文字 + 颜色 + 说明
struct WantedPresentation {
    var label: String
    var color: Color
    var note: String
    /// 胶囊里放不下长词时的短名
    var short: String?

    var shortLabel: String { short ?? label }
}

enum WantedLogic {
    /// 工单 → 调度语义下的状态说明
    static func presentation(_ w: API.WantedView, now: Date = .now) -> WantedPresentation {
        if w.status == "imported" {
            if let up = w.upgrade, up.active {
                return .init(label: String(localized: .subscriptionUpgradeStateInFlight), color: SubsColor.upgrade, note: String(localized: .subscriptionMilestoneUpgradeTarget(up.currentLabel, up.targetLabel)))
            }
            if let up = w.upgrade, up.indeterminate {
                return .init(label: String(localized: .subscriptionProgressImported), color: SubsColor.ok, note: String(localized: .subscriptionWantedIndeterminate(up.currentLabel)))
            }
            if let up = w.upgrade {
                return .init(label: String(localized: .subscriptionProgressImported), color: SubsColor.ok, note: String(localized: .subscriptionWantedImportedQuality(up.currentLabel, SubsFormat.dateTime(w.importedAt))))
            }
            return .init(label: String(localized: .subscriptionProgressImported), color: SubsColor.ok, note: String(localized: .subscriptionWantedImportedAt(SubsFormat.dateTime(w.importedAt))))
        }
        if w.status == "downloaded" {
            return .init(label: String(localized: .subscriptionWantedDownloaded), color: SubsColor.ok, note: String(localized: .subscriptionWantedDownloadedAt(SubsFormat.dateTime(w.downloadedAt ?? w.grabbedAt))))
        }
        if w.status == "grabbed" {
            return .init(label: String(localized: .subscriptionWantedSubmitted), color: SubsColor.ok, note: String(localized: .subscriptionWantedSubmittedAgo(SubsFormat.relative(w.grabbedAt))), short: String(localized: .subscriptionWantedSubmittedShort))
        }
        if let smart = SmartSelection(w) {
            return .init(label: smart.presentation.label, color: SubsColor.info, note: smart.presentation.note)
        }
        guard let nextSearch = w.nextSearchAt, let due = SubsFormat.date(nextSearch) else {
            return .init(label: String(localized: .subscriptionWantedUndated), color: SubsColor.neutral, note: String(localized: .subscriptionWantedUndatedNote))
        }
        if let airDate = w.airDate, let forecast = ReleaseForecast(w.releaseForecast),
           forecast.version == 1, forecast.targetAirDate == airDate, forecast.confidence != "volatile",
           !forecast.siteIds.isEmpty, let windowEnd = SubsFormat.date(forecast.windowEnd), windowEnd >= now {
            let sites = forecast.siteIds.prefix(2).joined(separator: "、")
            return .init(
                label: String(localized: .subscriptionWantedForecast), color: SubsColor.warn,
                note: String(localized: .subscriptionWantedForecastNote(SubsFormat.dateTime(forecast.windowStart), SubsFormat.dateTime(forecast.windowEnd), sites)),
                short: String(localized: .subscriptionWantedForecastShort)
            )
        }
        if let airDate = w.airDate, let air = SubsFormat.date(airDate), air > now {
            return .init(label: String(localized: .subscriptionCollectionUnaired), color: SubsColor.warn, note: String(localized: .subscriptionWantedAirThenSearch(airDate, SubsFormat.dateTime(nextSearch))))
        }
        if due <= now {
            return .init(
                label: String(localized: .subscriptionWantedQueued), color: SubsColor.info,
                note: w.lastSearchAt != nil ? String(localized: .subscriptionWantedLastSearch(SubsFormat.relative(w.lastSearchAt))) : String(localized: .subscriptionWantedWaitingSearch),
                short: String(localized: .subscriptionWantedQueuedShort)
            )
        }
        if w.lastSearchAt == nil, due.timeIntervalSince(now) > 3600 {
            return .init(label: String(localized: .subscriptionWantedScheduled), color: SubsColor.warn, note: String(localized: .subscriptionWantedBeforeSchedule(SubsFormat.dateTime(nextSearch))))
        }
        return .init(label: String(localized: .subscriptionWantedCooldown), color: SubsColor.info, note: String(localized: .subscriptionWantedRetryAt(SubsFormat.dateTime(nextSearch))))
    }

    /// 实时下载快照 → 一行进度说明。
    /// 成员拿到的是精简口径（种子名、下载器名、错误原文为空，member-permissions-v2 §3.2），只用进度类字段；
    /// 出错时没有原文就不叫成员「去下载器处理」（成员进不了下载器），改为提示由管理员处理
    static func downloadNote(_ d: API.SubscriptionDownloadView) -> String {
        if d.state == "missing" { return String(localized: .subscriptionDownloadMissing) }
        let pct = d.progress.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? ""
        switch d.state {
        case "completed": return String(localized: .subscriptionDownloadCompleted)
        case "paused": return String(localized: .subscriptionDownloadPaused(pct))
        case "error":
            guard let message = d.errorMessage, !message.isEmpty else {
                return String(localized: .subscriptionDownloadMemberErrorNote(pct))
            }
            return String(localized: .subscriptionDownloadAdminError(pct, message))
        case "stalled": return String(localized: .subscriptionDownloadStalled(pct))
        default:
            var parts = [pct]
            if let speed = d.dlspeedBytes, speed > 0 { parts.append("\(SubsFormat.bytes(speed))/s") }
            if let eta = d.etaSeconds { parts.append(String(localized: .subscriptionDownloadRemaining(String(SubsFormat.duration(eta))))) }
            if let size = d.sizeBytes, parts.count == 1 { parts.append(SubsFormat.bytes(size)) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// 资源时间链 → 「隔了多久才拉到」；超过 7 天的存量耗时不展示
    static func resourceTimingNote(_ timing: API.ResourceTimingView?, previous: Bool) -> String? {
        guard let timing else { return nil }
        if let total = timing.publishToSubmitSeconds, total > 7 * 24 * 3600 { return nil }
        func delay(_ seconds: Int) -> String { seconds < 60 ? String(localized: .subscriptionTimingUnderMinute) : SubsFormat.duration(seconds) }
        let prefix = (previous ? String(localized: .subscriptionTimingPreviousPrefix) : "")
            + (timing.dryRun ? String(localized: .subscriptionTimingDryRunPrefix) : "")
        let site = timing.siteId
        if let seen = timing.publishToSeenSeconds, let submit = timing.seenToSubmitSeconds, let total = timing.publishToSubmitSeconds {
            return String(localized: .subscriptionTimingFullNote(prefix, site, delay(seen), delay(submit), delay(total)))
        }
        if let total = timing.publishToSubmitSeconds { return String(localized: .subscriptionTimingReleaseToSubmitNote(prefix, site, delay(total))) }
        if let submit = timing.seenToSubmitSeconds { return String(localized: .subscriptionTimingSeenToSubmitNote(prefix, site, delay(submit))) }
        return nil
    }

    /// 工单 → 里程碑链：播出 → 搜索 → 投递 → 下载 → 入库 →（洗版）
    static func milestones(
        _ w: API.WantedView,
        isMovie: Bool,
        live: API.SubscriptionDownloadView?,
        failure: API.ActivityView?,
        isSmart: Bool = false,
        now: Date = .now
    ) -> [Milestone] {
        var chain: [Milestone] = []
        // 1. 播出 / 上映（定档站）
        if isMovie {
            let undated = w.status == "wanted" && w.nextSearchAt == nil
            chain.append(undated
                ? Milestone(label: String(localized: .subscriptionMilestoneRelease), state: .now, detail: String(localized: .subscriptionMilestoneReleaseUndated))
                : Milestone(label: String(localized: .subscriptionMilestoneRelease), state: .done, detail: String(localized: .subscriptionMilestoneReleased)))
        } else if let airDate = w.airDate {
            let future = SubsFormat.date(airDate).map { $0 > now } ?? false
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneAir), state: .done, time: airDate, detail: future ? String(localized: .subscriptionArrivalsAirDate(airDate)) : String(localized: .subscriptionMilestoneAired)))
        } else {
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneAir), state: .now, detail: String(localized: .subscriptionMilestoneAirUndated)))
        }
        let preAir = chain[0].state == .now

        // 2. 搜索
        if w.status != "wanted" {
            chain.append(Milestone(
                label: String(localized: .commonSearch), state: .done,
                time: w.lastSearchAt != nil ? SubsFormat.relative(w.lastSearchAt) : "",
                detail: w.searchAttempts > 0 ? String(localized: .subscriptionMilestoneFoundAfter(w.searchAttempts)) : String(localized: .subscriptionMilestonePassiveMatch)
            ))
        } else if preAir {
            chain.append(Milestone(label: String(localized: .commonSearch), state: .todo, detail: String(localized: .subscriptionMilestoneSearchAfterDate)))
        } else {
            chain.append(Milestone(
                label: String(localized: .commonSearch), state: .now,
                time: w.searchAttempts > 0 ? String(localized: .subscriptionMilestoneSearchAttempts(w.searchAttempts)) : "",
                detail: presentation(w, now: now).note,
                why: w.selectionState?["reason"]?.stringValue == "identity_unconfirmed" ? nil : w.lastRejectReason.map { String(localized: .subscriptionMilestoneRejected($0)) }
            ))
        }

        // 3. 投递
        if let grabbedAt = w.grabbedAt {
            let sources = [w.grabTitle, resourceTimingNote(w.resourceTiming, previous: false)].compactMap { $0 }.filter { !$0.isEmpty }
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneDispatch), state: .done, time: SubsFormat.relative(grabbedAt), detail: String(localized: .subscriptionMilestoneSubmitted), sources: sources))
        } else {
            let lastTiming = resourceTimingNote(w.resourceTiming, previous: true)
            let dispatchFailure = failure?.type == "dispatch_failed" ? failure : nil
            chain.append(Milestone(
                label: String(localized: .subscriptionMilestoneDispatch), state: .todo,
                detail: dispatchFailure != nil ? String(localized: .subscriptionMilestoneDispatchRetry) : isSmart
                    ? (SmartSelection(w) != nil && w.selectionState?["reason"]?.stringValue != "identity_unconfirmed"
                        ? String(localized: .subscriptionMilestoneWaitingSmart) : String(localized: .subscriptionMilestoneWaitingQualified))
                    : String(localized: .subscriptionMilestoneNoRuleMatch),
                why: dispatchFailure?.message,
                sources: lastTiming.map { [$0] } ?? []
            ))
        }

        // 4. 下载（入库发生过即说明下载必然完成）
        if let downloadedAt = w.downloadedAt ?? w.importedAt {
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneDownload), state: .done, time: SubsFormat.relative(downloadedAt), detail: String(localized: .subscriptionMilestoneOnDisk)))
        } else if w.grabbedAt != nil {
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneDownload), state: .now, time: String(localized: .subscriptionMilestoneInProgress), detail: live.map(downloadNote) ?? String(localized: .subscriptionMilestoneWaitingProgress)))
        } else {
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneDownload), state: .todo, detail: String(localized: .subscriptionMilestoneWaitingDispatch)))
        }

        // 5. 入库
        if let importedAt = w.importedAt {
            chain.append(Milestone(
                label: String(localized: .subscriptionMilestoneImport), state: .done, time: SubsFormat.relative(importedAt),
                detail: w.upgrade.map { String(localized: .subscriptionMilestoneImportedQuality($0.currentLabel)) } ?? String(localized: .subscriptionMilestoneImported)
            ))
        } else if failure?.type == "import_failed" {
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneImport), state: .fail, detail: String(localized: .subscriptionMilestoneImportFailed), why: failure?.message))
        } else if w.downloadedAt != nil {
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneImport), state: .now, detail: String(localized: .subscriptionMilestoneWaitingImport)))
        } else {
            chain.append(Milestone(label: String(localized: .subscriptionMilestoneImport), state: .todo, detail: String(localized: .subscriptionMilestoneImportAfterDownload)))
        }

        // 6. 洗版（规则组配了洗版目标才有）
        if let up = w.upgrade {
            if up.active {
                chain.append(Milestone(
                    label: String(localized: .subscriptionRulesUpgrade), state: .now,
                    time: up.searchAttempts > 0 ? String(localized: .subscriptionMilestoneSearchAttempts(up.searchAttempts)) : "",
                    detail: String(localized: .subscriptionMilestoneUpgradeTarget(up.currentLabel, up.targetLabel))
                ))
            } else if up.indeterminate {
                chain.append(Milestone(label: String(localized: .subscriptionRulesUpgrade), state: .now, detail: String(localized: .subscriptionMilestoneIndeterminate(up.currentLabel))))
            } else {
                chain.append(Milestone(label: String(localized: .subscriptionRulesUpgrade), state: .done, detail: String(localized: .subscriptionMilestoneCurrentQuality(up.currentLabel))))
            }
        }
        return chain
    }

    /// 卡点 = 第一个非 done 的站；全 done 时亮终点站
    static func stuckIndex(_ chain: [Milestone]) -> Int {
        chain.firstIndex { $0.state != .done } ?? max(chain.count - 1, 0)
    }

    /// 工单 → 此刻仍未解决的失败活动（该工单最新一条活动仍是入库/投递失败）
    static func pendingFailures(_ activities: [API.ActivityView]) -> [Int: API.ActivityView] {
        var failures: [Int: API.ActivityView] = [:]
        var seen = Set<Int>()
        for activity in activities {
            guard let wantedId = activity.wantedItemId, !seen.contains(wantedId) else { continue }
            seen.insert(wantedId)
            if activity.type == "import_failed" || activity.type == "dispatch_failed" {
                failures[wantedId] = activity
            }
        }
        return failures
    }

    /// 默认展开：最新一季 ∪ 有在途工单的季
    static func defaultOpenSeasons(_ wanted: [API.WantedView]) -> Set<Int> {
        var open = Set<Int>()
        let regular = wanted.filter { $0.seasonNumber > 0 }
        let pool = regular.isEmpty ? wanted : regular
        if let latest = pool.map(\.seasonNumber).max() { open.insert(latest) }
        for w in wanted where w.status == "grabbed" || w.status == "downloaded" { open.insert(w.seasonNumber) }
        return open
    }

    /// 活动类型 → 时间线圆点颜色：绿=成果，青=洗版，红=失败，黄=暂停/异常，蓝=常规
    static func activityColor(_ type: String) -> Color {
        switch type {
        case "grabbed", "match_accepted", "completed", "downloaded", "imported", "replacement_promoted": SubsColor.ok
        case "upgrade_grabbed", "upgraded": SubsColor.upgrade
        case "match_rejected", "dispatch_failed", "import_failed": SubsColor.danger
        case "paused", "download_stalled", "upgrade_verify_failed", "spec_mismatch": SubsColor.warn
        default: SubsColor.info
        }
    }
}
