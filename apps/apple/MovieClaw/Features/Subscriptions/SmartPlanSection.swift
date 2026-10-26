import SwiftUI

/// 订阅首屏的智能选择（对应 Web `components/smart-plan-card.tsx`）。
/// 摘要与整句文案都由服务端按设置、记忆和作品信息解析好（`PrepareView.smart`），这里只负责显示；
/// 管理员在这里回答第一次碰到的语言、改字幕回答、改画质，提交订阅时一并写入记忆。
struct SmartPlanSection: View {
    let plan: API.SmartPlanView?
    @Binding var choice: SmartChoice
    @State private var editingSubtitle = false

    var body: some View {
        Section {
            if let plan {
                if !plan.configured {
                    if plan.canEdit {
                        NavigationLink(value: SubscribeSheet.Page.smart) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: .subscriptionSmartTitle)).font(.subheadline).foregroundStyle(.secondary)
                                Text(String(localized: .subscriptionSmartSetupTitle)).font(.headline)
                                Text(String(localized: .subscriptionSmartSetupOnce)).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("smart-edit")
                    } else {
                        Text(String(localized: .subscriptionSmartAdminRequired))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("smart-needs-admin")
                    }
                } else {
                    if plan.canEdit {
                        NavigationLink(value: SubscribeSheet.Page.smart) { summary(plan) }
                            .accessibilityIdentifier("smart-edit")
                        NavigationLink(value: SubscribeSheet.Page.quality) {
                            LabeledContent(String(localized: .subscriptionSmartEditQuality)) {
                                if choice.qualityChanged(plan) {
                                    Text(choice.scope == "only" ? String(localized: .subscriptionSmartOnlyThis) : plan.scopeOptions.first { $0.value == choice.scope }?.label ?? "")
                                }
                            }
                        }.accessibilityIdentifier("smart-quality")
                    } else {
                        summary(plan)
                    }
                }
            } else {
                // 只在预检完成后渲染：没有摘要说明服务器早于 0.42.0
                Text(String(localized: .subscriptionSmartServerUnsupported))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("smart-unsupported")
            }
        }
        if let plan, plan.configured, let language = plan.subtitleLanguageLabel, let line = plan.subtitleLine {
            subtitleSection(plan, language: language, line: line)
        }
    }

    private func summary(_ plan: API.SmartPlanView) -> some View {
        let changed = choice.qualityChanged(plan)
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: .subscriptionSmartTitle)).font(.subheadline).foregroundStyle(.secondary)
            Text(changed ? String(localized: .subscriptionSmartPrefer(SmartLabels.quality(resolution: choice.resolution ?? plan.resolution, source: choice.source ?? plan.source))) : plan.qualityLabel ?? "")
                .font(.headline).accessibilityIdentifier("smart-quality-label")
            if !changed, let note = plan.qualityNote {
                Text(note).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("smart-quality-note")
            }
            if !changed, let shadow = plan.qualityShadow {
                Text(shadow).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("smart-quality-shadow")
            }
            if let wait = plan.waitLabel { Text(wait).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func subtitleSection(_ plan: API.SmartPlanView, language: String, line: String) -> some View {
        let answer = Binding<String>(
            mcGet: { choice.language ?? (plan.subtitleUnderstood == true ? "understood" : "subtitles") },
            set: { choice.language = $0 }
        )
        if plan.canEdit, plan.question != nil || editingSubtitle {
            let question = plan.question
            Section {
                Picker(question?.prompt ?? String(localized: .subscriptionSmartEditLanguageQuestion(language)), selection: answer) {
                    Text(question?.subtitlesLabel ?? (plan.subtitleUnderstood == true ? String(localized: .subscriptionSmartGenericRequireSubtitles) : line.replacingOccurrences(of: "\(language) · ", with: String(localized: .subscriptionSmartYesPrefix))))
                        .tag("subtitles")
                    Text(question?.understoodLabel ?? String(localized: .subscriptionSmartUnderstoodAnswer(language))).tag("understood")
                }
                .pickerStyle(.inline).labelsHidden()
                .accessibilityIdentifier("smart-language")
            } header: {
                Text(question?.prompt ?? String(localized: .subscriptionSmartEditLanguageQuestion(language))).accessibilityIdentifier("smart-language-prompt")
            }
        } else {
            Section {
                HStack {
                    Text(choice.language == "understood" ? String(localized: .subscriptionSmartUnderstoodLine(language)) : line)
                        .accessibilityIdentifier("smart-subtitle-line")
                    Spacer(minLength: 8)
                    if plan.canEdit {
                        Button(String(localized: .subscriptionSmartEditSubtitle)) { editingSubtitle = true }
                            .buttonStyle(.borderless).accessibilityLabel(String(localized: .subscriptionSmartEditSubtitleLabel))
                            .accessibilityIdentifier("smart-language-edit")
                    }
                }
            }
        }
    }
}

