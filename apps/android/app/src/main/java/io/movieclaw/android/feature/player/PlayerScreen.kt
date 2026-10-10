package io.movieclaw.android.feature.player

import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.ActivityInfo
import android.media.AudioManager
import android.util.Rational
import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Brightness6
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.ClosedCaption
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.automirrored.rounded.PlaylistPlay
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PictureInPictureAlt
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.VolumeUp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.viewinterop.AndroidView
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.media3.ui.PlayerView
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.AccentSoft
import io.movieclaw.android.core.designsystem.GlassCard
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.PlaybackSessionView
import io.movieclaw.android.core.model.PlaybackDecisionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.playback.EngineKind
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.playback.PlaybackController
import io.movieclaw.android.core.playback.PlaybackSessionHolder
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 播放页是应用级会话(PlaybackSessionHolder)的视图:
 * 播放不随页面销毁停止,退到后台继续由 MediaSessionService 保活;
 * 显式返回(BackHandler)才结束会话并冲刷进度。
 */
@HiltViewModel
class PlayerViewModel @Inject constructor(
    private val holder: PlaybackSessionHolder,
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
    private val subtitleStyles: io.movieclaw.android.core.playback.SubtitleStyleStore,
    private val screenPrefs: io.movieclaw.android.core.playback.ScreenPrefs,
) : ViewModel() {

    /** 上次手势调出来的播放页亮度（本机记忆；进播放页套上，退出仍把系统亮度还回去） */
    private val _playerBrightness = MutableStateFlow<Float?>(null)
    val playerBrightness = _playerBrightness.asStateFlow()

    init {
        viewModelScope.launch { _playerBrightness.value = screenPrefs.playerBrightness() }
    }

    fun rememberBrightness(value: Float) {
        _playerBrightness.value = value
        viewModelScope.launch { screenPrefs.rememberBrightness(value) }
    }

    /** 字幕外观（字号/时间轴/位置/背景），存本机；改完立刻重画 */
    val subtitleStyle = subtitleStyles.style

    fun updateSubtitleStyle(
        transform: (io.movieclaw.android.core.playback.SubtitleStyle) -> io.movieclaw.android.core.playback.SubtitleStyle,
    ) = subtitleStyles.update(transform)

    /** 下一集(iOS 语义:同季内第一个「有文件且集号更大」的集,本季没有就看下一季) */
    data class UpNext(
        val seasonNumber: Int,
        val episodeNumber: Int,
        val label: String,
        /** 下一集的默认文件（字幕预热的落点；解析不到就是 null，预热跳过） */
        val fileId: Long? = null,
    )

    val state = holder.state

    private val _upNext = MutableStateFlow<UpNext?>(null)
    val upNext = _upNext.asStateFlow()

    private var upNextLoadedFor: String? = null

    init {
        viewModelScope.launch {
            holder.state.collect { current ->
                val target = (current as? PlaybackSessionHolder.State.Playing)?.controller?.target
                if (target == null || target.kind != "tv") {
                    _upNext.value = null
                    upNextLoadedFor = null
                    return@collect
                }
                val key = "${target.mediaItemId}:${target.seasonNumber}:${target.episodeNumber}"
                if (upNextLoadedFor == key) return@collect
                upNextLoadedFor = key
                _upNext.value = loadUpNext(target)
            }
        }
    }

    private suspend fun loadUpNext(target: PlayTarget): UpNext? {
        val origin = sessionRepository.ui.value.origin ?: return null
        val api = apiFactory.forOrigin(origin)
        return runCatching {
            val detail = api.libraryItemDetail(target.libraryId, target.mediaItemId).dataOrThrow()
            // 下一集要播哪个文件（字幕预热的落点）：服务端选版的逻辑客户端看不见，
            // 取第一个在位文件——多版本剧集可能预热到另一个版本，代价是多读一次，不伤正确性
            fun fileIdOf(season: Int, episode: Int): Long? = detail.files
                .firstOrNull {
                    it.seasonNumber == season && it.episodeNumber == episode &&
                        !it.missing && it.state == "in_place"
                }
                ?.id
            val seasons = detail.seasons
            val current = api.seasonEpisodes(target.libraryId, target.mediaItemId, target.seasonNumber).dataOrThrow()
            current.episodes
                .filter { it.owned && it.episodeNumber > target.episodeNumber }
                .minByOrNull { it.episodeNumber }
                ?.let {
                    UpNext(target.seasonNumber, it.episodeNumber, it.name.orEmpty(), fileIdOf(target.seasonNumber, it.episodeNumber))
                }
                ?: seasons.filter { it > target.seasonNumber }.minOrNull()?.let { nextSeason ->
                    api.seasonEpisodes(target.libraryId, target.mediaItemId, nextSeason).dataOrThrow()
                        .episodes
                        .filter { it.owned }
                        .minByOrNull { it.episodeNumber }
                        ?.let { UpNext(nextSeason, it.episodeNumber, it.name.orEmpty(), fileIdOf(nextSeason, it.episodeNumber)) }
                }
        }.getOrNull()
    }

    suspend fun episodeSeasons(target: PlayTarget): List<Int> {
        val origin = sessionRepository.ui.value.origin ?: error("尚未连接服务器")
        return (apiFactory.forOrigin(origin).libraryItemDetail(target.libraryId, target.mediaItemId)
            .dataOrThrow().seasons + target.seasonNumber).distinct().sorted()
    }

    suspend fun seasonEpisodes(target: PlayTarget, season: Int): List<EpisodeView> {
        val origin = sessionRepository.ui.value.origin ?: error("尚未连接服务器")
        return apiFactory.forOrigin(origin).seasonEpisodes(target.libraryId, target.mediaItemId, season)
            .dataOrThrow().episodes.sortedBy { it.episodeNumber }
    }

    fun playNext(upNext: UpNext) {
        val current = holder.state.value as? PlaybackSessionHolder.State.Playing ?: return
        val target = current.controller.target
        holder.open(
            PlayTarget(
                mediaItemId = target.mediaItemId,
                libraryId = target.libraryId,
                kind = target.kind,
                title = target.title,
                subtitle = "第 ${upNext.seasonNumber} 季 第 ${upNext.episodeNumber} 集" +
                    (if (upNext.label.isNotEmpty()) " · ${upNext.label}" else ""),
                seasonNumber = upNext.seasonNumber,
                episodeNumber = upNext.episodeNumber,
            )
        )
    }

    fun grantConsent() = holder.grantConsent()
    fun exit() = holder.exit()

    /**
     * 取一条字幕的原始内容（供 libass 渲染）。token 用会话流地址里的签名令牌。
     * 失败返回 null —— 调用方据此回落到 Exo 自带字幕，保证"最差也能看"。
     * `startMs/endMs`（文件时间）= 只要这一段（内封轨的窗口抽取，几秒回来）。
     */
    suspend fun loadSubtitleContent(
        fileId: Long,
        track: String,
        token: String,
        startMs: Long? = null,
        endMs: Long? = null,
    ): ByteArray? {
        val origin = sessionRepository.ui.value.origin ?: return null
        // 必须切到 IO：Retrofit 的 suspend 函数把响应交回调用方调度器（主线程），
        // 而 ResponseBody.bytes() 是阻塞读取 —— 主线程上会抛 NetworkOnMainThreadException（实机踩过）
        return kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching {
                // 走播放专用通道：字幕整轨可达几 MB，别和页面请求互相排队
                apiFactory.playbackForOrigin(origin).subtitleContent(
                    fileId = fileId,
                    track = track,
                    token = token,
                    startMs = startMs,
                    endMs = endMs,
                ).bytes()
            }.onFailure {
            // 之前这里静默吞异常，导致"取不到字幕"完全没线索（实机踩过）
                android.util.Log.w("McAss", "取字幕失败 file=$fileId track=$track: ${it::class.java.simpleName}: ${it.message}")
            }.getOrNull()
        }
    }

    /**
     * 预热一条内封字幕轨（当前集与下一集通用）：服务端登记后后台抽取、落缓存，
     * **不随请求断开取消**——快速切集/离开播放页不再把读过的一半丢掉、下次又冷读 40 秒。
     * 预热不该有存在感：只记一行日志，失败不打扰用户。
     */
    suspend fun warmSubtitle(fileId: Long, track: String) {
        val origin = sessionRepository.ui.value.origin ?: return
        runCatching {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                apiFactory.forOrigin(origin).subtitlePreview(fileId = fileId, track = track).dataOrThrow()
            }
        }.onSuccess {
            android.util.Log.i("McAss", "字幕预热已发起 file=$fileId track=$track")
        }.onFailure {
            android.util.Log.i("McAss", "字幕预热未发起 file=$fileId track=$track: ${it.message}")
        }
    }

    /** 画质档位(iOS:上限语义,不是目标;iOS 文案照搬) */
    data class QualityOption(val height: Int?, val label: String, val hint: String)

    fun qualityOptions(): List<QualityOption> = listOf(
        QualityOption(null, "自动", "原画质优先,能直通不转码"),
        QualityOption(1080, "1080p", "约 6 Mbps"),
        QualityOption(720, "720p", "约 3 Mbps,网络一般时选它"),
        QualityOption(480, "480p", "约 1.5 Mbps,弱网救急"),
    )

    fun currentQualityCap(): Int? = (holder.state.value as? PlaybackSessionHolder.State.Playing)
        ?.controller?.qualityCap?.value

    /** 换画质:从当前位置重开会话;并写入画质记忆 */
    fun selectQuality(option: QualityOption) {
        holder.changeQuality(option.height)
    }
}

