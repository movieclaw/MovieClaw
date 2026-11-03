package io.movieclaw.android.core.network

import java.security.Provider
import java.security.Security
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * /health 主机签名校验。向量是服务端（Python cryptography）真实签出来的。
 *
 * Android 的系统密码库没有 `EdDSA` 这个算法名（Android 16 实测 NoSuchAlgorithmException），
 * 而 JDK 自带——所以这里先摘掉 JDK 里提供 EdDSA 的 Provider，按 Android 的条件跑。
 */
class HealthProofTest {
    private val hostKey = "jwj-1mXU5vSSs9R4tjcvJrd2EHRCaUAhb0VUMwicTTo"
    private val instanceId = "da940e01e32ae42c8bde610c721bc2a4"
    private val nonce = "WycSLlu_RPhSe3jAqBXoOg"
    private val proof = "JFzN6b6ttS-tCiqpVY-yxuVPeNxwPYD_00bWuMrDYrdnlsu7gA0PWSLjNUCe1SCzs_DlaQP5cc-nBkdXrOpFDg"

    private val removed = mutableListOf<Pair<Provider, Int>>()

    @Before fun dropJdkEdDsa() {
        Security.getProviders().forEachIndexed { index, provider ->
            if (provider.getService("Signature", "EdDSA") != null) removed += provider to index + 1
        }
        removed.forEach { (provider, _) -> Security.removeProvider(provider.name) }
    }

    @After fun restore() {
        removed.forEach { (provider, position) -> Security.insertProviderAt(provider, position) }
    }

    @Test fun `服务端签的 proof 在没有系统 EdDSA 的环境里也能验过`() {
        assertTrue(runCatching { java.security.Signature.getInstance("EdDSA") }.isFailure)
        assertTrue(verifyHealthProof(hostKey, nonce, instanceId, proof))
    }

    @Test fun `换了 nonce 或实例号就验不过`() {
        assertFalse(verifyHealthProof(hostKey, "AAAAAAAAAAAAAAAAAAAAAA", instanceId, proof))
        assertFalse(verifyHealthProof(hostKey, nonce, "0".repeat(32), proof))
    }
}
