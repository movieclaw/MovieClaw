import SwiftUI

// MARK: - 播出日历（issue #547，Web `lib/air-schedule.ts`）的口径：iPhone、Mac、Apple TV 共用，各端只管怎么画
//
// 只在本季还有今天或以后的播出日期时出现（服务端不给 air_schedule 就整块不画）。日期一律是 yyyy-MM-dd 的日历日，
// 按 UTC 零点换算，「今天」由服务端按站点日历给出，不用本机时钟。

enum AirTone {
    case owned, missing, today, todayFree, upcoming, absent
}

struct AirDay: Identifiable, Equatable {
    let date: String
    let episodes: [API.EpisodeView]
    let past: Bool
    let today: Bool
    let finale: Bool
    var id: String { date }
}

/// 日程里的一行：分组标题、停更说明、一个播出日
enum AirRow: Identifiable {
    case group(Int)
    case gap(after: String, text: String)
    case day(AirDay)

    var id: String {
        switch self {
        case let .group(group): "group-\(group)"
        case let .gap(after, _): "gap-\(after)"
        case let .day(day): day.date
        }
    }
}

/// 日程一行右侧写什么
enum AirDayStatus {
    /// 全部入库
    case owned
    /// 已播、库里没有、也不在订阅范围内
    case absent
    /// 已播、订阅在找：能补时给补集入口，不能补时只在集号下面写「缺第 N 集」
    case missing
    /// 今天的入库进度
    case arrival(text: String, color: Color)
    /// 「明天 / 6 天后」
    case relative(String)
    case none
}

/// 时间线上的点：今天实心蓝、大结局琥珀圈、已播按入库与否，之后的空心圈
enum AirDot {
    case today, finale, missing, owned, upcoming
}

/// 入口摘要：今天 / 下次更新哪一集 + 本季节奏，另一头是入库时刻或还有几天
struct AirSummary {
    struct Side {
        let value: String
        var caption: String?
        let color: Color
        /// 预计今天入库：时刻放大
        var large = false
    }

    let next: AirDay?
    /// 「今天」或星期
    let tag: String?
    /// 「第 13–14 集更新」「第 24 集 大结局」
    let headline: String?
    /// 第二行从长到短：一行放不下先省完结日，再省更新节奏
    let metaFull: String
    let metaNoFinale: String
    let metaShort: String
    let side: Side?

    init(episodes: [API.EpisodeView], schedule: API.SeasonAirScheduleView) {
        let next = AirSchedule.airDays(episodes, schedule).first { !$0.past }
        let counts = AirSchedule.counts(episodes, schedule)
        let cadence = AirSchedule.cadence(schedule.weekdays)
        let remaining = counts.upcoming > 0 ? String(localized: .libraryItemAirRemaining(counts.upcoming)) : nil
        let finale = AirSchedule.finale(schedule)
        self.next = next
        tag = next.map { $0.today ? String(localized: .libraryItemAirToday) : AirSchedule.weekday($0.date) }
        headline = next.map { day in
            let range = AirSchedule.rangeLabel(day.episodes)
            return day.finale ? String(localized: .libraryItemAirEpisodesFinale(range)) : String(localized: .libraryItemAirEpisodesUpdate(range))
        }
        metaFull = Self.join([cadence, remaining, finale])
        metaNoFinale = Self.join([cadence, remaining])
        metaShort = Self.join([remaining])
        side = next.flatMap { Self.side($0, schedule) }
    }

    private static func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

    /// 今天的看入库进度（预计时刻放大），之后的看还有几天
    private static func side(_ day: AirDay, _ schedule: API.SeasonAirScheduleView) -> Side? {
        guard day.today else {
            let date = AirSchedule.shortDate(day.date)
            let caption = schedule.region.map { String(localized: .libraryItemAirDateRegion(date, AirSchedule.regionName($0))) } ?? date
            return Side(value: AirSchedule.relative(day.date, schedule), caption: caption, color: Theme.text)
        }
        if day.episodes.allSatisfy(\.owned) {
            return Side(value: String(localized: .libraryItemAirLegendOwned), color: Theme.success)
        }
        if let at = AirSchedule.expectedAt(day.episodes, schedule) {
            let sameDay = Formatters.date(at).map { Calendar.current.isDateInToday($0) } ?? false
            return Side(value: AirSchedule.expectedTime(at), caption: String(localized: .libraryItemAirExpectedShort),
                        color: Theme.info, large: sameDay)
        }
        return AirSchedule.arrival(day.episodes, schedule).map { Side(value: $0.text, color: $0.color) }
    }
}

