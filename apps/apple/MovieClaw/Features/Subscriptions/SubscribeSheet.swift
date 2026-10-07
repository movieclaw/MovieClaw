import SwiftUI

/// 全局订阅弹层（对应 Web `components/subscribe-dialog.tsx`）：一次点击完成订阅，复杂度沉到默认值。
/// 由 `router.present(.subscribe(...))` 唤起——发现海报、影片详情、搜索结果、AI 卡片、媒体库「洗版」共用。
///
/// 流程对应后端 `POST /subscriptions/title-preview` 的三态：
/// - ready：品质 / 等待摘要；追踪范围与更多选项进入子页；首次智能设置保存后才可确认；
/// - ambiguous：豆瓣收敛歧义，候选海报墙确认一次后带新引用重新预检；
/// - not_found：TMDB 未收录，无法订阅。
/// 已订阅的条目进入管理态：取消订阅（成员 = 取消关注；管理员叠一层带预览的彻底删除）。
///
/// 默认值：剧集勾选全部已播正季（豆瓣季条目采信服务端 suggested_seasons）；在播剧开自动续订；
/// 默认智能选择；电影和剧集分别复用服务器偏好。规则模式与目标库收进更多选项，配置异常保持可见。
///
/// 洗版变体（`request.upgrade`）：季按库存预填、（超管）只列带洗版目标的规则组（成员不选组）、自动续订默认关；
/// 建好订阅后立刻跑一轮洗版并在弹层内展示体检报告。
///
/// 交互形态按 iOS 26 表单弹层：绝大多数时候只是确认一下默认值，所以弹层高度跟内容走（半高悬浮，
/// 系统给液态玻璃材质，不自设背景以免盖掉），正文是原生分组列表，左上 ✕ 关闭、右上 ✓ 确认；
/// 「新建规则组」这种低频操作收进规则组菜单末尾。只有洗版体检报告内容多，直接全高。
struct SubscribeSheet: View {
    let request: SubscribeRequest

    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model

    @State private var prepared: API.PrepareView?
    @State private var error: String?
    @State private var ruleSets: [API.RuleSetView] = []
    @State private var libraries: [API.LibraryView] = []
    @State private var selectedSeasons: Set<Int> = []
    @State private var followFuture = false
    @State private var ruleSetId: Int?
    @State private var libraryId: Int?
    @State private var busy = false
    @State private var dispatchPreview: API.DispatchPreviewView?
    /// 收藏范围路由的预选结论（用户改选其它库即显式指定，说明消失）
    @State private var routed: (libraryId: Int, reason: String?)?
    /// 规则组适用范围的预选结论
    @State private var ruleRouted: (ruleSetId: Int, reason: String)?
    @State private var upgradeReport: API.UpgradeRunView?
    @State private var creatingRuleSet = false
    @State private var cancelling = false

    @State private var selectionMode = "smart"
    @State private var smartProfile: SmartProfile?
    @State private var pages: [Page] = []
    @State private var formHeight: CGFloat = 0

    enum Page: Hashable { case smart, range, options }

    private var upgradeMode: Bool { request.upgrade }
    private var canManage: Bool { permissions.canManageSubscriptions }

    /// 入口引用自带的类型（`tmdb:movie:1` / `douban:tv:2`）；豆瓣裸 ID 没有类型，等后端收敛
    private var requestKind: String? {
        let parts = request.titleRef.split(separator: ":").map(String.init)
        return parts.count >= 3 && (parts[1] == "movie" || parts[1] == "tv") ? parts[1] : nil
    }

    private var kind: String { prepared?.media?.kind ?? requestKind ?? "movie" }
    private var displayTitle: String { prepared?.media?.title ?? request.title ?? "" }

    private var selectableRules: [API.RuleSetView] {
        upgradeMode ? ruleSets.filter { $0.upgradeTarget != nil } : ruleSets
    }

    private var canSubmit: Bool {
        guard let media = prepared?.media, !busy, pages.isEmpty else { return false }
        if selectionMode == "smart", smartProfile?.preferences == nil || smartProfile?.kind != media.kind { return false }
        if upgradeMode, canManage, !selectableRules.contains(where: { $0.id == ruleSetId }) { return false }
        if media.kind == "movie" { return true }
        return !selectedSeasons.isEmpty || followFuture
    }

