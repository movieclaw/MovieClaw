import SwiftUI

/// 规则组编辑器（对应 Web `RuleSetEditorDialog`，components/rule-sets-panel.tsx）。
///
/// 可复用组件：订阅弹层 / 洗一轮版里的「+ 新建规则组」、之后「设置 → 订阅规则」的新建 / 编辑 / 复制
/// 都直接弹这个 sheet：
/// ```swift
/// .sheet(isPresented: $creating) { RuleSetEditorSheet(ruleSet: nil) { saved in … } }
/// .sheet(item: $editing) { rule in RuleSetEditorSheet(ruleSet: rule) { _ in reload() } }
/// RuleSetEditorSheet(ruleSet: nil, template: (name: "\(rule.name) 副本", spec: rule.typedSpec)) { … } // 复制
/// ```
///
/// 设计原则同 Web：
/// - **表单化，不手写 JSON**：spec 的每个维度铺成芯片 / 开关 / 输入框；
/// - **列表顺序即偏好**：分辨率、片源、洗版维度按点击顺序入列，芯片上标序号；
/// - **渐进披露**：「适用范围」「画质与来源」「下载与限制」默认折叠，折叠头直接显示当前摘要；
/// - **所见即所存**：底部回执与保存共用同一个 `draft`，看到的摘要就是将要存下去的东西；
/// - **矛盾在源头消除**：平台 / HDR 三态循环不可能同时进白黑名单；收窄片源会清掉不在范围内的洗版终点。
struct RuleSetEditorSheet: View {
    /// nil = 新建
    let ruleSet: API.RuleSetView?
    /// 新建时的预填（复制场景）；编辑时忽略
    var template: (name: String, spec: RuleSetSpec)?
    /// 保存成功，参数是后端返回的最新规则组（快捷新建场景据此选中它）
    let onSaved: (API.RuleSetView) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var original = RuleSetSpec()
    @State private var name = ""
    @State private var scope = RuleSetScope()
    @State private var routingOptions: LibraryRoutingOptions?
    @State private var resolutions: [String] = []
    @State private var mediaSources: [String] = []
    @State private var codecFamilies: Set<String> = []
    @State private var platformsAllow: [String] = []
    @State private var platformsBlock: [String] = []
    @State private var hdrLevels: [String] = []
    @State private var hdrBlock: [String] = []
    @State private var subLangs: [String] = []
    @State private var audioLangs: [String] = []
    @State private var freeOnly = false
    @State private var excludeHr = false
    @State private var hrStrict = false
    @State private var minSeeders = ""
    @State private var sizeMin = ""
    @State private var sizeMax = ""
    @State private var groupsAllow = ""
    @State private var groupsBlock = ""
    /// "" = 不洗版
    @State private var upgradeSource = ""
    @State private var upgradeKeepOld = false
    /// "" = 跟随分辨率偏好首位
    @State private var cutoffResolution = ""
    @State private var upgradeLadder = RuleSetVocabulary.defaultLadder
    @State private var ladderOpen = false
    @State private var ladderPreviewOpen = false
    @State private var openSections: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    // MARK: 派生

    /// 编码族之外的原有值（经 API 写入的自定义编码）：编辑时不丢
    private var codecExtras: [String] {
        original.videoCodecs.filter { value in !RuleSetVocabulary.codecFamilies.contains { $0.values.contains(value) } }
    }

    /// 常驻选项之外的既有平台值：编辑时不丢
    private var platformExtras: (allow: [String], block: [String]) {
        (original.platforms.filter { !RuleSetVocabulary.platformOptions.contains($0) },
         original.platformsBlock.filter { !RuleSetVocabulary.platformOptions.contains($0) })
    }

    private func ladderUnconfigured(_ dim: String) -> Bool {
        (dim == "hdr" && hdrLevels.isEmpty)
            || (dim == "video_codec" && codecFamilies.isEmpty && codecExtras.isEmpty)
            || (dim == "platform" && platformsAllow.isEmpty && platformExtras.allow.isEmpty)
    }

