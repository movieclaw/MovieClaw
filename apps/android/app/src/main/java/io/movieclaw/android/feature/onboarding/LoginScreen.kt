package io.movieclaw.android.feature.onboarding

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseIn
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.movieclaw.android.core.designsystem.AccentStrong
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import kotlinx.coroutines.delay

/**
 * 登录 / 欢迎页 —— 与移动端网页同一个两段式（components/welcome-screen.tsx）：
 *
 *   · **首页**：星空（约 40 分钟转一圈）+ 行星地平线；片名「MovieClaw」46/300 衬线、
 *     字距从 12 收到 1，下面一道细线（0 → 28）与「智能影音服务器」13/字距 8；
 *     再下面是影史台词轮播（18 中文 / 13 斜体原文 / 11 出处 36%，**9 秒一句、点一下换**）；
 *     底部「登录」玻璃胶囊 188×54、17/字距 4。
 *   · **卡片**：片名缩到 0.72 留在顶部、台词与按钮让位；卡片从下方升起；
 *     标题 22 衬线、说明 14/62%、右上角 × 30×30；输入组圆角 16、白 5% 底、行间 8% 细线、
 *     每行 50 高、左侧 22 宽图标位；主按钮 50 高圆角 999、银白实底 17/600 深色字。
 *   · 实测片头时序：片名 2.4s@0.6s → 细线 1.2s@1.4s → 副标题 1.4s@1.6s → 台词 1.4s@2.2s → 按钮 1s@2.8s。
 *
 * 与网页的差异（App 侧必须）：网页由服务器托管、不需要地址，卡片只有账号密码；
 * App 是客户端，多一行「服务器地址」。网页的「30 天内记住我」本 App 无对应参数，故不渲染假控件。
 */
@Composable
fun LoginScreen(
    presetUsername: String?,
    onDone: (() -> Unit)? = null,
    vm: LoginViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    LaunchedEffect(presetUsername) { presetUsername?.let { vm.presetUsername(it) } }
    LaunchedEffect(ui.loggedIn) { if (ui.loggedIn) onDone?.invoke() }

    var cardStage by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    val lit = remember { Animatable(0f) }
    LaunchedEffect(Unit) { lit.animateTo(1f, tween(16)) }

    Box(Modifier.fillMaxSize().background(Color.Black).imePadding()) {
        StarfieldBackdrop()
        PlanetHorizon(reveal = lit.value)

        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 12.dp),
        ) {
            WelcomeMasthead(compact = cardStage, hidden = cardStage && editing, lit = lit.value)
            Spacer(Modifier.weight(1f))
            if (!cardStage) {
                FilmQuote()
                Spacer(Modifier.weight(1f))
                LoginButton { cardStage = true }
            } else {
                LoginCard(
                    ui = ui,
                    onServer = vm::onServer,
                    onUsername = vm::onUsername,
                    onPassword = vm::onPassword,
                    onConfirm = vm::onConfirm,
                    onDiscover = vm::discoverServer,
                    onSubmit = vm::submit,
                    onFocusChange = { editing = it },
                    onClose = { cardStage = false },
                )
            }
        }
    }
}

