import SwiftUI

/// 活动页（管理员）：一页总览。
///
/// 2026-09-26 用户拍板取代 Web 式的「观看 / 任务」分段 + 二级切片胶囊（Web 的 `/activity?view=` 不变，App 与之结构不同）：
/// - **不分段**：打开就是「现在有没有要我管的事、家里在发生什么」，按紧急程度自上而下——
///   需要处理 → 正在播放 → 正在下载 → 进行中（含刷流）→ 最近播放 → 观看统计 → 最近完成；没内容的分组不出现；
/// - **大标题下一行实时摘要**（「2 项需要处理 · 1 台设备在播放 · 5 个任务进行中」，需要处理标红），
///   不用 navigationSubtitle：它会把大标题压成小号，与其它标签页不一致；
/// - **历史与统计只露一小段**（3 条 / 一张 7 天摘要卡），分组标题右侧「查看全部」压栈到二级页
///   （`ActivityPageView`），成员 / 周期 / 范围筛选在二级页右上角；
/// - **系统分组列表**：行自带按压高亮、左滑操作、长按菜单、下拉刷新；「需要处理」例外，保留完整卡片——
///   每种故障的补救动作不同（换种、重试、交给 AI、删除、忽略），压成一行反而要多点一层；
/// - **浏览范围**（我的浏览范围 / 全部）不占顶栏：只在确有被隐藏的内容时以分组脚注出现、就地切换。
///
/// 数据全部来自外壳常驻的 `ShellBadges.tasks / media`（SSE + 轮询，来回切标签不打断）：最近播放与 7 天统计
/// 也由 `media` 预取（见 MediaActivityStore），打开就是完整的一页，页面出现时只做一次就地刷新。
struct ActivityView: View {
    @Environment(ShellBadges.self) private var badges
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(Router.self) private var router

    @State private var taskActions = TaskCenterActions()
    @State private var deviceActions = ActivityDeviceActions()
    /// 刷流在池概况（刷流行要按站点开关状态、待清理数写文案）；只在有刷流种子时取
    @State private var boostPool: API.BoostPoolView?

    /// 总览上「进行中」最多露几条，其余进二级页
    private static let activeLimit = 5
    /// 最近完成露几条（最近播放的条数见 MediaActivityStore.recentPlaysLimit）
    private static let recentLimit = 3

    /// 进行中的一条：下载组或后台作业（两者在二级页的时间线里也是这个顺序）
    private enum ActiveItem: Identifiable {
        case group(TaskCenter.DownloadGroup)
        case job(API.JobView)

        var id: String {
            switch self {
            case let .group(group): "group:\(group.id)"
            case let .job(job): "job:\(job.id)"
            }
        }
    }

