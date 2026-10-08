package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/* ---------------- 更新与维护 ---------------- */

@Serializable
data class UpdateStatus(
    val currentVersion: String = "",
    val codeSource: String = "",
    val overlayVersion: String? = null,
    val canUpdate: Boolean = false,
    val hasPrevious: Boolean = false,
    val previousVersion: String? = null,
    val badVersions: List<String> = emptyList(),
    val modelTag: String? = null,
    val inactiveOverlayVersion: String? = null,
    val inactiveOverlayReason: String? = null,
)

/**
 * 待更新快照（`GET /app/update/pending`，读库不触网）：「我的」页提醒组与设置页的更新卡片
 * 都由它点亮。`appVersion`/`modelTag` 都为 null = 无可用更新（含从未检查过）。
 */
@Serializable
data class PendingUpdate(
    val appVersion: String? = null,
    /** False = 该版本含依赖变化，需重拉 Docker 镜像，应用内更新按钮不可用 */
    val appCompatible: Boolean = true,
    val appChangelog: String = "",
    val appPublishedAt: String = "",
    val modelTag: String? = null,
    val checkedAt: String? = null,
)

@Serializable
data class UpdateCheck(
    val currentVersion: String = "",
    val latestVersion: String = "",
    val updateAvailable: Boolean = false,
    val compatible: Boolean = true,
    val requiresRuntime: Int = 0,
    val changelog: String = "",
    val publishedAt: String = "",
    val latestKnownBad: Boolean = false,
)

@Serializable
data class UpdateProgress(
    val phase: String = "",
    val detail: String = "",
    val percent: Float? = null,
    val error: String? = null,
    val targetVersion: String? = null,
)

/** 存储用量:顶层是总量,dirs 是登记目录(无单目录体积,清理动作按 clearable 给) */
@Serializable
data class StorageUsage(
    val dataRoot: String = "",
    val diskTotal: Long = 0,
    val diskUsed: Long = 0,
    val diskFree: Long = 0,
    val cacheBytes: Long = 0,
    val dataBytes: Long = 0,
    val dirs: List<StorageDir> = emptyList(),
    val computedAt: Long = 0,
)

@Serializable
data class StorageDir(
    val key: String = "",
    val title: String = "",
    val summary: String = "",
    val description: String = "",
    val path: String = "",
    /** cache=可清理派生物 / data=只展示 */
    val group: String = "data",
    val rebuildCost: String = "none",
    val clearable: Boolean = false,
    val orphanAware: Boolean = false,
    val exists: Boolean = true,
)

@Serializable
data class StorageState(
    val usage: StorageUsage? = null,
    val computing: Boolean = false,
    val error: String? = null,
)

@Serializable
data class CleanResult(
    val key: String = "",
    val mode: String = "",
    val removed: Int = 0,
    val skippedBusy: Int = 0,
    val freedBytes: Long = 0,
)

/* ---------------- 日志 ---------------- */

@Serializable
data class LogDay(val day: String = "", val sizeBytes: Long = 0)

@Serializable
data class LogDayList(val days: List<LogDay> = emptyList())

@Serializable
data class LogContent(
    val day: String = "",
    val lines: List<String> = emptyList(),
    val totalLines: Int = 0,
    val truncated: Boolean = false,
    val sizeBytes: Long = 0,
)

/* ---------------- 网络 ---------------- */

@Serializable
data class NetworkConfig(
    val proxyMode: String = "off",
    val proxyUrl: String = "",
    val proxyServices: List<String> = emptyList(),
    val tmdbApiBaseUrl: String = "",
    val tmdbImageBaseUrl: String = "",
    val doubanApiBaseUrl: String = "",
)

@Serializable
data class NetworkTestResult(
    val ok: Boolean = false,
    val latencyMs: Int? = null,
    val message: String = "",
)