@Composable
fun PlayerScreen(onExit: () -> Unit, vm: PlayerViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    val upNext by vm.upNext.collectAsStateWithLifecycle()
    val subStyle by vm.subtitleStyle.collectAsStateWithLifecycle()
    // 上次手势记下的播放页亮度（本机）：进页套上，退出仍把系统亮度还回去
    val brightnessMemory by vm.playerBrightness.collectAsStateWithLifecycle()

    val activity = androidx.activity.compose.LocalActivity.current
    DisposableEffect(Unit) {
        val previous = activity?.requestedOrientation
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        // 沉浸式：播放页要满屏，手机的状态栏与手势条也得收起来
        // （退出播放时原样恢复）。系统栏隐藏后从边缘划入会临时浮出，
        // 与 iOS 的全屏播放器一致。
        val window = activity?.window
        val controller = window?.let { androidx.core.view.WindowCompat.getInsetsController(it, it.decorView) }
        val previousBehavior = controller?.systemBarsBehavior
        controller?.systemBarsBehavior =
            androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller?.hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
        onDispose {
            controller?.systemBarsBehavior = previousBehavior
                ?: androidx.core.view.WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
            controller?.show(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            activity?.requestedOrientation = previous ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }
    BackHandler { vm.exit(); onExit() }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when (val s = state) {
            PlaybackSessionHolder.State.Idle -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("播放已结束", style = McType.footnote, color = TextMuted)
            }
            PlaybackSessionHolder.State.Preparing -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = Accent)
                    Spacer(Modifier.height(12.dp))
                    Text("正在与服务器协商播放方案…", style = McType.footnote, color = TextMuted)
                }
            }
            is PlaybackSessionHolder.State.Consent -> ConsentPane(
                reason = s.reason,
                costHint = s.costHint,
                onGrant = vm::grantConsent,
                onCancel = { vm.exit(); onExit() },
            )
            is PlaybackSessionHolder.State.Failed -> FailedPane(
                message = s.message,
                suggestion = s.suggestion,
                onBack = { vm.exit(); onExit() },
            )
            is PlaybackSessionHolder.State.Playing -> PlayingSurface(
                state = s,
                upNext = upNext,
                loadSubtitle = { f, t2, tk, s2, e2 -> vm.loadSubtitleContent(f, t2, tk, s2, e2) },
                warmSubtitle = { f, t2 -> vm.warmSubtitle(f, t2) },
                qualityOptions = vm.qualityOptions(),
                onSelectQuality = vm::selectQuality,
                onPlayNext = vm::playNext,
                loadSeasons = vm::episodeSeasons,
                loadEpisodes = vm::seasonEpisodes,
                onExit = { vm.exit(); onExit() },
                subStyle = subStyle,
                onSubStyle = vm::updateSubtitleStyle,
                brightnessMemory = brightnessMemory,
                onRememberBrightness = vm::rememberBrightness,
            )
        }
    }
}

private data class ScrubState(val baseMs: Long, val targetMs: Long)

private data class LevelHud(val brightness: Boolean, val level: Float, val generation: Long)

