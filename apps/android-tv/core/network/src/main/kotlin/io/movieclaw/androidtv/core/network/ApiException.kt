package io.movieclaw.androidtv.core.network

import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException

/** 服务端明确拒绝了请求（非 2xx）。[code] 是信封里的业务码，如 `AUTHORIZATION_DENIED`。 */
class ApiException(
    val status: Int,
    val code: String?,
    message: String,
) : IOException(message) {
    val isUnauthorized: Boolean get() = status == 401
}

/**
 * 根本没连上服务器（断网、地址错、超时）。文案对齐 Apple 端 `APIClient.networkMessage`：
 * 「发生了什么：该怎么办」，带上是哪台服务器，自托管用户一眼能看出是不是地址填错了。
 */
class UnreachableException(val host: String?, cause: Throwable) : IOException(networkMessage(host, cause), cause) {
    val isTimeout: Boolean get() = cause is SocketTimeoutException || cause is InterruptedIOException

    companion object {
        fun networkMessage(host: String?, error: Throwable): String {
            val who = host?.let { "「$it」" } ?: "服务器"
            return when (error) {
                is UnknownHostException -> "找不到$who：域名无法解析，请检查地址拼写；内网域名需要电视与服务器在同一网络"
                is NoRouteToHostException -> "电视没有联网：请检查 Wi-Fi 或有线网络"
                is ConnectException -> "${who}拒绝连接：端口不对或服务器没在运行。请确认地址与浏览器里打开 MovieClaw 时的完全一致（包括端口）"
                is SocketTimeoutException, is InterruptedIOException ->
                    "连接${who}超时，服务器没有响应：请确认地址和端口正确、服务器在运行；局域网地址需要电视连着同一个网络"
                is SSLHandshakeException -> "${who}的 HTTPS 证书不受信任（常见于自签名证书）：请换用正规证书（如 Let's Encrypt），或改用 http 地址"
                is SSLException -> "无法与${who}建立 HTTPS 安全连接：服务器如果没有配置 https，请把地址开头改成 http://"
                is SocketException -> "与${who}的连接中途断开：请重试；反复出现时检查网络是否稳定"
                else -> "网络请求失败：请检查网络连接和服务器地址后重试"
            }
        }
    }
}
