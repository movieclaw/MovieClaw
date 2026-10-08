@file:OptIn(UnstableApi::class)

package io.movieclaw.androidtv.ui.player

import android.view.KeyEvent as AndroidKeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.compose.ContentFrame
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.core.playback.PlaybackController
import io.movieclaw.androidtv.core.playback.PlaybackTarget
import io.movieclaw.androidtv.core.playback.Phase
import io.movieclaw.androidtv.core.playback.PlayerState
import io.movieclaw.androidtv.core.playback.PrefsStore
import io.movieclaw.androidtv.core.playback.ScrubMath
import io.movieclaw.androidtv.ui.shell.PlayRequest
import io.movieclaw.androidtv.ui.theme.pt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Android TV 的全屏播放器（照 Apple 端 MovieClawTV/Player/TVPlayerScreen.swift 一比一）。
 * 会话协议、兜底阶梯、上报、选轨记忆、下一集都在 [PlaybackController]，这里只有电视的控制层：
 *
 * | 遥控器 | 行为 |
 * |---|---|
 * | 确认键 / 播放暂停键 | 播放 / 暂停（暂停时显示进度条） |
 * | 点按左 / 右 | 后退 / 前进 10 秒（控制层收起时也行） |
 * | 按住左 / 右 | 拖动进度（Apple TV 是触控板横滑；安卓遥控器没有触控板）：带缩略图，松手跳过去 |
 * | 下 | 信息面板：字幕、音轨、画质 |
 * | 上 | 只显示控制层 |
 * | 返回 | 依次：取消拖动 → 收起面板 → 收起「下一集」卡片 → 收起换画质建议 → 退出播放 |
 * | 快进 / 快退 / 下一首 / 上一首键 | ±10 秒 / 下一集 / 上一集 |
 *
 * 片头片尾时段右下角出现「跳过」按钮、片尾出现「下一集」卡片，焦点自动落在上面，按一下就生效。
 */