@Composable
private fun PlayingSurface(
    state: PlaybackSessionHolder.State.Playing,
    upNext: PlayerViewModel.UpNext?,
    /** 取字幕内容（由调用方注入，PlayingSurface 本身拿不到 VM）；后两个参数是窗口（文件时间毫秒） */
    loadSubtitle: suspend (Long, String, String, Long?, Long?) -> ByteArray?,
    /** 预热一条内封字幕轨（服务端后台抽取、请求断开也继续；由调用方注入） */
    warmSubtitle: suspend (Long, String) -> Unit,
    qualityOptions: List<PlayerViewModel.QualityOption>,
    onSelectQuality: (PlayerViewModel.QualityOption) -> Unit,
    onPlayNext: (PlayerViewModel.UpNext) -> Unit,
    loadSeasons: suspend (PlayTarget) -> List<Int>,
    loadEpisodes: suspend (PlayTarget, Int) -> List<EpisodeView>,
    onExit: () -> Unit,
    subStyle: io.movieclaw.android.core.playback.SubtitleStyle,
    onSubStyle: ((io.movieclaw.android.core.playback.SubtitleStyle) -> io.movieclaw.android.core.playback.SubtitleStyle) -> Unit,
    /** 上次手势调出来的播放页亮度（本机记忆）；PlayingSurface 拿不到 VM，从外面递进来 */
    brightnessMemory: Float?,
    onRememberBrightness: (Float) -> Unit,
) {
    val context = LocalContext.current
    val activity = androidx.activity.compose.LocalActivity.current
    val controller = state.controller
    val decision = state.session.decision
    val engineKind by controller.engineKind.collectAsStateWithLifecycle()
    val selectedAudioRef by controller.selectedAudioRef.collectAsStateWithLifecycle()
    val selectedSubtitleRef by controller.selectedSubtitleRef.collectAsStateWithLifecycle()

    var chromeVisible by remember { mutableStateOf(true) }
    var lastTapChromeState by remember { mutableStateOf(true) }
    var positionMs by remember { mutableLongStateOf(0L) }
    var durationMs by remember { mutableLongStateOf(0L) }
    var playing by remember { mutableStateOf(false) }
    var ended by remember { mutableStateOf(false) }
    var scrub by remember { mutableStateOf<ScrubState?>(null) }
    var levelHud by remember { mutableStateOf<LevelHud?>(null) }
    var holdSpeed by remember { mutableStateOf(false) }
    var upNextDismissed by remember { mutableStateOf(false) }
    // 自动连播（iOS autoNextArmed）：连续自动播了几集（任何用户操作清零）；倒计时进度 0...1
    var autoNextStreak by remember { mutableIntStateOf(0) }
    var autoNextProgress by remember { mutableFloatStateOf(0f) }
    var scrubbing by remember { mutableStateOf(false) }
    var adjusting by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf<String?>(null) }
    // 有菜单开着就**不许自动隐藏控制层**：菜单是控制层的子节点，控制层一收，
    // 菜单跟着消失——表现就是"没动它自己突然隐藏了"（用户反馈）
    var menuOpen by remember { mutableStateOf(false) }
    var episodePickerOpen by remember(controller) { mutableStateOf(false) }
    // 跳转后给读数一段宽限期：Exo 的 seek 不是瞬时完成，立刻读回来的还是**旧位置**，
    // 小球就会"跳回原处再挪过来"（用户原话"落点位置会跳"）。宽限期内先按落点显示，
    // 等播放器真的追上来（或超时）再交回真实读数。
    var pendingSeekMs by remember { mutableLongStateOf(-1L) }
    var seekGraceUntil by remember { mutableLongStateOf(0L) }
    fun seekTo(targetMs: Long) {
        val clamped = if (durationMs > 0) targetMs.coerceIn(0L, durationMs) else targetMs.coerceAtLeast(0L)
        pendingSeekMs = clamped
        seekGraceUntil = android.os.SystemClock.elapsedRealtime() + 2_500
        positionMs = clamped
        autoNextStreak = 0   // 用户操作清零自动连播计数（iOS 同语义）
        controller.seekToFileMs(clamped)
    }

    /** 相对跳转：基准取**播放器实时位置**（界面上的 positionMs 最多滞后 500 毫秒） */
    fun seekByRelative(deltaMs: Long) = seekTo(controller.filePositionMs() + deltaMs)

    val qualityOffer by controller.qualityOffer.collectAsStateWithLifecycle()
    var offerDismissed by remember { mutableStateOf(false) }
    LaunchedEffect(controller) { offerDismissed = false }

    // 锁屏(iOS PlayerScreen):锁上后碰哪儿都不响应,点一下才唤出「解锁」键,3 秒自己收起。
    // 播放器全程横屏(见 PlayerScreen 的方向锁),所以锁屏键恒可用。
    var locked by remember { mutableStateOf(false) }
    var lockHint by remember { mutableStateOf(false) }
    LaunchedEffect(locked, lockHint) {
        if (locked && lockHint) {
            delay(3000)
            lockHint = false
        }
    }
    LaunchedEffect(locked) {
        if (locked) {
            chromeVisible = false
            lockHint = true
        }
    }

    // 进入新单元时重置连播卡与结束标记
    LaunchedEffect(controller) {
        upNextDismissed = false
        ended = false
    }

    LaunchedEffect(state) {
        while (true) {
            val actual = controller.filePositionMs()
            val grace = android.os.SystemClock.elapsedRealtime() < seekGraceUntil
            val reached = pendingSeekMs < 0 || kotlin.math.abs(actual - pendingSeekMs) < 1_500
            if (!grace || reached) {
                pendingSeekMs = -1L
                positionMs = actual
            }   // 否则保持落点显示，别把小球拽回旧位置
            durationMs = controller.fileDurationMs()
            playing = controller.isPlaying()
            val nowEnded = controller.isEnded()
            if (nowEnded && !ended) {
                ended = true
                controller.reportEnded()
            }
            if (!nowEnded) ended = false
            delay(500)
        }
    }

    if (episodePickerOpen) {
        PlayerEpisodePicker(
            target = controller.target,
            loadSeasons = loadSeasons,
            loadEpisodes = loadEpisodes,
            onDismiss = { episodePickerOpen = false },
            onSelect = { season, episode ->
                episodePickerOpen = false
                onPlayNext(PlayerViewModel.UpNext(season, episode.episodeNumber, episode.name.orEmpty()))
            },
        )
    }

    // 控制层常显条件(iOS):暂停中 / 拖动中 / 调节中
    val mustStayVisible = !playing || scrubbing || adjusting || menuOpen || episodePickerOpen
    var chromeActivity by remember { mutableIntStateOf(0) }
    LaunchedEffect(chromeVisible, mustStayVisible, chromeActivity) {
        if (chromeVisible && !mustStayVisible) {
            delay(4000)
            chromeVisible = false
        }
    }
    LaunchedEffect(mustStayVisible) {
        if (mustStayVisible && !locked) chromeVisible = true
    }
    LaunchedEffect(notice) {
        if (notice != null) {
            delay(4000)
            notice = null
        }
    }
    LaunchedEffect(levelHud) {
        if (levelHud != null) {
            delay(1200)
            levelHud = null
        }
    }

    val audioManager = remember(context) { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    val initialBrightness = remember { activity?.window?.attributes?.screenBrightness }
    var maxVolume by remember { mutableFloatStateOf(audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).toFloat()) }
    var levelGeneration by remember { mutableLongStateOf(0L) }

    // 竖滑调整的**基准值**：在一次手势开始时取一次，之后用「基准 + 位移」算目标值。
    // 之前是每个事件都拿当前值再加一次累计位移（等于把位移算了 N 遍），所以「太敏感」、
    // 轻轻一划就冲到 0 或 100%（iOS `AdjustState(value, base)` 就是这里这个基准的用法）。
    var adjustBase by remember { mutableFloatStateOf(0f) }

    // 进播放页套上上次手势记下的亮度（本机记忆）；退出时仍把系统亮度还回去（iOS 同款）
    LaunchedEffect(brightnessMemory, activity) {
        brightnessMemory?.let { value ->
            activity?.window?.attributes = activity?.window?.attributes?.apply { screenBrightness = value }
        }
    }

    // 退出播放恢复进入前的屏幕亮度(iOS 同款)
    DisposableEffect(Unit) {
        onDispose {
            initialBrightness?.let { value ->
                activity?.window?.attributes = activity?.window?.attributes?.apply { screenBrightness = value }
            }
        }
    }

    var subVideoSize by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            // 尺寸采集放在这个「始终存在」的根 Box 上：叠层在未启用时会提前 return，
            // 挂在里面会导致回调永不触发（实机验过：自检一行日志都没有）
            .onSizeChanged { if (subVideoSize == androidx.compose.ui.unit.IntSize.Zero) subVideoSize = it },
    ) {
        when (engineKind) {
            EngineKind.EXO -> AndroidView(
                factory = { ctx -> PlayerView(ctx).apply { useController = false } },
                update = { it.player = controller.exoPlayer() },
                onRelease = { it.player = null },
                modifier = Modifier.fillMaxSize(),
            )
            EngineKind.MPV -> AndroidView(
                factory = { ctx -> controller.mpvSurfaceView() ?: SurfaceView(ctx) },
                modifier = Modifier.fillMaxSize(),
            )
        }

        // 方案 B：libass 字幕叠层 —— 画面由 Exo/mpv 渲染，字幕由 libass 画在其上。
        // 位置在「引擎画面」之后、「手势层/控件」之前：字幕在画面之上、控件之下。
        // 选中的字幕轨 → 取内容 → 转 ASS → 交给 libass；取不到就让 Exo 自己渲染
        var subCues by remember { mutableStateOf<List<io.movieclaw.android.core.playback.SubtitleCues.Cue>>(emptyList()) }
        // 拉回来的**原始**字幕按 ref 缓存：服务端抽取内封轨是"首次要通读整个容器"（实测
        // 一部片等了 28 秒），改一次字号/位置就重新拉一遍的话，用户每调一下都要再等半分钟。
        // 样式只在本地重跑 ASS 转换（毫秒级）。
        var rawSub by remember { mutableStateOf<Pair<String, ByteArray>?>(null) }
        var fetchingSubtitle by remember { mutableStateOf(false) }
        // 预热去重（当前集 + 下一集共用一把键）：同一个文件的一条轨只发起一次。
        // 纯记账、不参与渲染，所以用普通 Set 而不是 State（改了也不用重组）
        val warmedSubtitleKeys = remember { mutableSetOf<String>() }
        // 当前集的字幕预热：**故意独立于下面那条接线 effect**。接线 effect 的键（轨、画面尺寸）
        // 起播时会连着变两次，跟在里面发的预热会被立刻取消（实机日志：「预热未发起 …
        // The coroutine scope left the composition」）——键稳定下来才发得出去。
        LaunchedEffect(decision.fileId, selectedSubtitleRef) {
            val fid = decision.fileId ?: return@LaunchedEffect
            val ref = selectedSubtitleRef ?: return@LaunchedEffect
            if (ref == "off" || !ref.startsWith("embedded:")) return@LaunchedEffect
            // 位图轨（PGS）服务端抽不出文本、预热口子会 400，不白问
            if (decision.subtitles.any { it.trackRef == ref && it.kind == "pgs" }) return@LaunchedEffect
            if (!warmedSubtitleKeys.add("$fid:$ref")) return@LaunchedEffect
            warmSubtitle(fid, ref)
        }
        LaunchedEffect(selectedSubtitleRef, subVideoSize) {
            // 只认**手动选择**的字幕轨：之前"没选就自动挑第一条"是在瞎猜——
            // 内封第 0 条常常不是你要的那条（语言/内容/时间轴都可能对不上，实机被吐槽过）。
            // 没选时不做任何事，字幕交给 Exo 自己渲染（保证"至少是对的"）；
            // 用户在字幕菜单里选一条后，libass 才接管（也就不会有黑框）。
            val ref = selectedSubtitleRef
            val fileId = decision.fileId
            val token = io.movieclaw.android.core.playback.TrickplayProvider
                .extractToken(state.session.streamUrl ?: state.session.masterUrl.orEmpty())
            // 诊断：把三个输入与结果都打出来（libass 主路是否走通一眼可见）
            android.util.Log.i(
                "McAss",
                "字幕接线 ref=${ref ?: "null"} fileId=$fileId tokenLen=${token.length} size=${subVideoSize.width}x${subVideoSize.height}",
            )
            // "off" 不是一条轨：服务端对 track=off 会 404（实机日志抓到），别去问
            val usable = !ref.isNullOrEmpty() && ref != "off" && fileId != null &&
                token.isNotEmpty() && subVideoSize.width > 0
            var cues: List<io.movieclaw.android.core.playback.SubtitleCues.Cue> = emptyList()
            if (!usable) {
                // 没选轨 / 缺令牌 / 画面还没量好：什么都不做（引擎渲染开关在下面统一处理）
            } else if (rawSub?.first == ref) {
                // 同一条轨：直接用缓存（改字号/位置时不用再去拉一遍）
                cues = io.movieclaw.android.core.playback.SubtitleCues.parse(rawSub!!.second)
            } else {
                fetchingSubtitle = true
                // 内封轨的整轨要服务端**通读整个容器**（实测 5.7 GB / 39.7 秒），所以分两步：
                //  ① 后台预热由上面那条独立 effect 负责（不随断开取消，快速切集/离页不白读）；
                //  ② 这里先只要起播点附近一个窗口（几秒回来），把这一段字幕立刻画上；
                // 整轨到手后整表替换（时间戳都是文件时间，位置对齐，看不出换过）。
                if (ref.startsWith("embedded:")) {
                    val winStart = (state.session.startMs - SUBTITLE_PREROLL_MS).coerceAtLeast(0L)
                    val winStarted = android.os.SystemClock.elapsedRealtime()
                    val winBytes = loadSubtitle(fileId, ref, token, winStart, winStart + SUBTITLE_WINDOW_MS)
                    val winCues = winBytes?.let { io.movieclaw.android.core.playback.SubtitleCues.parse(it) }.orEmpty()
                    android.util.Log.i(
                        "McAss",
                        "窗口字幕 ${winCues.size} 条 ${winBytes?.size ?: 0} 字节，耗时 " +
                            "${android.os.SystemClock.elapsedRealtime() - winStarted} 毫秒",
                    )
                    if (winCues.isNotEmpty()) {
                        cues = winCues
                        subCues = winCues
                        // 这一段已经上屏：剩下的整轨是后台的活，「字幕加载中」到此为止
                        // （否则字幕明明显示着，进度条还挂一分钟——实机观感很怪）
                        fetchingSubtitle = false
                        // 叠层先接管：引擎要是也在画，两层叠着就是"带黑框"的观感（实机踩过）
                        runCatching { controller.setEngineSubtitleRendering(state.session.decision.disc == "image") }
                    }
                }
                val started = android.os.SystemClock.elapsedRealtime()
                val loaded = loadSubtitle(fileId, ref, token, null, null)
                android.util.Log.i(
                    "McAss",
                    "字幕内容到手 ${loaded?.size ?: 0} 字节，耗时 ${android.os.SystemClock.elapsedRealtime() - started} 毫秒",
                )
                fetchingSubtitle = false
                loaded?.also { rawSub = ref to it }
                // 整轨解析出的 cue 整表替换；空表（真的没台词 / 解析不出）保留窗口那一段
                val full = loaded?.let { io.movieclaw.android.core.playback.SubtitleCues.parse(it) }.orEmpty()
                if (full.isNotEmpty()) cues = full
            }
            android.util.Log.i("McAss", "字幕接线结果 cue=${cues.size} 条（0 = 回落引擎渲染）")
            subCues = cues
            // 关键：libass 接管字幕时必须**关掉引擎自己的字幕输出**，否则两层叠着画——
            // 上层是引擎的（带黑框），看起来就像"libass 也没去掉黑框"（实机踩过）。
            // 两个内核的关法不同（Exo 关文本轨类型 / mpv 关 sub-visibility），统一交给 controller。
            // **引擎一律不画字幕**：Exo 是按字幕文件自带的样式画的（`{ord20\shad0c...}`
            // 这类内联覆盖会一起上屏），那就是用户看到"带黑框"的来源。宁可这一条不显示，
            // 也不让屏幕上出现文件自带的框——解析不出 cue 的情况会记录在日志里。
            runCatching {
                // 光盘镜像例外：服务端抽不了盘内字幕，本机叠层没有 cue，
                // 这时让 mpv 自己渲染（它是唯一读得到盘内 PGS/文本轨的引擎）
                controller.setEngineSubtitleRendering(state.session.decision.disc == "image")
                android.util.Log.i(
                    "McAss",
                    if (cues.isEmpty()) "引擎字幕渲染 = 关闭（本机叠层无 cue，这一条不显示）"
                    else "引擎字幕渲染 = 关闭（交给本机叠层）",
                )
            }
        }
        // 载入提示：内封轨首次抽取要通读整个容器（大文件分钟级；服务端会缓存）。
        // 窗口那一段（几秒）到了就先把字幕画上台面，所以这个提示只在"一句都还没有"时出现；
        // 文案就四个字——慢的原因写日志里，不塞给用户。
        if (fetchingSubtitle) {
            Row(
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 140.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.Black.copy(alpha = 0.7f))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text("字幕加载中", style = McType.caption, color = Color.White)
            }
        }

        SubtitleOverlayLayer(
            currentPositionMs = { controller.filePositionMs() },
            videoSize = subVideoSize,
            cues = subCues,
            // 解析出 cue 就自己画（无黑框）；解析不出自动让引擎渲染
            enabled = subCues.isNotEmpty(),
            style = subStyle,
            offsetMs = (subStyle.offsetSeconds * 1000f).toLong(),
            modifier = Modifier.fillMaxSize(),
        )


        // 手势层:位于控制层之下的兄弟节点 —— 控件上的触摸不会落到这里(iOS 的排除区等价物)
        Box(
            Modifier
                .fillMaxSize()
                .playerGestures(
                    enabled = !locked,
                    canHold = playing,
                    onTap = {
                        lastTapChromeState = chromeVisible
                        chromeVisible = if (mustStayVisible) true else !chromeVisible
                        chromeActivity += 1
                    },
                    onDoubleTap = { xRatio ->
                        chromeVisible = lastTapChromeState
                        when {
                            xRatio < 1f / 3f -> seekByRelative(-10_000)
                            xRatio > 2f / 3f -> seekByRelative(10_000)
                            else -> if (!mustStayVisible) chromeVisible = !chromeVisible
                        }
                        chromeActivity += 1
                    },
                    onScrubStart = {
                        scrubbing = true
                        scrub = ScrubState(controller.filePositionMs(), controller.filePositionMs())
                        chromeVisible = true
                    },
                    onScrubTo = { ratio ->
                        val base = scrub ?: ScrubState(controller.filePositionMs(), controller.filePositionMs())
                        val target = (base.baseMs + (ratio * PlayerGestureMath.FULL_SWEEP_SEEK_MS).toLong())
                            .coerceIn(0L, durationMs.coerceAtLeast(1L))
                        scrub = base.copy(targetMs = target)
                    },
                    onScrubEnd = {
                        scrub?.let { seekTo(it.targetMs) }
                        scrub = null
                        scrubbing = false
                    },
                    onAdjustStart = { brightness ->
                        adjusting = true
                        chromeVisible = true
                        chromeActivity += 1
                        // 基准只在手势开始时取一次（iOS 同款）：之后每个事件都是「基准 + 累计位移」
                        maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).toFloat()
                        adjustBase = if (brightness) {
                            val current = activity?.window?.attributes?.screenBrightness ?: 0.5f
                            if (current <= 0f) 0.5f else current
                        } else {
                            if (maxVolume <= 0f) 1f
                            else audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / maxVolume
                        }
                    },
                    onAdjust = { brightness, delta ->
                        levelGeneration += 1
                        if (brightness) {
                            val next = (adjustBase + delta).coerceIn(0.05f, 1f)
                            activity?.window?.attributes = activity?.window?.attributes?.apply { screenBrightness = next }
                            levelHud = LevelHud(true, next, levelGeneration)
                        } else {
                            val next = (adjustBase + delta).coerceIn(0f, 1f)
                            audioManager.setStreamVolume(
                                AudioManager.STREAM_MUSIC,
                                (next * maxVolume).toInt().coerceIn(0, maxVolume.toInt()),
                                0,
                            )
                            levelHud = LevelHud(false, next, levelGeneration)
                        }
                    },
                    onAdjustEnd = {
                        adjusting = false
                        // 手势结束记一次（不是每个事件都写盘）：下一部片子起播时套上同一个亮度
                        activity?.window?.attributes?.screenBrightness
                            ?.takeIf { it > 0f }
                            ?.let { onRememberBrightness(it) }
                    },
                    onHoldStart = {
                        holdSpeed = true
                        controller.setSpeed(HOLD_SPEED)
                        notice = "${HOLD_SPEED.toInt()}× 快进中"
                    },
                    onHoldEnd = {
                        if (holdSpeed) {
                            holdSpeed = false
                            controller.setSpeed(1f)
                            notice = null
                        }
                    },
                ),
        )

        // 倍速持有期间缓冲跟不上就自动退出(iOS:缓冲 < 1s 时退出并提示)
        LaunchedEffect(holdSpeed) {
            if (!holdSpeed) return@LaunchedEffect
            val player = controller.exoPlayer()
            while (holdSpeed) {
                delay(400)
                val buffered = runCatching { (player?.bufferedPosition ?: 0L) - controller.filePositionMs() }.getOrDefault(0L)
                if (player != null && buffered in 0..1_000) {
                    holdSpeed = false
                    controller.setSpeed(1f)
                    notice = "缓冲跟不上,已退出倍速"
                    break
                }
            }
        }

        // 定位预览(iOS:只显示,松手才跳;有 trickplay 时显示缩略图)
        scrub?.let { active ->
            val base = scrub
            Column(
                Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 72.dp)
                    .background(Color.Black.copy(alpha = 0.65f), RoundedCornerShape(10.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                var tile by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
                LaunchedEffect(active.targetMs / 1000) {
                    tile = controller.trickplayTile(active.targetMs)
                }
                tile?.let { bitmap ->
                    androidx.compose.foundation.Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .width(160.dp)
                            .heightIn(max = 120.dp)
                            .clip(RoundedCornerShape(6.dp)),
                    )
                    Spacer(Modifier.height(6.dp))
                }
                Text(
                    McFormat.clock(active.targetMs),
                    style = McType.title2,
                    color = Color.White,
                )
                Text(
                    "${McFormat.clock(active.targetMs)} / ${McFormat.clock(durationMs)}",
                    style = McType.caption2,
                    color = Color.White.copy(alpha = 0.6f),
                )
                Spacer(Modifier.height(6.dp))
                Box(
                    Modifier
                        .width(160.dp)
                        .height(3.dp)
                        .background(Color.White.copy(alpha = 0.25f), RoundedCornerShape(3.dp)),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth((active.targetMs.toFloat() / durationMs.coerceAtLeast(1L)).coerceIn(0f, 1f))
                            .height(3.dp)
                            .background(AccentStrong, RoundedCornerShape(3.dp)),
                    )
                }
            }
        }

        // 亮度/音量 HUD(iOS LevelBar:图标 + 条 + 百分比)
        levelHud?.let { hud ->
            Row(
                Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 72.dp)
                    .background(Color.Black.copy(alpha = 0.65f), RoundedCornerShape(999.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (hud.brightness) Icons.Rounded.Brightness6 else Icons.Rounded.VolumeUp,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(9.dp))
                Box(
                    Modifier
                        .width(96.dp)
                        .height(4.dp)
                        .background(Color.White.copy(alpha = 0.25f), RoundedCornerShape(4.dp)),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth(hud.level.coerceIn(0f, 1f))
                            .height(4.dp)
                            .background(Color.White, RoundedCornerShape(4.dp)),
                    )
                }
                Spacer(Modifier.width(9.dp))
                Text("${(hud.level * 100).toInt()}%", style = McType.caption, color = Color.White)
            }
        }

        // 操作提示(iOS flash:顶部玻璃条 4 秒)
        notice?.let { text ->
            Text(
                text,
                style = McType.footnote,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 24.dp)
                    .background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(999.dp))
                    .padding(horizontal = 14.dp, vertical = 7.dp),
            )
        }

        // 降质建议卡:最多一次;20 秒无操作自动消失;绝不自动切换(iOS QualitySuggestion)
        if (qualityOffer != null && !offerDismissed && !locked) {
            val offer = qualityOffer!!
            LaunchedEffect(offer) {
                delay(20_000)
                offerDismissed = true
                controller.dismissQualityOffer()
            }
            QualityOfferCard(
                offer = offer,
                onAccept = {
                    offerDismissed = true
                    controller.dismissQualityOffer()
                    onSelectQuality(PlayerViewModel.QualityOption(offer.recommendedHeight, "${offer.recommendedHeight}p", "根据实测网速建议"))
                },
                onKeep = {
                    offerDismissed = true
                    controller.dismissQualityOffer()
                },
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 76.dp, start = 24.dp, end = 24.dp),
            )
        }

        // ── 跳过片头/片尾（docs/design/skip-intro.md §5，逻辑照 iOS SkipSegments）──
        // 位置进区间（终点前 3s 前）出按钮，点了跳到区间尾；文案只按服务端类型走
        // （广告 / 预告 / 未分类各有各的，见 `controller.skipLabel`）。一直放到结尾的片尾不出
        // （交给连播卡）。片段模式/已播完/报错/要同意/锁屏都不给。不自动跳过（v1 拍板）。
        val activeSkip = remember(positionMs) { controller.activeSkipSegment() }
        // 「一直放到结尾」的片尾：连播卡提前到片尾起点就弹，不必等最后 40 秒
        val inFileOutro = remember(positionMs) { controller.isInFileOutro() }
        val remaining = durationMs - positionMs
        // 谁占右下角：照 iOS `SkipSegments.shouldShowUpNext` 的串行判断——播完必出卡；
        // **当前有可跳的段就不出卡**（手动跳过优先，免得「最后 40 秒」的卡盖住「跳过预告」）；
        // 认出结尾片尾提前出；否则最后 40 秒兜底。（此前这里是反的：出了卡才不出按钮。）
        val upNextShowing = upNext != null && !upNextDismissed && !locked &&
            (ended || (activeSkip == null && (inFileOutro || remaining in 1..40_000)))
        if (activeSkip != null && !locked && !ended && !upNextShowing) {
            Text(
                controller.skipLabel(activeSkip),
                style = McType.subheadlineSemibold,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 96.dp)
                    .clip(RoundedCornerShape(999.dp))
                    // iOS 是系统液态玻璃（`.buttonStyle(.glass)`）。播放页做不了真模糊：
                    // 视频在 SurfaceView 上（mpv / PlayerView 都是系统合成），Haze 抓不到它的像素；
                    // 所以取项目里那份「黑底等价」的玻璃（GlassCapsule 半透明灰底）+ 一圈淡白边。
                    .background(GlassCapsule)
                    .border(1.dp, Color.White.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
                    .clickable {
                        autoNextStreak = 0   // 任何用户操作都清零连播计数（iOS noteUserActivity）
                        seekTo(activeSkip.endMs)
                    }
                    .padding(horizontal = 17.dp, vertical = 9.dp),
            )
        }

        // 片尾连播卡（iOS PlayerUpNextCard）：T−40s、服务端认出的片尾起点、或已播完时出现。
        // 自动连播只在「服务端认出一直放到结尾的片尾」时武装（按最后 40 秒猜出来的片尾，
        // 字幕还没放完画面就被抢走）：8 秒倒计时、连播 ≤3 集、任何用户操作清零（人半睡着时
        // 别让 NAS 白转一晚上）。倒计时 = 「立即播放」按钮本身的填充。
        if (upNextShowing) {
            val nextArmed = upNext != null && inFileOutro && autoNextStreak < 3 && !episodePickerOpen
            // A：片尾卡一露头就**预热下一集**的字幕（内封轨）。整轨要服务端通读整部片
            // （实测 5.7 GB / 39.7 秒），而卡最早只在结束前 40 秒出现——这段时间正好把
            // 下一集的抽取跑掉，切过去就是缓存命中（0.01 秒）。
            // 门槛：字幕开着且不是位图轨、此刻真的在播（暂停/卡顿时不抢盘）、每个文件只发一次。
            // 不管网络类型：读盘发生在服务端（NAS），手机上只为那几十 KB 字幕付流量，
            // 与"在流量上下整部片"是两回事。
            LaunchedEffect(upNextShowing, upNext?.fileId, selectedSubtitleRef, playing) {
                val nextFileId = upNext?.fileId ?: return@LaunchedEffect
                val ref = selectedSubtitleRef ?: return@LaunchedEffect
                if (!playing || !ref.startsWith("embedded:")) return@LaunchedEffect
                // 位图轨（PGS）服务端抽不出文本、预热口子会 400，不白问
                if (decision.subtitles.any { it.trackRef == ref && it.kind == "pgs" }) return@LaunchedEffect
                if (!warmedSubtitleKeys.add("$nextFileId:$ref")) return@LaunchedEffect
                kotlinx.coroutines.delay(3_000)          // 卡刚出现时正在换段/收尾，让出这几秒
                if (!playing) return@LaunchedEffect
                warmSubtitle(nextFileId, ref)
            }
            // 倒计时的钟：挂在卡片上（iOS 同款）——卡片收起 / 换集 / 拖出片尾，循环随之取消。
            // 语义照 iOS `advanceAutoNext`：**暂停冻住、播完照走**；未武装时进度清零。
            // 进度按**帧时钟**推进，每帧只加「这一帧真实流逝的时间」（暂停的那一帧不加）：
            // 早先是 100 毫秒跳 1/80，一格一格看得见台阶（用户反馈「不丝滑」）。
            LaunchedEffect(upNextShowing, inFileOutro, upNext?.episodeNumber, upNextDismissed, locked, episodePickerOpen) {
                autoNextProgress = 0f
                if (!nextArmed) return@LaunchedEffect
                var lastFrameNs: Long? = null
                while (true) {
                    withFrameNanos { frameNs ->
                        val prevNs = lastFrameNs
                        lastFrameNs = frameNs
                        if (prevNs != null && (playing || ended)) {
                            autoNextProgress =
                                (autoNextProgress + (frameNs - prevNs) / 8_000_000_000f).coerceAtMost(1f)
                        }
                    }
                    if (!(inFileOutro && autoNextStreak < 3)) return@LaunchedEffect
                    if (autoNextProgress >= 1f) {
                        autoNextProgress = 0f
                        autoNextStreak += 1
                        onPlayNext(upNext)
                        return@LaunchedEffect
                    }
                }
            }
            // 进度读取器：进度每帧都在变，在这里读值会把整个播放页拖进每帧重组；
            // 推迟到卡片内部读，只有卡片里真用到它的那几个节点跟着动（丝滑的另一半）。
            val autoNextProgressReader = { autoNextProgress }
            UpNextCard(
                upNext = upNext,
                countdown = if (nextArmed) autoNextProgressReader else null,
                onPlay = {
                    autoNextStreak = 0                     // 用户操作清零（iOS noteUserActivity）
                    upNextDismissed = false
                    onPlayNext(upNext)
                },
                onDismiss = {
                    autoNextStreak = 0
                    upNextDismissed = true
                },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 120.dp),
            )
        }

        // 横屏锁屏键:左缘竖直居中(左手拇指落点),与控制层同时出现,锁上后换成解锁键
        if (chromeVisible && !locked) {
            Row(
                Modifier
                    .fillMaxSize()
                    .padding(start = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                GlassRoundButton(Icons.Rounded.Lock, "锁屏") {
                    locked = true
                    lockHint = true
                }
            }
        }

        // 锁屏遮罩:盖住并吃掉所有触摸;点一下只唤出解锁键(与锁屏键同一位置,不用满屏找)
        if (locked) {
            Box(
                Modifier
                    .fillMaxSize()
                    .pointerInput(Unit) { detectTapGestures(onTap = { lockHint = true }) },
            ) {
                if (lockHint) {
                    Row(
                        Modifier.fillMaxSize().padding(start = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        GlassRoundButton(Icons.Rounded.LockOpen, "解锁") {
                            locked = false
                            lockHint = false
                            chromeVisible = true
                        }
                    }
                }
            }
        }

        if (chromeVisible) {
            Column(Modifier.fillMaxSize()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.65f), Color.Transparent)))
                        // 横屏顶部没有安全区,顶距留 16 与左右边距一致(iOS PlayerLayout.topInset)
                        .padding(horizontal = 16.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = onExit) {
                        Icon(
                            Icons.AutoMirrored.Rounded.ArrowBack,
                            contentDescription = "退出横屏",
                            tint = Color.White,
                        )
                    }
                    Column(Modifier.weight(1f)) {
                        Text(
                            controller.target.title,
                            style = McType.subheadlineSemibold,
                            color = Color.White,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        controller.target.subtitle?.let {
                            Text(it, style = McType.caption, color = Color.White.copy(alpha = 0.65f), maxLines = 1)
                        }
                    }
                    QualityMenuButton(
                        controller = controller,
                        engineKind = engineKind,
                        options = qualityOptions,
                        onSelect = onSelectQuality,
                        decision = decision,
                        onExpandedChange = { menuOpen = it },
                    )
                    IconButton(onClick = {
                        activity?.enterPictureInPictureMode(
                            PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()
                        )
                    }) {
                        Icon(Icons.Rounded.PictureInPictureAlt, contentDescription = "画中画", tint = Color.White)
                    }
                    TierChip(decision)
                }
                Spacer(Modifier.weight(1f))
                val shownMs = scrub?.targetMs ?: positionMs
                val totalMs = durationMs.coerceAtLeast(1L)
                val fraction = (shownMs.toFloat() / totalMs.toFloat()).coerceIn(0f, 1f)
                Column(
                    Modifier
                        .fillMaxWidth()
                        .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.78f))))
                        .padding(top = 8.dp, bottom = 12.dp),
                ) {
                    PlayerBottomControls(
                        series = controller.target.kind == "tv",
                        hasNext = upNext != null,
                        onNext = { upNext?.let { autoNextStreak = 0; onPlayNext(it) } },
                        onEpisodes = { episodePickerOpen = true; autoNextStreak = 0 },
                        tracks = {
                            TrackMenuButton(
                                icon = Icons.Rounded.GraphicEq,
                                label = "音轨",
                                options = controller.audioOptions(),
                                selectedRef = selectedAudioRef,
                                includeOff = false,
                                onSelect = controller::selectAudio,
                                onExpandedChange = { menuOpen = it },
                            )
                            TrackMenuButton(
                                icon = Icons.Rounded.ClosedCaption,
                                label = "字幕",
                                options = controller.subtitleOptions(),
                                selectedRef = selectedSubtitleRef,
                                includeOff = true,
                                onSelect = controller::selectSubtitle,
                                onExpandedChange = { menuOpen = it },
                                // 样式行**永远显示**：以前按"有没有选中字幕"决定显不显示，
                                // 关闭字幕时菜单就只剩上半截，看着像没显示全（用户反馈）
                                styleEditor = {
                                    SubtitleStyleEditor(
                                        style = subStyle,
                                        onChange = onSubStyle,
                                        subtitleActive = !selectedSubtitleRef.isNullOrEmpty() && selectedSubtitleRef != "off",
                                    )
                                },
                            )
                        },
                        speed = { SpeedChip(controller) },
                    )
                    Spacer(Modifier.height(10.dp))
                    // 进度条（实测：左右内距 35、轨 3px 白 30%、句柄 11 白点）
                    // BoxWithConstraints：句柄要按**真实条宽**摆，不能按固定 dp 猜
                    BoxWithConstraints(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 35.dp)
                            .height(14.dp)
                            // 点按 = 直接跳；**拖动 = 跟手预览，松手才跳**（iOS PlayerProgressBar 同款）。
                            // 旧版只有 tap：在条上拖动等于什么都没发生（tap 手势一移动就取消），
                            // 用户以为"拖了但位置不对"。
                            .pointerInput(totalMs) {
                                detectTapGestures { offset ->
                                    val target = (offset.x / size.width).coerceIn(0f, 1f) * totalMs
                                    seekTo(target.toLong())
                                }
                            }
                            .pointerInput(totalMs) {
                                detectHorizontalDragGestures(
                                    onDragStart = { offset ->
                                        val target = (offset.x / size.width).coerceIn(0f, 1f) * totalMs
                                        scrubbing = true
                                        scrub = ScrubState(target.toLong(), target.toLong())
                                        chromeVisible = true
                                    },
                                    onDragEnd = {
                                        scrub?.let { seekTo(it.targetMs) }
                                        scrub = null
                                        scrubbing = false
                                    },
                                    onDragCancel = {
                                        scrub = null
                                        scrubbing = false
                                    },
                                ) { change, _ ->
                                    val x = change.position.x.coerceIn(0f, size.width.toFloat())
                                    val target = (x / size.width) * totalMs
                                    val base = scrub ?: ScrubState(target.toLong(), target.toLong())
                                    scrub = base.copy(targetMs = target.toLong().coerceIn(0L, totalMs))
                                    change.consume()
                                }
                            },
                    ) {
                        val handleSize = 11.dp
                        // 条宽 = 容器宽（内距已由 padding 去掉）。句柄的位移必须按它换算：
                        // 旧版写的是 `fraction * 100.dp` —— 条宽 ~1000dp 时小球只在前 100dp 里挪，
                        // 看起来就是"进度条小球不随着动"（实机反馈）。
                        val travel = maxWidth - handleSize
                        Box(
                            Modifier
                                .align(Alignment.CenterStart)
                                .fillMaxWidth()
                                .height(3.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(Color.White.copy(alpha = 0.3f)),
                        )
                        Box(
                            Modifier
                                .align(Alignment.CenterStart)
                                .fillMaxWidth(fraction)
                                .height(3.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(AccentStrong),
                        )
                        // 片头结束点与播放位置使用相同的文件时间和条宽；没有识别结果就不画。
                        if (totalMs > 0) {
                            state.session.segments.orEmpty().filter {
                                it.type == "intro" && it.startMs >= 0 && it.endMs > it.startMs && it.endMs < totalMs
                            }.forEach { segment ->
                                val markerSize = 5.dp
                                Box(
                                    Modifier.align(Alignment.CenterStart)
                                        .offset(x = travel * (segment.endMs.toFloat() / totalMs) + (handleSize - markerSize) / 2)
                                        .size(markerSize).clip(CircleShape).background(Color.White),
                                )
                            }
                        }
                        Box(
                            Modifier
                                .align(Alignment.CenterStart)
                                .offset(x = travel * fraction)
                                .size(handleSize)
                                .clip(CircleShape)
                                .background(Color.White),
                        )
                    }
                    Spacer(Modifier.height(6.dp))
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 35.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(McFormat.clock(shownMs), style = McType.caption, color = Color.White.copy(alpha = 0.7f))
                        Spacer(Modifier.weight(1f))
                        Text(
                            McFormat.clock(totalMs),
                            style = McType.caption,
                            color = Color.White.copy(alpha = 0.7f),
                        )
                    }
                }
            }
            PlayerCenterControls(
                playing = playing,
                onToggle = { autoNextStreak = 0; controller.setPlaying(!playing) },
                onSeekBack = { autoNextStreak = 0; seekByRelative(-10_000) },
                onSeekForward = { autoNextStreak = 0; seekByRelative(10_000) },
                modifier = Modifier.align(Alignment.Center),
            )
        }
    }
}


