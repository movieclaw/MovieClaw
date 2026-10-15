@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.feature.player

import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.ActivityInfo
import android.media.AudioManager
import android.util.Rational
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.clickable
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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.media3.ui.compose.ContentFrame
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.GlassCard
import androidx.compose.foundation.layout.heightIn
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.playback.PlaybackSessionHolder
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.core.model.generated.PlaybackDecisionView
import io.movieclaw.core.playback.Phase
import io.movieclaw.core.playback.PlaybackController
import io.movieclaw.core.playback.QualityOption
import io.movieclaw.core.playback.QualitySuggestion
import io.movieclaw.core.playback.SkipSegments
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 播放页是应用级会话（PlaybackSessionHolder）的视图：播放不随页面销毁停止，退到后台继续由 MediaSessionService 保活；
 * 显式返回（BackHandler）才结束会话并冲刷进度。
 *
 * 播放本身全在与 TV 共用的统一引擎（core PlaybackController）里：协商、起播、失败兜底（重连 / 改走服务端流 / 逐级降档）、
 * 上报、选轨与记忆、跳过片头片尾、下一集。这里只有手机的控制层：手势、锁屏、亮度音量、画中画、倍速、字幕外观。
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

    val state = holder.state

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

    /** 选集面板挑的一集：同一季交给控制器（换集、续播点、轨记忆都在引擎里）；换季则重开一次播放 */
    fun playEpisode(active: PlaybackSessionHolder.Active, currentSeason: Int, season: Int, episode: EpisodeView) {
        if (season == currentSeason) {
            active.controller.playEpisode(episode.episodeNumber.toLong())
            return
        }
        holder.open(
            active.target.copy(
                subtitle = "第 $season 季 第 ${episode.episodeNumber} 集" +
                    (episode.name?.takeIf { it.isNotEmpty() }?.let { " · $it" } ?: ""),
                seasonNumber = season,
                episodeNumber = episode.episodeNumber,
                preferredAudio = null,
                preferredSubtitle = null,
                startMs = null,
            ),
        )
    }

    fun exit() = holder.exit()
}

