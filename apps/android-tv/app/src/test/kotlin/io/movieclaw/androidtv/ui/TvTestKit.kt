package io.movieclaw.androidtv.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.compose.ui.text.AnnotatedString
import io.movieclaw.androidtv.AccountSession
import io.movieclaw.androidtv.AppGraph
import io.movieclaw.androidtv.LocalGraph
import io.movieclaw.androidtv.LocalSession
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.model.generated.SessionView
import io.movieclaw.core.network.ApiTransport
import io.movieclaw.core.network.ServerAddress
import io.movieclaw.core.network.generated.McApi
import io.movieclaw.androidtv.ui.components.LocalServer
import io.movieclaw.androidtv.ui.theme.McTheme
import okhttp3.HttpUrl.Companion.toHttpUrl
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import java.io.File
import java.io.IOException

/** 电视 1920×1080（1pt = 1px，同 McMetrics 的画布） */
const val TV_QUALIFIERS = "w960dp-h540dp-land-television-xhdpi"

/**
 * 假服务端：按路径给现成的对象，其余请求一律当断网。
 * 值也可以是 [Responder]：按这次请求的查询参数现算（按 offset 切片的海报墙、按筛选条件变的计数）；
 * [delays] 里的路径晚这么多毫秒才答（模拟真机网络延迟）
 */
class FakeTransport(private val routes: Map<String, Any>, private val delays: Map<String, Long> = emptyMap()) : ApiTransport {
    /** 收到过的请求路径（按先后） */
    val requested = java.util.Collections.synchronizedList(mutableListOf<String>())
    /** 收到过的请求（路径 + 查询参数，按先后）：同一路径带不同参数的请求（相似推荐排除 / 不排除同系列）要分开看 */
    val queries = java.util.Collections.synchronizedList(mutableListOf<Pair<String, List<Pair<String, String>>>>())

    @Suppress("UNCHECKED_CAST")
    override suspend fun <T> send(
        method: String, path: String, query: List<Pair<String, String>>, body: JsonElement?,
        response: KSerializer<T>, enveloped: Boolean,
    ): T {
        requested += path
        queries += path to query
        delays[path]?.let { kotlinx.coroutines.delay(it) }
        val route = routes[path] ?: throw IOException("offline: $method $path")
        return (if (route is Responder) route.respond(query.toMap()) else route) as T
    }
}

/** 按查询参数现算的假响应 */
fun interface Responder {
    fun respond(query: Map<String, String>): Any
}

/** 摆好的电视界面：依赖图（开关设置用）与假服务端（看发了哪些请求） */
class TvEnv(val graph: AppGraph, val transport: FakeTransport)

fun episodes(count: Int, played: Int = 0, owned: (Long) -> Boolean = { true }) = (1..count.toLong()).map {
    EpisodeView(episodeNumber = it, name = "第 $it 集的标题", owned = owned(it), played = it <= played)
}

typealias TvRule = AndroidComposeTestRule<*, ComponentActivity>

/** 摆上电视界面：主题、依赖图、已登录账号（接口走 [routes] 假服务端，[delays] 见 [FakeTransport]） */
fun TvRule.setTvContent(routes: Map<String, Any>, delays: Map<String, Long> = emptyMap(), content: @Composable () -> Unit): TvEnv {
    val graph = AppGraph(activity.application)
    val server = ServerAddress("http://127.0.0.1:9".toHttpUrl())
    val transport = FakeTransport(routes, delays)
    val session = AccountSession(server, "token", SessionView(username = "u", nickname = "我"), McApi(transport))
    setContent {
        McTheme {
            CompositionLocalProvider(LocalGraph provides graph, LocalSession provides session, LocalServer provides server, content = content)
        }
    }
    return TvEnv(graph, transport)
}

/** 遥控器按一下（按下 + 抬起），走 Activity 的整条按键分发，同真机 */
fun TvRule.press(code: Int, settleMs: Long = 400) {
    activity.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
    activity.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    mainClock.advanceTimeBy(settleMs)
    waitForIdle()
}

/** 当前焦点控件上的文字（合并后的语义）；没有焦点控件或焦点落在没有文字的容器上时为 null */
fun TvRule.focusedText(): String? {
    val nodes = onAllNodes(isFocused()).fetchSemanticsNodes()
    val node = nodes.singleOrNull() ?: return null
    val texts = node.config.getOrNull(SemanticsProperties.Text).orEmpty().map(AnnotatedString::text)
    val description = node.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
    return (texts + description).joinToString(" ").ifEmpty { null }
}

/** 把整个窗口画成 PNG，存到 app/build/ui-previews/<name>.png（真实 Compose 绘制，需 @GraphicsMode(NATIVE)） */
fun TvRule.savePreview(name: String): File {
    val view = activity.window.decorView
    val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
    view.draw(Canvas(bitmap))
    val dir = File("build/ui-previews").apply { mkdirs() }
    return File(dir, "$name.png").also { file -> file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
}