/**
 * 中央走带区（iOS 同款）：后退 10 秒 · 播放/暂停 · 前进 10 秒，整组在画面正中，
 * 玻璃底与左缘锁屏键一致（38% 黑），亮画面上也看得清。
 */
@Composable
internal fun PlayerCenterControls(
    playing: Boolean,
    onToggle: () -> Unit,
    onSeekBack: () -> Unit,
    onSeekForward: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(36.dp),
    ) {
        CenterGlassButton(Icons.Rounded.Replay10, "后退 10 秒", 56.dp, 30.dp, onSeekBack)
        CenterGlassButton(
            if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
            if (playing) "暂停" else "播放",
            72.dp, 40.dp, onToggle,
        )
        CenterGlassButton(Icons.Rounded.Forward10, "前进 10 秒", 56.dp, 30.dp, onSeekForward)
    }
}

@Composable
private fun CenterGlassButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    size: androidx.compose.ui.unit.Dp,
    iconSize: androidx.compose.ui.unit.Dp,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .size(size)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.38f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = Color.White, modifier = Modifier.size(iconSize))
    }
}

/**
 * 进度条上方的工具行：左胶囊 = 音轨 / 字幕，右胶囊 = 下一集 / 选集 / 倍速（电影只有倍速）。
 * 两侧与进度条共用 35dp 边距。
 */
