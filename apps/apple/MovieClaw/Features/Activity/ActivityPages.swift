import SwiftUI

/// 活动总览的二级页：从分组标题「查看全部」、行尾箭头或站内链接 `/activity?view=` 压栈进来。
enum ActivityPage: String, Hashable {
    /// 进行中的全部任务（下载过程 + 后台作业的时间线，可取消 / 删种 / 换种）
    case active
    /// 已结束的后台作业（按天分组，可撤销忽略 / 重新执行）
    case finished
    /// 刷流做种逐种子明细
    case boost
    /// 最近播放（按场、游标分页，可按成员筛选）
    case plays
    /// 观看统计（可按周期、成员筛选）
    case stats

    /// Web `/activity?view=` → 二级页；需要处理 / 正在播放 / 全部 / 缺省都落在总览本身，返回 nil
    init?(webView: String?) {
        switch webView {
        case "active": self = .active
        case "history": self = .finished
        case "plays": self = .plays
        case "stats": self = .stats
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .active: String(localized: .activityJobStatusRunning)
        case .finished: String(localized: .activityNavHistory)
        case .boost: String(localized: .activityNavBoost)
        case .plays: String(localized: .activityNavPlays)
        case .stats: String(localized: .activityNavStats)
        }
    }
}

struct ActivityPageView: View {
    let page: ActivityPage

    var body: some View {
        switch page {
        case .active: ActivityTasksPage(mode: .active)
        case .finished: ActivityTasksPage(mode: .history)
        case .boost: ActivityBoostPage()
        case .plays, .stats: ActivityWatchPage(page: page)
        }
    }
}

// MARK: - 任务

/// 进行中 / 已结束：沿用任务中心的时间线与历史分组（完整过程与全部操作都在这里）
private struct ActivityTasksPage: View {
    @Environment(\.cardMetrics) private var cards
    let mode: TaskCenterPanel.Mode

    @Environment(ShellBadges.self) private var badges
    @State private var actions = TaskCenterActions()

    var body: some View {
        let store = badges.tasks
        ScrollView {
            TaskCenterPanel(store: store, mode: mode, actions: actions)
                .padding(.horizontal, cards.edge)
                .padding(.top, 8)
                .padding(.bottom, 48)
        }
        .refreshable {
            store.refreshJobs()
            store.refreshDownloads()
        }
        .navigationTitle(mode == .history ? String(localized: .activityNavHistory) : String(localized: .activityJobStatusRunning))
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
        .taskDeleteSheet(actions, store: store)
    }
}

// MARK: - 刷流

/// 刷流做种：页头实时汇总 → 按站点（开着 / 已暂停 / 已关闭）→ 逐种子一行；右上角「清理」。
///
/// 清理（docs/design/site-protection-ratio-boost.md §2.9）：关闭刷流不会删种，残留种子会一直满速做种、
/// 占着磁盘，这里是事后清掉它们的入口。点开先取最新的在池概况，再用系统底部菜单讲清后果：
/// 删多少、还开着刷流的站点会一并关闭、保留期内的（提前删可能被记 H&R）默认到期后自动删，
/// 另给「立即全部删除」由用户自担风险。清理入口放右上角工具栏（同 Safari 历史记录的「清除」、照片
/// 「最近删除」的「全部删除」）：种子动辄上百个，放列表底部要滑到头才找得到。
/// 种子列表默认只列上行最快的 20 个（真正值得看的是正在出力的），其余按批「再显示 20 个」。
private struct ActivityBoostPage: View {
    @Environment(ShellBadges.self) private var badges
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @State private var pool: API.BoostPoolView?
    /// 服务端支持清理（旧版服务端没有 /sites/boost-pool 时隐藏清理入口）
    @State private var supportsCleanup = false
    @State private var confirming = false
    @State private var cleaning = false
    /// 种子列表当前露出的条数（默认 20，每次「再显示」加 20）
    @State private var visibleCount = ActivityBoostPage.pageSize

