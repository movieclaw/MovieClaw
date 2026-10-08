package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.generated.EpisodeView
import io.movieclaw.androidtv.core.model.generated.PlaybackDecisionView
import io.movieclaw.androidtv.core.model.generated.PlaybackItemView
import io.movieclaw.androidtv.core.model.generated.PlaybackSegmentView
import io.movieclaw.androidtv.core.model.generated.TrickplayView

/** 要播的那一集 / 那部片（进入播放器的第一个单元）。电影的季、集都是 0 */
data class PlaybackTarget(
    val mediaItemId: Long,
    val seasonNumber: Long = 0,
    val episodeNumber: Long = 0,
    /** 指定起播位置（只对第一个单元生效）；null 由服务端按续播点起，0 从头播放 */
    val startMs: Long? = null,
    /** 指定版本（只对第一个单元生效） */
    val fileId: Long? = null,
)

/** 起播状态机（对照 Apple 端 PlaybackController.Phase） */
enum class Phase {
    Idle, Deciding, SessionStarting, Buffering, Playing, Degrading, Consent, Error, Ended;

    /** 转圈该不该显示：起播四段与降档重来都算「还没出画」 */
    val isBusy: Boolean get() = this == Deciding || this == SessionStarting || this == Buffering || this == Degrading

    /** 转圈时说清楚卡在哪一段 */
    val busyLabel: String
        get() = when (this) {
            Deciding -> "正在判断播放方式…"
            SessionStarting -> "正在准备视频流…"
            Degrading -> "这一档放不出来，正在降档重试…"
            else -> "正在缓冲…"
        }
}

/**
 * 播放器界面要的一切（一份不可变快照）。派生量（跳过按钮、下一集卡片……）都是纯函数，单测直接覆盖。
 * 位置、时长一律是**文件时间**（毫秒）。
 */
data class PlayerState(
    val unit: PlaybackUnit,
    val phase: Phase = Phase.Idle,
    val info: PlaybackItemView? = null,
    /** 条目信息都拿不到（无权访问、已删除）：整页换成原因 +「返回」 */
    val infoError: String? = null,
    val episodes: List<EpisodeView> = emptyList(),
    val hasSession: Boolean = false,
    val segments: List<PlaybackSegmentView>? = null,
    val errorMessage: String? = null,
    val errorSuggestion: String? = null,
    /** 等用户拍板的决策（需要软件转码的同意弹窗） */
    val pendingDecision: PlaybackDecisionView? = null,
    val positionMs: Long = 0,
    val durationMs: Long? = null,
    val bufferedEndMs: Long? = null,
    val paused: Boolean = true,
    /** 用户想不想播（换流、换轨时的程序性暂停不改它） */
    val wantsPlay: Boolean = true,
    val speedLabel: String? = null,
    val notice: String? = null,
    val qualityOffer: QualitySuggestion.Offer? = null,
    val trickplay: TrickplayView? = null,
    val nextDismissed: Boolean = false,
    val autoNextStreak: Int = 0,
    val autoNextProgress: Double = 0.0,
    val subtitles: SubtitleTracks = SubtitleTracks(),
    val selectedSubtitle: String? = null,
    val audioOptions: List<AudioOption> = emptyList(),
    val currentAudio: String? = null,
    /** 画质上限（null = 原画） */
    val quality: Int? = null,
    /** 叠加层要画的服务端文本字幕（已带 `&format=vtt`）；Exo 自己画、烧录、图形字幕时为 null */
    val overlaySubtitleUrl: String? = null,
    /** 当前字幕由 Exo 画（画面里的 cue 走 [PlaybackController.cues]） */
    val engineSubtitles: Boolean = false,
    val videoWidth: Int = 0,
    val videoHeight: Int = 0,
    /** 片源帧率（解出来的格式优先，没有就用台账的）：界面层据此做自动帧率匹配 */
    val contentFrameRate: Float? = null,
) {
    val title: String get() = info?.title ?: "正在播放"

    val nextEpisode: EpisodeView? get() = EpisodeNavigation.next(episodes, unit)
    val previousEpisode: EpisodeView? get() = EpisodeNavigation.previous(episodes, unit)
    val currentEpisode: EpisodeView? get() = episodes.firstOrNull { it.episodeNumber == unit.episode }
    val episodeLabel: String? get() = EpisodeNavigation.label(unit, currentEpisode)

    /** 底部标题行：「片名 · S01E02 · 集名」/ 电影只有片名 */
    val titleLine: String get() = episodeLabel?.let { "$title · $it" } ?: title

    /** 片尾 40 秒内（或已播完）显示「即将播放」卡片；认出了一直放到结尾的片尾时进了片尾就给 */
    val showsUpNext: Boolean
        get() = nextEpisode != null && !nextDismissed &&
            SkipSegments.shouldShowUpNext(segments, positionMs, durationMs, ended = phase == Phase.Ended)

    /** 当前位置该给的「跳过」按钮；与「即将播放」卡片不同时出现，已播完 / 报错 / 等同意时都不给 */
    val skipSegment: PlaybackSegmentView?
        get() {
            if (phase == Phase.Ended || phase == Phase.Error || phase == Phase.Consent || showsUpNext) return null
            return SkipSegments.active(segments, positionMs)
        }

    /** 认出了片尾、卡片在显示、没到连播上限：卡片倒计时，走满自动换集 */
    val autoNextArmed: Boolean get() = showsUpNext && SkipSegments.autoNextArmed(segments, positionMs, autoNextStreak)

    val isModal: Boolean get() = infoError != null || phase == Phase.Error || phase == Phase.Consent

    /** 暂停遮罩只跟「用户意图」走：缓冲、换流时的程序性暂停不压暗 */
    val showPaused: Boolean get() = paused && !wantsPlay && !phase.isBusy && !isModal && positionMs > 0

    /** 用户暂停着（控制层常显） */
    val userPaused: Boolean get() = paused && !phase.isBusy && hasSession

    /** 字幕栏的条数 */
    val subtitleCount: Int get() = subtitles.options.size + subtitles.unavailable.size
}
