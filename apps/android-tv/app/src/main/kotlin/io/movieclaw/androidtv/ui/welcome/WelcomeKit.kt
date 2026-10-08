package io.movieclaw.androidtv.ui.welcome

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.R
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.session.SavedAccount
import io.movieclaw.androidtv.ui.components.Avatar
import io.movieclaw.androidtv.ui.components.LocalServer
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.glass
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.theme.ptSp
import kotlinx.coroutines.delay
import io.movieclaw.androidtv.ui.components.layerFocus

/*
 * 欢迎页、登录卡片与「谁在看」共用的小零件：宋体、按钮、电视输入框、状态行、选人大头像。
 */

/**
 * 欢迎页的宋体：思源宋体（Noto Serif SC，SIL OFL 1.1）子集，只含欢迎页与「谁在看」用到的字 + 全部可打印 ASCII。
 * 子集外的字由系统逐字回落到默认字体，不会显示成方块。改了这些页面的文案或台词后跑
 * apps/android-tv/scripts/subset-welcome-font.py 重新生成。
 */
val WelcomeSerif = FontFamily(Font(R.font.welcome_serif))

fun welcomeSerif(pt: Int) = TextStyle(fontFamily = WelcomeSerif, fontSize = pt.ptSp)

/** tvOS 默认按钮字号（body 29 中等；模拟器截图量出，大号的主按钮另给 headline） */
val ButtonText = McType.size(29, FontWeight.Medium)

/**
 * 标准按钮（tvOS 的默认按钮）：平时半透明胶囊，获得焦点时白底黑字放大。可带一个前置图标。
 * tvOS 的按钮高度固定 68（与字号无关，聚焦放大到 76 上下）、左右各留 32（两台模拟器截图量出）。
 */
@Composable
fun WelcomeButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    style: TextStyle = ButtonText,
    destructive: Boolean = false,
    leading: (@Composable () -> Unit)? = null,
) {
    Button(
        onClick = onClick,
        modifier = modifier.layerFocus().height(68.pt),
        enabled = enabled,
        shape = ButtonDefaults.shape(CircleShape),
        colors = ButtonDefaults.colors(
            containerColor = Color.White.copy(alpha = 0.12f),
            contentColor = if (destructive) McColors.Danger else McColors.Text,
            focusedContainerColor = Color.White,
            focusedContentColor = if (destructive) Color(0xFFD7263D) else Color.Black,
            pressedContainerColor = Color.White,
            pressedContentColor = Color.Black,
            disabledContainerColor = Color.White.copy(alpha = 0.06f),
            disabledContentColor = McColors.TextFaint,
        ),
        scale = ButtonDefaults.scale(focusedScale = 1.1f),
        contentPadding = PaddingValues(horizontal = 32.pt, vertical = 0.pt),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.pt), verticalAlignment = Alignment.CenterVertically) {
            leading?.invoke()
            icon?.let { Icon(it, null, modifier = Modifier.size((style.fontSize.value * 2.2f).toInt().pt)) }
            Text(text, style = style, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/**
 * 电视上的输入框：平时只是一个可聚焦的框（方向键经过时不弹键盘），按确认才把焦点交给里面的输入、弹出系统键盘；
 * 键盘上按「完成 / 前往 / 搜索」触发 [onSubmit]，焦点回到框上。
 */
@Composable
fun TvTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester = remember { FocusRequester() },
    password: Boolean = false,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Done,
    leadingIcon: ImageVector? = null,
    /** 每加一就直接进入输入（上一个框按了「下一项」） */
    editTrigger: Int = 0,
    onSubmit: () -> Unit = {},
) {
    val field = remember { FocusRequester() }
    var editing by remember { mutableStateOf(false) }
    var focused by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val lit = editing || focused
    // tvOS 的输入框：胶囊形，平时比卡片还暗一点（黑 30%），聚焦浅灰底（231）、放大到 78 高（模拟器截图取色、量出）
    val shape = CircleShape
    Surface(
        onClick = { editing = true },
        modifier = modifier
            .height(72.pt)
            .focusRequester(focusRequester)
            .onFocusChanged { focused = it.isFocused },
        shape = ClickableSurfaceDefaults.shape(shape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.08f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (editing) FieldLit else Color.Black.copy(alpha = 0.3f),
            contentColor = if (editing) Color.Black else McColors.Text,
            focusedContainerColor = FieldLit,
            focusedContentColor = Color.Black,
        ),
    ) {
        Row(
            Modifier.padding(horizontal = 30.pt).height(72.pt),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(18.pt),
        ) {
            leadingIcon?.let { Icon(it, null, tint = if (lit) Color.Black.copy(alpha = 0.6f) else McColors.Secondary, modifier = Modifier.size(36.pt)) }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(field)
                    .focusProperties { canFocus = editing }
                    .onFocusChanged { if (!it.hasFocus && editing) editing = false },
                singleLine = true,
                textStyle = McType.size(27).copy(color = if (lit) Color.Black else McColors.Text),
                cursorBrush = SolidColor(Color.Black),
                visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(
                    keyboardType = if (password) KeyboardType.Password else keyboardType,
                    imeAction = imeAction,
                    autoCorrectEnabled = false,
                ),
                keyboardActions = KeyboardActions(onAny = {
                    keyboard?.hide()
                    editing = false
                    focusRequester.requestFocus()
                    onSubmit()
                }),
                decorationBox = { inner ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (value.isEmpty()) {
                            Text(
                                placeholder,
                                style = McType.size(25),
                                color = if (lit) Color.Black.copy(alpha = 0.45f) else McColors.Secondary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        inner()
                    }
                },
            )
        }
    }
    LaunchedEffect(editTrigger) {
        if (editTrigger > 0) editing = true
    }
    LaunchedEffect(editing) {
        if (editing) {
            field.requestFocus()
            keyboard?.show()
        }
    }
}

/** 输入框聚焦 / 编辑时的浅灰底 */
private val FieldLit = Color(0xFFE7E7E7)

/** 红色的出错说明（Label + exclamationmark.triangle.fill） */
@Composable
fun ErrorLabel(message: String, modifier: Modifier = Modifier, style: TextStyle = McType.Callout) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(14.pt), verticalAlignment = Alignment.Top) {
        Icon(McIcons.Warning, null, tint = McColors.Danger, modifier = Modifier.padding(top = 4.pt).size(34.pt))
        Text(message, style = style, color = McColors.Danger)
    }
}

