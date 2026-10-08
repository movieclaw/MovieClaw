package io.movieclaw.androidtv.ui.accounts

import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import io.movieclaw.androidtv.ui.components.TvScrollSpec
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Brush
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import io.movieclaw.androidtv.BuildConfig
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.androidtv.core.network.ServerAddress
import io.movieclaw.androidtv.core.session.NeedsPasswordException
import io.movieclaw.androidtv.core.session.SavedAccount
import io.movieclaw.androidtv.ui.components.McIcons
import io.movieclaw.androidtv.ui.components.glass
import io.movieclaw.androidtv.ui.shell.LocalRouter
import io.movieclaw.androidtv.ui.shell.MainTab
import io.movieclaw.androidtv.ui.shell.Route
import io.movieclaw.androidtv.ui.theme.McColors
import io.movieclaw.androidtv.ui.theme.McMetrics
import io.movieclaw.androidtv.ui.theme.McType
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.androidtv.ui.welcome.AddAccountTile
import io.movieclaw.androidtv.ui.welcome.CosmosBackdrop
import io.movieclaw.androidtv.ui.welcome.InitialFocus
import io.movieclaw.androidtv.ui.welcome.ProfileTile
import io.movieclaw.androidtv.ui.welcome.ServerPicker
import io.movieclaw.androidtv.ui.welcome.showNotice
import io.movieclaw.androidtv.ui.welcome.switchedNotice
import io.movieclaw.androidtv.ui.welcome.SignInStep
import io.movieclaw.androidtv.ui.welcome.WelcomeButton
import io.movieclaw.androidtv.ui.welcome.welcomeSerif
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import io.movieclaw.androidtv.ui.components.layerFocus

/**
 * 谁在看（TVWhoIsWatchingView）：本机登录过的全部账号（跨服务器）大头像横排，星空背景，焦点放大，按确认键进入。
 * 放在侧边栏的「账号」页签里：当前账号默认获得焦点（打开时、从下面一行往上回来时都落在它上面）。
 * 选自己回首页；选别人就换一枚令牌（不用密码），主界面整棵重建。返回键交给外壳（展开侧边栏）。
 * 底部一行「关于」「退出登录」——电视上与账号有关的操作都在这一页。
 */
@Composable
fun AccountsScreen() {
    val graph = LocalGraph.current
    val model = graph.model
    val session = LocalSession.current
    val router = LocalRouter.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val servers by model.savedServers.collectAsState()
    val accounts = servers.flatMap { saved -> saved.accounts.map { SavedAccount(saved.address, it) } }
    val currentId = "${session.server}#${session.session.username}"

    var error by remember { mutableStateOf<String?>(null) }
    var addingAccount by remember { mutableStateOf(false) }
    var confirmingLogout by remember { mutableStateOf(false) }
    // 从关于页回来时焦点回到「关于」上
    var returnToAbout by rememberSaveable { mutableStateOf(false) }
    val currentFocus = remember { FocusRequester() }
    val aboutFocus = remember { FocusRequester() }
    val redirecting = remember { booleanArrayOf(false) }

    InitialFocus(if (returnToAbout) aboutFocus else currentFocus)
    LaunchedEffect(Unit) { returnToAbout = false }

    fun pick(saved: SavedAccount) {
        if (saved.id == currentId) {
            router.select(MainTab.Home)
            return
        }
        scope.launch {
            try {
                model.switchAccount(saved.account.username, saved.server)
                model.session?.let { showNotice(context, switchedNotice(it.nickname, saved.server, session.server)) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: NeedsPasswordException) {
                // 这个账号的登录失效了：到「添加账号」里重新登录
                error = "「${saved.account.nickname}」的登录已失效，请在「添加账号」里重新登录"
            } catch (e: Exception) {
                error = e.message
            }
        }
    }

    /** 焦点从别处进这一组时改落在 [target] 上（不按位置挑最近的） */
    fun Modifier.enterAt(target: FocusRequester) = focusProperties {
        onEnter = {
            if (!redirecting[0]) {
                redirecting[0] = true
                runCatching { target.requestFocus() }
                redirecting[0] = false
            }
        }
    }.focusGroup()

    Box(Modifier.fillMaxSize()) {
        CosmosBackdrop(lit = true, dimmed = true)
        Column(
            // tvOS 在页签里居中的是安全区（上沿让出页签栏那一截）：整块比屏幕正中低 40（两台模拟器截图量出）
            Modifier.fillMaxSize().padding(top = 80.pt),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(70.pt, Alignment.CenterVertically),
        ) {
            Text("谁在看？", style = welcomeSerif(72))
            // 放得下就居中摆一排；账号太多才横向滚动
            LazyRow(
                Modifier.fillMaxWidth().enterAt(currentFocus),
                // 上下只留焦点放大的余量（横向列表在竖直方向本来就多给一截不裁）
                contentPadding = PaddingValues(horizontal = McMetrics.Edge, vertical = 16.pt),
                horizontalArrangement = Arrangement.spacedBy(70.pt, Alignment.CenterHorizontally),
            ) {
                items(accounts, key = { it.id }) { saved ->
                    ProfileTile(
                        saved,
                        onClick = { pick(saved) },
                        current = saved.id == currentId,
                        modifier = if (saved.id == currentId) Modifier.focusRequester(currentFocus) else Modifier,
                    )
                }
                item(key = "add") { AddAccountTile({ addingAccount = true }) }
            }
            error?.let { Text(it, style = McType.Body, color = McColors.Danger) }
            // 次要操作：小一号、靠下；从头像往下进这一行先落在「关于」上（「退出登录」手一滑就点到了）
            Row(Modifier.enterAt(aboutFocus), horizontalArrangement = Arrangement.spacedBy(30.pt)) {
                WelcomeButton(
                    "关于",
                    onClick = {
                        returnToAbout = true
                        router.push(Route.About)
                    },
                    icon = McIcons.Info,
                    style = McType.Callout,
                    modifier = Modifier.focusRequester(aboutFocus),
                )
                WelcomeButton("退出登录", onClick = { confirmingLogout = true }, icon = McIcons.Logout, style = McType.Callout, destructive = true)
            }
        }
    }

    if (addingAccount) AddAccountCover(session.server) { addingAccount = false }
    if (confirmingLogout) {
        LogoutAlert(
            nickname = session.session.nickname,
            onConfirm = {
                confirmingLogout = false
                // 比页面活得久：退出后主界面整棵重建，注销请求不能跟着页面一起被取消
                graph.appScope.launch {
                    // 退出后人还在 App 里，很容易以为没退成：明确说出现在换成了谁
                    model.logout()?.let { showNotice(context, "已退出「${session.session.nickname}」，已切换到「${it.nickname}」") }
                }
            },
            onCancel = { confirmingLogout = false },
        )
    }
}

/**
 * 添加账号（TVAddAccountView）：盖满整屏，星空（压暗）上是当前服务器的登录（先扫码），账号密码页的「更换」打开找服务器。
 * 返回键关掉。登录成功后 AppModel 直接切到新账号、主界面整棵重建，这一层随之消失。
 */
@Composable
private fun AddAccountCover(current: ServerAddress, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        var server by remember { mutableStateOf<ServerAddress?>(current) }
        Box(Modifier.fillMaxSize()) {
            CosmosBackdrop(lit = true, dimmed = true)
            Box(Modifier.fillMaxSize().padding(McMetrics.Edge), contentAlignment = Alignment.Center) {
                val picked = server
                if (picked != null) {
                    SignInStep(picked, prefilledUsername = null, expired = false) { server = null }
                } else {
                    ServerPicker { server = it }
                }
            }
        }
    }
}

