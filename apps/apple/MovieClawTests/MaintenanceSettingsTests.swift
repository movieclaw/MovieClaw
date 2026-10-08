import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct MaintenanceSettingsTests {
    private func task(seconds: Int = 7200, cron: String? = nil) -> API.ScheduledTaskView {
        .init(key: "test", title: "任务", description: "", enabled: true,
              triggerType: cron == nil ? "interval" : "cron", intervalSeconds: cron == nil ? seconds : nil, cronExpr: cron)
    }

    @Test func togglingEnabledPreservesExactInterval() {
        for seconds in [90, 1200, 7200] {
            var draft = TaskScheduleDraft(task(seconds: seconds))
            #expect(!draft.dirty)
            draft.enabled = false
            #expect(draft.dirty)
            #expect(draft.payload.intervalSeconds == seconds)
            #expect(draft.payload.enabled == false)
        }
    }

    @Test func changingIntervalOrModeProducesMatchingPayload() {
        var draft = TaskScheduleDraft(task())
        draft.hours = 4
        #expect(draft.payload.intervalSeconds == 14400)
        draft.mode = .daily
        draft.time = Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: .now)!
        #expect(draft.payload.cronExpr == "30 6 * * *")
        #expect(draft.payload.intervalSeconds == nil)
    }

    @Test func preservesCustomScheduleUntilEdited() {
        var draft = TaskScheduleDraft(task(cron: "*/15 8-20 * * 1-5"))
        #expect(draft.mode == .cron)
        #expect(!draft.dirty)
        draft.enabled = false
        #expect(draft.payload.cronExpr == "*/15 8-20 * * 1-5")
        #expect(SettingsSchedule.dailyTime("30 25 * * *") == nil)
    }
}
