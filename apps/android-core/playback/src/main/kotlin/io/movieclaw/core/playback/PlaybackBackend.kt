package io.movieclaw.core.playback

import io.movieclaw.core.model.generated.PlaybackClientLogPayload
import io.movieclaw.core.model.generated.PlaybackItemView
import io.movieclaw.core.model.generated.PlaybackMetricPayload
import io.movieclaw.core.model.generated.PlaybackPolicyPayload
import io.movieclaw.core.model.generated.PlaybackProgressRequest
import io.movieclaw.core.model.generated.PlaybackSessionRequest
import io.movieclaw.core.model.generated.PlaybackSessionView
import io.movieclaw.core.model.generated.PlaybackStateView
import io.movieclaw.core.model.generated.SeasonEpisodesView
import io.movieclaw.core.model.generated.TrickplayView
import io.movieclaw.core.network.generated.McApi

/**
 * 播放器跟服务端说话的那一面（对照 Apple 端 PlaybackApiScope）：成员走成员域播放接口，访客走按分享 slug 收窄的公开通道。
 * 控制器不感知身份差异；访客没有的能力（缩略图、播放记录、客户端日志、转码开关）由 [MemberOnly] 的几项标出来。
 */
interface PlaybackBackend {
    suspend fun itemInfo(mediaItemId: Long): PlaybackItemView
    suspend fun episodes(mediaItemId: Long, season: Long): SeasonEpisodesView
    suspend fun startSession(body: PlaybackSessionRequest): PlaybackSessionView
    suspend fun pingSession(sessionId: String)
    suspend fun stopSession(sessionId: String)
    suspend fun progress(body: PlaybackProgressRequest): PlaybackStateView

    /** 打开软件转码全局开关，返回落库后的取值；访客没有设置权，返回 null */
    suspend fun enableSoftwareTranscode(): Boolean?

    /** 进度条缩略图索引；访客没有这个接口，返回 null */
    suspend fun trickplay(fileId: Long, token: String): TrickplayView?

    /**
     * 播放质量记录与客户端日志只记在成员名下。访客播放不攒记录：本机的待发队列是按设备的，
     * 访客的记录排进去之后会被下一次成员播放用成员身份发出去，算到别人头上。
     */
    val reportsMetrics: Boolean
    suspend fun reportMetric(payload: PlaybackMetricPayload)
    suspend fun clientLog(payload: PlaybackClientLogPayload)
}

/** 成员：成员域播放接口 */
class MemberBackend(private val api: McApi) : PlaybackBackend {
    override suspend fun itemInfo(mediaItemId: Long) = api.playbackItemInfo(mediaItemId)
    override suspend fun episodes(mediaItemId: Long, season: Long) = api.playbackItemEpisodes(mediaItemId, season)
    override suspend fun startSession(body: PlaybackSessionRequest) = api.playbackSessionStart(body)
    override suspend fun pingSession(sessionId: String) {
        api.playbackSessionPing(sessionId)
    }
    override suspend fun stopSession(sessionId: String) {
        api.playbackSessionStop(sessionId)
    }
    override suspend fun progress(body: PlaybackProgressRequest) = api.playbackProgress(body)
    override suspend fun enableSoftwareTranscode(): Boolean =
        api.playbackPolicySet(PlaybackPolicyPayload(softwareTranscodeEnabled = true)).softwareTranscodeEnabled
    override suspend fun trickplay(fileId: Long, token: String): TrickplayView = api.playbackFileTrickplay(fileId, token)
    override val reportsMetrics: Boolean get() = true
    override suspend fun reportMetric(payload: PlaybackMetricPayload) {
        api.playbackMetricReport(payload)
    }
    override suspend fun clientLog(payload: PlaybackClientLogPayload) {
        api.playbackClientLog(payload)
    }
}

/** 访客：分享页的公开播放通道（有密码的分享要求请求带着解锁 Cookie，由传输层的 Cookie 罐负责） */
class ShareBackend(private val api: McApi, private val slug: String) : PlaybackBackend {
    override suspend fun itemInfo(mediaItemId: Long) = api.sharePlaybackItem(mediaItemId, slug)
    override suspend fun episodes(mediaItemId: Long, season: Long) = api.sharePlaybackItemEpisodes(mediaItemId, slug, season)
    override suspend fun startSession(body: PlaybackSessionRequest) = api.sharePlaybackSessionStart(slug, body)
    override suspend fun pingSession(sessionId: String) {
        api.sharePlaybackSessionPing(sessionId, slug)
    }
    override suspend fun stopSession(sessionId: String) {
        api.sharePlaybackSessionStop(sessionId, slug)
    }
    override suspend fun progress(body: PlaybackProgressRequest) = api.sharePlaybackProgress(slug, body)
    override suspend fun enableSoftwareTranscode(): Boolean? = null
    override suspend fun trickplay(fileId: Long, token: String): TrickplayView? = null
    override val reportsMetrics: Boolean get() = false
    override suspend fun reportMetric(payload: PlaybackMetricPayload) = Unit
    override suspend fun clientLog(payload: PlaybackClientLogPayload) = Unit
}
