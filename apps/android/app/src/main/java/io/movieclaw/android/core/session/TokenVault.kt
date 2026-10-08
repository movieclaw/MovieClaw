package io.movieclaw.android.core.session

import android.content.Context
import android.util.Base64
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import java.security.KeyStore
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

private val Context.vaultStore by preferencesDataStore(name = "mc_vault")

/**
 * 令牌库:Android Keystore(AES-256-GCM)加密后落 DataStore,键 `origin#username`。
 * 对齐 iOS Keychain 语义:token 不进日志、不进备份(allowBackup=false)。
 * Keystore 不可用时拒绝新写；历史 raw 格式仅为迁移兼容读取，不再产生明文凭证。
 */
@Singleton
class TokenVault @Inject constructor(@ApplicationContext private val context: Context) {

    private val mem = ConcurrentHashMap<String, String>()

    /** 一次原子读取的请求身份；generation 防止退出后重登同一 token 的旧响应复活。 */
    data class Identity(val origin: String, val username: String, val token: String, val generation: Long)
    private val identityLock = Any()
    @Volatile private var identity: Identity? = null
    private var generation = 0L
    val activeOrigin: String? get() = identity?.origin

    fun activate(origin: String, username: String, token: String) = synchronized(identityLock) {
        identity = Identity(origin, username, token, ++generation)
    }

    fun snapshot(): Identity? = identity
    fun activeToken(): String? = identity?.token
    fun isCurrent(expected: Identity): Boolean = identity == expected

    /** 先摘除内存身份，再清持久令牌，避免清理期间请求继续拿到已退出的凭证。 */
    fun clearActive(expected: Identity? = identity): Identity? = synchronized(identityLock) {
        if (identity != expected) null else identity.also { identity = null }
    }

    suspend fun warmUp() {
        val entries = context.vaultStore.data.first().asMap()
        entries.forEach { (key, value) ->
            if (value is String) decrypt(value)?.let { mem[key.name] = it }
        }
    }

    suspend fun token(origin: String, username: String): String? {
        val key = vaultKey(origin, username)
        mem[key]?.let { return it }
        val blob = context.vaultStore.data.first()[stringPreferencesKey(key)] ?: return null
        return decrypt(blob).also { if (it != null) mem[key] = it }
    }

    suspend fun saveToken(origin: String, username: String, token: String) {
        val key = vaultKey(origin, username)
        val encrypted = encrypt(token)
        context.vaultStore.edit { it[stringPreferencesKey(key)] = encrypted }
        mem[key] = token
    }

    suspend fun deleteToken(origin: String, username: String) {
        val key = vaultKey(origin, username)
        mem.remove(key)
        context.vaultStore.edit { it.remove(stringPreferencesKey(key)) }
    }

    suspend fun deactivateActive(expected: Identity? = snapshot()) {
        val removed = clearActive(expected) ?: return
        deleteToken(removed.origin, removed.username)
    }

    private fun vaultKey(origin: String, username: String) = "$origin#$username"

    private fun secretKey(): SecretKey? = runCatching {
        val keyStore = KeyStore.getInstance(KEY_STORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey ?: run {
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEY_STORE)
            generator.init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
            generator.generateKey()
        }
    }.getOrNull()

    private fun encrypt(plain: String): String {
        val key = secretKey()
            ?: throw IllegalStateException("设备安全存储不可用，无法安全保存登录令牌，请检查设备后重试")
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val cipherText = cipher.doFinal(plain.toByteArray())
        return Base64.encodeToString(cipher.iv + cipherText, Base64.NO_WRAP)
    }

    private fun decrypt(blob: String): String? = runCatching {
        if (blob.startsWith(PLAIN_PREFIX)) {
            return String(Base64.decode(blob.removePrefix(PLAIN_PREFIX), Base64.NO_WRAP))
        }
        val all = Base64.decode(blob, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, all.copyOfRange(0, 12)))
        String(cipher.doFinal(all.copyOfRange(12, all.size)))
    }.getOrNull()

    private companion object {
        const val KEY_STORE = "AndroidKeyStore"
        const val KEY_ALIAS = "mc_token_key"
        const val TRANSFORM = "AES/GCM/NoPadding"
        const val PLAIN_PREFIX = "raw:"
    }
}
