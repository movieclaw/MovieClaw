package io.movieclaw.android.core.network

import kotlinx.serialization.Serializable

/** /api/v1 统一响应信封:{success, code, message, data} */
@Serializable
data class McEnvelope<T>(
    val success: Boolean = false,
    val code: String = "",
    val message: String = "",
    val data: T? = null,
)

/** 业务码非 OK / 信封缺 data */
class ApiException(
    val code: String,
    override val message: String,
    val httpCode: Int = 0,
) : Exception(message)

/** 首次部署,服务器未初始化管理员 */
class SetupRequiredException(val origin: String) :
    Exception("服务器尚未初始化,请先创建管理员账号")

fun <T> McEnvelope<T>.dataOrThrow(): T =
    if (success) {
        data ?: throw ApiException(code = code, message = message.ifEmpty { "响应缺少数据" })
    } else {
        throw ApiException(code = code.ifEmpty { "FAILED" }, message = message.ifEmpty { "请求失败" })
    }