/// 已播出的日子折叠成的那一行
struct AirPastSummary {
    let range: String
    /// 「已播出 · 10月20日–10月31日」
    let aired: String
    let missing: [Int]
    let owned: Int
    let total: Int

    var allOwned: Bool { owned == total }

    init(_ past: [AirDay], _ schedule: API.SeasonAirScheduleView) {
        let all = past.flatMap(\.episodes)
        range = AirSchedule.rangeLabel(all)
        missing = all.filter { schedule.missingEpisodes.contains($0.episodeNumber) }.map(\.episodeNumber)
        owned = all.filter(\.owned).count
        total = all.count
        if let first = past.first, let last = past.last {
            aired = past.count == 1
                ? String(localized: .libraryItemAirAiredDay(AirSchedule.shortDate(first.date)))
                : String(localized: .libraryItemAirAiredRange(AirSchedule.shortDate(first.date), AirSchedule.shortDate(last.date)))
        } else {
            aired = ""
        }
    }
}

enum AirSchedule {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = AppLanguage.locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let dayFormatter = formatter("MMMd")
    private static let weekdayFormatter = formatter("EEE")
    private static let longWeekdayFormatter = formatter("EEEE")

    /// 解析结果按原串缓存：日更长剧一季上千个日期，排日程时同一天要比好几次（DateFormatter 每次几十微秒）
    private static var parsedDays: [String: Date] = [:]

    static func date(_ day: String) -> Date? {
        if let parsed = parsedDays[day] { return parsed }
        guard let parsed = parser.date(from: String(day.prefix(10))) else { return nil }
        if parsedDays.count >= 8192 { parsedDays.removeAll(keepingCapacity: true) }
        parsedDays[day] = parsed
        return parsed
    }

