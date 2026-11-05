import SwiftUI

// MARK: - 播出日历（issue #547）的 Mac 版
//
// 口径同 iPhone（`Shared/Library/AirScheduleLogic.swift`），版式按大屏和指针重排：
// - 入口是分集横排上面的一条，一行写完（今天 / 星期 + 第几集更新 + 本季节奏，右边入库时刻或还有几天），
//   窗口窄了先省完结日、再省节奏；指针悬停提亮，点开日程；
// - 日程是从入口弹出的宽面板（同「全部分集」，点外面或按 Esc 关）：左栏还剩几集、完结日、补集与订阅，
//   右栏是按天的时间线，星期、日期、圆点、集号、状态排成表格的几列；指针停在一行上提亮并浮出那天的集名。

/// 分集横排上面的入口条
struct MacAirScheduleStrip: View {
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let summary = AirSummary(episodes: episodes, schedule: schedule)
        Button(action: action) {
            HStack(spacing: 12) {
                if let next = summary.next {
                    Text(summary.tag ?? "")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(next.today ? .black : .white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(next.today ? Color.white : Color.white.opacity(0.14), in: .rect(cornerRadius: 6))
                    Text(summary.headline ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
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
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 0.5, height: 24)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let caption = side.caption {
                            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Text(side.value)
                            .font(.system(size: side.large ? 20 : 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(side.color)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.white.opacity(hovering ? 0.13 : 0.08), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            .contentShape(.rect)
        }
        .buttonStyle(MacCardButtonStyle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .help(String(localized: .libraryItemAirCalendar))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("air-schedule-summary")
    }

    private func metaText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// 从入口弹出的日程面板
struct MacAirSchedulePanel: View {
    let title: String
    let seasonLabel: String
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    let canSubscribe: Bool
    /// 这部剧在 TMDB 的 id：没有的（本地识别不出来的）不能订阅
    let tmdbId: Int?
    /// 管理员订阅时入哪个库（这部剧所在的库）；成员走服务端路由
    let libraryId: Int?
    /// 补了缺集、订阅成功后：页面重读这一季（日历跟着更新）
    let changed: () async -> Void

    @Environment(\.api) private var api
    @State private var pastOpen = false
    @State private var actions = AirScheduleActions()

    private static let width: CGFloat = 780
    private static let sideWidth: CGFloat = 256
    private static let maxHeight: CGFloat = 640

    private var canFind: Bool { AirSchedule.canFind(schedule, canSubscribe: canSubscribe) }
    private var canOfferSubscribe: Bool { schedule.subscriptionId == nil && canSubscribe && (tmdbId ?? 0) > 0 }

    var body: some View {
        let days = AirSchedule.airDays(episodes, schedule)
        let past = days.filter(\.past)
        let coming = days.filter { !$0.past }
        let pastRows = pastOpen ? AirSchedule.rows(past, schedule, grouped: false) : []
        let comingRows = AirSchedule.rows(coming, schedule, grouped: true)
        HStack(alignment: .top, spacing: 0) {
            side.frame(width: Self.sideWidth)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5)
            ScrollView(.vertical) {
                // 懒加载：日更长剧的已播展开能有上千行
                LazyVStack(spacing: 2) {
                    if !past.isEmpty { pastRow(past).padding(.bottom, 4) }
                    rows(pastRows)
                    rows(comingRows)
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: Self.width, height: height(pastShown: !past.isEmpty, rows: pastRows + comingRows))
        .animation(.easeInOut(duration: 0.2), value: pastOpen)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("air-schedule-sheet")
    }

    /// 面板跟着内容高（行高都是定的，不用量）：排得下不留空，排不下滚动
    private func height(pastShown: Bool, rows: [AirRow]) -> CGFloat {
        let content = rows.reduce(CGFloat(24 + (pastShown ? 60 : 0))) { total, row in
            switch row {
            case .group: total + 30
            case .gap: total + 18
            case .day: total + 42
            }
        }
        return min(Self.maxHeight, max(380, content))
    }

    // MARK: 左栏

    private var side: some View {
        let counts = AirSchedule.counts(episodes, schedule)
        let finale = AirSchedule.finale(schedule)
        return VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: .libraryItemAirCalendar))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text([title, seasonLabel].joined(separator: " · "))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                if counts.upcoming > 0 {
                    Text(String(localized: .libraryItemAirRemaining(counts.upcoming)))
                        .font(.system(size: 30, weight: .bold))
                    if let finale { Text(finale).font(.system(size: 13)).foregroundStyle(.secondary) }
                } else if let finale {
                    Text(finale).font(.system(size: 30, weight: .bold))
                }
                if let cadence = AirSchedule.cadence(schedule.weekdays) {
                    Text(cadence).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.top, 18)
            actionsBlock.padding(.top, 20)
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 6) {
                if let region = schedule.region {
                    footnote(String(localized: .libraryItemAirRegionNote(AirSchedule.regionName(region))))
                }
                if schedule.subscriptionId != nil { footnote(String(localized: .libraryItemAirSource)) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if canFind {
                Button(AirSchedule.findTitle(schedule)) { Task { await find() } }
                    .buttonStyle(MacAirFindStyle(filled: true))
                    .disabled(actions.searching)
                    .accessibilityIdentifier("air-schedule-find")
            }
            if canOfferSubscribe { subscribeBlock }
            if let message = actions.message {
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(message.isError ? Theme.warning : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("air-schedule-message")
            }
        }
    }

    /// 「订阅追更」：按下读预检 → 列出默认值（追踪范围、品质）→ 确认建好；要改选项到手机或网页
    @ViewBuilder
    private var subscribeBlock: some View {
        switch actions.stage {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Button { Task { await actions.beginSubscribe(api: api, tmdbId: tmdbId ?? 0) } } label: {
                    Text(String(localized: .libraryItemAirSubscribe)).frame(maxWidth: .infinity)
                }
                .buttonStyle(MacPrimaryButtonStyle())
                .accessibilityIdentifier("air-schedule-subscribe")
                Text(String(localized: .libraryItemAirSubscribeHint))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: .subscriptionSubscribeLoading)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case let .confirming(draft):
            confirm(draft, busy: false)
        case let .submitting(draft):
            confirm(draft, busy: true)
        }
    }

    private func confirm(_ draft: QuickSubscribe, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: .subscriptionSubscribeTrackingScope)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(draft.scope).font(.system(size: 13, weight: .semibold))
                Text(draft.scopeNote).font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(draft.quality, id: \.self) { line in
                    Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { if await actions.confirmSubscribe(api: api, libraryId: libraryId) { await changed() } }
                } label: {
                    Text(String(localized: .subscriptionSubscribeConfirm))
                }
                .buttonStyle(MacPrimaryButtonStyle())
                .accessibilityIdentifier("air-schedule-subscribe-confirm")
                Button(String(localized: .commonCancel)) { actions.cancelSubscribe() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .accessibilityIdentifier("air-schedule-subscribe-cancel")
            }
            .disabled(busy)
        }
    }

    private func find() async {
        if await actions.findMissing(api: api, schedule: schedule) { await changed() }
    }

    // MARK: 右栏

    private func pastRow(_ past: [AirDay]) -> some View {
        let summary = AirPastSummary(past, schedule)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { pastOpen.toggle() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill((summary.missing.isEmpty ? Theme.success : Theme.warning).opacity(0.18))
                    if summary.missing.isEmpty {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.success)
                    } else {
                        Text(verbatim: "!").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.warning)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.range).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text(summary.aired).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let text = AirSchedule.missingText(summary.missing) {
                    Text(text).font(.system(size: 12)).foregroundStyle(Theme.warning)
                } else {
                    Text(summary.allOwned ? String(localized: .libraryItemAirLegendOwned) : String(localized: .libraryItemAirStatOwned(summary.owned)))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(summary.allOwned ? Theme.success : .secondary)
                }
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(pastOpen ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .contentShape(.rect)
        }
        .buttonStyle(MacAirRowStyle())
        .accessibilityAddTraits(pastOpen ? .isSelected : [])
        .accessibilityIdentifier("air-schedule-past")
    }

    @ViewBuilder
    private func rows(_ list: [AirRow]) -> some View {
        ForEach(list) { row in
            switch row {
            case let .group(group):
                Text(AirSchedule.groupTitle(group))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottomLeading)
                    .padding(.horizontal, 12)
            case let .gap(_, text):
                HStack(spacing: 10) {
                    MacAirDashedLine()
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    MacAirDashedLine()
                }
                .frame(height: 16)
                .padding(.horizontal, 12)
            case let .day(day):
                MacAirDayRow(day: day, schedule: schedule, canFind: canFind, searching: actions.searching) {
                    Task { await find() }
                }
            }
        }
    }
}

/// 日程一行：星期、日期、圆点、集号（大结局标签）、缺集、右边状态，同一条基线
private struct MacAirDayRow: View {
    let day: AirDay
    let schedule: API.SeasonAirScheduleView
    let canFind: Bool
    let searching: Bool
    let find: () -> Void
    @State private var hovering = false

    /// 指针停在一行上浮出那天的集名（手机上没有地方放）
    private var names: String {
        day.episodes.map { episode in
            let number = String(localized: .mediaEpisodeNumber(episode.episodeNumber))
            return episode.name.map { "\(number) · \($0)" } ?? number
        }.joined(separator: "\n")
    }

    var body: some View {
        let dayMissing = AirSchedule.missing(day, schedule)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(day.today ? String(localized: .libraryItemAirToday) : AirSchedule.weekday(day.date))
                .font(.system(size: 12, weight: day.today ? .bold : .regular))
                .foregroundStyle(day.today ? Theme.info : .secondary)
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)
            // 定宽：「11月2日」与「10月28日」两行的集号要对齐
            Text(AirSchedule.shortDate(day.date))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 72, alignment: .leading)
            MacAirDot(kind: AirSchedule.dot(day, schedule))
                // 圆点没有基线：让圆心落在集号字身中部
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(AirSchedule.rangeLabel(day.episodes))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            if day.finale {
                Text(String(localized: .libraryItemAirFinaleTag))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MacAirInk.onWarning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.warning, in: .rect(cornerRadius: 5))
            }
            if day.past, let text = AirSchedule.missingText(dayMissing) {
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.warning).lineLimit(1)
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background((day.today ? Theme.info.opacity(hovering ? 0.2 : 0.14) : .white.opacity(hovering ? 0.06 : 0)), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(names)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("air-day-\(day.date)")
    }

