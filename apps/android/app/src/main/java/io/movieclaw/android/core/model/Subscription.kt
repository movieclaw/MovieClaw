package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

@Serializable
data class MediaBrief(
    val mediaItemId: Long = 0,
    val kind: String = "movie",
    val tmdbId: Int? = null,
    val title: String = "",
    val originalTitle: String? = null,
    val year: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val logoUrl: String? = null,
    val status: String? = null,
)

@Serializable
data class SeasonOverview(
    val seasonNumber: Int = 0,
    val name: String? = null,
    val airDate: String? = null,
    val episodeCount: Int? = null,
    val airedCount: Int = 0,
    val ownedCount: Int = 0,
)

/** POST /subscriptions/title-preview 的结果 */
@Serializable
data class PrepareView(
    val status: String = "not_found",
    val media: MediaBrief? = null,
    val seasons: List<SeasonOverview> = emptyList(),
    val existingSubscriptionId: Long? = null,
    val movieOwned: Boolean = false,
    val suggestedSeasons: List<Int> = emptyList(),
    /** 智能选择摘要：服务端按设置、记忆和作品信息解析好的结果与整句文案；旧服务端没有 */
    val smart: SmartPlanView? = null,
)

/** 第一次碰到某种语言时问的那一句（文案由服务端生成） */
@Serializable
data class SmartQuestionView(
    val language: String = "",
    val prompt: String = "",
    val subtitlesLabel: String = "",
    val understoodLabel: String = "",
)

@Serializable
data class SmartScopeOptionView(
    /** 回传给创建接口的 smart_scope；only = 只这部 */
    val value: String = "only",
    val label: String = "",
)

/** `PrepareView.smart`（docs/design/smart-subscription-memory.md） */
@Serializable
data class SmartPlanView(
    val configured: Boolean = false,
    val profileRevision: Long = 0,
    val memoryRevision: Long = 0,
    val resolution: String? = null,
    val source: String? = null,
    /** 如「优先 4K WEB-DL」 */
    val qualityLabel: String? = null,
    /** 如「按「韩国的剧」的习惯」 */
    val qualityNote: String? = null,
    /** 被更具体的习惯盖住的那条，如「「韩国的剧」是 1080p」 */
    val qualityShadow: String? = null,
    val waitLabel: String? = null,
    val subtitleLanguage: String? = null,
    val subtitleLanguageLabel: String? = null,
    val subtitleUnderstood: Boolean? = null,
    /** 如「英语 · 只下带中文字幕的」；中文或未知语言为空 */
    val subtitleLine: String? = null,
    /** 仅管理员、且这种语言还没回答过时给出 */
    val question: SmartQuestionView? = null,
    val scopeOptions: List<SmartScopeOptionView> = emptyList(),
    val canEdit: Boolean = false,
)

/** 智能设置只有一套：画质、洗版、最低要求共用，等待时间电影和剧集各一个 */
@Serializable
data class SmartDefaultsView(
    val configured: Boolean = false,
    val movieRevision: Long = 0,
    val tvRevision: Long = 0,
    val resolution: String = "2160p",
    val source: String = "web-dl",
    val allowUpgrade: Boolean = true,
    val strictResolution: Boolean = false,
    val movieWaitSeconds: Int = 86400,
    val tvWaitSeconds: Int = 10800,
)

@Serializable
data class SmartDefaultsPayload(
    val movieRevision: Long,
    val tvRevision: Long,
    val resolution: String,
    val source: String,
    val allowUpgrade: Boolean,
    val strictResolution: Boolean,
    val movieWaitSeconds: Int,
    val tvWaitSeconds: Int,
)

@Serializable
data class SmartLanguageView(
    val key: String = "",
    val label: String = "",
    val sourceTitle: String? = null,
    val removable: Boolean = true,
)

@Serializable
data class SmartLanguageOptionView(val key: String = "", val label: String = "")

@Serializable
data class SmartHabitView(
    val key: String = "",
    val label: String = "",
    val qualityLabel: String = "",
    val sourceTitle: String? = null,
)