    static func days(from: String, to: String) -> Int {
        guard let a = date(from), let b = date(to) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    static func shortDate(_ day: String) -> String { date(day).map(dayFormatter.string(from:)) ?? day }
    static func weekday(_ day: String) -> String { date(day).map(weekdayFormatter.string(from:)) ?? "" }
    private static func weekday(_ value: Date) -> String { weekdayFormatter.string(from: value) }

    /// 0=周一…6=周日 → 星期名（2026-01-05 是周一）；中文用「周四」，英文用全称
    private static func weekdayName(_ index: Int) -> String {
        let monday = date("2026-01-05")!
        let value = calendar.date(byAdding: .day, value: index, to: monday)!
        return AppLanguage.identifier == "en" ? longWeekdayFormatter.string(from: value) : weekdayFormatter.string(from: value)
    }

    /// 0=周一…6=周日
    private static func weekdayIndex(_ day: String) -> Int { date(day).map(weekdayIndex) ?? 0 }
    private static func weekdayIndex(_ value: Date) -> Int { (calendar.component(.weekday, from: value) + 5) % 7 }

    /// 某天所在的周相对今天所在的周差几周（周一起算）：0 本周、1 下周，已播的为负
    static func weekOffset(today: String, day: String) -> Int {
        Int((Double(days(from: today, to: day) + weekdayIndex(today)) / 7).rounded(.down))
    }

    /// 日程分组标题：本周 / 下周 / 之后（再往后按周分，周更剧就成了一行一个标题）
    static func groupTitle(_ group: Int) -> String {
        switch group {
        case 0: String(localized: .libraryItemAirThisWeek)
        case 1: String(localized: .libraryItemAirNextWeek)
        default: String(localized: .libraryItemAirLater)
        }
    }

    static func tone(_ episode: API.EpisodeView, _ schedule: API.SeasonAirScheduleView) -> AirTone {
        if episode.owned { return .owned }
        if schedule.missingEpisodes.contains(episode.episodeNumber) { return .missing }
        guard let air = episode.airDate else { return .upcoming }
        let offset = days(from: schedule.today, to: air)
        if offset > 0 { return .upcoming }
        if offset == 0 { return schedule.subscriptionId != nil ? .today : .todayFree }
        return .absent
    }

    /// 库里没有、今天播出的集（分集卡剧照位写入库状态）
    static func airsToday(_ episode: API.EpisodeView, _ schedule: API.SeasonAirScheduleView?) -> Bool {
        guard let schedule, !episode.owned else { return false }
        let tone = tone(episode, schedule)
        return tone == .today || tone == .todayFree
    }

    /// 库里没有、但还没播的集（今天播出或之后）：不置灰、不标「缺」，剧照位换成播出日。
    /// 有日历才分得清「还没播」与「缺集」；没有日历时库里没有的集一律按缺集
    static func isUnaired(_ episode: API.EpisodeView, _ schedule: API.SeasonAirScheduleView?) -> Bool {
        guard let schedule, !episode.owned else { return false }
        let tone = tone(episode, schedule)
        return tone == .today || tone == .todayFree || tone == .upcoming
    }

    struct Counts { let owned: Int, missing: Int, upcoming: Int }

    static func counts(_ episodes: [API.EpisodeView], _ schedule: API.SeasonAirScheduleView) -> Counts {
        Counts(
            owned: episodes.filter(\.owned).count,
            missing: schedule.missingEpisodes.count,
            upcoming: episodes.filter { !$0.owned && ($0.airDate.map { days(from: schedule.today, to: $0) > 0 } ?? true) }.count
        )
    }

    /// 有日期的集按播出日分组，升序
    static func airDays(_ episodes: [API.EpisodeView], _ schedule: API.SeasonAirScheduleView) -> [AirDay] {
        var byDate: [String: [API.EpisodeView]] = [:]
        for episode in episodes {
            guard let air = episode.airDate else { continue }
            byDate[String(air.prefix(10)), default: []].append(episode)
        }
        let last = schedule.lastAirDate.map { String($0.prefix(10)) }
        return byDate.keys.sorted().map { day in
            let offset = days(from: schedule.today, to: day)
            return AirDay(date: day, episodes: byDate[day]!, past: offset < 0, today: offset == 0, finale: day == last)
        }
    }

    /// 一组播出日摊成日程的行：按需插「本周 / 下周 / 之后」标题和停更说明
    static func rows(_ list: [AirDay], _ schedule: API.SeasonAirScheduleView, grouped: Bool) -> [AirRow] {
        var rows: [AirRow] = []
        var current: Int?
        for (index, day) in list.enumerated() {
            let group = min(weekOffset(today: schedule.today, day: day.date), 2)
            if grouped, group != current {
                current = group
                rows.append(.group(group))
            }
            if index > 0, let text = gap(list[index - 1].date, day.date, weekdays: schedule.weekdays) {
                rows.append(.gap(after: list[index - 1].date, text: text))
            }
            rows.append(.day(day))
        }
        return rows
    }

    static func rangeLabel(_ episodes: [API.EpisodeView]) -> String {
        let numbers = episodes.map(\.episodeNumber).sorted()
        guard let from = numbers.first, let to = numbers.last else { return "" }
        return from == to
            ? String(localized: .libraryItemEpisode(String(from)))
            : String(localized: .libraryItemAirEpisodeRange(from, to))
    }

    static func regionName(_ code: String) -> String {
        AppLanguage.locale.localizedString(forRegionCode: code) ?? code
    }

    /// 「每天 / 每周四 / 周一至周四 / 周二、周五」更新
    static func cadence(_ weekdays: [Int]) -> String? {
        let days = Array(Set(weekdays)).sorted()
        guard let first = days.first, let last = days.last else { return nil }
        if days.count == 7 { return String(localized: .libraryItemAirCadenceDaily) }
        if days.count == 1 { return String(localized: .libraryItemAirCadenceWeekly(weekdayName(first))) }
        if zip(days, days.dropFirst()).allSatisfy({ $1 == $0 + 1 }) {
            return String(localized: .libraryItemAirCadenceRange(weekdayName(first), weekdayName(last)))
        }
        let names = days.map(weekdayName).formatted(.list(type: .and, width: .narrow).locale(AppLanguage.locale))
        return String(localized: .libraryItemAirCadenceList(names))
    }

    static func finale(_ schedule: API.SeasonAirScheduleView) -> String? {
        guard let last = schedule.lastAirDate else { return nil }
        return days(from: schedule.today, to: last) == 0
            ? String(localized: .libraryItemAirFinaleToday)
            : String(localized: .libraryItemAirFinale(shortDate(last)))
    }

    /// 「明天 / 6 天后」
    static func relative(_ day: String, _ schedule: API.SeasonAirScheduleView) -> String {
        let offset = days(from: schedule.today, to: day)
        return offset == 1 ? String(localized: .libraryItemAirTomorrow) : String(localized: .libraryItemAirInDays(offset))
    }

    static func missingText(_ numbers: [Int]) -> String? {
        guard let first = numbers.first else { return nil }
        return numbers.count == 1
            ? String(localized: .libraryItemAirStatMissingOne(first))
            : String(localized: .libraryItemAirStatMissing(numbers.count))
    }

    /// 这一天的集里哪些是缺集
    static func missing(_ day: AirDay, _ schedule: API.SeasonAirScheduleView) -> [Int] {
        day.episodes.filter { schedule.missingEpisodes.contains($0.episodeNumber) }.map(\.episodeNumber)
    }

    /// 日程一行右侧的状态
    static func status(_ day: AirDay, _ schedule: API.SeasonAirScheduleView) -> AirDayStatus {
        if day.past {
            if day.episodes.allSatisfy(\.owned) { return .owned }
            return missing(day, schedule).isEmpty ? .absent : .missing
        }
        if day.today {
            return arrival(day.episodes, schedule).map { .arrival(text: $0.text, color: $0.color) } ?? .none
        }
        return .relative(relative(day.date, schedule))
    }

    static func dot(_ day: AirDay, _ schedule: API.SeasonAirScheduleView) -> AirDot {
        if day.today { return .today }
        if day.finale { return .finale }
        if day.past, !missing(day, schedule).isEmpty { return .missing }
        if day.past, day.episodes.allSatisfy(\.owned) { return .owned }
        return .upcoming
    }

    /// 能不能「补缺集」：有订阅、有缺集、账号能订阅
    static func canFind(_ schedule: API.SeasonAirScheduleView, canSubscribe: Bool) -> Bool {
        canSubscribe && schedule.subscriptionId != nil && !schedule.missingEpisodes.isEmpty
    }

    /// 「补第 7 集 / 补 3 集」
    static func findTitle(_ schedule: API.SeasonAirScheduleView) -> String {
        schedule.missingEpisodes.count == 1
            ? String(localized: .libraryItemAirFindOne(schedule.missingEpisodes[0]))
            : String(localized: .libraryItemAirFindMany(schedule.missingEpisodes.count))
    }

    /// 两个播出日之间的停更说明。头部已经写了「周五至周六更新」，按节奏空着的日子不说，
    /// 只标跳过了本该更新的日子的真停更
    static func gap(_ previous: String, _ next: String, weekdays: [Int]) -> String? {
        let skipped = days(from: previous, to: next) - 1
        guard skipped > 0, let start = date(previous), let end = date(next) else { return nil }
        let breaks = (1...skipped).contains { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { weekdays.contains(weekdayIndex($0)) } ?? false
        }
        guard breaks else { return nil }
        if skipped >= 7 { return String(localized: .libraryItemAirBreak(skipped)) }
        let first = weekday(calendar.date(byAdding: .day, value: 1, to: start)!)
        if skipped == 1 { return String(localized: .libraryItemAirNoUpdateDay(first)) }
        return String(localized: .libraryItemAirNoUpdateRange(first, weekday(calendar.date(byAdding: .day, value: -1, to: end)!)))
    }

    /// 一组同日播出的集在订阅里走到哪了（日程「今天」行右侧）
    static func arrival(_ episodes: [API.EpisodeView], _ schedule: API.SeasonAirScheduleView) -> (text: String, color: Color)? {
        if let at = expectedAt(episodes, schedule) {
            return (String(localized: .libraryItemAirExpected(expectedTime(at))), Theme.info)
        }
        let pending = Set(episodes.filter { !$0.owned }.map(\.episodeNumber))
        if pending.isEmpty { return (String(localized: .libraryItemAirInLibrary), Theme.success) }
        if schedule.subscriptionId == nil { return (String(localized: .libraryItemAirNotSubscribed), Theme.textMuted) }
        let arrivals = schedule.arrivals.filter { pending.contains($0.episodeNumber) }
        if arrivals.contains(where: { $0.stage == "organizing" }) { return (String(localized: .libraryItemAirOrganizing), Theme.info) }
        if arrivals.contains(where: { $0.stage == "downloading" }) { return (String(localized: .libraryItemAirDownloading), Theme.info) }
        return arrivals.isEmpty ? nil : (String(localized: .libraryItemAirWaiting), Theme.textMuted)
    }

    /// 还没入库、也不在下载 / 整理中的那几集最早的预计入库时刻
    static func expectedAt(_ episodes: [API.EpisodeView], _ schedule: API.SeasonAirScheduleView) -> String? {
        let pending = Set(episodes.filter { !$0.owned }.map(\.episodeNumber))
        guard !pending.isEmpty, schedule.subscriptionId != nil else { return nil }
        let arrivals = schedule.arrivals.filter { pending.contains($0.episodeNumber) }
        if arrivals.contains(where: { $0.stage == "organizing" || $0.stage == "downloading" }) { return nil }
        return arrivals.compactMap(\.expectedAt).sorted().first
    }

    /// 预计入库时刻：今天只给时分，跨天带上日期
    static func expectedTime(_ iso: String) -> String {
        guard let value = Formatters.date(iso) else { return "" }
        let clock = SubsFormat.clock(value)
        if Calendar.current.isDateInToday(value) { return clock }
        let local = Calendar.current.dateComponents([.year, .month, .day], from: value)
        let day = String(format: "%04d-%02d-%02d", local.year ?? 0, local.month ?? 0, local.day ?? 0)
        return "\(shortDate(day)) \(clock)"
    }
}

// MARK: - 还没播的集的剧照位

/// 今天播出描蓝边、写入库状态；之后的虚线框写播出日；没日期写待定档。
/// 字号、圆角按各端的卡片来（默认是 iPhone 的分集卡）
struct UnairedStill: View {
    let episode: API.EpisodeView
    let schedule: API.SeasonAirScheduleView
    let today: Bool
    var corner: CGFloat = 12
    var titleFont: Font = .subheadline
    var captionFont: Font = .caption2
    var lineScale: CGFloat = 1

