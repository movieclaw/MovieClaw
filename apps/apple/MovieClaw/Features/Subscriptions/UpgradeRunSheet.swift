import SwiftUI

/// 「洗一轮版」弹层（对应 Web `components/upgrade-run-dialog.tsx`，quality-upgrade.md §13.4/§13.5）。
///
/// 两段式：确认段 → 报告段。确认段把既有订阅的三种状态并成一条动线：
/// - 规则组未配洗版目标 → 必须先选一个带洗版目标的组（含快捷新建），「选组 + 触发」由
///   upgrade-runs 的 rule_set_id 参数合成一次调用；
/// - 库里有文件但不在订阅范围的季 → 如实列出供勾选并入（并入会连带补缺下载，是用户决策）；
/// - 订阅已暂停 → 提示并改为「恢复并触发」。
/// 报告段渲染后端体检快照，不落库、不轮询——后续进展看追踪明细的「洗版中」徽标。
struct UpgradeRunSheet: View {
    let detail: API.SubscriptionDetailView
    /// 一轮洗版已触发（报告看完关闭）后回调，父页面刷新。
    /// 报告态下任何关闭方式（「完成」、左上关闭、下滑）都会回调，同 Web 报告态 Modal 的 onClose = onFinished
    let onFinished: () -> Void

    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(\.dismiss) private var dismiss

    @State private var ruleSets: [API.RuleSetView]?
    @State private var ruleSetId: Int?
    @State private var creatingRuleSet = false
    @State private var optedSeasons: Set<Int> = []
    @State private var busy = false
    @State private var error: String?
    @State private var report: API.UpgradeRunView?
    /// 报告里点了「标注片源」的季（电影为 0）
    @State private var annotateSeason: Int?

    private var isMovie: Bool { detail.media.kind == "movie" }
    private var paused: Bool { detail.status == "paused" }
    private var upgradeRules: [API.RuleSetView] { (ruleSets ?? []).filter { $0.upgradeTarget != nil } }
    private var currentHasTarget: Bool { (ruleSets ?? []).first { $0.id == detail.ruleSetId }?.upgradeTarget != nil }
    private var selectedRule: API.RuleSetView? { upgradeRules.first { $0.id == ruleSetId } }
    /// 规则组是超管的配置（`GET /rule-sets` 仅超管可读）：成员不拉列表、不选组，
    /// 后端按订阅当前的规则组洗版（成员传了 rule_set_id 也会被忽略，member-permissions-v2 §3.7）
    private var picksRule: Bool { permissions.canManageSubscriptions && !detail.isSmart }
    private var canRun: Bool { detail.isSmart ? detail.smartPreferences?.allowUpgrade == true : !picksRule || selectedRule != nil }
    private var outOfScopeOwned: [API.SeasonOverview] {
        isMovie ? [] : detail.seasonCollection.filter { $0.ownedCount > 0 && !detail.selectedSeasons.contains($0.seasonNumber) }
    }

    var body: some View {
        Group {
            if let report {
                SubsSheetScaffold(
                    title: String(localized: .subscriptionUpgradeReportTitle),
                    closable: false,
                    confirm: SubsSheetConfirm(title: String(localized: .commonDone), identifier: "upgrade-report-done", action: finish),
                    fullHeight: true
                ) {
                    UpgradeRunReportView(
                        title: detail.media.title,
                        isMovie: isMovie,
                        report: report,
                        onAnnotate: { annotateSeason = $0 }
                    )
                }
            } else {
                confirm
            }
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $creatingRuleSet) {
            RuleSetEditorSheet(ruleSet: nil) { saved in
                ruleSets = (ruleSets ?? []) + [saved]
                // 新建组带洗版目标时自动选中（快捷新建的动机就是没得选）
                if saved.upgradeTarget != nil { ruleSetId = saved.id }
            }
        }
        .sheet(item: Binding(mcGet: { annotateSeason.map(SeasonKey.init) }, set: { annotateSeason = $0?.season })) { key in
            MediaSourceAnnotationSheet(mediaItemId: detail.media.mediaItemId, seasonNumber: key.season, isMovie: isMovie) { _ in
                // 标注已刷新快照：重跑一轮体检，报告当场翻新
                if let fresh = try? await api.subscriptionsUpgradeRun(subscriptionId: detail.id, body: .init(ruleSetId: nil)) {
                    self.report = fresh
                }
            }
        }
        .task { await loadRules() }
        .onDisappear {
            if report != nil { onFinished() }
        }
    }

    private func finish() {
        dismiss()
    }