/** 片名：衬线 46/300，字距 12→1；细线与副标题按时序浮现 */
@Composable
private fun WelcomeMasthead(compact: Boolean, hidden: Boolean, lit: Float) {
    if (hidden) return
    val title = revealDelay(lit, 600, 2400)
    val rule = revealDelay(lit, 1400, 1200)
    val tagline = revealDelay(lit, 1600, 1400)
    Column(
        Modifier
            .fillMaxWidth()
            .graphicsLayer {
                val s = if (compact) 0.72f else 1f
                scaleX = s
                scaleY = s
                transformOrigin = TransformOrigin(0.5f, 0f)
            }
            .padding(top = if (compact) 12.dp else 96.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row {
            Text(
                "Movie",
                style = McType.wordmark.copy(
                    fontFamily = FontFamily.Serif,
                    color = AccentStrong,
                    letterSpacing = (12f - 11f * title).sp,
                ),
                maxLines = 1,
            )
            Text(
                "Claw",
                style = McType.wordmark.copy(
                    fontFamily = FontFamily.Serif,
                    fontStyle = FontStyle.Italic,
                    color = AccentStrong,
                    letterSpacing = (12f - 11f * title).sp,
                ),
                maxLines = 1,
            )
        }
        Spacer(Modifier.height(14.dp))
        Box(
            Modifier
                .width((28f * rule).dp)
                .height(1.dp)
                .background(Color.White.copy(alpha = 0.5f)),
        )
        Spacer(Modifier.height(14.dp))
        Text(
            "智能影音服务器",
            style = McType.caption.copy(
                fontFamily = FontFamily.Serif,
                color = TextMuted,
                letterSpacing = 8.sp,
            ),
            modifier = Modifier.graphicsLayer { alpha = tagline },
        )
    }
}

/**
 * 影史台词轮播（iOS `WelcomeView` 的 `quoteChange` 过渡）：9 秒一句、点一下换。
 * 旧句先走（0.45 秒上移 14、虚化 6、淡出），新句稍晚 0.25 秒、0.7 秒从下方 14 浮上来——
 * 两句只短暂交叠，读起来是一句接一句（原先旧句是「啪」地消失、新句才淡入，观感生硬）。
 * 一轮播完重新打乱顺序（iOS 同款）。
 */
@Composable
private fun FilmQuote() {
    var order by remember { mutableStateOf(QUOTES.indices.shuffled()) }
    var index by remember { mutableIntStateOf(0) }
    var leaving by remember { mutableStateOf<Quote?>(null) }
    /** 出场进度：0 → 1 = 旧句完全离场 */
    val out = remember { Animatable(0f) }
    /** 入场进度：0 → 1 = 新句完全在场 */
    val enter = remember { Animatable(0f) }
    var turn by remember { mutableIntStateOf(0) }

    fun next() {
        leaving = QUOTES[order[index]]
        index += 1
        if (index >= order.size) {
            order = QUOTES.indices.shuffled()
            index = 0
        }
        turn++
    }

    // 入场：从下方 0.7 秒浮上来（晚 0.25 秒起，首句同样）
    LaunchedEffect(turn) {
        enter.snapTo(0f)
        enter.animateTo(1f, tween(700, easing = EaseOut, delayMillis = 250))
    }
    // 出场：旧句 0.45 秒上移虚化淡出，走完撤下
    LaunchedEffect(turn) {
        if (turn == 0) return@LaunchedEffect
        out.snapTo(0f)
        out.animateTo(1f, tween(450, easing = EaseIn))
        leaving = null
    }
    // 9 秒一句（iOS `sceneDuration`）
    LaunchedEffect(turn) {
        delay(9_000)
        next()
    }

    Column(
        Modifier
            .fillMaxWidth()
            .height(150.dp)
            .clickable { next() },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Bottom,
    ) {
        Box(contentAlignment = Alignment.BottomCenter) {
            leaving?.let { QuoteBlock(it, t = 1f - out.value, upward = true) }
            QuoteBlock(QUOTES[order[index]], t = enter.value, upward = false)
        }
    }
}

/** 一句台词文本块；`t` = 在场程度 0~1，`upward` = 离场时向上飘（入场从下方来） */
@Composable
private fun QuoteBlock(q: Quote, t: Float, upward: Boolean) {
    Column(
        Modifier
            .graphicsLayer {
                alpha = t
                translationY = (1f - t) * (if (upward) -14f else 14f)
            }
            .blur((6f * (1f - t)).dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            q.line,
            style = McType.body.copy(
                fontFamily = FontFamily.Serif,
                color = TextPrimary,
                lineHeight = 30.sp,
                textAlign = TextAlign.Center,
            ),
        )
        q.original?.let {
            Text(
                it,
                style = McType.caption.copy(
                    fontFamily = FontFamily.Serif,
                    fontStyle = FontStyle.Italic,
                    color = TextMuted,
                    lineHeight = 19.sp,
                    textAlign = TextAlign.Center,
                ),
            )
        }
        Text(
            "——《${q.film}》${q.year}",
            style = McType.micro.copy(fontFamily = FontFamily.Serif, color = TextFaint, letterSpacing = 2.sp),
        )
    }
}

@Composable
private fun LoginButton(onClick: () -> Unit) {
    val appear = revealDelay(1f, 2800, 1000)
    Box(
        Modifier
            .fillMaxWidth()
            .graphicsLayer { alpha = appear }
            .padding(bottom = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier
                .height(54.dp)
                .width(188.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(GlassCapsule)
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(999.dp))
                .clickable(onClick = onClick),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "登录",
                style = McType.headline.copy(
                    fontFamily = FontFamily.Serif,
                    fontWeight = FontWeight.Normal,
                    color = TextPrimary,
                    letterSpacing = 4.sp,
                ),
            )
        }
    }
}

