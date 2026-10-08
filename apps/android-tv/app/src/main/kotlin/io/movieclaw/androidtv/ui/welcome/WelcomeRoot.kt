package io.movieclaw.androidtv.ui.welcome

import androidx.activity.compose.BackHandler
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextAlign
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.session.AppModel
import io.movieclaw.androidtv.core.session.NeedsPasswordException
import io.movieclaw.androidtv.core.session.SavedAccount
import io.movieclaw.androidtv.core.session.WelcomeScene
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.theme.ptSp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 本页内的步骤：介绍页 → 找服务器 → 登录；「选择账号」是从「连不上」卡片进来的 */
private sealed interface Step {
    data object Intro : Step
    data object Server : Step
    data class SignIn(val server: ServerAddress) : Step
    data object Accounts : Step
}

/** 阶段卡片之外的位置：步骤 + 是否已离开阶段卡片 */
private data class Place(val step: Step, val detached: Boolean)

/**
 * 欢迎页（TVWelcomeView）：没有登录中的账号时出现。星空背景上按阶段给不同的卡片：
 *
 * | 阶段 | 电视上给什么 |
 * |---|---|
 * | 第一次使用（NeedsServer） | 片名 + 台词 +「连接服务器」→ 找服务器 → 登录 |
 * | 账号都退出了 / 登录过期（NeedsLogin） | 片名 + 台词 +「登录」；过期时直接进登录卡片（用户名已预填） |
 * | 服务器是全新的（NeedsSetup） | 请在网页上完成初始化 |
 * | 当前服务器没有账号了、别处还有（ChooseAccount） | 选择账号 |
 * | 冷启动连不上（Unreachable） | 原因 + 重试 / 换服务器 / 切换账号 |
 *
 * 与 Apple 端的差别：卡片上的「换一台服务器」「切换到其他账号」「添加账号」真的会打开找服务器 / 选账号
 * （Apple 端只改了本页步骤，被阶段卡片盖住，按了没反应）。返回键退回上一步，退到头交给系统。
 */
@Composable
fun WelcomeRoot(phase: AppModel.Phase) {
    val model = LocalGraph.current.model
    var place by remember { mutableStateOf(Place(Step.Intro, detached = false)) }
    val history = remember { mutableStateListOf<Place>() }
    // 每重连一次加一：「连不上」卡片的原因不是可观察的状态，重连完要重新读一遍
    var reconnects by remember { mutableIntStateOf(0) }
    val launchError = remember(phase, reconnects) { model.launchError }

    fun go(step: Step) {
        history += place
        place = Place(step, detached = true)
    }

    // 登录过期（预填了用户名）直接进登录卡片；换到阶段卡片时回到卡片本身
    LaunchedEffect(phase) {
        val server = model.server
        when {
            phase == AppModel.Phase.NeedsLogin && model.expiredUsername != null && server != null -> {
                // 返回键退到介绍页
                history.clear()
                history += Place(Step.Intro, detached = false)
                place = Place(Step.SignIn(server), detached = false)
            }
            phase.isCard -> {
                history.clear()
                place = Place(Step.Intro, detached = false)
            }
        }
    }
    BackHandler(enabled = history.isNotEmpty()) { place = history.removeAt(history.lastIndex) }

    val showsCard = phase.isCard && !place.detached
    Box(Modifier.fillMaxSize()) {
        CosmosBackdrop(lit = true, dimmed = !showsCard && place.step != Step.Intro)
        Box(Modifier.fillMaxSize().padding(80.pt), contentAlignment = Alignment.Center) {
            // 阶段之间交叉淡入（同 Apple 端 .animation(.default)），本页步骤之间直接换
            Crossfade(if (showsCard) phase else null, label = "welcome-phase") { card ->
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    when (card) {
                        AppModel.Phase.NeedsSetup -> InfoCard(
                            "这台服务器还没初始化",
                            "请先在电脑或手机的浏览器里打开 ${model.server?.fullDisplay ?: "服务器地址"}，创建管理员账号，再回到这里登录。",
                        ) { first ->
                            ReconnectButton("我已完成，重新连接", first) { reconnects++ }
                            WelcomeButton("换一台服务器", onClick = { go(Step.Server) })
                        }
                        AppModel.Phase.Unreachable -> InfoCard("连不上服务器", launchError ?: "请检查网络，或确认服务器正在运行。") { first ->
                            ReconnectButton("重试", first) { reconnects++ }
                            WelcomeButton("换一台服务器", onClick = { go(Step.Server) })
                            if (model.accountsOnOtherServers.isNotEmpty()) {
                                WelcomeButton("切换到其他账号", onClick = { go(Step.Accounts) })
                            }
                        }
                        AppModel.Phase.ChooseAccount -> AccountChooser(model.accountsOnOtherServers) { go(Step.Server) }
                        else -> StepContent(place.step, ::go)
                    }
                }
            }
        }
    }
}

private val AppModel.Phase.isCard: Boolean
    get() = this == AppModel.Phase.NeedsSetup || this == AppModel.Phase.Unreachable || this == AppModel.Phase.ChooseAccount

