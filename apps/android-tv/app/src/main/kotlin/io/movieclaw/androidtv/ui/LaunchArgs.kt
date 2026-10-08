package io.movieclaw.androidtv.ui

import android.content.Intent

/**
 * 调试直达参数（只认 debug 包），同 Apple 端 DebugLaunch 的 `-mcServer -mcUser -mcPass -mcTab -mcRoute`：
 *
 *   adb shell am start -n io.movieclaw.androidtv/.MainActivity \
 *     --es mc_server http://10.0.2.2:8810 --es mc_user admin --es mc_pass xxx \
 *     [--es mc_tab account|search|home] [--el mc_play <id>] [--es mc_item <库>-<条目>]
 */
data class LaunchArgs(
    val server: String? = null,
    val username: String? = null,
    val password: String? = null,
    val tab: String? = null,
    val playMediaItemId: Long? = null,
    val item: Pair<Long, Long>? = null,
) {
    companion object {
        fun from(intent: Intent?): LaunchArgs {
            if (intent == null || !io.movieclaw.androidtv.BuildConfig.DEBUG) return LaunchArgs()
            return LaunchArgs(
                server = intent.getStringExtra("mc_server"),
                username = intent.getStringExtra("mc_user"),
                password = intent.getStringExtra("mc_pass"),
                tab = intent.getStringExtra("mc_tab"),
                playMediaItemId = intent.getLongExtra("mc_play", -1).takeIf { it > 0 },
                item = intent.getStringExtra("mc_item")?.split("-")?.mapNotNull { it.toLongOrNull() }
                    ?.takeIf { it.size == 2 }?.let { it[0] to it[1] },
            )
        }
    }
}