    @ViewBuilder
    private var status: some View {
        switch AirSchedule.status(day, schedule) {
        case .owned:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text(String(localized: .libraryItemAirLegendOwned)).font(.system(size: 12))
            }
            .foregroundStyle(Theme.success)
            .fixedSize()
        case .absent:
            Text(String(localized: .libraryItemAirAbsent)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
        case .missing:
            if canFind {
                Button(String(localized: .libraryItemAirFindEpisode), action: find)
                    .buttonStyle(MacAirFindStyle(filled: false))
                    .disabled(searching)
            }
        case let .arrival(text, color):
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1).fixedSize()
        case let .relative(text):
            Text(text).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
        case .none:
            EmptyView()
        }
    }
}

/// 时间线上的点
private struct MacAirDot: View {
    let kind: AirDot

    var body: some View {
        Group {
            switch kind {
            case .today: Circle().fill(Theme.info)
            case .finale: Circle().strokeBorder(Theme.warning, lineWidth: 2)
            case .missing: Circle().fill(Theme.warning)
            case .owned: Circle().fill(Theme.success)
            case .upcoming: Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

private struct MacAirDashedLine: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}

private enum MacAirInk {
    /// 琥珀底上的深色字（大结局标签、补集按钮）
    static let onWarning = Color(red: 0x24 / 255, green: 0x1A / 255, blue: 0x02 / 255)
}

/// 补集按钮：左栏实心、行里描边；悬停提亮
private struct MacAirFindStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, filled: filled)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let filled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filled ? MacAirInk.onWarning : Theme.warning)
                .padding(.horizontal, 12)
                .frame(height: filled ? 30 : 24)
                .background(Capsule().fill(filled ? Theme.warning.opacity(hovering ? 1 : 0.92) : .white.opacity(hovering ? 0.08 : 0)))
                .overlay { Capsule().strokeBorder(Theme.warning.opacity(filled ? 0 : 0.55)) }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(.capsule)
                .onHover { hovering = $0 }
        }
    }
}

/// 已播折叠行：淡底，悬停提亮
private struct MacAirRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(.white.opacity(configuration.isPressed ? 0.14 : hovering ? 0.1 : 0.06), in: .rect(cornerRadius: 12))
                .onHover { hovering = $0 }
        }
    }
}