    /// 表单状态 → spec 的唯一构造点（保存与底部回执共用），校验错误随返回值给出
    private var draft: (spec: RuleSetSpec, error: String?) {
        func parseInt(_ text: String) -> Int? {
            guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
            return n
        }
        func parseGroups(_ text: String) -> [String] {
            text.components(separatedBy: CharacterSet(charactersIn: ",，、").union(.whitespacesAndNewlines)).filter { !$0.isEmpty }
        }
        var next = RuleSetSpec()
        next.resolutions = resolutions
        next.mediaSources = mediaSources
        next.videoCodecs = RuleSetVocabulary.codecFamilies.filter { codecFamilies.contains($0.label) }.flatMap(\.values) + codecExtras
        if !upgradeSource.isEmpty, upgradeLadder != RuleSetVocabulary.defaultLadder { next.upgradeLadder = upgradeLadder }
        next.platforms = platformsAllow + platformExtras.allow
        next.platformsBlock = platformsBlock + platformExtras.block
        next.hdrLevels = hdrLevels
        next.hdrBlock = hdrBlock
        next.subtitleLanguages = subLangs
        next.audioLanguages = audioLangs
        next.freeOnly = freeOnly
        next.excludeHr = excludeHr
        next.hrUnknownPolicy = excludeHr && hrStrict ? "strict" : nil
        if let seeders = parseInt(minSeeders), seeders > 0 { next.minSeeders = seeders }
        let min = parseInt(sizeMin), max = parseInt(sizeMax)
        if let min, min > 0 { next.sizeMinMb = min }
        if let max, max > 0 { next.sizeMaxMb = max }
        if let min, let max, min > 0, max > 0, min > max { return (next, String(localized: .subscriptionRulesSizeInvalid)) }
        next.releaseGroupsAllow = parseGroups(groupsAllow)
        next.releaseGroupsBlock = parseGroups(groupsBlock)
        if !upgradeSource.isEmpty {
            if !mediaSources.isEmpty, !mediaSources.contains(upgradeSource) {
                return (next, String(localized: .subscriptionRulesSourceInvalid))
            }
            next.upgradeSource = upgradeSource
            if !cutoffResolution.isEmpty, cutoffResolution != (resolutions.first ?? "") {
                if !resolutions.isEmpty, !resolutions.contains(cutoffResolution) {
                    return (next, String(localized: .subscriptionRulesResolutionInvalid))
                }
                next.cutoffResolution = cutoffResolution
            }
            next.upgradeKeepOld = upgradeKeepOld
        }
        next.sites = original.sites
        next.sitesBlock = original.sitesBlock
        return (next, nil)
    }

    private var validScope: RuleSetScope {
        var result = scope
        if let routingOptions {
            let allowed = Set(routingOptions.genres(for: scope.kind).map(\.id))
            result.genres = scope.genres.filter(allowed.contains)
        }
        return result
    }

    private var qualitySummary: String {
        let parts = [
            codecFamilies.isEmpty ? "" : RuleSetVocabulary.codecFamilies.map(\.label).filter(codecFamilies.contains).joined(separator: "/"),
            platformsAllow.isEmpty ? "" : platformsAllow.map(RuleSetVocabulary.platformLabel).joined(separator: "/"),
            platformsBlock.isEmpty ? "" : String(localized: .subscriptionRulesExcludeValues(platformsBlock.map(RuleSetVocabulary.platformLabel).joined(separator: "/"))),
            hdrLevels.isEmpty ? "" : RuleSetText.hdrChipText(hdrLevels),
            hdrBlock.isEmpty ? "" : String(localized: .subscriptionRulesExcludeValues(hdrBlock.joined(separator: "/"))),
            groupsAllow.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(localized: .subscriptionRulesGroupSummary(groupsAllow.trimmingCharacters(in: .whitespaces))),
            groupsBlock.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(localized: .subscriptionRulesBlockedGroupsSummary(groupsBlock.trimmingCharacters(in: .whitespaces))),
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: .subscriptionRulesUnset) : parts.joined(separator: " · ")
    }

    private var limitSummary: String {
        func labels(_ options: [(value: String, label: String)], _ values: [String]) -> String {
            values.map { v in options.first { $0.value == v }?.label ?? v }.joined(separator: "/")
        }
        let min = sizeMin.trimmingCharacters(in: .whitespaces), max = sizeMax.trimmingCharacters(in: .whitespaces)
        let parts = [
            subLangs.isEmpty ? "" : String(localized: .subscriptionRulesSubtitleSummary(labels(RuleSetVocabulary.subtitleLanguages, subLangs))),
            audioLangs.isEmpty ? "" : String(localized: .subscriptionRulesAudioSummary(labels(RuleSetVocabulary.audioLanguages, audioLangs))),
            freeOnly ? String(localized: .subscriptionRulesFreeOnly) : "",
            excludeHr ? String(localized: .subscriptionRulesExcludeHr) : "",
            minSeeders.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(localized: .subscriptionRulesSeedersChip(Int(minSeeders.trimmingCharacters(in: .whitespaces)) ?? 0)),
            min.isEmpty && max.isEmpty ? "" : max.isEmpty ? String(localized: .subscriptionRulesSizeUnbounded(min.isEmpty ? "0" : min))
                : String(localized: .subscriptionRulesSizeSummary(min.isEmpty ? "0" : min, max)),
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: .subscriptionRulesUnset) : parts.joined(separator: " · ")
    }