@Composable
fun PlayerScreen(onExit: () -> Unit, vm: PlayerViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
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
            PlaybackSessionHolder.State.Opening -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Accent)
            }
            is PlaybackSessionHolder.State.Failed -> FailedPane(
                message = s.message,
                suggestion = null,
                onRetry = null,
                onBack = { vm.exit(); onExit() },
            )
            is PlaybackSessionHolder.State.Playing -> PlayingSurface(
                active = s.active,
                onPlayEpisode = vm::playEpisode,
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

/** 菜单里的一条轨（音轨 / 字幕共用）：放不了的轨带原因，置灰显示 */
private data class TrackItem(val ref: String, val label: String, val unavailableReason: String? = null)

@Composable
private fun PlayingSurface(
    active: PlaybackSessionHolder.Active,
    onPlayEpisode: (PlaybackSessionHolder.Active, Int, Int, EpisodeView) -> Unit,
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
    val controller = active.controller
    val state by controller.state.collectAsStateWithLifecycle()
    val engineCues by controller.cues.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val trickplay = remember(controller) { TrickplayImages(active.http, scope, controller::resolve) }
    // 自动换集之后进来时的 target 就旧了：季、集以引擎当前单元为准
    val target = active.target.copy(seasonNumber = state.unit.season.toInt(), episodeNumber = state.unit.episode.toInt())
    val series = state.unit.isEpisode

    // 调了字幕时间轴：外挂文本字幕改由叠层按偏移画（Exo 解出的字幕时机挪不动）
    val timingAdjusted = subStyle.offsetSeconds != 0f
    LaunchedEffect(controller, timingAdjusted) { controller.setSubtitleTimingAdjusted(timingAdjusted) }

    // 后台（锁屏、切走）：手机接着放，引擎只停掉看门狗；回到前台探一次会话还在不在
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { controller.setBackgrounded(true) }
    LifecycleEventEffect(Lifecycle.Event.ON_START) { controller.setBackgrounded(false) }

    // 屏幕常亮：在放（或正要放）的时候；暂停久了让系统照常息屏
    val view = LocalView.current
    val keepOn = !state.paused || (state.wantsPlay && state.phase.isBusy)
    DisposableEffect(keepOn) {
        view.keepScreenOn = keepOn
        onDispose { view.keepScreenOn = false }
    }

    val positionMs = state.positionMs
    val durationMs = state.durationMs ?: 0L
    val playing = !state.paused

    var chromeVisible by remember { mutableStateOf(true) }
    var lastTapChromeState by remember { mutableStateOf(true) }
    var scrub by remember { mutableStateOf<ScrubState?>(null) }
    var levelHud by remember { mutableStateOf<LevelHud?>(null) }
    var holdSpeed by remember { mutableStateOf(false) }
    var scrubbing by remember { mutableStateOf(false) }
    var adjusting by remember { mutableStateOf(false) }
    var localNotice by remember { mutableStateOf<String?>(null) }
    // 有菜单开着就**不许自动隐藏控制层**：菜单是控制层的子节点，控制层一收，
    // 菜单跟着消失——表现就是"没动它自己突然隐藏了"（用户反馈）
    var menuOpen by remember { mutableStateOf(false) }
    var episodePickerOpen by remember(controller) { mutableStateOf(false) }

    fun seekTo(targetMs: Long) {
        val clamped = if (durationMs > 0) targetMs.coerceIn(0L, durationMs) else targetMs.coerceAtLeast(0L)
        controller.seekTo(clamped, exact = true, source = "scrub")
    }

    /** 相对跳转（双击两侧、±10 秒键）：按关键帧，快 */
    fun seekByRelative(deltaMs: Long) = controller.seekTo(controller.currentFileMs() + deltaMs, exact = false, source = "gesture")

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

    if (episodePickerOpen) {
        PlayerEpisodePicker(
            target = target,
            loadSeasons = loadSeasons,
            loadEpisodes = loadEpisodes,
            onDismiss = { episodePickerOpen = false },
            onSelect = { season, episode ->
                episodePickerOpen = false
                onPlayEpisode(active, target.seasonNumber, season, episode)
            },
        )
    }

    // 控制层常显条件(iOS):暂停中 / 拖动中 / 调节中
    val mustStayVisible = !playing || scrubbing || adjusting || menuOpen || episodePickerOpen
    var chromeActivity by remember { mutableLongStateOf(0L) }
    LaunchedEffect(chromeVisible, mustStayVisible, chromeActivity) {
        if (chromeVisible && !mustStayVisible) {
            delay(4000)
            chromeVisible = false
        }
    }
    LaunchedEffect(mustStayVisible) {
        if (mustStayVisible && !locked) chromeVisible = true
    }
    LaunchedEffect(localNotice) {
        if (localNotice != null) {
            delay(4000)
            localNotice = null
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

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        // 画面：统一引擎的播放器；ASS 特效字幕由 libass 画在它自己的叠加层上
        ContentFrame(player = controller.player, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit, keepContentOnReset = true)
        AndroidView(factory = controller::assOverlay, modifier = Modifier.fillMaxSize())

        // 文本 / 图形字幕：服务端流的文本字幕与直连时引擎解出的字幕，都按用户的字幕外观画
        SubtitleOverlayLayer(
            text = rememberVttText(state.overlaySubtitleUrl, active.http, controller::currentFileMs, subStyle.offsetSeconds),
            engineCues = engineCues,
            videoWidth = state.videoWidth,
            videoHeight = state.videoHeight,
            style = subStyle,
            modifier = Modifier.fillMaxSize(),
        )

        // 手势层:位于控制层之下的兄弟节点 —— 控件上的触摸不会落到这里(iOS 的排除区等价物)
        Box(
            Modifier
                .fillMaxSize()
                .playerGestures(
                    enabled = !locked && !state.isModal,
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
                        scrub = ScrubState(controller.currentFileMs(), controller.currentFileMs())
                        chromeVisible = true
                    },
                    onScrubTo = { ratio ->
                        val base = scrub ?: ScrubState(controller.currentFileMs(), controller.currentFileMs())
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
                        localNotice = "${HOLD_SPEED.toInt()}× 快进中"
                    },
                    onHoldEnd = {
                        if (holdSpeed) {
                            holdSpeed = false
                            controller.setSpeed(1f)
                            localNotice = null
                        }
                    },
                ),
        )

        // 倍速持有期间缓冲跟不上就自动退出(iOS:缓冲 < 1s 时退出并提示)
        LaunchedEffect(holdSpeed) {
            if (!holdSpeed) return@LaunchedEffect
            while (holdSpeed) {
                delay(400)
                val current = controller.state.value
                val buffered = (current.bufferedEndMs ?: 0L) - current.positionMs
                if (buffered in 0..1_000) {
                    holdSpeed = false
                    controller.setSpeed(1f)
                    localNotice = "缓冲跟不上,已退出倍速"
                    break
                }
            }
        }

        // 起播 / 换流 / 降档：说清楚卡在哪一段，带实时加载速度
        if (state.phase.isBusy && !state.isModal) {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(34.dp))
                Spacer(Modifier.height(10.dp))
                Text(state.phase.busyLabel, style = McType.footnote, color = Color.White.copy(alpha = 0.85f))
                state.speedLabel?.let {
                    Text(it, style = McType.caption2, color = Color.White.copy(alpha = 0.6f))
                }
            }
        }

        // 定位预览(iOS:只显示,松手才跳;有 trickplay 时显示缩略图)
        scrub?.let { activeScrub ->
            Column(
                Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 72.dp)
                    .background(Color.Black.copy(alpha = 0.65f), RoundedCornerShape(10.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                trickplay.tile(state.trickplay, activeScrub.targetMs)?.let { tile ->
                    androidx.compose.foundation.Image(
                        bitmap = tile,
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
                    McFormat.clock(activeScrub.targetMs),
                    style = McType.title2,
                    color = Color.White,
                )
                Text(
                    "${McFormat.clock(activeScrub.targetMs)} / ${McFormat.clock(durationMs)}",
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
                            .fillMaxWidth((activeScrub.targetMs.toFloat() / durationMs.coerceAtLeast(1L)).coerceIn(0f, 1f))
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

        // 操作提示(iOS flash:顶部玻璃条 4 秒)：本页的（倍速）优先，其次引擎的（沿用记忆、重连、改走服务端流…）
        (localNotice ?: state.notice)?.let { text ->
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

        // 降质建议卡:最多一次;20 秒无操作引擎自己收起;绝不自动切换(iOS QualitySuggestion)
        val offer = state.qualityOffer
        if (offer != null && !locked) {
            QualityOfferCard(
                offer = offer,
                onAccept = controller::acceptQualityOffer,
                onKeep = controller::dismissQualityOffer,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 76.dp, start = 24.dp, end = 24.dp),
            )
        }

        // ── 跳过片头/片尾（docs/design/skip-intro.md §5，判定在引擎 SkipSegments）──
        // 位置进区间（终点前 3s 前）出按钮，点了跳到区间尾；与「下一集」卡片不同时出现。不自动跳过（v1 拍板）。
        val skip = state.skipSegment
        if (skip != null && !locked) {
            Text(
                SkipSegments.label(skip),
                style = McType.subheadlineSemibold,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 96.dp)
                    .clip(RoundedCornerShape(999.dp))
                    // iOS 是系统液态玻璃（`.buttonStyle(.glass)`）。播放页做不了真模糊：
                    // 视频在 SurfaceView 上（系统合成），Haze 抓不到它的像素；
                    // 所以取项目里那份「黑底等价」的玻璃（GlassCapsule 半透明灰底）+ 一圈淡白边。
                    .background(GlassCapsule)
                    .border(1.dp, Color.White.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
                    .clickable(onClick = controller::skipCurrentSegment)
                    .padding(horizontal = 17.dp, vertical = 9.dp),
            )
        }

        // 片尾连播卡（iOS PlayerUpNextCard）：最后 40 秒、服务端认出的片尾起点、或已播完时出现。
        // 自动连播只在「服务端认出一直放到结尾的片尾」时武装：8 秒倒计时、连播 ≤3 集、任何用户操作清零
        // （人半睡着时别让 NAS 白转一晚上）。倒计时 = 「立即播放」按钮本身的填充。
        val next = state.nextEpisode
        if (state.showsUpNext && next != null && !locked) {
            val armed = state.autoNextArmed && !episodePickerOpen
            // 倒计时的钟挂在卡片上：卡片收起 / 换集 / 拖出片尾，循环随之取消。暂停冻住、播完照走（引擎里判）
            LaunchedEffect(armed, next.episodeNumber) {
                if (!armed) return@LaunchedEffect
                while (true) {
                    delay(100)
                    controller.advanceAutoNext(100)
                }
            }
            UpNextCard(
                episodeNumber = next.episodeNumber,
                label = next.name.orEmpty(),
                countdown = if (armed) state.autoNextProgress.toFloat() else null,
                onPlay = controller::playNext,
                onDismiss = controller::dismissUpNext,
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
            val decision = controller.decision
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
                            state.info?.title ?: active.target.title,
                            style = McType.subheadlineSemibold,
                            color = Color.White,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        (state.episodeLabel ?: active.target.subtitle)?.let {
                            Text(it, style = McType.caption, color = Color.White.copy(alpha = 0.65f), maxLines = 1)
                        }
                    }
                    QualityMenuButton(
                        current = state.quality,
                        reason = decision?.reason.orEmpty(),
                        onSelect = controller::selectQuality,
                        onExpandedChange = { menuOpen = it },
                    )
                    IconButton(onClick = {
                        val aspect = if (state.videoWidth > 0 && state.videoHeight > 0) {
                            Rational(state.videoWidth, state.videoHeight)
                        } else {
                            Rational(16, 9)
                        }
                        activity?.enterPictureInPictureMode(
                            // 系统只收 1:2.39～2.39:1 的比例，超出的（超宽银幕）按 16:9
                            PictureInPictureParams.Builder()
                                .setAspectRatio(aspect.takeIf { it.toFloat() in 0.42f..2.39f } ?: Rational(16, 9))
                                .build()
                        )
                    }) {
                        Icon(Icons.Rounded.PictureInPictureAlt, contentDescription = "画中画", tint = Color.White)
                    }
                    decision?.let { TierChip(it) }
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
                        series = series,
                        hasNext = state.nextEpisode != null,
                        onNext = controller::playNext,
                        onEpisodes = { episodePickerOpen = true; controller.noteUserActivity() },
                        tracks = {
                            TrackMenuButton(
                                icon = Icons.Rounded.GraphicEq,
                                label = "音轨",
                                options = state.audioOptions.map { TrackItem(it.ref, it.label, it.unavailableReason) },
                                selectedRef = state.currentAudio,
                                includeOff = false,
                                onSelect = controller::selectAudio,
                                onExpandedChange = { menuOpen = it },
                            )
                            TrackMenuButton(
                                icon = Icons.Rounded.ClosedCaption,
                                label = "字幕",
                                options = state.subtitles.options.map { TrackItem(it.ref, it.label) } +
                                    state.subtitles.unavailable.map { TrackItem(it.ref, it.label, it.reason) },
                                selectedRef = state.selectedSubtitle,
                                includeOff = true,
                                onSelect = { ref -> controller.selectSubtitle(ref.takeIf { it != "off" }) },
                                onExpandedChange = { menuOpen = it },
                                // 样式行**永远显示**：以前按"有没有选中字幕"决定显不显示，
                                // 关闭字幕时菜单就只剩上半截，看着像没显示全（用户反馈）
                                styleEditor = {
                                    SubtitleStyleEditor(
                                        style = subStyle,
                                        onChange = onSubStyle,
                                        subtitleActive = state.selectedSubtitle != null,
                                        // 直连时内封字幕由引擎解出，时机挪不动（外挂字幕调了时间轴会改由叠层画，可以调）
                                        timingFixed = state.engineSubtitles &&
                                            state.selectedSubtitle?.startsWith("embedded:") == true,
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
                            // 点按 = 直接跳；**拖动 = 跟手预览，松手才跳**（iOS PlayerProgressBar 同款）
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
                            state.segments.orEmpty().filter {
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
            if (!state.phase.isBusy) {
                PlayerCenterControls(
                    playing = playing,
                    onToggle = controller::togglePlay,
                    onSeekBack = { seekByRelative(-10_000) },
                    onSeekForward = { seekByRelative(10_000) },
                    modifier = Modifier.align(Alignment.Center),
                )
            }
        }

        // 错误页 / 要开启软件转码：盖在画面之上（引擎的错误都带原因与建议）
        when {
            state.infoError != null -> FailedPane(state.infoError!!, null, onRetry = null, onBack = onExit)
            state.phase == Phase.Error -> FailedPane(
                message = state.errorMessage ?: "无法播放",
                suggestion = state.errorSuggestion,
                onRetry = controller::retry,
                onBack = onExit,
            )
            state.phase == Phase.Consent -> state.pendingDecision?.let { pending ->
                var granting by remember(pending) { mutableStateOf(false) }
                var grantError by remember(pending) { mutableStateOf<String?>(null) }
                ConsentPane(
                    reason = pending.reason,
                    costHint = grantError ?: pending.costHint,
                    canGrant = controller.canGrantConsent && !granting,
                    onGrant = {
                        granting = true
                        scope.launch {
                            runCatching { controller.grantConsent() }
                                .onFailure { grantError = it.message ?: "开启失败，请重试" }
                            granting = false
                        }
                    },
                    onCancel = onExit,
                )
            }
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
    episodeNumber: Long,
    label: String,
    /** 倒计时进度 0...1（引擎的 autoNextProgress）；null = 不倒计时（实心白按钮） */
    countdown: Float?,
    onPlay: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val progress = countdown?.coerceIn(0f, 1f)
    // iOS：眉题「即将播放 · N 秒」，秒数向上取整、最少 1
    val countdownSeconds = SkipSegments.AUTO_NEXT_MS / 1000f
    val leftSec = progress?.let { kotlin.math.ceil((1f - it) * countdownSeconds).toInt().coerceAtLeast(1) }
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
                    "第 $episodeNumber 集",
                    style = McType.caption,
                    color = Color.White.copy(alpha = 0.7f),
                )
                if (label.isNotEmpty()) {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        label,
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

/** 降质建议卡(iOS PlayerQualityOfferView):窄卡、圆角 22、两个按钮 */
@Composable
private fun QualityOfferCard(
    offer: QualitySuggestion.Offer,
    onAccept: () -> Unit,
    onKeep: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // 引擎给的是比特每秒，格式化按字节每秒
    val measuredText = McFormat.speed(offer.measuredBps / 8)
    val requiredText = McFormat.speed(offer.requiredBps / 8)
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
                append("可以暂停攒一会缓冲再看,或改用 ${offer.maxHeight}p(服务端转码,画质会降低)。")
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
                Text("改用 ${offer.maxHeight}p", style = McType.footnote)
            }
        }
    }
}

/** 画质菜单(iOS SettingsMenu):标题「画质」+ 四档上限 + 分隔线 + 这一档的判据原文 */
@Composable
private fun QualityMenuButton(
    /** 当前画质上限（null = 原画） */
    current: Int?,
    /** 服务端的判据原文 */
    reason: String,
    onSelect: (Int?) -> Unit,
    onExpandedChange: (Boolean) -> Unit = {},
) {
    var expanded by remember { mutableStateOf(false) }
    LaunchedEffect(expanded) { onExpandedChange(expanded) }
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
            QualityOption.ALL.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(
                                option.label,
                                style = McType.subheadline,
                                color = if (option.maxHeight == current) Accent else Color.Unspecified,
                            )
                            Text(option.hint, style = McType.caption2, color = io.movieclaw.android.core.designsystem.TextFaint)
                        }
                    },
                    onClick = {
                        expanded = false
                        if (option.maxHeight != current) onSelect(option.maxHeight)
                    },
                )
            }
            // 服务端的判据原文：档位标签只说得清"结果"，说不清"是谁顶上去的"
            // （容器 / 视频编码 / HDR / 音轨 / 画质上限），这一行是排"为什么在转码"的入口
            if (reason.isNotBlank()) {
                androidx.compose.material3.HorizontalDivider(color = io.movieclaw.android.core.designsystem.LineColor)
                Text(
                    reason,
                    style = McType.caption2,
                    color = io.movieclaw.android.core.designsystem.TextFaint,
                    modifier = Modifier
                        .width(268.dp)
                        .padding(horizontal = 14.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun TrackMenuButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    options: List<TrackItem>,
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
    /** 当前字幕的时机由播放器定（直连时的内封轨）：时间轴这一行调了不生效，得说一句 */
    timingFixed: Boolean = false,
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
        if (timingFixed) {
            Text(
                "这条内封字幕由播放器直接解出，时间轴调整对它不生效",
                style = McType.caption2,
                color = io.movieclaw.android.core.designsystem.TextFaint,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
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
    val tier = (decision.tier ?: 0L).toInt()
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
    var speed by remember { mutableStateOf(controller.speed) }
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
private fun ConsentPane(reason: String, costHint: String?, canGrant: Boolean, onGrant: () -> Unit, onCancel: () -> Unit) {
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
                // 访客（分享观看）没有设置权，只能看说明
                enabled = canGrant,
                colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF0A0E12)),
            ) { Text("开启并播放") }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text("取消") } },
    )
}

@Composable
private fun FailedPane(message: String, suggestion: String?, onRetry: (() -> Unit)?, onBack: () -> Unit) {
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
            Row {
                // 重试：从刚才的位置接着放（引擎按失败处置重新开会话）
                onRetry?.let { retry -> TextButton(onClick = retry) { Text("重试", color = Accent) } }
                TextButton(onClick = onBack) { Text("返回", color = Accent) }
            }
        }
    }
}
