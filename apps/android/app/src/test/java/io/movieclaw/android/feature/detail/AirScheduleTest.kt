package io.movieclaw.android.feature.detail

import io.movieclaw.android.core.model.EpisodeArrival
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.SeasonAirSchedule
import io.movieclaw.android.core.model.SeasonEpisodesView
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

/** 播出日历的纯逻辑（issue #547，与网页 test/air-schedule.test.mjs 同一组用例） */
class AirScheduleTest {

    private fun ep(n: Int, air: String?, owned: Boolean = false) = EpisodeView(episodeNumber = n, airDate = air, owned = owned)

    // 2026-10-28 是周三；周一至周四每天两集
    private val schedule = SeasonAirSchedule(
        today = "2026-10-28",
        weekdays = listOf(0, 1, 2, 3),
        lastAirDate = "2026-11-02",
        subscriptionId = 9,
        missingEpisodes = listOf(3),
        arrivals = listOf(EpisodeArrival(5, "waiting", "2026-10-28T12:00:00+00:00")),
    )
    private val episodes = listOf(
        ep(1, "2026-10-26", true), ep(2, "2026-10-26", true),
        ep(3, "2026-10-27"), ep(4, "2026-10-27", true),
        ep(5, "2026-10-28"), ep(6, "2026-10-28"),
        ep(7, "2026-10-29"), ep(8, "2026-11-02"), ep(9, null),
    )

    @Test fun `tone distinguishes missing from unaired`() {
        assertEquals(
            listOf("Owned", "Owned", "Missing", "Owned", "Today", "Today", "Upcoming", "Upcoming", "Upcoming"),
            episodes.map { AirSchedule.tone(it, schedule).name },
        )
        val free = schedule.copy(subscriptionId = null, missingEpisodes = emptyList())
        assertEquals(AirTone.Absent, AirSchedule.tone(ep(3, "2026-10-27"), free))
        assertEquals(AirTone.TodayFree, AirSchedule.tone(ep(5, "2026-10-28"), free))
    }

    @Test fun `week groups start on monday`() {
        // 2026-10-28 是周三，本周是 10-26（周一）到 11-01（周日）
        val d = { s: String -> LocalDate.parse(s) }
        assertEquals(
            listOf(0, 0, 0, 1, 2, -1),
            listOf("2026-10-26", "2026-10-28", "2026-11-01", "2026-11-02", "2026-11-09", "2026-10-25")
                .map { AirSchedule.weekOffset(d("2026-10-28"), d(it)) },
        )
        assertEquals(0, AirSchedule.weekOffset(d("2026-11-01"), d("2026-10-26")))
        assertEquals(0, AirSchedule.weekOffset(d("2026-10-26"), d("2026-11-01")))
        assertEquals(listOf("本周", "下周", "之后"), (0..2).map(AirSchedule::groupTitle))
    }

    @Test fun `counts days and next update`() {
        assertEquals(AirCounts(owned = 3, missing = 1, upcoming = 3), AirSchedule.counts(episodes, schedule))
        val days = AirSchedule.days(episodes, schedule)
        assertEquals(5, days.size)
        assertEquals(LocalDate.parse("2026-10-28"), days.first { !it.past }.date)
        assertEquals(true, days.first { !it.past }.today)
        assertEquals(true, days.last().finale)
        assertEquals("第 5–6 集", AirSchedule.rangeLabel(days.first { it.today }.episodes))
        assertEquals("第 7 集", AirSchedule.rangeLabel(listOf(ep(7, null))))
    }

    @Test fun `cadence and gaps`() {
        assertEquals("周一至周四更新", AirSchedule.cadence(listOf(0, 1, 2, 3)))
        assertEquals("每周四更新", AirSchedule.cadence(listOf(3)))
        assertEquals("每天更新", AirSchedule.cadence((0..6).toList()))
        assertEquals("周二、周五更新", AirSchedule.cadence(listOf(1, 4)))
        assertNull(AirSchedule.cadence(emptyList()))
        val d = { s: String -> LocalDate.parse(s) }
        // 只标跳过了更新日的真停更：周四 → 下周一跳过了周五至周日三个更新日
        assertEquals("周五至周日不更新", AirSchedule.gap(d("2026-10-29"), d("2026-11-02"), (0..6).toList()))
        assertEquals("周五不更新", AirSchedule.gap(d("2026-10-29"), d("2026-10-31"), (0..6).toList()))
        assertNull(AirSchedule.gap(d("2026-10-28"), d("2026-10-29"), listOf(2, 3)))
        // 周五、周六更新：周六 → 下周五中间是周日到周四，正常节奏
        assertNull(AirSchedule.gap(d("2026-10-31"), d("2026-11-06"), listOf(4, 5)))
        assertNull(AirSchedule.gap(d("2026-10-29"), d("2026-11-05"), listOf(3)))
        assertEquals("停更 13 天", AirSchedule.gap(d("2026-10-01"), d("2026-10-15"), listOf(3)))
    }

    @Test fun `arrival state of a day`() {
        val today = episodes.filter { it.airDate == "2026-10-28" }
        assertEquals("下载中", AirSchedule.arrival(today, schedule.copy(arrivals = listOf(EpisodeArrival(6, "downloading"))))?.first)
        assertEquals("已入库，可以看了", AirSchedule.arrival(listOf(ep(5, "2026-10-28", true)), schedule)?.first)
        assertEquals("未订阅", AirSchedule.arrival(today, schedule.copy(subscriptionId = null))?.first)
        assertNull(AirSchedule.arrival(today, schedule.copy(arrivals = emptyList())))
    }

    @Test fun `decodes air_schedule from the server and tolerates old servers`() {
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val view = json.decodeFromString<SeasonEpisodesView>(
            """{"season_number":1,"episodes":[],"air_schedule":{"today":"2026-10-28","region":"US","weekdays":[3],
            "last_air_date":null,"subscription_id":null,"missing_episodes":[],
            "arrivals":[{"episode_number":6,"stage":"waiting","expected_at":"2026-10-28T13:00:00+00:00"}]}}""",
        )
        assertEquals("US", view.airSchedule?.region)
        assertEquals(6, view.airSchedule?.arrivals?.single()?.episodeNumber)
        assertNull(json.decodeFromString<SeasonEpisodesView>("""{"season_number":1,"episodes":[]}""").airSchedule)
    }
}
