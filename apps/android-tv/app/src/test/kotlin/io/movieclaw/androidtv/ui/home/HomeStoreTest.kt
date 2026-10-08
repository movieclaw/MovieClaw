package io.movieclaw.androidtv.ui.home

import io.movieclaw.androidtv.core.network.ApiTransport
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class HomeStoreTest {
    /** 断网：每个请求都失败 */
    private val offline = object : ApiTransport {
        override suspend fun <T> send(
            method: String, path: String, query: List<Pair<String, String>>, body: JsonElement?,
            response: KSerializer<T>, enveloped: Boolean,
        ): T = throw IOException("unexpected end of stream")
    }

    @Test
    fun offlineReloadMarksFailureInsteadOfThrowing() = runBlocking {
        // 首页 60 秒一次的刷新撞上断网：原来异常从 coroutineScope 冒出去，LaunchedEffect 接不住，App 闪退（故障注入实测）
        val store = HomeStore(McApi(offline))
        store.reload()
        assertTrue(store.failed)
    }
}
