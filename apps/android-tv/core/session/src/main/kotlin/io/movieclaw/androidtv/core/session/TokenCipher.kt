package io.movieclaw.androidtv.core.session

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 令牌用 AndroidKeyStore 里的 AES-GCM 密钥加密后再落盘。
 *
 * 有些电视盒子的 KeyStore 实现是坏的（生成或解密直接抛异常）。这时退回明文存在
 * App 私有目录里——令牌本就只在本 App 沙箱内可读，宁可少一层防护也不能让人登录不了。
 */
internal class TokenCipher {
    fun seal(token: String): String = try {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(token.toByteArray())
        ENCRYPTED + Base64.encodeToString(sealed, Base64.NO_WRAP)
    } catch (e: Exception) {
        Log.w(TAG, "KeyStore 不可用，令牌以明文保存在私有目录", e)
        PLAIN + token
    }

    fun open(stored: String): String? = when {
        stored.startsWith(PLAIN) -> stored.removePrefix(PLAIN)
        stored.startsWith(ENCRYPTED) -> try {
            val bytes = Base64.decode(stored.removePrefix(ENCRYPTED), Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_BYTES))
            }
            String(cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES))
        } catch (e: Exception) {
            Log.w(TAG, "令牌解不开（KeyStore 被清空？），需要重新登录", e)
            null
        }
        else -> null
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).apply {
            init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    private companion object {
        const val TAG = "TokenCipher"
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "movieclaw.device-token"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val ENCRYPTED = "ks1:"
        const val PLAIN = "pt1:"
    }
}
