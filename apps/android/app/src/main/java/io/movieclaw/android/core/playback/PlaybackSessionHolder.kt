package io.movieclaw.android.core.playback

import android.content.ComponentName
import android.content.Context
import android.os.Build
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.BuildConfig
import io.movieclaw.android.core.AppScopes
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.TokenVault
import io.movieclaw.core.network.ClientIdentity
import io.movieclaw.core.network.ServerAddress
import io.movieclaw.core.playback.MemberBackend
import io.movieclaw.core.playback.PlaybackBackend
import io.movieclaw.core.playback.PlaybackController
import io.movieclaw.core.playback.PlaybackHost
import io.movieclaw.core.playback.PlaybackTarget
import io.movieclaw.core.playback.ShareBackend
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 应用级播放会话宿主：播放不绑定在播放页上——页面退出 / 重建不影响播放，后台播放由 [PlaybackService] 保活。
 *
 * 播放本身（协商、起播、兜底阶梯、上报、选轨、下一集）全在与 TV 共用的统一引擎 [PlaybackController] 里；
 * 这里只管三件事：按成员 / 访客身份建控制器、身份变了（退出登录、切账号）立即停掉成员播放、把播放器交给系统媒体会话。
 */
@Singleton
class PlaybackSessionHolder @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
    private val playbackEvents: PlaybackDataEvents,
    private val prefs: CorePlaybackPrefs,
) {
    /** 正在放的那一次：控制器 + 进来时的目标（标题、库归属、剧集选集用）+ 它的网络通道（字幕、缩略图也从这里取） */
    data class Active(
        val controller: PlaybackController,
        val target: PlayTarget,
        val guest: Boolean,
        val http: okhttp3.OkHttpClient,
    )

    sealed interface State {
        data object Idle : State
        /** 在取设备号、建控制器（毫秒级） */
        data object Opening : State
        data class Playing(val active: Active) : State
        data class Failed(val message: String) : State
    }

    private val scope = AppScopes.main("PlaybackSessionHolder")

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _sessionPlayer = MutableStateFlow<Player?>(null)

    /** 当前播放器（统一引擎的 [PlaybackController.player]），[PlaybackService] 据此挂载 MediaSession */
    val sessionPlayer: StateFlow<Player?> = _sessionPlayer.asStateFlow()

    private val identity = ClientIdentity(
        appVersion = BuildConfig.VERSION_NAME,
        buildNumber = BuildConfig.VERSION_CODE.toLong(),
        model = Build.MODEL,
        osVersion = Build.VERSION.RELEASE,
        kind = ClientIdentity.PHONE_KIND,
        product = ClientIdentity.PHONE_PRODUCT,
    )

    /** 成员播放归属启动它的账号；访客播放不绑定成员身份 */
    private var memberIdentity: TokenVault.Identity? = null
    private var opening: Job? = null
    private var mediaControllerFuture: ListenableFuture<MediaController>? = null

    init {
        // 退出登录 / 切账号：立即终止属于旧账号的播放
        scope.launch {
            sessionRepository.ui.collect {
                val owner = memberIdentity
                if (owner != null && !sessionRepository.isCurrentIdentity(owner)) exit()
            }
        }
    }

    fun open(target: PlayTarget) {
        val origin = sessionRepository.ui.value.origin
        if (origin == null) {
            replace(null)
            _state.value = State.Failed("尚未连接服务器")
            return
        }
        val owner = sessionRepository.requestIdentity(origin)
        val channel = runCatching { apiFactory.corePlaybackForIdentity(origin, owner) }.getOrElse {
            replace(null)
            _state.value = State.Failed(it.message ?: "无效的服务器地址")
            return
        }
        begin(owner) {
            val deviceId = sessionRepository.deviceId()
            create(origin, MemberBackend(channel.api), channel.http, deviceId, owner?.token, target, guest = false) {
                if (owner != null && sessionRepository.isCurrentIdentity(owner)) playbackEvents.committed(owner)
            }
        }
    }

    /** 访客播放：显式指定服务器与分享 slug，走按 slug 收窄的公开播放通道；不读写任何成员态 */
    fun openGuest(origin: String, slug: String, target: PlayTarget) {
        val channel = runCatching { apiFactory.coreGuestPlayback(origin) }.getOrElse {
            replace(null)
            _state.value = State.Failed(it.message ?: "无效的服务器地址")
            return
        }
        begin(owner = null) {
            create(origin, ShareBackend(channel.api, slug), channel.http, "guest", null, target, guest = true) {}
        }
    }

    /** 关闭播放：控制器补发 stop 上报、释放服务端会话（页面销毁后照样发完），后台服务随之停用 */
    fun exit() {
        replace(null)
        _state.value = State.Idle
        mediaControllerFuture?.let { MediaController.releaseFuture(it) }
        mediaControllerFuture = null
    }

    fun isPlaying(): Boolean = (_state.value as? State.Playing)?.active?.controller?.player?.isPlaying == true

    private fun begin(owner: TokenVault.Identity?, build: suspend () -> Active?) {
        replace(null)
        memberIdentity = owner
        _state.value = State.Opening
        // 取设备号期间又点了别的 / 退出了：这个协程已被 replace 取消，不会走到下面
        opening = scope.launch {
            val created = build() ?: return@launch
            if (owner != null && !sessionRepository.isCurrentIdentity(owner)) {
                created.controller.close()
                exit()
                return@launch
            }
            created.controller.start()
            _sessionPlayer.value = created.controller.player
            _state.value = State.Playing(created)
            connectMediaController()
        }
    }

    private fun create(
        origin: String,
        backend: PlaybackBackend,
        http: okhttp3.OkHttpClient,
        deviceId: String,
        token: String?,
        target: PlayTarget,
        guest: Boolean,
        onStopCommitted: () -> Unit,
    ): Active? {
        val server = ServerAddress.parse(origin) ?: run {
            _state.value = State.Failed("无效的服务器地址:$origin")
            return null
        }
        val controller = PlaybackController(
            context = context,
            backend = backend,
            server = server,
            http = http,
            identity = identity,
            deviceId = deviceId,
            token = token,
            prefs = prefs,
            scope = scope,
            target = PlaybackTarget(
                mediaItemId = target.mediaItemId,
                seasonNumber = target.seasonNumber.toLong(),
                episodeNumber = target.episodeNumber.toLong(),
                startMs = target.startMs,
                audioTrack = target.preferredAudio,
                subtitleTrack = target.preferredSubtitle,
            ),
            // 调试包每秒往 logcat（PlaybackProbe）打一行状态：端到端验证与故障注入实验台读它
            probe = BuildConfig.DEBUG,
            // 能力申报与电视一致（不报 is_mobile）：服务端会把「移动端 + 原生 HLS」当成 iOS 系统播放器，
            // 把 5.1 音轨固定转成 AAC 双声道、限制转码画质——Exo 用不着这些限制
            host = PlaybackHost(playInBackground = true, ownsMediaSession = false),
            onStopCommitted = onStopCommitted,
        )
        return Active(controller, target, guest, http)
    }

    /** 换掉当前控制器：旧的关掉（stop 上报与关会话在控制器自己的队列里发完） */
    private fun replace(next: Active?) {
        opening?.cancel()
        opening = null
        val previous = (_state.value as? State.Playing)?.active
        if (previous != null && previous !== next) previous.controller.close()
        _sessionPlayer.value = next?.controller?.player
        if (next == null) memberIdentity = null
    }

    private fun connectMediaController() {
        if (mediaControllerFuture != null) return
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        mediaControllerFuture = MediaController.Builder(context, token).buildAsync()
    }
}