/// 改画质：只改这一部，或记成某类作品的习惯。范围选项来自这部作品本身（电影或剧集、地区、平台）。
struct SmartQualityPage: View {
    let plan: API.SmartPlanView
    @Binding var choice: SmartChoice

    var body: some View {
        let resolution = Binding<String>(mcGet: { choice.resolution ?? plan.resolution ?? "2160p" }, set: { choice.resolution = $0 })
        let source = Binding<String>(mcGet: { choice.source ?? plan.source ?? "web-dl" }, set: { choice.source = $0 })
        Form {
            Section {
                Picker(String(localized: .subscriptionSmartResolution), selection: resolution) {
                    Text("4K").tag("2160p"); Text("1080p").tag("1080p")
                }.pickerStyle(.segmented).accessibilityIdentifier("smart-quality-resolution")
                Picker(String(localized: .subscriptionSmartSource), selection: source) {
                    Text("WEB-DL").tag("web-dl"); Text(String(localized: .subscriptionSmartBluray)).tag("blu-ray"); Text("Remux").tag("remux")
                }.pickerStyle(.segmented).accessibilityIdentifier("smart-quality-source")
            } footer: {
                if let note = plan.qualityNote { Text(String(localized: .subscriptionSmartCurrentNote(note))) }
            }
            if choice.qualityChanged(plan) {
                Section {
                    Picker(String(localized: .subscriptionSmartRememberScope), selection: $choice.scope) {
                        ForEach(plan.scopeOptions, id: \.value) { option in Text(option.label).tag(option.value) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    .accessibilityIdentifier("smart-quality-scope")
                } header: {
                    Text(String(localized: .subscriptionSmartRememberScope))
                } footer: {
                    Text(String(localized: .subscriptionSmartScopeFooter))
                }
            }
        }
        .subsFormStyle()
        .navigationTitle(String(localized: .libraryFiltersQuality))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 智能设置（一套）：画质、洗版、最低要求共用，电影和剧集各一个等待上限；下面是它记住的东西。
struct SmartDefaultsEditor: View {
    let onSaved: () -> Void
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var defaults: API.SmartDefaultsView?
    @State private var draft: API.SmartDefaultsPayload?
    @State private var memory: API.SmartMemoryView?
    @State private var busy = false
    @State private var error: String?
    @State private var reloads = 0

    var body: some View {
        Form {
            if let error {
                Section {
                    SubsNoticeRow(text: error, tone: .error)
                    Button(String(localized: .subscriptionSmartReload)) {
                        Task {
                            await load()
                            // 订阅页的摘要也跟着刷新，取消回去看到的是最新设置
                            onSaved()
                        }
                    }.accessibilityIdentifier("smart-reload")
                }
            }
            if let draft = Binding($draft) {
                Section {
                    Picker(String(localized: .subscriptionSmartPreferredResolution), selection: draft.resolution) {
                        Text("4K").tag("2160p"); Text("1080p").tag("1080p")
                    }.accessibilityIdentifier("smart-resolution")
                    Picker(String(localized: .subscriptionSmartPreferredSource), selection: draft.source) {
                        Text("WEB-DL").tag("web-dl"); Text(String(localized: .subscriptionSmartBluray)).tag("blu-ray"); Text("Remux").tag("remux")
                    }.accessibilityIdentifier("smart-source")
                    // 选择器的状态在创建时取自草稿；重新读取设置后按新版本重建，显示的就是要保存的值
                    SmartWaitPicker(title: String(localized: .subscriptionSmartMovieWait), identifier: "smart-movie-wait", seconds: draft.movieWaitSeconds)
                        .id("movie-\(defaults?.movieRevision ?? 0)-\(reloads)")
                    SmartWaitPicker(title: String(localized: .subscriptionSmartTvWait), identifier: "smart-tv-wait", seconds: draft.tvWaitSeconds)
                        .id("tv-\(defaults?.tvRevision ?? 0)-\(reloads)")
                    Toggle(String(localized: .subscriptionSmartAllowUpgrade), isOn: Binding(mcGet: { draft.wrappedValue.allowUpgrade ?? true }, set: { draft.wrappedValue.allowUpgrade = $0 }))
                        .toggleStyle(SystemSwitchStyle()).accessibilityIdentifier("smart-upgrade")
                } footer: {
                    Text(defaults?.configured == true ? String(localized: .subscriptionSmartUpdateHint) : String(localized: .subscriptionSmartSetupHint))
                }
                Section(String(localized: .subscriptionSmartMinimum)) {
                    Toggle(String(localized: .subscriptionSmartOnlyResolution(draft.wrappedValue.resolution == "2160p" ? "4K" : "1080p")), isOn: Binding(mcGet: { draft.wrappedValue.strictResolution ?? false }, set: { draft.wrappedValue.strictResolution = $0 }))
                        .toggleStyle(SystemSwitchStyle()).accessibilityIdentifier("smart-strict-resolution")
                }
            } else if error == nil {
                Section { HStack { ProgressView(); Text(String(localized: .subscriptionSmartLoadingSettings)) } }
            }
            if let memory, defaults?.configured == true { memorySections(memory) }
        }
        .pickerStyle(.menu)
        .subsFormStyle()
        .disabled(busy)
        .navigationTitle(String(localized: .subscriptionSmartSettingsLabel))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: .commonCancel), systemImage: "xmark", role: .cancel) { dismiss() }
                    .disabled(busy).accessibilityIdentifier("smart-cancel-edit")
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy { ProgressView().accessibilityLabel(String(localized: .subscriptionSmartSavingLabel)) }
                else {
                    Button(String(localized: .commonSave), systemImage: "checkmark", role: .confirm) { Task { await save() } }
                        .discoverProminentButton().disabled(draft == nil).accessibilityIdentifier("smart-save")
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func memorySections(_ memory: API.SmartMemoryView) -> some View {
        Section {
            ForEach(memory.languages, id: \.key) { language in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.label)
                        Text(language.removable ? (language.sourceTitle.map { String(localized: .subscriptionSmartLanguageAddedFrom($0)) } ?? String(localized: .subscriptionSmartAddedInSettings)) : String(localized: .subscriptionSmartDefault))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if language.removable {
                        Button(String(localized: .subscriptionSmartRemove)) { Task { await change(.init(revision: memory.revision, language: language.key, understood: false)) } }
                            .buttonStyle(.borderless).accessibilityLabel(String(localized: .subscriptionSmartRemoveNamed(language.label)))
                            .accessibilityIdentifier("smart-language-remove-\(language.key)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("smart-language-\(language.key)")
            }
            if !memory.addableLanguages.isEmpty {
                Menu(String(localized: .subscriptionSmartAddLanguageMenu)) {
                    ForEach(memory.addableLanguages, id: \.key) { option in
                        Button(option.label) { Task { await change(.init(revision: memory.revision, language: option.key, understood: true)) } }
                    }
                }.accessibilityIdentifier("smart-language-add")
            }
        } header: {
            Text(String(localized: .subscriptionSmartUnderstoodLanguages))
        } footer: {
            Text(String(localized: .subscriptionSmartUnderstoodHint))
        }
        if !memory.habits.isEmpty {
            Section {
                ForEach(memory.habits, id: \.key) { habit in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(habit.label) · \(habit.qualityLabel)")
                            Text(habit.sourceTitle.map { String(localized: .subscriptionSmartHabitFrom($0)) } ?? String(localized: .subscriptionSmartLegacyTvSource))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: .subscriptionSmartRemove)) { Task { await change(.init(revision: memory.revision, removeHabit: habit.key)) } }
                            .buttonStyle(.borderless).accessibilityLabel(String(localized: .subscriptionSmartRemoveNamed(habit.label)))
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("smart-habit")
                }
            } header: {
                Text(String(localized: .subscriptionSmartQualityHabits))
            } footer: {
                Text(String(localized: .subscriptionSmartHabitsHint))
            }
        }
    }

    private func load() async {
        error = nil
        do {
            async let defaultsTask = api.subscriptionsGetSmartDefaults()
            async let memoryTask = api.subscriptionsGetSmartMemory()
            let (value, remembered) = try await (defaultsTask, memoryTask)
            defaults = value
            memory = remembered
            reloads += 1
            draft = .init(
                movieRevision: value.movieRevision, tvRevision: value.tvRevision,
                resolution: value.resolution, source: value.source,
                allowUpgrade: value.allowUpgrade, strictResolution: value.strictResolution,
                movieWaitSeconds: value.movieWaitSeconds, tvWaitSeconds: value.tvWaitSeconds
            )
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard let draft, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await api.subscriptionsSaveSmartDefaults(body: draft)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func change(_ patch: API.SmartMemoryPatch) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            memory = try await api.subscriptionsUpdateSmartMemory(body: patch)
            onSaved()
        } catch {
            self.error = error.localizedDescription
            memory = try? await api.subscriptionsGetSmartMemory()
        }
    }
}

/// 等待上限：预设三档、自定义 1–7 天；旧版本存下的整小时值原样保留为一档。
private struct SmartWaitPicker: View {
    let title: String
    let identifier: String
    @Binding var seconds: Int
    @State private var choice: String
    @State private var customDays: String
    @State private var legacy: Int?

    init(title: String, identifier: String, seconds: Binding<Int>) {
        self.title = title
        self.identifier = identifier
        _seconds = seconds
        let value = seconds.wrappedValue
        _choice = State(initialValue: ![0, 10800, 86400].contains(value) && value % 86400 == 0 ? "custom" : String(value))
        _customDays = State(initialValue: String(min(7, max(1, Int(ceil(Double(value) / 86400))))))
        _legacy = State(initialValue: ![0, 10800, 86400].contains(value) && value % 86400 != 0 ? value : nil)
    }

    var body: some View {
        Picker(title, selection: $choice) {
            Text(String(localized: .subscriptionSmartWaitNow)).tag("0")
            Text(String(localized: .subscriptionSmartWaitThreeHours)).tag("10800")
            Text(String(localized: .subscriptionSmartWaitOneDay)).tag("86400")
            Text(String(localized: .subscriptionSmartCustomWait)).tag("custom")
            if let legacy { Text(String(localized: .subscriptionSmartLegacyWait(legacy / 3600))).tag(String(legacy)) }
        }
        .accessibilityIdentifier(identifier)
        .onChange(of: choice) { _, value in
            if value == "custom" { seconds = (Int(customDays) ?? 1) * 86400 }
            else if let value = Int(value) { seconds = value }
        }
        if choice == "custom" {
            Stepper(value: Binding(mcGet: { Int(customDays) ?? 1 }, set: { customDays = String($0); seconds = $0 * 86400 }), in: 1...7) {
                LabeledContent(String(localized: .subscriptionSmartWaitLimit), value: String(localized: .libraryShareDays(Int(customDays) ?? 1)))
            }
            .accessibilityIdentifier("\(identifier)-days")
        }
    }
}
