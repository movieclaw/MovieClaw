package io.movieclaw.core.update

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.movieclaw.core.model.generated.ClientReleaseView
import io.movieclaw.core.network.generated.McApi
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import java.io.File
import java.security.MessageDigest

/**
 * App 自身的更新（手机 product = "android"，电视 = "androidtv"）：
 * 查最新版（[check]）→ 下载并校验（[download]）→ 交给系统安装器（[install]）。
 *
 * 先直接找官网（官网的下载就是 GitHub Release，[OfficialReleases]）；连不上（国内网络、电视在内网）
 * 再改问自己的服务器——服务器沿用它的 GitHub 出口（代理、镜像）代查、代下。下载同理：先官网直链，失败走服务器。
 * 装不装由用户在系统弹窗里确认；签名与本机不同（例如装的是自己编的测试包）时提前说清楚，不让系统报一句「安装失败」。
 */
class AppUpdater(
    private val context: Context,
    val product: String,
    val currentBuild: Long,
    private val official: OfficialReleases = OfficialReleases(product),
) {
    /** 这次的结果是从哪里查到的 */
    enum class Source { Official, Server }

    sealed interface Check {
        data class UpToDate(val latest: ClientReleaseView, val source: Source) : Check
        data class Available(
            val release: ClientReleaseView,
            val signatureMatches: Boolean?,
            val source: Source,
            /** 官网直链；从服务器查到的为 null（只能经服务器下） */
            val officialApkUrl: String? = null,
        ) : Check
    }

    sealed interface InstallStatus {
        data object WaitingForUser : InstallStatus
        data object Installed : InstallStatus
        data class Failed(val message: String) : InstallStatus
    }

    private val prefs = context.getSharedPreferences("movieclaw_app_update", Context.MODE_PRIVATE)

    var skippedBuild: Long?
        get() = prefs.getLong(KEY_SKIPPED, -1).takeIf { it > 0 }
        set(value) = prefs.edit().putLong(KEY_SKIPPED, value ?: -1).apply()

    fun shouldAutoCheck(now: Long = System.currentTimeMillis()): Boolean =
        UpdatePolicy.shouldAutoCheck(prefs.getLong(KEY_LAST_CHECK, 0), now)

    /** 先官网，失败再问服务器（[api] 为 null 时不兜底）；两边都失败时抛出说明两边原因的错误 */
    suspend fun check(api: McApi?, force: Boolean = false): Check {
        val (latest, source, apkUrl) = runCatching { official.latest() }.fold(
            onSuccess = { Triple(it.release, Source.Official, it.apkUrl) },
            onFailure = { officialError ->
                if (officialError is kotlin.coroutines.cancellation.CancellationException) throw officialError
                if (api == null) throw officialError
                val fromServer = runCatching { api.appClientsLatest(product, refresh = force.takeIf { it }) }
                    .getOrElse { throw UpdateCheckException(officialError, it) }
                Triple(fromServer, Source.Server, null)
            },
        )
        prefs.edit().putLong(KEY_LAST_CHECK, System.currentTimeMillis()).apply()
        return if (UpdatePolicy.isNewer(latest, currentBuild)) {
            Check.Available(latest, UpdatePolicy.signatureMatches(latest, installedCertSha256()), source, apkUrl)
        } else {
            Check.UpToDate(latest, source)
        }
    }

    /**
     * 下载并校验：有官网直链先直连，失败（不通、超时、校验不过）再经服务器下（[serverHttp] 已带账号凭证时 [bearer] 传 null）。
     * [onSource] 告诉界面正在从哪里下。
     */
    suspend fun download(
        offer: Check.Available,
        serverHttp: OkHttpClient?,
        apiBase: HttpUrl?,
        bearer: String?,
        onSource: (Source) -> Unit = {},
        onProgress: (Float) -> Unit = {},
    ): File {
        val direct = offer.officialApkUrl?.toHttpUrlOrNull()
        var officialError: Throwable? = null
        if (direct != null) {
            onSource(Source.Official)
            try {
                return ApkDownload.fetch(OfficialReleases.defaultClient, direct, null, offer.release, downloadDir, onProgress)
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                throw e
            } catch (e: Exception) {
                officialError = e
            }
        }
        if (serverHttp == null || apiBase == null) throw officialError ?: java.io.IOException("没有可用的下载地址")
        onSource(Source.Server)
        onProgress(0f)
        return try {
            ApkDownload.fetch(serverHttp, ApkDownload.serverUrl(apiBase, product), bearer, offer.release, downloadDir, onProgress)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Exception) {
            if (officialError != null) throw UpdateCheckException(officialError, e, downloading = true) else throw e
        }
    }

    /** 自动检查：到时间了才问，有新版且没被跳过才返回 */
    suspend fun autoCheck(api: McApi?): Check.Available? {
        if (!shouldAutoCheck()) return null
        val result = runCatching { check(api) }.getOrNull() as? Check.Available ?: return null
        return result.takeIf { UpdatePolicy.shouldPrompt(it.release, currentBuild, skippedBuild) }
    }

    val downloadDir: File get() = File(context.cacheDir, "app-update")

    /** Android 8+ 要用户允许「安装未知应用」；没允许时 [installPermissionIntent] 带去设置页 */
    fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()

    fun installPermissionIntent(): Intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** 把 APK 写进系统安装会话并提交；系统会弹确认，结果经 [onStatus] 回来（App 被替换时进程直接结束） */
    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    fun install(apk: File, onStatus: (InstallStatus) -> Unit) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
        }
        val sessionId = installer.createSession(params)
        val action = "${context.packageName}.APP_UPDATE_STATUS.$sessionId"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        @Suppress("DEPRECATION")
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        if (confirm != null) ctx.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        onStatus(InstallStatus.WaitingForUser)
                    }
                    PackageInstaller.STATUS_SUCCESS -> {
                        runCatching { ctx.unregisterReceiver(this) }
                        onStatus(InstallStatus.Installed)
                    }
                    else -> {
                        runCatching { ctx.unregisterReceiver(this) }
                        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                        onStatus(InstallStatus.Failed(failureText(status, message)))
                    }
                }
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        runCatching {
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, apk.length()).use { out ->
                    apk.inputStream().use { it.copyTo(out) }
                    session.fsync(out)
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
                val callback = PendingIntent.getBroadcast(context, sessionId, Intent(action).setPackage(context.packageName), flags)
                session.commit(callback.intentSender)
            }
        }.onFailure {
            runCatching { context.unregisterReceiver(receiver) }
            runCatching { installer.abandonSession(sessionId) }
            onStatus(InstallStatus.Failed("没能交给系统安装器：${it.message ?: it.javaClass.simpleName}"))
        }
    }

    /** 本机这份安装包的签名证书 sha256（与发布信息里的 certificateSha256 同口径） */
    fun installedCertSha256(): String? = runCatching {
        val pm = context.packageManager
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info: PackageInfo = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            info.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES).signatures
        }
        signatures?.firstOrNull()?.toByteArray()?.let { cert ->
            MessageDigest.getInstance("SHA-256").digest(cert).joinToString("") { "%02x".format(it) }
        }
    }.getOrNull()

    private fun failureText(status: Int, message: String?): String = when (status) {
        PackageInstaller.STATUS_FAILURE_ABORTED -> "已取消安装"
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "和本机已装的版本签名不同，需要先卸载再装（会清掉登录和设置）"
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "这台设备不支持这个安装包"
        PackageInstaller.STATUS_FAILURE_STORAGE -> "存储空间不足，清理后再试"
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "系统拦截了安装，请在设置里允许本应用安装未知应用"
        else -> "安装失败" + (message?.let { "：$it" } ?: "")
    }

    private companion object {
        const val KEY_SKIPPED = "skipped_build"
        const val KEY_LAST_CHECK = "last_check_at"
    }
}
