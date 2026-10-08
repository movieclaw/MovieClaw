package io.movieclaw.androidtv

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import io.movieclaw.androidtv.system.DeepLink
import io.movieclaw.androidtv.ui.AppRoot
import io.movieclaw.androidtv.ui.LaunchArgs

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val args = LaunchArgs.from(intent)
        DeepLink.from(intent)?.let { graph.deepLinks.value = it }
        setContent { AppRoot(graph, args) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        DeepLink.from(intent)?.let { graph.deepLinks.value = it }
    }

    /** 播放器要求常亮时调用（看片不熄屏 / 不进屏保） */
    fun keepScreenOn(on: Boolean) {
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
