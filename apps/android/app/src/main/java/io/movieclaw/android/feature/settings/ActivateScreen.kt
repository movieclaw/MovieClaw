package io.movieclaw.android.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warning
import io.movieclaw.android.core.model.DeviceRequestView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 批准设备登录（`/activate`；iOS `DeviceApprovalFlow`、Web `device-approval.tsx` 的对应页）。
 *
 * 电视 / 命令行 / 转码器上发起配对后显示一个码，人在这里输进来、核对、批准——
 * **谁批准，令牌就是谁的**（成员批准的命令行权限 = 这个成员的权限；转码器只能超管批）。
 * 防钓鱼的那道人工闸是「先核对与设备屏幕上显示的配对码完全一致」，所以码用大号等宽字。
 *
 * 文案照上游原文（`DeviceText` / Web `devices-display.ts`——措辞是安全设计的一部分，不自行改写）：
 * 输入页说明、审批卡的「将获得：…」、来源 IP、以及「以「X」的身份批准 · 换账号请先在「我的」页切换」。
 * 扫码入口（iOS 主路径）本批未做：需要相机权限与新依赖，单独一步加；输入的配对码归一化照
 * iOS `PairingQRCode.normalize`（去掉分隔符 → 校验 4 位 → 补回 `MCLW-XXXX`）。
 */
@HiltViewModel
class ActivateViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    sealed interface Step {
        /** 输配对码 */
        data object Input : Step
        /** 拉到的请求详情（确认页） */
        data class Confirm(val request: DeviceRequestView) : Step
        /** 完成（批准 / 拒绝后的收尾） */
        data class Done(val approved: Boolean, val clientName: String) : Step
    }

    data class Ui(
        val step: Step = Step.Input,
        val loading: Boolean = false,
        val error: String? = null,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui = _ui.asStateFlow()

    val origin: String? get() = repository.ui.value.origin
    val isAdmin: Boolean get() = repository.ui.value.session?.role == "admin"

    /** 「以谁的身份批准」：批准后设备即登录成这个账号 */
    val approverName: String
        get() = repository.ui.value.session?.let { s ->
            s.nickname?.takeIf { it.isNotBlank() } ?: s.username
        } ?: "当前账号"

    /**
     * 配对码归一化（照 iOS `PairingQRCode.normalize`）：去分隔符与空白 → 大写 → 4 位字母数字
     * → 补回 `MCLW-XXXX`；对不上格式返回 null（界面上给「配对码形如 MCLW-7F3K」的提示）。
     */
    fun normalizeCode(raw: String): String? {
        val compact = raw.trim()
            .replace(Regex("[\\s\\-_\uFF0D\u2014\u2013]"), "")
            .uppercase()
        val body = when {
            compact.length == 8 && compact.startsWith("MCLW") -> compact.drop(4)
            compact.length == 4 -> compact
            else -> return null
        }
        if (body.any { it !in 'A'..'Z' && it !in '0'..'9' }) return null
        return "MCLW-$body"
    }

    fun lookup(rawCode: String) {
        val code = normalizeCode(rawCode) ?: run {
            _ui.update { it.copy(error = "配对码形如 MCLW-7F3K，请对照设备上显示的重新输入。") }
            return
        }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            runCatching { apiFactory.forOrigin(origin).deviceRequest(code).dataOrThrow() }
                .onSuccess { view -> _ui.update { it.copy(loading = false, step = Step.Confirm(view)) } }
                .onFailure { e ->
                    val msg = if (e is retrofit2.HttpException && e.code() == 404) {
                        "没有找到配对码 $code 的请求：请核对设备上显示的码，或让设备重新发起（配对码 5 分钟内有效）。"
                    } else {
                        friendlyMessage(e)
                    }
                    _ui.update { it.copy(loading = false, error = msg) }
                }
        }
    }

    fun approve(request: DeviceRequestView) = act(request, approve = true)

    fun deny(request: DeviceRequestView) = act(request, approve = false)

    private fun act(request: DeviceRequestView, approve: Boolean) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            val call = runCatching {
                if (approve) {
                    apiFactory.forOrigin(origin).approveDeviceRequest(request.userCode).dataOrThrow()
                } else {
                    apiFactory.forOrigin(origin).denyDeviceRequest(request.userCode).dataOrThrow()
                }
            }
            call.onSuccess {
                _ui.update { it.copy(loading = false, step = Step.Done(approve, request.clientName)) }
            }.onFailure { e ->
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }

    fun reset() {
        _ui.value = Ui()
    }
}

