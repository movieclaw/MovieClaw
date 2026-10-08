package io.movieclaw.android.core.playback

import io.movieclaw.android.core.AppScopes

import io.movieclaw.android.core.designsystem.FeedbackBus
import android.content.ComponentName
import android.content.Context
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.model.PlaybackSessionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.TokenVault
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import io.movieclaw.android.core.network.friendlyMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 应用级播放会话宿主(M1d):播放不再绑定在播放页 ViewModel 上——
 * 页面退出/重建不影响播放,后台播放由 MediaSessionService 保活。
 * 连接 MediaController 是 Media3 的约定入口:服务随之创建,播放中
 * Media3 自行 startForegroundService 并维护通知。
 */
@Singleton
class PlaybackSessionHolder @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
    private val qualityMemory: QualityMemory,
    private val feedback: FeedbackBus,
    private val qoe: PlaybackQoe,
    private val trickplay: TrickplayProvider,
    private val playbackEvents: PlaybackDataEvents = PlaybackDataEvents(),
) {
    sealed interface State {
        data object Idle : State
        data object Preparing : State
        data class Playing(val controller: PlaybackController, val session: PlaybackSessionView) : State
        data class Consent(val reason: String, val costHint: String?) : State
        data class Failed(val message: String, val suggestion: String? = null) : State
    }

    private val scope = AppScopes.main("PlaybackSessionHolder")

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _sessionPlayer = MutableStateFlow<Player?>(null)

    /** 当前 Media3 Player(Exo 实体或 MPV 代理),PlaybackService 据此挂载 MediaSession */
    val sessionPlayer: StateFlow<Player?> = _sessionPlayer.asStateFlow()

    private var controller: PlaybackController? = null
    private var memberIdentity: TokenVault.Identity? = null
    private var operation: Job? = null
    private var generation = 0L
    private var mediaControllerFuture: ListenableFuture<MediaController>? = null
    private var rememberedQualityNotice: String? = null

    init {
        // 成员播放归属启动它的账号；退出/切账号立即终止，访客播放不绑定成员身份。
        scope.launch {
            sessionRepository.ui.collect {
                val owner = memberIdentity
                if (owner != null && !sessionRepository.isCurrentIdentity(owner)) exit()
            }
        }
    }

    /** 用户的新操作作废旧协商；UI/服务只接受当前实例的播放器回调。 */
    private fun beginOperation(replaceController: Boolean): Long {
        generation += 1
        operation?.cancel()
        operation = null
        if (replaceController) {
            memberIdentity = null
            val previous = controller
            controller = null
            previous?.dispose()
            _sessionPlayer.value = null
            rememberedQualityNotice = null
        }
        return generation
    }

    private fun bind(created: PlaybackController) {
        controller = created
        created.onPlayerChanged = { player ->
            if (controller === created) _sessionPlayer.value = player
        }
    }

    private fun launchOperation(mine: Long, block: suspend () -> Unit) {
        operation = scope.launch {
            try {
                val owner = memberIdentity
                if (owner != null && !sessionRepository.isCurrentIdentity(owner)) {
                    exit()
                    return@launch
                }
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (mine == generation) _state.value = State.Failed(friendlyMessage(e))
            }
        }
    }

    fun open(target: PlayTarget) {
        val mine = beginOperation(replaceController = true)
        // 起播分段计时从这里起算（iOS `PlaybackStartupTrace`：用户说起播慢时先看这一行）
        PlaybackStartupTrace.start()
        PlaybackStartupTrace.mark("点击")
        val origin = sessionRepository.ui.value.origin
        if (origin == null) {
            _state.value = State.Failed("尚未连接服务器")
            return
        }
        memberIdentity = sessionRepository.requestIdentity(origin)
        val owner = memberIdentity
        _state.value = State.Preparing
        launchOperation(mine) {
            // 播放链路走专用连接池（协商/进度/心跳/停止都在它上面，不排在页面请求后面）
            val api = apiFactory.playbackForOrigin(origin)
            val created = PlaybackController(
                context = context.applicationContext,
                endpoint = MemberPlaybackEndpoint(api),
                deviceId = sessionRepository.deviceId(),
                target = target,
                origin = origin,
                qoe = qoe,
                trickplay = trickplay,
                onStopCommitted = {
                    if (owner != null && sessionRepository.isCurrentIdentity(owner)) playbackEvents.committed(owner)
                },
            )
            created.attachApi(api)
            if (mine != generation) {
                created.dispose()
                return@launchOperation
            }
            bind(created)
            // 画质记忆:同一片名 + 同一网络环境沿上次的选择(iOS QualityMemory)
            val remembered = qualityMemory.remembered(target.mediaItemId, networkOf())
            if (remembered != null) {
                created.applyRememberedQuality(remembered.takeIf { it > 0 })
                // iOS:第一帧后提示「已沿用上次的选择」(只提限制性的选择)
                rememberedQualityNotice = remembered
                    .takeIf { it > 0 }
                    ?.let { "${it}p(${networkOf().label})" }
            }
            val negotiation = created.negotiate()
            PlaybackStartupTrace.mark("决策+会话")
            handle(created, mine, negotiation)
        }
    }

    private suspend fun handle(
        active: PlaybackController, mine: Long, negotiation: PlaybackController.Negotiation,
    ) {
        val owner = memberIdentity
        if (owner != null && !sessionRepository.isCurrentIdentity(owner)) exit()
        if (mine != generation || controller !== active) {
            if (negotiation is PlaybackController.Negotiation.Ready) active.discardSession(negotiation.session)
            return
        }
        when (negotiation) {
            is PlaybackController.Negotiation.Rejected ->
                _state.value = State.Failed(negotiation.reason.ifEmpty { "无法播放" }, negotiation.suggestion)
            is PlaybackController.Negotiation.Consent ->
                _state.value = State.Consent(negotiation.reason, negotiation.costHint)
            is PlaybackController.Negotiation.Ready -> {
                active.start(negotiation.session)
                PlaybackStartupTrace.mark("引擎")
                _state.value = State.Playing(active, negotiation.session)
                connectMediaController()
                rememberedQualityNotice?.let { choice ->
                    rememberedQualityNotice = null
                    feedback.info("已沿用上次的选择:画质 $choice")
                }
            }
        }
    }

    /** 画质重开与点播共用操作闸，退出/再次选择会取消旧协商。 */
    fun changeQuality(height: Int?) {
        val active = controller ?: return
        val mine = beginOperation(replaceController = false)
        val network = networkOf()
        launchOperation(mine) {
            val result = active.changeQuality(height)
            handle(active, mine, result)
            if (result is PlaybackController.Negotiation.Ready && mine == generation && controller === active) {
                qualityMemory.remember(active.target.mediaItemId, network, height)
            }
        }
    }

    /**
     * 访客播放:显式指定服务器与分享 slug,走按 slug 收窄的公开播放通道;
     * 不读写任何成员态(进度由服务端访客通道保存)。
     */
    fun openGuest(origin: String, slug: String, target: PlayTarget) {
        val mine = beginOperation(replaceController = true)
        _state.value = State.Preparing
        launchOperation(mine) {
            val api = apiFactory.guestPlaybackForOrigin(origin)
            val created = PlaybackController(
                context = context.applicationContext,
                endpoint = GuestPlaybackEndpoint(api, slug),
                deviceId = "guest",
                target = target,
                origin = origin,
                qoe = qoe,
                trickplay = trickplay,
            )
            created.attachApi(api)
            if (mine != generation) {
                created.dispose()
                return@launchOperation
            }
            bind(created)
            handle(created, mine, created.negotiate())
        }
    }

    fun grantConsent() {
        val active = controller ?: return
        val mine = beginOperation(replaceController = false)
        launchOperation(mine) { handle(active, mine, active.grantConsent()) }
    }

    fun retryWithoutSubtitle() {
        val active = controller ?: return
        val mine = beginOperation(replaceController = false)
        launchOperation(mine) { handle(active, mine, active.retryWithoutSubtitle()) }
    }

    /** 关闭播放:先冲刷进度,再断开控制器(服务随之后台停用) */
    fun exit() {
        beginOperation(replaceController = true)
        _sessionPlayer.value = null
        _state.value = State.Idle
        mediaControllerFuture?.let { MediaController.releaseFuture(it) }
        mediaControllerFuture = null
    }

    fun networkOf(): PlaybackNetwork {
        val origin = sessionRepository.ui.value.origin ?: return PlaybackNetwork.UNKNOWN
        return PlaybackNetwork.of(android.net.Uri.parse(origin).host)
    }

    fun isPlaying(): Boolean = when (val current = _state.value) {
        is State.Playing -> current.controller.isPlaying()
        else -> false
    }

    private fun connectMediaController() {
        if (mediaControllerFuture != null) return
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        mediaControllerFuture = MediaController.Builder(context, token).buildAsync()
    }
}