    // MARK: 视图

    var body: some View {
        let draft = draft
        let ladderPreview = UpgradeLadderPreview(draft.spec)
        let draftChips = RuleSetText.summary(draft.spec, withoutUpgrade: ladderPreview != nil)
        SubsSheetScaffold(
            title: ruleSet == nil ? String(localized: .subscriptionRulesCreate) : String(localized: .subscriptionRulesEdit),
            subtitle: String(localized: .subscriptionRulesEditorHint),
            confirm: SubsSheetConfirm(
                title: String(localized: .commonSave),
                enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                busy: busy,
                identifier: "ruleset-save"
            ) { Task { await submit() } }
        ) {
            // 保存失败的原因放最上面：确认键在右上角，放底部会被滚出视野
            if let error {
                Section { SubsNoticeRow(text: error, tone: .error) }
            }
            if let ruleSet, ruleSet.referenceCount > 0 {
                Section {
                    SubsNoticeRow(text: String(localized: .subscriptionRulesReferencesNotice(ruleSet.referenceCount)), tone: .warn)
                }
            }
            Section {
                TextField(String(localized: .subscriptionRulesNamePlaceholder), text: $name)
                    .accessibilityIdentifier("ruleset-name")
            } header: {
                Text(String(localized: .subscriptionRulesName))
            }

            collapsible(String(localized: .subscriptionRulesScope), key: "scope", summary: validScope.summary(routingOptions) ?? String(localized: .subscriptionRulesUnsetScope)) {
                Text(String(localized: .subscriptionRulesScopeHintText))
                    .font(.footnote).foregroundStyle(Theme.textMuted)
                field(String(localized: .subscriptionRulesKind)) {
                    chips {
                        ForEach([(String?.none, String(localized: .subscriptionRulesAny)), ("movie", String(localized: .subscriptionFilterMovie)), ("tv", String(localized: .subscriptionFilterTv))], id: \.1) { value, label in
                            SubsToggleChip(label: label, active: scope.kind == value) { scope.kind = value }
                        }
                    }
                }
                scopeEditor
            }

            fieldSection(String(localized: .subscriptionSmartResolution), hint: String(localized: .subscriptionRulesResolutionHint)) {
                chips {
                    ForEach(RuleSetVocabulary.resolutions, id: \.self) { option in
                        let index = resolutions.firstIndex(of: option)
                        SubsToggleChip(label: option, active: index != nil, order: index != nil && resolutions.count > 1 ? (index ?? 0) + 1 : nil) {
                            toggle(&resolutions, option)
                        }
                    }
                }
            }

            fieldSection(String(localized: .subscriptionSmartSource), hint: String(localized: .subscriptionRulesSourceHint)) {
                chips {
                    ForEach(RuleSetVocabulary.mediaSources, id: \.value) { option in
                        let index = mediaSources.firstIndex(of: option.value)
                        SubsToggleChip(label: option.label, active: index != nil, order: index != nil && mediaSources.count > 1 ? (index ?? 0) + 1 : nil) {
                            toggle(&mediaSources, option.value)
                            // 收窄白名单时洗版终点被排除在外，直接清掉终点
                            if !upgradeSource.isEmpty, !mediaSources.isEmpty, !mediaSources.contains(upgradeSource) { upgradeSource = "" }
                        }
                    }
                }
            }

            collapsible(String(localized: .subscriptionRulesQuality), key: "quality", summary: qualitySummary) {
                field(String(localized: .subscriptionRulesCodec), hint: String(localized: .subscriptionRulesCodecHint)) {
                    chips {
                        ForEach(RuleSetVocabulary.codecFamilies, id: \.label) { family in
                            SubsToggleChip(label: family.label, active: codecFamilies.contains(family.label)) {
                                if codecFamilies.contains(family.label) { codecFamilies.remove(family.label) } else { codecFamilies.insert(family.label) }
                            }
                        }
                    }
                    if !codecExtras.isEmpty {
                        Text(String(localized: .subscriptionRulesCustomValues(AppFormatting.list(codecExtras)))).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
                field(String(localized: .subscriptionRulesPlatform), hint: String(localized: .subscriptionRulesPlatformHint)) {
                    chips {
                        ForEach(RuleSetVocabulary.platformOptions, id: \.self) { id in
                            SubsTriChip(label: RuleSetVocabulary.platformLabel(id), state: triState(id, allow: platformsAllow, block: platformsBlock)) {
                                cycle(id, allow: &platformsAllow, block: &platformsBlock)
                            }
                        }
                    }
                    let extras = platformExtras.allow + platformExtras.block
                    if !extras.isEmpty {
                        Text(String(localized: .subscriptionRulesCustomValues(AppFormatting.list(extras.map(RuleSetVocabulary.platformLabel))))).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
                field("HDR", hint: String(localized: .subscriptionRulesHdrHint)) {
                    chips {
                        ForEach(RuleSetVocabulary.hdrOptions, id: \.self) { value in
                            SubsTriChip(label: value, state: triState(value, allow: hdrLevels, block: hdrBlock)) {
                                cycle(value, allow: &hdrLevels, block: &hdrBlock)
                            }
                        }
                        ForEach(RuleSetVocabulary.hdrBlockOnly, id: \.self) { value in
                            SubsTriChip(label: value, state: hdrBlock.contains(value) ? .exclude : .off) {
                                toggle(&hdrBlock, value)
                            }
                        }
                    }
                }
                field(String(localized: .subscriptionRulesGroupsAllow), hint: String(localized: .subscriptionRulesGroupsAllowHint)) {
                    textInput(String(localized: .subscriptionRulesBlankAny), text: $groupsAllow)
                }
                field(String(localized: .subscriptionRulesGroupsBlock), hint: String(localized: .subscriptionRulesGroupsBlockHint)) {
                    textInput(String(localized: .subscriptionRulesBlankDisabled), text: $groupsBlock)
                }
            }

            collapsible(String(localized: .subscriptionRulesLimits), key: "limits", summary: limitSummary) {
                field(String(localized: .subscriptionRulesSubtitleLanguage), hint: String(localized: .subscriptionRulesSubtitleHint)) {
                    chips {
                        ForEach(RuleSetVocabulary.subtitleLanguages, id: \.value) { option in
                            SubsToggleChip(label: option.label, active: subLangs.contains(option.value)) { toggle(&subLangs, option.value) }
                        }
                    }
                }
                field(String(localized: .subscriptionRulesAudioLanguage), hint: String(localized: .subscriptionRulesAudioHint)) {
                    chips {
                        ForEach(RuleSetVocabulary.audioLanguages, id: \.value) { option in
                            SubsToggleChip(label: option.label, active: audioLangs.contains(option.value)) { toggle(&audioLangs, option.value) }
                        }
                    }
                }
                SubsToggleRow(title: String(localized: .subscriptionRulesFree), hint: String(localized: .subscriptionRulesFreeHint), isOn: $freeOnly)
                SubsToggleRow(title: String(localized: .subscriptionRulesHr), hint: String(localized: .subscriptionRulesHrHint), isOn: $excludeHr)
                if excludeHr {
                    SubsToggleRow(title: String(localized: .subscriptionRulesHrStrictHint), isOn: $hrStrict)
                }
                numberField(String(localized: .subscriptionRulesSeeders), text: $minSeeders)
                numberField(String(localized: .subscriptionRulesMinSize), text: $sizeMin)
                numberField(String(localized: .subscriptionRulesMaxSize), text: $sizeMax)
                Text(String(localized: .subscriptionRulesSizeHint))
                    .font(.footnote).foregroundStyle(Theme.textMuted)
            }

            upgradeSection

            Section {
                Text(draftChips.isEmpty ? String(localized: .subscriptionRulesNoConditions) : draftChips.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Theme.text.opacity(0.85))
                    .accessibilityIdentifier("ruleset-draft-summary")
                if let ladderPreview { ladderPreviewView(ladderPreview) }
            } header: {
                Text(ladderPreview != nil ? String(localized: .subscriptionRulesFilterFirst) : String(localized: .subscriptionRulesFilterSummary))
            }
        }
        .interactiveDismissDisabled(busy)
        .accessibilityIdentifier("ruleset-editor")
        .task {
            guard !loaded else { return }
            loaded = true
            populate()
            routingOptions = try? await api.routingOptions()
        }
    }

    // MARK: 分段

    @ViewBuilder
    private var scopeEditor: some View {
        if let options = routingOptions {
            field(String(localized: .libraryFormMatchRegions)) {
                let known = Set(options.countryNames.keys)
                let countries = options.sortedCountries + scope.regions.filter { !known.contains($0) }.map { ($0, $0) }
                chips {
                    ForEach(countries, id: \.code) { country in
                        SubsToggleChip(label: country.name, active: scope.regions.contains(country.code)) { toggle(&scope.regions, country.code) }
                    }
                }
                chips {
                    Text(String(localized: .libraryFormRegionPresets)).font(.caption).foregroundStyle(Theme.textFaint)
                    let allCodes = Array(options.countryNames.keys)
                    let allOn = allCodes.allSatisfy(scope.regions.contains)
                    SubsToggleChip(label: allOn ? String(localized: .commonClear) : String(localized: .commonSelectAll), active: false) {
                        scope.regions = allOn ? [] : Array(Set(scope.regions + allCodes)).sorted()
                    }
                    ForEach(options.regionPresets) { preset in
                        let active = preset.countries.allSatisfy(scope.regions.contains)
                        SubsToggleChip(label: preset.label, active: active) {
                            if active {
                                scope.regions.removeAll { preset.countries.contains($0) }
                            } else {
                                for code in preset.countries where !scope.regions.contains(code) { scope.regions.append(code) }
                            }
                        }
                    }
                }
            }
            field(String(localized: .libraryFormMatchGenres)) {
                let genres = options.genres(for: scope.kind)
                let allOn = genres.allSatisfy { scope.genres.contains($0.id) }
                chips {
                    SubsToggleChip(label: allOn ? String(localized: .commonClear) : String(localized: .commonSelectAll), active: false) {
                        scope.genres = allOn ? [] : Array(Set(scope.genres + genres.map(\.id)))
                    }
                    ForEach(genres) { genre in
                        SubsToggleChip(label: genre.label, active: scope.genres.contains(genre.id)) {
                            if let i = scope.genres.firstIndex(of: genre.id) { scope.genres.remove(at: i) } else { scope.genres.append(genre.id) }
                        }
                    }
                }
            }
        } else {
            Text(String(localized: .libraryFormLoadingOptions)).font(.subheadline).foregroundStyle(Theme.textFaint)
        }
    }

    /// 洗版：档位芯片一行；开启后依次是目标分辨率、保留旧版本、洗版优先级（可展开），各占一行
    @ViewBuilder
    private var upgradeSection: some View {
        Section {
            chips {
                SubsToggleChip(label: String(localized: .subscriptionRulesUpgradeOff), active: upgradeSource.isEmpty) { upgradeSource = "" }
                ForEach(RuleSetVocabulary.upgradeOptions.filter { mediaSources.isEmpty || mediaSources.contains($0.value) }, id: \.value) { option in
                    SubsToggleChip(label: option.label, active: upgradeSource == option.value) { upgradeSource = option.value }
                }
            }
            if !upgradeSource.isEmpty {
                field(String(localized: .subscriptionRulesCutoff), hint: resolutions.isEmpty ? String(localized: .subscriptionRulesCutoffUnrestricted) : String(localized: .subscriptionRulesCutoffHint)) {
                    chips {
                        let effective = cutoffResolution.isEmpty ? (resolutions.first ?? "1080p") : cutoffResolution
                        ForEach(resolutions.isEmpty ? RuleSetVocabulary.resolutions : resolutions, id: \.self) { option in
                            SubsToggleChip(label: option, active: effective == option) {
                                cutoffResolution = option == (resolutions.first ?? "") ? "" : option
                            }
                        }
                    }
                }
                SubsToggleRow(title: String(localized: .subscriptionRulesKeepOld), hint: String(localized: .subscriptionRulesKeepOldHint), isOn: $upgradeKeepOld)
                Button {
                    withAnimation(.snappy) { ladderOpen.toggle() }
                } label: {
                    HStack {
                        Text(String(localized: .subscriptionRulesPriority)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(upgradeLadder.filter { !ladderUnconfigured($0) }.map { dim in RuleSetVocabulary.ladderOptions.first { $0.value == dim }?.label ?? dim }.joined(separator: " › "))
                            .font(.footnote).foregroundStyle(Theme.textMuted).lineLimit(1)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textFaint).rotationEffect(.degrees(ladderOpen ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if ladderOpen {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: .subscriptionRulesChooseOrder)).font(.footnote).foregroundStyle(Theme.textMuted)
                        chips {
                            ForEach(RuleSetVocabulary.ladderOptions, id: \.value) { dim in
                                let index = upgradeLadder.firstIndex(of: dim.value)
                                SubsToggleChip(
                                    label: dim.label,
                                    active: index != nil,
                                    order: index != nil && upgradeLadder.count > 1 ? (index ?? 0) + 1 : nil,
                                    suffix: index != nil && ladderUnconfigured(dim.value) ? String(localized: .subscriptionRulesUnconfigured) : nil
                                ) {
                                    // 最后一维不允许移除：空阶梯与界面口径不一致
                                    if let index {
                                        if upgradeLadder.count > 1 { upgradeLadder.remove(at: index) }
                                    } else {
                                        upgradeLadder.append(dim.value)
                                    }
                                }
                            }
                        }
                        Text(String(localized: .subscriptionRulesPriorityHintText))
                            .font(.footnote).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.vertical, 4)
                }
                let effective = upgradeLadder.filter { !ladderUnconfigured($0) }
                if let index = effective.firstIndex(of: "platform"), index < effective.count - 1 {
                    SubsNoticeRow(text: String(localized: .subscriptionRulesPlatformOrderWarning), tone: .warn)
                }
            }
        } header: {
            Text(String(localized: .subscriptionRulesUpgrade))
        } footer: {
            Text(String(localized: .subscriptionRulesUpgradeHint))
        }
    }

    /// 洗版阶梯预览：终点在上、过渡档降序排开；默认折叠只留一行终点
    private func ladderPreviewView(_ preview: UpgradeLadderPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { ladderPreviewOpen.toggle() }
            } label: {
                HStack {
                    (Text(String(localized: .subscriptionRulesUpgradeStepsLead)) + Text(preview.target).bold().foregroundStyle(.white)).foregroundStyle(Theme.textMuted).font(.subheadline)
                    Spacer()
                    Text(ladderPreviewOpen ? String(localized: .commonCollapse) : String(localized: .subscriptionRulesShowLadder)).font(.caption).foregroundStyle(Theme.textFaint)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textFaint).rotationEffect(.degrees(ladderPreviewOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if ladderPreviewOpen {
                Text(String(localized: .subscriptionRulesLadderOrder(preview.dimensions.joined(separator: " › ")))).font(.caption).foregroundStyle(Theme.textFaint)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(String(localized: .subscriptionRulesTarget)).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.accent2.opacity(0.25), in: .capsule)
                        Text(preview.target).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    }
                    // 分段拼好再交给 Text：一整串 + 与 map/?? 混写，Xcode 26 类型推断超时
                    let stopNote: String = preview.ceiling.map { String(localized: .subscriptionRulesTargetStopHigher($0)) } ?? String(localized: .subscriptionRulesTargetStopPlain)
                    let keepNote: String = upgradeKeepOld ? String(localized: .subscriptionRulesOldKept) : String(localized: .subscriptionRulesOldRecycled)
                    Text(AppFormatting.sentences([stopNote, keepNote]))
                        .font(.caption).foregroundStyle(Theme.textFaint)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent2.opacity(0.14), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent2.opacity(0.45)))
                if preview.below.isEmpty {
                    Text(String(localized: .subscriptionRulesLowestTarget)).font(.caption).foregroundStyle(Theme.textFaint)
                } else {
                    Text(String(localized: .subscriptionRulesBelowHint)).font(.caption).foregroundStyle(Theme.textFaint)
                    ForEach(preview.below, id: \.self) { label in
                        HStack(spacing: 8) {
                            Text("↑").foregroundStyle(Theme.textFaint)
                            Text(label).foregroundStyle(Theme.textMuted)
                        }
                        .font(.subheadline)
                    }
                    if preview.moreBelow > 0 {
                        Text("↑ " + String(localized: .subscriptionRulesMoreBelow(preview.moreBelow))).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
    }

    // MARK: 积木

    /// 字段行：小标题 + 内容 + 说明，在折叠分段里作为表单的一行
    private func field<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            content()
            if let hint { Text(hint).font(.footnote).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 4)
    }

    /// 独立字段：自成一组，标题作分组头、说明作脚注
    private func fieldSection<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            Text(label)
        } footer: {
            if let hint { Text(hint) }
        }
    }

    private func chips<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        DiscoverFlowLayout(spacing: 6, lineSpacing: 6) { content() }
    }

    /// 可折叠分段：一组表单行，首行是折叠头（直接显示当前摘要），展开后字段逐行排在下面
    private func collapsible<Content: View>(_ title: String, key: String, summary: String, @ViewBuilder content: () -> Content) -> some View {
        let open = openSections.contains(key)
        return Section {
            Button {
                withAnimation(.snappy) {
                    if open { openSections.remove(key) } else { openSections.insert(key) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(summary).font(.footnote).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textFaint).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ruleset-section-\(key)")
            if open { content() }
        }
    }

    private func textInput(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))
    }

    /// 数字行：左标题、右输入（原生设置页的「键 — 值」形态），留空 = 不限
    private func numberField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(String(localized: .subscriptionRulesAny), text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func toggle(_ list: inout [String], _ value: String) {
        if let index = list.firstIndex(of: value) { list.remove(at: index) } else { list.append(value) }
    }

    private func triState(_ value: String, allow: [String], block: [String]) -> SubsTriChip.Value {
        allow.contains(value) ? .include : block.contains(value) ? .exclude : .off
    }

    /// 三态循环：不限 → 只要 → 排除 → 不限（同一值不可能同时进白黑名单）
    private func cycle(_ value: String, allow: inout [String], block: inout [String]) {
        if allow.contains(value) {
            allow.removeAll { $0 == value }
            block.append(value)
        } else if block.contains(value) {
            block.removeAll { $0 == value }
        } else {
            allow.append(value)
        }
    }

    // MARK: 数据

    private func populate() {
        let spec = ruleSet?.typedSpec ?? template?.spec ?? RuleSetSpec()
        original = spec
        name = ruleSet?.name ?? template?.name ?? ""
        // 适用范围不随复制带过去：两个组范围一模一样时只有更早的那个会被选中
        scope = RuleSetScope(ruleSet?.matchRules ?? [])
        resolutions = spec.resolutions
        mediaSources = spec.mediaSources
        codecFamilies = Set(RuleSetVocabulary.codecFamilies.filter { $0.values.contains(where: spec.videoCodecs.contains) }.map(\.label))
        platformsAllow = spec.platforms.filter(RuleSetVocabulary.platformOptions.contains)
        platformsBlock = spec.platformsBlock.filter(RuleSetVocabulary.platformOptions.contains)
        let hdr = spec.effectiveHdr
        hdrLevels = hdr.levels
        hdrBlock = hdr.block
        subLangs = spec.subtitleLanguages
        audioLangs = spec.audioLanguages
        freeOnly = spec.freeOnly
        excludeHr = spec.excludeHr
        hrStrict = spec.hrUnknownPolicy == "strict"
        minSeeders = spec.minSeeders.map(String.init) ?? ""
        sizeMin = spec.sizeMinMb.map(String.init) ?? ""
        sizeMax = spec.sizeMaxMb.map(String.init) ?? ""
        groupsAllow = spec.releaseGroupsAllow.joined(separator: ", ")
        groupsBlock = spec.releaseGroupsBlock.joined(separator: ", ")
        upgradeSource = spec.upgradeSource ?? ""
        upgradeKeepOld = spec.upgradeKeepOld
        cutoffResolution = spec.cutoffResolution ?? ""
        upgradeLadder = spec.upgradeLadder ?? RuleSetVocabulary.defaultLadder
    }

    private func submit() async {
        let draft = draft
        if let message = draft.error {
            error = message
            return
        }
        busy = true
        error = nil
        let payload = API.RuleSetPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            spec: draft.spec.json,
            matchRules: validScope.rules
        )
        do {
            let saved = if let ruleSet {
                try await api.rulesUpdate(ruleSetId: ruleSet.id, body: payload)
            } else {
                try await api.rulesCreate(body: payload)
            }
            onSaved(saved)
            dismiss()
        } catch {
            self.error = error.localizedDescription.isEmpty ? String(localized: .subscriptionRulesSaveFailed) : error.localizedDescription
            busy = false
        }
    }
}
