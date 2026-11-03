package io.movieclaw.android.core.offline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 下载顺序（§5.5）：顺序就是优先级，优先下载 = 排到最前（与 iOS `OfflineQueueTests` 逐条对应） */
class OfflineQueueTest {
    private val t0 = 1_800_000_000_000L

    private fun unit(
        fileId: Long,
        state: OfflineUnit.State = OfflineUnit.State.queued,
        item: Long = 1,
        episode: Int = 0,
        addedSeconds: Long = 0,
        order: Double? = null,
        retryable: Boolean = true,
    ) = OfflineUnit(
        fileId = fileId, mediaItemId = item, season = if (episode == 0) 0 else 1, episode = episode, profile = "original",
        profileLabel = "原画", state = state, expectedBytes = 100, fileExtension = "mkv", createdAt = t0 + addedSeconds * 1000,
        retryable = retryable, queueOrder = order,
    )

    @Test
    fun addedOrderUntilReordered() {
        val queue = OfflineQueue.entries(listOf(unit(3, addedSeconds = 2), unit(1), unit(2, addedSeconds = 1), unit(4, OfflineUnit.State.done, addedSeconds = 3)))
        assertEquals("按加入时间；下完的不在队里", listOf(1L, 2L, 3L), queue.map { it.fileId })
    }

    /** 调过顺序的编号 0、1、2…，之后新加的按加入时间排在它们后面（加入时间按秒算，与 iOS 同一单位） */
    @Test
    fun numberedComeBeforeLaterAdditions() {
        val queue = OfflineQueue.entries(listOf(unit(1, order = 1.0), unit(2, addedSeconds = 1, order = 0.0), unit(3, addedSeconds = 5)))
        assertEquals(listOf(2L, 1L, 3L), queue.map { it.fileId })
    }

    /** 暂停的、要人处理的失败不算在前面；会自动重试的（含等转码）算 */
    @Test
    fun aheadCountsOnlyUnitsThatWillRun() {
        val queue = OfflineQueue.entries(
            listOf(
                unit(1, OfflineUnit.State.downloading),
                unit(2, OfflineUnit.State.paused, addedSeconds = 1),
                unit(3, OfflineUnit.State.failed, addedSeconds = 2, retryable = false),
                unit(4, OfflineUnit.State.failed, addedSeconds = 3),
                unit(5, addedSeconds = 4),
            ),
        )
        assertEquals(0, OfflineQueue.ahead(1, queue))
        assertEquals(2, OfflineQueue.ahead(5, queue))
        assertEquals("不在队里", 0, OfflineQueue.ahead(9, queue))
    }

    /** 正在下的排在下载中的最前：继续下载的那集排序在它前面、但不打断它，写「下一个下载」 */
    @Test
    fun downloadingIsListedFirst() {
        val queue = OfflineQueue.entries(listOf(unit(1), unit(2, OfflineUnit.State.downloading, addedSeconds = 1), unit(3, addedSeconds = 2)))
        assertEquals(listOf(2L, 1L, 3L), queue.map { it.fileId })
        assertEquals(1, OfflineQueue.ahead(1, queue))
        assertTrue("要它立刻开始，就得打断正在下的", OfflineQueue.canPrioritize(1, queue))
    }

    @Test
    fun prioritizeOfferedUnlessAlreadyFirst() {
        val queue = OfflineQueue.entries(listOf(unit(1, OfflineUnit.State.downloading), unit(2, addedSeconds = 1), unit(3, OfflineUnit.State.paused, addedSeconds = 2)))
        assertFalse("已经排在最前", OfflineQueue.canPrioritize(1, queue))
        assertTrue(OfflineQueue.canPrioritize(2, queue))
        assertTrue("暂停的也能优先（顺带继续）", OfflineQueue.canPrioritize(3, queue))
        assertFalse(OfflineQueue.canPrioritize(9, queue))
    }

    /** 整部剧插队：只有别的条目排在它某一集前面时才有意义 */
    @Test
    fun wholeShowOnlyWhenSomethingElseIsAhead() {
        val behind = OfflineQueue.entries(listOf(unit(1, item = 1), unit(2, item = 2, episode = 1, addedSeconds = 1), unit(3, item = 2, episode = 2, addedSeconds = 2)))
        assertTrue(OfflineQueue.canPrioritizeItem(2, behind))
        assertFalse("电影已经在最前", OfflineQueue.canPrioritizeItem(1, behind))
        val mixed = OfflineQueue.entries(listOf(unit(2, item = 2, episode = 1), unit(1, item = 1, addedSeconds = 1), unit(3, item = 2, episode = 2, addedSeconds = 2)))
        assertTrue("第 2 集排在电影后面", OfflineQueue.canPrioritizeItem(2, mixed))
        assertFalse("只有它一部", OfflineQueue.canPrioritizeItem(2, OfflineQueue.entries(listOf(unit(2, item = 2, episode = 1)))))
    }

    @Test
    fun newOrderPutsListedFirstAndKeepsTheRest() {
        val queue = OfflineQueue.entries((1L..5L).map { unit(it, addedSeconds = it) })
        assertEquals(listOf(4L, 1L, 2L, 3L, 5L), OfflineQueue.order(listOf(4L), queue))
        assertEquals("去重、不认队外的", listOf(5L, 3L, 1L, 2L, 4L), OfflineQueue.order(listOf(5L, 3L, 5L, 99L), queue))
    }

    @Test
    fun queuedStatusSaysHowManyAheadOrWaitingForWiFi() {
        val queued = unit(1)
        assertEquals("等待下载", OfflineUnitStatus.text(queued))
        assertEquals("下一个下载", OfflineUnitStatus.text(queued, ahead = 1))
        assertEquals("等待下载，前面还有 3 个", OfflineUnitStatus.text(queued, ahead = 3))
        assertEquals("分集卡上写短的", "前面还有 3 个", OfflineUnitStatus.short(queued, ahead = 3))
        assertEquals("只有排队的写排第几", "已暂停", OfflineUnitStatus.text(unit(2, OfflineUnit.State.paused), ahead = 3))
        assertEquals("等待 Wi-Fi", OfflineUnitStatus.text(unit(3, OfflineUnit.State.downloading), waitingForWiFi = true))
        assertEquals("暂停的不说在等 Wi-Fi", "已暂停", OfflineUnitStatus.text(unit(4, OfflineUnit.State.paused), waitingForWiFi = true))
    }

    /** 排序键写进存档；没有这个字段的旧存档照样读 */
    @Test
    fun orderSurvivesArchiveAndOldArchivesStillRead() {
        val json = OfflineDisk.json.encodeToString(OfflineUnit.serializer(), unit(1, order = 2.0))
        assertEquals(2.0, OfflineDisk.json.decodeFromString(OfflineUnit.serializer(), json).queueOrder)
        val legacy = json.replace(Regex(",?\"queueOrder\":2\\.0"), "")
        assertNull(OfflineDisk.json.decodeFromString(OfflineUnit.serializer(), legacy).queueOrder)
    }
}