/** 转圈 + 次要色说明（「正在局域网里寻找 MovieClaw…」） */
@Composable
fun StatusLine(text: String, spacing: Dp = 16.pt, color: Color = McColors.Secondary) {
    Row(horizontalArrangement = Arrangement.spacedBy(spacing), verticalAlignment = Alignment.CenterVertically) {
        Spinner(sizePt = 44)
        Text(text, style = McType.Body, color = color)
    }
}

/** 浮在星空上的一张玻璃卡：左对齐竖排，内边 60、圆角 48 */
@Composable
fun WelcomeCard(widthPt: Int?, spacingPt: Int, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        modifier
            .then(if (widthPt != null) Modifier.width(widthPt.pt) else Modifier)
            .glass()
            .padding(60.pt),
        verticalArrangement = Arrangement.spacedBy(spacingPt.pt),
    ) { content() }
}

/** 进入页面时把焦点交给它（焦点系统还没准备好时隔一会儿再试几次） */
@Composable
fun InitialFocus(requester: FocusRequester, key: Any? = Unit) {
    LaunchedEffect(key) {
        for (wait in listOf(0L, 50L, 100L, 200L, 400L)) {
            delay(wait)
            if (runCatching { requester.requestFocus() }.getOrDefault(false)) return@LaunchedEffect
        }
    }
}

/** 头像地址带上账号名（AvatarURL.tagged）：同一台服务器上不同账号的头像缓存分开 */
fun taggedAvatar(raw: String?, username: String): String? {
    if (raw.isNullOrEmpty() || raw.contains("mc_account=")) return raw
    val separator = if (raw.contains('?')) "&" else "?"
    return raw + separator + "mc_account=" + java.net.URLEncoder.encode(username, "UTF-8").replace("+", "%20")
}

