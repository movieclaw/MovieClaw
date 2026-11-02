package io.movieclaw.core.network

import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateException
import java.security.cert.CertificateExpiredException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLPeerUnverifiedException

/** 手机与 TV 共用的 TLS 提示；保留 cause 链，优先说明具体的证书问题。 */
fun tlsErrorMessage(host: String?, error: Throwable): String? {
    // OkHttp 多地址重试会把后续失败放进 suppressed，首个失败可能只是拒绝连接。
    val causes = mutableListOf(error)
    var index = 0
    while (index < causes.size) {
        val current = causes[index++]
        for (nested in listOfNotNull(current.cause) + current.suppressed) {
            if (causes.none { it === nested }) causes += nested
        }
    }
    val who = host?.let { "「$it」" } ?: "服务器"
    return when {
        causes.any { it is CertificateExpiredException ||
            (it is CertPathValidatorException && it.reason == CertPathValidatorException.BasicReason.EXPIRED) } ->
            "${who}的 HTTPS 证书已过期：请在服务器上续期证书，并检查设备时间是否正确"
        // OkHttp 的域名校验失败是 SSLPeerUnverifiedException，并非 SSLHandshakeException。
        causes.any { it is SSLPeerUnverifiedException && it.message?.contains("Hostname", ignoreCase = true) == true } ->
            "${who}的 HTTPS 证书与服务器域名不匹配：请使用证书对应的域名，或修正服务器证书"
        // Android 的 Trust anchor 错误也可能由缺失中间证书引起，不能仅凭它断定是自签名。
        causes.any { it is CertificateException || it is CertPathValidatorException || it is SSLPeerUnverifiedException } ->
            "${who}的 HTTPS 证书不受信任或证书链不完整：请在系统中安装可信 CA 证书，或在服务器上配置受信任的完整证书链"
        causes.any { it is SSLException } ->
            "无法与${who}建立 HTTPS 安全连接：请检查服务器的 HTTPS 配置与证书"
        else -> null
    }
}
