package io.movieclaw.android.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/*
 * 资源站点（设置 → 资源站点，原生页）：服务端 `schemas/site.py` 的同构模型。
 * 登录态有三种：cookie / apikey / credential（用户名密码），由站点目录的 required_fields 决定要填哪些。
 */

/** 站点目录里一种授权方式及其必填字段（如 cookie；credential 需要 username + password） */
@Serializable
data class AuthTypeRequirement(
    val authType: String = "",
    val requiredFields: List<String> = emptyList(),
)

/** `GET /sites/catalog`：可接入的站点 */
@Serializable
data class SiteCatalogItem(
    val siteId: String = "",
    val displayName: String = "",
    val baseUrl: String? = null,
    val supportedAuthTypes: List<AuthTypeRequirement> = emptyList(),
)

/** 站点账号资料（验证通过后拉到的） */
@Serializable
data class SiteProfile(
    val username: String? = null,
    val userClass: String? = null,
    val uploadedBytes: Long = 0,
    val downloadedBytes: Long = 0,
    val ratio: Double? = null,
    val bonus: Double? = null,
    val seedingCount: Int = 0,
    val leechingCount: Int = 0,
    val fetchedAt: String? = null,
)

/**
 * 已配置的站点（脱敏，无 cookie / api_key / 密码）。
 * `status`：pending（已保存待验证）/ verifying / active / failed（原因在 lastError）。
 */
@Serializable
data class ConfiguredSite(
    val siteId: String = "",
    val authType: String = "",
    val enabled: Boolean = true,
    val status: String = "",
    /** 已启用且验证通过 */
    val usable: Boolean = false,
    @SerialName("protected") val isProtected: Boolean = false,
    val boostEnabled: Boolean = false,
    val boostPaused: Boolean = false,
    val boostBudgetBytes: Long = 0,
    val boostHoldDays: Int? = null,
    val boostDownloaderId: Long? = null,
    val lastVerifiedAt: String? = null,
    val lastCheckedAt: String? = null,
    val lastError: String? = null,
    val profile: SiteProfile? = null,
)

/** 新增站点：site_id + 授权方式 + 该方式的凭据字段 */
@Serializable
data class SiteConfigCreate(
    val siteId: String,
    val authType: String,
    val cookie: String? = null,
    val apiKey: String? = null,
    val username: String? = null,
    val password: String? = null,
    val enabled: Boolean = true,
)

/** 更新授权（路径里带 site_id；密码类字段不回显，需重填） */
@Serializable
data class SiteConfigUpdate(
    val authType: String,
    val cookie: String? = null,
    val apiKey: String? = null,
    val username: String? = null,
    val password: String? = null,
    val enabled: Boolean = true,
)

@Serializable
data class SiteEnabledPayload(val enabled: Boolean)

@Serializable
data class SiteProtectedPayload(@SerialName("protected") val isProtected: Boolean)

/** 刷流：开启/预算/保留期/下载器；调小预算会按效率汰换在池任务 */
@Serializable
data class SiteBoostPayload(
    val enabled: Boolean,
    val budgetBytes: Long? = null,
    val holdDays: Int? = null,
    val downloaderId: Long? = null,
)

@Serializable
data class SitePausePayload(val paused: Boolean)

/** 站点种子缓存与同步节奏（GET /sites/sync-stats，key = site_id） */
@Serializable
data class SiteSyncStatsView(
    val torrentCount: Int = 0,
    val trackingSince: String? = null,
    val lastSyncAt: String? = null,
    val lastSuccessAt: String? = null,
    /** null = 立即到期（新站等待首刷） */
    val nextSyncAt: String? = null,
    val syncIntervalSeconds: Int? = null,
    val lastNewCount: Int? = null,
    /** null = 上次同步成功 */
    val lastError: String? = null,
    val consecutiveFailures: Int = 0,
)

/** 站点刷流运行统计（GET /sites/boost-stats，key = site_id） */
@Serializable
data class SiteBoostStatsView(
    val activeCount: Int = 0,
    val usedBytes: Long = 0,
    val budgetBytes: Long = 0,
    val uploadedBytesTotal: Long = 0,
    val evictedCount: Int = 0,
    val uploadedBytes24h: Long = 0,
    val avgUsedBytes24h: Long = 0,
    val uploadedBytes7d: Long = 0,
    val avgUsedBytes7d: Long = 0,
)