@Composable
internal fun PlayerBottomControls(
    series: Boolean,
    hasNext: Boolean,
    onNext: () -> Unit,
    onEpisodes: () -> Unit,
    tracks: @Composable () -> Unit,
    speed: @Composable () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 35.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GlassPill { tracks() }
        Spacer(Modifier.weight(1f))
        GlassPill {
            if (series) {
                IconButton(onClick = onNext, enabled = hasNext) {
                    Icon(Icons.Rounded.SkipNext, contentDescription = "下一集",
                        tint = Color.White.copy(alpha = if (hasNext) 1f else 0.35f))
                }
                IconButton(onClick = onEpisodes) {
                    Icon(Icons.AutoMirrored.Rounded.PlaylistPlay, contentDescription = "选集", tint = Color.White)
                }
            }
            speed()
        }
    }
}

@Composable
private fun GlassPill(content: @Composable () -> Unit) {
    Row(
        Modifier
            .height(44.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.38f))
            .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) { content() }
}

/** 圆形玻璃图标键(锁屏/解锁):44 边 = 系统最小触控尺寸,玻璃底 38% 黑 */
@Composable
private fun GlassRoundButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.38f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

/**
 * 片尾连播卡（iOS `PlayerUpNextCard`）——手机横屏 = iOS「高度紧」那一档（紧凑款）：
 * 宽 252、圆角 26、内距 14、**不放剧照**；眉题「即将播放 · N 秒」（等宽数字、白 50%）、
 * 集号（白 70%）、集名（semibold、白、最多两行）；右上 ✕（可见圆 28、白 14% 底、触控 44）；
 * 底部「立即播放」——**黑字白底高 34 的胶囊，倒计时就是它上面的白色填充**（白 35% 底打满即换集），
 * 不倒计时是实心白。平板（高度不紧）才有左剧照 112×63，等安卓平板适配时按 iOS 的
 * `verticalSizeClass` 再补这一档（见 preview-player-skip-ios.html 的竖屏开关）。
 */
