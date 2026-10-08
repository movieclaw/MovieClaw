package io.movieclaw.androidtv.ui.welcome

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.tv.material3.Icon
import androidx.tv.material3.Text
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.core.model.generated.DeviceAuthorizeRequest
import io.movieclaw.androidtv.core.model.generated.DeviceAuthorizeView
import io.movieclaw.androidtv.core.network.ClientIdentity
import io.movieclaw.androidtv.core.network.OkHttpTransport
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.network.generated.McApi
import io.movieclaw.androidtv.core.session.AppModel
import io.movieclaw.androidtv.core.session.Pairing
import io.movieclaw.androidtv.core.session.PairingStatus
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.Spinner
import io.movieclaw.androidtv.ui.components.glass
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.theme.ptSp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * 登录这一步（TVSignInStep）：默认扫码（[PairingLogin]），可以改用账号密码（[SignInForm]），切换没有过渡。
 */
@Composable
fun SignInStep(server: ServerAddress, prefilledUsername: String?, expired: Boolean, onChangeServer: () -> Unit) {
    var usePassword by rememberSaveable(server.toString()) { mutableStateOf(false) }
    if (usePassword) {
        SignInForm(server, prefilledUsername, expired, onUseQrCode = { usePassword = false }, onChangeServer = onChangeServer)
    } else {
        PairingLogin(server, onUsePassword = { usePassword = true }, onChangeServer = onChangeServer)
    }
}

/**
 * 扫码登录（TVPairingLogin）：电视上显示配对码与二维码，人用手机扫码打开网页批准页（或在已登录的浏览器里输入配对码），
 * 谁批准电视就登录成谁。协议与状态见 [Pairing]。比 Apple 端多一个「更换服务器」（Apple 只能绕道账号密码页）。
 */
@Composable
fun PairingLogin(server: ServerAddress, onUsePassword: () -> Unit, onChangeServer: () -> Unit) {
    val graph = LocalGraph.current
    var challenge by remember { mutableStateOf<DeviceAuthorizeView?>(null) }
    var status by remember { mutableStateOf<PairingStatus>(PairingStatus.Requesting) }
    // 加一就重新发起一次（「换一个码」）
    var attempt by remember { mutableIntStateOf(0) }
    val usePasswordFocus = remember { FocusRequester() }

    LaunchedEffect(server, attempt) {
        val api = McApi(OkHttpTransport(server.apiBase, graph.http))
        val request = DeviceAuthorizeRequest(
            clientType = ClientIdentity.KIND,
            clientName = graph.deviceName,
            installationId = graph.store.installationId,
            platform = graph.identity.platform,
            clientVersion = graph.identity.appVersion,
        )
        Pairing.run(
            api, server, request,
            onChallenge = { challenge = it },
            onStatus = { status = it },
            signIn = { token -> graph.model.signIn(server, token) },
        )
    }
    InitialFocus(usePasswordFocus)

    Row(
        Modifier.glass().padding(60.pt).focusGroup(),
        horizontalArrangement = Arrangement.spacedBy(80.pt),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.width(820.pt), verticalArrangement = Arrangement.spacedBy(30.pt)) {
            Text("用手机扫码登录", style = welcomeSerif(52))
            Text(
                "用手机相机，或 iPhone 上 MovieClaw「我的」页右上角的扫码，扫右边的二维码后批准。" +
                    "不方便扫码的话，在任何已登录的电脑或手机浏览器里打开下面的地址，输入配对码。谁批准，这台电视就登录成谁。",
                style = McType.Callout,
                color = McColors.Secondary,
            )
            challenge?.let {
                // 同 Netflix 的「访问 netflix.com/tv8」：批准页地址直接写在屏幕上，不扫码也找得到
                Text(Pairing.displayAddress(it.verificationUri), style = McType.Title3.copy(fontWeight = FontWeight.Medium))
                Text(
                    it.userCode,
                    style = McType.size(72, FontWeight.SemiBold).copy(fontFamily = FontFamily.Monospace, letterSpacing = 6.ptSp),
                )
            }
            when (val s = status) {
                PairingStatus.Requesting -> StatusLine("正在向服务器申请配对码…")
                PairingStatus.Waiting -> StatusLine("等待批准…（配对码 5 分钟内有效）")
                PairingStatus.SigningIn -> StatusLine("已批准，正在登录…")
                is PairingStatus.Failed -> ErrorLabel(s.message)
            }
            Row(Modifier.padding(top = 10.pt), horizontalArrangement = Arrangement.spacedBy(24.pt)) {
                if (status is PairingStatus.Failed) WelcomeButton("换一个码", onClick = { attempt++ })
                WelcomeButton("改用账号密码登录", onClick = onUsePassword, modifier = Modifier.focusRequester(usePasswordFocus))
                WelcomeButton("更换服务器", onClick = onChangeServer)
            }
        }
        QrCodeBox(challenge?.verificationUriComplete)
    }
}

