import SwiftUI

// MARK: - 播出日历（issue #547）的 Apple TV 版
//
// 口径同 iPhone（`Shared/Library/AirScheduleLogic.swift`），交互按遥控器重排：
// - 入口是下半截选季下面的一条，一行写完，看一眼就知道下一集什么时候来；从分集横排往上就能落到它，按确认打开日程；
// - 日程是盖满整屏的面板（同「全部分集」），打开时焦点落在今天 / 下一个更新日：上下一天一天走，
//   往上一格是折叠的「已播出」（按确认展开）；往左是补缺集、订阅追更；返回键关面板、焦点回到入口。
//   手机上行里的小按钮遥控器够不着，缺集那一行整行就是「补这一集」。

/// 下半截选季下面的入口条（按确认打开日程）
struct TVAirScheduleStrip: View {
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    let action: () -> Void

    /// 条本身的高度（页面据此给下半截的顶让位）
    static let height: CGFloat = 84

    var body: some View {
        Button(action: action) {
            TVAirStripLabel(summary: AirSummary(episodes: episodes, schedule: schedule))
        }
        .buttonStyle(TVAirBareStyle())
        .accessibilityIdentifier("air-schedule-summary")
    }
}

private struct TVAirStripLabel: View {
    let summary: AirSummary
    @Environment(\.isFocused) private var focused

    private var ink: Color { focused ? .black : .white }
    private var muted: Color { focused ? .black.opacity(0.6) : .white.opacity(0.6) }

