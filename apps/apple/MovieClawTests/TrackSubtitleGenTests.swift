import Foundation
import Testing
@testable import MovieClaw

/// issue #1337：失败任务被忽略后，详情页最新任务选择、徽标与点击入口均不得再指向旧失败。
struct TrackSubtitleGenTests {
    private func decodeJob(
        id: String,
        status: String,
        createdAt: String,
        updatedAt: String? = nil,
        dismissedAt: String? = nil
    ) -> API.JobView {
        let json: [String: Any] = [
            "id": id,
            "job_type": "subtitle.generate",
            "job_type_label": NSNull(),
            "subject": "S06E01.mkv",
            "definition_version": 1,
            "handler_revision": "subtitle.generate.v2",
            "status": status,
            "input_data": ["file_id": 5056, "target_language": "chs"],
            "result": NSNull(),
            "error": NSNull(),
            "usage": [:],
            "progress": ["mode": "determinate", "phase": "completed", "message": "", "details": [:]],
            "resources": [["resource_type": "library_file", "resource_id": "5056", "relation": "target"]],
            "origin": "cli",
            "attempt": 1,
            "max_attempts": 3,
            "revision": 2,
            "cancel_requested_by": NSNull(),
            "dismissed_at": dismissedAt ?? NSNull(),
            "created_at": createdAt,
            "updated_at": updatedAt ?? createdAt,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(API.JobView.self, from: data)
    }

    @Test func dismissedOlderFailureWithNewerUpdatedAtDoesNotBeatNewerSuccess() {
        let pollutedFailure = decodeJob(
            id: "job_fail",
            status: "failed",
            createdAt: "2026-11-25T15:47:00Z",
            updatedAt: "2026-11-25T17:25:09Z",
            dismissedAt: "2026-11-25T17:25:08Z"
        )
        let newerSuccess = decodeJob(
            id: "job_ok",
            status: "succeeded",
            createdAt: "2026-11-25T15:50:00Z",
            updatedAt: "2026-11-25T15:52:51Z"
        )

        let selected = TrackSubtitleGenLogic.latestJob(in: [newerSuccess, pollutedFailure])
        #expect(selected?.id == "job_ok")
        #expect(!TrackSubtitleGenLogic.showsTerminalIssue(selected, generated: false))
        #expect(!TrackSubtitleGenLogic.showsTerminalIssue(selected, generated: true))
        #expect(TrackSubtitleGenLogic.openMode(job: selected, generated: false) == .preview)
        #expect(TrackSubtitleGenLogic.openMode(job: selected, generated: true) == .preview)
    }

    @Test func onlyDismissedFailureReturnsIdleAndPreviewUntilUndismissed() {
        let dismissed = decodeJob(
            id: "job_fail_only",
            status: "failed",
            createdAt: "2026-11-25T15:47:00Z",
            updatedAt: "2026-11-25T17:25:09Z",
            dismissedAt: "2026-11-25T17:25:08Z"
        )
        #expect(TrackSubtitleGenLogic.latestJob(in: [dismissed]) == nil)
        #expect(!TrackSubtitleGenLogic.showsTerminalIssue(dismissed, generated: false))
        #expect(TrackSubtitleGenLogic.openMode(job: dismissed, generated: false) == .preview)

        let restored = decodeJob(
            id: "job_fail_only",
            status: "failed",
            createdAt: "2026-11-25T15:47:00Z",
            updatedAt: "2026-11-25T15:47:00Z",
            dismissedAt: nil
        )
        let selected = TrackSubtitleGenLogic.latestJob(in: [restored])
        #expect(selected?.id == "job_fail_only")
        #expect(TrackSubtitleGenLogic.showsTerminalIssue(selected, generated: false))
        #expect(TrackSubtitleGenLogic.openMode(job: selected, generated: false) == .status)
    }

    @Test func generatedSubtitleOpensPreviewInsteadOfStaleFailureStatus() {
        let failure = decodeJob(
            id: "job_fail",
            status: "failed",
            createdAt: "2026-11-25T15:47:00Z"
        )
        #expect(!TrackSubtitleGenLogic.showsTerminalIssue(failure, generated: true))
        #expect(TrackSubtitleGenLogic.openMode(job: failure, generated: true) == .preview)

        let running = decodeJob(
            id: "job_run",
            status: "running",
            createdAt: "2026-11-25T16:00:00Z"
        )
        #expect(TrackSubtitleGenLogic.openMode(job: running, generated: true) == .status)
    }

    @Test func activeJobWinsAndUndismissedOlderFailureStillLosesToNewerSuccess() {
        let restoredOldFailure = decodeJob(
            id: "job_fail_old",
            status: "failed",
            createdAt: "2026-11-25T15:47:00Z",
            updatedAt: "2026-11-25T17:30:00Z"
        )
        let newerSuccess = decodeJob(
            id: "job_ok_new",
            status: "succeeded",
            createdAt: "2026-11-25T15:50:00Z",
            updatedAt: "2026-11-25T15:52:51Z"
        )
        #expect(TrackSubtitleGenLogic.latestJob(in: [restoredOldFailure, newerSuccess])?.id == "job_ok_new")

        let running = decodeJob(
            id: "job_running",
            status: "running",
            createdAt: "2026-11-25T15:48:00Z"
        )
        #expect(TrackSubtitleGenLogic.latestJob(in: [restoredOldFailure, newerSuccess, running])?.id == "job_running")
    }
}
