package io.movieclaw.androidtv

import android.content.Intent
import android.os.Bundle
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import android.view.WindowManager
import io.movieclaw.androidtv.core.playback.EngineLog
import io.movieclaw.androidtv.core.playback.FrameRateMatch
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import io.movieclaw.androidtv.system.DeepLink
import io.movieclaw.androidtv.ui.AppRoot
import io.movieclaw.androidtv.ui.LaunchArgs

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val args = LaunchArgs.from(intent)
        args.lab?.let { (application as MovieClawApp).labScenario = it }
        // 调试包：实验台拉黑一个解码器（「名字:MIME」；clear = 清空），验证选解码器与能力申报都会绕开它
        if (BuildConfig.DEBUG) intent.getStringExtra("mc_deny_decoder")?.let { spec ->
            val prefs = object : io.movieclaw.androidtv.core.playback.PrefsStore {
                override fun string(key: String) = graph.store.string(key)
                override fun putString(key: String, value: String?) = graph.store.putString(key, value)
            }
            val list = io.movieclaw.androidtv.core.playback.DecoderDenylist(prefs, graph.identity.appVersion)
            val parts = spec.split(":", limit = 2)
            if (spec == "clear") list.clear() else if (parts.size == 2) list.deny(parts[0], parts[1], "实验台")
        }
        DeepLink.from(intent)?.let { graph.deepLinks.value = it }
        setContent { AppRoot(graph, args) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        DeepLink.from(intent)?.let { graph.deepLinks.value = it }
        if (BuildConfig.DEBUG) {
            intent.getLongExtra("mc_seek_ms", -1).takeIf { it >= 0 }?.let { graph.labSeeks.tryEmit(it) }
            intent.getStringExtra("mc_audio")?.let { graph.labTracks.tryEmit("audio" to it) }
            intent.getStringExtra("mc_subtitle")?.let { graph.labTracks.tryEmit("subtitle" to it) }
        }
    }

    /**
     * 自动帧率匹配（androidtv-app.md §4.4）：按片源帧率切显示模式。遵从系统「匹配内容帧率」设置
     * （Android 12+）：从不 → 不切；仅无缝 → 交给 Media3 自带的无缝切换；始终 → 主动切。更老的系统没有这个设置，主动切
     */
    fun matchFrameRate(fps: Float?) {
        val preference = frameRatePreference()
        val display = window.decorView.display ?: return
        val current = display.mode
        val target = if (preference == FrameRateMatch.Preference.Always) {
            FrameRateMatch.pick(display.supportedModes.map(::modeOf), modeOf(current), fps)
        } else {
            null
        }
        EngineLog.add(
            "display",
            "帧率匹配 片源 ${fps ?: "?"}fps 设置 $preference 当前 ${modeOf(current)}" + (target?.let { " → 切到 $it" } ?: " → 不切"),
        )
        if (target != null) window.attributes = window.attributes.also { it.preferredDisplayModeId = target.id }
    }

    /** 离开播放器：交还给系统默认的显示模式 */
    fun restoreDisplayMode() {
        if (window.attributes.preferredDisplayModeId != 0) {
            window.attributes = window.attributes.also { it.preferredDisplayModeId = 0 }
        }
    }

    private fun frameRatePreference(): FrameRateMatch.Preference {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return FrameRateMatch.Preference.Always
        return when (getSystemService(DisplayManager::class.java)?.matchContentFrameRateUserPreference) {
            DisplayManager.MATCH_CONTENT_FRAMERATE_NEVER -> FrameRateMatch.Preference.Never
            DisplayManager.MATCH_CONTENT_FRAMERATE_SEAMLESSS_ONLY -> FrameRateMatch.Preference.SeamlessOnly
            else -> FrameRateMatch.Preference.Always
        }
    }

    private fun modeOf(mode: Display.Mode) = FrameRateMatch.Mode(mode.modeId, mode.physicalWidth, mode.physicalHeight, mode.refreshRate)

    /** 播放器要求常亮时调用（看片不熄屏 / 不进屏保） */
    fun keepScreenOn(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
