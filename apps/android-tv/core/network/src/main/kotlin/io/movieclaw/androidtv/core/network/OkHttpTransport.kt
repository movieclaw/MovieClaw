package io.movieclaw.androidtv.core.network

import io.movieclaw.androidtv.core.model.McJson
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * 一台服务器、一个身份的传输通道。令牌由 [token] 现取：同一个通道在登录前后都能用。
 *
 * @param apiBase 形如 `http://192.168.1.10:3000/api/v1`
 */
class OkHttpTransport(
    private val apiBase: HttpUrl,
    private val client: OkHttpClient,
    private val token: () -> String? = { null },
    /** 带着令牌收到 401：令牌已失效（被注销、改了密码），上层据此打回登录页 */
    private val onUnauthorized: (rejectedToken: String) -> Unit = {},
) : ApiTransport {

    override suspend fun <T> send(
        method: String,
        path: String,
        query: List<Pair<String, String>>,
        body: JsonElement?,
        response: KSerializer<T>,
        enveloped: Boolean,
    ): T {
        val url = apiBase.newBuilder().apply {
            addPathSegments(path.trimStart('/'))
            query.forEach { (name, value) -> addQueryParameter(name, value) }
        }.build()
        val payload = body?.let { McJson.encodeToString(JsonElement.serializer(), it).toRequestBody(JSON) }
        val bearer = token()
        val request = Request.Builder()
            .url(url)
            .method(method, payload ?: if (method in BODY_METHODS) EMPTY_BODY else null)
            .apply { bearer?.let { header("Authorization", "Bearer $it") } }
            .build()
        val text: String
        val status: Int
        try {
            client.newCall(request).await().use { resp ->
                status = resp.code
                text = resp.body.string()
            }
        } catch (e: IOException) {
            throw UnreachableException(apiBase.host + (if (apiBase.port != 80 && apiBase.port != 443) ":${apiBase.port}" else ""), e)
        }
        val json = text.takeIf { it.isNotBlank() }?.let {
            runCatching { McJson.parseToJsonElement(it) }.getOrNull()
        }
        if (status == 401 && bearer != null) onUnauthorized(bearer)
        if (status !in 200..299) throw errorOf(status, json)
        val data = if (enveloped) (json as? JsonObject)?.get("data") ?: JsonNull else json ?: JsonNull
        return try {
            McJson.decodeFromJsonElement(response, data)
        } catch (e: SerializationException) {
            throw ApiException(status, "DECODE_ERROR", "服务器返回的数据看不懂：${e.message}")
        } catch (e: IllegalArgumentException) {
            throw ApiException(status, "DECODE_ERROR", "服务器返回的数据看不懂：${e.message}")
        }
    }

    private fun errorOf(status: Int, json: JsonElement?): ApiException {
        val obj = json as? JsonObject
        val code = obj?.get("code")?.jsonPrimitive?.contentOrNull
        val message = obj?.get("message")?.jsonPrimitive?.contentOrNull
            ?: when (status) {
                401 -> "登录已失效，请重新登录"
                403 -> "没有权限"
                404 -> "找不到"
                else -> "服务器出错了（$status）"
            }
        return ApiException(status, code, message)
    }

    private companion object {
        val JSON = "application/json; charset=utf-8".toMediaType()
        val EMPTY_BODY = ByteArray(0).toRequestBody(JSON)
        val BODY_METHODS = setOf("POST", "PUT", "PATCH")
    }
}

/** OkHttp 回调转挂起；协程取消时取消请求。 */
internal suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = cont.resume(response)
        override fun onFailure(call: Call, e: IOException) = cont.resumeWithException(e)
    })
    cont.invokeOnCancellation { runCatching { cancel() } }
}
