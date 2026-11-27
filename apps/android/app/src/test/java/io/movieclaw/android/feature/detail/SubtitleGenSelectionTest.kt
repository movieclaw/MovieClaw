package io.movieclaw.android.feature.detail

import io.movieclaw.android.core.model.JobView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** issue #1337：失败任务被忽略后，详情页最新任务选择、徽标与点击入口均不得再指向旧失败。 */
class SubtitleGenSelectionTest {
    private fun job(
        id: String,
        status: String,
        createdAt: String,
        updatedAt: String = createdAt,
        dismissedAt: String? = null,
    ) = JobView(
        id = id,
        jobType = "subtitle.generate",
        status = status,
        createdAt = createdAt,
        updatedAt = updatedAt,
        dismissedAt = dismissedAt,
    )

    @Test
    fun dismissedOlderFailureWithNewerUpdatedAtDoesNotBeatNewerSuccess() {
        val pollutedFailure = job(
            id = "job_fail",
            status = "failed",
            createdAt = "2026-11-25T15:47:00+00:00",
            updatedAt = "2026-11-25T17:25:09Z",
            dismissedAt = "2026-11-25T17:25:08Z",
        )
        val newerSuccess = job(
            id = "job_ok",
            status = "succeeded",
            createdAt = "2026-11-25T15:50:00Z",
            updatedAt = "2026-11-25T15:52:51+00:00",
        )

        val selected = selectLatestSubtitleJob(listOf(newerSuccess, pollutedFailure))
        assertEquals("job_ok", selected?.id)
        assertFalse(subtitleJobShowsTerminalIssue(selected, generated = false))
        assertFalse(subtitleJobShowsTerminalIssue(selected, generated = true))
        assertEquals(SubtitleGenMode.PREVIEW, subtitleGenOpenMode(selected, generated = false))
        assertEquals(SubtitleGenMode.PREVIEW, subtitleGenOpenMode(selected, generated = true))
    }

    @Test
    fun onlyDismissedFailureReturnsNullUntilUndismissed() {
        val dismissed = job(
            id = "job_fail_only",
            status = "failed",
            createdAt = "2026-11-25T15:47:00Z",
            updatedAt = "2026-11-25T17:25:09Z",
            dismissedAt = "2026-11-25T17:25:08Z",
        )
        assertNull(selectLatestSubtitleJob(listOf(dismissed)))
        assertFalse(subtitleJobShowsTerminalIssue(dismissed, generated = false))
        assertEquals(SubtitleGenMode.PREVIEW, subtitleGenOpenMode(dismissed, generated = false))

        val restored = dismissed.copy(dismissedAt = null)
        val selected = selectLatestSubtitleJob(listOf(restored))
        assertEquals("job_fail_only", selected?.id)
        assertTrue(subtitleJobShowsTerminalIssue(selected, generated = false))
        assertEquals(SubtitleGenMode.STATUS, subtitleGenOpenMode(selected, generated = false))
    }

    @Test
    fun generatedSubtitleHidesIssueAndOpensPreview() {
        val failure = job(
            id = "job_fail",
            status = "failed",
            createdAt = "2026-11-25T15:47:00Z",
        )
        assertFalse(subtitleJobShowsTerminalIssue(failure, generated = true))
        assertEquals(SubtitleGenMode.PREVIEW, subtitleGenOpenMode(failure, generated = true))

        val running = job(
            id = "job_run",
            status = "running",
            createdAt = "2026-11-25T16:00:00Z",
        )
        assertEquals(SubtitleGenMode.STATUS, subtitleGenOpenMode(running, generated = true))
    }

    @Test
    fun activeJobWinsAndRestoredOlderFailureStillLosesToNewerSuccess() {
        val restoredOldFailure = job(
            id = "job_fail_old",
            status = "failed",
            createdAt = "2026-11-25T15:47:00Z",
            updatedAt = "2026-11-25T17:30:00Z",
        )
        val newerSuccess = job(
            id = "job_ok_new",
            status = "succeeded",
            createdAt = "2026-11-25T15:50:00Z",
            updatedAt = "2026-11-25T15:52:51Z",
        )
        assertEquals("job_ok_new", selectLatestSubtitleJob(listOf(restoredOldFailure, newerSuccess))?.id)

        val running = job(
            id = "job_running",
            status = "running",
            createdAt = "2026-11-25T15:48:00Z",
        )
        assertEquals(
            "job_running",
            selectLatestSubtitleJob(listOf(restoredOldFailure, newerSuccess, running))?.id,
        )
    }
}
