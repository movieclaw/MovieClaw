package io.movieclaw.androidtv.ui

import android.content.Intent

/**
 * 调试直达参数（只认 debug 包）：端到端验收时跳过手动输入，同 Apple 端的 `-mcServer -mcUser -mcPass`。
 *
 *   adb shell am start -n io.movieclaw.androidtv/.MainActivity \
 *     --es mc_server http://10.0.2.2:8810 --es mc_user admin --es mc_pass xxx --el mc_play 2
 */
data class LaunchArgs(
    val server: String? = null,
    val username: String? = null,
    val password: String? = null,
    val playMediaItemId: Long? = null,
) {
    companion object {
        fun from(intent: Intent?): LaunchArgs {
            if (intent == null || !io.movieclaw.androidtv.BuildConfig.DEBUG) return LaunchArgs()
            return LaunchArgs(
                server = intent.getStringExtra("mc_server"),
                username = intent.getStringExtra("mc_user"),
                password = intent.getStringExtra("mc_pass"),
                playMediaItemId = intent.getLongExtra("mc_play", -1).takeIf { it > 0 },
            )
        }
    }
}
