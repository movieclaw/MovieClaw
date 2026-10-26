package io.movieclaw.android.core.playback

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.BuildConfig
import io.movieclaw.core.playback.DecoderDenylist
import io.movieclaw.core.playback.PrefsStore
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 统一引擎的本机小件偏好（解码器黑名单、画质记忆、播放记录待发队列……）：一个独立的 SharedPreferences 文件。
 * 正片与刷片共用同一份，正片里实测坏掉的解码器刷片也不再选。
 */
@Singleton
class CorePlaybackPrefs @Inject constructor(@ApplicationContext context: Context) : PrefsStore {
    private val store = context.getSharedPreferences("movieclaw-playback", Context.MODE_PRIVATE)

    override fun string(key: String): String? = store.getString(key, null)

    override fun putString(key: String, value: String?) =
        store.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()

    fun decoderDenylist(): DecoderDenylist = DecoderDenylist(this, BuildConfig.VERSION_NAME)
}
