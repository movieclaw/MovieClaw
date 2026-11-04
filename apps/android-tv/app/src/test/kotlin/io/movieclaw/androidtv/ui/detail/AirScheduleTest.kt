package io.movieclaw.androidtv.ui.detail

import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.core.model.generated.EpisodeArrivalView
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.model.generated.MediaBrief
import io.movieclaw.core.model.generated.PrepareView
import io.movieclaw.core.model.generated.SeasonAirScheduleView
import io.movieclaw.core.model.generated.SeasonOverview
import io.movieclaw.core.model.generated.SmartPlanView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/** 播出日历的口径（同 Apple 端 AirScheduleLogic、网页 lib/air-schedule.ts） */
class AirScheduleTest {
    /** 2026-11-05 是周四 */
    private val today = "2026-11-05"

    private fun date(offset: Int) = AirDate.parse(today)!!.plusDays(offset).iso

    private fun episode(number: Long, offset: Int?, owned: Boolean = false) =
        EpisodeView(episodeNumber = number, owned = owned, airDate = offset?.let(::date))

    private fun schedule(
        missing: List<Long> = emptyList(),
        subscription: Long? = null,
        weekdays: List<Long> = emptyList(),
        last: Int? = null,
        arrivals: List<EpisodeArrivalView> = emptyList(),
        region: String? = null,
    ) = SeasonAirScheduleView(
        today = today,
        region = region,
        weekdays = weekdays,
        lastAirDate = last?.let(::date),
        subscriptionId = subscription,
        missingEpisodes = missing,
        arrivals = arrivals,
    )

    @Test
    fun calendarDayArithmeticWithoutJavaTime() {
        val day = AirDate.parse("2026-11-05T00:00:00")!!
        assertEquals(11, day.month)
        assertEquals(5, day.day)
        assertEquals(3, day.weekday) // 周四
        assertEquals("2026-11-05", day.iso)
        assertEquals("2026-12-31", AirDate.parse("2026-12-30")!!.plusDays(1).iso)
        assertEquals("2027-01-01", AirDate.parse("2026-12-31")!!.plusDays(1).iso)
        assertEquals(0, AirDate.parse("2026-11-02")!!.weekday) // 周一
        assertEquals(6, AirDate.parse("2026-11-08")!!.weekday) // 周日
        assertNull(AirDate.parse(null))
        assertNull(AirDate.parse("not-a-date"))
    }

    @Test
    fun calendarDayRoundTripsAcrossYearsAndLeapDays() {
        assertEquals(0, AirDate.parse("1970-01-01")!!.epochDay)
        assertEquals(20_397, AirDate.parse("2025-11-05")!!.epochDay)
        assertEquals("2028-02-29", AirDate.parse("2028-02-28")!!.plusDays(1).iso)
        assertEquals("2028-03-01", AirDate.parse("2028-02-29")!!.plusDays(1).iso)
        assertEquals("2027-03-01", AirDate.parse("2027-02-28")!!.plusDays(1).iso)
        // 与系统日历逐日对照十年（1970 前后、跨世纪闰年的算法边界也在里面）
        val calendar = java.util.GregorianCalendar(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(1999, Calendar.DECEMBER, 25)
        }
        repeat(3_700) {
            val iso = "%04d-%02d-%02d".format(calendar.get(Calendar.YEAR), calendar.get(Calendar.MONTH) + 1, calendar.get(Calendar.DAY_OF_MONTH))
            val date = AirDate.parse(iso)!!
            assertEquals(iso, date.iso)
            assertEquals((calendar.timeInMillis / 86_400_000L).toInt(), date.epochDay)
            // Calendar 的星期从周日 = 1 起
            assertEquals((calendar.get(Calendar.DAY_OF_WEEK) + 5) % 7, date.weekday)
            calendar.add(Calendar.DAY_OF_MONTH, 1)
        }
    }

