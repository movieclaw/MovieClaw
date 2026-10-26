package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 手动下载的「识别 → 路由 → 投递目录」预检输入（`POST /downloaders/resolve-target`）。
 *
 * 身份三件套（kind/title/year）齐全时按它自动收敛；收敛失败或种子没解析出身份时，
 * 改用 [hint]（搜索框里的关键词）检索 TMDB 给候选请用户点选确认。
 */
@Serializable
data class ManualDownloadTargetRequest(
    val kind: String? = null,
    val title: String? = null,
    val year: Int? = null,
    val subtitle: String? = null,
    val hint: String? = null,
    /** 预检指定下载器；缺省用默认下载器（成员不许指定） */
    val downloaderId: Long? = null,
    /** 用户从候选里确认的 TMDB 条目 ID（服务端会按同样的线索重新求候选再校验） */
    val selectedTmdbId: Int? = null,
    /** 确认候选的媒体类型；缺省同 [kind]（TMDB 的电影与剧集 ID 会撞号，必须带） */
    val selectedKind: String? = null,
)

/** 预检未收敛时留给用户确认的 TMDB 候选 */
@Serializable
data class ManualDownloadCandidateView(
    val tmdbId: Int = 0,
    val kind: String = "movie",
    val title: String = "",
    val year: Int? = null,
    val episodeCount: Int? = null,
    val posterUrl: String? = null,
)

/** 预检结论：能不能自动入库、落到哪个目录、库名与路由理由 */
@Serializable
data class ManualDownloadTargetView(
    /** ready / ambiguous / not_found */
    val status: String = "not_found",
    val tmdbId: Int? = null,
    val kind: String? = null,
    /** TMDB 标题：提交智能入库时原样带回（不能用乱码的种子标题代替） */
    val title: String? = null,
    val year: Int? = null,
    val candidates: List<ManualDownloadCandidateView> = emptyList(),
    val libraryId: Long? = null,
    val libraryName: String? = null,
    /** watch / inplace / downloader_default */
    val mode: String? = null,
    /** movieclaw 视角的实际投递目录 */
    val path: String? = null,
    /** 条目目录的完整路径预览（按生效的命名模板渲染）——展示落点用它，不要自己拼「标题 (年份)」 */
    val entryDir: String? = null,
    /** 自定义目录规则的整理落点 */
    val stagingPath: String? = null,
    val routeMatched: Boolean? = null,
    val routeReason: String? = null,
    /** 当前选择的下载器与投递配置能否自动入库 */
    val ok: Boolean = false,
    /** 不可自动入库时的中文指引 */
    val warning: String? = null,
)

/** 我的保存位置记忆（搜索结果页据此决定弹确认条还是完整弹窗） */
@Serializable
data class DownloadTargetPrefView(
    /** 种子分类（TorrentCategory 值） */
    val category: String = "other",
    /** smart=智能入库 / dir=固定目录 / default=下载器默认目录 */
    val kind: String = "default",
    val savePath: String? = null,
    val downloaderId: Long? = null,
    /** 下载器名；空 = 用默认下载器，或指定的下载器已被删除（据此判记忆失效） */
    val downloaderName: String? = null,
    val updatedAt: String? = null,
)

/** 一条路径映射（movieclaw 路径 → 下载器路径） */
@Serializable
data class PathMapping(
    val local: String = "",
    val remote: String = "",
)

/** 一条路径体检结果（服务端 `PathHealthView`）：state = ok / empty / not_dir / missing / unmapped */
@Serializable
data class PathHealthView(
    val local: String = "",
    val remote: String = "",
    val state: String = "",
    val detail: String? = null,
)

/** 下载器配置（脱敏视图）；搜索结果页的「其他保存位置」与设置页共用 */
@Serializable
data class DownloaderView(
    val id: Long = 0,
    val name: String = "",
    val clientType: String = "",
    val url: String = "",
    val username: String? = null,
    val savePath: String? = null,
    val pathMappings: List<PathMapping>? = null,
    val enabled: Boolean = true,
    val isDefault: Boolean = false,
    val status: String = "",
    /** 已启用且连接测试通过 */
    val usable: Boolean = false,
    val version: String? = null,
    val lastError: String? = null,
    val lastCheckedAt: String? = null,
    /** 每个映射的体检结果（空 = 没配映射，视为正常） */
    val pathHealth: List<PathHealthView> = emptyList(),
    val pathsHealthy: Boolean = true,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

/** 可接入的下载器类型（`GET /downloaders/types`）：内置 qBittorrent / Transmission，插件可追加 */
@Serializable
data class DownloaderTypeInfo(
    val type: String = "",
    val title: String = "",
    val connection: String = "",
    /** 地址这一栏该叫什么（WebUI 地址 / RPC 地址） */
    val urlLabel: String? = null,
    val urlPlaceholder: String? = null,
    val needsUsername: Boolean = false,
    val help: String? = null,
)

/** 新增 / 更新下载器的请求体（更新是全字段覆盖；密码留空 = 无密码） */
@Serializable
data class DownloaderPayload(
    val name: String,
    val clientType: String,
    val url: String,
    val username: String? = null,
    val password: String? = null,
    val savePath: String? = null,
    val pathMappings: List<PathMapping>? = null,
    val enabled: Boolean = true,
)

/** 启停请求体 */
@Serializable
data class DownloaderStatusPayload(val enabled: Boolean)

/** 删除结果：被这台下载器刷流的站点（服务端会顺手关掉它们的刷流） */
@Serializable
data class DownloaderDeleteResult(val boostDisabledSites: List<String> = emptyList())

/** 限速与队列（读写同一结构；null = 保持现状，限速 0 = 不限） */
@Serializable
data class DownloaderLimits(
    val downloadLimitBytes: Long? = null,
    val uploadLimitBytes: Long? = null,
    val altSpeedEnabled: Boolean? = null,
    val queueEnabled: Boolean? = null,
    val maxActiveDownloads: Int? = null,
    val maxActiveUploads: Int? = null,
    val maxActiveTorrents: Int? = null,
)

/** `POST /downloaders/submit` 的结果：提交到哪台下载器、实际用了哪个目录 */
@Serializable
data class DownloadSubmitView(
    val infoHash: String? = null,
    val name: String = "",
    /** 种子提交前已存在于下载器（幂等，未重复添加） */
    val alreadyExists: Boolean = false,
    val downloaderId: Long = 0,
    val downloaderName: String = "",
    /** 实际保存目录（下载器视角）；成员一律为空 */
    val savePath: String? = null,
)

/** `POST /subscriptions/{id}/selected-torrent-downloads` 的请求体：搜索结果行原样回传 */
@Serializable
data class GrabPayload(
    val siteId: String,
    val torrentId: String,
    val title: String,
    val subtitle: String? = null,
    val category: String? = null,
    val downloadUrl: String? = null,
    val sizeBytes: Long? = null,
    val seeders: Int? = null,
    val isFree: Boolean? = null,
    val hitAndRun: Boolean? = null,
    /** 站点提供的扩充属性（服务端搜索链路解析出的那份） */
    val attrs: kotlinx.serialization.json.JsonObject? = null,
    val imdbId: String? = null,
    val doubanId: String? = null,
    val publishTime: String? = null,
)

/** 手动选种的结果：这次投递覆盖了哪些追踪单元 */
@Serializable
data class GrabResultView(
    val units: List<DownloadUnitView> = emptyList(),
)
