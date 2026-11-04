import SwiftUI

// MARK: - 播出日历的 iPhone 界面（issue #547，Web `components/library-air-schedule.tsx`）
//
// 分集标题下的两行摘要入口 + 分本周 / 下周 / 之后的日程弹层。离线时也不画。口径在 `Shared/Library/AirScheduleLogic.swift`。

// MARK: - 入口：分集标题下的两行摘要

/// 左边今天 / 下次更新哪一集 + 一行本季节奏，右边入库时刻或还有几天；整块点开日程
struct AirScheduleSummary: View {
    let episodes: [API.EpisodeView]
    let schedule: API.SeasonAirScheduleView
    var onOpen: () -> Void

    var body: some View {
        let summary = AirSummary(episodes: episodes, schedule: schedule)
        Button(action: onOpen) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    if let next = summary.next {
                        HStack(spacing: 8) {
                            Text(summary.tag ?? "")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(next.today ? Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x18 / 255) : Theme.text)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(next.today ? Theme.text : .white.opacity(0.14), in: .rect(cornerRadius: 6))
                            Text(summary.headline ?? "").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                                .lineLimit(1)
                        }
                    }
                    // 一行放不下先省完结日，再省更新节奏，别把「11月8日」折成两行
                    ViewThatFits(in: .horizontal) {
                        Text(summary.metaFull).lineLimit(1)
                        Text(summary.metaNoFinale).lineLimit(1)
                        Text(summary.metaShort)
                    }
                    .font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let side = summary.side {
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

    private var canFind: Bool { AirSchedule.canFind(schedule, canSubscribe: canSubscribe) }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 8)
    }

    private func pastSummary(_ past: [AirDay]) -> some View {
        let summary = AirPastSummary(past, schedule)
        return HStack(spacing: 8) {
            Button { withAnimation(.snappy) { pastOpen.toggle() } } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill((summary.missing.isEmpty ? Theme.success : Theme.warning).opacity(0.18))
                        if summary.missing.isEmpty {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.success)
                        } else {
                            Text(verbatim: "!").font(.subheadline.weight(.bold)).foregroundStyle(Theme.warning)
                        }
                    }
                    .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.range).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        Text(summary.aired).font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let text = AirSchedule.missingText(summary.missing) {
                        // 能补集时右边的「补第 7 集」已经说了缺哪集，这里不再重复
                        if !canFind { Text(text).font(.caption).foregroundStyle(Theme.warning) }
                    } else {
                        Text(summary.allOwned ? String(localized: .libraryItemAirLegendOwned) : String(localized: .libraryItemAirStatOwned(summary.owned)))
                            .font(.caption).monospacedDigit().foregroundStyle(summary.allOwned ? Theme.success : Theme.textMuted)
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
                findButton(AirSchedule.findTitle(schedule), filled: true)
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 6)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func rows(_ list: [AirDay], grouped: Bool) -> some View {
        let items = AirSchedule.rows(list, schedule, grouped: grouped)
        ForEach(items) { row in
            switch row {
            case let .group(group):
                Text(AirSchedule.groupTitle(group))
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, row.id == items.first?.id ? 4 : 16).padding(.bottom, 4)
            case let .gap(_, text):
                HStack(spacing: 10) {
                    dashed
                    Text(text).font(.caption2).foregroundStyle(Theme.textMuted).fixedSize()
                    dashed
                }
                .padding(.horizontal, 14)
            case let .day(day):
                dayRow(day)
            }
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
        let dayMissing = AirSchedule.missing(day, schedule)
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
                dot(day)
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
                switch AirSchedule.status(day, schedule) {
                case .owned:
                    Label(String(localized: .libraryItemAirLegendOwned), systemImage: "checkmark")
                        .font(.caption).foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
                case .absent:
                    Text(String(localized: .libraryItemAirAbsent)).font(.caption).foregroundStyle(Theme.textMuted)
                case .missing:
                    if canFind { findButton(String(localized: .libraryItemAirFindEpisode), filled: false) }
                case let .arrival(text, color):
                    Text(text).font(.caption.weight(.semibold)).foregroundStyle(color).lineLimit(1)
                case let .relative(text):
                    Text(text).font(.caption).monospacedDigit().foregroundStyle(Theme.textMuted)
                case .none:
                    EmptyView()
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
    private func dot(_ day: AirDay) -> some View {
        Group {
            switch AirSchedule.dot(day, schedule) {
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