    @Test
    fun toneTellsUnairedFromMissing() {
        val subscribed = schedule(missing = listOf(7), subscription = 5)
        assertEquals(AirTone.Owned, AirSchedule.tone(episode(1, -3, owned = true), subscribed))
        assertEquals(AirTone.Missing, AirSchedule.tone(episode(7, -3), subscribed))
        assertEquals(AirTone.Absent, AirSchedule.tone(episode(8, -3), subscribed))
        assertEquals(AirTone.Today, AirSchedule.tone(episode(9, 0), subscribed))
        assertEquals(AirTone.TodayFree, AirSchedule.tone(episode(9, 0), schedule()))
        assertEquals(AirTone.Upcoming, AirSchedule.tone(episode(10, 2), subscribed))
        assertEquals(AirTone.Upcoming, AirSchedule.tone(episode(11, null), subscribed))

        assertTrue(AirSchedule.isUnaired(episode(9, 0), subscribed))
        assertTrue(AirSchedule.isUnaired(episode(10, 2), subscribed))
        assertFalse("库里有的不算", AirSchedule.isUnaired(episode(9, 0, owned = true), subscribed))
        assertFalse("真缺的不算", AirSchedule.isUnaired(episode(7, -3), subscribed))
        assertFalse("没有日历时库里没有的一律按缺集", AirSchedule.isUnaired(episode(10, 2), null))
        assertTrue(AirSchedule.airsToday(episode(9, 0), subscribed))
        assertFalse(AirSchedule.airsToday(episode(10, 2), subscribed))
    }

    @Test
    fun weekOffsetCountsFromMonday() {
        val thursday = AirDate.parse(today)!!
        assertEquals(0, AirSchedule.weekOffset(thursday, thursday))
        assertEquals(0, AirSchedule.weekOffset(thursday, thursday.plusDays(3))) // 周日还在本周
        assertEquals(1, AirSchedule.weekOffset(thursday, thursday.plusDays(4))) // 下周一
        assertEquals(2, AirSchedule.weekOffset(thursday, thursday.plusDays(11)))
        assertEquals(-1, AirSchedule.weekOffset(thursday, thursday.plusDays(-4)))
    }

    @Test
    fun cadenceReadsLikeASentence() {
        assertEquals("每天更新", AirSchedule.cadence((0L..6L).toList()))
        assertEquals("每周四更新", AirSchedule.cadence(listOf(3)))
        assertEquals("周一至周四更新", AirSchedule.cadence(listOf(0, 1, 2, 3)))
        assertEquals("周二、周五更新", AirSchedule.cadence(listOf(1, 4)))
        assertNull(AirSchedule.cadence(emptyList()))
    }

    @Test
    fun gapOnlyMarksSkippedUpdateDays() {
        val thursday = AirDate.parse(today)!!
        val weekly = listOf(3L)
        assertNull("周更的下一周不算停更", AirSchedule.gap(thursday, thursday.plusDays(7), weekly))
        assertEquals("停更 13 天", AirSchedule.gap(thursday, thursday.plusDays(14), weekly))
        val daily = (0L..6L).toList()
        assertNull(AirSchedule.gap(thursday, thursday.plusDays(1), daily))
        assertEquals("周五不更新", AirSchedule.gap(thursday, thursday.plusDays(2), daily))
        assertEquals("周五至周六不更新", AirSchedule.gap(thursday, thursday.plusDays(3), daily))
    }

    @Test
    fun rowsInsertGroupsAndGaps() {
        val weekly = listOf(3L, 4L)
        val episodes = listOf(episode(1, 0), episode(2, 1), episode(3, 7), episode(4, 14), episode(5, 28))
        val days = AirSchedule.days(episodes, schedule(weekdays = weekly))
        val rows = AirSchedule.rows(days, schedule(weekdays = weekly), grouped = true)
        val shape = rows.map {
            when (it) {
                is AirRow.Group -> AirSchedule.groupTitle(it.group)
                is AirRow.Gap -> "gap:${it.text}"
                is AirRow.Day -> AirSchedule.rangeLabel(it.day.episodes)
            }
        }
        assertEquals(
            listOf(
                "本周", "第 1 集", "第 2 集",
                "下周", "第 3 集",
                "之后", "gap:周五至周三不更新", "第 4 集",
                "gap:停更 13 天", "第 5 集",
            ),
            shape,
        )
        // 已播展开时不分组
        assertTrue(AirSchedule.rows(days, schedule(weekdays = weekly), grouped = false).none { it is AirRow.Group })
    }

