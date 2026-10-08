import SwiftUI

/// 更新与维护 →「定时任务」（Web scheduled-tasks-section.tsx + lib/scheduled-tasks.ts）。
///
/// 每个后台任务的周期与启停：给两种人能说清的形状——「每 N 小时」「每天固定时刻」，
/// 其它 cron 照样能显示与保存（改表达式）。启停与周期都在独立抽屉里编辑，点「保存」才落库（`PUT /scheduled-tasks/{key}`）。
/// 「媒体库对账」多一条建议：有库在网络挂载上且周期比一小时长时，提示调到每 1 小时（只建议，不替用户改）。
struct ScheduledTasksPanel: View {
    @Environment(\.api) private var api

    @State private var tasks: [API.ScheduledTaskView]?
    @State private var anyNetwork = false
    @State private var error: String?
    @State private var busyKey: String?
    @State private var selected: API.ScheduledTaskView?

    var body: some View {
        List {
            SettingsFormSection {
                if let error {
                    SettingsNotice(text: error)
                    Button("重试") { Task { await load() } }
                }
                if let reconcile = tasks?.first(where: { $0.key == "library_reconcile" }),
                   SettingsSchedule.suggestReconcile(reconcile, anyNetwork: anyNetwork) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("有媒体库放在网络挂载上：实时监控收不到远端变化，新文件全靠「媒体库对账」发现。现在是\(SettingsSchedule.describe(reconcile))，建议调到每 1 小时——增量对账通常只需几秒。")
                            .font(.subheadline)
                        Button("调到每 1 小时") {
                            Task { error = await save(reconcile, .init(enabled: true, triggerType: "interval", intervalSeconds: 3600, cronExpr: nil)) }
                        }
                        .buttonStyle(.glass).controlSize(.small)
                        .disabled(busyKey == reconcile.key)
                    }
                }
                if tasks == nil, error == nil {
                    SettingsLoadingRow(text: "正在加载…")
                }
            }
            SettingsFormSection {
                ForEach(tasks ?? [], id: \.key) { task in
                    Button { selected = task } label: {
                        HStack(spacing: 12) {
                            Image(systemName: task.enabled ? "clock" : "pause.circle")
                                .foregroundStyle(task.enabled ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).foregroundStyle(.primary)
                                Text(task.enabled ? SettingsSchedule.describe(task) : "已暂停")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }.accessibilityIdentifier("task-row-\(task.key)")
                }
            } footer: { Text("点选任务调整周期。保存后在服务器生效，无需重启。") }
        }
        .task { await load() }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                TaskEditor(task: selected) { body in
                    await save(selected, body)
                }
            }
        }
    }

    private func load() async {
        do {
            async let rows = api.appTasksList()
            async let libs = try? api.libraryList(scope: "all")
            tasks = try await rows
            anyNetwork = (await libs ?? []).contains(where: \.networkMount)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ task: API.ScheduledTaskView, _ body: API.ScheduledTaskUpdate) async -> String? {
        busyKey = task.key
        defer { busyKey = nil }
        do {
            let updated = try await api.appTasksUpdate(taskKey: task.key, body: body)
            tasks = tasks?.map { $0.key == task.key ? updated : $0 }
            error = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - 周期形状（Web lib/scheduled-tasks.ts）

enum SettingsSchedule {
    /// 「分 时 * * *」形状的 cron → 每天固定时刻；其它形状返回 nil
    static func dailyTime(_ cron: String?) -> (hour: Int, minute: Int)? {
        guard let cron else { return nil }
        let parts = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5, parts[2] == "*", parts[3] == "*", parts[4] == "*" else { return nil }
        guard parts[0].count <= 2, parts[1].count <= 2, let minute = Int(parts[0]), let hour = Int(parts[1]),
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber),
              hour <= 23, minute <= 59 else { return nil }
        return (hour, minute)
    }

    static func dailyCron(hour: Int, minute: Int) -> String { "\(minute) \(hour) * * *" }

    static func describe(_ task: API.ScheduledTaskView) -> String {
        if task.triggerType == "interval" {
            let seconds = task.intervalSeconds ?? 0
            if seconds <= 0 { return "间隔未设置" }
            if seconds % 3600 == 0 { return "每 \(seconds / 3600) 小时" }
            if seconds % 60 == 0 { return "每 \(seconds / 60) 分钟" }
            return "每 \(seconds) 秒"
        }
        if let daily = dailyTime(task.cronExpr) {
            return String(format: "每天 %02d:%02d", daily.hour, daily.minute)
        }
        return task.cronExpr.map { "cron：\($0)" } ?? "未设置"
    }

    /// 固定时刻 = 一天一次，比一小时长；间隔超过一小时也建议
    static func suggestReconcile(_ task: API.ScheduledTaskView, anyNetwork: Bool) -> Bool {
        guard anyNetwork else { return false }
        if task.triggerType != "interval" { return true }
        return (task.intervalSeconds ?? 0) > 3600
    }
}

// MARK: - 单个任务

struct TaskScheduleDraft {
    enum Mode: String { case interval, daily, cron }
    let original: API.ScheduledTaskView
    var enabled: Bool
    var mode: Mode
    var hours: Int
    var time: Date
    var cron: String

    init(_ task: API.ScheduledTaskView) {
        original = task
        enabled = task.enabled
        mode = task.triggerType == "interval" ? .interval : SettingsSchedule.dailyTime(task.cronExpr) != nil ? .daily : .cron
        hours = max(1, Int((Double(task.intervalSeconds ?? 3600) / 3600).rounded()))
        let daily = SettingsSchedule.dailyTime(task.cronExpr) ?? (3, 0)
        time = Calendar.current.date(bySettingHour: daily.hour, minute: daily.minute, second: 0, of: .now) ?? .now
        cron = task.cronExpr ?? ""
    }

    var payload: API.ScheduledTaskUpdate {
        switch mode {
        case .interval:
            // 仅切换启停时保留服务器的精确间隔，不把分钟/秒级周期四舍五入成小时。
            let originalHours = max(1, Int((Double(original.intervalSeconds ?? 3600) / 3600).rounded()))
            let seconds = original.triggerType == "interval" && hours == originalHours ? original.intervalSeconds : hours * 3600
            return .init(enabled: enabled, triggerType: "interval", intervalSeconds: seconds, cronExpr: nil)
        case .daily:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .init(enabled: enabled, triggerType: "cron", intervalSeconds: nil,
                         cronExpr: SettingsSchedule.dailyCron(hour: parts.hour ?? 3, minute: parts.minute ?? 0))
        case .cron:
            return .init(enabled: enabled, triggerType: "cron", intervalSeconds: nil,
                         cronExpr: cron.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var dirty: Bool {
        let value = payload
        return value.enabled != original.enabled || value.triggerType != original.triggerType
            || (value.triggerType == "interval" ? value.intervalSeconds != original.intervalSeconds : value.cronExpr != original.cronExpr)
    }
}

private struct TaskEditor: View {
    let task: API.ScheduledTaskView
    let onSave: (API.ScheduledTaskUpdate) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskScheduleDraft
    @State private var busy = false
    @State private var error: String?
    @State private var discarding = false

    init(task: API.ScheduledTaskView, onSave: @escaping (API.ScheduledTaskUpdate) async -> String?) {
        self.task = task
        self.onSave = onSave
        _draft = State(initialValue: TaskScheduleDraft(task))
    }

    var body: some View {
        SubsSheetScaffold(title: task.title, onClose: {
            if draft.dirty { discarding = true } else { dismiss() }
        }, confirm: SubsSheetConfirm(title: "保存", enabled: draft.dirty && (draft.mode != .cron || !draft.cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                     busy: busy, identifier: "task-save-\(task.key)") {
            Task {
                busy = true
                error = await onSave(draft.payload)
                busy = false
                if error == nil { dismiss() }
            }
        }) {
            SettingsFormSection {
                Toggle("启用任务", isOn: $draft.enabled).accessibilityIdentifier("task-enabled-\(task.key)")
                Picker("运行方式", selection: $draft.mode) {
                    Text("每隔一段时间").tag(TaskScheduleDraft.Mode.interval)
                    Text("每天固定时刻").tag(TaskScheduleDraft.Mode.daily)
                    Text("自定义周期").tag(TaskScheduleDraft.Mode.cron)
                }.pickerStyle(.menu).accessibilityIdentifier("task-mode-\(task.key)")
                switch draft.mode {
                case .interval:
                    Stepper(value: $draft.hours, in: 1 ... 168) {
                        LabeledContent("间隔", value: draft.payload.intervalSeconds == draft.hours * 3600 ? "\(draft.hours) 小时" : SettingsSchedule.describe(task))
                    }.accessibilityIdentifier("task-hours-\(task.key)")
                case .daily:
                    DatePicker("运行时间", selection: $draft.time, displayedComponents: .hourAndMinute)
                case .cron:
                    TextField("分 时 日 月 周", text: $draft.cron)
                        .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: { Text(task.description) }
            SettingsFormSection {
                LabeledContent("上次运行", value: task.lastRunAt.map(Formatters.relative) ?? "尚未运行")
                if task.enabled, let next = task.nextRunAt { LabeledContent("下次运行", value: Formatters.dateTime(next)) }
            }
            if let error { SettingsFormSection { Text(error).foregroundStyle(Theme.danger) } }
        }
        .disabled(busy)
        .interactiveDismissDisabled(busy || draft.dirty)
        .alert("放弃未保存的修改？", isPresented: $discarding) {
            Button("继续编辑", role: .cancel) { }
            Button("放弃修改", role: .destructive) { dismiss() }
        }
    }
}