/** 「退出登录？」确认框：默认落在「取消」上 */
@Composable
private fun LogoutAlert(nickname: String, onConfirm: () -> Unit, onCancel: () -> Unit) {
    Dialog(onDismissRequest = onCancel, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val cancel = remember { FocusRequester() }
        InitialFocus(cancel)
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(
                Modifier.widthIn(max = 900.pt).glass().padding(60.pt).focusGroup(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(24.pt),
            ) {
                Text("退出登录？", style = McType.Title3.copy(fontWeight = FontWeight.SemiBold))
                Text(
                    "「$nickname」在这台电视上的登录会在服务器上一并注销。同一台服务器上还有别的账号时会自动切过去。",
                    style = McType.Callout,
                    color = McColors.Secondary,
                    textAlign = TextAlign.Center,
                )
                Column(Modifier.padding(top = 12.pt), verticalArrangement = Arrangement.spacedBy(20.pt), horizontalAlignment = Alignment.CenterHorizontally) {
                    WelcomeButton("退出", onClick = onConfirm, destructive = true, modifier = Modifier.widthIn(min = 500.pt))
                    WelcomeButton("取消", onClick = onCancel, modifier = Modifier.widthIn(min = 500.pt).focusRequester(cancel))
                }
            }
        }
    }
}

/**
 * 关于（TVAboutView，收在「谁在看」里）：版本、开源组件与许可全文、数据来源声明。电视上没有浏览器，地址只显示、不能点开。
 */