@Composable
private fun UpNextCard(
    upNext: PlayerViewModel.UpNext,
    /** 倒计时进度 0...1 的读取器；null = 不倒计时（实心白按钮）。
     *  传读取器不是传值：进度每帧在变，值在调用方读会把整个播放页拖进每帧重组 */
    countdown: (() -> Float)?,
    onPlay: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // 进度在这里读（每帧只重组这张卡自己），取一次给眉题和填充共用
    val progress = countdown?.invoke()?.coerceIn(0f, 1f)
    // iOS：眉题「即将播放 · N 秒」，秒数向上取整、最少 1
    val leftSec = progress?.let { kotlin.math.ceil((1f - it) * 8f).toInt().coerceAtLeast(1) }
    Column(
        modifier
            .width(252.dp)
            .clip(RoundedCornerShape(26.dp))
            // 播放页的玻璃只能是「黑底等价」（视频在 SurfaceView 上，Haze 抓不到像素）：
            // 近 iOS `Glass.regular + 黑 35%` 的观感——半透明深底 + 一圈白 12% 描边
            .background(Color(0xFF121316).copy(alpha = 0.55f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(26.dp))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(
                    if (leftSec != null) "即将播放 · $leftSec 秒" else "即将播放",
                    style = TextStyle(fontSize = 11.sp, fontFeatureSettings = "tnum"),
                    color = Color.White.copy(alpha = 0.5f),
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    "第 ${upNext.episodeNumber} 集",
                    style = McType.caption,
                    color = Color.White.copy(alpha = 0.7f),
                )
                if (upNext.label.isNotEmpty()) {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        upNext.label,
                        style = McType.subheadlineSemibold,
                        color = Color.White,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            // ✕：可见圆 28 + 触控 44（负 padding 把触控区往角上贴，不撑高排版——iOS 同款）
            Box(
                Modifier
                    .offset(x = 8.dp, y = (-8).dp)
                    .size(44.dp)
                    .clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(28.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("✕", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.8f))
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        // 立即播放：黑字、高 34、胶囊；倒计时 = 白 35% 底上白色左→右填充（iOS 同款）
        Box(
            Modifier
                .fillMaxWidth()
                .height(34.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(if (progress == null) Color.White else Color.White.copy(alpha = 0.35f))
                .clickable(onClick = onPlay),
            contentAlignment = Alignment.Center,
        ) {
            if (progress != null) {
                Box(
                    Modifier
                        .align(Alignment.CenterStart)
                        .fillMaxHeight()
                        .fillMaxWidth(progress)
                        .background(Color.White),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.Black, modifier = Modifier.size(15.dp))
                Text("立即播放", style = McType.caption, fontWeight = FontWeight.SemiBold, color = Color.Black)
            }
        }
    }
}

private const val HOLD_SPEED = 2f

/** 窗口字幕：起播点往前多要 10 秒（上集续播/跳片头的落点都盖得住） */
private const val SUBTITLE_PREROLL_MS = 10_000L

/** 窗口要多少：5 分钟就够——整轨通常 40 秒内到，这 5 分钟只是给"整轨还没好就往前拖"留余量
 *  （服务端上限 600 秒，超了会被截断；窗口越短读得越少、回来得越快） */
private const val SUBTITLE_WINDOW_MS = 300_000L

/** 降质建议卡(iOS PlayerQualityOfferView):窄卡、圆角 22、两个按钮 */
@Composable
private fun QualityOfferCard(
    offer: PlaybackController.QualityOffer,
    onAccept: () -> Unit,
    onKeep: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val measuredText = offer.measuredBps?.let { McFormat.speed(it) }.orEmpty()
    val requiredText = McFormat.speed(offer.requiredBps.toDouble())
    Column(
        modifier
            .width(420.dp)
            .background(Color.Black.copy(alpha = 0.78f), RoundedCornerShape(22.dp))
            .padding(16.dp),
    ) {
        Text("网速跟不上当前画质", style = McType.subheadlineSemibold, color = Color.White)
        Spacer(Modifier.height(6.dp))
        Text(
            buildString {
                if (measuredText.isNotEmpty() && requiredText.isNotEmpty()) {
                    append("实测约 $measuredText,这一版需要约 $requiredText。")
                }
                append("可以暂停攒一会缓冲再看,或改用 ${offer.recommendedHeight}p(服务端转码,画质会降低)。")
            },
            style = McType.footnote,
            color = Color.White.copy(alpha = 0.75f),
            lineHeight = 19.sp,
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onKeep, modifier = Modifier.weight(1f)) {
                Text("继续当前画质", style = McType.footnote, color = Color.White.copy(alpha = 0.85f))
            }
            Button(
                onClick = onAccept,
                shape = RoundedCornerShape(10.dp),
                colors = ButtonDefaults.buttonColors(containerColor = AccentStrong, contentColor = Color(0xFF0A0E12)),
                modifier = Modifier.weight(1f),
            ) {
                Text("改用 ${offer.recommendedHeight}p", style = McType.footnote)
            }
        }
    }
}

/** 画质菜单(iOS SettingsMenu):标题「画质」+ 四档上限 + 分隔线 + 播放引擎 */
@Composable
private fun QualityMenuButton(
    controller: PlaybackController,
    engineKind: EngineKind,
    options: List<PlayerViewModel.QualityOption>,
    onSelect: (PlayerViewModel.QualityOption) -> Unit,
    decision: PlaybackDecisionView,
    onExpandedChange: (Boolean) -> Unit = {},
) {
    var expanded by remember { mutableStateOf(false) }
    LaunchedEffect(expanded) { onExpandedChange(expanded) }
    val currentCap by controller.qualityCap.collectAsStateWithLifecycle()
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(Icons.Rounded.Tune, contentDescription = "画质", tint = Color.White)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            Text(
                "画质",
                style = McType.caption,
                color = io.movieclaw.android.core.designsystem.TextFaint,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
            )
            options.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(
                                option.label,
                                style = McType.subheadline,
                                color = if (option.height == currentCap) Accent else Color.Unspecified,
                            )
                            Text(option.hint, style = McType.caption2, color = io.movieclaw.android.core.designsystem.TextFaint)
                        }
                    },
                    onClick = {
                        expanded = false
                        if (option.height != currentCap) onSelect(option)
                    },
                )
            }
            androidx.compose.material3.HorizontalDivider(color = io.movieclaw.android.core.designsystem.LineColor)
            // 服务端的判据原文：档位标签只说得清"结果"，说不清"是谁顶上去的"
            // （容器 / 视频编码 / HDR / 音轨 / 画质上限），这一行是排"为什么在转码"的入口
            if (decision.reason.isNotBlank()) {
                Text(
                    decision.reason,
                    style = McType.caption2,
                    color = io.movieclaw.android.core.designsystem.TextFaint,
                    modifier = Modifier
                        .width(268.dp)
                        .padding(horizontal = 14.dp, vertical = 6.dp),
                )
            }
            if (controller.mpvAvailable) {
                DropdownMenuItem(
                    text = {
                        Column {
                            Text("播放引擎", style = McType.subheadline)
                            Text(
                                if (engineKind == EngineKind.MPV) "MPV(万能解码,兼容性最好)" else "Exo(硬解省电)",
                                style = McType.caption2,
                                color = io.movieclaw.android.core.designsystem.TextFaint,
                            )
                        }
                    },
                    onClick = {
                        expanded = false
                        controller.switchEngine(if (engineKind == EngineKind.MPV) EngineKind.EXO else EngineKind.MPV)
                    },
                )
            }
        }
    }
}