/** 智能订阅记住的东西：看得懂的语言与画质习惯 */
@Serializable
data class SmartMemoryView(
    val revision: Long = 0,
    val languages: List<SmartLanguageView> = emptyList(),
    val addableLanguages: List<SmartLanguageOptionView> = emptyList(),
    val habits: List<SmartHabitView> = emptyList(),
)

/** 设一种语言看不看得懂，或删一条画质习惯（null 字段不发送） */
@Serializable
data class SmartMemoryPatch(
    val revision: Long,
    val language: String? = null,
    val understood: Boolean? = null,
    val removeHabit: String? = null,
)

/** 智能等待的人工操作：立即下载某个候选，或延长等待 */
@Serializable
data class SmartWaitPayload(
    val version: Long,
    val extendSeconds: Int? = null,
    val candidateKey: String? = null,
)

/** 订阅详情：这部作品的字幕要求 */
@Serializable
data class SmartSubtitleView(
    val language: String = "",
    val languageLabel: String = "",
    val line: String = "",
    val understood: Boolean = false,
)

/**
 * `POST /subscriptions` 的返回（**不是** SubscriptionView）。
 * 声明错了会报 `Field 'id' is required for ... SubscriptionView ... at path: $.data`——
 * 服务端这一层的 `data` 是 `{subscription: {...}, download_routing: {...}}`，没有 id。
 */
@Serializable
data class SubscriptionCreateView(
    val subscription: SubscriptionView,
    /** 管理员可见的下载与入库路由预检；成员调用时为空 */
    val downloadRouting: DispatchPreviewView? = null,
)

/**
 * 投递路由预检（`GET /subscriptions/download-routing-preview`，管理员）：
 * 与真实投递同源判定，把"下载完成后能不能进库"在订阅那一刻就回答掉。
 * 字段与服务端 `schemas/subscription.py: DispatchPreviewView` 一一对应。
 */
@Serializable
data class DispatchPreviewView(
    /** watch = 监听导入目录 / inplace = 直接下载进库 / downloader_default = 下载器默认目录 */
    val mode: String = "",
    val path: String? = null,
    /** 条目目录的完整路径预览（按生效的命名模板渲染，前端不要自己拼） */
    val entryDir: String? = null,
    val stagingPath: String? = null,
    /** 解析出的目标库（前端预选用） */
    val libraryId: Long? = null,
    val libraryName: String? = null,
    val downloaderName: String? = null,
    val routeMatched: Boolean? = null,
    /** 路由理由（中文整句，弹窗直接展示：自动选库：…） */
    val routeReason: String? = null,
    val ruleSetId: Long? = null,
    val ruleSetName: String? = null,
    val ruleSetMatched: Boolean? = null,
    val ruleSetReason: String? = null,
    /** 按当前配置投递能否顺利入库 */
    val ok: Boolean = false,
    /** 不 ok 时的中文指引 */
    val warning: String? = null,
)

@Serializable
data class SubscriptionCreateRequest(
    val titleRef: String,
    val sourceTitleRef: String? = null,
    val selectedSeasons: List<Int> = emptyList(),
    val followFuture: Boolean = false,
    val ruleSetId: Long? = null,
    val libraryId: Long? = null,
    /** null = 不发送（旧服务端按规则模式处理） */
    val selectionMode: String? = null,
    val smartProfileRevision: Long? = null,
    val smartLanguageAnswer: String? = null,
    val smartResolution: String? = null,
    val smartSource: String? = null,
    val smartScope: String? = null,
    val smartMemoryRevision: Long? = null,
)

@Serializable
data class ProgressView(
    val total: Int = 0,
    val wanted: Int = 0,
    val grabbed: Int = 0,
    val downloaded: Int = 0,
    val imported: Int = 0,
    val upgrading: Int = 0,
)

/**
 * 一轮洗版的体检报告（`POST /subscriptions/{id}/upgrade-runs`）。
 * `summary` 是**服务端给的中文摘要句**，前端直接展示——不自己拼。
 */
