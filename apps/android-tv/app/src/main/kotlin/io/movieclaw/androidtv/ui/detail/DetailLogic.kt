package io.movieclaw.androidtv.ui.detail

import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.core.model.generated.LibraryItemDetailView
import io.movieclaw.androidtv.core.model.generated.PersonCreditView
import io.movieclaw.androidtv.core.model.generated.PersonView
import io.movieclaw.androidtv.ui.stage.StageBadge
import io.movieclaw.androidtv.ui.theme.Formatters
import kotlin.math.roundToLong

/** 演职员一格：姓名、身份（导演 / 饰 X）、头像、TMDB 影人 id（没有就进不了影人页） */
data class CastPerson(val name: String, val role: String?, val avatar: String?, val personId: Long?)

/**
 * 详情页的纯逻辑（TVItemDetailView.swift 里的派生计算），单独放这里方便单测。
 */
object DetailLogic {
    /** 「2160p」「4k」「1080」→ 画面高度 */
    fun resolutionHeight(raw: String): Int? = when (val normalized = raw.trim().lowercase()) {
        "8k" -> 4320
        "4k", "uhd" -> 2160
        "2k" -> 1440
        else -> normalized.filter(Char::isDigit).toIntOrNull()
    }

    private val hdrPriority = listOf("Dolby Vision", "HDR10+", "HDR10", "HLG", "HDR")

    /**
     * 画质、HDR、音频小标签：在位文件里各挑最好的一档。
     * 分辨率 8K / 4K / HD；HDR 杜比视界 > HDR10+ > HDR10 > HLG > HDR；音频杜比全景声 > DTS:X > 7.1 > 5.1
     */
    fun mediaBadges(detail: LibraryItemDetailView): List<StageBadge> {
        val sources = detail.files.filter { it.state == "in_place" }
        val badges = mutableListOf<StageBadge>()
        sources.mapNotNull { it.resolution?.let(::resolutionHeight) }.maxOrNull()?.let { best ->
            when {
                best >= 4320 -> badges += StageBadge("8K", true)
                best >= 2160 -> badges += StageBadge("4K", true)
                best >= 720 -> badges += StageBadge("HD", true)
            }
        }
        sources.mapNotNull { it.hdr }
            .minByOrNull { hdr -> hdrPriority.indexOf(hdr).let { if (it < 0) 99 else it } }
            ?.let { badges += StageBadge(if (it == "Dolby Vision") "DOLBY VISION" else it.uppercase(), false) }
        val audio = sources.flatMap { it.audioStreams.orEmpty() }
        val described = audio.map { listOfNotNull(it.profile, it.title, it.codec).joinToString(" ").lowercase() }
        val channels = audio.mapNotNull { it.channels }.maxOrNull()
        when {
            described.any { "atmos" in it } -> badges += StageBadge("DOLBY ATMOS", false)
            described.any { "dts:x" in it || "dts-x" in it } -> badges += StageBadge("DTS:X", false)
            channels != null && channels >= 6 -> badges += StageBadge(if (channels >= 8) "7.1" else "5.1", false)
        }
        return badges
    }

    /** 片名下第一行：年份 · 类型（前两个） · 电影写片长、剧集两季以上写「共 N 季」；不放评分 */
    fun metaLine(detail: LibraryItemDetailView): String {
        val meta = detail.localMeta
        val facts = mutableListOf<String>()
        detail.year?.let { facts += it.toString() }
        facts += meta?.genres.orEmpty().take(2)
        if (detail.kind != "tv") {
            val runtime = meta?.runtimeMinutes
                ?: detail.files.firstOrNull { it.durationSeconds != null }?.durationSeconds?.let { (it / 60.0).roundToLong() }
            if (runtime != null && runtime > 0) facts += Formatters.runtime(runtime.toInt())
        } else {
            val seasons = detail.seasons.count { it > 0 }
            if (seasons >= 2) facts += "共 $seasons 季"
        }
        return facts.joinToString(" · ")
    }

    /** 主按钮上的「第 1 季第 3 集」；特别篇（第 0 季）写「特别篇第 2 集」；电影没有 */
    fun unitLabel(season: Long?, episode: Long?): String? {
        if (season == null || episode == null) return null
        return if (season == 0L) "特别篇第 $episode 集" else "第 $season 季第 $episode 集"
    }

    /**
     * 主按钮文字：「继续 第 1 季第 5 集 · 7:48」「继续 46:56」「播放 第 1 季第 1 集」「重新播放」「播放」。
     * 有续播点（且能播）就「继续」，看完了是「重新播放」，否则「播放」。
     */
    fun mainButtonLabel(canPlay: Boolean, positionMs: Long, played: Boolean, unit: String?): String {
        val resumable = canPlay && positionMs > 0
        val verb = if (resumable) "继续" else if (played) "重新播放" else "播放"
        val parts = listOfNotNull(verb, unit, if (resumable) Formatters.clock(positionMs / 1000.0) else null)
        return if (parts.size > 2) "${parts[0]} ${parts[1]} · ${parts[2]}" else parts.joinToString(" ")
    }

    /**
     * 剧集打开时首屏讲哪一季：「接下来继续」里的那一季 → 第一个有片源的正季 → 任一有片源的季 → 第一个正季 → 第一季
     */
    fun startingSeason(detail: LibraryItemDetailView, upNextSeason: Long?): Long? {
        val owned = detail.files.filter { it.state == "in_place" }.map { it.seasonNumber }.toSet()
        return upNextSeason?.takeIf { it in detail.seasons }
            ?: detail.seasons.firstOrNull { it > 0 && it in owned }
            ?: detail.seasons.firstOrNull { it in owned }
            ?: detail.seasons.firstOrNull { it > 0 }
            ?: detail.seasons.firstOrNull()
    }