    private static let pageSize = 20

    var body: some View {
        let tasks = badges.tasks.activity.boostTasks
        let totals = ActivityBoostTotals(tasks)
        let sites = ActivityBoostSites(tasks: tasks, pool: pool)
        List {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        SpeedStat(direction: .up, bytesPerSecond: totals.upSpeed, placeholder: "↑ 0 B/s")
                        SpeedStat(direction: .down, bytesPerSecond: totals.downSpeed, placeholder: "↓ 0 B/s")
                    }
                    GridRow {
                        Text.activityJoin([Text(String(localized: .activityBoostUploaded) + " "), Text(ActivityFormat.bytes(Double(totals.uploaded))).fontWeight(.semibold).foregroundStyle(Theme.success)])
                        Text.activityJoin([Text(String(localized: .activityBoostDownloaded) + " "), Text(ActivityFormat.bytes(Double(totals.downloaded))).fontWeight(.semibold).foregroundStyle(Theme.info)])
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
                .padding(.vertical, 4)
            } header: {
                Text(String(localized: .activityBoostTorrentCount(totals.count))).textCase(nil)
            }
            if !sites.sites.isEmpty {
                Section {
                    ForEach(sites.sites) { site in siteRow(site) }
                } header: {
                    Text(String(localized: .activityBoostBySite)).textCase(nil)
                } footer: {
                    if sites.count(.off) > 0 {
                        Text(String(localized: .activityBoostOffPageHint))
                    }
                }
            }
            if !tasks.isEmpty {
                let sorted = ActivityBoostTotals.sorted(tasks)
                Section {
                    ForEach(sorted.prefix(visibleCount)) { task in
                        BoostTaskRow(task: task, cleanupNote: cleanupNote(sites.taskStates[task.infoHash.lowercased()]))
                    }
                    if sorted.count > visibleCount {
                        Button {
                            withAnimation { visibleCount += Self.pageSize }
                        } label: {
                            Text(String(localized: .activityBoostShowMore(min(Self.pageSize, sorted.count - visibleCount), sorted.count)))
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("boost-show-more")
                    }
                } header: {
                    Text(String(localized: .activityBoostBySpeed)).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable {
            badges.tasks.refreshDownloads()
            await loadPool()
        }
        .navigationTitle(String(localized: .activityNavBoost))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if supportsCleanup, !tasks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { cleanupButton }
            }
        }
        .appBackground()
        .task { await loadPool() }
    }

    // MARK: 清理

    /// 右上角「清理」：确认菜单挂在它上面（iOS 26 的确认菜单是贴着来源弹出的气泡，箭头指向这个按钮）
    private var cleanupButton: some View {
        Button(role: .destructive) {
            Task { await prepareCleanup() }
        } label: {
            if cleaning {
                ProgressView()
            } else {
                Text(String(localized: .activityBoostClean))
            }
        }
        .tint(Theme.danger)
        .disabled(cleaning)
        .accessibilityLabel(String(localized: .activityBoostCleanupButton))
        .accessibilityIdentifier("boost-cleanup")
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            let plan = CleanupPlan(pool)
            Button(plan.enabledNames.isEmpty ? String(localized: .activityBoostClean) : String(localized: .activityBoostDisableAndClean), role: .destructive) {
                Task { await cleanup(force: false) }
            }
            if plan.protectedCount > 0 {
                Button(String(localized: .activityBoostDeleteAllNow), role: .destructive) {
                    Task { await cleanup(force: true) }
                }
            }
            Button(String(localized: .commonCancel), role: .cancel) {}
        } message: {
            Text(CleanupPlan(pool).message)
        }
    }

    /// 清理前的汇总：删多少、哪些站还开着刷流、保留期内有多少（都取自最新的在池概况）
    private struct CleanupPlan {
        var count = 0
        var bytes = 0
        var protectedCount = 0
        var protectedBytes = 0
        var protectedUntil: String?
        var enabledNames: [String] = []

