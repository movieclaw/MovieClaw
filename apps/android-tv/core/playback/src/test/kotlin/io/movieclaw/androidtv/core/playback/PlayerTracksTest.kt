package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.AudioTrackView
import io.movieclaw.androidtv.core.model.generated.SubtitlePlanView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 轨道菜单的纯逻辑：标签、说明、分组折叠、默认选择、Exo 读到的轨补进清单（同 Apple 端 PlayerTracksTests） */
class PlayerTracksTest {
    private fun option(ref: String, kind: String = "vtt", language: String? = null, title: String? = null, path: String = "/api/v1/sub") =
        SubtitleOption(ref, ref, kind, path, language, isDefault = false, isAi = false, title = title)

    private fun plan(ref: String, kind: String = "vtt", language: String? = null, default: Boolean = false, title: String? = null, forced: Boolean? = null, ai: Boolean = false) =
        SubtitlePlanView(trackRef = ref, kind = kind, language = language, isDefault = default, isAi = ai, title = title, isForced = forced)

    @Test fun languageNames() {
        assertEquals("简体中文", LanguageLabel.of("chs"))
        assertEquals("繁体中文", LanguageLabel.of("CHT"))
        assertEquals("中文", LanguageLabel.of("zho"))
        assertEquals("粤语", LanguageLabel.of("yue"))
        assertEquals("德语", LanguageLabel.of("deu"))
        assertEquals("印地语", LanguageLabel.of("hin"))
        assertNull(LanguageLabel.of("und"))
        assertNull(LanguageLabel.of(""))
        assertNull(LanguageLabel.of(null))
        assertEquals("swe", LanguageLabel.of("swe"))
    }

    @Test fun audioLabels() {
        assertEquals("日语 · AC3 · 5.1", AudioOption.label("embedded:1", "jpn", "ac3", 6))
        assertEquals("英语 · TRUEHD · 7.1", AudioOption.label("embedded:0", "eng", "truehd", 8))
        assertEquals("中文 · AAC · 立体声", AudioOption.label("embedded:0", "chi", "aac", 2))
        assertEquals("音轨 3 · MP3 · 单声道", AudioOption.label("embedded:3", null, "mp3", 1))
        assertEquals("未知音轨 · 3 声道", AudioOption.label("x", "und", null, 3))
        assertEquals("音轨 0", AudioOption.label("embedded:0", null, null, null))
        val (title, detail) = TrackText.split("日语 · AC3 · 5.1")
        assertEquals("日语", title)
        assertEquals("AC3 · 5.1", detail)
        assertNull(TrackText.split("日语").second)
    }

    @Test fun audioMenuNeedsTwoTracksAndGreysOutUnrecognizedCodec() {
        assertTrue(AudioOption.plan(listOf(AudioTrackView("embedded:0", "aac", 2, "chi", true))).isEmpty())
        val options = AudioOption.plan(
            listOf(
                AudioTrackView("embedded:0", null, 10, "chi", false),
                AudioTrackView("embedded:1", "eac3", 6, "chi", false),
                AudioTrackView("embedded:2", "aac", 2, "chi", true),
            ),
        )
        assertEquals(listOf(true, false, false), options.map { it.unavailableReason != null })
        assertEquals("中文 · 10 声道", options[0].label)
        // 整片都认不出（没探测过）：不下「放不了」的结论
        val unprobed = AudioOption.plan(listOf(AudioTrackView("embedded:0", null, null, null, true), AudioTrackView("embedded:1", null, null, null, false)))
        assertTrue(unprobed.all { it.unavailableReason == null })
    }

    @Test fun defaultAudioSkipsUnplayableTracks() {
        val vivid = AudioOption.plan(listOf(AudioTrackView("embedded:0", null, 10, "chi", true), AudioTrackView("embedded:1", "eac3", 6, "chi", false)))
        assertEquals("embedded:1", AudioOption.defaultRef(vivid))
        val unflagged = AudioOption.plan(listOf(AudioTrackView("embedded:0", "truehd", 8, "eng", false), AudioTrackView("embedded:1", "ac3", 6, "chi", false)))
        assertEquals("embedded:0", AudioOption.defaultRef(unflagged))
    }