/** 二维码：白色圆角方块 440，内缩 28；内容是带码的批准页地址（扫了直接打开、预填好这个码）。码没到之前转圈 */
@Composable
private fun QrCodeBox(text: String?) {
    val bitmap = remember(text) { text?.let(::qrBitmap)?.asImageBitmap() }
    Box(Modifier.size(440.pt).background(Color.White, RoundedCornerShape(28.pt)), contentAlignment = Alignment.Center) {
        if (bitmap != null) {
            Image(
                bitmap,
                contentDescription = null,
                modifier = Modifier.fillMaxSize().padding(28.pt),
                contentScale = ContentScale.FillBounds,
                // 最近邻放大：模块边缘锐利，不糊
                filterQuality = FilterQuality.None,
            )
        } else {
            Spinner(color = Color.Black)
        }
    }
}

/** 生成二维码位图：纠错等级 M，一个模块一个像素（显示时最近邻放大） */
private fun qrBitmap(text: String): Bitmap? = runCatching {
    val matrix = QRCodeWriter().encode(
        text, BarcodeFormat.QR_CODE, 0, 0,
        mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 1, EncodeHintType.CHARACTER_SET to "UTF-8"),
    )
    val pixels = IntArray(matrix.width * matrix.height) { i ->
        if (matrix.get(i % matrix.width, i / matrix.width)) android.graphics.Color.BLACK else android.graphics.Color.WHITE
    }
    Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
}.getOrNull()

/**
 * 账号密码登录（TVSignInForm，兜底方式）。提交时先测服务器（健康、最低版本、是否初始化）再换设备令牌，
 * 文案见 [AppModel.signIn]。
 */
@Composable
fun SignInForm(
    server: ServerAddress,
    prefilledUsername: String?,
    expired: Boolean,
    onUseQrCode: () -> Unit,
    onChangeServer: () -> Unit,
) {
    val model = LocalGraph.current.model
    val scope = rememberCoroutineScope()
    var username by rememberSaveable { mutableStateOf(prefilledUsername.orEmpty()) }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val usernameFocus = remember { FocusRequester() }
    val passwordFocus = remember { FocusRequester() }
    // 键盘上按「下一项」：直接接着输密码
    var editPassword by remember { mutableIntStateOf(0) }

    fun submit() {
        if (busy || username.isEmpty() || password.isEmpty()) return
        busy = true
        error = null
        scope.launch {
            try {
                if (model.signIn(server, username.trim(), password) == AppModel.SignInResult.NeedsSetup) {
                    error = "这台服务器还没初始化：请先在浏览器里打开 ${server.fullDisplay} 创建管理员账号。"
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: "登录失败"
            } finally {
                busy = false
            }
        }
    }

    // 用户名已经填好（登录过期）就直接落在密码上
    InitialFocus(if (username.isEmpty()) usernameFocus else passwordFocus)

    WelcomeCard(1100, 30, Modifier.focusGroup()) {
        Text(if (expired) "重新登录" else "登录 MovieClaw", style = welcomeSerif(52))
        Row(horizontalArrangement = Arrangement.spacedBy(20.pt), verticalAlignment = Alignment.CenterVertically) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.pt), verticalAlignment = Alignment.CenterVertically) {
                Icon(McIcons.Server, null, tint = McColors.Secondary, modifier = Modifier.size(36.pt))
                Text(server.fullDisplay, style = McType.Body, color = McColors.Secondary)
            }
            WelcomeButton("更换", onClick = onChangeServer)
        }
        if (expired && prefilledUsername != null) {
            Text("「$prefilledUsername」的登录已失效，请重新输入密码。", style = McType.Callout, color = McColors.Warning)
        }
        TvTextField(
            username, { username = it }, "用户名",
            Modifier.fillMaxWidth(),
            focusRequester = usernameFocus,
            imeAction = ImeAction.Next,
            onSubmit = { editPassword++ },
        )
        TvTextField(
            password, { password = it }, "密码",
            Modifier.fillMaxWidth(),
            focusRequester = passwordFocus,
            password = true,
            editTrigger = editPassword,
            imeAction = ImeAction.Done,
            onSubmit = ::submit,
        )
        error?.let { ErrorLabel(it) }
        Row(horizontalArrangement = Arrangement.spacedBy(24.pt)) {
            WelcomeButton(
                if (busy) "正在连接…" else "登录",
                onClick = ::submit,
                enabled = !busy && username.isNotEmpty() && password.isNotEmpty(),
                leading = if (busy) ({ Spinner(sizePt = 36) }) else null,
            )
            WelcomeButton("改用扫码登录", onClick = onUseQrCode)
        }
    }
}
