import SwiftUI

// MARK: - 播出日历（issue #547，Web `lib/air-schedule.ts` + `components/library-air-schedule.tsx`）
//
// 分集标题下的两行摘要入口 + 分本周 / 下周 / 之后的日程弹层。只在本季还有今天或以后的播出日期时出现
// （服务端不给 air_schedule 就整块不画），离线时也不画。日期一律是 yyyy-MM-dd 的日历日，
// 按 UTC 零点换算，「今天」由服务端按站点日历给出，不用本机时钟。

enum AirTone {
    case owned, missing, today, todayFree, upcoming, absent
}

struct AirDay: Identifiable {
    let date: String
    let episodes: [API.EpisodeView]
    let past: Bool
    let today: Bool
    let finale: Bool
    var id: String { date }
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

    static func date(_ day: String) -> Date? { parser.date(from: String(day.prefix(10))) }

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

// MARK: - 入口：分集标题下的两行摘要

/// 左边今天 / 下次更新哪一集 + 一行本季节奏，右边入库时刻或还有几天；整块点开日程
struct AirScheduleSummary: View {
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    var onOpen: () -> Void

    private struct Side {
        let value: String
        var caption: String?
        let color: Color
        var large = false
    }

    var body: some View {
        let next = AirSchedule.airDays(episodes, schedule).first { !$0.past }
        let counts = AirSchedule.counts(episodes, schedule)
        let cadence = AirSchedule.cadence(schedule.weekdays)
        let remaining = counts.upcoming > 0 ? String(localized: .libraryItemAirRemaining(counts.upcoming)) : nil
        let finale = AirSchedule.finale(schedule)
        Button(action: onOpen) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    if let next {
                        HStack(spacing: 8) {
                            Text(next.today ? String(localized: .libraryItemAirToday) : AirSchedule.weekday(next.date))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(next.today ? Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x18 / 255) : Theme.text)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(next.today ? Theme.text : .white.opacity(0.14), in: .rect(cornerRadius: 6))
                            Text(headline(next)).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                                .lineLimit(1)
                        }
                    }
                    // 一行放不下先省完结日，再省更新节奏，别把「11月8日」折成两行
                    ViewThatFits(in: .horizontal) {
                        Text(join([cadence, remaining, finale])).lineLimit(1)
                        Text(join([cadence, remaining])).lineLimit(1)
                        Text(join([remaining]))
                    }
                    .font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let next, let side = side(next) {
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 0.5, height: 38)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(side.value).font(side.large ? .title2.weight(.semibold) : .body.weight(.semibold))
                            .monospacedDigit().foregroundStyle(side.color)
                        if let caption = side.caption {
                            Text(caption).font(.caption2).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("air-schedule-summary")
    }

    private func headline(_ day: AirDay) -> String {
        let range = AirSchedule.rangeLabel(day.episodes)
        return day.finale ? String(localized: .libraryItemAirEpisodesFinale(range)) : String(localized: .libraryItemAirEpisodesUpdate(range))
    }

    private func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

    /// 今天的看入库进度（预计时刻放大），之后的看还有几天
    private func side(_ day: AirDay) -> Side? {
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

// MARK: - 日程弹层

struct AirScheduleSheet: View {
    let title: String
    let seasonLabel: String
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    let canSubscribe: Bool
    /// 未订阅时底部「订阅追更」；nil 不显示
    var onSubscribe: (() -> Void)?
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(\.dismiss) private var dismiss
    @State private var pastOpen = false
    @State private var searching = false

    var body: some View {
        let days = AirSchedule.airDays(episodes, schedule)
        let past = days.filter(\.past)
        let coming = days.filter { !$0.past }
        let counts = AirSchedule.counts(episodes, schedule)
        let finale = AirSchedule.finale(schedule)
        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 44, height: 44)
                Text(String(localized: .libraryItemAirCalendar)).font(.headline).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(String(localized: .commonClose))
            }
            .padding(.horizontal, 14).padding(.top, 14)
            VStack(alignment: .leading, spacing: 3) {
                Text([title, seasonLabel, AirSchedule.cadence(schedule.weekdays)].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Theme.textMuted).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if counts.upcoming > 0 {
                        Text(String(localized: .libraryItemAirRemaining(counts.upcoming))).font(.title.weight(.bold))
                        if let finale { Text(finale).font(.subheadline).foregroundStyle(Theme.textMuted) }
                    } else if let finale {
                        Text(finale).font(.title.weight(.bold))
                    }
                }
                .monospacedDigit().foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 2) {
                    if !past.isEmpty { pastSummary(past).padding(.bottom, 4) }
                    if pastOpen { rows(past, grouped: false) }
                    rows(coming, grouped: true)
                    if let region = schedule.region {
                        footnote(String(localized: .libraryItemAirRegionNote(AirSchedule.regionName(region))))
                    }
                    if schedule.subscriptionId != nil { footnote(String(localized: .libraryItemAirSource)) }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            if schedule.subscriptionId == nil, let onSubscribe {
                VStack(spacing: 8) {
                    Button(action: onSubscribe) {
                        Text(String(localized: .libraryItemAirSubscribe)).font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).clipShape(.capsule)
                    Text(String(localized: .libraryItemAirSubscribeHint)).font(.caption).foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .accessibilityIdentifier("air-schedule-sheet")
    }

    private var canFind: Bool { canSubscribe && schedule.subscriptionId != nil && !schedule.missingEpisodes.isEmpty }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 8)
    }