    var body: some View {
        let tasks = badges.tasks
        let media = badges.media
        let activity = tasks.activity
        let snapshot = media.snapshot
        List {
            Section {} header: {
                summary(activity: activity, snapshot: snapshot)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .textCase(nil)
                    .accessibilityIdentifier("activity-summary")
                    // 实时通道状态给 UI 测试核对（live-事件数 / poll-事件数）
                    .accessibilityValue("\(tasks.streamConnected ? "live" : "poll")-\(tasks.streamEventCount)")
            }

            if media.error != nil || tasks.downloadsError != nil || tasks.sources.contains(where: { $0.status != "active" }) {
                Section {
                    VStack(spacing: 8) {
                        if let error = media.error { ActivityWarningBanner(message: error) }
                        TaskSourceWarning(store: tasks)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if activity.attentionTotal > 0 {
                Section {
                    TaskCenterPanel(store: tasks, mode: .attention, actions: taskActions)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    let canDismissAll = activity.standaloneAttentionJobs.contains { $0.status == "failed" }
                    ActivitySectionHeader(
                        title: String(localized: .activityJobStatusBlocked), count: activity.attentionTotal, tint: Theme.danger,
                        trailing: canDismissAll ? (taskActions.bulkDismissing ? String(localized: .activityJobsDismissing) : String(localized: .activityTaskCenterDismissAll)) : nil,
                        trailingIdentifier: "dismiss-all-failed", chevron: false,
                        action: { taskActions.dismissAllFailed(api: api, feedback: feedback, store: tasks) }
                    )
                }
            }

            if !snapshot.sessions.isEmpty || snapshot.hiddenSessionCount > 0 {
                Section {
                    ForEach(snapshot.sessions, id: \.self) { session in
                        ActivityPlaybackSessionRow(session: session, store: media, actions: deviceActions)
                    }
                } header: {
                    ActivitySectionHeader(title: String(localized: .activityOverviewPlaying), count: snapshot.sessions.count + snapshot.hiddenSessionCount, tint: Theme.success)
                } footer: {
                    scopeFooter(hidden: snapshot.hiddenSessionCount) { String(localized: .activityOverviewHiddenSessions($0)) }
                }
            }

            if !snapshot.downloads.isEmpty || snapshot.hiddenDownloadCount > 0 {
                Section {
                    ForEach(snapshot.downloads, id: \.self) { download in
                        ActivityFileDownloadRow(download: download, store: media, actions: deviceActions)
                    }
                } header: {
                    ActivitySectionHeader(title: String(localized: .activityOverviewDownloading), count: snapshot.downloads.count + snapshot.hiddenDownloadCount)
                } footer: {
                    scopeFooter(hidden: snapshot.hiddenDownloadCount) { String(localized: .activityOverviewHiddenDownloads($0)) }
                }
            }

            if activity.activeTotal > 0 || !activity.boostTasks.isEmpty {
                Section {
                    ForEach(activeItems(activity).prefix(Self.activeLimit)) { item in
                        activeRow(item, activity: activity)
                    }
                    if !activity.boostTasks.isEmpty {
                        NavigationLink(value: AppRoute.activityPage(.boost)) {
                            ActivityBoostSummaryRow(tasks: activity.boostTasks, pool: boostPool)
                        }
                    }
                } header: {
                    ActivitySectionHeader(
                        title: String(localized: .activityJobStatusRunning), count: activity.activeTotal > 0 ? activity.activeTotal : nil,
                        trailing: activity.activeTotal > 0 ? String(localized: .activityOverviewSeeAll) : nil, trailingIdentifier: "activity-active-all",
                        action: { router.push(.activityPage(.active)) }
                    )
                }
            }

            if !media.recentPlays.isEmpty {
                Section {
                    ForEach(media.recentPlays, id: \.id) { entry in
                        if let route = WatchFormat.detailRoute(entry.media) {
                            NavigationLink(value: route) { ActivityRecentPlayRow(entry: entry) }
                        } else {
                            ActivityRecentPlayRow(entry: entry)
                        }
                    }
                } header: {
                    ActivitySectionHeader(
                        title: String(localized: .activityNavPlays), trailing: String(localized: .activityOverviewSeeAll), trailingIdentifier: "activity-plays-all",
                        action: { router.push(.activityPage(.plays)) }
                    )
                }
            }

            if let weekly = media.weekly {
                Section {
                    NavigationLink(value: AppRoute.activityPage(.stats)) { ActivityWeeklyWatchCard(stats: weekly) }
                } header: {
                    ActivitySectionHeader(
                        title: String(localized: .activityNavStats), trailing: String(localized: .activityOverviewSeeAll), trailingIdentifier: "activity-stats-all",
                        action: { router.push(.activityPage(.stats)) }
                    )
                }
            }

            if !activity.standaloneHistoricalJobs.isEmpty {
                Section {
                    ForEach(activity.standaloneHistoricalJobs.prefix(Self.recentLimit), id: \.id) { job in
                        finishedRow(job, store: tasks)
                    }
                } header: {
                    ActivitySectionHeader(
                        title: String(localized: .activityOverviewRecentFinished), trailing: String(localized: .activityOverviewSeeAllCount(activity.historyTotal)), trailingIdentifier: "activity-finished-all",
                        action: { router.push(.activityPage(.finished)) }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .padReadableWidth(880)
        .headerProminence(.increased)
        .scrollContentBackground(.hidden)
        .refreshable {
            tasks.refreshJobs()
            tasks.refreshDownloads()
            media.refresh()
            await media.refreshExtras()
            await loadBoostPool()
        }
        .navigationTitle(String(localized: .activityNavTitle))
        .toolbarTitleDisplayMode(.inlineLarge)
        .appBackground()
        .taskDeleteSheet(taskActions, store: tasks)
        // 外壳已预取过，这里只为拿最新（观看时长、看到哪会一直变），回来后就地更新
        .task { await media.refreshExtras() }
        .task(id: activity.boostTasks.isEmpty) { await loadBoostPool() }
        .onChange(of: router.rootParameter, initial: true) { _, parameter in
            // 站内链接 /activity?view=…：点名二级页的（plays / stats / history / active）接着压栈打开，
            // 其余（需要处理、正在播放、全部、缺省）都落在总览本身
            guard let parameter, parameter.tab == .activity else { return }
            router.rootParameter = nil
            if let page = ActivityPage(webView: parameter.value) { router.push(.activityPage(page)) }
        }
    }

    // MARK: 摘要 / 脚注

    /// 「2 项需要处理 · 1 台设备在播放 · 5 个任务进行中」；什么都没有时「一切正常 · 现在没有人在看」
    private func summary(activity: TaskCenter.Activity, snapshot: API.MediaActivityView) -> Text {
        if !badges.tasks.jobsLoaded, badges.media.loading { return Text(String(localized: .activityOverviewLoading)) }
        let watching = snapshot.sessions.count + snapshot.hiddenSessionCount
        let downloading = snapshot.downloads.count + snapshot.hiddenDownloadCount
        var parts: [Text] = []
        if activity.attentionTotal > 0 {
            parts.append(Text(String(localized: .activityNavTaskAttentionCount(activity.attentionTotal))).foregroundColor(Theme.danger).fontWeight(.semibold))
        }
        if watching > 0 { parts.append(Text(String(localized: .activityOverviewWatchingCount(watching)))) }
        if downloading > 0 { parts.append(Text(String(localized: .activityOverviewDownloadingCount(downloading)))) }
        if activity.activeTotal > 0 { parts.append(Text(String(localized: .activityOverviewActiveCount(activity.activeTotal)))) }
        if parts.isEmpty { return Text("\(String(localized: .activityOverviewHealthy)) · \(String(localized: .activityOverviewNoOneWatching))") }
        if watching == 0 { parts.append(Text(String(localized: .activityOverviewNoOneWatching))) }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }

    /// 浏览范围脚注：有被隐藏的内容才出现，就地切到「全部」；已是「全部」时给回退出口
    @ViewBuilder
    private func scopeFooter(hidden: Int, text: (Int) -> String) -> some View {
        let media = badges.media
        if hidden > 0 || media.scope == "all" {
            HStack(spacing: 4) {
                Text(hidden > 0 ? text(hidden) : String(localized: .activityOverviewScopeIncludesHidden))
                Button(hidden > 0 ? String(localized: .activityOverviewShowAll) : String(localized: .activityOverviewScopeMineAction)) {
                    media.setScope(hidden > 0 ? "all" : "visible")
                }
                .fontWeight(.semibold)
                .foregroundStyle(Theme.info)
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity-scope-toggle")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textFaint)
        }
    }

    // MARK: 行

    private func activeItems(_ activity: TaskCenter.Activity) -> [ActiveItem] {
        activity.activeDownloadGroups.map(ActiveItem.group) + activity.standaloneActiveJobs.map(ActiveItem.job)
    }

    /// 进行中的一行：点进「进行中」二级页看完整过程；左滑删种（单资源）/ 取消作业
    @ViewBuilder
    private func activeRow(_ item: ActiveItem, activity: TaskCenter.Activity) -> some View {
        let tasks = badges.tasks
        switch item {
        case let .group(group):
            NavigationLink(value: AppRoute.activityPage(.active)) {
                ActivityActiveDownloadRow(group: group, ingestJobsByHash: activity.ingestJobsByHash)
            }
            .swipeActions(allowsFullSwipe: false) {
                if group.tasks.count == 1, let task = group.tasks.first, task.downloaderId != nil {
                    Button(String(localized: .commonDelete), systemImage: "trash") { taskActions.pendingDelete = task }.tint(.red)
                }
            }
        case let .job(job):
            NavigationLink(value: AppRoute.activityPage(.active)) {
                ActivityActiveJobRow(job: job)
            }
            .swipeActions(allowsFullSwipe: false) {
                if job.status != "cancelling" {
                    Button(String(localized: .activityJobsCancelAction), systemImage: "xmark") { taskActions.cancel(job, api: api, feedback: feedback, store: tasks) }
                        .tint(.orange)
                        .disabled(taskActions.cancellingJobId != nil)
                }
            }
        }
    }

    /// 最近完成的一行：点进「已结束」；左滑撤销忽略（被忽略的失败）/ 重新执行（用户取消的）
    private func finishedRow(_ job: API.JobView, store: TaskActivityStore) -> some View {
        NavigationLink(value: AppRoute.activityPage(.finished)) {
            ActivityFinishedJobRow(job: job)
        }
        .swipeActions(allowsFullSwipe: false) {
            if job.status == "failed", TaskCenter.isDismissed(job) {
                Button(String(localized: .activityJobsRestoreAction), systemImage: "arrow.uturn.backward") {
                    taskActions.undismiss(job, api: api, feedback: feedback, store: store)
                }
                .tint(.blue)
            } else if job.status == "cancelled", !TaskCenter.isSystemCancelled(job) {
                Button(String(localized: .activityJobsRetryAction), systemImage: "arrow.clockwise") {
                    taskActions.retry(job, api: api, feedback: feedback, store: store)
                }
                .tint(.blue)
            }
        }
    }

    // MARK: 数据

    /// 刷流在池概况：只在有刷流种子时取
    private func loadBoostPool() async {
        if !badges.tasks.activity.boostTasks.isEmpty, let loaded = await ActivityBoostPoolLoader.load(api) { boostPool = loaded.pool }
    }
}