@Composable
private fun TrackMenuButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    options: List<PlaybackController.TrackOption>,
    selectedRef: String?,
    includeOff: Boolean,
    onSelect: (String) -> Unit,
    /** 字幕菜单尾部的外观编辑器（iOS SubtitleStyleEditor）：只在选中某条字幕时出现 */
    styleEditor: (@Composable () -> Unit)? = null,
    /** 菜单开合通知：开着的时候控制层不能自动收起（否则菜单会跟着消失） */
    onExpandedChange: (Boolean) -> Unit = {},
) {
    Box {
        var expanded by remember { mutableStateOf(false) }
        // 只认 expanded：任何关闭路径（点条目 / 点外面 / 返回键）都会经过它，
        // 手写调用迟早会漏一处，那样 menuOpen 会永远停 true、控制层再也不自动隐藏
        LaunchedEffect(expanded) { onExpandedChange(expanded) }
        IconButton(onClick = { expanded = true }) {
            Icon(icon, contentDescription = label, tint = Color.White)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            if (includeOff) {
                DropdownMenuItem(
                    text = { TrackRow("关闭字幕", selectedRef == null || selectedRef == "off") },
                    onClick = { onSelect("off"); expanded = false },
                )
            }
            options.forEach { option ->
                val reason = option.unavailableReason
                if (reason != null) {
                    // iOS 口径：拿不到/放不了的轨**置灰 + 写明原因**，而不是给一个点了没反应的选项
                    Column(
                        Modifier
                            .width(268.dp)
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                    ) {
                        Text(
                            option.label,
                            style = McType.subheadline,
                            color = io.movieclaw.android.core.designsystem.TextFaint,
                        )
                        Text(reason, style = McType.caption2, color = io.movieclaw.android.core.designsystem.TextFaint)
                    }
                } else {
                    DropdownMenuItem(
                        text = { TrackRow(option.label, option.ref == selectedRef) },
                        onClick = { onSelect(option.ref); expanded = false },
                    )
                }
            }
            styleEditor?.let {
                androidx.compose.material3.HorizontalDivider(color = io.movieclaw.android.core.designsystem.LineColor)
                // 这几行**不能**用 DropdownMenuItem：那是「点一下关菜单」，而样式是连续调节
                it()
            }
        }
    }
}

