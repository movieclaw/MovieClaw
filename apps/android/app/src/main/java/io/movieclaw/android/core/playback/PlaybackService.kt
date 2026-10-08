@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.core.playback

import io.movieclaw.android.core.AppScopes

import android.app.PendingIntent
import android.content.Intent
import android.os.Looper
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import dagger.hilt.android.AndroidEntryPoint
import io.movieclaw.android.MainActivity
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * 后台播放服务(MediaSessionService):
 *   MediaSession 的 player 在引擎切换时被换掉(setPlayer):Exo 直挂 ExoPlayer,
 *   MPV 挂 MpvPlayerProxy(SimpleBasePlayer 包装)。锁屏/通知/媒体键由 Media3 统一处理。
 *
 * 生命周期契约(读 Media3 1.8 源码确认):
 *   - 服务由 App 侧 MediaController 连接拉起(MediaControllerImplBase 用 bindService);
 *   - 播放中 Media3 的通知管理器自行 ContextCompat.startForegroundService 进入前台;
 *   - 划掉任务卡片时默认 onTaskRemoved:播放中保活,未播放则 pauseAll + stopSelf。
 */
@AndroidEntryPoint
class PlaybackService : MediaSessionService() {

    @Inject
    lateinit var holder: PlaybackSessionHolder

    private var mediaSession: MediaSession? = null
    private val idlePlayer by lazy { IdlePlayer() }
    private val scope = AppScopes.main("PlaybackService")
    private var observeJob: Job? = null

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession {
        mediaSession?.let { return it }
        val session = MediaSession.Builder(this, holder.sessionPlayer.value ?: idlePlayer)
            .setSessionActivity(openAppIntent())
            .build()
        mediaSession = session
        observePlayerChanges(session)
        return session
    }

    /** 引擎切换 / 会话收尾时换掉会话 player */
    private fun observePlayerChanges(session: MediaSession) {
        observeJob?.cancel()
        observeJob = scope.launch {
            holder.sessionPlayer.collectLatest { player ->
                val next = player ?: idlePlayer
                if (session.player !== next) {
                    session.player = next
                }
            }
        }
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        },
        PendingIntent.FLAG_IMMUTABLE,
    )

    override fun onDestroy() {
        observeJob?.cancel()
        holder.exit()
        scope.cancel()
        mediaSession?.run {
            player = idlePlayer
            release()
        }
        mediaSession = null
        idlePlayer.release()
        super.onDestroy()
    }
}

/** 会话尚未挂载真实播放器时的空 player(服务被系统复用拉起时仍可安全建会话) */
private class IdlePlayer : SimpleBasePlayer(Looper.getMainLooper()) {
    override fun getState(): State = State.Builder()
        .setAvailableCommands(Player.Commands.EMPTY)
        .setPlaybackState(Player.STATE_IDLE)
        .setPlayWhenReady(false, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        .build()

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> =
        Futures.immediateVoidFuture()

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> =
        Futures.immediateVoidFuture()

    override fun handleSetPlaybackParameters(playbackParameters: PlaybackParameters): ListenableFuture<*> =
        Futures.immediateVoidFuture()

    override fun handleStop(): ListenableFuture<*> = Futures.immediateVoidFuture()

    override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()
}