    @Test fun subtitleTitleAndDetail() {
        val tracks = SubtitleTracks.plan(
            listOf(
                plan("embedded:3", "pgs", "chi", title = "  国配简体  ", forced = true),
                plan("embedded:4", "pgs", "chi", default = true, title = "国配简体"),
                plan("embedded:0", "vtt", "und"),
                plan("external:film.chs.ass", "ass", "chs", ai = true),
            ),
            listOf("/a", "/b", "/c", "/d"),
        )
        assertEquals(listOf("国配简体", "国配简体", "内封轨 1", "film.chs.ass"), tracks.options.map { it.displayTitle })
        assertEquals("中文 · PGS 图形 · 内封轨 4 · 强制", tracks.options[0].detail)
        assertEquals("中文 · PGS 图形 · 内封轨 5 · 默认", tracks.options[1].detail)
        assertEquals("未知语言 · WebVTT · 内封", tracks.options[2].detail)
        assertEquals("简体中文 · ASS · 外挂 · AI 翻译", tracks.options[3].detail)
        assertEquals("简体中文 · 特效", tracks.options[3].label)
    }

    @Test fun missingUrlOrUnsupportedKindIsUnavailable() {
        val tracks = SubtitleTracks.plan(listOf(plan("embedded:0", "vtt", "eng"), plan("embedded:1", "dvb", "eng"), plan("embedded:2", "vtt", "jpn")), listOf("/a", "/b"))
        assertEquals(listOf("embedded:0"), tracks.options.map { it.ref })
        assertEquals("暂不支持的字幕格式：dvb", tracks.unavailable[0].reason)
        assertEquals("服务端没有给出这条轨的地址", tracks.unavailable[1].reason)
    }

    @Test fun initialSelectionRespectsRememberedOffThenDefault() {
        val tracks = SubtitleTracks(
            listOf(option("embedded:0"), option("embedded:1").copy(isDefault = true), option("external:a.srt")),
        )
        assertNull(tracks.initialSelection("off"))
        assertEquals("external:a.srt", tracks.initialSelection("external:a.srt"))
        // 记着的轨这次不在清单里：退到默认轨
        assertEquals("embedded:1", tracks.initialSelection("embedded:9"))
        assertEquals("embedded:1", tracks.initialSelection(null))
        assertNull(SubtitleTracks(listOf(option("embedded:0"))).initialSelection(null))
    }

    @Test fun engineTracksFillWhatTheServerDidNotList() {
        val tracks = SubtitleTracks(listOf(option("embedded:0", "pgs"), option("external:a.srt")))
        val engine = listOf(
            EngineTrack(title = null, language = "eng", codec = "application/pgs"),
            EngineTrack(title = null, language = "chi", codec = "application/dvbsubs", isDefault = true),
        )
        val adopted = tracks.adoptEngineSubtitles(engine)
        assertNotNull(adopted)
        assertEquals(listOf("embedded:0", "embedded:1", "external:a.srt"), adopted!!.options.map { it.ref })
        val added = adopted.options[1]
        assertEquals("pgs", added.kind)
        assertEquals("中文 · 图形", added.label)
        assertTrue(added.path.isEmpty() && added.isDefault)
        // 再来一次什么都不变
        assertNull(adopted.adoptEngineSubtitles(engine))
    }

    @Test fun engineClosedCaptionsAndKinds() {
        val adopted = SubtitleTracks().adoptEngineSubtitles(
            listOf(
                EngineTrack(title = null, language = null, codec = "application/cea-608"),
                EngineTrack(title = null, language = null, codec = "text/x-ssa"),
                EngineTrack(title = null, language = "eng", codec = "application/x-subrip"),
            ),
        )!!
        assertEquals(listOf("vtt", "ass", "vtt"), adopted.options.map { it.kind })
        assertEquals("隐藏字幕（CC）", adopted.options[0].displayTitle)
        assertEquals("内封轨 2 · 特效", adopted.options[1].label)
        assertEquals("英语 · 文本", adopted.options[2].label)
    }

    @Test fun engineOnlyFillsMissingTitles() {
        val tracks = SubtitleTracks(listOf(option("embedded:0", title = "服务端标题"), option("embedded:1"), option("external:a.srt")))
        val engine = listOf(
            EngineTrack(title = "引擎标题", language = "chi", codec = "application/pgs", isDefault = true),
            EngineTrack(title = "简英 · 修订版", language = "chi", codec = "application/pgs", isDefault = true, isForced = true),
        )
        val adopted = tracks.adoptEngineSubtitles(engine)!!
        assertEquals("服务端标题", adopted.options[0].displayTitle)
        assertEquals("简英 · 修订版", adopted.options[1].displayTitle)
        assertEquals("/api/v1/sub", adopted.options[1].path)
        assertFalse(adopted.options[1].isDefault)
        assertTrue(adopted.options[1].isForced)
        assertNull(adopted.adoptEngineSubtitles(engine))
    }