/**
 * 选人大头像按钮（TVProfileButton + TVProfileButtonStyle）：获得焦点的那个整体提亮、头像放大 1.12 套 6pt 白边；
 * 其余压暗到 0.65；按下缩到 0.97。下面昵称（headline）与服务器（caption 次要色）不跟着放大。
 */
@Composable
fun ProfileTile(
    saved: SavedAccount,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    current: Boolean = false,
) {
    ProfileButton(onClick, modifier) { focused ->
        CompositionLocalProvider(LocalServer provides saved.server) {
            Avatar(
                name = saved.account.nickname,
                image = taggedAvatar(saved.account.avatarUrl, saved.account.username),
                sizePt = 220,
                focused = focused,
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.pt)) {
            Text(saved.account.nickname, style = McType.Headline, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                if (current) "正在使用 · ${saved.server.hostLabel}" else saved.server.hostLabel,
                style = McType.Caption,
                color = McColors.Secondary,
                maxLines = 1,
            )
        }
    }
}

/** 「添加账号」：同样的按钮样式，白 10% 的圆 + 加号；[captionLine] 时下面补一行空说明，和旁边头像的字对齐 */
@Composable
fun AddAccountTile(onClick: () -> Unit, modifier: Modifier = Modifier, captionLine: Boolean = true) {
    ProfileButton(onClick, modifier) { focused ->
        val scale by animateFloatAsState(if (focused) McMetrics.AvatarFocusZoom else 1f, tween(200), label = "add")
        Box(
            Modifier
                .size(220.pt)
                .scale(scale)
                .then(if (focused) Modifier.shadow(28.pt, CircleShape, spotColor = Color.Black.copy(alpha = 0.55f)) else Modifier)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.1f))
                .then(if (focused) Modifier.border(6.pt, Color.White, CircleShape) else Modifier),
            contentAlignment = Alignment.Center,
        ) {
            Icon(McIcons.Plus, null, tint = Color.White, modifier = Modifier.size(80.pt))
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.pt)) {
            Text("添加账号", style = McType.Headline)
            if (captionLine) Text(" ", style = McType.Caption)
        }
    }
}

/** 选人按钮的外壳：不放大、不裁切、不带系统焦点框（头像放大后要伸出格子），焦点状态交给 [content] 自己画 */
@Composable
private fun ProfileButton(onClick: () -> Unit, modifier: Modifier, content: @Composable (focused: Boolean) -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val pressed by interaction.collectIsPressedAsState()
    val alpha by animateFloatAsState(if (focused) 1f else 0.65f, tween(200), label = "profile")
    val scale by animateFloatAsState(if (pressed) 0.97f else 1f, tween(200), label = "profile-press")
    Column(
        modifier
            .layerFocus()
            .tvClickable(interaction, onClick)
            .graphicsLayer {
                this.alpha = alpha
                scaleX = scale
                scaleY = scale
            }
            .padding(horizontal = 12.pt, vertical = 24.pt),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.pt),
    ) { content(focused) }
}

/** 遥控器能选中、按确认触发的一块区域，没有任何默认的焦点外观（外观由调用方按焦点状态自己画） */
fun Modifier.tvClickable(interaction: MutableInteractionSource, onClick: () -> Unit): Modifier =
    clickable(interactionSource = interaction, indication = null, onClick = onClick)

/** 一台服务器的地址给人看的写法（Apple 端 displayString：完整的 origin，如 http://192.168.1.10:3000） */
val ServerAddress.fullDisplay: String get() = toString()

/**
 * 换了账号之后的一句提示（Apple 端 pendingNotice，tvOS 上其实从没弹出来过）：主界面会整棵重建，
 * 页面里的提示条会跟着消失，所以用系统 Toast。
 */
fun showNotice(context: android.content.Context, text: String) {
    android.widget.Toast.makeText(context.applicationContext, text, android.widget.Toast.LENGTH_LONG).show()
}

/** 「已切换到「某某」」；换到另一台服务器时写上是哪台 */
fun switchedNotice(nickname: String, server: ServerAddress, previous: ServerAddress?): String =
    "已切换到「$nickname」" + if (server != previous) " · ${server.hostLabel}" else ""