@Serializable
data class UpgradeRunView(
    val targetLabel: String = "",
    val ruleSetId: Long? = null,
    val summary: String = "",
    val counts: Map<String, Int> = emptyMap(),
)

/** `GET /rule-sets`：过滤规则组（订阅换绑用） */
@Serializable
data class RuleSetView(
    val id: Long,
    val name: String = "",
    val isDefault: Boolean = false,
    val referenceCount: Int = 0,
    /** 规则内容（摘要由 `specSummary` 渲染，口径同网页） */
    val spec: kotlinx.serialization.json.JsonObject? = null,
)

@Serializable
data class SubscriptionView(
    val id: Long,
    val media: MediaBrief = MediaBrief(),
    val status: String = "",
    val selectedSeasons: List<Int> = emptyList(),
    val followFuture: Boolean = false,
    val ruleSetId: Long? = null,
    val libraryId: Long? = null,
    val progress: ProgressView = ProgressView(),
    val seasonCollection: List<SeasonOverview> = emptyList(),
    val createdAt: String? = null,
    val updatedAt: String? = null,
    /** 详情接口附带：追踪工单明细（列表接口为空数组） */
    val wanted: List<WantedView> = emptyList(),
    /**
     * 当前观看者能否调整这条订阅（改季、暂停、立即搜索、洗版、手动选种）：
     * 超管与发起人为 true；只关注不发起的成员为 false，只能取消关注
     * （member-permissions-v2；老服务端没有这个字段，缺省 true = 维持原行为）。
     */
    val canManage: Boolean = true,
    /** 资源发布时间预测正在后台刷新（创建 / 调整 / 恢复后的几秒内）；稍后重取即可 */
    val forecastPending: Boolean = false,
    /** smart = 智能选择（rule_set_id 为 0，以本字段为准） */
    val selectionMode: String = "rules",
    val smartPolicy: kotlinx.serialization.json.JsonObject? = null,
    /** invalid_policy / disabled / shadow / active */
    val smartStatus: String? = null,
    /** 详情接口：智能订阅的字幕要求 */
    val smartSubtitle: SmartSubtitleView? = null,
    val smartQualityNote: String? = null,
)

/** `PATCH /subscriptions/{id}/follow-future`：服务端字段名是 `enabled`（以前发 follow_future → 422） */
@Serializable
data class FollowFutureRequest(val enabled: Boolean)

/** POST /subscriptions/title-preview 请求 */
@Serializable
data class TitlePreviewRequest(val titleRef: String)

/** 今日/近期入库条目 */
@Serializable
data class TodayArrival(
    val subscriptionId: Long = 0,
    val mediaTitle: String = "",
    val mediaKind: String = "tv",
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val status: String = "wanted",
    val airDate: String? = null,
    val expectedDay: String? = null,
    val daysAhead: Int = 0,
    val estimatedReleaseToImportMinutes: Int? = null,
)

@Serializable
data class PipelineHealth(
    val status: String = "ok",
    val errorCount: Int = 0,
    val warnCount: Int = 0,
    val downloaderOk: Boolean = false,
    val sitesConfigured: Boolean = false,
    val downloadersConfigured: Boolean = false,
)

/** GET /subscriptions/today-arrivals —— 带媒体美术资源，供订阅首页英雄/日程使用 */
@Serializable
data class TodayArrivalFull(
    val subscriptionId: Long = 0,
    val mediaTitle: String = "",
    val mediaKind: String = "tv",
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val status: String = "wanted",
    val airDate: String? = null,
    val expectedDay: String? = null,
    val daysAhead: Int = 0,
    val grabbedAt: String? = null,
    val downloadedAt: String? = null,
    /** 下载器任务的 info hash：订阅首页据此把实时进度 / ETA 套到这一行上（iOS `taskByHash`） */
    val infoHash: String? = null,
    val estimatedReleaseToImportMinutes: Int? = null,
    val estimatedDownloadToImportMinutes: Int? = null,
    /** 出种预测原始 JSON（服务端 `release_forecast`：predicted_at / confidence）；日程据此判「等待资源」 */
    val releaseForecast: kotlinx.serialization.json.JsonObject? = null,
    /** 下一次有效预测探测时间（ISO）：给不出入库时刻时的兜底文案「HH:mm 探测」 */
    val nextProbeAt: String? = null,
)

