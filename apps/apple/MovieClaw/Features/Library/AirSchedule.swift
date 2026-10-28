import SwiftUI

// MARK: - 播出日历（issue #547，Web `lib/air-schedule.ts` + `components/library-air-schedule.tsx`）
//
// 分集区里的「季进度条」入口卡 + 按天的日程弹层。只在本季还有今天或以后的播出日期时出现
// （服务端不给 air_schedule 就整块不画），离线时也不画。日期一律是 yyyy-MM-dd 的日历日，
// 按 UTC 零点换算，「今天」由服务端按站点日历给出，不用本机时钟。

enum AirTone {
    case owned, missing, today, todayFree, upcoming, absent

    var color: Color {
        switch self {
        case .owned: Color(red: 0xC3 / 255, green: 0xCA / 255, blue: 0xD6 / 255)
        case .missing: Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
        case .today: Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)
        case .todayFree: Color(red: 0x7C / 255, green: 0x84 / 255, blue: 0x94 / 255)
        case .upcoming, .absent: .white.opacity(0.14)
        }
    }
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
    /// 超过这么多集就把同状态的连续集合并成色段，一集一格太细
    static let mergeAbove = 40

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

    static func tone(_ episode: API.EpisodeView, _ schedule: API.SeasonAirScheduleView) -> AirTone {
        if episode.owned { return .owned }
        if schedule.missingEpisodes.contains(episode.episodeNumber) { return .missing }
        guard let air = episode.airDate else { return .upcoming }
        let offset = days(from: schedule.today, to: air)
        if offset > 0 { return .upcoming }
        if offset == 0 { return schedule.subscriptionId != nil ? .today : .todayFree }
        return .absent
    }

    static func segments(_ episodes: [API.EpisodeView], _ schedule: API.SeasonAirScheduleView) -> [(tone: AirTone, count: Int)] {
        let tones = episodes.map { tone($0, schedule) }
        if tones.count <= mergeAbove { return tones.map { ($0, 1) } }
        var runs: [(tone: AirTone, count: Int)] = []
        for t in tones {
            if let last = runs.last, last.tone == t { runs[runs.count - 1].count += 1 } else { runs.append((t, 1)) }
        }
        return runs
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

    /// 「10月29日 周四」，海外首播加地区「（美国）」
    static func dayLabel(_ day: String, _ schedule: API.SeasonAirScheduleView) -> String {
        let label = String(localized: .libraryItemAirDateWeekday(shortDate(day), weekday(day)))
        guard let region = schedule.region else { return label }
        return String(localized: .libraryItemAirDateRegion(label, regionName(region)))
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

    /// 两个播出日之间的停更说明；周更剧的正常间隔不说（头部已经写了「每周四更新」）
    static func gap(_ previous: String, _ next: String, weekly: Bool) -> String? {
        let skipped = days(from: previous, to: next) - 1
        guard skipped > 0 else { return nil }
        if skipped >= 7 { return String(localized: .libraryItemAirBreak(skipped)) }
        guard !weekly, let start = date(previous), let end = date(next) else { return nil }
        let first = weekday(calendar.date(byAdding: .day, value: 1, to: start)!)
        if skipped == 1 { return String(localized: .libraryItemAirNoUpdateDay(first)) }
        return String(localized: .libraryItemAirNoUpdateRange(first, weekday(calendar.date(byAdding: .day, value: -1, to: end)!)))
    }

    /// 一组同日播出的集在订阅里走到哪了（入口卡与日程「今天」行右侧）
    static func arrival(_ episodes: [API.EpisodeView], _ schedule: API.SeasonAirScheduleView) -> (text: String, color: Color)? {
        let pending = Set(episodes.filter { !$0.owned }.map(\.episodeNumber))
        if pending.isEmpty { return (String(localized: .libraryItemAirInLibrary), Theme.success) }
        if schedule.subscriptionId == nil { return (String(localized: .libraryItemAirNotSubscribed), Theme.textMuted) }
        let arrivals = schedule.arrivals.filter { pending.contains($0.episodeNumber) }
        if arrivals.contains(where: { $0.stage == "organizing" }) { return (String(localized: .libraryItemAirOrganizing), Theme.info) }
        if arrivals.contains(where: { $0.stage == "downloading" }) { return (String(localized: .libraryItemAirDownloading), Theme.info) }
        if let at = arrivals.compactMap(\.expectedAt).sorted().first {
            return (String(localized: .libraryItemAirExpected(expectedTime(at))), Theme.info)
        }
        return arrivals.isEmpty ? nil : (String(localized: .libraryItemAirWaiting), Theme.textMuted)
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

// MARK: - 季进度条

struct AirSeasonBar: View {
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    var height: CGFloat = 8

    var body: some View {
        let segments = AirSchedule.segments(episodes, schedule)
        let total = max(1, segments.reduce(0) { $0 + $1.count })
        let counts = AirSchedule.counts(episodes, schedule)
        GeometryReader { proxy in
            let room = proxy.size.width - CGFloat(max(0, segments.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.tone.color)
                        .frame(width: max(3, room * CGFloat(segment.count) / CGFloat(total)))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(String(localized: .libraryItemAirProgress(counts.owned, counts.missing, counts.upcoming)))
    }
}

// MARK: - 入口卡

struct AirScheduleCard: View {
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    var onOpen: () -> Void

    var body: some View {
        let days = AirSchedule.airDays(episodes, schedule)
        let next = days.first { !$0.past }
        let counts = AirSchedule.counts(episodes, schedule)
        let meta = [AirSchedule.cadence(schedule.weekdays), AirSchedule.finale(schedule)].compactMap { $0 }.joined(separator: " · ")
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").font(.subheadline).foregroundStyle(Theme.accentStrong)
                    Text(String(localized: .libraryItemAirCalendar)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(meta).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
                AirSeasonBar(episodes: episodes, schedule: schedule)
                if let next {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(headline(next)).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if let note = note(next) {
                            Text(note.text).font(.caption).foregroundStyle(note.color).lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Text(String(localized: .libraryItemAirStatOwned(counts.owned)))
                    if let missing = missingText(counts.missing) { Text(missing).foregroundStyle(Theme.warning) }
                    if counts.upcoming > 0 { Text(String(localized: .libraryItemAirStatUpcoming(counts.upcoming))) }
                }
                .font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("air-schedule-card")
    }

    private func headline(_ day: AirDay) -> String {
        let range = AirSchedule.rangeLabel(day.episodes)
        if day.today {
            return day.finale ? String(localized: .libraryItemAirTodayFinale(range)) : String(localized: .libraryItemAirTodayEpisodes(range))
        }
        return String(localized: .libraryItemAirNextEpisodes(AirSchedule.dayLabel(day.date, schedule), range))
    }

    private func note(_ day: AirDay) -> (text: String, color: Color)? {
        if day.today { return AirSchedule.arrival(day.episodes, schedule) }
        let offset = AirSchedule.days(from: schedule.today, to: day.date)
        return (offset == 1 ? String(localized: .libraryItemAirTomorrow) : String(localized: .libraryItemAirInDays(offset)), Theme.textMuted)
    }

    private func missingText(_ count: Int) -> String? {
        if count == 0 { return nil }
        if count == 1, let only = schedule.missingEpisodes.first { return String(localized: .libraryItemAirStatMissingOne(only)) }
        return String(localized: .libraryItemAirStatMissing(count))
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
        let weekly = Set(schedule.weekdays).count == 1
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: .libraryItemAirCalendar)).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                    Text([title, seasonLabel, AirSchedule.cadence(schedule.weekdays)].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer()
                Button(String(localized: .commonDone)) { dismiss() }.font(.subheadline).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 20).padding(.top, 20)
            VStack(alignment: .leading, spacing: 8) {
                AirSeasonBar(episodes: episodes, schedule: schedule, height: 10)
                HStack(spacing: 12) {
                    legend(.owned, "\(String(localized: .libraryItemAirLegendOwned)) \(counts.owned)")
                    if counts.missing > 0 { legend(.missing, "\(String(localized: .libraryItemAirLegendMissing)) \(counts.missing)") }
                    if let today = coming.first, today.today {
                        legend(schedule.subscriptionId != nil ? .today : .todayFree,
                               "\(String(localized: .libraryItemAirLegendToday)) \(today.episodes.filter { !$0.owned }.count)")
                    }
                    legend(.upcoming, "\(String(localized: .libraryItemAirLegendUpcoming)) \(counts.upcoming)")
                    Spacer(minLength: 0)
                    if let finale = AirSchedule.finale(schedule) { Text(finale) }
                }
                .font(.caption2).monospacedDigit().foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.top, 14)
            Divider().overlay(Theme.line).padding(.top, 14)
            ScrollView {
                VStack(spacing: 6) {
                    if !past.isEmpty { pastSummary(past) }
                    if pastOpen { rows(past, weekly: weekly) }
                    rows(coming, weekly: weekly)
                    if let region = schedule.region {
                        footnote(String(localized: .libraryItemAirRegionNote(AirSchedule.regionName(region))))
                    }
                    if schedule.subscriptionId != nil { footnote(String(localized: .libraryItemAirSource)) }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
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

    private func legend(_ tone: AirTone, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(tone.color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).padding(.top, 6)
    }

    private func pastSummary(_ past: [AirDay]) -> some View {
        let all = past.flatMap(\.episodes)
        let missing = all.filter { schedule.missingEpisodes.contains($0.episodeNumber) }
        let title = past.count == 1
            ? String(localized: .libraryItemAirAiredDay(AirSchedule.shortDate(past[0].date)))
            : String(localized: .libraryItemAirAiredRange(AirSchedule.shortDate(past[0].date), AirSchedule.shortDate(past[past.count - 1].date)))
        return HStack(spacing: 8) {
            Button { withAnimation(.snappy) { pastOpen.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(pastOpen ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        (Text([String(localized: .libraryItemAirStatEpisodes(all.count)),
                               String(localized: .libraryItemAirStatOwned(all.filter(\.owned).count))].joined(separator: " · "))
                            + Text(missing.isEmpty ? "" : " · \(missingText(missing))").foregroundStyle(Theme.warning))
                            .font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 0)
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
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)
        .background(.white.opacity(0.04), in: .rect(cornerRadius: 12))
    }

    private func missingText(_ list: [API.EpisodeView]) -> String {
        list.count == 1
            ? String(localized: .libraryItemAirStatMissingOne(list[0].episodeNumber))
            : String(localized: .libraryItemAirStatMissing(list.count))
    }

    @ViewBuilder
    private func rows(_ list: [AirDay], weekly: Bool) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, day in
            if index > 0, let gap = AirSchedule.gap(list[index - 1].date, day.date, weekly: weekly) {
                HStack(spacing: 10) {
                    dashed
                    Text(gap).font(.caption2).foregroundStyle(Theme.textMuted).fixedSize()
                    dashed
                }
                .padding(.horizontal, 12)
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
        let dayMissing = day.episodes.filter { schedule.missingEpisodes.contains($0.episodeNumber) }
        let allOwned = day.episodes.allSatisfy(\.owned)
        return HStack(spacing: 10) {
            VStack(spacing: 1) {
                Text(day.today ? String(localized: .libraryItemAirToday) : AirSchedule.weekday(day.date))
                    .font(.caption2.weight(day.today ? .bold : .regular))
                    .foregroundStyle(day.today ? Theme.info : Theme.textMuted)
                Text(AirSchedule.shortDate(day.date)).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(Theme.text)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            // 定宽：「11月2日」与「10月28日」两行的集号要对齐
            .frame(width: 80)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(AirSchedule.rangeLabel(day.episodes)).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                    if day.finale {
                        Text(String(localized: .libraryItemAirFinaleTag)).font(.caption2.weight(.bold)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.white.opacity(0.14), in: .capsule)
                    }
                }
                if day.past, !dayMissing.isEmpty {
                    Text(missingText(dayMissing)).font(.caption).foregroundStyle(Theme.warning)
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
            } else if day.today, let status = AirSchedule.arrival(day.episodes, schedule) {
                Text(status.text).font(.caption.weight(.semibold)).foregroundStyle(status.color).lineLimit(1)
            }
        }
        .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 8)
        .frame(minHeight: 60)
        .background(day.today ? AirTone.today.color.opacity(0.12) : .white.opacity(0.04), in: .rect(cornerRadius: 12))
        .overlay {
            if day.today { RoundedRectangle(cornerRadius: 12).strokeBorder(AirTone.today.color.opacity(0.5)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("air-day-\(day.date)")
    }

    private func findButton(_ title: String, filled: Bool) -> some View {
        Button {
            Task { await findMissing() }
        } label: {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.warning)
                .padding(.horizontal, 11).frame(minHeight: 32)
                .background(filled ? Theme.warning.opacity(0.1) : .clear, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.55)))
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
                RoundedRectangle(cornerRadius: 12).strokeBorder(AirTone.today.color.opacity(0.75), lineWidth: 1.5)
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
