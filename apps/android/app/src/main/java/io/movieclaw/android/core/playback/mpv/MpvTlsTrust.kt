package io.movieclaw.android.core.playback.mpv

import android.content.Context
import android.util.Log
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Base64
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** 使用 App 默认的平台信任；不直接枚举 AndroidCAStore，以免额外信任用户安装的 CA。 */
internal object MpvTlsTrust {
    @Synchronized
    fun systemBundle(context: Context): File? = try {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        val trust = factory.trustManagers.filterIsInstance<X509TrustManager>().single()
        writeBundle(File(context.filesDir, "mpv-tls"), trust.acceptedIssuers.toList())
    } catch (error: Exception) {
        Log.w("McMpv", "无法导出平台 TLS CA，保持证书校验并停止加载", error)
        null
    }

    /** 进程内两个 MPV 实例共用锁；同目录原子替换确保原生读取者不会读到半份 PEM。 */
    @Synchronized
    internal fun writeBundle(directory: File, certificates: List<X509Certificate>): File {
        val encoded = certificates.map { Base64.getEncoder().encodeToString(it.encoded) }.distinct()
        check(encoded.isNotEmpty()) { "平台 TLS CA 为空" }
        check(directory.isDirectory || directory.mkdirs()) { "无法创建 TLS CA 私有目录" }
        val pem = encoded.joinToString("") {
            "-----BEGIN CERTIFICATE-----\n" + it.chunked(64).joinToString("\n") +
                "\n-----END CERTIFICATE-----\n"
        }
        val file = File(directory, "platform-ca.pem")
        val temporary = File(directory, "platform-ca.pem.tmp")
        try {
            temporary.writeBytes(pem.toByteArray(Charsets.US_ASCII))
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally {
            temporary.delete()
        }
        return file
    }
}