    @Test
    fun statusAndDotFollowDayState() {
        val schedule = schedule(missing = listOf(7), subscription = 5, last = 2)
        fun day(vararg list: EpisodeView) = AirSchedule.days(list.toList(), schedule).single()
        assertEquals(AirDayStatus.Owned, AirSchedule.status(day(episode(1, -2, owned = true)), schedule))
        assertEquals(AirDot.Owned, AirSchedule.dot(day(episode(1, -2, owned = true)), schedule))
        assertEquals(AirDayStatus.Missing, AirSchedule.status(day(episode(7, -2)), schedule))
        assertEquals(AirDot.Missing, AirSchedule.dot(day(episode(7, -2)), schedule))
        assertEquals(AirDayStatus.Absent, AirSchedule.status(day(episode(8, -2)), schedule))
        assertEquals(AirDayStatus.Relative("明天"), AirSchedule.status(day(episode(9, 1)), schedule))
        assertEquals(AirDayStatus.Relative("2 天后"), AirSchedule.status(day(episode(10, 2)), schedule))
        assertEquals(AirDot.Finale, AirSchedule.dot(day(episode(10, 2)), schedule))
        assertEquals(AirDot.Upcoming, AirSchedule.dot(day(episode(9, 1)), schedule))
        assertEquals(AirDot.Today, AirSchedule.dot(day(episode(11, 0)), schedule))
    }

    @Test
    fun arrivalWalksTheSubscriptionStages() {
        val episodes = listOf(episode(13, 0))
        assertEquals("未订阅", AirSchedule.arrival(episodes, schedule())?.first)
        assertEquals("已入库，可以看了", AirSchedule.arrival(listOf(episode(13, 0, owned = true)), schedule(subscription = 5))?.first)
        fun stage(stage: String, expected: String? = null) = schedule(
            subscription = 5,
            arrivals = listOf(EpisodeArrivalView(13, stage, expected)),
        )
        assertEquals("整理中" to McColors.Info, AirSchedule.arrival(episodes, stage("organizing")))
        assertEquals("下载中" to McColors.Info, AirSchedule.arrival(episodes, stage("downloading")))
        assertEquals("等待资源" to McColors.TextMuted, AirSchedule.arrival(episodes, stage("waiting")))
        assertNull("订阅没在追这一集就不说", AirSchedule.arrival(episodes, schedule(subscription = 5)))
        val expected = "2026-11-05T12:30:00+00:00"
        assertTrue(AirSchedule.arrival(episodes, stage("waiting", expected))!!.first.startsWith("预计 "))
    }

    @Test
    fun expectedTimeIsLocalAndDropsTheDateToday() {
        val zone = TimeZone.getDefault()
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai"))
        try {
            val now = Calendar.getInstance().apply {
                clear()
                set(2026, Calendar.NOVEMBER, 5, 9, 0)
            }
            assertEquals("20:30", AirSchedule.expectedTime("2026-11-05T12:30:00+00:00", now))
            assertEquals("20:30", AirSchedule.expectedTime("2026-11-05T12:30:00.123456", now))
            assertEquals("20:30", AirSchedule.expectedTime("2026-11-05T12:30:00Z", now))
            assertEquals("20:30", AirSchedule.expectedTime("2026-11-05T20:30:00+08:00", now))
            assertEquals("11月6日 08:15", AirSchedule.expectedTime("2026-11-06T00:15:00+00:00", now))
            assertEquals("", AirSchedule.expectedTime("垃圾", now))
            assertTrue(AirSchedule.isToday("2026-11-05T12:30:00+00:00", now))
            assertFalse(AirSchedule.isToday("2026-11-06T00:15:00+00:00", now))
        } finally {
            TimeZone.setDefault(zone)
        }
    }