@Composable
fun PlayerScreen(request: PlayRequest, onClose: () -> Unit) {
    val graph = LocalGraph.current
    val account = LocalSession.current
    val context = LocalContext.current
    val controller = remember(request) {
        PlaybackController(
            context = context.applicationContext,
            api = account.api,
            server = account.server,
            http = graph.http,
            identity = graph.identity,
            deviceId = graph.store.playbackDeviceId,
            token = account.token,
            prefs = object : PrefsStore {
                override fun string(key: String) = graph.store.string(key)
                override fun putString(key: String, value: String?) = graph.store.putString(key, value)
            },
            scope = graph.appScope,
            probe = io.movieclaw.androidtv.BuildConfig.DEBUG,
            lab = (context.applicationContext as io.movieclaw.androidtv.MovieClawApp).labScenario,
            target = PlaybackTarget(
                mediaItemId = request.mediaItemId,
                seasonNumber = request.seasonNumber ?: 0,
                episodeNumber = request.episodeNumber ?: 0,
                startMs = request.startSeconds?.times(1000),
                fileId = request.fileId,
            ),
        )
    }
    DisposableEffect(controller) {
        controller.start()
        onDispose { controller.close() }
    }
    LaunchedEffect(controller) { graph.labSeeks.collect { controller.seekTo(it, exact = true, source = "lab") } }
    LaunchedEffect(controller) {
        graph.labTracks.collect { (kind, ref) ->
            if (kind == "audio") controller.selectAudio(ref) else controller.selectSubtitle(ref.takeIf { it != "off" })
        }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { controller.setBackgrounded(true) }
    LifecycleEventEffect(Lifecycle.Event.ON_START) { controller.setBackgrounded(false) }

    val state by controller.state.collectAsState()
    PlayerContent(controller, state, graph.http, onClose)
}

/** 播放器里能拿焦点的东西：平时在「画面」上（一块看不见的全屏可聚焦区，收遥控器的按键） */
private enum class Focus { None, Surface, Skip, UpNext, QualityOffer, Panel, Dialog }

/** 按住左右键的拖动状态（只在按键回调里读写，不需要触发重组） */
private class HoldState {
    var direction = 0
    var scrubbing = false
    /** 拖动途中按了返回：之后的松手不再提交、也不算点按 */
    var cancelled = false
    var startedAt = 0L
}

@Composable
private fun PlayerContent(controller: PlaybackController, state: PlayerState, http: okhttp3.OkHttpClient, exit: () -> Unit) {
    val scope = rememberCoroutineScope()
    val surfaceFocus = remember { FocusRequester() }
    val skipFocus = remember { FocusRequester() }
    val upNextFocus = remember { FocusRequester() }
    val offerFocus = remember { FocusRequester() }
    val dialogFocus = remember { FocusRequester() }
    var focus by remember { mutableStateOf(Focus.None) }
    var chromeVisible by remember { mutableStateOf(true) }
    var chromeActivity by remember { mutableIntStateOf(0) }
    var panelOpen by remember { mutableStateOf(false) }
    var scrubMs by remember { mutableStateOf<Long?>(null) }
    var scrubBase by remember { mutableLongStateOf(0L) }
    val hold = remember { HoldState() }
    val trickplay = remember(controller) { TrickplayImages(http, scope, controller::resolve) }
    val cues by controller.cues.collectAsState()

    // 屏幕常亮：在放（或正要放）的时候；暂停久了让系统屏保照常起来
    val view = LocalView.current
    val keepOn = !state.paused || (state.wantsPlay && state.phase.isBusy)
    DisposableEffect(keepOn) {
        view.keepScreenOn = keepOn
        onDispose { view.keepScreenOn = false }
    }

    // 自动帧率匹配：片源帧率一确定就切显示模式（换集换了帧率再切一次），离开播放器交还系统
    val activity = androidx.activity.compose.LocalActivity.current as? io.movieclaw.androidtv.MainActivity
    LaunchedEffect(state.contentFrameRate) { state.contentFrameRate?.let { activity?.matchFrameRate(it) } }
    DisposableEffect(activity) { onDispose { activity?.restoreDisplayMode() } }

    fun showChrome() {
        chromeVisible = true
        chromeActivity += 1
    }

    fun focusSurfaceSoon() {
        scope.launch {
            // 等这一帧的重组把画面重新设成可聚焦
            delay(32)
            runCatching { surfaceFocus.requestFocus() }
        }
    }

    fun togglePlay() {
        controller.noteUserActivity()
        if (state.isModal) return
        controller.togglePlay()
        showChrome()
    }

    fun openPanel() {
        if (state.isModal || !state.hasSession) return
        panelOpen = true
        showChrome()
    }

    /** 返回键：取消拖动 → 收起面板 → 收起下一集卡片 → 收起换画质建议 → 退出播放（跳过按钮不收：返回就是退出） */
    fun back() {
        controller.noteUserActivity()
        if (scrubMs != null) {
            scrubMs = null
            hold.scrubbing = false
            hold.cancelled = true
            controller.cancelScrubFollow()
            controller.seekTo(scrubBase, exact = true)
            return
        }
        if (panelOpen) {
            panelOpen = false
            focusSurfaceSoon()
            return
        }
        if (focus == Focus.UpNext) {
            controller.dismissUpNext()
            focusSurfaceSoon()
            return
        }
        if (focus == Focus.QualityOffer) {
            controller.dismissQualityOffer()
            focusSurfaceSoon()
            return
        }
        exit()
    }
    BackHandler(onBack = ::back)

    /** 左右键：点按 ∓10 秒；按住（系统开始连发）进入拖动，按住越久走得越快，松手精确跳过去 */
    fun horizontal(direction: Int, down: Boolean, repeat: Int, time: Long) {
        if (down) {
            if (repeat == 0) {
                if (hold.scrubbing) {
                    // 拖动中换了方向：从当前落点接着拖
                    scrubBase = scrubMs ?: scrubBase
                    hold.startedAt = time
                    hold.direction = direction
                    return
                }
                hold.direction = direction
                hold.cancelled = false
                return
            }
            if (hold.cancelled || direction != hold.direction) return
            val duration = state.durationMs ?: return
            if (!state.hasSession || panelOpen || state.isModal) return
            if (!hold.scrubbing) {
                hold.scrubbing = true
                hold.startedAt = time
                controller.noteUserActivity()
                scrubBase = state.positionMs
                showChrome()
            }
            val target = ScrubMath.target(scrubBase, direction, time - hold.startedAt, duration)
            scrubMs = target
            controller.scrubFollow(target)
            return
        }
        if (hold.scrubbing && direction != hold.direction) return
        when {
            hold.cancelled -> hold.cancelled = false
            hold.scrubbing -> {
                hold.scrubbing = false
                controller.cancelScrubFollow()
                scrubMs?.let { controller.seekTo(it, exact = true) }
                scrubMs = null
                showChrome()
            }
            hold.direction == direction -> {
                controller.noteUserActivity()
                controller.seekBy(direction * 10_000L)
                showChrome()
            }
        }
        hold.direction = 0
    }

    fun onSurfaceKey(event: KeyEvent): Boolean {
        val native = event.nativeKeyEvent
        val down = event.type == KeyEventType.KeyDown
        when (native.keyCode) {
            AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER, AndroidKeyEvent.KEYCODE_NUMPAD_ENTER -> {
                if (down && native.repeatCount == 0) togglePlay()
            }
            AndroidKeyEvent.KEYCODE_DPAD_LEFT -> horizontal(-1, down, native.repeatCount, native.eventTime)
            AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> horizontal(1, down, native.repeatCount, native.eventTime)
            AndroidKeyEvent.KEYCODE_DPAD_UP -> if (down) {
                controller.noteUserActivity()
                showChrome()
            }
            AndroidKeyEvent.KEYCODE_DPAD_DOWN -> if (down && native.repeatCount == 0) {
                controller.noteUserActivity()
                openPanel()
            }
            else -> return false
        }
        return true
    }

    /** 媒体键在哪儿都管用（面板开着也能暂停），出错 / 同意弹窗时不管 */
    fun onMediaKey(event: KeyEvent): Boolean {
        val native = event.nativeKeyEvent
        val code = native.keyCode
        if (code !in MEDIA_KEYS) return false
        if (event.type != KeyEventType.KeyDown || native.repeatCount != 0) return true
        when (code) {
            AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, AndroidKeyEvent.KEYCODE_HEADSETHOOK -> togglePlay()
            AndroidKeyEvent.KEYCODE_MEDIA_PLAY -> if (state.paused) togglePlay()
            AndroidKeyEvent.KEYCODE_MEDIA_PAUSE -> if (!state.paused) togglePlay()
            AndroidKeyEvent.KEYCODE_MEDIA_FAST_FORWARD, AndroidKeyEvent.KEYCODE_MEDIA_SKIP_FORWARD -> {
                controller.noteUserActivity()
                controller.seekBy(10_000)
                showChrome()
            }
            AndroidKeyEvent.KEYCODE_MEDIA_REWIND, AndroidKeyEvent.KEYCODE_MEDIA_SKIP_BACKWARD -> {
                controller.noteUserActivity()
                controller.seekBy(-10_000)
                showChrome()
            }
            AndroidKeyEvent.KEYCODE_MEDIA_NEXT -> {
                controller.noteUserActivity()
                controller.playNext()
            }
            AndroidKeyEvent.KEYCODE_MEDIA_PREVIOUS -> controller.playPrevious()
        }
        return true
    }

    // ---- 状态派生 ----

    val mustStay = state.userPaused || scrubMs != null || panelOpen
    val contextual: Focus? = when {
        state.isModal || panelOpen -> null
        state.qualityOffer != null -> Focus.QualityOffer
        state.skipSegment != null -> Focus.Skip
        state.showsUpNext && state.nextEpisode != null -> Focus.UpNext
        else -> null
    }
    val dialogKind = when {
        state.infoError != null -> 1
        state.phase == Phase.Error && state.errorMessage != null -> 2
        state.phase == Phase.Consent && state.pendingDecision != null -> 3
        else -> 0
    }

    fun requestContextual(target: Focus) {
        val requester = when (target) {
            Focus.Skip -> skipFocus
            Focus.UpNext -> upNextFocus
            Focus.QualityOffer -> offerFocus
            else -> surfaceFocus
        }
        runCatching { requester.requestFocus() }
    }

    LaunchedEffect(Unit) { runCatching { surfaceFocus.requestFocus() } }
    // 控制层 4 秒无操作自动收起；暂停、拖动、面板打开时一直显示
    LaunchedEffect(chromeVisible, mustStay, chromeActivity) {
        if (!chromeVisible || mustStay) return@LaunchedEffect
        delay(4000)
        chromeVisible = false
    }
    // 系统 / 语音助手暂停了：以「用户暂停了」这个状态为准把控制层叫出来
    LaunchedEffect(state.showPaused) { if (state.showPaused) showChrome() }
    // 跳过按钮、下一集卡片、换画质建议出现时焦点自动落上去（按一下就生效），消失时回到画面
    LaunchedEffect(contextual) {
        delay(150)
        val corner = focus == Focus.Skip || focus == Focus.UpNext || focus == Focus.QualityOffer
        if (contextual != null && (focus == Focus.None || focus == Focus.Surface || corner)) {
            requestContextual(contextual)
        } else if (contextual == null && (focus == Focus.None || corner)) {
            runCatching { surfaceFocus.requestFocus() }
        }
        // 兜底：刚出现时请求可能落空（还没进焦点系统），隔一会儿按钮早就绪了
        delay(250)
        if (contextual != null && focus != contextual && (focus == Focus.None || focus == Focus.Surface)) requestContextual(contextual)
    }
    // 出错 / 要用户同意的对话框：焦点落在主按钮；没有对话框时回到画面（或正露着的右下角按钮）
    LaunchedEffect(dialogKind) {
        delay(120)
        if (dialogKind != 0) runCatching { dialogFocus.requestFocus() } else requestContextual(contextual ?: Focus.Surface)
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .onPreviewKeyEvent(::onMediaKey),
    ) {
        // 1. 画面 + 字幕
        // 换会话（换音轨、换画质、降档）时留着最后一帧，别闪黑
        ContentFrame(player = controller.player, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit, keepContentOnReset = true)
        SubtitleLayer(
            overlayUrl = state.overlaySubtitleUrl,
            engineCues = if (state.engineSubtitles) cues else emptyList(),
            videoWidth = state.videoWidth,
            videoHeight = state.videoHeight,
            http = http,
            fileTimeMs = controller::currentFileMs,
        )

        // 2. 暂停压暗（只跟用户意图走：缓冲、换流时的程序性暂停不压暗）
        if (state.showPaused) {
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.15f), Color.Black.copy(alpha = 0.6f)))))
        }

        // 3. 画面：看不见的全屏可聚焦区，收遥控器的按键
        Box(
            Modifier
                .fillMaxSize()
                .focusRequester(surfaceFocus)
                .focusProperties { canFocus = !panelOpen && !state.isModal }
                .onFocusChanged { if (it.isFocused) focus = Focus.Surface else if (focus == Focus.Surface) focus = Focus.None }
                .onKeyEvent(::onSurfaceKey)
                .focusable(),
        )

        // 4. 控制层（面板打开时让位）
        AnimatedVisibility(chromeVisible && !panelOpen, enter = fadeIn(tween(250)), exit = fadeOut(tween(250))) {
            Chrome(state, scrubMs, trickplay)
        }

        // 5. 转圈
        if (state.phase.isBusy) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { BusyView(state.phase, state.speedLabel) }
        }

        // 6. 右下角：换画质建议 > 跳过 > 下一集（同时只出一个）
        val cornerBottom by animateDpAsState(if (chromeVisible) 200.pt else 80.pt, tween(250), label = "corner")
        Box(
            Modifier
                .fillMaxSize()
                .padding(end = 80.pt, bottom = cornerBottom)
                .alpha(if (state.isModal || panelOpen) 0f else 1f)
                .focusProperties { canFocus = !panelOpen }
                .onPreviewKeyEvent { event ->
                    // 右下角按钮上按左 / 上回到画面（那边就是画面），按右 / 下没有去处
                    if (focus != Focus.Skip && focus != Focus.UpNext) return@onPreviewKeyEvent false
                    when (event.nativeKeyEvent.keyCode) {
                        AndroidKeyEvent.KEYCODE_DPAD_LEFT, AndroidKeyEvent.KEYCODE_DPAD_UP -> {
                            if (event.type == KeyEventType.KeyDown) runCatching { surfaceFocus.requestFocus() }
                            true
                        }
                        AndroidKeyEvent.KEYCODE_DPAD_RIGHT, AndroidKeyEvent.KEYCODE_DPAD_DOWN -> true
                        else -> false
                    }
                },
            contentAlignment = Alignment.BottomEnd,
        ) {
            val offer = state.qualityOffer
            val segment = state.skipSegment
            val next = state.nextEpisode
            when {
                offer != null -> QualityOfferCard(
                    offer,
                    onAccept = {
                        controller.noteUserActivity()
                        controller.acceptQualityOffer()
                    },
                    onDismiss = {
                        controller.noteUserActivity()
                        controller.dismissQualityOffer()
                    },
                    acceptFocus = offerFocus,
                    modifier = Modifier.onFocusChanged {
                        if (it.hasFocus) focus = Focus.QualityOffer else if (focus == Focus.QualityOffer) focus = Focus.None
                    },
                )
                segment != null -> SkipButton(
                    segment,
                    onClick = controller::skipCurrentSegment,
                    modifier = Modifier
                        .focusRequester(skipFocus)
                        .onFocusChanged { if (it.isFocused) focus = Focus.Skip else if (focus == Focus.Skip) focus = Focus.None },
                )
                state.showsUpNext && next != null -> {
                    UpNextCard(
                        next,
                        countdown = if (state.autoNextArmed) state.autoNextProgress else null,
                        onClick = {
                            controller.noteUserActivity()
                            controller.playNext()
                        },
                        modifier = Modifier
                            .focusRequester(upNextFocus)
                            .onFocusChanged { if (it.isFocused) focus = Focus.UpNext else if (focus == Focus.UpNext) focus = Focus.None },
                    )
                    // 倒计时的钟：卡片在才走
                    LaunchedEffect(Unit) {
                        while (true) {
                            delay(100)
                            controller.advanceAutoNext(100)
                        }
                    }
                }
            }
        }

        // 7. 顶部提示
        // 淡出期间提示已经清空：留着上一句，别淡出一个空胶囊
        val lastNotice = remember { mutableStateOf("") }
        SideEffect { state.notice?.let { lastNotice.value = it } }
        AnimatedVisibility(
            state.notice != null,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 40.pt),
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(200)),
        ) { NoticeCapsule(state.notice ?: lastNotice.value) }

        // 8. 信息面板
        AnimatedVisibility(panelOpen, enter = fadeIn(tween(250)), exit = fadeOut(tween(250))) {
            Box(Modifier.onFocusChanged { if (it.hasFocus) focus = Focus.Panel else if (focus == Focus.Panel) focus = Focus.None }) {
                PlayerPanel(state, controller)
            }
        }

        // 9. 对话框
        Box(Modifier.onFocusChanged { if (it.hasFocus) focus = Focus.Dialog else if (focus == Focus.Dialog) focus = Focus.None }) {
            val decision = state.pendingDecision
            when (dialogKind) {
                1 -> PlayerDialog(state.infoError ?: "", null, "返回" to exit, null, dialogFocus)
                2 -> PlayerDialog(state.errorMessage ?: "", state.errorSuggestion, "重试" to controller::retry, "返回" to exit, dialogFocus)
                3 -> if (decision != null) ConsentDialog(decision, controller::grantConsent, exit, dialogFocus)
            }
        }
    }
}

