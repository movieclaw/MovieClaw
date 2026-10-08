package io.movieclaw.androidtv.core.network

import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement

/**
 * 生成的 [io.movieclaw.androidtv.core.network.generated.McApi] 只依赖这一个口子。
 *
 * @param path 相对 `/api/v1` 的路径
 * @param enveloped 响应是不是统一信封 `{success, code, message, data}`（只有 `/health` 不是）
 */
interface ApiTransport {
    suspend fun <T> send(
        method: String,
        path: String,
        query: List<Pair<String, String>>,
        body: JsonElement?,
        response: KSerializer<T>,
        enveloped: Boolean,
    ): T
}
