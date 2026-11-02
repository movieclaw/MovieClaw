package io.movieclaw.core.network

import java.io.IOException
import java.net.ConnectException
import java.security.cert.CertPathValidatorException
import java.security.cert.CertificateException
import java.security.cert.CertificateExpiredException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import org.junit.Assert.*
import org.junit.Test

class TlsErrorsTest {
    private fun handshake(cause: Throwable) = SSLHandshakeException("Handshake failed").apply { initCause(cause) }

    @Test fun expiredCertificateTakesPrecedenceOverOuterTrustFailure() {
        val error = IOException("request failed", handshake(CertificateException("validation failed", CertificateExpiredException())))
        assertTrue(tlsErrorMessage(null, error)!!.contains("证书已过期"))
        val pathError = CertPathValidatorException("expired", null, null, -1, CertPathValidatorException.BasicReason.EXPIRED)
        assertTrue(tlsErrorMessage(null, handshake(pathError))!!.contains("证书已过期"))
    }

    @Test fun unknownCaAndIncompleteChainHaveActionableAdviceWithoutGuessingTheCause() {
        for (cause in listOf(
            CertPathValidatorException("Trust anchor for certification path not found."),
            CertificateException("Unable to build certificate chain"),
            SSLPeerUnverifiedException("Failed to find a trusted cert that signed the chain"),
        )) {
            val message = tlsErrorMessage("nas.example.xyz", handshake(cause))!!
            assertTrue(message.contains("nas.example.xyz"))
            assertTrue(message.contains("证书不受信任或证书链不完整"))
            assertTrue(message.contains("系统中安装可信 CA"))
            assertFalse(message.contains("http"))
        }
    }

    @Test fun tvHostnameMismatchNeverSuggestsHttp() {
        val cause = SSLPeerUnverifiedException("Hostname nas.example.xyz not verified:\n    subjectAltNames: [other.example.xyz]")
        val error = UnreachableException("nas.example.xyz", cause)
        assertSame(cause, error.cause)
        assertTrue(error.message!!.contains("证书与服务器域名不匹配"))
        assertFalse(error.message!!.contains("http"))
        assertEquals(error.message, tlsErrorMessage("nas.example.xyz", IOException(error)))
    }

    @Test fun protocolErrorsAreNotMisreportedAsUntrustedCertificates() {
        for (error in listOf(SSLHandshakeException("protocol_version"), SSLException("connection closed"))) {
            val message = UnreachableException.networkMessage(null, error)
            assertTrue(message.contains("HTTPS 安全连接"))
            assertFalse(message.contains("不受信任"))
            assertFalse(message.contains("http"))
        }
    }

    @Test fun ordinaryNetworkErrorsRetainTheirExistingMessages() {
        assertNull(tlsErrorMessage(null, ConnectException()))
        assertTrue(UnreachableException.networkMessage("nas", ConnectException()).contains("拒绝连接"))
    }

    @Test fun tlsFailureFromAnotherAddressIsNotHiddenByAnEarlierConnectionFailure() {
        val error = ConnectException("IPv6 connection refused").apply {
            addSuppressed(handshake(CertificateException("Trust anchor not found")))
        }
        assertTrue(tlsErrorMessage(null, IOException(error))!!.contains("证书不受信任或证书链不完整"))
        error.addSuppressed(handshake(CertificateExpiredException()))
        assertTrue(UnreachableException.networkMessage(null, error).contains("证书已过期"))
    }
}