    private func pastSummary(_ past: [AirDay]) -> some View {
        let all = past.flatMap(\.episodes)
        let missing = all.filter { schedule.missingEpisodes.contains($0.episodeNumber) }.map(\.episodeNumber)
        let owned = all.filter(\.owned).count
        let aired = past.count == 1
            ? String(localized: .libraryItemAirAiredDay(AirSchedule.shortDate(past[0].date)))
            : String(localized: .libraryItemAirAiredRange(AirSchedule.shortDate(past[0].date), AirSchedule.shortDate(past[past.count - 1].date)))
        return HStack(spacing: 8) {
            Button { withAnimation(.snappy) { pastOpen.toggle() } } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill((missing.isEmpty ? Theme.success : Theme.warning).opacity(0.18))
                        if missing.isEmpty {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.success)
                        } else {
                            Text(verbatim: "!").font(.subheadline.weight(.bold)).foregroundStyle(Theme.warning)
                        }
                    }
                    .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AirSchedule.rangeLabel(all)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        Text(aired).font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let text = AirSchedule.missingText(missing) {
                        // 能补集时右边的「补第 7 集」已经说了缺哪集，这里不再重复
                        if !canFind { Text(text).font(.caption).foregroundStyle(Theme.warning) }
                    } else {
                        Text(owned == all.count ? String(localized: .libraryItemAirLegendOwned) : String(localized: .libraryItemAirStatOwned(owned)))
                            .font(.caption).monospacedDigit().foregroundStyle(owned == all.count ? Theme.success : Theme.textMuted)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(pastOpen ? 90 : 0))
                }
                .frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(pastOpen ? .isSelected : [])
            .accessibilityIdentifier("air-schedule-past")
            if canFind {
                findButton(schedule.missingEpisodes.count == 1
                    ? String(localized: .libraryItemAirFindOne(schedule.missingEpisodes[0]))
                    : String(localized: .libraryItemAirFindMany(schedule.missingEpisodes.count)), filled: true)
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 6)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func rows(_ list: [AirDay], grouped: Bool) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, day in
            let group = min(AirSchedule.weekOffset(today: schedule.today, day: day.date), 2)
            if grouped, index == 0 || min(AirSchedule.weekOffset(today: schedule.today, day: list[index - 1].date), 2) != group {
                Text(AirSchedule.groupTitle(group))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, index == 0 ? 4 : 16).padding(.bottom, 4)
            }
            if index > 0, let gap = AirSchedule.gap(list[index - 1].date, day.date, weekdays: schedule.weekdays) {
                HStack(spacing: 10) {
                    dashed
                    Text(gap).font(.caption2).foregroundStyle(Theme.textMuted).fixedSize()
                    dashed
                }
                .padding(.horizontal, 14)
            }
            dayRow(day)
        }
    }

    private var dashed: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.white.opacity(0.2)).frame(height: 1)
    }

    private nonisolated struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: 0, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }

    private func dayRow(_ day: AirDay) -> some View {
        let dayMissing = day.episodes.filter { schedule.missingEpisodes.contains($0.episodeNumber) }.map(\.episodeNumber)
        let allOwned = day.episodes.allSatisfy(\.owned)
        // 星期单独占一行；日期、圆点、集号、右侧状态排在同一行按文字基线对齐，集号不会落在两行日期的中间
        return VStack(alignment: .leading, spacing: 1) {
            Text(day.today ? String(localized: .libraryItemAirToday) : AirSchedule.weekday(day.date))
                .font(.caption.weight(day.today ? .bold : .regular))
                .foregroundStyle(day.today ? Theme.info : Theme.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(AirSchedule.shortDate(day.date)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    // 定宽：「11月2日」与「10月28日」两行的集号要对齐
                    .frame(width: 72, alignment: .leading)
                dot(day, missing: !dayMissing.isEmpty, owned: allOwned)
                    // 圆点没有基线：让圆心落在集号字身中部（基线上方约 6pt）
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AirSchedule.rangeLabel(day.episodes)).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                    if day.finale {
                        Text(String(localized: .libraryItemAirFinaleTag)).font(.caption2.weight(.bold))
                            .foregroundStyle(Color(red: 0x24 / 255, green: 0x1A / 255, blue: 0x02 / 255))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.warning, in: .rect(cornerRadius: 6))
                    }
                }
                Spacer(minLength: 4)
                if day.past {
                    if allOwned {
                        Label(String(localized: .libraryItemAirLegendOwned), systemImage: "checkmark")
                            .font(.caption).foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
                    } else if dayMissing.isEmpty {
                        Text(String(localized: .libraryItemAirAbsent)).font(.caption).foregroundStyle(Theme.textMuted)
                    } else if canFind {
                        findButton(String(localized: .libraryItemAirFindEpisode), filled: false)
                    }
                } else if day.today {
                    if let status = AirSchedule.arrival(day.episodes, schedule) {
                        Text(status.text).font(.caption.weight(.semibold)).foregroundStyle(status.color).lineLimit(1)
                    }
                } else {
                    Text(AirSchedule.relative(day.date, schedule)).font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
            }
            if day.past, let text = AirSchedule.missingText(dayMissing) {
                // 与集号左缘对齐：日期 72 + 间距 12 + 圆点 10 + 间距 12
                Text(text).font(.caption).foregroundStyle(Theme.warning).padding(.leading, 106)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minHeight: 60)
        .background(day.today ? Theme.info.opacity(0.14) : .clear, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("air-day-\(day.date)")
    }

    /// 时间线上的点：今天实心蓝、大结局琥珀圈、已播按入库与否，之后的空心圈
    @ViewBuilder
    private func dot(_ day: AirDay, missing: Bool, owned: Bool) -> some View {
        Group {
            if day.today {
                Circle().fill(Theme.info)
            } else if day.finale {
                Circle().strokeBorder(Theme.warning, lineWidth: 2)
            } else if day.past, missing {
                Circle().fill(Theme.warning)
            } else if day.past, owned {
                Circle().fill(Theme.success)
            } else {
                Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }

    private func findButton(_ title: String, filled: Bool) -> some View {
        Button {
            Task { await findMissing() }
        } label: {
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(filled ? Color(red: 0x24 / 255, green: 0x1A / 255, blue: 0x02 / 255) : Theme.warning)
                .padding(.horizontal, 12).frame(minHeight: 32)
                .background(filled ? Theme.warning : .clear, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.warning.opacity(filled ? 0 : 0.55)))
        }
        .buttonStyle(.plain)
        .disabled(searching)
        .accessibilityIdentifier("air-schedule-find")
    }

    private func findMissing() async {
        guard let id = schedule.subscriptionId, !searching else { return }
        searching = true
        defer { searching = false }
        do {
            let result = try await api.subscriptionsSearchMissingResources(subscriptionId: id)
            feedback.success(String(localized: .subscriptionInspectorRequeued(result.resetCount)))
        } catch {
            feedback.error(error)
        }
    }
}

// MARK: - 还没播的集的剧照位

/// 今天播出描蓝边、写入库状态；之后的虚线框写播出日；没日期写待定档
struct UnairedStill: View {
    let episode: API.EpisodeView
    let schedule: API.SeasonAirScheduleView
    let today: Bool

    var body: some View {
        ZStack {
            if today {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0x11 / 255, green: 0x15 / 255, blue: 0x1D / 255))
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255).opacity(0.75), lineWidth: 1.5)
                VStack(spacing: 4) {
                    Text(String(localized: .libraryItemAirAirsToday)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.text)
                    if let status = AirSchedule.arrival([episode], schedule) {
                        Text(status.text).font(.caption2).foregroundStyle(status.color).lineLimit(1)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x13 / 255))
                RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                VStack(spacing: 4) {
                    if let air = episode.airDate {
                        Text(String(localized: .libraryItemAirDateWeekday(AirSchedule.shortDate(air), AirSchedule.weekday(air))))
                            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text.opacity(0.85))
                        let offset = AirSchedule.days(from: schedule.today, to: air)
                        Text(offset == 1 ? String(localized: .libraryItemAirTomorrow) : String(localized: .libraryItemAirInDays(offset)))
                            .font(.caption2).foregroundStyle(Theme.textMuted)
                    } else {
                        Text(String(localized: .libraryItemAirUnscheduled)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text.opacity(0.85))
                    }
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}
