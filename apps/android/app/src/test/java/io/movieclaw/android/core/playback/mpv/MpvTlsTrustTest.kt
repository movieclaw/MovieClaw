package io.movieclaw.android.core.playback.mpv

import android.content.ContextWrapper
import java.io.File
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.Executors
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = android.app.Application::class)
class MpvTlsTrustTest {
    private fun roots(): List<X509Certificate> {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        return factory.trustManagers.filterIsInstance<X509TrustManager>().single().acceptedIssuers.toList()
    }
    private fun fingerprint(cert: X509Certificate) = Base64.getEncoder().encodeToString(cert.encoded)
    private fun read(file: File) = file.inputStream().use {
        CertificateFactory.getInstance("X.509").generateCertificates(it).map { cert -> fingerprint(cert as X509Certificate) }
    }

    @Test fun platformBundleRoundTripsExactlyTheDefaultTrustedIssuers() {
        val context = RuntimeEnvironment.getApplication()
        val file = MpvTlsTrust.systemBundle(context)
        assertNotNull(file)
        assertEquals(roots().map(::fingerprint).toSet(), read(file!!).toSet())
        assertTrue(file.canonicalPath.startsWith(context.filesDir.canonicalPath + File.separator))
    }

    @Test fun duplicateCertificatesAndTwoPlayersStillProduceACompleteBundle() {
        val context = RuntimeEnvironment.getApplication()
        val certificates = roots().take(2)
        assertEquals(2, certificates.size)
        val directory = File(context.cacheDir, "tls-concurrent-test")
        val executor = Executors.newFixedThreadPool(2)
        try {
            val files = executor.invokeAll(List(2) {
                java.util.concurrent.Callable { MpvTlsTrust.writeBundle(directory, certificates + certificates) }
            }).map { it.get() }
            files.forEach { assertEquals(certificates.map(::fingerprint), read(it)) }
            val before = files.first().readBytes()
            assertThrows(IllegalStateException::class.java) { MpvTlsTrust.writeBundle(directory, emptyList()) }
            assertArrayEquals(before, files.first().readBytes())
        } finally { executor.shutdownNow(); directory.deleteRecursively() }
    }

    @Test fun filesystemFailureReturnsNullWithoutCrashingThePlayer() {
        val context = RuntimeEnvironment.getApplication()
        val blocked = File(context.cacheDir, "tls-blocked-files-dir").apply { writeText("file") }
        try {
            val wrapper = object : ContextWrapper(context) { override fun getFilesDir() = blocked }
            assertNull(MpvTlsTrust.systemBundle(wrapper))
        } finally { blocked.delete() }
    }
}