    var body: some View {
        HStack(spacing: 20) {
            if let next = summary.next {
                Text(summary.tag ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(tagInk(today: next.today))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(tagFill(today: next.today), in: .rect(cornerRadius: 8))
                Text(summary.headline ?? "")
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            ViewThatFits(in: .horizontal) {
                metaText(summary.metaFull)
                metaText(summary.metaNoFinale)
                metaText(summary.metaShort)
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let side = summary.side {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    if let caption = side.caption {
                        Text(caption).font(.system(size: 24)).foregroundStyle(muted)
                    }
                    Text(side.value)
                        .font(.system(size: side.large ? 40 : 30, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(focused ? .black : side.color)
                }
                .lineLimit(1)
                .fixedSize()
            }
            Image(systemName: "chevron.forward")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(muted)
        }
        .padding(.horizontal, 32)
        .frame(height: TVAirScheduleStrip.height)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(focused ? .white : .white.opacity(0.1)))
        .scaleEffect(focused ? 1.02 : 1)
        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 18, y: 10)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private func tagInk(today: Bool) -> Color {
        if today { return focused ? .white : .black }
        return focused ? .black : .white
    }

    private func tagFill(today: Bool) -> Color {
        if today { return focused ? .black : .white }
        return focused ? .black.opacity(0.1) : .white.opacity(0.14)
    }

    private func metaText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24))
            .monospacedDigit()
            .foregroundStyle(muted)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 整屏日程：左栏还剩几集、完结日、补集与订阅，右栏按天的时间线
struct TVAirSchedulePanel: View {
    let title: String
    let seasonLabel: String
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    let canSubscribe: Bool
    /// 这部剧在 TMDB 的 id：没有的（本地识别不出来的）不能订阅
    let tmdbId: Int?
    /// 管理员订阅时入哪个库（这部剧所在的库）；成员走服务端路由
    let libraryId: Int?
    let ambientURL: URL?
    /// 补了缺集、订阅成功后：页面重读这一季（日历跟着更新）
    let changed: () async -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var pastOpen = false
    @State private var actions = AirScheduleActions()
    @FocusState private var focus: PanelFocus?

    private enum PanelFocus: Hashable {
        case past
        case day(String)
        case find, subscribe, cancel
    }

    private var canFind: Bool { AirSchedule.canFind(schedule, canSubscribe: canSubscribe) }
    private var canOfferSubscribe: Bool { schedule.subscriptionId == nil && canSubscribe && (tmdbId ?? 0) > 0 }
    private var days: [AirDay] { AirSchedule.airDays(episodes, schedule) }
    /// 打开时落在今天 / 下一个更新日
    private var entry: PanelFocus? { days.first { !$0.past }.map { .day($0.date) } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVBlurredBackdrop(url: ambientURL)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 44) {
                header
                HStack(alignment: .top, spacing: 64) {
                    side.frame(width: 500)
                    list
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.top, 40)
            .padding(.bottom, 40)
        }
        .defaultFocus($focus, entry)
        // 确认订阅时返回键先退回「订阅追更」，再按一下才关面板
        .onExitCommand {
            if case .confirming = actions.stage {
                actions.cancelSubscribe()
                focus = .subscribe
            } else {
                dismiss()
            }
        }
        .onChange(of: schedule.subscriptionId) { _, id in
            // 订阅成功，左栏的按钮没了：焦点回到时间线
            if id != nil { focus = entry }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("air-schedule-sheet")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(String(localized: .libraryItemAirCalendar))
                .font(.system(size: 44, weight: .bold))
            Text([title, seasonLabel, AirSchedule.cadence(schedule.weekdays)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    // MARK: 左栏

    private var side: some View {
        let counts = AirSchedule.counts(episodes, schedule)
        let finale = AirSchedule.finale(schedule)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if counts.upcoming > 0 {
                    Text(String(localized: .libraryItemAirRemaining(counts.upcoming)))
                        .font(.system(size: 76, weight: .bold))
                    if let finale { Text(finale).font(.system(size: 30)).foregroundStyle(.white.opacity(0.6)) }
                } else if let finale {
                    Text(finale).font(.system(size: 76, weight: .bold))
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            actionsBlock.padding(.top, 44)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 10) {
                if let region = schedule.region {
                    footnote(String(localized: .libraryItemAirRegionNote(AirSchedule.regionName(region))))
                }
                if schedule.subscriptionId != nil { footnote(String(localized: .libraryItemAirSource)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 右边走到哪一行，往左都进得来
        .focusSection()
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 24) {
            if canFind {
                Button(AirSchedule.findTitle(schedule)) { Task { await find() } }
                    .focused($focus, equals: .find)
                    .accessibilityIdentifier("air-schedule-find")
            }
            if canOfferSubscribe { subscribeBlock }
            if let message = actions.message {
                Text(message.text)
                    .font(.system(size: 24))
                    .foregroundStyle(message.isError ? Theme.warning : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("air-schedule-message")
            }
        }
    }

    /// 「订阅追更」：按下读预检 → 列出默认值（追踪范围、品质）→ 同一颗按钮变「确认订阅」→ 建好。
    /// 按钮一直是同一颗，焦点不会因为换状态掉走。要改选项到手机或网页
    private var subscribeBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let draft = subscribeDraft {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: .subscriptionSubscribeTrackingScope)).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6))
                    Text(draft.scope).font(.system(size: 30, weight: .semibold))
                    Text(draft.scopeNote).font(.system(size: 24)).foregroundStyle(.white.opacity(0.6))
                    ForEach(draft.quality, id: \.self) { line in
                        Text(line).font(.system(size: 24)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("air-schedule-subscribe-draft")
            }
            Button(subscribeTitle) { Task { await subscribeTapped() } }
                .focused($focus, equals: .subscribe)
                .accessibilityIdentifier("air-schedule-subscribe")
            if subscribeDraft != nil {
                Button(String(localized: .commonCancel)) {
                    actions.cancelSubscribe()
                    focus = .subscribe
                }
                .focused($focus, equals: .cancel)
                .accessibilityIdentifier("air-schedule-subscribe-cancel")
            } else if actions.stage == .idle {
                Text(String(localized: .libraryItemAirSubscribeHint))
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subscribeDraft: QuickSubscribe? {
        switch actions.stage {
        case let .confirming(draft), let .submitting(draft): draft
        case .idle, .preparing: nil
        }
    }

    private var subscribeTitle: String {
        switch actions.stage {
        case .idle: String(localized: .libraryItemAirSubscribe)
        case .preparing: String(localized: .subscriptionSubscribeLoading)
        case .confirming, .submitting: String(localized: .subscriptionSubscribeConfirm)
        }
    }

    private func subscribeTapped() async {
        switch actions.stage {
        case .idle:
            await actions.beginSubscribe(api: api, tmdbId: tmdbId ?? 0)
        case .confirming:
            if await actions.confirmSubscribe(api: api, libraryId: libraryId) { await changed() }
        case .preparing, .submitting:
            break
        }
    }

    private func find() async {
        if await actions.findMissing(api: api, schedule: schedule) { await changed() }
    }

    // MARK: 右栏

    private var list: some View {
        let past = days.filter(\.past)
        let coming = days.filter { !$0.past }
        return ScrollView(.vertical) {
            LazyVStack(spacing: 6) {
                if !past.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { pastOpen.toggle() }
                    } label: {
                        TVAirPastLabel(summary: AirPastSummary(past, schedule), open: pastOpen, canFind: canFind)
                    }
                    .buttonStyle(TVAirBareStyle())
                    .focused($focus, equals: .past)
                    .accessibilityAddTraits(pastOpen ? .isSelected : [])
                    .accessibilityIdentifier("air-schedule-past")
                    .padding(.bottom, 8)
                }
                if pastOpen { rows(AirSchedule.rows(past, schedule, grouped: false)) }
                rows(AirSchedule.rows(coming, schedule, grouped: true))
            }
            // 获得焦点放大一点，四周留出余地（列表要裁边，不然滚上去的行会盖住标题）
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusSection()
    }

    @ViewBuilder
    private func rows(_ list: [AirRow]) -> some View {
        ForEach(list) { row in
            switch row {
            case let .group(group):
                Text(AirSchedule.groupTitle(group))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
            case let .gap(_, text):
                HStack(spacing: 18) {
                    TVAirDashedLine()
                    Text(text).font(.system(size: 22)).foregroundStyle(.white.opacity(0.55)).fixedSize()
                    TVAirDashedLine()
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 4)
            case let .day(day):
                Button {
                    // 缺集那一行整行就是「补这一集」；别的行只读（能落焦点才滚得动）
                    if canFind, !AirSchedule.missing(day, schedule).isEmpty { Task { await find() } }
                } label: {
                    TVAirDayLabel(day: day, schedule: schedule, canFind: canFind)
                }
                .buttonStyle(TVAirBareStyle())
                .focused($focus, equals: .day(day.date))
                .accessibilityIdentifier("air-day-\(day.date)")
            }
        }
    }
}

/// 已播出折叠成的一行：淡底；获得焦点白底黑字
private struct TVAirPastLabel: View {
    let summary: AirPastSummary
    let open: Bool
    let canFind: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        let accent = summary.missing.isEmpty ? Theme.success : Theme.warning
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(accent.opacity(focused ? 0.3 : 0.18))
                if summary.missing.isEmpty {
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(focused ? .black : accent)
                } else {
                    Text(verbatim: "!").font(.system(size: 26, weight: .bold)).foregroundStyle(focused ? .black : accent)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.range).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text(summary.aired).font(.system(size: 24)).monospacedDigit().foregroundStyle(focused ? .black.opacity(0.6) : .white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let text = AirSchedule.missingText(summary.missing) {
                Text(text).font(.system(size: 26)).foregroundStyle(focused ? .black : Theme.warning)
            } else {
                Text(summary.allOwned ? String(localized: .libraryItemAirLegendOwned) : String(localized: .libraryItemAirStatOwned(summary.owned)))
                    .font(.system(size: 26))
                    .monospacedDigit()
                    .foregroundStyle(focused ? .black : summary.allOwned ? Theme.success : .white.opacity(0.6))
            }
            Image(systemName: "chevron.forward")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(focused ? .black.opacity(0.6) : .white.opacity(0.6))
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .foregroundStyle(focused ? .black : .white)
        .padding(.horizontal, 26)
        .frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 18).fill(focused ? .white : .white.opacity(0.08)))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// 日程一行：星期、日期、圆点、集号（大结局标签）、缺集、右边状态，同一条基线。今天的行垫蓝底；获得焦点白底黑字
private struct TVAirDayLabel: View {
    let day: AirDay
    let schedule: API.SeasonAirScheduleView
    let canFind: Bool
    @Environment(\.isFocused) private var focused

    private var muted: Color { focused ? .black.opacity(0.6) : .white.opacity(0.6) }

    var body: some View {
        let dayMissing = AirSchedule.missing(day, schedule)
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(day.today ? String(localized: .libraryItemAirToday) : AirSchedule.weekday(day.date))
                .font(.system(size: 24, weight: day.today ? .bold : .regular))
                .foregroundStyle(day.today && !focused ? Theme.info : muted)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            // 定宽：「11月2日」与「10月28日」两行的集号要对齐
            Text(AirSchedule.shortDate(day.date))
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 140, alignment: .leading)
            TVAirDot(kind: AirSchedule.dot(day, schedule), focused: focused)
                // 圆点没有基线：让圆心落在集号字身中部
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 10 }
            Text(AirSchedule.rangeLabel(day.episodes))
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if day.finale {
                Text(String(localized: .libraryItemAirFinaleTag))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(red: 0x24 / 255, green: 0x1A / 255, blue: 0x02 / 255))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(Theme.warning, in: .rect(cornerRadius: 8))
            }
            if day.past, let text = AirSchedule.missingText(dayMissing) {
                Text(text).font(.system(size: 24)).foregroundStyle(focused ? .black : Theme.warning).lineLimit(1)
            }
            Spacer(minLength: 12)
            status
        }
        .foregroundStyle(focused ? .black : .white)
        .padding(.horizontal, 26)
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 16).fill(focused ? .white : day.today ? Theme.info.opacity(0.16) : .clear))
        .scaleEffect(focused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    @ViewBuilder
    private var status: some View {
        switch AirSchedule.status(day, schedule) {
        case .owned:
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .bold))
                Text(String(localized: .libraryItemAirLegendOwned)).font(.system(size: 24))
            }
            .foregroundStyle(focused ? .black : Theme.success)
            .fixedSize()
        case .absent:
            Text(String(localized: .libraryItemAirAbsent)).font(.system(size: 24)).foregroundStyle(muted).fixedSize()
        case .missing:
            if canFind {
                Text(String(localized: .libraryItemAirFindEpisode)).font(.system(size: 24, weight: .semibold)).foregroundStyle(focused ? .black : Theme.warning).fixedSize()
            }
        case let .arrival(text, color):
            Text(text).font(.system(size: 24, weight: .semibold)).foregroundStyle(focused ? .black : color).lineLimit(1).fixedSize()
        case let .relative(text):
            Text(text).font(.system(size: 24)).monospacedDigit().foregroundStyle(muted).fixedSize()
        case .none:
            EmptyView()
        }
    }
}

/// 时间线上的点（比手机大一倍，三米外也看得清）
private struct TVAirDot: View {
    let kind: AirDot
    let focused: Bool

    var body: some View {
        Group {
            switch kind {
            case .today: Circle().fill(Theme.info)
            case .finale: Circle().strokeBorder(Theme.warning, lineWidth: 4)
            case .missing: Circle().fill(Theme.warning)
            case .owned: Circle().fill(Theme.success)
            case .upcoming: Circle().strokeBorder(focused ? .black.opacity(0.5) : .white.opacity(0.5), lineWidth: 3)
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct TVAirDashedLine: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
        }
        .frame(height: 2)
    }
}

/// 什么都不画的按钮样式：焦点效果都在标签自己身上（读 `isFocused`）
private struct TVAirBareStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
