package io.movieclaw.androidtv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import io.movieclaw.androidtv.ui.AppRoot
import io.movieclaw.androidtv.ui.LaunchArgs

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val args = LaunchArgs.from(intent)
        setContent { AppRoot(graph, args) }
    }
}
