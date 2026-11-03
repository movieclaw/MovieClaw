package io.movieclaw.core.update

import android.content.ActivityNotFoundException
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageInstaller
import io.movieclaw.core.update.AppUpdater.InstallStatus
import io.movieclaw.core.model.generated.ClientReleaseView
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okio.Buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 34])
class AppUpdaterInstallTest {
    private val app = RuntimeEnvironment.getApplication()
    private val attempts = mutableListOf<Intent>()
    private val statuses = mutableListOf<InstallStatus>()
    private var rejectConfirm = false
    private var rejectFallback = false
    private var blockConfirm = false
    private val context = object : ContextWrapper(app) {
        override fun startActivity(intent: Intent) {
            attempts += intent
            if (intent.action == CONFIRM && blockConfirm) throw SecurityException("blocked")
            if ((intent.action == CONFIRM && rejectConfirm) || (intent.action != CONFIRM && rejectFallback)) {
                throw ActivityNotFoundException("No Activity found to handle $intent")
            }
        }
    }
    private val updater = AppUpdater(context, "androidtv", 1)

    @Before fun initializeProvider() {
        // Robolectric 按需创建 Provider；先启动本次测试的实例，避免沿用上个测试的缓存路径。
        app.contentResolver.acquireContentProviderClient("${app.packageName}.app-update")!!.close()
    }

    private fun pending(
        confirm: Intent? = Intent(CONFIRM),
        apk: File = File(updater.downloadDir.apply { mkdirs() }, "update.apk").apply { writeText("test apk") },
    ) {
        updater.install(apk, statuses::add)
        val registration = shadowOf(app).registeredReceivers.single {
            it.intentFilter.getAction(0).startsWith("${app.packageName}.APP_UPDATE_STATUS.")
        }
        registration.broadcastReceiver.onReceive(context, Intent(registration.intentFilter.getAction(0))
            .putExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_PENDING_USER_ACTION)
            .putExtra(Intent.EXTRA_INTENT, confirm))
    }

    @Test fun missingConfirmationActivityFallsBackToReadableApk() {
        rejectConfirm = true
        pending()
        assertEquals(statuses.toString(), listOf(CONFIRM, Intent.ACTION_VIEW), attempts.map { it.action })
        val fallback = attempts.last()
        assertEquals("content", fallback.data?.scheme)
        assertEquals("${app.packageName}.app-update", fallback.data?.authority)
        assertEquals("application/vnd.android.package-archive", fallback.type)
        assertTrue(fallback.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertTrue(fallback.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertEquals("test apk", app.contentResolver.openInputStream(fallback.data!!)!!.bufferedReader().use { it.readText() })
        assertEquals(listOf(InstallStatus.WaitingForUser), statuses)
        assertTrue(context.packageManager.packageInstaller.mySessions.isEmpty())
        assertTrue(shadowOf(app).registeredReceivers.none {
            it.intentFilter.getAction(0).startsWith("${app.packageName}.APP_UPDATE_STATUS.")
        })
    }

    @Test fun unavailableInstallersReportFailureWithoutCrashing() {
        rejectConfirm = true
        rejectFallback = true
        pending()
        assertTrue(statuses.single() is InstallStatus.Failed)
        assertTrue(context.packageManager.packageInstaller.mySessions.isEmpty())
        assertTrue(shadowOf(app).registeredReceivers.none {
            it.intentFilter.getAction(0).startsWith("${app.packageName}.APP_UPDATE_STATUS.")
        })
    }

    @Test fun normalConfirmationKeepsSessionAndReportsWaiting() {
        pending()
        assertEquals(listOf(CONFIRM), attempts.map { it.action })
        assertEquals(listOf(InstallStatus.WaitingForUser), statuses)
        assertEquals(1, context.packageManager.packageInstaller.mySessions.size)
    }

    @Test fun blockedConfirmationReportsFailureWithoutFallback() {
        blockConfirm = true
        pending()
        assertEquals(listOf(CONFIRM), attempts.map { it.action })
        assertTrue(statuses.single() is InstallStatus.Failed)
        assertTrue(context.packageManager.packageInstaller.mySessions.isEmpty())
        assertTrue(shadowOf(app).registeredReceivers.none {
            it.intentFilter.getAction(0).startsWith("${app.packageName}.APP_UPDATE_STATUS.")
        })
    }

    @Test fun missingConfirmationIntentReportsFailure() {
        pending(null)
        assertTrue(statuses.single() is InstallStatus.Failed)
        assertTrue(context.packageManager.packageInstaller.mySessions.isEmpty())
        assertTrue(shadowOf(app).registeredReceivers.none {
            it.intentFilter.getAction(0).startsWith("${app.packageName}.APP_UPDATE_STATUS.")
        })
    }

    @Test fun downloadedAndVerifiedApkReachesFallbackInstaller() = runTest {
        MockWebServer().use { server ->
            server.start()
            val bytes = "downloaded update".toByteArray()
            val sha = MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }
            server.enqueue(MockResponse.Builder().body(Buffer().write(bytes)).build())
            val release = ClientReleaseView(
                product = "androidtv", version = "0.7.1", build = 2, size = bytes.size.toLong(), sha256 = sha,
            )
            val offer = AppUpdater.Check.Available(release, true, AppUpdater.Source.Server)
            val apk = updater.download(offer, OkHttpClient(), server.url("/api/v1/"), "token")
            rejectConfirm = true
            pending(apk = apk)
            assertArrayEquals(bytes, app.contentResolver.openInputStream(attempts.last().data!!)!!.use { it.readBytes() })
            assertEquals(listOf(InstallStatus.WaitingForUser), statuses)
        }
    }

    private companion object {
        const val CONFIRM = "android.content.pm.action.CONFIRM_INSTALL"
    }
}
