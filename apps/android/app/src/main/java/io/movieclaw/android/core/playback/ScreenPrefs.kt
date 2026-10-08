package io.movieclaw.android.core.playback

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first

private val Context.screenStore by preferencesDataStore(name = "mc_screen")

/**
 * 播放页的屏幕亮度记忆。
 *
 * 手势调出来的亮度是**窗口级**的（`Window.attributes.screenBrightness`），窗口一换就没了——
 * 表现就是「上一部调暗了，下一部又亮回来」。这里记一份（本机、全 app 共用），进播放页时
 * 套上，退出播放页仍然把系统亮度还回去（iOS `ScreenBrightness` 也是退出即还，
 * 这一层记忆是本端的加法：用户明确要求「下一部别又变回原来的亮度」）。
 *
 * 音量不用记：`AudioManager.setStreamVolume` 改的就是系统音量，天然跨播放保留。
 */
@Singleton
class ScreenPrefs @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    suspend fun playerBrightness(): Float? =
        context.screenStore.data.first()[KEY_BRIGHTNESS]

    suspend fun rememberBrightness(value: Float) {
        val v = value.coerceIn(MIN, 1f)
        context.screenStore.edit { it[KEY_BRIGHTNESS] = v }
    }

    private companion object {
        val KEY_BRIGHTNESS = floatPreferencesKey("player_brightness")

        /** 与手势下限一致：太暗会「黑屏不知道发生了什么」 */
        const val MIN = 0.05f
    }
}
