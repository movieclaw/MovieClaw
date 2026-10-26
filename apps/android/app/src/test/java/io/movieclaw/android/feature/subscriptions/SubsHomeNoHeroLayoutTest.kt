package io.movieclaw.android.feature.subscriptions

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import io.movieclaw.android.core.designsystem.ImageLoaders
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.ShareCookieJar
import io.movieclaw.android.core.playback.PlaybackDataEvents
import io.movieclaw.android.core.session.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.*
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * 用户截图的场景：只有一条「没勾季、已收齐」的剧集订阅 → 没有英雄位。
 * 以前这时剧集那一排从屏幕顶端画起，压在悬浮的「我的订阅」大标题和状态栏下面。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = io.movieclaw.android.MovieClawApp::class, qualifiers = "w400dp-h800dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
class SubsHomeNoHeroLayoutTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val server = MockWebServer()

    @After fun stop() = server.shutdown()

    @Test fun shelvesStartBelowLargeTitleWithoutHero() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl!!.encodedPath
                if (path.endsWith("/subscriptions")) return MockResponse().setBody(
                    """{"success":true,"data":[{"id":1,"status":"completed","selected_seasons":[],"follow_future":true,
                       "media":{"media_item_id":9,"kind":"tv","title":"暗潮之下","year":2024,"status":"Ended"},
                       "progress":{"total":0,"imported":0}}]}"""
                )
                if (path.endsWith("arrivals")) return MockResponse().setBody("""{"success":true,"data":[]}""")
                return MockResponse().setResponseCode(403).setBody("{}")
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
        val vm = SubsHomeViewModel(api, repository, PlaybackDataEvents())

        compose.setContent { MovieClawTheme { SubsHomeScreen(onOpenSubscription = {}, onPlay = {}, vm = vm) } }
        compose.waitUntil(5_000) { compose.onAllNodes(androidx.compose.ui.test.hasText("剧集订阅")).fetchSemanticsNodes().isNotEmpty() }
        compose.waitForIdle()

        val title = compose.onNodeWithText("我的订阅").getUnclippedBoundsInRoot()
        val shelf = compose.onNodeWithText("剧集订阅").getUnclippedBoundsInRoot()
        assertTrue("shelf header (top=${shelf.top}) overlaps the large title (bottom=${title.bottom})", shelf.top >= title.bottom)
        // 海报下不再编造「第 1 季 · 0 / 0」
        compose.onNodeWithText("2024").assertExists()

        File("build/ui-previews").mkdirs()
        File("build/ui-previews/subs-home-no-hero.png").outputStream().use {
            val view = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(bitmap))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