    /** 一季里「接着看的那一集」：看了一半的 → 第一集没看过的 → 第一集有片源的 → 第一集 */
    fun resumeEpisode(episodes: List<EpisodeView>): EpisodeView? {
        val owned = episodes.filter { it.owned }
        return owned.firstOrNull { it.positionMs > 0 }
            ?: owned.firstOrNull { !it.played }
            ?: owned.firstOrNull()
            ?: episodes.firstOrNull()
    }

    /** 首屏讲哪一集：指定的那一集（「接下来继续」给的 / 刚播的）→ 接着看的那一集（服务端给的锚点 [resume] 优先） */
    fun chooseEpisode(episodes: List<EpisodeView>, preferred: Long?, resume: Long? = null): EpisodeView? =
        preferred?.let { number -> episodes.firstOrNull { it.episodeNumber == number } } ?: EpisodeRanges.anchor(episodes, resume)

    /** 能不能播：电影看有没有在位文件，剧集看首屏这一集有没有片源 */
    fun canPlay(detail: LibraryItemDetailView, selectedEpisode: EpisodeView?): Boolean =
        if (detail.kind != "tv") detail.files.any { it.state == "in_place" } else selectedEpisode?.owned == true

    /** 按钮上方的提示：剧集、这一集不能播，且一季都没有或这一季全缺 */
    fun noteLine(detail: LibraryItemDetailView, canPlay: Boolean, episodes: List<EpisodeView>): String? {
        if (canPlay || detail.kind != "tv") return null
        if (detail.seasons.isEmpty()) return "这部剧还没有可播放的分集"
        return if (episodes.all { !it.owned }) "这一集还没有片源，往下挑别的集" else null
    }

    /** 首屏右下角的导演（结构化的优先，没有退回姓名）与前两位主演 */
    fun stageCredits(detail: LibraryItemDetailView): Pair<String?, List<String>> {
        val meta = detail.localMeta ?: return null to emptyList()
        val directors = meta.directorCredits.map { it.name }.ifEmpty { meta.directors }
        return directors.firstOrNull() to meta.actors.take(2).map { it.name }
    }

    /** 演职员：导演在前（结构化的优先，没有退回姓名、去重），演员跟着写「饰 X」 */
    fun castPeople(detail: LibraryItemDetailView): List<CastPerson> {
        val meta = detail.localMeta ?: return emptyList()
        val directors = if (meta.directorCredits.isEmpty()) {
            meta.directors.distinct().map { CastPerson(it, "导演", null, null) }
        } else {
            meta.directorCredits.map { CastPerson(it.name, "导演", it.thumbUrl, it.tmdbPersonId) }
        }
        return directors + meta.actors.map { CastPerson(it.name, it.role?.let { role -> "饰 $role" }, it.thumbUrl, it.tmdbPersonId) }
    }

    /** 季的胶囊上的字 */
    fun seasonLabel(number: Long): String = if (number == 0L) "特别篇" else "第 $number 季"

    /** 首屏下沿（918）到下半截的距离：剧集 82（露分集剧照上沿）、有系列的电影 20、没有系列的电影 164（什么都不露） */
    fun lowerGap(isMovie: Boolean, hasSeries: Boolean): Int = if (!isMovie) 82 else if (hasSeries) 20 else 164

    /** 下半截滑上来后第一行在屏幕上的 y：250，有选季、有集段页签各往下让 80 */
    fun lowerScreenTop(hasSeasonTabs: Boolean, hasRangeTabs: Boolean = false): Int =
        250 + (if (hasSeasonTabs) 80 else 0) + (if (hasRangeTabs) 80 else 0)

    /** 分集卡剧照左下的字：看了一半写「看到 m:ss」，否则片长 */
    fun episodeBandText(episode: EpisodeView, runtimeMinutes: Long?): String? = when {
        episode.positionMs > 0 -> "看到 ${Formatters.clock(episode.positionMs / 1000.0)}"
        runtimeMinutes != null && runtimeMinutes > 0 -> Formatters.runtime(runtimeMinutes.toInt())
        else -> null
    }
}

/** 影人页的纯逻辑（TVPersonView.swift） */
object PersonLogic {
    data class Section(val title: String, val credits: List<PersonCreditView>)

    /** 参演在前、执导在后（接口已排好序，这里不再排）；空的段不出 */
    fun sections(person: PersonView): List<Section> = listOf(
        Section("参演", person.credits.filter { it.department == "cast" }),
        Section("执导", person.credits.filter { it.department == "director" }),
    ).filter { it.credits.isNotEmpty() }

    /** 「库内 12 部 · 参演 10 · 执导 2」：只有一种身份时只写总数 */
    fun summary(person: PersonView): String {
        val all = "库内 ${person.credits.map { it.mediaItemId }.toSet().size} 部"
        val parts = sections(person)
        if (parts.size <= 1) return all
        return (listOf(all) + parts.map { "${it.title} ${it.credits.size}" }).joinToString(" · ")
    }

    /** 海报底部暗带那一行：「饰 柯布 · 2010」「导演 · 2010」（剧集写主创）；文件已删的补「片源已移除」 */
    fun focusDetail(credit: PersonCreditView): String {
        val role = if (credit.department == "director") {
            if (credit.kind == "tv") "主创" else "导演"
        } else {
            credit.character?.takeIf { it.isNotEmpty() }?.let { "饰 $it" }
        }
        val line = listOfNotNull(role, credit.year?.toString()).joinToString(" · ")
        if (credit.libraryId == null) return if (line.isEmpty()) "片源已移除" else "$line · 片源已移除"
        return line.ifEmpty { credit.title }
    }
}