@Composable
fun ActivateScreen(
    onBack: () -> Unit,
    vm: ActivateViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    var code by remember { mutableStateOf("") }

    Column(
        Modifier
            .fillMaxSize()
            .background(Bg)
            .verticalScroll(rememberScrollState()),
    ) {
        io.movieclaw.android.core.designsystem.McTopBar(
            variant = io.movieclaw.android.core.designsystem.McTopBarVariant.Sub,
            title = "批准设备登录",
            // 审批卡里「返回」= 换一个码重来（还没批准任何东西）；输入页的返回才是离开
            onBack = { if (ui.step is ActivateViewModel.Step.Confirm) vm.reset() else onBack() },
        )

        when (val step = ui.step) {
            ActivateViewModel.Step.Input -> Column(Modifier.padding(horizontal = 24.dp)) {
                Spacer(Modifier.height(18.dp))
                // 说明照 Web `device-approval.tsx` 原文（本端暂无扫码，故不带 iOS 那句「或者扫它旁边的二维码」）
                Text(
                    "输入 Apple TV、命令行（mclaw login）或转码器上显示的配对码。",
                    style = McType.footnote, color = TextMuted, lineHeight = 20.sp,
                )
                Spacer(Modifier.height(20.dp))
                OutlinedTextField(
                    value = code,
                    onValueChange = { value -> code = value.uppercase().take(12) },
                    singleLine = true,
                    textStyle = McType.title3.copy(
                        color = TextPrimary, fontFamily = FontFamily.Monospace,
                        letterSpacing = 3.sp, textAlign = TextAlign.Center,
                    ),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Ascii,
                        imeAction = ImeAction.Go,
                    ),
                    placeholder = { Text("MCLW-XXXX", style = McType.body, color = TextFaint) },
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color.White.copy(alpha = 0.3f),
                        unfocusedBorderColor = Color.White.copy(alpha = 0.15f),
                        cursorColor = Accent,
                    ),
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.fillMaxWidth(),
                )
                ui.error?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, style = McType.footnote, color = Danger, lineHeight = 18.sp)
                }
                Spacer(Modifier.height(18.dp))
                Button(
                    onClick = { vm.lookup(code) },
                    enabled = !ui.loading && code.isNotBlank(),
                    shape = RoundedCornerShape(999.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color(0xFF141821)),
                    elevation = null,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(46.dp)
                        .background(
                            Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))),
                            RoundedCornerShape(999.dp),
                        ),
                ) {
                    if (ui.loading) {
                        CircularProgressIndicator(color = Color(0xFF141821), modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                    }
                    Text("继续", style = McType.bodySemibold)
                }
            }

            is ActivateViewModel.Step.Confirm -> {
                val request = step.request
                val blocked = request.requiresAdmin && !vm.isAdmin
                val grant = grantText(request.clientType, vm.isAdmin)
                Column(Modifier.padding(horizontal = 24.dp)) {
                    Spacer(Modifier.height(18.dp))
                    // 设备行：图标 + 名字 +（平台 ?? 类型说法）——iOS 审批卡同款
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            Modifier
                                .size(52.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.1f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                clientTypeIcon(request.clientType),
                                contentDescription = null,
                                tint = TextPrimary,
                                modifier = Modifier.size(24.dp),
                            )
                        }
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(request.clientName, style = McType.title3, color = TextPrimary, maxLines = 1)
                            Text(
                                request.platform?.takeIf { it.isNotBlank() }
                                    ?: clientTypeLabel(request.clientType),
                                style = McType.sub, color = TextMuted, maxLines = 1,
                            )
                        }
                    }
                    Spacer(Modifier.height(18.dp))
                    // 配对码：大号等宽 + 字距——它要被拿去和设备屏幕逐字比对，这是这张卡真正的安全控制
                    Text(
                        request.userCode,
                        fontSize = 34.sp, fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                        fontFamily = FontFamily.Monospace, letterSpacing = 5.sp,
                        color = Accent,
                    )
                    Text(
                        "先核对与设备屏幕上显示的配对码完全一致",
                        style = McType.footnote, color = TextMuted,
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(grant.first, style = McType.subSemibold, color = TextPrimary)
                    Spacer(Modifier.height(2.dp))
                    Text(grant.second, style = McType.footnote, color = TextMuted, lineHeight = 19.sp)
                    // 来源地址认得出时才写（桥接网络的容器只看得到网桥网关，那时不如不写，判断依据就是配对码）
                    if (request.sourceIp.isNotBlank()) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "来源 ${request.sourceIp}",
                            style = McType.footnote.copy(fontFamily = FontFamily.Monospace),
                            color = TextFaint,
                        )
                    }
                    if (blocked) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            "转码器只能由管理员批准：请把这个配对码告诉管理员，让他在网页或 App 的批准页输入。",
                            style = McType.footnote, color = Warning, lineHeight = 18.sp,
                        )
                    }
                    ui.error?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, style = McType.footnote, color = Danger, lineHeight = 18.sp)
                    }
                    Spacer(Modifier.height(20.dp))
                    if (!blocked) {
                        Button(
                            onClick = { vm.approve(request) },
                            enabled = !ui.loading,
                            shape = RoundedCornerShape(999.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color(0xFF141821)),
                            elevation = null,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(46.dp)
                                .background(
                                    Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))),
                                    RoundedCornerShape(999.dp),
                                ),
                        ) {
                            if (ui.loading) {
                                CircularProgressIndicator(color = Color(0xFF141821), modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(8.dp))
                            }
                            Text("批准登录", style = McType.bodySemibold)
                        }
                    }
                    TextButton(
                        onClick = { vm.deny(request) },
                        enabled = !ui.loading,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("拒绝", style = McType.subheadline, color = TextMuted)
                    }
                    // 「以谁的身份批准」：批准的后果是设备登录成这个账号，必须写明
                    Text(
                        "以「${vm.approverName}」的身份批准 · 换账号请先在「我的」页切换",
                        style = McType.caption, color = TextMuted, textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            is ActivateViewModel.Step.Done -> Column(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(64.dp))
                Text(
                    if (step.approved) "已批准" else "已拒绝",
                    style = McType.title2, color = TextPrimary,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    if (step.approved) {
                        "「${step.clientName}」会在几秒内自动登录，回到那台设备上继续就好。"
                    } else {
                        "这台设备不会登录。如果它其实是你的，让它重新发起配对即可。"
                    },
                    style = McType.sub, color = TextMuted, textAlign = TextAlign.Center, lineHeight = 21.sp,
                )
                Spacer(Modifier.height(24.dp))
                Button(
                    onClick = onBack,
                    shape = RoundedCornerShape(999.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = Color(0xFF141821)),
                    elevation = null,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(46.dp)
                        .background(
                            Brush.linearGradient(listOf(Color(0xFFF6F8FC), Color(0xFFCCD6E6))),
                            RoundedCornerShape(999.dp),
                        ),
                ) {
                    Text("完成", style = McType.bodySemibold)
                }
            }
        }
    }
}

