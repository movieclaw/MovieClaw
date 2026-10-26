package io.movieclaw.android.core.push

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.net.toUri

/*
 * 后台运行引导：国产系统（vivo / OPPO / 小米 / 华为 / 荣耀…）默认会冻结、清理后台 App，
 * 前台服务也可能被杀。实时通知要稳定，需要用户手动放行几项。厂商设置页没有公开接口，
 * 这里按已知的页面逐个尝试，打不开就退回「应用详情」页，由文字说明指路。
 */
object BackgroundGuide {

    /** 每一步旁边的按钮打开哪里；null = 只能手动操作 */
    enum class Action { BATTERY_OPTIMIZATION, VENDOR_SETTINGS, APP_DETAILS }

    data class Step(val title: String, val detail: String, val action: Action?)

    fun isVivo(): Boolean = Build.MANUFACTURER.lowercase() in setOf("vivo", "iqoo")

    /** 给当前机型的步骤说明（vivo 写得最细，其他厂商给通用说法） */
    fun steps(): List<Step> {
        val maker = Build.MANUFACTURER.lowercase()
        val autostart = when {
            isVivo() -> "i管家 → 应用管理 → 权限管理 → 自启动，打开 MovieClaw（新系统在「设置 → 应用与权限 → 权限管理 → 自启动」）"
            maker == "xiaomi" || maker == "redmi" -> "安全中心 → 应用管理 → 权限 → 自启动管理，打开 MovieClaw"
            maker == "oppo" || maker == "oneplus" || maker == "realme" -> "设置 → 应用 → 自启动管理，打开 MovieClaw"
            maker == "huawei" || maker == "honor" -> "设置 → 应用和服务 → 应用启动管理，MovieClaw 改为手动管理并全部打开"
            else -> "在系统的应用管理里允许 MovieClaw 自启动 / 后台启动"
        }
        val battery = when {
            isVivo() -> "设置 → 电池 → 后台耗电管理 → MovieClaw → 允许后台高耗电"
            maker == "xiaomi" || maker == "redmi" -> "设置 → 应用设置 → MovieClaw → 省电策略 → 无限制"
            maker == "oppo" || maker == "oneplus" || maker == "realme" -> "设置 → 电池 → 应用耗电管理 → MovieClaw → 允许后台运行"
            maker == "huawei" || maker == "honor" -> "设置 → 电池 → 更多电池设置 → 休眠时始终保持网络连接"
            else -> "在电池设置里允许 MovieClaw 后台运行、不受限制"
        }
        return listOf(
            Step("忽略电池优化", "在系统弹窗里选「允许」，熄屏后连接不会被断开", Action.BATTERY_OPTIMIZATION),
            Step("允许自启动", autostart, Action.VENDOR_SETTINGS),
            Step("允许后台运行", battery, Action.APP_DETAILS),
            Step("锁定在最近任务", "打开多任务界面，下拉 MovieClaw 的卡片或长按选「锁定」，一键清理时不会被清掉", null),
        )
    }

    fun ignoringBatteryOptimizations(context: Context): Boolean =
        context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) ?: true

    /** 系统标准流程：直接弹「允许 MovieClaw 在后台运行？」；不支持就退到电池优化列表 */
    @SuppressLint("BatteryLife") // 实时通知就是这个权限的正当用途：用户主动开启后才引导
    fun requestIgnoreBatteryOptimizations(context: Context): Boolean =
        launchFirst(
            context,
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, "package:${context.packageName}".toUri()),
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            appDetails(context),
        )

    /** 厂商的自启动 / 后台管理页；都打不开就退回应用详情 */
    fun openVendorBackgroundSettings(context: Context): Boolean =
        launchFirst(context, *(vendorIntents() + appDetails(context)).toTypedArray())

    fun openAppDetails(context: Context): Boolean = launchFirst(context, appDetails(context))

    private fun appDetails(context: Context) =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri())

    private fun component(pkg: String, cls: String) = Intent().setComponent(ComponentName(pkg, cls))

    private fun vendorIntents(): List<Intent> {
        val maker = Build.MANUFACTURER.lowercase()
        return when {
            isVivo() -> listOf(
                component("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                component("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
                component("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
                component("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.PurviewTabActivity"),
                component("com.iqoo.secure", "com.iqoo.secure.MainActivity"),
            )
            maker == "xiaomi" || maker == "redmi" -> listOf(
                component("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            )
            maker == "oppo" || maker == "oneplus" || maker == "realme" -> listOf(
                component("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
                component("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
                component("com.oplus.safecenter", "com.oplus.safecenter.startupapp.StartupAppListActivity"),
            )
            maker == "huawei" || maker == "honor" -> listOf(
                component("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
                component("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            )
            else -> emptyList()
        }
    }

    /** 逐个尝试：厂商页常常不导出或已改名，打不开（找不到 / 无权限）就试下一个 */
    private fun launchFirst(context: Context, vararg intents: Intent): Boolean = intents.any { intent ->
        runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess
    }
}