    var body: some View {
        ZStack {
            if today {
                RoundedRectangle(cornerRadius: corner).fill(Color(red: 0x11 / 255, green: 0x15 / 255, blue: 0x1D / 255))
                RoundedRectangle(cornerRadius: corner).strokeBorder(Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255).opacity(0.75), lineWidth: 1.5 * lineScale)
                VStack(spacing: 4 * lineScale) {
                    Text(String(localized: .libraryItemAirAirsToday)).font(titleFont.weight(.bold)).foregroundStyle(Theme.text)
                    if let status = AirSchedule.arrival([episode], schedule) {
                        Text(status.text).font(captionFont).foregroundStyle(status.color).lineLimit(1)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: corner).fill(Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x13 / 255))
                RoundedRectangle(cornerRadius: corner).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: lineScale, dash: [4 * lineScale, 3 * lineScale]))
                VStack(spacing: 4 * lineScale) {
                    if let air = episode.airDate {
                        Text(String(localized: .libraryItemAirDateWeekday(AirSchedule.shortDate(air), AirSchedule.weekday(air))))
                            .font(titleFont.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text.opacity(0.85))
                        Text(AirSchedule.relative(air, schedule))
                            .font(captionFont).foregroundStyle(Theme.textMuted)
                    } else {
                        Text(String(localized: .libraryItemAirUnscheduled)).font(titleFont.weight(.semibold)).foregroundStyle(Theme.text.opacity(0.85))
                    }
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}