    @Test
    fun summaryForTodayAndForLaterDays() {
        val later = AirSummary(listOf(episode(5, 6)), schedule(weekdays = listOf(2), last = 6, region = "US"))
        assertEquals("周三", later.tag)
        assertEquals("第 5 集 大结局", later.headline)
        assertEquals("每周三更新 · 还剩 1 集 · 11月11日 完结", later.meta)
        assertEquals("6 天后", later.side?.value)
        assertEquals("11月11日（美国）", later.side?.caption)

        val today = AirSummary(
            listOf(episode(13, 0), episode(14, 0), episode(15, 1)),
            schedule(subscription = 5, arrivals = listOf(EpisodeArrivalView(13, "downloading"), EpisodeArrivalView(14, "waiting"))),
        )
        assertEquals("今天", today.tag)
        assertEquals("第 13–14 集更新", today.headline)
        assertEquals("还剩 1 集", today.meta)
        assertEquals("下载中", today.side?.value)
    }

    @Test
    fun pastSummaryFoldsAiredDays() {
        val schedule = schedule(missing = listOf(2), subscription = 5)
        val days = AirSchedule.days(listOf(episode(1, -3, owned = true), episode(2, -2), episode(3, -1, owned = true)), schedule)
        val summary = AirPastSummary(days, schedule)
        assertEquals("第 1–3 集", summary.range)
        assertEquals("已播出 · 11月2日–11月4日", summary.aired)
        assertEquals(listOf(2L), summary.missing)
        assertEquals(2, summary.owned)
        assertFalse(summary.allOwned)
        assertEquals("缺第 2 集", AirSchedule.missingText(summary.missing))
        assertEquals("缺 2 集", AirSchedule.missingText(listOf(2, 3)))
        assertEquals("补第 2 集", AirSchedule.findTitle(schedule))
        assertTrue(AirSchedule.canFind(schedule, canSubscribe = true))
        assertFalse(AirSchedule.canFind(schedule, canSubscribe = false))
    }

    @Test
    fun quickSubscribeUsesTheSameDefaultsAsThePhone() {
        val media = MediaBrief(mediaItemId = 1, kind = "tv", tmdbId = 42, title = "长街夜行", status = "Returning Series")
        val seasons = listOf(
            SeasonOverview(seasonNumber = 0, name = "特别篇", airedCount = 3),
            SeasonOverview(seasonNumber = 1, name = "第 1 季", airedCount = 10),
            SeasonOverview(seasonNumber = 2, name = "第 2 季", airedCount = 0),
        )
        val plan = SmartPlanView(configured = true, profileRevision = 3, memoryRevision = 9, canEdit = true, qualityLabel = "优先 4K WEB-DL")
        val draft = QuickSubscribe.of(PrepareView(status = "ready", media = media, seasons = seasons, smart = plan))!!
        assertEquals(listOf(1L), draft.seasons)
        assertTrue(draft.followFuture)
        assertEquals("第 1 季", draft.scope)
        assertEquals("自动追踪新集和新季", draft.scopeNote)
        assertEquals(listOf("优先 4K WEB-DL"), draft.quality)

        val payload = draft.payload(libraryId = 3)
        assertEquals("tmdb:tv:42", payload.titleRef)
        assertEquals(listOf(1L), payload.selectedSeasons)
        assertEquals(true, payload.followFuture)
        assertEquals(3L, payload.libraryId)
        assertEquals("smart", payload.selectionMode)
        assertEquals(3L, payload.smartProfileRevision)
        assertEquals(9L, payload.smartMemoryRevision)
        assertNull("没有问题时不回答", payload.smartLanguageAnswer)

        // 服务器不带智能摘要：按规则模式；成员不写记忆
        assertEquals("rules", QuickSubscribe.of(PrepareView(status = "ready", media = media, seasons = seasons))!!.payload(null).selectionMode)
        val member = QuickSubscribe.of(PrepareView(status = "ready", media = media, seasons = seasons, smart = plan.copy(canEdit = false)))!!.payload(null)
        assertNull(member.smartMemoryRevision)
        assertNull(member.libraryId)

        // 一季都还没播：只能从新集追起
        val first = QuickSubscribe.of(PrepareView(status = "ready", media = media.copy(status = "In Production"), seasons = listOf(seasons[2])))!!
        assertTrue(first.seasons.isEmpty())
        assertTrue(first.followFuture)
        assertEquals("仅追新集", first.scope)
        assertNull(QuickSubscribe.of(PrepareView(status = "not_found")))
    }
}
