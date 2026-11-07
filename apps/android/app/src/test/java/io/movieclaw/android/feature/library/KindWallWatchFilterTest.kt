package io.movieclaw.android.feature.library

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.session.*
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * PR #1205 维护者 P2：类型墙的观看筛选要有单选语义（TalkBack 读得出当前选中项），
 * 「未看完」把墙筛空时要说清是筛选造成的，并能一键清除回到全部。
 * 真实 KindWallViewModel + HTTP（MockWebServer）+ Compose 交互，按用户操作顺序走一遍。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = io.movieclaw.android.MovieClawApp::class, qualifiers = "w400dp-h800dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
class KindWallWatchFilterTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val server = MockWebServer()
    private val itemRequests = CopyOnWriteArrayList<String?>()

    @After fun stop() = server.shutdown()

    private val isRadio = SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.RadioButton)

    @Test fun unfinishedEmptyWallExplainsFilterAndClearsBackToAll() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.requestUrl!!
                val watch = url.queryParameter("w")
                val path = url.encodedPath
                return when {
                    path.endsWith("/libraries/kinds/movie") -> MockResponse().setBody(
                        """{"success":true,"data":{"kind":"movie","library_ids":[1],"item_count":${if (watch == "unfinished") 0 else 2}}}""",
                    )
                    path.endsWith("/libraries/kinds/movie/items") -> {
                        itemRequests += watch
                        MockResponse().setBody(
                            if (watch == "unfinished") """{"success":true,"data":[]}"""
                            else """{"success":true,"data":[{"media_item_id":1,"library_id":1,"title":"长夜将尽"},{"media_item_id":2,"library_id":1,"title":"山海之间"}]}""",
                        )
                    }
                    else -> MockResponse().setResponseCode(404).setBody("{}")
                }
            }
        }
        server.start()
        val context = RuntimeEnvironment.getApplication()
        val json = Json { ignoreUnknownKeys = true; namingStrategy = JsonNamingStrategy.SnakeCase }
        val client = OkHttpClient()
        val vault = TokenVault(context)
        val cookies = ShareCookieJar()
        val api = ApiFactory(json, client, client, vault, cookies)
        val repository = SessionRepository(context, json, vault, api, client,
            SessionCacheCleaner(context, ImageLoaders(context, vault, client, cookies), LibraryHomeSnapshotStore(context, json)),
            dagger.Lazy { throw UnsupportedOperationException() })
        val origin = server.url("/").toString().trimEnd('/')
        vault.activate(origin, "alice", "token")
        @Suppress("UNCHECKED_CAST")
        val ui = SessionRepository::class.java.getDeclaredField("_ui").apply { isAccessible = true }
            .get(repository) as MutableStateFlow<SessionUi>
        ui.value = SessionUi(phase = SessionPhase.READY, origin = origin, session = SessionView("alice"))
        val vm = KindWallViewModel(androidx.lifecycle.SavedStateHandle(mapOf("kind" to "movie")), api, repository)

        compose.setContent { MovieClawTheme { KindWallScreen(onBack = {}, onOpenItem = { _, _ -> }, vm = vm) } }
        compose.waitUntil(5_000) { compose.onAllNodes(hasText("长夜将尽")).fetchSemanticsNodes().isNotEmpty() }

        // 三个观看选项都是单选按钮，选中状态在语义里（不只靠颜色）
        listOf("全部", "未看", "未看完").forEach { compose.onNodeWithText(it).assert(isRadio) }
        compose.onNodeWithText("全部").assertIsSelected()
        compose.onNodeWithText("未看完").assertIsNotSelected()

        compose.onNodeWithText("未看完").performClick()
        compose.waitUntil(5_000) { compose.onAllNodes(hasText("没有未看完的作品")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("未看完").assertIsSelected()
        compose.onNodeWithText("全部").assertIsNotSelected()
        compose.onNodeWithText("当前观看筛选下没有作品，清除筛选即可查看全部。").assertExists()
        assertEquals(0, compose.onAllNodes(hasText("这个类型下还没有作品")).fetchSemanticsNodes().size)
        snapshot("kind-wall-unfinished-empty.png")

        compose.onNodeWithText("清除观看筛选").performClick()
        compose.waitUntil(5_000) { compose.onAllNodes(hasText("山海之间")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("全部").assertIsSelected()
        assertEquals(listOf(null, "unfinished", null), itemRequests.toList())
    }

    private fun snapshot(name: String) {
        compose.waitForIdle()
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name").outputStream().use {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