    private var confirm: some View {
        SubsSheetScaffold(
            title: String(localized: .subscriptionUpgradeTitle),
            subtitle: String(localized: .subscriptionUpgradeDescription(detail.media.title)),
            confirm: SubsSheetConfirm(
                title: paused ? String(localized: .subscriptionUpgradeResume) : String(localized: .subscriptionUpgradeStart),
                enabled: canRun,
                busy: busy,
                identifier: "upgrade-run-start"
            ) { Task { await run() } },
            ready: !picksRule || ruleSets != nil || error != nil
        ) {
            if let error {
                Section { SubsNoticeRow(text: error, tone: .error) }
            }
            if paused {
                Section { SubsNoticeRow(text: String(localized: .subscriptionUpgradePausedHint), tone: .warn) }
            }

            if detail.isSmart {
                Section {
                    if let preferences = detail.smartPreferences {
                        Text(String(localized: .subscriptionUpgradeSmartTargetLine(preferences.targetLabel))).font(.headline)
                        Text(preferences.allowUpgrade ? String(localized: .subscriptionUpgradeSmartUpgradeOn) : String(localized: .subscriptionUpgradeSmartUpgradeOff))
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else { Text(String(localized: .subscriptionUpgradeSmartUnreadable)) }
                }
            } else if !picksRule {
                Section {
                    Text(String(localized: .subscriptionUpgradeCurrentRules)).foregroundStyle(Theme.textMuted)
                } header: {
                    Text(String(localized: .subscriptionUpgradeTarget))
                }
            } else {
                Section {
                    if ruleSets == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: .subscriptionUpgradeLoadingRules)).foregroundStyle(Theme.textMuted)
                        }
                    } else {
                        ForEach(upgradeRules, id: \.id) { rule in
                            SubsChoiceRow(
                                title: rule.name + (rule.id == detail.ruleSetId ? String(localized: .subscriptionUpgradeCurrentSuffix) : ""),
                                subtitle: String(localized: .subscriptionUpgradeUpgradeTo(rule.upgradeTarget ?? "")),
                                selected: rule.id == ruleSetId,
                                tint: SubsColor.upgrade
                            ) {
                                ruleSetId = rule.id
                            }
                            .disabled(busy)
                            .accessibilityIdentifier("upgrade-rule-option")
                        }
                        if permissions.canManageSubscriptions {
                            Button(String(localized: .subscriptionUpgradeNewRules), systemImage: "plus") { creatingRuleSet = true }
                        }
                    }
                } header: {
                    Text(String(localized: .subscriptionUpgradeTarget))
                } footer: {
                    if ruleSets != nil {
                        if upgradeRules.isEmpty {
                            Text(AppFormatting.sentences([
                                String(localized: .subscriptionUpgradeNoRules),
                                permissions.canManageSubscriptions ? String(localized: .subscriptionUpgradeCreateRulesHint) : String(localized: .subscriptionUpgradeAskAdminRulesHint),
                            ]))
                        } else if !currentHasTarget {
                            Text(String(localized: .subscriptionUpgradeChooseRulesHint))
                        }
                    }
                }
            }

            if !outOfScopeOwned.isEmpty {
                Section {
                    ForEach(outOfScopeOwned, id: \.seasonNumber) { season in
                        let stock = (season.episodeCount.map { season.ownedCount < $0 } ?? false)
                            ? String(localized: .subscriptionUpgradeOwnedOfTotal(season.ownedCount, season.episodeCount ?? 0))
                            : String(localized: .subscriptionUpgradeOwnedEpisodes(season.ownedCount))
                        SubsChoiceRow(
                            title: SubsFormat.seasonName(season.seasonNumber),
                            subtitle: stock,
                            selected: optedSeasons.contains(season.seasonNumber)
                        ) {
                            if optedSeasons.contains(season.seasonNumber) { optedSeasons.remove(season.seasonNumber) } else { optedSeasons.insert(season.seasonNumber) }
                        }
                        .disabled(busy)
                    }
                } header: {
                    Text(String(localized: .subscriptionUpgradeOutsideSeasons))
                } footer: {
                    Text(String(localized: .subscriptionUpgradeOutsideHint))
                }
            }
        }
        .accessibilityIdentifier("upgrade-run-sheet")
    }

    private func loadRules() async {
        guard picksRule else { return }
        do {
            let rules = try await api.rulesList()
            ruleSets = rules
            // 现用组已配洗版目标 → 预选它；否则只有一个可选组时也预选
            if let current = rules.first(where: { $0.id == detail.ruleSetId }), current.upgradeTarget != nil {
                ruleSetId = current.id
            } else {
                let candidates = rules.filter { $0.upgradeTarget != nil }
                ruleSetId = candidates.count == 1 ? candidates[0].id : nil
            }
        } catch is CancellationError {
        } catch {
            self.error = String(localized: .subscriptionUpgradeLoadFailed)
        }
    }

    private func run() async {
        guard canRun else { return }
        guard !picksRule || selectedRule != nil else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            if !optedSeasons.isEmpty {
                _ = try await api.subscriptionsUpdate(
                    subscriptionId: detail.id,
                    body: .init(selectedSeasons: (detail.selectedSeasons + optedSeasons).sorted())
                )
            }
            if paused {
                _ = try await api.subscriptionsSetTrackingState(subscriptionId: detail.id, body: .init(state: "active"))
            }
            // 成员不选组（selectedRule 恒为 nil），选的就是现用组时也不带
            var switchTo: Int?
            if let selectedRule, selectedRule.id != detail.ruleSetId { switchTo = selectedRule.id }
            report = try await api.subscriptionsUpgradeRun(subscriptionId: detail.id, body: .init(ruleSetId: switchTo))
        } catch {
            self.error = error.localizedDescription.isEmpty ? String(localized: .subscriptionUpgradeRunFailed) : error.localizedDescription
        }
    }
}

