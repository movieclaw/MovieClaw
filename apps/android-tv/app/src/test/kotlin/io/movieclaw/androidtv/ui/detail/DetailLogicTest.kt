package io.movieclaw.androidtv.ui.detail

import io.movieclaw.androidtv.core.model.generated.ActorView
import io.movieclaw.androidtv.core.model.generated.AudioStreamView
import io.movieclaw.androidtv.core.model.generated.DirectorView
import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.core.model.generated.LibraryFileView
import io.movieclaw.androidtv.core.model.generated.LibraryItemDetailView
import io.movieclaw.androidtv.core.model.generated.LocalMetaView
import io.movieclaw.androidtv.core.model.generated.PersonCreditView
import io.movieclaw.androidtv.core.model.generated.PersonView
import io.movieclaw.androidtv.ui.stage.StageBadge
import io.movieclaw.androidtv.ui.stage.episodeLine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DetailLogicTest {
    private fun file(
        resolution: String? = null,
        hdr: String? = null,
        audio: List<AudioStreamView>? = null,
        state: String = "in_place",
        season: Long = 0,
        duration: Long? = null,
    ) = LibraryFileView(resolution = resolution, hdr = hdr, audioStreams = audio, state = state, seasonNumber = season, durationSeconds = duration)

    private fun movie(vararg files: LibraryFileView, meta: LocalMetaView? = null, year: Long? = 2023) =
        LibraryItemDetailView(kind = "movie", title = "片", year = year, files = files.toList(), localMeta = meta)

    // ---- 主按钮 ----

    @Test
    fun mainButtonLabel() {
        assertEquals("继续 46:56", DetailLogic.mainButtonLabel(true, (46 * 60 + 56) * 1000L, false, null))
        assertEquals("继续 第 1 季第 5 集 · 7:48", DetailLogic.mainButtonLabel(true, (7 * 60 + 48) * 1000L, false, "第 1 季第 5 集"))
        assertEquals("继续 1:02:03", DetailLogic.mainButtonLabel(true, 3723_000L, true, null))
        assertEquals("播放 第 1 季第 1 集", DetailLogic.mainButtonLabel(true, 0, false, "第 1 季第 1 集"))
        assertEquals("重新播放", DetailLogic.mainButtonLabel(true, 0, true, null))
        assertEquals("重新播放 第 2 季第 3 集", DetailLogic.mainButtonLabel(true, 0, true, "第 2 季第 3 集"))
        assertEquals("播放", DetailLogic.mainButtonLabel(true, 0, false, null))
        // 不能播时有进度也不写「继续」
        assertEquals("播放", DetailLogic.mainButtonLabel(false, 5000, false, null))
    }

    @Test
    fun unitLabel() {
        assertEquals("第 1 季第 3 集", DetailLogic.unitLabel(1, 3))
        assertEquals("特别篇第 2 集", DetailLogic.unitLabel(0, 2))
        assertNull(DetailLogic.unitLabel(null, 2))
        assertNull(DetailLogic.unitLabel(1, null))
    }

    // ---- 信息行 ----

    @Test
    fun metaLineMovieUsesRuntimeOrFileDuration() {
        val meta = LocalMetaView(genres = listOf("古装", "喜剧", "爱情"), runtimeMinutes = 118)
        assertEquals("2023 · 古装 · 喜剧 · 1 小时 58 分钟", DetailLogic.metaLine(movie(meta = meta)))
        // 没有 NFO 片长：用第一个有时长的文件四舍五入成分钟
        assertEquals("2023 · 45 分钟", DetailLogic.metaLine(movie(file(), file(duration = 2690))))
        assertEquals("2023 · 2 小时", DetailLogic.metaLine(movie(meta = LocalMetaView(runtimeMinutes = 120))))
        assertEquals("", DetailLogic.metaLine(movie(year = null)))
    }

    @Test
    fun metaLineTvCountsRealSeasons() {
        val tv = LibraryItemDetailView(kind = "tv", year = 2020, seasons = listOf(0, 1, 2), localMeta = LocalMetaView(genres = listOf("剧情"), runtimeMinutes = 40))
        assertEquals("2020 · 剧情 · 共 2 季", DetailLogic.metaLine(tv))
        assertEquals("2020", DetailLogic.metaLine(tv.copy(seasons = listOf(0, 1), localMeta = null)))
    }

    // ---- 片源标签 ----

    @Test
    fun resolutionBadges() {
        assertEquals(listOf(StageBadge("8K", true)), DetailLogic.mediaBadges(movie(file("8k"))))
        assertEquals(listOf(StageBadge("4K", true)), DetailLogic.mediaBadges(movie(file("1080p"), file("2160p"))))
        assertEquals(listOf(StageBadge("4K", true)), DetailLogic.mediaBadges(movie(file("UHD"))))
        assertEquals(listOf(StageBadge("HD", true)), DetailLogic.mediaBadges(movie(file("720p"))))
        assertEquals(emptyList<StageBadge>(), DetailLogic.mediaBadges(movie(file("480p"))))
        // 不在位的文件不算
        assertEquals(listOf(StageBadge("HD", true)), DetailLogic.mediaBadges(movie(file("1080p"), file("2160p", state = "missing"))))
        assertEquals(1440, DetailLogic.resolutionHeight("2k"))
        assertEquals(1080, DetailLogic.resolutionHeight(" 1080P "))
        assertNull(DetailLogic.resolutionHeight("sd"))
    }

    @Test
    fun hdrBadgePicksBest() {
        assertEquals(StageBadge("DOLBY VISION", false), DetailLogic.mediaBadges(movie(file(hdr = "HDR10"), file(hdr = "Dolby Vision"))).single())
        assertEquals(StageBadge("HDR10+", false), DetailLogic.mediaBadges(movie(file(hdr = "HLG"), file(hdr = "HDR10+"))).single())
        assertEquals(StageBadge("HDR10", false), DetailLogic.mediaBadges(movie(file(hdr = "HDR10"), file(hdr = "HDR"))).single())
        assertEquals(StageBadge("HLG", false), DetailLogic.mediaBadges(movie(file(hdr = "HLG"))).single())
        assertEquals(StageBadge("HDR", false), DetailLogic.mediaBadges(movie(file(hdr = "HDR"))).single())
    }

    @Test
    fun audioBadgePriority() {
        fun audio(vararg streams: AudioStreamView) = DetailLogic.mediaBadges(movie(file(audio = streams.toList()))).single()
        assertEquals(StageBadge("DOLBY ATMOS", false), audio(AudioStreamView(codec = "truehd", profile = "TrueHD + Atmos", channels = 8)))
        assertEquals(StageBadge("DOLBY ATMOS", false), audio(AudioStreamView(codec = "eac3", title = "Dolby Atmos 5.1"), AudioStreamView(codec = "dts", profile = "DTS:X")))
        assertEquals(StageBadge("DTS:X", false), audio(AudioStreamView(codec = "dts", profile = "DTS-X", channels = 8)))
        assertEquals(StageBadge("7.1", false), audio(AudioStreamView(codec = "aac", channels = 2), AudioStreamView(codec = "dts", profile = "DTS-HD MA", channels = 8)))
        assertEquals(StageBadge("5.1", false), audio(AudioStreamView(codec = "ac3", channels = 6)))
        assertEquals(emptyList<StageBadge>(), DetailLogic.mediaBadges(movie(file(audio = listOf(AudioStreamView(codec = "aac", channels = 2))))))
    }

    @Test
    fun badgesOrderResolutionHdrAudio() {
        val badges = DetailLogic.mediaBadges(movie(file("2160p", "Dolby Vision", listOf(AudioStreamView(profile = "TrueHD Atmos", channels = 8)))))
        assertEquals(listOf("4K", "DOLBY VISION", "DOLBY ATMOS"), badges.map { it.text })
        assertEquals(listOf(true, false, false), badges.map { it.filled })
    }

    // ---- 季与集 ----

    private fun tv(seasons: List<Long>, ownedSeasons: List<Long>) = LibraryItemDetailView(
        kind = "tv",
        seasons = seasons,
        files = ownedSeasons.map { file(season = it) } + file(season = 9, state = "missing"),
    )

    @Test
    fun startingSeason() {
        // 「接下来继续」的那一季优先（得是这部剧有的季）
        assertEquals(3L, DetailLogic.startingSeason(tv(listOf(1, 2, 3), listOf(1)), 3))
        assertEquals(1L, DetailLogic.startingSeason(tv(listOf(1, 2, 3), listOf(1)), 7))
        // 第一个有片源的正季（综艺只收了最新一季）
        assertEquals(10L, DetailLogic.startingSeason(tv(listOf(0, 1, 10), listOf(0, 10)), null))
        // 只有特别篇有片源
        assertEquals(0L, DetailLogic.startingSeason(tv(listOf(0, 1, 2), listOf(0)), null))
        // 一季都没有片源：第一个正季
        assertEquals(1L, DetailLogic.startingSeason(tv(listOf(0, 1, 2), emptyList()), null))
        assertEquals(0L, DetailLogic.startingSeason(tv(listOf(0), emptyList()), null))
        // 缺失（missing）的文件不算有片源
        assertEquals(1L, DetailLogic.startingSeason(tv(listOf(1, 9), emptyList()), null))
        assertNull(DetailLogic.startingSeason(tv(emptyList(), emptyList()), null))
    }

    private fun ep(n: Long, owned: Boolean = true, position: Long = 0, played: Boolean = false) =
        EpisodeView(episodeNumber = n, owned = owned, positionMs = position, played = played)

    @Test
    fun resumeEpisode() {
        assertEquals(3L, DetailLogic.resumeEpisode(listOf(ep(1, played = true), ep(2), ep(3, position = 1000), ep(4, owned = false, position = 5)))?.episodeNumber)
        assertEquals(2L, DetailLogic.resumeEpisode(listOf(ep(1, played = true), ep(2), ep(3)))?.episodeNumber)
        assertEquals(2L, DetailLogic.resumeEpisode(listOf(ep(1, owned = false), ep(2, played = true), ep(3, played = true)))?.episodeNumber)
        assertEquals(1L, DetailLogic.resumeEpisode(listOf(ep(1, owned = false), ep(2, owned = false)))?.episodeNumber)
        assertNull(DetailLogic.resumeEpisode(emptyList()))
    }

    @Test
    fun chooseEpisodePrefersRequested() {
        val list = listOf(ep(1, played = true), ep(2), ep(6))
        assertEquals(6L, DetailLogic.chooseEpisode(list, 6)?.episodeNumber)
        assertEquals(2L, DetailLogic.chooseEpisode(list, 9)?.episodeNumber)
        assertEquals(2L, DetailLogic.chooseEpisode(list, null)?.episodeNumber)
    }

    @Test
    fun canPlayAndNote() {
        val tvItem = tv(listOf(1), listOf(1))
        assertEquals(true, DetailLogic.canPlay(tvItem, ep(1)))
        assertEquals(false, DetailLogic.canPlay(tvItem, ep(1, owned = false)))
        assertEquals(false, DetailLogic.canPlay(tvItem, null))
        assertEquals(true, DetailLogic.canPlay(movie(file()), null))
        assertEquals(false, DetailLogic.canPlay(movie(file(state = "trashed")), null))
        assertEquals("这部剧还没有可播放的分集", DetailLogic.noteLine(tv(emptyList(), emptyList()), false, emptyList()))
        assertEquals("这一集还没有片源，往下挑别的集", DetailLogic.noteLine(tvItem, false, listOf(ep(1, owned = false))))
        assertNull(DetailLogic.noteLine(tvItem, false, listOf(ep(1, owned = false), ep(2))))
        assertNull(DetailLogic.noteLine(tvItem, true, emptyList()))
        assertNull(DetailLogic.noteLine(movie(), false, emptyList()))
    }

    @Test
    fun episodeLineDropsGenericNames() {
        assertEquals("第 2 季 第 6 集 · 归来", episodeLine(2, 6, "归来"))
        assertEquals("第 2 季 第 6 集", episodeLine(2, 6, "第 6 集"))
        assertEquals("第 2 季 第 6 集", episodeLine(2, 6, "episode 6"))
        assertEquals("第 2 季 第 6 集", episodeLine(2, 6, "  "))
        assertEquals("第 1 季 第 1 集", episodeLine(1, 1, null))
    }

    @Test
    fun episodeBand() {
        assertEquals("看到 7:48", DetailLogic.episodeBandText(ep(1, position = 468_000), 45))
        assertEquals("45 分钟", DetailLogic.episodeBandText(ep(1), 45))
        assertNull(DetailLogic.episodeBandText(ep(1), null))
        assertNull(DetailLogic.episodeBandText(ep(1), 0))
    }

    // ---- 演职员与版式 ----

    @Test
    fun castAndCredits() {
        val meta = LocalMetaView(
            directors = listOf("诺兰"),
            directorCredits = listOf(DirectorView("克里斯托弗·诺兰", "d.jpg", 525)),
            actors = listOf(ActorView("莱昂纳多", "柯布", "a.jpg", 6193), ActorView("约瑟夫", null, null, null), ActorView("艾伦", "阿德里安")),
        )
        val item = movie(meta = meta)
        val people = DetailLogic.castPeople(item)
        assertEquals(CastPerson("克里斯托弗·诺兰", "导演", "d.jpg", 525), people[0])
        assertEquals(CastPerson("莱昂纳多", "饰 柯布", "a.jpg", 6193), people[1])
        assertEquals(CastPerson("约瑟夫", null, null, null), people[2])
        assertEquals("克里斯托弗·诺兰" to listOf("莱昂纳多", "约瑟夫"), DetailLogic.stageCredits(item))
        // 没有结构化导演：退回姓名（去重），没有影人 id
        val names = movie(meta = LocalMetaView(directors = listOf("甲", "甲", "乙")))
        assertEquals(listOf(CastPerson("甲", "导演", null, null), CastPerson("乙", "导演", null, null)), DetailLogic.castPeople(names))
        assertEquals("甲" to emptyList<String>(), DetailLogic.stageCredits(names))
        assertEquals(emptyList<CastPerson>(), DetailLogic.castPeople(movie()))
    }

    @Test
    fun lowerGeometry() {
        assertEquals(82, DetailLogic.lowerGap(isMovie = false, hasSeries = false))
        assertEquals(20, DetailLogic.lowerGap(isMovie = true, hasSeries = true))
        assertEquals(164, DetailLogic.lowerGap(isMovie = true, hasSeries = false))
        assertEquals(330, DetailLogic.lowerScreenTop(true))
        assertEquals(250, DetailLogic.lowerScreenTop(false))
        assertEquals("特别篇", DetailLogic.seasonLabel(0))
        assertEquals("第 3 季", DetailLogic.seasonLabel(3))
    }

    @Test
    fun scrollSpecs() {
        // 已在留边之内：不动；越过右边：右沿对齐到可见区 - 边距；越过左边：左沿对齐到边距
        assertEquals(0f, minimalScroll(100f, 200f, 1000f, 80f))
        assertEquals(80f, minimalScroll(800f, 200f, 1000f, 80f))
        assertEquals(-60f, minimalScroll(20f, 200f, 1000f, 80f))
        var zone = DetailZone.Stage
        var scroll = 300f
        val spec = DetailSnapSpec({ zone }, { scroll }, { 2000f }, { 670f }, 30f)
        assertEquals(-300f, spec.calculateScrollDistance(0f, 100f, 1080f))
        zone = DetailZone.Top
        assertEquals(370f, spec.calculateScrollDistance(900f, 100f, 1080f))
        zone = DetailZone.Below
        scroll = 670f
        // 下面的行露全即可，但不高于下半截的顶
        assertEquals(50f, spec.calculateScrollDistance(1000f, 100f, 1080f))
        assertEquals(0f, spec.calculateScrollDistance(-200f, 100f, 1080f))
    }
}

