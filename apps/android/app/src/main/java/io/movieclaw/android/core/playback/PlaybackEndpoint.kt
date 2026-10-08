package io.movieclaw.android.core.playback

import io.movieclaw.android.core.api.McApi
import io.movieclaw.android.core.model.PlaybackProgressRequest
import io.movieclaw.android.core.model.PlaybackSessionRequest
import io.movieclaw.android.core.model.PlaybackSessionView
import io.movieclaw.android.core.model.PlaybackStateView
import io.movieclaw.android.core.network.dataOrThrow

/**
 * 播放端点抽象(iOS PlaybackApiScope 的对应物):
 * 成员走成员域播放接口,访客走按 slug 收窄的公开播放通道 —— 播放器与上报链路
 * 不感知身份差异,换端点即可复用整套播放逻辑。
 * 注意:注释里不要出现斜杠加星号的通配写法 —— Kotlin 块注释可嵌套,会当成嵌套注释。
 */
interface PlaybackEndpoint {
    suspend fun startSession(body: PlaybackSessionRequest): PlaybackSessionView
    suspend fun reportProgress(body: PlaybackProgressRequest): PlaybackStateView?
    suspend fun ping(sessionId: String)
    suspend fun stop(sessionId: String)

    /** 仅成员域:软件转码同意开关 */
    suspend fun enableSoftwareTranscode(): Boolean
}

class MemberPlaybackEndpoint(private val api: McApi) : PlaybackEndpoint {
    override suspend fun startSession(body: PlaybackSessionRequest) =
        api.startPlaybackSession(body).dataOrThrow()

    override suspend fun reportProgress(body: PlaybackProgressRequest) =
        runCatching { api.reportProgress(body).dataOrThrow() }.getOrNull()

    override suspend fun ping(sessionId: String) {
        api.pingPlaybackSession(sessionId)
    }

    override suspend fun stop(sessionId: String) {
        api.stopPlaybackSession(sessionId)
    }

    override suspend fun enableSoftwareTranscode(): Boolean =
        runCatching {
            api.savePlaybackPolicy(
                io.movieclaw.android.core.model.PlaybackPolicyPatch(softwareTranscodeEnabled = true)
            )
        }.isSuccess
}

/** 访客域:进度只落服务端访客通道,不写任何成员态 */
class GuestPlaybackEndpoint(private val api: McApi, private val slug: String) : PlaybackEndpoint {
    override suspend fun startSession(body: PlaybackSessionRequest) =
        api.startShareSession(slug, body).dataOrThrow()

    override suspend fun reportProgress(body: PlaybackProgressRequest) =
        runCatching { api.shareProgress(slug, body).dataOrThrow() }.getOrNull()

    override suspend fun ping(sessionId: String) {
        api.pingShareSession(slug, sessionId)
    }

    override suspend fun stop(sessionId: String) {
        api.stopShareSession(slug, sessionId)
    }

    /** 访客没有设置权:服务端要软件转码就只能看提示 */
    override suspend fun enableSoftwareTranscode(): Boolean = false
}