    private var showsSubmit: Bool { prepared?.status == "ready" && prepared?.existingSubscriptionId == nil }
    /// 规则组只有超管能选（`GET /rule-sets` 仅超管可读）；成员洗版沿用订阅当前的规则组（member-permissions-v2 §3.7）
    private var showsRules: Bool { canManage && selectionMode == "rules" && (upgradeMode || !ruleSets.isEmpty) }
    private var showsLibrary: Bool { canManage && !libraries.isEmpty }
    private var pickedRule: API.RuleSetView? { selectableRules.first { $0.id == ruleSetId } }

    var body: some View {
        Group {
            if let upgradeReport {
                SubsSheetScaffold(
                    title: "订阅《\(displayTitle)》",
                    closable: false,
                    confirm: SubsSheetConfirm(title: "完成", identifier: "upgrade-report-done") { dismiss() },
                    fullHeight: true
                ) {
                    UpgradeRunReportView(title: displayTitle, isMovie: kind == "movie", report: upgradeReport)
                }
            } else {
                NavigationStack(path: $pages) {
                    Form { content }
                        .subsFormStyle()
                        .listSectionSpacing(12)
                        .onScrollGeometryChange(for: CGFloat.self) { geometry in
                            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                        } action: { _, height in
                            formHeight = height
                        }
                        .navigationTitle(upgradeMode ? "订阅并洗版" : "订阅")
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationDestination(for: Page.self) { page in
                            switch page {
                            case .smart:
                                if let smartProfile {
                                    SmartProfileEditor(kind: kind, profile: smartProfile) { self.smartProfile = $0 }
                                }
                            case .range:
                                Form { rangeFields }.subsFormStyle().navigationTitle("追踪范围")
                                    .navigationBarTitleDisplayMode(.inline)
                            case .options:
                                Form { optionFields }.subsFormStyle().navigationTitle("更多选项")
                                    .navigationBarTitleDisplayMode(.inline)
                            }
                        }
                        .toolbar {
                            if pages.isEmpty {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("取消", systemImage: "xmark", role: .close) { dismiss() }
                                        .disabled(busy).accessibilityIdentifier("sheet-close")
                                }
                                if showsSubmit {
                                    ToolbarItem(placement: .confirmationAction) {
                                        if busy { ProgressView() }
                                        else {
                                            Button(upgradeMode ? "订阅并开始洗版" : "确认订阅", systemImage: "checkmark", role: .confirm) {
                                                Task { await submit() }
                                            }
                                            .discoverProminentButton().disabled(!canSubmit)
                                            .accessibilityIdentifier("subscribe-submit")
                                        }
                                    }
                                }
                            }
                        }
                }
                .modifier(SubsFittedDetents(ready: prepared != nil || error != nil, fullHeight: !pages.isEmpty, contentHeight: formHeight))
            }
        }
        .interactiveDismissDisabled(busy || pages.contains(.smart))
        .accessibilityIdentifier("subscribe-sheet")
        .task { await runPrepare(request.titleRef) }
        // 投递路由预览随「入库库」与「预检收敛出的条目」两者变化重拉（同 Web 依赖 [prepared?.media, libraryId]）：
        // 豆瓣歧义选定候选后库 id 可能不变，只盯库 id 会漏掉这次重拉
        .task(id: "\(libraryId ?? -1)-\(prepared?.media?.tmdbId ?? -1)") { await refreshDispatchPreview() }
        .sheet(isPresented: $creatingRuleSet) {
            RuleSetEditorSheet(ruleSet: nil) { saved in
                ruleSets.append(saved)
                // 洗版变体只接受带洗版目标的组；新组没配目标就不抢选中
                if !upgradeMode || saved.upgradeTarget != nil { ruleSetId = saved.id }
            }
        }
        .sheet(isPresented: $cancelling) {
            if let id = prepared?.existingSubscriptionId {
                SubscriptionCancelSheet(subscriptionId: id, title: displayTitle) { torrents, files in
                    await removePermanently(id, torrents: torrents, files: files)
                }
            }
        }
    }

    // MARK: 正文

    @ViewBuilder
    private var content: some View {
        if upgradeMode {
            Section {
                header
            } footer: {
                Text("洗版通过订阅持续追踪更好的版本：确认后建立订阅并立即体检库里已有的每一集。")
            }
            .subsBareRow()
        } else {
            Section { header }.subsBareRow()
        }

        if let error {
            Section {
                SubsNoticeRow(text: error, tone: .error).accessibilityIdentifier("subscribe-error")
            }
        }
        if let prepared {
            switch prepared.status {
            case "not_found":
                Section {
                    Text("TMDB 未收录该条目，暂时无法订阅。订阅依赖 TMDB 的别名与季集数据来匹配站点资源，可尝试在 TMDB 搜索入口确认条目后再订阅。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("subscribe-not-found")
                }
            case "ambiguous":
                Section {
                    candidateWall(prepared.candidates)
                } header: {
                    Text("找到多个可能的条目，请确认你订阅的是哪一部")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            default:
                if let existing = prepared.existingSubscriptionId {
                    manageState(existing)
                } else {
                    form(prepared)
                }
            }
        }
    }

    /// 条目卡：海报 + 片名 + 年份与类型，一眼确认订的是哪一部；加载中在这里转圈
    private var header: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 56, height: 84)
                .overlay { RemoteImage(url: api.image(prepared?.media?.posterUrl, width: ImageWidth.points(56))) }
                .background(Color.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle).font(.title3.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(2)
                if let meta = headerMeta {
                    Text(meta).font(.subheadline).foregroundStyle(.secondary)
                }
                if prepared == nil, error == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在获取条目信息…")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                } else if prepared?.movieOwned == true, prepared?.existingSubscriptionId == nil {
                    Label(upgradeMode ? "媒体库已有，将体检现有版本并按需洗版" : "媒体库已有，订阅后不会重复下载", systemImage: "checkmark")
                        .font(.footnote).foregroundStyle(SubsColor.ok)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 「2026 · 电影」；类型未收敛（豆瓣裸 ID）时只写年份
    private var headerMeta: String? {
        let kindText = (prepared?.media?.kind ?? requestKind).map { $0 == "movie" ? "电影" : "剧集" }
        let parts = [prepared?.media?.year.map(String.init), kindText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func candidateWall(_ candidates: [API.ResolveCandidateView]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 14) {
            ForEach(candidates, id: \.tmdbId) { candidate in
                Button {
                    Task { await runPrepare(candidate.titleRef) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .overlay { MeasuredRemoteImage(raw: candidate.posterUrl) }
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
                        Text(candidate.title).font(.subheadline).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(1)
                        Text(candidate.year.map(String.init) ?? "年份未知").font(.caption).foregroundStyle(Theme.textFaint)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("subscribe-candidate")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subscribe-ambiguous")
    }

    /// 已订阅：管理态。关闭走左上 ✕；动作是原生列表行，破坏性的「取消订阅」单独一组垫底
    @ViewBuilder
    private func manageState(_ existing: Int) -> some View {
        Section {
            Label("该\(kind == "movie" ? "电影" : "剧集")已在订阅中，movieclaw 正在持续追踪资源。", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.text.opacity(0.85))
                .symbolRenderingMode(.multicolor)
                .accessibilityIdentifier("subscribe-existing")
        }
        Section {
            if upgradeMode {
                // 洗版入口进到已有订阅：并入既有订阅，去详情触发一轮
                Button("去洗一轮版", systemImage: "sparkles") {
                    dismiss()
                    router.push(.subscription(id: existing, upgradeRun: true))
                }
                .accessibilityIdentifier("subscribe-go-upgrade")
            }
            Button("查看订阅详情", systemImage: "list.bullet.rectangle") {
                dismiss()
                router.push(.subscription(id: existing))
            }
            .accessibilityIdentifier("subscribe-open-detail")
        }
        Section {
            Button("取消订阅", systemImage: "bell.slash", role: .destructive) {
                Task { await unsubscribe(existing) }
            }
            .disabled(busy)
            .accessibilityIdentifier("subscribe-unsubscribe")
        }
    }

    /// 订阅表单（ready 且未订阅）
    @ViewBuilder
    private func form(_ prepared: API.PrepareView) -> some View {
        if selectionMode == "smart" {
            SmartProfileSection(kind: kind, profile: $smartProfile) {
                if pages.isEmpty { pages.append(.smart) }
            }
                .id(kind)
        } else {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(upgradeMode ? "洗版规则" : "规则模式").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if canManage {
                            Button("修改规则") { pages.append(.options) }
                                .font(.subheadline).buttonStyle(.borderless)
                        }
                    }
                    Text(pickedRule?.name ?? "按系统规则选择").font(.headline)
                    if let pickedRule, RuleSetText.summary(pickedRule.typedSpec).isEmpty {
                        Text("当前规则不限品质，可能选到低画质资源。")
                            .font(.footnote).foregroundStyle(SubsColor.warn)
                    }
                    if upgradeMode {
                        Text(pickedRule?.upgradeTarget.map { "洗到 \($0)" } ?? "按订阅当前的规则组洗版")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if prepared.media?.kind == "tv" {
            Section {
                NavigationLink(value: Page.range) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("追踪范围").font(.subheadline).foregroundStyle(.secondary)
                        Text(rangeSummary).font(.body.weight(.medium))
                        Text(followFuture ? "自动追踪新集和新季" : "仅收录所选季")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("subscribe-range")
                if selectedSeasons.isEmpty && !followFuture {
                    Text("请选择至少一季，或开启自动续订。").font(.footnote).foregroundStyle(SubsColor.warn)
                }
            }
        }
        if !upgradeMode || canManage {
            Section {
                NavigationLink(value: Page.options) {
                    LabeledContent("更多选项") {
                        if let library = libraries.first(where: { $0.id == libraryId }) {
                            Text("存入「\(library.name)」").font(.subheadline)
                        }
                    }
                }.accessibilityIdentifier("subscribe-options")
            }
        }
        if let preview = dispatchPreview, !preview.ok {
            Section { SubsNoticeRow(text: preview.warning ?? "下载与入库配置尚未就绪", tone: .warn) }
        }
    }

    @ViewBuilder private var rangeFields: some View {
        Section("收录的季") {
            ForEach(prepared?.seasons ?? [], id: \.seasonNumber) { season in
                SeasonPickRow(season: season, checked: selectedSeasons.contains(season.seasonNumber)) {
                    if selectedSeasons.contains(season.seasonNumber) { selectedSeasons.remove(season.seasonNumber) }
                    else { selectedSeasons.insert(season.seasonNumber) }
                }
            }
        }
        Section {
            Toggle("自动续订", isOn: $followFuture)
                .toggleStyle(SystemSwitchStyle()).accessibilityIdentifier("subscribe-follow-future")
        } footer: { Text("自动追踪新集和新季") }
    }

    @ViewBuilder private var optionFields: some View {
        Section {
            if !upgradeMode {
                Picker("选择方式", selection: $selectionMode) {
                    Text("智能选择").tag("smart")
                    Text("规则模式").tag("rules")
                }.pickerStyle(.menu).accessibilityIdentifier("subscribe-mode")
            }
            if showsRules { ruleRow }
        }
        if showsLibrary {
            Section {
                Picker("入库到", selection: $libraryId) {
                    ForEach(libraries, id: \.id) { library in
                        Text(library.name + (library.isDefault ? "（默认）" : "")).tag(Int?.some(library.id))
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("subscribe-library")
            } footer: { routingFooter.font(.footnote) }
        }
    }

    private var rangeSummary: String {
        let seasons = selectedSeasons.sorted()
        if seasons.isEmpty { return followFuture ? "仅追新集" : "选择要收录的季" }
        return seasons.count > 3 ? "已选 \(seasons.count) 季" : seasons.map(SubsFormat.seasonName).joined(separator: "、")
    }

    /// 规则组行：原生菜单行，菜单里单选规则组，末尾是低频的「新建规则组…」
    @ViewBuilder
    private var ruleRow: some View {
        let title = upgradeMode ? "洗版规则" : "资源规则"
        if upgradeMode, selectableRules.isEmpty {
            Text(canManage
                ? "还没有配置洗版目标的规则组——新建一个，在编辑器里选择「洗到哪一档」即可。"
                : "还没有配置洗版目标的规则组，请联系管理员在「设置 → 订阅规则 → 规则组」中配置「洗到哪一档」。")
                .font(.subheadline).foregroundStyle(.secondary)
            if canManage {
                Button("新建规则组…", systemImage: "plus") { creatingRuleSet = true }
                    .accessibilityIdentifier("subscribe-new-ruleset")
            }
        } else {
            Menu {
                Picker(title, selection: $ruleSetId) {
                    ForEach(selectableRules, id: \.id) { rule in
                        Text(rule.name + (rule.isDefault ? "（默认）" : "") + (upgradeMode ? " · 洗到 \(rule.upgradeTarget ?? "")" : ""))
                            .tag(Int?.some(rule.id))
                    }
                }
                if canManage {
                    Divider()
                    Button("新建规则组…", systemImage: "plus") { creatingRuleSet = true }
                        .accessibilityIdentifier("subscribe-new-ruleset")
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        Text(pickedRule?.name ?? "未选择").lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    // 品质摘要放在行内：行底比脚注背后的毛玻璃实，字才看得清
                    if let picked = pickedRule {
                        let chips = RuleSetText.summary(picked.typedSpec)
                        // 全不限是个危险默认：把风险讲在订阅之前
                        Text(chips.isEmpty
                            ? "该规则组不限任何条件——可能抓到低画质或无人做种的资源，建议在「设置 → 订阅规则 → 规则组」里加上分辨率与做种数限制"
                            : chips.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(chips.isEmpty ? SubsColor.warn : Theme.textMuted)
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier("subscribe-ruleset-summary")
                    }
                }
                .contentShape(.rect)
            }
            .accessibilityIdentifier("subscribe-ruleset")
        }
    }

    /// 规则 / 入库分组的脚注：路由选中非默认项的理由、投递路径。
    /// 脚注背后是毛玻璃，系统次要色太淡，统一提到 textMuted
    @ViewBuilder
    private var routingFooter: some View {
        if showsRules, let ruleRouted, ruleSetId == ruleRouted.ruleSetId, pickedRule?.isDefault == false {
            Label("按适用范围自动选择", systemImage: "sparkles").foregroundStyle(Theme.textMuted)
        }
        if showsLibrary, let routed, let reason = routed.reason, libraryId == routed.libraryId,
           libraries.first(where: { $0.id == routed.libraryId })?.isDefault == false {
            Label(reason, systemImage: "sparkles").foregroundStyle(Theme.textMuted)
                .accessibilityIdentifier("subscribe-routed-library")
        }
    }

    // MARK: 数据

    /// 预检并按结果初始化表单默认值（候选确认后带新引用再次进入）
    private func runPrepare(_ ref: String) async {
        prepared = nil
        smartProfile = nil
        selectionMode = upgradeMode ? "rules" : "smart"
        error = nil
        upgradeReport = nil
        do {
            async let resultTask = api.uiSubscriptionsPreviewTitle(body: .init(titleRef: ref))
            async let rulesTask: [API.RuleSetView] = canManage ? api.rulesList() : []
            async let libsTask: [API.LibraryView] = canManage && requestKind != nil ? api.libraryList(kind: requestKind, scope: "all") : []
            let (result, rules, initialLibs) = try await (resultTask, rulesTask, libsTask)
            // 媒体库与投递路由以后端收敛后的 canonical kind 为准（豆瓣引用可能被收敛成另一类型）
            let resolvedKind = result.media?.kind ?? requestKind ?? "movie"
            let libs = !canManage || resolvedKind == requestKind ? initialLibs : try await api.libraryList(kind: resolvedKind, scope: "all")
            ruleSets = rules
            libraries = libs
            routed = nil
            ruleRouted = nil
            var pickedLibrary = libs.first { $0.isDefault }?.id ?? libs.first?.id
            var pickedRule: Int?
            var pickedReason: String?
            if canManage, result.status == "ready", let media = result.media {
                let preview = try? await api.subscriptionsPreviewDownloadRouting(kind: resolvedKind, libraryId: nil, tmdbId: media.tmdbId)
                if let id = preview?.libraryId, libs.contains(where: { $0.id == id }) {
                    pickedLibrary = id
                    routed = (id, preview?.routeReason)
                }
                if let id = preview?.ruleSetId {
                    pickedRule = id
                    pickedReason = preview?.ruleSetMatched == true ? preview?.ruleSetReason : nil
                }
            }
            let candidates = upgradeMode ? rules.filter { $0.upgradeTarget != nil } : rules
            let scoped = candidates.first { $0.id == pickedRule }
            ruleSetId = (scoped ?? candidates.first { $0.isDefault } ?? candidates.first)?.id
            if let scoped, let pickedReason { ruleRouted = (scoped.id, pickedReason) }
            libraryId = pickedLibrary
            // 默认季：洗版按库存预填；豆瓣季条目采信 suggested_seasons；否则全部已播正季
            let defaultSeasons: [Int] = if upgradeMode {
                result.seasons.filter { $0.ownedCount > 0 }.map(\.seasonNumber)
            } else if !result.suggestedSeasons.isEmpty {
                result.suggestedSeasons
            } else {
                result.seasons.filter { $0.seasonNumber > 0 && $0.airedCount > 0 }.map(\.seasonNumber)
            }
            selectedSeasons = Set(defaultSeasons)
            followFuture = !upgradeMode && resolvedKind == "tv" && result.media?.status == "Returning Series"
            prepared = result
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription.isEmpty ? "预检失败，请稍后重试" : error.localizedDescription
        }
    }

    private func refreshDispatchPreview() async {
        guard canManage, let libraryId, let media = prepared?.media else {
            dispatchPreview = nil
            return
        }
        dispatchPreview = nil
        // 带上条目身份：后端据此渲染条目目录预览（entry_dir），前端不自己拼名字
        dispatchPreview = try? await api.subscriptionsPreviewDownloadRouting(
            kind: media.kind, libraryId: libraryId, tmdbId: media.tmdbId, title: media.title, year: media.year
        )
    }

    private func refreshIndex() async {
        await SubscriptionIndex.shared.refresh(api: api, owner: model.session?.username)
    }

    private func submit() async {
        guard canSubmit, let media = prepared?.media else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            // 提交预检收敛好的 TMDB 引用；豆瓣身份靠 source_title_ref 原样带回
            let created = try await api.subscriptionsCreate(body: .init(
                titleRef: "tmdb:\(media.kind):\(media.tmdbId)",
                sourceTitleRef: request.titleRef.hasPrefix("douban:") ? request.titleRef : nil,
                selectedSeasons: selectedSeasons.sorted(),
                followFuture: followFuture,
                ruleSetId: canManage && selectionMode == "rules" ? ruleSetId : nil,
                libraryId: canManage ? libraryId : nil,
                selectionMode: selectionMode,
                smartProfileRevision: selectionMode == "smart" ? smartProfile?.revision : nil
            ))
            await refreshIndex()
            if upgradeMode {
                // 洗版变体：创建成功即接一轮洗版；失败时订阅已建好，报错留在弹层里
                do {
                    upgradeReport = try await api.subscriptionsUpgradeRun(subscriptionId: created.subscription.id, body: .init(ruleSetId: canManage ? ruleSetId : nil))
                } catch {
                    self.error = "订阅已创建，但触发洗版失败：\(error.localizedDescription.isEmpty ? "请稍后到订阅详情里重试" : error.localizedDescription)"
                }
                return
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription.isEmpty ? "订阅失败，请稍后重试" : error.localizedDescription
        }
    }

    /// 管理员先叠一层问「种子与媒体库资源要不要一起删」；成员只取消自己的关注
    private func unsubscribe(_ id: Int) async {
        if permissions.isAdmin {
            cancelling = true
            return
        }
        busy = true
        defer { busy = false }
        do {
            _ = try await api.subscriptionsUnsubscribe(subscriptionId: id)
            await refreshIndex()
            dismiss()
        } catch {
            self.error = error.localizedDescription.isEmpty ? "取消订阅失败" : error.localizedDescription
        }
    }

    private func removePermanently(_ id: Int, torrents: Bool, files: Bool) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await api.subscriptionsDelete(subscriptionId: id, deleteTorrents: torrents, deleteLibraryFiles: files)
            cancelling = false
            await refreshIndex()
            dismiss()
        } catch {
            cancelling = false
            self.error = error.localizedDescription.isEmpty ? "取消订阅失败" : error.localizedDescription
        }
    }
}