@Composable
private fun StepContent(step: Step, go: (Step) -> Unit) {
    val model = LocalGraph.current.model
    when (step) {
        Step.Intro -> Intro { go(model.server?.let(Step::SignIn) ?: Step.Server) }
        Step.Server -> ServerPicker { go(Step.SignIn(it)) }
        is Step.SignIn -> SignInStep(step.server, model.expiredUsername, expired = model.expiredUsername != null) { go(Step.Server) }
        Step.Accounts -> AccountChooser(model.accountsOnOtherServers) { go(Step.Server) }
    }
}

private val EaseInOut = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)

/** 介绍页：片名 + 一句台词（像电影字幕一样 8 秒换一句，淡入淡出 1 秒）+ 主按钮。按钮是唯一能聚焦的东西 */
@Composable
private fun Intro(onStart: () -> Unit) {
    val model = LocalGraph.current.model
    val scenes = remember { WelcomeScene.all.shuffled() }
    var index by remember { mutableIntStateOf(0) }
    val start = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        while (true) {
            delay(8_000)
            index++
        }
    }
    InitialFocus(start)
    Column(
        Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(60.pt),
    ) {
        Spacer(Modifier.weight(1f))
        Text("MovieClaw", style = welcomeSerif(110).copy(letterSpacing = 6.ptSp))
        Crossfade(WelcomeScene.at(scenes, index), Modifier.fillMaxWidth().height(260.pt), animationSpec = tween(1000, easing = EaseInOut), label = "quote") { scene ->
            // 固定高度、内容居中；长台词可以超出这块（同 Apple 端 frame(height:) 不裁切）
            if (scene != null) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(
                    Modifier.fillMaxWidth().wrapContentHeight(unbounded = true),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(18.pt),
                ) {
                    Text(scene.line, style = welcomeSerif(40).copy(lineHeight = 58.ptSp), textAlign = TextAlign.Center)
                    scene.original?.let {
                        Text(it, style = McType.Callout.copy(fontStyle = FontStyle.Italic), color = McColors.Secondary, textAlign = TextAlign.Center)
                    }
                    Text(scene.credit, style = McType.Caption, color = McColors.Secondary)
                }
            }
        }
        Spacer(Modifier.weight(1f))
        WelcomeButton(if (model.server == null) "连接服务器" else "登录", onClick = onStart, modifier = Modifier.focusRequester(start), style = McType.Headline)
        Spacer(Modifier.height(40.pt))
    }
}

/** 欢迎页上的一张说明卡（TVWelcomeCard）：标题、说明、一排按钮；第一个按钮默认获得焦点 */
@Composable
private fun InfoCard(title: String, message: String, buttons: @Composable (first: FocusRequester) -> Unit) {
    val first = remember { FocusRequester() }
    InitialFocus(first)
    WelcomeCard(1100, 28, Modifier.focusGroup()) {
        Text(title, style = welcomeSerif(52))
        Text(message, style = McType.Callout, color = McColors.Secondary)
        Row(Modifier.padding(top = 12.pt), horizontalArrangement = Arrangement.spacedBy(30.pt)) { buttons(first) }
    }
}

/** 「重试」「我已完成，重新连接」：重连当前服务器；连接中再按不重复发起 */
@Composable
private fun ReconnectButton(title: String, focus: FocusRequester, onDone: () -> Unit) {
    val model = LocalGraph.current.model
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    WelcomeButton(title, onClick = {
        if (busy) return@WelcomeButton
        busy = true
        scope.launch {
            try {
                model.reconnect()
            } finally {
                busy = false
                onDone()
            }
        }
    }, modifier = Modifier.focusRequester(focus))
}

/**
 * 选择账号（TVAccountChooser）：本机登录过的账号（可跨服务器），点一下就进，不用密码；最后是「添加账号」。
 */
@Composable
private fun AccountChooser(accounts: List<SavedAccount>, onAddAccount: () -> Unit) {
    val model = LocalGraph.current.model
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    val first = remember { FocusRequester() }
    InitialFocus(first)
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(60.pt)) {
        Text("选择账号", style = welcomeSerif(64))
        Row(Modifier.focusGroup(), horizontalArrangement = Arrangement.spacedBy(60.pt)) {
            accounts.forEachIndexed { i, saved ->
                ProfileTile(saved, onClick = {
                    scope.launch {
                        try {
                            val previous = model.server
                            model.switchAccount(saved.account.username, saved.server)
                            model.session?.let { showNotice(context, switchedNotice(it.nickname, saved.server, previous)) }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: NeedsPasswordException) {
                            error = "「${saved.account.nickname}」的登录已失效，请在「添加账号」里重新登录"
                        } catch (e: Exception) {
                            error = e.message
                        }
                    }
                }, modifier = if (i == 0) Modifier.focusRequester(first) else Modifier)
            }
            AddAccountTile(onAddAccount, if (accounts.isEmpty()) Modifier.focusRequester(first) else Modifier, captionLine = false)
        }
        error?.let { Text(it, style = McType.Body, color = McColors.Danger) }
    }
}