/** 客户端形态 → 给人看的说法（照 Web `devices-display.ts` / iOS `DeviceText`，内部值不上屏） */
private fun clientTypeLabel(type: String): String = when (type) {
    "worker" -> "转码器"
    "cli" -> "命令行 / Agent"
    "tvos" -> "Apple TV"
    "manual" -> "手工令牌"
    else -> "未知类型"
}

private fun clientTypeIcon(type: String): ImageVector = when (type) {
    "tvos" -> Icons.Rounded.Tv
    "cli" -> Icons.Rounded.Terminal
    "worker" -> Icons.Rounded.Memory
    else -> Icons.Rounded.Computer
}

/**
 * 「将获得」：权限说明照 iOS `DeviceText.grant` 原文——三条硬要求都在这里：
 * 说人话（不出现 scope 之类内部名词）、谁批准令牌就是谁的（超管批的是完全权限，成员批的是他自己的那份）、
 * 不认识的形态按最危险的一档解释。
 */
private fun grantText(type: String, isAdmin: Boolean): Pair<String, String> = when (type) {
    "worker" -> "将获得：仅限转码" to
        "这台机器不能查看或修改你的订阅、媒体库和设置。"
    "tvos" -> (if (isAdmin) "将获得：这台 Apple TV 以你的超级管理员身份登录" else "将获得：这台 Apple TV 以你的身份登录") to
        "等同你在这台电视上输入账号密码登录：它能看到你能看到的媒体库、记录你的观看进度。只批准你面前这台电视上显示的配对码。"
    else -> (if (isAdmin) "将获得：与你相同的完全权限" else "将获得：与你相同的权限") to
        "这台机器上的程序将能做你在网页上能做的一切，包括删除媒体文件。只在你清楚这台机器上正在运行什么程序时才批准。"
}