    @Test fun engineAudioOptions() {
        assertTrue(AudioOption.engineOptions(listOf(EngineTrack(null, "eng", "dts", channels = 6))).isEmpty())
        val options = AudioOption.engineOptions(listOf(EngineTrack(null, "eng", "dts", channels = 6), EngineTrack(null, "chi", "ac3", isDefault = true, channels = 2)))
        assertEquals(listOf("英语 · DTS · 5.1", "中文 · AC3 · 立体声"), options.map { it.label })
        assertEquals("eac3", audioCodecName("audio/eac3-joc"))
        assertEquals("dts", audioCodecName("audio/vnd.dts.hd"))
        assertEquals("aac", audioCodecName("audio/mp4a-latm"))
    }

    // ---- 字幕栏分组 ----

    private fun subs(vararg pairs: Pair<String, String?>) = SubtitleTracks(pairs.map { (ref, lang) -> option(ref, language = lang) })

    @Test fun sectionsInOrder() {
        val tracks = subs("embedded:0" to "eng", "embedded:1" to "chi", "embedded:2" to "jpn", "embedded:3" to "zh-Hans", "embedded:4" to "en-US")
        val sections = SubtitleSections.build(tracks, selected = "embedded:1", live = "embedded:1", expanded = false)
        assertEquals(listOf("off", "current", "zh", "en", "other"), sections.map { it.id })
        assertEquals(listOf(null, "正在使用", "中文", "英语", "其他语言"), sections.map { it.title })
        assertEquals(listOf("embedded:3"), sections[2].rows.map { it.id })
        assertEquals(listOf("embedded:0", "embedded:4"), sections[3].rows.map { it.id })
    }

    @Test fun pinnedCurrentRenamesWithoutReordering() {
        val tracks = subs("embedded:0" to "chi", "embedded:1" to "eng")
        val sections = SubtitleSections.build(tracks, selected = "embedded:0", live = "embedded:1", expanded = false)
        assertEquals("之前在用", sections[1].title)
        assertEquals(listOf("embedded:0"), sections[1].rows.map { it.id })
        // 没选字幕：没有「正在使用」
        assertEquals(listOf("off", "zh", "en"), SubtitleSections.build(tracks, null, null, false).map { it.id })
    }

    @Test fun othersCollapseWhenMany() {
        val langs = listOf("chi", "eng", "jpn", "kor", "fre", "ger", "spa", "rus", "ita")
        val tracks = SubtitleTracks(
            langs.mapIndexed { i, lang -> option("embedded:$i", language = lang).copy(label = "${LanguageLabel.of(lang)} · 文本") },
            listOf(UnavailableSubtitle("embedded:9", "泰语 · 文本", "x")),
        )
        val collapsed = SubtitleSections.build(tracks, null, null, expanded = false)
        val more = collapsed.last().rows.single() as SubtitleSections.Row.More
        assertEquals(8, more.count)
        assertEquals("日语 · 韩语 · 法语 · 德语 …", more.names)
        val expanded = SubtitleSections.build(tracks, null, null, expanded = true)
        assertEquals(8, expanded.last().rows.size)
        assertEquals("embedded:2", SubtitleSections.firstOther(tracks, null)?.ref)
        // 总数不超过 8 或其他语言不到 3 条：不折叠
        val few = subs("embedded:0" to "jpn", "embedded:1" to "kor", "embedded:2" to "fre")
        assertEquals(3, SubtitleSections.build(few, null, null, false).last().rows.size)
    }

    @Test fun languageGroups() {
        for (code in listOf("zh", "zh-Hant", "chi", "zho", "chs", "cht", "cmn", "yue", "Chinese")) {
            assertEquals(code, SubtitleSections.Group.Chinese, SubtitleSections.group(code))
        }
        for (code in listOf("en", "eng", "en-GB", "english")) assertEquals(SubtitleSections.Group.English, SubtitleSections.group(code))
        for (code in listOf(null, "", "jpn", "und")) assertEquals(SubtitleSections.Group.Other, SubtitleSections.group(code))
    }

    @Test fun rememberedChoiceNotice() {
        assertEquals(
            "已沿用上次的选择：画质 720p（外网），音轨 日语，字幕 关闭",
            RememberedChoices.notice(720, PlaybackNetwork.Away, "日语", "关闭"),
        )
        assertEquals("已沿用上次的选择：画质 1080p", RememberedChoices.notice(1080, PlaybackNetwork.Unknown, null, null))
        assertNull(RememberedChoices.notice(null, PlaybackNetwork.Home, null, null))
        assertEquals("日语", RememberedChoices.shortLabel("日语 · AC3 · 5.1", listOf("日语 · AC3 · 5.1", "中文 · AAC")))
        assertEquals("日语 · AC3 · 5.1", RememberedChoices.shortLabel("日语 · AC3 · 5.1", listOf("日语 · AC3 · 5.1", "日语 · AAC")))
    }
}
