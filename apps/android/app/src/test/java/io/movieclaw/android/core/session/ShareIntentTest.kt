package io.movieclaw.android.core.session

import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34])
class ShareIntentTest {
    @Test fun manifestRoutesShareLinksWithoutCapturingUnrelatedBrowserUrls() {
        val context = RuntimeEnvironment.getApplication()
        fun resolves(url: String): Boolean = context.packageManager.queryIntentActivities(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE),
            PackageManager.MATCH_DEFAULT_ONLY,
        ).any { it.activityInfo.name == "io.movieclaw.android.MainActivity" }
        assertTrue(resolves("https://nas.example/s/movie"))
        assertTrue(resolves("http://nas.example:8096/s/movie"))
        assertTrue(resolves("movieclaw://share/movie?origin=https%3A%2F%2Fnas.example"))
        assertFalse(resolves("https://nas.example/settings"))
        assertFalse(resolves("http://nas.example/api/v1/media-items"))
    }
}