@Composable
fun AboutScreen() {
    val router = LocalRouter.current
    val first = remember { FocusRequester() }
    InitialFocus(first)
    // 只在焦点那一格露不全时才滚（同 tvOS）：进页面焦点落在第一个组件上，页头照常露着
    TvScrollSpec(80) {
    Column(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(McColors.SystemTop, McColors.SystemBottom)))
            .verticalScroll(rememberScrollState())
            .padding(start = McMetrics.Edge, end = McMetrics.Edge, top = McMetrics.PushedTop + 40.pt, bottom = 40.pt),
        verticalArrangement = Arrangement.spacedBy(48.pt),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(16.pt)) {
            Text("MovieClaw", style = McType.Title)
            Text("版本 ${BuildConfig.VERSION_NAME}（${BuildConfig.VERSION_CODE}）", style = McType.Callout, color = McColors.Secondary)
            Text(
                "MovieClaw 是自托管服务的客户端：你的媒体、账号与观看记录都在你自己部署的服务器上，App 不向开发者或任何第三方上传数据。" +
                    "项目主页：github.com/movieclaw/movieclaw",
                style = McType.Callout,
                color = McColors.Secondary,
                modifier = Modifier.widthIn(max = 1300.pt),
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(20.pt)) {
            Text("开源组件", style = McType.Title3.copy(fontWeight = FontWeight.SemiBold))
            Text(
                "播放使用 AndroidX Media3（ExoPlayer），与下方各组件一样按各自的开源许可随 App 分发；" +
                    "你可以按各自的许可获取源码、修改并替换。选中组件可查看源码地址与许可全文。",
                style = McType.Callout,
                color = McColors.Secondary,
                modifier = Modifier.widthIn(max = 1300.pt),
            )
            // 两列网格：列距 40、行距 30
            Column(Modifier.focusGroup(), verticalArrangement = Arrangement.spacedBy(30.pt)) {
                OpenSourceComponent.all.chunked(2).forEachIndexed { row, pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(40.pt)) {
                        pair.forEachIndexed { column, component ->
                            ComponentCell(
                                component,
                                onClick = { router.push(Route.License(component.name)) },
                                modifier = Modifier.weight(1f).then(if (row == 0 && column == 0) Modifier.focusRequester(first) else Modifier),
                            )
                        }
                        if (pair.size == 1) Box(Modifier.weight(1f))
                    }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.pt)) {
            Text("数据来源", style = McType.Title3.copy(fontWeight = FontWeight.SemiBold))
            Text(
                "影视资料与图片由你的服务器从 TMDB（themoviedb.org）等来源获取。本产品使用 TMDB API，但未经 TMDB 认可或认证。",
                style = McType.Callout,
                color = McColors.Secondary,
            )
        }
    }
    }
}

/** 一个组件的格子（系统 NavigationLink 的样子）：平时半透明底，焦点时白底黑字微微放大 */
@Composable
private fun ComponentCell(component: OpenSourceComponent, onClick: () -> Unit, modifier: Modifier) {
    Surface(
        onClick = onClick,
        modifier = modifier.layerFocus(),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(20.pt)),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.04f),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = Color.White.copy(alpha = 0.08f),
            contentColor = McColors.Text,
            focusedContainerColor = Color.White,
            focusedContentColor = Color.Black,
        ),
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 36.pt, vertical = 24.pt), verticalArrangement = Arrangement.spacedBy(6.pt)) {
            Text(component.name, style = McType.Headline, maxLines = 1)
            Text(component.license, style = McType.Caption, modifier = Modifier.padding(bottom = 2.pt), color = androidx.tv.material3.LocalContentColor.current.copy(alpha = 0.6f))
        }
    }
}

/**
 * 一个组件的源码地址与许可全文（TVLicenseTextView）。电视上长文要靠焦点滚动：全文按 20 行切成可聚焦的块，
 * 上下按一下翻一块（整篇一个块的话焦点只在块与块之间跳，中间那段永远滚不到）。
 */
@Composable
fun LicenseScreen(componentName: String) {
    val context = LocalContext.current
    val component = remember(componentName) { OpenSourceComponent.named(componentName) }
    val texts = remember(componentName) {
        component?.licenseFiles.orEmpty().map { file ->
            runCatching { context.assets.open("licenses/$file.txt").bufferedReader().use { it.readText() } }
                .getOrElse { "（许可全文缺失：$file.txt）" }
        }
    }
    val first = remember { FocusRequester() }
    InitialFocus(first)
    Column(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(McColors.SystemTop, McColors.SystemBottom)))
            .verticalScroll(rememberScrollState())
            .padding(start = McMetrics.Edge, end = McMetrics.Edge, top = McMetrics.PushedTop + 40.pt, bottom = 40.pt),
        verticalArrangement = Arrangement.spacedBy(30.pt),
    ) {
        Text(componentName, style = McType.Title2.copy(fontWeight = FontWeight.Bold))
        Text("源码：${component?.source.orEmpty()}", style = McType.Callout, color = McColors.Secondary)
        texts.forEachIndexed { fileIndex, text ->
            // 同一份文件的各块紧挨着排，读起来还是连续的一篇
            Column {
                pages(text).forEachIndexed { page, chunk ->
                    Text(
                        chunk,
                        style = McType.Caption.copy(fontFamily = FontFamily.Monospace),
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (fileIndex == 0 && page == 0) Modifier.focusRequester(first) else Modifier)
                            .focusable(),
                    )
                }
            }
        }
    }
}

/** 每块 20 行：等宽小字一屏放得下，翻页时上一块的尾巴还露在屏幕上，读着不断档 */
private fun pages(text: String, linesPerPage: Int = 20): List<String> =
    text.split("\n").chunked(linesPerPage).map { it.joinToString("\n") }
