package io.movieclaw.android

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import dagger.hilt.android.AndroidEntryPoint
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.android.core.session.DeepLinkBus
import io.movieclaw.android.core.playback.PlaybackSessionHolder
import io.movieclaw.android.routing.MovieClawRoot
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject
    lateinit var playbackHolder: PlaybackSessionHolder

    @Inject
    lateinit var deepLinkBus: DeepLinkBus

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* 拒绝则仅无通知,播放不受影响 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        requestNotificationPermissionIfNeeded()
        deepLinkBus.parse(intent?.dataString)?.let(deepLinkBus::publish)
        handleNotificationTab(intent)
        setContent {
            MovieClawTheme {
                MovieClawRoot()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deepLinkBus.parse(intent.dataString)?.let(deepLinkBus::publish)
        handleNotificationTab(intent)
    }

    /** 通知点按落点：有具体条目就投路由（AppNav 消费），否则退到底栏页（见 core/notify） */
    private fun handleNotificationTab(intent: Intent?) {
        intent?.getStringExtra("mc_route")?.takeIf { it.isNotBlank() }?.let {
            io.movieclaw.android.core.notify.NotifyRouteBus.publish(it)
            return
        }
        when (intent?.getStringExtra("mc_tab")) {
            "ACTIVITY" -> io.movieclaw.android.feature.root.MainTabBus.open(
                io.movieclaw.android.feature.root.MainTab.ACTIVITY,
            )
            "SUBSCRIPTIONS" -> io.movieclaw.android.feature.root.MainTabBus.open(
                io.movieclaw.android.feature.root.MainTab.SUBSCRIPTIONS,
            )
        }
    }

    /** 自动画中画:播放中按 Home/切走时进入 PiP(对齐视频应用习惯) */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (playbackHolder.isPlaying()) {
            runCatching {
                enterPictureInPictureMode(
                    PictureInPictureParams.Builder()
                        .setAspectRatio(Rational(16, 9))
                        .build()
                )
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
