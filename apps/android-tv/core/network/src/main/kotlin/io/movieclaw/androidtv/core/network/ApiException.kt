package io.movieclaw.androidtv.core.network

import java.io.IOException

/** 服务端明确拒绝了请求（非 2xx）。[code] 是信封里的业务码，如 `AUTHORIZATION_DENIED`。 */
class ApiException(
    val status: Int,
    val code: String?,
    message: String,
) : IOException(message) {
    val isUnauthorized: Boolean get() = status == 401
}

/** 根本没连上服务器（断网、地址错、超时）。界面据此说「连不上」而不是「出错了」。 */
class UnreachableException(cause: Throwable) : IOException("连不上服务器", cause)