        init(_ pool: API.BoostPoolView?) {
            for site in pool?.sites ?? [] {
                count += site.taskCount
                bytes += site.sizeBytes
                protectedCount += site.protectedCount
                protectedBytes += site.protectedBytes
                if let until = site.protectedUntil, until > (protectedUntil ?? "") { protectedUntil = until }
                if site.boostEnabled { enabledNames.append(site.siteName) }
            }
        }

        var message: String {
            var lines = [String(localized: .activityBoostConfirmDelete(count, ActivityFormat.bytes(Double(bytes))))]
            if !enabledNames.isEmpty {
                let names = enabledNames.joined(separator: AppLanguage.identifier == "zh-Hans" ? "、" : ", ")
                lines.append(String(localized: .activityBoostConfirmDisable(names)))
            }
            if protectedCount > 0 {
                let until = ActivityBoostCleanupText.deadline(protectedUntil)
                let all = protectedCount == count
                let rest: String = switch (all, until) {
                case (true, let until?): String(localized: .activityBoostConfirmRestAllUntil(until))
                case (true, nil): String(localized: .activityBoostConfirmRestAll)
                case (false, let until?): String(localized: .activityBoostConfirmRestSomeUntil(protectedCount, until))
                case (false, nil): String(localized: .activityBoostConfirmRestSome(protectedCount))
                }
                lines.append(String(localized: .activityBoostConfirmProtected(protectedCount, ActivityFormat.bytes(Double(protectedBytes)))) + rest)
            }
            return lines.joined(separator: "\n\n")
        }
    }

    private var confirmTitle: String {
        let count = CleanupPlan(pool).count
        return count > 0 ? String(localized: .activityBoostCleanupTitle(count)) : String(localized: .activityBoostCleanupTitleGeneric)
    }

    private func cleanupNote(_ state: API.BoostPoolTaskView?) -> String? {
        guard let state, state.cleanupScheduled else { return nil }
        if let until = ActivityBoostCleanupText.deadline(state.protectedUntil) {
            return String(localized: .activityBoostPendingDeadline(until))
        }
        return String(localized: .activityBoostPendingPatrol)
    }

    private func loadPool() async {
        guard let loaded = await ActivityBoostPoolLoader.load(api) else { return }
        pool = loaded.pool
        supportsCleanup = loaded.supportsCleanup
    }

    /// 先取最新概况再弹确认（刚关掉刷流 / 保留期刚过，旧数据会讲错后果）
    private func prepareCleanup() async {
        do {
            pool = try await api.siteBoostPoolShow()
            confirming = true
        } catch {
            feedback.error(error)
        }
    }

    private func cleanup(force: Bool) async {
        cleaning = true
        defer { cleaning = false }
        do {
            let result = try await api.siteBoostPoolCleanup(body: .init(siteIds: nil, disableBoost: true, force: force))
            feedback.success(ActivityBoostCleanupText.summary(result))
            badges.tasks.refreshDownloads()
            await loadPool()
        } catch {
            feedback.error(error)
        }
    }

    private func siteRow(_ site: ActivityBoostSites.Site) -> some View {
        let totals = ActivityBoostTotals(site.tasks)
        let size = site.tasks.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        let (label, color): (String, Color) = switch site.mode {
        case .running: (String(localized: .activityBoostRunning), Theme.success)
        case .paused: (String(localized: .activityDownloadStatePaused), Theme.warning)
        case .off: (String(localized: .activityBoostSiteOff), Theme.textFaint)
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(WatchFormat.metaLine([
                    String(localized: .activityBoostTorrentCount(site.tasks.count)), ActivityFormat.bytes(Double(size)), "↑ \(ActivityFormat.rate(Double(totals.upSpeed)))",
                ]))
                .font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted)
                if let scheduled = site.pool?.scheduledCount, scheduled > 0 {
                    Text(String(localized: .activityBoostSiteScheduled(scheduled)))
                        .font(.footnote).foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: 8)
            Text(label).font(.footnote.weight(.medium)).foregroundStyle(color)
        }
    }
}