/// 体检报告段：摘要句 + 按季分组的单元列表（一次性快照），直接产出表单 Section，放进 `SubsSheetScaffold`。
/// 订阅弹层的洗版变体（建订阅后自动接一轮洗版）复用本段。
///
/// 「标注片源」弹层不挂在这里：原生列表的行按需创建，挂在行上的弹层滚出屏幕后可能失效，
/// 所以只回调季号，由宿主弹层统一呈现。
struct UpgradeRunReportView: View {
    let title: String
    let isMovie: Bool
    let report: API.UpgradeRunView
    /// 有值时（且为管理员）「无法确认」的季显示「标注片源」入口，参数为季号（电影为 0）
    var onAnnotate: ((Int) -> Void)?

    @Environment(\.permissions) private var permissions

    static func stateMeta(_ state: String) -> (label: String, color: Color) {
        switch state {
        case "upgradable": (String(localized: .subscriptionUpgradeStateUpgradable), SubsColor.upgrade)
        case "in_flight": (String(localized: .subscriptionUpgradeStateInFlight), SubsColor.upgradeInFlight)
        case "at_cutoff": (String(localized: .subscriptionUpgradeStateAtCutoff), SubsColor.ok)
        case "not_comparable": (String(localized: .subscriptionUpgradeStateUnknown), SubsColor.neutral)
        default: (String(localized: .subscriptionUpgradeStateMissing), SubsColor.warn)
        }
    }

    static func note(_ unit: API.UpgradeRunUnitView) -> String {
        let current = unit.currentLabel ?? String(localized: .subscriptionUpgradeUnknown)
        return switch unit.state {
        case "upgradable": String(localized: .subscriptionUpgradeUpgradableNote(current, unit.targetLabel))
        case "in_flight": String(localized: .subscriptionUpgradeInFlightNote)
        case "at_cutoff": String(localized: .subscriptionUpgradeAtCutoffNote(current))
        case "not_comparable": String(localized: .subscriptionUpgradeUnknownNote)
        default: String(localized: .subscriptionUpgradeMissingNote)
        }
    }

    var body: some View {
        let seasons = Dictionary(grouping: report.units, by: \.seasonNumber)
        let annotatable: Set<Int> = (onAnnotate != nil && permissions.isAdmin)
            ? Set(report.units.filter { $0.state == "not_comparable" }.map(\.seasonNumber)) : []
        let keys = seasons.keys.sorted()
        Section {
            SubsNoticeRow(text: report.summary, tone: .upgrade)
                .accessibilityIdentifier("upgrade-report-summary")
        } header: {
            Text(String(localized: .subscriptionUpgradeReportSubtitle(title, report.targetLabel)))
        } footer: {
            if keys.isEmpty { footerNote }
        }
        ForEach(keys, id: \.self) { season in
            Section {
                ForEach(seasons[season] ?? [], id: \.episodeNumber) { unit in
                    unitRow(unit)
                }
            } header: {
                if !isMovie || annotatable.contains(season) {
                    HStack {
                        Text(isMovie ? String(localized: .subscriptionInspectorFeature) : SubsFormat.seasonName(season))
                        Spacer()
                        if annotatable.contains(season) {
                            Button(String(localized: .subscriptionUpgradeAnnotateSource)) { onAnnotate?(season) }
                                .font(.caption.weight(.medium)).buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                }
            } footer: {
                if season == keys.last { footerNote }
            }
        }
    }

    private var footerNote: some View {
        Text(String(localized: .subscriptionUpgradeFollowUp))
    }

    private func unitRow(_ unit: API.UpgradeRunUnitView) -> some View {
        let meta = Self.stateMeta(unit.state)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(isMovie ? String(localized: .subscriptionInspectorFeature) : "E\(SubsFormat.pad(unit.episodeNumber))")
                .font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(Theme.text)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(meta.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(meta.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(meta.color.opacity(0.13), in: .capsule)
                Text(Self.note(unit)).font(.footnote).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// `.sheet(item:)` 用的季号包装
struct SeasonKey: Identifiable, Hashable {
    var season: Int
    var id: Int { season }
}