/**
 * 菜单里的一行轨：左侧固定列宽的对勾标"当前用的是这条"（iOS `PlayerMenuRow` 同款）。
 * 之前只把选中的字改成浅灰蓝（#CDD6E6）——和正文的白（#F3F5F9）几乎看不出差别，
 * 用户反馈"选中后再打开面板不知道选了哪个"。
 */
@Composable
private fun TrackRow(label: String, active: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(20.dp)) {
            Icon(
                Icons.Rounded.Check,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier
                    .size(16.dp)
                    .alpha(if (active) 1f else 0f),
            )
        }
        Spacer(Modifier.width(6.dp))
        Text(label, maxLines = 2)
    }
}

/**
 * 字幕外观（iOS `SubtitleStyleEditor`）：时间轴 ±0.1 秒（夹 ±30）、字号、位置、背景。
 * 行距 12、步进键 32 但触控区外扩到 44（相邻两行首尾相接、互不抢点，iOS 同款做法）。
 */
@Composable
private fun SubtitleStyleEditor(
    style: io.movieclaw.android.core.playback.SubtitleStyle,
    onChange: ((io.movieclaw.android.core.playback.SubtitleStyle) -> io.movieclaw.android.core.playback.SubtitleStyle) -> Unit,
    /** 当前有没有字幕在放：没有时这几行调了看不见效果，得说一句 */
    subtitleActive: Boolean,
) {
    Column(Modifier.width(268.dp).padding(horizontal = 12.dp, vertical = 4.dp)) {
        if (!subtitleActive) {
            Text(
                "选一条字幕后这些样式才生效",
                style = McType.caption2,
                color = io.movieclaw.android.core.designsystem.TextFaint,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
        SubStepRow(
            label = "时间轴",
            value = (if (style.offsetSeconds > 0) "+" else "") + String.format(java.util.Locale.US, "%.1f 秒", style.offsetSeconds),
            onMinus = { onChange { it.copy(offsetSeconds = io.movieclaw.android.core.playback.SubtitleStyle.clampOffset(it.offsetSeconds - io.movieclaw.android.core.playback.SubtitleStyle.OFFSET_STEP)) } },
            onPlus = { onChange { it.copy(offsetSeconds = io.movieclaw.android.core.playback.SubtitleStyle.clampOffset(it.offsetSeconds + io.movieclaw.android.core.playback.SubtitleStyle.OFFSET_STEP)) } },
        )
        SubStepRow(
            label = "字号",
            value = String.format(java.util.Locale.US, "%.1f", style.fontPercent),
            onMinus = { onChange { it.copy(fontPercent = io.movieclaw.android.core.playback.SubtitleStyle.clampFont(it.fontPercent - io.movieclaw.android.core.playback.SubtitleStyle.FONT_STEP)) } },
            onPlus = { onChange { it.copy(fontPercent = io.movieclaw.android.core.playback.SubtitleStyle.clampFont(it.fontPercent + io.movieclaw.android.core.playback.SubtitleStyle.FONT_STEP)) } },
        )
        SubStepRow(
            // iOS 只写"位置"，但那个 8% 是「距画面底边」的意思，不写清用户会问"为什么不是 0"
            label = "位置（距底）",
            value = "${style.bottomPercent.toInt()}%",
            onMinus = { onChange { it.copy(bottomPercent = io.movieclaw.android.core.playback.SubtitleStyle.clampPosition(it.bottomPercent - io.movieclaw.android.core.playback.SubtitleStyle.POSITION_STEP)) } },
            onPlus = { onChange { it.copy(bottomPercent = io.movieclaw.android.core.playback.SubtitleStyle.clampPosition(it.bottomPercent + io.movieclaw.android.core.playback.SubtitleStyle.POSITION_STEP)) } },
        )
        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("背景", style = McType.subheadline, color = Color.White.copy(alpha = 0.75f))
            Spacer(Modifier.weight(1f))
            androidx.compose.material3.Switch(
                checked = style.background,
                onCheckedChange = { next -> onChange { it.copy(background = next) } },
                colors = androidx.compose.material3.SwitchDefaults.colors(
                    checkedThumbColor = Color.White,
                    checkedTrackColor = AccentStrong,
                ),
            )
        }
        Text(
            "样式存本机，切换播放器也保留",
            style = McType.caption2,
            color = Color.White.copy(alpha = 0.4f),
        )
    }
}

@Composable
private fun SubStepRow(label: String, value: String, onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = McType.subheadline, color = Color.White.copy(alpha = 0.65f))
        Spacer(Modifier.weight(1f))
        SubStepButton(icon = "minus", description = "${label}减", onClick = onMinus)
        Text(
            value,
            style = McType.subheadline,
            color = Color.White.copy(alpha = 0.9f),
            modifier = Modifier.width(72.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        SubStepButton(icon = "plus", description = "${label}加", onClick = onPlus)
    }
}

@Composable
private fun SubStepButton(icon: String, description: String, onClick: () -> Unit) {
    val symbol = if (icon == "plus") Icons.Rounded.Add else Icons.Rounded.Remove
    Box(
        Modifier.size(32.dp).clip(CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(symbol, contentDescription = description, tint = Color.White, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun TierChip(decision: PlaybackDecisionView) {
    val tier = decision.tier ?: 0
    // 档位名照 iOS 的 tierLabels：**档 1 换壳直通、档 2 换壳+转音轨都不是"转码"**。
    // 旧版把所有非 0 档一律写成"转码"，用户看到的"全都在转码"有一大半是这么来的
    // （视频根本没重编，只是换了容器 / 转了一路音轨），也会把该不该转的排查方向带偏。
    val label = buildString {
        when (tier) {
            0 -> append("原画直出")
            1 -> append("换壳直通")
            2 -> append("换壳 · 转音轨")
            3 -> append("硬件转码")
            4 -> append("软件转码")
            else -> append("档 $tier")
        }
        if (tier >= 3) decision.video?.height?.let { append(" · ${it}p") }
        if (decision.video?.toneMap == true) append(" · 色调映射")
        decision.video?.burnSubtitle?.let { append(" · 字幕压制") }
    }
    val direct = tier <= 1
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(Color.White.copy(alpha = 0.14f), RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Box(
            Modifier
                .size(6.dp)
                .background(if (direct) Success else io.movieclaw.android.core.designsystem.Warning, CircleShape),
        )
        Spacer(Modifier.size(5.dp))
        Text(label, style = McType.caption2, color = Color.White)
    }
}

@Composable
private fun SpeedChip(controller: PlaybackController) {
    var expanded by remember { mutableStateOf(false) }
    var speed by remember { mutableStateOf(controller.currentSpeed()) }
    Box {
        TextButton(onClick = { expanded = true }) {
            Text("${speed}×", style = McType.caption, color = Color.White)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            listOf(0.75f, 1.0f, 1.25f, 1.5f, 2.0f, 3.0f).forEach { value ->
                DropdownMenuItem(
                    text = { Text("${value}×") },
                    onClick = {
                        speed = value
                        controller.setSpeed(value)
                        expanded = false
                    },
                )
            }
        }
    }
}

@Composable
private fun ConsentPane(reason: String, costHint: String?, onGrant: () -> Unit, onCancel: () -> Unit) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("需要开启软件转码") },
        text = {
            Column {
                Text(reason, style = McType.footnote, lineHeight = 20.sp)
                if (!costHint.isNullOrEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(costHint, style = McType.caption, color = TextMuted, lineHeight = 18.sp)
                }
            }
        },
        confirmButton = {
            Button(
                onClick = onGrant,
                colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF0A0E12)),
            ) { Text("开启并播放") }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("取消") } },
    )
}

@Composable
private fun FailedPane(message: String, suggestion: String?, onBack: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        GlassCard {
            Text("无法播放", style = McType.headline, color = Color.White)
            Spacer(Modifier.height(8.dp))
            Text(message, style = McType.footnote, color = Color.White.copy(alpha = 0.75f), lineHeight = 20.sp)
            if (!suggestion.isNullOrEmpty()) {
                Spacer(Modifier.height(6.dp))
                Text(suggestion, style = McType.caption, color = TextMuted, lineHeight = 18.sp)
            }
            Spacer(Modifier.height(14.dp))
            TextButton(onClick = onBack) { Text("返回", color = Accent) }
        }
    }
}