/** 控制层：顶部渐暗（暂停时左上角片名）+ 底部进度条 */
@Composable
private fun Chrome(state: PlayerState, scrubMs: Long?, trickplay: TrickplayImages) {
    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(220.pt)
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.Transparent))),
        )
        if (state.showPaused) {
            PausedTitle(state.title, state.episodeLabel, Modifier.padding(top = 60.pt, start = 80.pt, end = 80.pt))
        }
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(360.pt)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f)))),
        )
        TransportBar(
            state, scrubMs, trickplay,
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(start = 80.pt, end = 80.pt, bottom = 60.pt),
        )
    }
}

private val MEDIA_KEYS = setOf(
    AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, AndroidKeyEvent.KEYCODE_HEADSETHOOK, AndroidKeyEvent.KEYCODE_MEDIA_PLAY,
    AndroidKeyEvent.KEYCODE_MEDIA_PAUSE, AndroidKeyEvent.KEYCODE_MEDIA_FAST_FORWARD, AndroidKeyEvent.KEYCODE_MEDIA_SKIP_FORWARD,
    AndroidKeyEvent.KEYCODE_MEDIA_REWIND, AndroidKeyEvent.KEYCODE_MEDIA_SKIP_BACKWARD, AndroidKeyEvent.KEYCODE_MEDIA_NEXT,
    AndroidKeyEvent.KEYCODE_MEDIA_PREVIOUS,
)