/** GET /subscriptions/recent-arrivals —— 订阅首页「刚刚入库」卡片 */
@Serializable
data class RecentArrivalView(
    val subscriptionId: Long = 0,
    val media: MediaBrief = MediaBrief(),
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val episodeName: String? = null,
    val stillUrl: String? = null,
    val units: List<RecentArrivalUnit> = emptyList(),
    val progressPercent: Int? = null,
)

@Serializable
data class RecentArrivalUnit(
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
)

/** 订阅详情的追踪工单（GET /subscriptions/{id} wanted[]） */
@Serializable
data class WantedView(
    val id: Long = 0,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val status: String = "wanted",
    val airDate: String? = null,
    val grabbedAt: String? = null,
    val downloadedAt: String? = null,
    val importedAt: String? = null,
    val lastSearchAt: String? = null,
    val lastRejectReason: String? = null,
    /** 在途工单锚定的种子 hash：据此把单元与实时下载进度组对上（同 iOS `item.infoHash`） */
    val infoHash: String? = null,
    /** 投递的种子名（里程碑链的叙事细节） */
    val grabTitle: String? = null,
    /** 洗版派生状态；规则组未配洗版目标或单元未入库时为 null */
    val upgrade: WantedUpgradeView? = null,
    /** 智能选择的等待状态（reason / deadline / candidate_key …）；规则模式为 null */
    val selectionState: kotlinx.serialization.json.JsonObject? = null,
    val selectionVersion: Long = 0,
)

/** 单元的洗版派生状态（docs/design/quality-upgrade.md §8.3/§9）：标签由后端生成，前端零拼接 */
@Serializable
data class WantedUpgradeView(
    /** 是否洗版中（可证明低于目标且未熔断） */
    val active: Boolean = false,
    val currentLabel: String = "",
    val targetLabel: String = "",
    val searchAttempts: Int = 0,
    /** 无法确认档位：不参与自动洗版，可手动选种替换 */
    val indeterminate: Boolean = false,
)

/** GET /subscriptions/{id}/active-downloads —— 在途种子的实时下载快照（详情页 5 秒轮询） */
@Serializable
data class SubscriptionDownloadView(
    val infoHash: String = "",
    /** 下载器中的任务名；成员拿到的一律为空（服务端置空），missing 时也为空 */
    val name: String? = null,
    /** 0.0~1.0；missing 时为空 */
    val progress: Double? = null,
    val sizeBytes: Long? = null,
    val dlspeedBytes: Long? = null,
    val etaSeconds: Long? = null,
    /** downloading / stalled / paused / completed / error / missing / unknown */
    val state: String = "unknown",
    /** state 为 error 时下载器给出的可读原因；成员拿到的一律为空 */
    val errorMessage: String? = null,
    /** 下载器名；成员拿到的一律为空 */
    val downloaderName: String? = null,
    val units: List<DownloadUnitView> = emptyList(),
)

/** 追踪单元（电影为 0/0）——下载快照与手动选种结果共用 */
@Serializable
data class DownloadUnitView(
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    /** 下载快照里这一集的进度 0..1（挂了多集的包才有；单集种子 / 认不出集号为空，看整包进度） */
    val progress: Double? = null,
)

/** GET /subscriptions/{id}/activities —— 排查记录 */
@Serializable
data class SubActivityView(
    val id: Long = 0,
    val type: String = "",
    val message: String = "",
    val createdAt: String? = null,
)

/** PATCH /subscriptions/{id}/tracking-state */
@Serializable
data class TrackingStateRequest(val state: String)

/**
 * POST /subscriptions/{id}/upgrade-runs 的请求体。
 * 所有客户端都发一个 JSON 对象（哪怕只有空对象）：这个接口的 body 是必填的，
 * 不带体会被 FastAPI 判 422（实机踩过）。
 */
@Serializable
data class UpgradeRunPayload(val ruleSetId: Long? = null)