/** 登录卡（圆角 30 / 内边距 22；输入组圆角 16 + 8% 细线；主按钮 50 圆角 999） */
@Composable
private fun LoginCard(
    ui: LoginViewModel.UiState,
    onServer: (String) -> Unit,
    onUsername: (String) -> Unit,
    onPassword: (String) -> Unit,
    onConfirm: (String) -> Unit,
    onDiscover: () -> Unit,
    onSubmit: () -> Unit,
    onFocusChange: (Boolean) -> Unit,
    onClose: () -> Unit,
) {
    val focus = LocalFocusManager.current
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(30.dp))
            .background(GlassCard)
            .border(1.dp, LineSoft, RoundedCornerShape(30.dp))
            .padding(22.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(
                    if (ui.needSetup) "初始化 MovieClaw" else "登录 MovieClaw",
                    style = McType.title2.copy(fontFamily = FontFamily.Serif, color = TextPrimary),
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    if (ui.needSetup) "这台服务器还没有管理员，先创建第一个账号。" else "使用你在这台服务器上的账号进入。",
                    style = McType.sub.copy(color = TextMuted, lineHeight = 22.sp),
                )
            }
            Box(
                Modifier
                    .size(30.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.05f))
                    .border(1.dp, Color.White.copy(alpha = 0.08f), CircleShape)
                    .clickable { focus.clearFocus(); onClose() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Rounded.Close, contentDescription = "关闭", tint = TextMuted, modifier = Modifier.size(14.dp))
            }
        }
        Spacer(Modifier.height(16.dp))

        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp)),
        ) {
            CardField(
                value = ui.server,
                onValue = onServer,
                placeholder = "服务器地址",
                icon = { Icon(Icons.Rounded.Language, contentDescription = null, tint = TextFaint, modifier = Modifier.size(18.dp)) },
                trailing = {
                    if (ui.discovering) {
                        CircularProgressIndicator(color = TextFaint, modifier = Modifier.size(15.dp), strokeWidth = 2.dp)
                    } else if (ui.server.isBlank()) {
                        Text("自动发现", style = McType.caption, color = TextMuted, modifier = Modifier.clickable(onClick = onDiscover))
                    }
                },
                onFocusChange = onFocusChange,
            )
            CardDivider()
            CardField(
                value = ui.username,
                onValue = onUsername,
                placeholder = "用户名",
                icon = { Icon(Icons.Rounded.Person, contentDescription = null, tint = TextFaint, modifier = Modifier.size(18.dp)) },
                onFocusChange = onFocusChange,
            )
            CardDivider()
            CardField(
                value = ui.password,
                onValue = onPassword,
                placeholder = "密码",
                password = true,
                icon = { Icon(Icons.Rounded.Lock, contentDescription = null, tint = TextFaint, modifier = Modifier.size(18.dp)) },
                onFocusChange = onFocusChange,
            )
            if (ui.needSetup) {
                CardDivider()
                CardField(
                    value = ui.confirmPassword,
                    onValue = onConfirm,
                    placeholder = "再输一次密码",
                    password = true,
                    icon = { Icon(Icons.Rounded.Lock, contentDescription = null, tint = TextFaint, modifier = Modifier.size(18.dp)) },
                    onFocusChange = onFocusChange,
                )
            }
        }

        ui.error?.let {
            Spacer(Modifier.height(14.dp))
            Text(it, style = McType.sub.copy(color = Danger, lineHeight = 22.sp))
        }

        Spacer(Modifier.height(16.dp))
        val enabled = ui.server.isNotBlank() && ui.username.isNotBlank() && ui.password.isNotBlank() && !ui.loading
        Row(
            Modifier
                .fillMaxWidth()
                .height(50.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(if (enabled) AccentStrong else AccentStrong.copy(alpha = 0.4f))
                .clickable(enabled = enabled) { focus.clearFocus(); onSubmit() },
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (ui.loading) {
                CircularProgressIndicator(color = Color.Black.copy(alpha = 0.6f), modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
            }
            Text(
                when {
                    ui.loading -> "正在登录…"
                    ui.needSetup -> "创建并进入"
                    else -> "登录"
                },
                style = McType.headline.copy(color = Color(0xFF141821)),
            )
        }
    }
}

