package io.movieclaw.android.core.playback

import io.movieclaw.android.core.AppScopes

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private val Context.subtitleStyleStore by preferencesDataStore(name = "mc_subtitle_style")

/**
 * 字幕外观（iOS `SubtitleStyle` 的对应物，存本机）：
 *   · 字号 = 相对画面高度的百分比（iOS 5.2%，本机按实测调成 2.8%——同一份字幕
 *     在手机上 5.2% 明显偏大，用户连着报过两次"字号太大"）
 *   · 时间轴微调（秒），**正数 = 字幕延后**（跟 iOS 一致）
 *   · 位置 = 字幕底边距画面底部的百分比（iOS 8%）
 *   · 背景 = 要不要整行底框（默认关：靠一层柔和投影压住亮画面，不做描边）
 *
 * 前三个参数都由 `SubtitleAss.rewriteAssStyles` 落到 ASS 的 `Style:` 行上，
 * 所以改样式要**重新转换一次**字幕（不是只改绘制参数）。
 */
@Serializable
data class SubtitleStyle(
    // 5.2% = 画面高度的百分比，与 iOS SubtitleStyle.fontScale 同值（1080p ≈ 56px，
    // 是常规电影字幕的尺寸；2.8% ≈ 30px 实测偏小，用户反馈过）
    val fontPercent: Float = 5.2f,
    val offsetSeconds: Float = 0f,
    val bottomPercent: Float = 8f,
    val background: Boolean = false,
) {
    companion object {
        /** 人耳能分辨的最小对不齐量级（iOS 同值） */
        const val OFFSET_STEP = 0.1f

        /** 超过 ±30 秒基本不是"没对齐"而是拿错了字幕文件（iOS 同值） */
        const val OFFSET_MAX = 30f
        const val FONT_STEP = 0.2f
        const val FONT_MIN = 1.0f
        const val FONT_MAX = 8.0f
        const val POSITION_STEP = 2f
        const val POSITION_MAX = 40f

        /** 消掉浮点累加误差（0.1 累十次会变成 0.9999999） */
        fun clampOffset(v: Float): Float = ((v.coerceIn(-OFFSET_MAX, OFFSET_MAX) * 10).roundToInt() / 10f)

        fun clampFont(v: Float): Float = (v.coerceIn(FONT_MIN, FONT_MAX) * 10).roundToInt() / 10f

        fun clampPosition(v: Float): Float = v.coerceIn(0f, POSITION_MAX)
    }
}

/** 本机持久化；进程内用 StateFlow 广播，改一下立刻重画（不用等 DataStore 往返） */
@Singleton
class SubtitleStyleStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val json: Json,
) {

    private val scope = AppScopes.io("SubtitleStyle")
    private val _style = MutableStateFlow(SubtitleStyle())
    val style: StateFlow<SubtitleStyle> = _style.asStateFlow()

    init {
        scope.launch {
            val raw = runCatching { context.subtitleStyleStore.data.first()[KEY] }.getOrNull()
            raw?.let {
                runCatching { json.decodeFromString<SubtitleStyle>(it) }.getOrNull()?.let { s ->
                    // 迁移：2.8% 是上一版的默认值（实测偏小）。存着这个值说明用户没调过字号，
                    // 直接换成新的默认 5.2%；真调过别的值就原样尊重。
                    _style.value = if (s.fontPercent == 2.8f) s.copy(fontPercent = 5.2f) else s
                }
            }
        }
    }

    fun update(transform: (SubtitleStyle) -> SubtitleStyle) {
        val next = transform(_style.value)
        _style.value = next
        scope.launch {
            runCatching { context.subtitleStyleStore.edit { it[KEY] = json.encodeToString(next) } }
        }
    }

    private companion object {
        val KEY = stringPreferencesKey("subtitle_style")
    }
}