class PersonLogicTest {
    private fun credit(id: Long, department: String = "cast", kind: String = "movie", year: Long? = 2010, character: String? = null, library: Long? = 1, title: String = "盗梦空间") =
        PersonCreditView(mediaItemId = id, kind = kind, title = title, year = year, department = department, character = character, libraryId = library)

    @Test
    fun focusDetail() {
        assertEquals("饰 柯布 · 2010", PersonLogic.focusDetail(credit(1, character = "柯布")))
        assertEquals("导演 · 2010", PersonLogic.focusDetail(credit(1, "director")))
        assertEquals("主创 · 2010", PersonLogic.focusDetail(credit(1, "director", kind = "tv")))
        assertEquals("2010", PersonLogic.focusDetail(credit(1, character = "")))
        assertEquals("饰 柯布 · 2010 · 片源已移除", PersonLogic.focusDetail(credit(1, character = "柯布", library = null)))
        assertEquals("片源已移除", PersonLogic.focusDetail(credit(1, year = null, library = null)))
        // 什么都没有又能点：写片名
        assertEquals("盗梦空间", PersonLogic.focusDetail(credit(1, year = null)))
    }

    @Test
    fun sectionsAndSummary() {
        val actorOnly = PersonView(credits = listOf(credit(1), credit(2)))
        assertEquals(listOf("参演"), PersonLogic.sections(actorOnly).map { it.title })
        assertEquals("库内 2 部", PersonLogic.summary(actorOnly))
        val both = PersonView(credits = listOf(credit(1), credit(2), credit(2, "director"), credit(3, "director")))
        assertEquals(listOf("参演", "执导"), PersonLogic.sections(both).map { it.title })
        assertEquals("库内 3 部 · 参演 2 · 执导 2", PersonLogic.summary(both))
        assertEquals("库内 0 部", PersonLogic.summary(PersonView()))
    }
}
