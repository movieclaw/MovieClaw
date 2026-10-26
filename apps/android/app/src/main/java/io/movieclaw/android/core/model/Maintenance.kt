package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/* ---------------- 更新与维护 ---------------- */

@Serializable
data class UpdateStatus(
    val currentVersion: String = "",
    val codeSource: String = "",
    val overlayVersion: String? = null,
    /** 镜像运行时版本（依赖集合代号）；非 Docker 部署为 null */
    val runtimeVersion: Int? = null,
    val canUpdate: Boolean = false,
    val hasPrevious: Boolean = false,
    val previousVersion: String? = null,
    val badVersions: List<String> = emptyList(),
    val modelTag: String? = null,
    val inactiveOverlayVersion: String? = null,
    val inactiveOverlayReason: String? = null,
    /** 近 7 天内最近一次容器异常退出并被自动拉起的记录；没有为 null */
    val lastAbnormalExit: LastAbnormalExit? = null,
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
    /** 「走代理」开关列表（服务端目录；iOS `current.services`） */
    val services: List<EgressService> = emptyList(),
    /** 环境变量里探测到的代理地址（env 模式下给用户确认） */
    @kotlinx.serialization.SerialName("env_proxy_detected")
    val envProxyDetected: String = "",
    /** 镜像地址的生效默认值（留空时的回落），键 = tmdb_api / tmdb_image / douban_api */
    @kotlinx.serialization.SerialName("mirror_defaults")
    val mirrorDefaults: Map<String, String> = emptyMap(),
)

/** 设置页「走代理」开关列表里的一项（服务端 `EgressServiceOption`） */
@Serializable
data class EgressService(
    val id: String = "",
    val label: String = "",
    val description: String = "",
) {
    /** PT 站点在服务端用 `site:<站点 id>` 前缀 */
    val isSite: Boolean get() = id.startsWith("site:")
}

/** 应用设置（GET/PUT /app/config：外部访问地址 + 对外端口状态） */
@Serializable
data class AppConfig(
    @kotlinx.serialization.SerialName("external_url") val externalUrl: String = "",
    @kotlinx.serialization.SerialName("web_port") val webPort: Int = 0,
    @kotlinx.serialization.SerialName("web_port_source") val webPortSource: String = "default",
    @kotlinx.serialization.SerialName("web_port_default") val webPortDefault: Int = 0,
    @kotlinx.serialization.SerialName("web_port_rejected") val webPortRejected: Int? = null,
    @kotlinx.serialization.SerialName("web_port_configurable") val webPortConfigurable: Boolean = false,
)

@Serializable
data class AppConfigPayload(
    @kotlinx.serialization.SerialName("external_url") val externalUrl: String,
)

@Serializable
data class WebPortPayload(
    /** null / 0 = 清除设置、恢复默认 */
    val port: Int? = null,
)

/** POST /network/test 的请求体：要测的服务 id（tmdb / image / douban / llm / site:<id> …） */
@Serializable
data class NetworkTestPayload(val service: String)

@Serializable
data class NetworkTestResult(
    val ok: Boolean = false,
    val latencyMs: Int? = null,
    val message: String = "",
)

/** 近 7 天内最近一次容器异常退出并被自动拉起的记录（Web `last_abnormal_exit`） */
@Serializable
data class LastAbnormalExit(
    val at: String = "",
    val exitCode: Int = 0,
    val detail: String = "",
)

/** 一个可回退（或切换）的目标版本（GET /app/update/rollback/options） */
@Serializable
data class RollbackTarget(
    /** baseline = Docker 镜像内置版本；version = 本地保留的历史版本 */
    val kind: String = "version",
    val version: String? = null,
    val changelog: String? = null,
    val installedAt: String? = null,
    val sizeBytes: Long? = null,
    /** switch=直接切换数据保留 / restore=需恢复备份 / unknown=无对应备份 */
    val schemaAction: String = "unknown",
    val backupTakenAt: String? = null,
)

@Serializable
data class RollbackOptions(
    val targets: List<RollbackTarget> = emptyList(),
    val versionsDirBytes: Long = 0,
    val keepVersions: Int = 3,
)

/** GitHub 访问令牌的配置状态；明文永不回传，只给打码尾号 */
@Serializable
data class GithubToken(
    val configured: Boolean = false,
    val masked: String = "",
)

/** 检查 NER 模型更新的结果（POST /app/update/model/check） */
@Serializable
data class ModelUpdateCheck(
    val currentTag: String? = null,
    val latestTag: String = "",
    val updateAvailable: Boolean = false,
    /** 最新模型发布是否携带更新清单（没带则无法应用内安装） */
    val installable: Boolean = false,
    val publishedAt: String = "",
)

/** 一个注册的定时任务：定义（代码里）+ 周期（库里可改）+ 运行台账 */
@Serializable
data class ScheduledTask(
    val key: String = "",
    val title: String = "",
    val description: String = "",
    val enabled: Boolean = false,
    /** interval | cron */
    val triggerType: String = "interval",
    val intervalSeconds: Long? = null,
    val cronExpr: String? = null,
    val lastRunAt: String? = null,
    val nextRunAt: String? = null,
)

@Serializable
data class RollbackRequest(
    /** "baseline" = 镜像内置版本；否则为版本号 */
    val target: String,
    /** 跨数据库升级的回退要一并恢复对应时点的自动备份 */
    @kotlinx.serialization.SerialName("restore_backup") val restoreBackup: Boolean = false,
)

@Serializable
data class RetentionRequest(
    @kotlinx.serialization.SerialName("keep_versions") val keepVersions: Int,
)

@Serializable
data class GithubTokenPayload(val token: String)

@Serializable
data class ScheduledTaskUpdate(
    val enabled: Boolean,
    /** interval | cron */
    @kotlinx.serialization.SerialName("trigger_type") val triggerType: String,
    @kotlinx.serialization.SerialName("interval_seconds") val intervalSeconds: Long? = null,
    @kotlinx.serialization.SerialName("cron_expr") val cronExpr: String? = null,
)