@Composable
private fun CardDivider() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(start = 14.dp)
            .height(1.dp)
            .background(Color.White.copy(alpha = 0.08f)),
    )
}

@Composable
private fun CardField(
    value: String,
    onValue: (String) -> Unit,
    placeholder: String,
    icon: @Composable () -> Unit,
    password: Boolean = false,
    trailing: (@Composable () -> Unit)? = null,
    onFocusChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(50.dp)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(22.dp), contentAlignment = Alignment.Center) { icon() }
        Spacer(Modifier.width(12.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) {
                Text(placeholder, style = McType.body, color = TextFaint)
            }
            BasicTextField(
                value = value,
                onValueChange = onValue,
                singleLine = true,
                textStyle = McType.body.copy(color = TextPrimary),
                cursorBrush = Brush.verticalGradient(listOf(AccentStrong, AccentStrong)),
                visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(
                    keyboardType = if (password) KeyboardType.Password else KeyboardType.Text,
                    imeAction = ImeAction.Done,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .onFocusChanged { onFocusChange(it.isFocused) },
            )
        }
        if (trailing != null) {
            Spacer(Modifier.width(8.dp))
            trailing()
        }
    }
}

/** 片头时序：delayMs 后开始，durationMs 内 0→1 */
@Composable
private fun revealDelay(lit: Float, delayMs: Long, durationMs: Long): Float {
    if (lit <= 0f) return 0f
    val a = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        delay(delayMs)
        a.animateTo(1f, tween(durationMs.toInt()))
    }
    return a.value
}

private data class Quote(val line: String, val original: String?, val film: String, val year: Int)

/** 影史台词（与网页/原生 App 同一份口径：AFI 百大 + 世界影史 + 华语片名句） */
private val QUOTES = listOf(
    Quote("你把它建起来，他就会来。", "If you build it, he will come.", "梦幻之地", 1989),
    Quote("毕竟，明天又是新的一天。", "After all, tomorrow is another day.", "乱世佳人", 1939),
    Quote("我会给他一个无法拒绝的条件。", "I'm gonna make him an offer he can't refuse.", "教父", 1972),
    Quote("我们永远拥有巴黎。", "We'll always have Paris.", "卡萨布兰卡", 1942),
    Quote("愿原力与你同在。", "May the Force be with you.", "星球大战", 1977),
    Quote("你需要一条更大的船。", "You're gonna need a bigger boat.", "大白鲨", 1975),
    Quote("希望是美好的，也许是人间至善，而美好的事物永不消逝。", "Hope is a good thing, maybe the best of things, and no good thing ever dies.", "肖申克的救赎", 1994),
    Quote("人生总是这么痛苦吗？还是只有小时候是这样？——总是如此。", "Is life always this hard, or is it just when you're a kid? Always like this.", "这个杀手不太冷", 1994),
    Quote("不要温和地走进那个良夜。", "Do not go gentle into that good night.", "星际穿越", 2014),
    Quote("所有这些时刻，终将消逝在时光中，一如雨中的泪水。", "All those moments will be lost in time, like tears in rain.", "银翼杀手", 1982),
    Quote("念念不忘，必有回响。", null, "一代宗师", 2013),
    Quote("如果记忆也是一个罐头的话，我希望这一个罐头不会过期。", null, "重庆森林", 1994),
    Quote("说的是一辈子！差一年、一个月、一天、一个时辰，都不算一辈子！", null, "霸王别姬", 1993),
    Quote("让子弹飞一会儿。", null, "让子弹飞", 2010),
    Quote("对不起，我是警察。", null, "无间道", 2002),
    Quote("如果非要在这份爱上加一个期限，我希望是……一万年。", null, "大话西游之大圣娶亲", 1995),
    Quote("把手握紧，里面什么也没有；把手松开，你拥有的是一切。", null, "卧虎藏龙", 2000),
    Quote("不管最终结果将人类历史导向何处，我们决定，选择希望。", null, "流浪地球", 2019),
    Quote("我们曾经仰望星空，思考自己在星辰间的位置。", "We used to look up at the sky and wonder at our place in the stars.", "星际穿越", 2014),
    Quote("敬那些做梦的人，哪怕他们看起来有点傻。", "Here's to the ones who dream, foolish as they may seem.", "爱乐之城", 2016),
)