// MARK: - 观看

/// 最近播放 / 观看统计：筛选（周期、成员、范围）收进右上角的筛选菜单，当前条件写在标题下方
private struct ActivityWatchPage: View {
    @Environment(\.cardMetrics) private var cards
    let page: ActivityPage

    @Environment(ShellBadges.self) private var badges
    @Environment(\.api) private var api
    @State private var memberId: Int?
    @State private var days = 30
    @State private var members: [API.MemberView] = []

    private static let periods = [7, 30, 90]
    /// 成员筛选里「超级管理员」的取值（同 Web：0 表示超管自己）
    private static let adminMember = 0

    var body: some View {
        let media = badges.media
        ScrollView {
            Group {
                if page == .plays {
                    PlaybackHistoryList(
                        scope: media.scope, memberId: memberId, memberLabel: memberLabel,
                        onClearMember: { memberId = nil }, onShowAll: { media.setScope("all") }
                    )
                } else {
                    WatchStatsPanel(
                        scope: media.scope, days: days, memberId: memberId, memberLabel: memberLabel,
                        onMemberSelect: { memberId = $0 }, onDaysChange: { days = $0 },
                        onShowAll: { media.setScope("all") }
                    )
                }
            }
            .padding(.horizontal, cards.edge)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .navigationTitle(page.title)
        .navigationSubtitle(filterSummary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
        .appBackground()
        .task { members = (try? await api.membersList()) ?? members }
    }

    private var memberLabel: String? {
        guard let memberId else { return nil }
        if memberId == Self.adminMember { return String(localized: .activityOverviewAdmin) }
        return members.first { $0.id == memberId }.map { $0.nickname.isEmpty ? $0.username : $0.nickname }
    }

    /// 标题下的当前条件：「最近 30 天 · 全部成员 · 我的浏览范围」
    private var filterSummary: String {
        var parts: [String] = []
        if page == .stats { parts.append(String(localized: .activityOverviewDays(days))) }
        parts.append(memberLabel ?? String(localized: .activityOverviewAllMembers))
        parts.append(badges.media.scope == "all" ? String(localized: .activityOverviewIncludeHidden) : String(localized: .activityOverviewScopeMine))
        return parts.joined(separator: " · ")
    }

    private var filterMenu: some View {
        let media = badges.media
        let filtered = memberId != nil || media.scope == "all" || (page == .stats && days != 30)
        return Menu {
            if page == .stats {
                Picker(String(localized: .activityOverviewPeriod), selection: $days) {
                    ForEach(Self.periods, id: \.self) { Text(String(localized: .activityOverviewDays($0))).tag($0) }
                }
                .pickerStyle(.inline)
            }
            Picker(String(localized: .activityOverviewMember), selection: Binding(mcGet: { memberId ?? -1 }, set: { memberId = $0 < 0 ? nil : $0 })) {
                Text(String(localized: .activityOverviewAllMembers)).tag(-1)
                Text(String(localized: .authRoleSuperAdmin)).tag(Self.adminMember)
                ForEach(members, id: \.id) { member in
                    Text(member.nickname.isEmpty ? member.username : member.nickname).tag(member.id)
                }
            }
            .pickerStyle(.menu)
            Picker(String(localized: .activityOverviewScope), selection: Binding(mcGet: { media.scope }, set: { media.setScope($0) })) {
                Text(String(localized: .activityOverviewScopeMine)).tag("visible")
                Text(String(localized: .activityOverviewScopeAll)).tag("all")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .accessibilityLabel(String(localized: .activityOverviewFilters))
        .accessibilityIdentifier("activity-filter")
    }
}
