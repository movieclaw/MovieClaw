// 由 apps/android-tv/scripts/gen_api.py 生成，勿手改。重新生成见脚本头部说明。
@file:Suppress("unused")

package io.movieclaw.androidtv.core.model.generated

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * 本地刮削（NFO）的一位演员。
 */
@Serializable
data class ActorView(
    @SerialName("name") val name: String = "",
    @SerialName("role") val role: String? = null,
    /**
     * 头像地址（NFO 里的图床 URL）
     */
    @SerialName("thumb_url") val thumbUrl: String? = null,
    /**
     * TMDB 影人 ID；有值时前端把这一格链到人物页
     */
    @SerialName("tmdb_person_id") val tmdbPersonId: Long? = null,
)

@Serializable
data class AudioPlanView(
    @SerialName("action") val action: String = "",
    @SerialName("track_ref") val trackRef: String? = null,
    @SerialName("codec") val codec: String? = null,
    @SerialName("channels") val channels: Long? = null,
    @SerialName("downmix") val downmix: Boolean = false,
)

/**
 * 一条音轨（ffprobe 探测；字段 None=该项探不出）。
 */
@Serializable
data class AudioStreamView(
    @SerialName("codec") val codec: String? = null,
    /**
     * 编码档次（如 DTS-HD MA），比 codec 更贴近用户认知
     */
    @SerialName("profile") val profile: String? = null,
    @SerialName("channels") val channels: Long? = null,
    /**
     * 声道布局（如 5.1(side)）
     */
    @SerialName("channel_layout") val channelLayout: String? = null,
    /**
     * 语言标签（ISO 639，如 chi/eng）
     */
    @SerialName("language") val language: String? = null,
    @SerialName("title") val title: String? = null,
    @SerialName("default") val default: Boolean = false,
)

@Serializable
data class AudioSupportIn(
    @SerialName("codec") val codec: String,
    @SerialName("max_channels") val maxChannels: Long? = null,
)

/**
 * 文件里的一条可选音轨。给播放器渲染音轨菜单用——只有候选列表在手，
 * 前端才能让用户换轨；`audio.track_ref` 说的是「这次放的是哪条」。
 */
@Serializable
data class AudioTrackView(
    @SerialName("ref") val ref: String = "",
    @SerialName("codec") val codec: String? = null,
    @SerialName("channels") val channels: Long? = null,
    @SerialName("language") val language: String? = null,
    @SerialName("is_default") val isDefault: Boolean = false,
)

/**
 * 首次初始化状态：前端据此决定进引导页（/setup）还是登录页（/login）。
 */
@Serializable
data class BootstrapStatus(
    @SerialName("initialized") val initialized: Boolean = false,
)

/**
 * 整库生成章节的作业状态（docs/design/video-chapters.md §4.5）。
 * 章节作业是低优先级后台 Job，点了菜单后常要排在扫描/刷新后面才跑；随库
 * 列表一并返回（见 LibraryView.chapter_job），管理页才能显示"排队中 /
 * 生成到第几个"，用户不必去活动页找。只投影未完成态，跑完即 null。
 */
@Serializable
data class ChapterJobView(
    @SerialName("job_id") val jobId: String = "",
    /**
     * Job 未完成态原词：queued / running / cancelling …
     */
    @SerialName("status") val status: String = "",
    /**
     * 已处理文件数（含失败）
     */
    @SerialName("processed") val processed: Long = 0,
    @SerialName("total") val total: Long = 0,
    /**
     * 生成失败的文件数
     */
    @SerialName("failed") val failed: Long = 0,
    /**
     * 0-100；排队中或分母未知为 null
     */
    @SerialName("percent") val percent: Double? = null,
    /**
     * 已请求停止，正在收尾
     */
    @SerialName("stopping") val stopping: Boolean = false,
)

/**
 * 一个章节（docs/design/video-chapters.md §4.6）：详情页「场景」横排的一张卡。
 */
@Serializable
data class ChapterView(
    /**
     * 章节序号（0 起），与 Jellyfin 章节图路由的 index 同义
     */
    @SerialName("index") val index: Long = 0,
    /**
     * 章节起点（毫秒）
     */
    @SerialName("start_ms") val startMs: Long = 0,
    /**
     * 章节终点（毫秒）；末章无终点时为 null
     */
    @SerialName("end_ms") val endMs: Long? = null,
    /**
     * 场景图上那一帧的真实时间（毫秒）；跳播用它，无图时为 null（退回 start_ms）
     */
    @SerialName("frame_ms") val frameMs: Long? = null,
    /**
     * 章节标题；合成章节与无名章节为 null
     */
    @SerialName("title") val title: String? = null,
    /**
     * 是否按时长合成（容器里没有内嵌章节）
     */
    @SerialName("synthetic") val synthetic: Boolean = false,
    /**
     * 场景图地址（本地资产相对路径）；未生成为 null
     */
    @SerialName("image_url") val imageUrl: String? = null,
)

/**
 * 客户端解码能力快照。前端探测后随决策请求上送，并缓存在 localStorage。
 */
@Serializable
data class ClientCapabilityIn(
    @SerialName("video") val video: List<VideoSupportIn>? = null,
    @SerialName("audio") val audio: List<AudioSupportIn>? = null,
    @SerialName("containers") val containers: List<String>? = null,
    @SerialName("hdr_passthrough") val hdrPassthrough: Boolean? = null,
    @SerialName("mse") val mse: String? = null,
    @SerialName("is_mobile") val isMobile: Boolean? = null,
    @SerialName("native_hls") val nativeHls: Boolean? = null,
    @SerialName("universal") val universal: Boolean? = null,
    @SerialName("disc_image") val discImage: Boolean? = null,
    @SerialName("disc_folder") val discFolder: Boolean? = null,
    @SerialName("local_tracks") val localTracks: Boolean? = null,
    @SerialName("dolby_vision_profiles") val dolbyVisionProfiles: List<Long>? = null,
    @SerialName("dolby_vision_base_layer_profiles") val dolbyVisionBaseLayerProfiles: List<Long>? = null,
)

/**
 * 合集卡片的一张封面图。
 * 合集自己没有图，封面就是成员的海报。由服务端在列合集时一并给出——否则
 * 客户端要为每个合集再请求一次成员才画得出卡片，一屏合集就是一屏请求。
 */
@Serializable
data class CollectionCover(
    @SerialName("url") val url: String = "",
    @SerialName("blur") val blur: String? = null,
)

/**
 * 系列合集的「已有 N / 共 M」与缺片名单（docs/design/library-series-collections.md 6.5）。
 * 只在合集详情页展示，**不上卡片**——一屏几十个红色角标是压迫感不是帮助。
 */
@Serializable
data class CollectionSeriesView(
    @SerialName("series_name") val seriesName: String? = null,
    /**
     * 库里已有几部
     */
    @SerialName("owned_count") val ownedCount: Long = 0,
    /**
     * 这个系列一共几部（TMDB 档案）
     */
    @SerialName("total") val total: Long = 0,
    /**
     * 系列官方海报
     */
    @SerialName("image_url") val imageUrl: String? = null,
    @SerialName("parts") val parts: List<SeriesPartView> = emptyList(),
    /**
     * 拉到上游档案了吗；false=没配 TMDB / 网络不通 / 本地系列没有上游档案
     */
    @SerialName("available") val available: Boolean = false,
)

/**
 * 一个合集。形态（规则驱动 / 名单驱动、可不可改）是**推导**出来的，不是存的。
 */
@Serializable
data class CollectionView(
    @SerialName("id") val id: Long = 0,
    @SerialName("name") val name: String = "",
    /**
     * 所属库；null=跨库合集
     */
    @SerialName("library_id") val libraryId: Long? = null,
    /**
     * 收录规则，与 library.match_rules 同构
     */
    @SerialName("rules") val rules: List<JsonElement> = emptyList(),
    /**
     * 合集内默认排序
     */
    @SerialName("sort") val sort: String = "",
    /**
     * household=全家可见 / private=只有我
     */
    @SerialName("visibility") val visibility: String = "",
    /**
     * 内置合集标识；null=用户创建
     */
    @SerialName("builtin") val builtin: String? = null,
    /**
     * 当前观看者能不能改规则与名单（用户创建的合集，且 manageable 为真）
     */
    @SerialName("editable") val editable: Boolean = false,
    /**
     * 当前观看者能不能管理这个合集（改名、排序、可见性、隐藏、删除）：超管恒为真；成员只能管理自己的私有合集与自己建的全家合集
     */
    @SerialName("manageable") val manageable: Boolean = false,
    /**
     * 规则驱动（会自己长）还是名单驱动（固定）
     */
    @SerialName("rule_driven") val ruleDriven: Boolean = false,
    /**
     * 当前可见成员数
     */
    @SerialName("item_count") val itemCount: Long = 0,
    /**
     * 封面取哪部作品；null=取首个成员
     */
    @SerialName("cover_item_id") val coverItemId: Long? = null,
    /**
     * 封面素材（前若干个成员的海报）；由服务端取，客户端不必为每个合集再请求一次成员
     */
    @SerialName("covers") val covers: List<CollectionCover> = emptyList(),
    /**
     * 合集从哪来：user=用户自建 / builtin=内置 / series=按作品系列自动生成
     */
    @SerialName("kind") val kind: String = "",
    /**
     * 已隐藏（自动合集的「删除」落成墓碑）
     */
    @SerialName("hidden") val hidden: Boolean = false,
    @SerialName("position") val position: Long = 0,
)

/**
 * 客户端发起接入请求。
 * 刻意**没有权限字段**：客户端只声明自己是什么形态、叫什么名字，
 * 能做什么由批准者决定。
 */
@Serializable
data class DeviceAuthorizeRequest(
    /**
     * 客户端形态：worker（转码 Worker）、cli（命令行 / Agent）、tvos（Apple TV App）、macos（Mac App）、androidtv（Android TV App）
     */
    @SerialName("client_type") val clientType: String,
    /**
     * 设备名，批准页上给人看的，如 'Yi的Mac-mini'
     */
    @SerialName("client_name") val clientName: String,
    /**
     * 客户端安装标识：同一台机器重新配对时替换旧凭证，而不是越积越多
     */
    @SerialName("installation_id") val installationId: String? = null,
    /**
     * 系统与架构，如 'macOS 26.0 · arm64'
     */
    @SerialName("platform") val platform: String? = null,
    /**
     * 客户端版本
     */
    @SerialName("client_version") val clientVersion: String? = null,
)

/**
 * 接入请求的回执。``user_code`` 给人看，``device_code`` 用于兑换。
 */
@Serializable
data class DeviceAuthorizeView(
    /**
     * 配对码，客户端显示给用户，在网页上核对
     */
    @SerialName("user_code") val userCode: String = "",
    /**
     * 兑换凭据，仅客户端持有，不得展示给用户
     */
    @SerialName("device_code") val deviceCode: String = "",
    /**
     * 批准页地址（不带配对码，用户需手动输入）
     */
    @SerialName("verification_uri") val verificationUri: String = "",
    /**
     * 带配对码的批准页地址：打开即显示这一条请求，客户端应优先打开它
     */
    @SerialName("verification_uri_complete") val verificationUriComplete: String = "",
    /**
     * 建议的轮询间隔（秒），不要比这更快
     */
    @SerialName("interval") val interval: Long = 0,
    /**
     * 配对码有效期（秒），超时需重新发起
     */
    @SerialName("expires_in") val expiresIn: Long = 0,
)

/**
 * 当前请求所用的登录设备（「当前设备」标记、``mclaw status`` 回显用）。
 */
@Serializable
data class DeviceBrief(
    @SerialName("id") val id: String = "",
    /**
     * web / ios / tvos / macos / android / cli / worker / manual
     */
    @SerialName("kind") val kind: String = "",
    @SerialName("name") val name: String = "",
)

/**
 * 原生 App 登录时自报的设备信息。
 */
@Serializable
data class DeviceClientInfo(
    /**
     * App 平台
     */
    @SerialName("kind") val kind: String,
    /**
     * App 安装标识（存在系统钥匙串）：同一台设备同一个人重新登录时替换旧凭证
     */
    @SerialName("installation_id") val installationId: String,
    /**
     * 设备名，如 'iPhone Air'；用户之后可改名
     */
    @SerialName("name") val name: String? = null,
    /**
     * 系统与机型，如 'iOS 26.0 · iPhone18,4'
     */
    @SerialName("platform") val platform: String? = null,
    /**
     * App 版本
     */
    @SerialName("client_version") val clientVersion: String? = null,
)

/**
 * 原生 App 用账号密码登录，换一枚设备令牌。
 */
@Serializable
data class DeviceLoginRequest(
    @SerialName("username") val username: String,
    @SerialName("password") val password: String,
    @SerialName("client") val client: DeviceClientInfo,
)

/**
 * App 登录成功：设备令牌（明文仅此一次）+ 这台设备 + 当前身份。
 */
@Serializable
data class DeviceLoginView(
    /**
     * 设备令牌明文；存进系统钥匙串，服务端只存哈希
     */
    @SerialName("token") val token: String = "",
    @SerialName("device") val device: LoginDeviceView = LoginDeviceView(),
    @SerialName("session") val session: SessionView = SessionView(),
)

/**
 * App 设备能不能收到推送（docs/design/cloud-push.md §4）。界面只在不是 ok 时提示。
 */
@Serializable
data class DevicePushView(
    /**
     * ok / permission_denied / no_channel / bad_token / not_registered
     */
    @SerialName("status") val status: String = "",
    @SerialName("status_text") val statusText: String = "",
)

/**
 * 客户端轮询兑换令牌。
 */
@Serializable
data class DeviceTokenRequest(
    @SerialName("device_code") val deviceCode: String,
)

/**
 * 兑换成功的返回体：令牌明文仅此一次。
 */
@Serializable
data class DeviceTokenView(
    /**
     * 令牌明文；服务端只存哈希，之后无法再次查看
     */
    @SerialName("token") val token: String = "",
    @SerialName("client_name") val clientName: String = "",
    @SerialName("client_type") val clientType: String = "",
    /**
     * 批准者的用户名：这枚令牌就是他的身份
     */
    @SerialName("granted_by") val grantedBy: String = "",
)

/**
 * 库内人物关系表中的一位导演。
 */
@Serializable
data class DirectorView(
    @SerialName("name") val name: String = "",
    /**
     * 头像地址（TMDB 图床 URL）
     */
    @SerialName("thumb_url") val thumbUrl: String? = null,
    /**
     * TMDB 影人 ID；用于人物页链接
     */
    @SerialName("tmdb_person_id") val tmdbPersonId: Long = 0,
)

/**
 * 剧集分集区的一集：季集结构 + 本地分集刮削 + TMDB 兜底的合并结果。
 */
@Serializable
data class EpisodeView(
    @SerialName("episode_number") val episodeNumber: Long = 0,
    @SerialName("name") val name: String? = null,
    /**
     * 分集简介
     */
    @SerialName("overview") val overview: String? = null,
    @SerialName("air_date") val airDate: String? = null,
    /**
     * 分集剧照：本地缩略图接口相对路径或 TMDB 图床地址；无为 null
     */
    @SerialName("still_url") val stillUrl: String? = null,
    /**
     * 该集有在位文件；false=缺集或文件缺失（前端置灰）
     */
    @SerialName("owned") val owned: Boolean = false,
    /**
     * 该集的台账文件 id
     */
    @SerialName("file_ids") val fileIds: List<Long> = emptyList(),
    /**
     * 当前观看者上次看到的位置（毫秒）
     */
    @SerialName("position_ms") val positionMs: Long = 0,
    /**
     * 当前观看者已看完该集
     */
    @SerialName("played") val played: Boolean = false,
    /**
     * 观看进度 1~99；已看完由 played 表达，不给百分比
     */
    @SerialName("progress_percent") val progressPercent: Long? = null,
)

/**
 * 筛选面板里的一个候选值（docs/design/library-filtering.md 3.3）。
 */
@Serializable
data class FacetValueView(
    /**
     * 取值（类型是 TMDB genre id、地区是国家码、年代是档名）
     */
    @SerialName("value") val value: String = "",
    /**
     * 展示名（类型/地区走内置映射表，未知取值原样显示）
     */
    @SerialName("label") val label: String = "",
    /**
     * 在**其他维度**已选条件下勾上本值还剩几部——算本维时排除本维自身的条件，否则勾了「动画」之后其他类型全变 0，多选就废了
     */
    @SerialName("count") val count: Long = 0,
)

/**
 * 首页「我的收藏」的一格：单库海报墙的条目视图 + 收藏上下文。
 * 收藏层级来自最近一次收藏的那一行：整剧两者皆 null，整季只有季号，
 * 单集季集都有；电影恒为 null（内部 (0,0) 哨兵不外泄）。
 */
@Serializable
data class FavoriteItemView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    @SerialName("kind") val kind: MediaKind = "",
    /**
     * 卡片的详情落点库（同一作品跨库时取首页顺序第一个可见库）
     */
    @SerialName("library_id") val libraryId: Long = 0,
    /**
     * 身份来源：tmdb / local（local=未识别或其他库）
     */
    @SerialName("source") val source: String = "",
    /**
     * TMDB 条目 ID；本地来源条目为 null
     */
    @SerialName("tmdb_id") val tmdbId: Long? = null,
    @SerialName("title") val title: String = "",
    @SerialName("year") val year: Long? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
    @SerialName("backdrop_url") val backdropUrl: String? = null,
    /**
     * 主图宽高比（真实像素尺寸或来源惯例），卡片按它排版
     */
    @SerialName("primary_aspect") val primaryAspect: Double = 0.0,
    /**
     * 内容日期：影视为上映/首播日，本地条目为拍摄/录制日（图片库按月分组与悬停日期用）
     */
    @SerialName("release_date") val releaseDate: String? = null,
    /**
     * 评分（0~10，TMDB 或 NFO）；海报墙默认不印，悬停层与按评分排序/筛选时才显示
     */
    @SerialName("rating") val rating: Double? = null,
    /**
     * 主图的微缩占位图 data URI（约 300 字节）：缩略图到达前铺一层模糊色块
     */
    @SerialName("poster_blur") val posterBlur: String? = null,
    /**
     * 条目的首个在位文件 id（一文件一条目的库用它取原图；多文件条目取最早入账的）
     */
    @SerialName("primary_file_id") val primaryFileId: Long? = null,
    @SerialName("file_count") val fileCount: Long = 0,
    @SerialName("total_size_bytes") val totalSizeBytes: Long = 0,
    @SerialName("seasons") val seasons: List<Long> = emptyList(),
    @SerialName("episode_count") val episodeCount: Long = 0,
    @SerialName("resolutions") val resolutions: List<String> = emptyList(),
    /**
     * 标记 missing 的文件数（>0 时前端提示）
     */
    @SerialName("missing_count") val missingCount: Long = 0,
    /**
     * 剧集播出状态：airing=在播 / ended=完结；电影或状态未知为 NULL
     */
    @SerialName("air_status") val airStatus: String? = null,
    /**
     * 已播出但所有媒体库里都没有的正季集数（电影恒 0）——「补齐缺集」的依据
     */
    @SerialName("missing_episode_count") val missingEpisodeCount: Long = 0,
    /**
     * 最近一次文件入账时间（首页「最近添加」排序依据）
     */
    @SerialName("added_at") val addedAt: String? = null,
    /**
     * 当前观看者是否收藏了这部作品（海报右上角那颗心）；不认人的调用恒 False
     */
    @SerialName("is_favorite") val isFavorite: Boolean = false,
    /**
     * 最近一次可追溯入库批次的剧集摘要；NULL=电影或迁移前旧台账
     */
    @SerialName("recent_addition") val recentAddition: LibraryRecentAdditionView? = null,
    /**
     * 本库在位剧集相对 TMDB 季集结构的完整度摘要；电影或无有效集号为 NULL
     */
    @SerialName("inventory_summary") val inventorySummary: LibraryInventorySummaryView? = null,
    /**
     * 在位但尚未探出介质规格的文件数——扫描补探阶段前端据此把「还在处理」的条目排到海报墙前面并点亮标记
     */
    @SerialName("probe_pending_count") val probePendingCount: Long = 0,
    @SerialName("favorite_season_number") val favoriteSeasonNumber: Long? = null,
    @SerialName("favorite_episode_number") val favoriteEpisodeNumber: Long? = null,
)

/**
 * 「我的收藏」分区的数据载荷。``total`` 是去重后的收藏作品总数，
 * ``items`` 受 limit 截断——前端据此决定要不要给「展开全部」。
 */
@Serializable
data class FavoritesView(
    @SerialName("items") val items: List<FavoriteItemView> = emptyList(),
    @SerialName("total") val total: Long = 0,
)

/**
 * 文件来源快照（docs/design/library-duplicate-files.md §2）：这个文件是怎么进库的。
 */
@Serializable
data class FileOriginView(
    /**
     * subscription / manual_download / watch_import / scan
     */
    @SerialName("kind") val kind: String = "",
    /**
     * 一句话：订阅《九门》自动投递 / 手动下载 / 监听目录自动识别入库 / 存量扫描发现
     */
    @SerialName("label") val label: String = "",
    /**
     * 第二行：站点 · 种子标题 · 下载器 · 搬运方式
     */
    @SerialName("detail") val detail: String? = null,
)

@Serializable
data class HealthResponse(
    @SerialName("status") val status: String = "",
    @SerialName("service") val service: String = "",
    @SerialName("environment") val environment: String = "",
    @SerialName("spec_hash") val specHash: String = "",
    @SerialName("version") val version: String? = null,
)

/**
 * 媒体库首页的一「行」：来源 × 排序 × 名字（docs/design/library-home-perspective.md）。
 * - 内置行（``up-next`` / ``favorites`` / ``libraries`` / ``genres:movie|tv``）只存
 * ``hidden``，收藏行多一个 ``sort``；来源与名字由前端决定，这里不存。
 * ``genres:*`` 是「按类型找电影 / 剧集」色块区：每个 TMDB 类型一格，点进去是
 * 按该类型筛好的跨库墙；
 * - 默认库行 ``lib:<library_id>`` 每库一条，能藏、能改排序和名字，不能删；
 * - 默认类型行 ``kind:movie|tv|video`` 每类一条（跨库聚合同类型的全部可见库，
 * §8），能力与默认库行相同；
 * - 自加行 ``row:<slug>`` 必须且只能带 ``library_id`` / ``collection_id`` /
 * ``media_kind`` 之一。
 * 除 ``id`` 外全部可空：空即默认（排序用预设、名字跟随推荐、不隐藏）。
 * 坏形状在 PUT 时就拒掉，读取端不再兜底——与 ``NavUiPrefs`` 一样，存下来的
 * 只是提示：指向已删库 / 不可见合集的行由前端合并时静默丢弃。
 */
@Serializable
data class HomeRowPref(
    /**
     * 行 id，见类注释的几种形状
     */
    @SerialName("id") val id: String = "",
    /**
     * 排序档；空 = 该行的默认排序
     */
    @SerialName("sort") val sort: String? = null,
    /**
     * 排序方向 asc / desc；空 = 该档的自然方向。前端只在反转自然方向时才存它
     */
    @SerialName("order") val order: String? = null,
    /**
     * 用户起的名字；空 = 跟随推荐
     */
    @SerialName("name") val name: String? = null,
    /**
     * 只显示没看过的（仅库行与类型行）
     */
    @SerialName("unwatched") val unwatched: Boolean? = null,
    /**
     * 隐藏这一行，位置保留
     */
    @SerialName("hidden") val hidden: Boolean? = null,
    /**
     * 自加库行的来源库
     */
    @SerialName("library_id") val libraryId: Long? = null,
    /**
     * 合集行的来源合集
     */
    @SerialName("collection_id") val collectionId: Long? = null,
    /**
     * 自加类型行的来源类型（跨库聚合该类型的全部可见库）
     */
    @SerialName("media_kind") val mediaKind: String? = null,
)

/**
 * 媒体库首页的行清单（每个成员一份，超管走全局域）。
 * 空列表 = 出厂布局；合并规则（存过的按存的顺序、没存过的内置行与每库默认行追加
 * 在后、认不出的 id 忽略）在前端 ``lib/home-rows.ts``。
 * 上限 128 只是防脏数据的安全阀：自定义页会把合并后的整份清单存回来（三个内置行 +
 * 每个可见库一条 + 自加的行），上限必须留得比"家里有很多库"大得多。
 */
@Serializable
data class HomeUiPrefs(
    /**
     * 首页的行，按显示顺序；空 = 出厂布局
     */
    @SerialName("rows") val rows: List<HomeRowPref> = emptyList(),
)

/**
 * 作品详情页那一行「合集」的一项：只要名字和落点。
 * **刻意不带封面与成员数**。合集封面是从成员海报里借的——在《千与千寻》
 * 的页面上摆「日本动画」的封面卡，那张图很可能就是《千与千寻》自己；
 * 而成员数属于合集卡片，这一行回答的是"它在哪儿"，不是"那儿有多大"。
 */
@Serializable
data class ItemCollectionRef(
    @SerialName("id") val id: Long = 0,
    @SerialName("name") val name: String = "",
)

/**
 * 最近一次整理的结论——给用户"整理完成了什么"的反馈。
 */
@Serializable
data class LastOrganizeView(
    @SerialName("finished_at") val finishedAt: String = "",
    /**
     * 改名归位的主文件数
     */
    @SerialName("renamed") val renamed: Long = 0,
    /**
     * 跟随改名的附属文件数（字幕、分集剧照等）
     */
    @SerialName("sidecars_renamed") val sidecarsRenamed: Long = 0,
    /**
     * 跟随条目目录改名的镜像资产数（海报/背景/Logo/季海报/条目 NFO）
     */
    @SerialName("entry_assets_moved") val entryAssetsMoved: Long = 0,
    /**
     * 本就符合规范、无需动作的文件数
     */
    @SerialName("already_ok") val alreadyOk: Long = 0,
    /**
     * 计划阶段跳过的文件数（原因见预览）
     */
    @SerialName("skipped") val skipped: Long = 0,
    /**
     * 搬空后清理掉的目录数
     */
    @SerialName("removed_dirs") val removedDirs: Long = 0,
    @SerialName("errors") val errors: List<String> = emptyList(),
)

/**
 * 最近一次扫描的结论——扫描常毫秒级结束，前端靠它给用户"点了有反应"的反馈。
 */
@Serializable
data class LastScanView(
    @SerialName("finished_at") val finishedAt: String = "",
    /**
     * 本轮新入账文件数
     */
    @SerialName("scanned") val scanned: Long = 0,
    @SerialName("identified") val identified: Long = 0,
    @SerialName("unidentified") val unidentified: Long = 0,
    /**
     * 本轮标记丢失的文件数
     */
    @SerialName("marked_missing") val markedMissing: Long = 0,
    /**
     * 本轮自动清理出台账的丢失记录数（库开了自动清理才非 0）
     */
    @SerialName("cleared_missing") val clearedMissing: Long = 0,
    /**
     * 本轮因已移除根路径而标记缺失的旧台账数
     */
    @SerialName("removed_root_marked_missing") val removedRootMarkedMissing: Long = 0,
    /**
     * 本轮因已移除根路径而自动清理的旧台账数
     */
    @SerialName("removed_root_cleared") val removedRootCleared: Long = 0,
    /**
     * 本轮已移除根路径台账的身份冲突数（需人工处理）
     */
    @SerialName("removed_root_conflicts") val removedRootConflicts: Long = 0,
    /**
     * 疑似写入中暂缓入账的文件数（稍后自动补扫）
     */
    @SerialName("deferred") val deferred: Long = 0,
    /**
     * 识别重试数：在位但待识别的文件重走识别链（不算新入账）
     */
    @SerialName("retried") val retried: Long = 0,
    /**
     * 本轮扫描被用户手动停止（未扫完）
     */
    @SerialName("cancelled") val cancelled: Boolean = false,
    @SerialName("errors") val errors: List<String> = emptyList(),
)

/**
 * 库的能力位（docs/design/library-other-kind.md 3.1）：前端按位显隐功能，
 * 不按 kind 字面分叉——新增类型/来源时前端零改动。
 */
@Serializable
data class LibraryCapabilitiesView(
    /**
     * 有外部刮削链（识别/刷新元数据/选图/待识别清单）
     */
    @SerialName("scraped") val scraped: Boolean = false,
    /**
     * 有季集结构（分集区、缺集统计）
     */
    @SerialName("episodic") val episodic: Boolean = false,
    /**
     * 有规范命名（整理功能）
     */
    @SerialName("naming") val naming: Boolean = false,
    /**
     * 可作为订阅入库目标
     */
    @SerialName("subscribable") val subscribable: Boolean = false,
    /**
     * 向媒体目录写 NFO/图片镜像
     */
    @SerialName("write_nfo") val writeNfo: Boolean = false,
    /**
     * 卡片主图默认宽高比（无真实尺寸时）
     */
    @SerialName("default_aspect") val defaultAspect: Double = 0.0,
    /**
     * Jellyfin 视图类型：movies / tvshows / homevideos / photos
     */
    @SerialName("jellyfin_collection") val jellyfinCollection: String = "",
    /**
     * 条目可播放；假 = 只可查看（图片库：点击开灯箱而非播放器）
     */
    @SerialName("playable") val playable: Boolean = false,
)

/**
 * 一次筛选下的全部候选值与计数。
 * 与 /items 共用同一组筛选参数，因此两者口径天然一致：面板上显示多少部，
 * 点下去墙上就是多少部。为 0 的候选值仍然返回（前端置灰不可点），
 * 这是"永不空货架"的第一道闸。
 */
@Serializable
data class LibraryFacetsView(
    /**
     * 当前条件下的命中总数
     */
    @SerialName("total") val total: Long = 0,
    /**
     * 类型，按数量倒序
     */
    @SerialName("genres") val genres: List<FacetValueView> = emptyList(),
    /**
     * 地区，按数量倒序
     */
    @SerialName("countries") val countries: List<FacetValueView> = emptyList(),
    /**
     * 年代，按时间倒序
     */
    @SerialName("decades") val decades: List<FacetValueView> = emptyList(),
    /**
     * 观看状态：未看/在看/已看完是一个划分，另加我收藏的
     */
    @SerialName("watch") val watch: List<FacetValueView> = emptyList(),
    /**
     * 评分档（找片）
     */
    @SerialName("ratings") val ratings: List<FacetValueView> = emptyList(),
    /**
     * 片长档（找片）
     */
    @SerialName("runtimes") val runtimes: List<FacetValueView> = emptyList(),
    /**
     * 原始语言（找片）
     */
    @SerialName("languages") val languages: List<FacetValueView> = emptyList(),
    /**
     * 分辨率（查库）
     */
    @SerialName("resolutions") val resolutions: List<FacetValueView> = emptyList(),
    /**
     * 动态范围（查库）
     */
    @SerialName("hdr") val hdr: List<FacetValueView> = emptyList(),
    /**
     * 库存状态（查库）
     */
    @SerialName("stock") val stock: List<FacetValueView> = emptyList(),
)

/**
 * 条目详情页的一个物理文件（一个版本 / 一集）。
 */
@Serializable
data class LibraryFileView(
    @SerialName("id") val id: Long = 0,
    @SerialName("file_path") val filePath: String = "",
    @SerialName("file_name") val fileName: String = "",
    @SerialName("size_bytes") val sizeBytes: Long = 0,
    @SerialName("container") val container: String? = null,
    @SerialName("resolution") val resolution: String? = null,
    @SerialName("video_codec") val videoCodec: String? = null,
    @SerialName("hdr") val hdr: String? = null,
    @SerialName("bit_depth") val bitDepth: Long? = null,
    @SerialName("duration_seconds") val durationSeconds: Long? = null,
    @SerialName("bit_rate") val bitRate: Long? = null,
    @SerialName("frame_rate") val frameRate: Double? = null,
    @SerialName("color_space") val colorSpace: String? = null,
    @SerialName("media_source") val mediaSource: String? = null,
    /**
     * 片源为人工标注（含 user-lowest 哨兵）
     */
    @SerialName("media_source_manual") val mediaSourceManual: Boolean = false,
    @SerialName("release_group") val releaseGroup: String? = null,
    /**
     * imported（入库管线）/ scanned（存量扫描）
     */
    @SerialName("source") val source: String = "",
    @SerialName("season_number") val seasonNumber: Long = 0,
    @SerialName("episode_number") val episodeNumber: Long = 0,
    /**
     * 文件当前不在磁盘（missing 标记）
     */
    @SerialName("missing") val missing: Boolean = false,
    /**
     * 生命周期：in_place 在位 / missing 缺失 / trashed 待回收
     */
    @SerialName("state") val state: String = "",
    /**
     * 待回收的预计自动清理时间；null = 不自动删（2026-08-17 之前的旧数据）
     */
    @SerialName("purge_after") val purgeAfter: String? = null,
    /**
     * 待回收原因（中文整句，含触发方），文件区直接展示
     */
    @SerialName("trash_note") val trashNote: String? = null,
    /**
     * 来源快照：这个文件是怎么进库的
     */
    @SerialName("origin") val origin: FileOriginView = FileOriginView(),
    /**
     * 用户在重复文件页点过「都留着」的时间；null=未标记
     */
    @SerialName("kept_at") val keptAt: String? = null,
    /**
     * 音轨列表；null=尚未探测（ffprobe 缺失或文件不可达）
     */
    @SerialName("audio_streams") val audioStreams: List<AudioStreamView>? = null,
    /**
     * 字幕列表：内封轨 + 外挂文件
     */
    @SerialName("subtitle_streams") val subtitleStreams: List<SubtitleStreamView> = emptyList(),
    /**
     * 当前成员起播时会放的音轨 / 字幕与原因；null = 原盘或尚未探测轨道（界面退回按片源标注的默认旗标展示）
     */
    @SerialName("playback_defaults") val playbackDefaults: TrackDefaultsView? = null,
    /**
     * 有效章节列表（内嵌或按时长合成）；null=所在库未开启「生成章节」或尚未探测
     */
    @SerialName("chapters") val chapters: List<ChapterView>? = null,
    @SerialName("added_at") val addedAt: String = "",
)

/**
 * 剧集库海报 hover 的在位库存完整度摘要。
 */
@Serializable
data class LibraryInventorySummaryView(
    /**
     * 在位正季数；仅特别篇时为 0
     */
    @SerialName("season_count") val seasonCount: Long = 0,
    /**
     * 摘要覆盖的在位去重集数
     */
    @SerialName("episode_count") val episodeCount: Long = 0,
    /**
     * 只覆盖一季时的季号（0=特别篇）；多季为 NULL
     */
    @SerialName("season_number") val seasonNumber: Long? = null,
    /**
     * 摘要所覆盖季的 TMDB 已知总集数；任一季未知时为 NULL
     */
    @SerialName("total_episode_count") val totalEpisodeCount: Long? = null,
    /**
     * 是否覆盖 TMDB 已知的全部正季
     */
    @SerialName("all_seasons_owned") val allSeasonsOwned: Boolean = false,
    /**
     * 摘要所覆盖的每一季是否都已收齐
     */
    @SerialName("all_episodes_owned") val allEpisodesOwned: Boolean = false,
)

/**
 * 条目详情页的完整数据：基本信息 + 本地刮削元数据 + 逐文件真实规格。
 * 图片优先级：条目目录里的本地美术图（poster.jpg/fanart.jpg，走
 * /libraries/.../artwork 接口的相对路径）优先，其次 TMDB 图床绝对地址
 * ——前端按"是否 http 开头"区分两种加载方式。
 */
@Serializable
data class LibraryItemDetailView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    @SerialName("kind") val kind: MediaKind = "",
    /**
     * 身份来源：tmdb / local（local=未识别或其他库）
     */
    @SerialName("source") val source: String = "",
    /**
     * TMDB 条目 ID；本地来源条目为 null
     */
    @SerialName("tmdb_id") val tmdbId: Long? = null,
    @SerialName("imdb_id") val imdbId: String? = null,
    @SerialName("douban_id") val doubanId: String? = null,
    @SerialName("title") val title: String = "",
    @SerialName("original_title") val originalTitle: String = "",
    /**
     * 国际英文名；「搜索资源」与中文名、原名一起搜
     */
    @SerialName("english_title") val englishTitle: String? = null,
    @SerialName("year") val year: Long? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
    @SerialName("backdrop_url") val backdropUrl: String? = null,
    /**
     * 片名 Logo（透明底 PNG）；没有时前端显示文字片名
     */
    @SerialName("logo_url") val logoUrl: String? = null,
    /**
     * 主图宽高比（同海报墙）
     */
    @SerialName("primary_aspect") val primaryAspect: Double = 0.0,
    /**
     * NFO 本地刮削元数据；目录里没有可用 NFO 时为 null
     */
    @SerialName("local_meta") val localMeta: LocalMetaView? = null,
    /**
     * 条目在磁盘上的目录（删除确认时展示）
     */
    @SerialName("entry_dirs") val entryDirs: List<String> = emptyList(),
    @SerialName("files") val files: List<LibraryFileView> = emptyList(),
    @SerialName("file_count") val fileCount: Long = 0,
    @SerialName("total_size_bytes") val totalSizeBytes: Long = 0,
    /**
     * 季号列表（电影为空）
     */
    @SerialName("seasons") val seasons: List<Long> = emptyList(),
    /**
     * 该条目正在后台刮削元数据
     */
    @SerialName("scraping") val scraping: Boolean = false,
    /**
     * 刮削当前阶段；没在刮为 null
     */
    @SerialName("scraping_phase") val scrapingPhase: String? = null,
    /**
     * 章节场景图正在后台生成
     */
    @SerialName("chapters_pending") val chaptersPending: Boolean = false,
    /**
     * 所属作品系列名；不属于任何系列为 null
     */
    @SerialName("series_name") val seriesName: String? = null,
    /**
     * 所属系列合集的 id；本库没生成该合集时为 null
     */
    @SerialName("series_collection_id") val seriesCollectionId: Long? = null,
    /**
     * 这部片所属的合集（不含系列与「我的收藏」）
     */
    @SerialName("collections") val collections: List<ItemCollectionRef> = emptyList(),
)

/**
 * 海报行「选中展开」要的展示信息（电视首页，同 Netflix 电视版的焦点卡）。
 * 海报墙列表（``LibraryItemView``）只带画格子要的字段；焦点停在某张海报上时，
 * 它展开成横版剧照卡、下面写类型 / 时长 / 分级与两行简介——这些字段一行二十部
 * 整批取一次，不逐张拉详情（详情带全部文件清单，一部剧上百集）。
 */
@Serializable
data class LibraryItemShowcaseView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    /**
     * 横版剧照：本地资产优先，回落 TMDB w1280（展开卡约 800 点宽，4K 下 1600px，列表那张 w780 发虚）
     */
    @SerialName("backdrop_url") val backdropUrl: String? = null,
    /**
     * 片名 Logo（透明底 PNG）；没有时前端写文字片名
     */
    @SerialName("logo_url") val logoUrl: String? = null,
    /**
     * 简介（前端最多显示两行）
     */
    @SerialName("overview") val overview: String? = null,
    /**
     * 类型（前端取前两个）
     */
    @SerialName("genres") val genres: List<String> = emptyList(),
    /**
     * 片长（电影用；剧集为单集时长，前端不显示）
     */
    @SerialName("runtime_minutes") val runtimeMinutes: Long? = null,
    /**
     * 分级（优先 CN，无则 US）
     */
    @SerialName("content_rating") val contentRating: String? = null,
)

/**
 * 库内一个媒体条目的库存聚合（单库海报墙的一格）。
 */
@Serializable
data class LibraryItemView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    @SerialName("kind") val kind: MediaKind = "",
    /**
     * 所属库；单库墙上恒为该库
     */
    @SerialName("library_id") val libraryId: Long? = null,
    /**
     * 身份来源：tmdb / local（local=未识别或其他库）
     */
    @SerialName("source") val source: String = "",
    /**
     * TMDB 条目 ID；本地来源条目为 null
     */
    @SerialName("tmdb_id") val tmdbId: Long? = null,
    @SerialName("title") val title: String = "",
    @SerialName("year") val year: Long? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
    @SerialName("backdrop_url") val backdropUrl: String? = null,
    /**
     * 主图宽高比（真实像素尺寸或来源惯例），卡片按它排版
     */
    @SerialName("primary_aspect") val primaryAspect: Double = 0.0,
    /**
     * 内容日期：影视为上映/首播日，本地条目为拍摄/录制日（图片库按月分组与悬停日期用）
     */
    @SerialName("release_date") val releaseDate: String? = null,
    /**
     * 评分（0~10，TMDB 或 NFO）；海报墙默认不印，悬停层与按评分排序/筛选时才显示
     */
    @SerialName("rating") val rating: Double? = null,
    /**
     * 主图的微缩占位图 data URI（约 300 字节）：缩略图到达前铺一层模糊色块
     */
    @SerialName("poster_blur") val posterBlur: String? = null,
    /**
     * 条目的首个在位文件 id（一文件一条目的库用它取原图；多文件条目取最早入账的）
     */
    @SerialName("primary_file_id") val primaryFileId: Long? = null,
    @SerialName("file_count") val fileCount: Long = 0,
    @SerialName("total_size_bytes") val totalSizeBytes: Long = 0,
    @SerialName("seasons") val seasons: List<Long> = emptyList(),
    @SerialName("episode_count") val episodeCount: Long = 0,
    @SerialName("resolutions") val resolutions: List<String> = emptyList(),
    /**
     * 标记 missing 的文件数（>0 时前端提示）
     */
    @SerialName("missing_count") val missingCount: Long = 0,
    /**
     * 剧集播出状态：airing=在播 / ended=完结；电影或状态未知为 NULL
     */
    @SerialName("air_status") val airStatus: String? = null,
    /**
     * 已播出但所有媒体库里都没有的正季集数（电影恒 0）——「补齐缺集」的依据
     */
    @SerialName("missing_episode_count") val missingEpisodeCount: Long = 0,
    /**
     * 最近一次文件入账时间（首页「最近添加」排序依据）
     */
    @SerialName("added_at") val addedAt: String? = null,
    /**
     * 当前观看者是否收藏了这部作品（海报右上角那颗心）；不认人的调用恒 False
     */
    @SerialName("is_favorite") val isFavorite: Boolean = false,
    /**
     * 最近一次可追溯入库批次的剧集摘要；NULL=电影或迁移前旧台账
     */
    @SerialName("recent_addition") val recentAddition: LibraryRecentAdditionView? = null,
    /**
     * 本库在位剧集相对 TMDB 季集结构的完整度摘要；电影或无有效集号为 NULL
     */
    @SerialName("inventory_summary") val inventorySummary: LibraryInventorySummaryView? = null,
    /**
     * 在位但尚未探出介质规格的文件数——扫描补探阶段前端据此把「还在处理」的条目排到海报墙前面并点亮标记
     */
    @SerialName("probe_pending_count") val probePendingCount: Long = 0,
)

/**
 * 首页「按类型找电影 / 剧集」的一格：一个 TMDB 类型、跨库部数，以及贴在卡片上的封面。
 * 封面是这个类型**最近入库**、有剧照的那部片——色块同时是「这个类型新来了什么」
 * 的提示。部数多的类型先挑，同一部片不会贴在两个类型上。
 */
@Serializable
data class LibraryKindGenreView(
    /**
     * TMDB genre id；点进去带 g=value 开墙
     */
    @SerialName("value") val value: String = "",
    /**
     * 类型中文名
     */
    @SerialName("label") val label: String = "",
    /**
     * 跨库去重后的部数
     */
    @SerialName("count") val count: Long = 0,
    /**
     * 封面那部片的条目 id；没有可用剧照时为空
     */
    @SerialName("cover_item_id") val coverItemId: Long? = null,
    /**
     * 封面那部片的片名
     */
    @SerialName("cover_title") val coverTitle: String? = null,
    /**
     * 封面剧照（横版）；本地资产优先，回落 TMDB 图床
     */
    @SerialName("cover_url") val coverUrl: String? = null,
)

/**
 * 让条目进入「最近添加」的最后一批剧集的紧凑摘要。
 */
@Serializable
data class LibraryRecentAdditionView(
    @SerialName("season_count") val seasonCount: Long = 0,
    @SerialName("episode_count") val episodeCount: Long = 0,
    /**
     * 仅涉及一季时的季号；跨季为 NULL
     */
    @SerialName("season_number") val seasonNumber: Long? = null,
    /**
     * 同季连续批次的起始集；否则 NULL
     */
    @SerialName("first_episode_number") val firstEpisodeNumber: Long? = null,
    /**
     * 同季连续批次的结束集；否则 NULL
     */
    @SerialName("last_episode_number") val lastEpisodeNumber: Long? = null,
    /**
     * 本批是否完整覆盖该季 TMDB 已知集数
     */
    @SerialName("complete_season") val completeSeason: Boolean = false,
)

@Serializable
data class LibrarySearchHit(
    @SerialName("item") val item: LibraryItemView = LibraryItemView(),
    @SerialName("library_ids") val libraryIds: List<Long> = emptyList(),
    @SerialName("match") val match: LibrarySearchMatch = LibrarySearchMatch(),
)

/**
 * 可解释的命中证据；原始名称保留，客户端无需知道拼音索引的实现。
 */
@Serializable
data class LibrarySearchMatch(
    @SerialName("type") val type: String = "",
    @SerialName("source_field") val sourceField: String = "",
    @SerialName("matched_name") val matchedName: String = "",
    @SerialName("label") val label: String = "",
    @SerialName("person_id") val personId: Long? = null,
)

@Serializable
data class LibrarySearchPerson(
    @SerialName("id") val id: Long = 0,
    /**
     * TMDB 影人 ID：客户端据此打开库内影人页（与演职员入口同一页）
     */
    @SerialName("tmdb_person_id") val tmdbPersonId: Long? = null,
    @SerialName("name") val name: String = "",
    @SerialName("profile_path") val profilePath: String? = null,
    /**
     * 头像地址：本地已下载给本地，否则给 TMDB 图床；没有照片为空
     */
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("item_count") val itemCount: Long = 0,
    @SerialName("match") val match: LibrarySearchMatch = LibrarySearchMatch(),
)

@Serializable
data class LibrarySearchSuggestion(
    @SerialName("type") val type: String = "",
    @SerialName("text") val text: String = "",
    /**
     * 为什么联想到它，与结果卡片同一份命中原因（如「演员：李一桐」）
     */
    @SerialName("label") val label: String? = null,
    @SerialName("media_item_id") val mediaItemId: Long? = null,
    @SerialName("person_id") val personId: Long? = null,
)

/**
 * 索引更新不改变同一次浏览的候选顺序；库存和权限在每一页实时核验。
 */
@Serializable
data class LibrarySearchView(
    @SerialName("query") val query: String = "",
    @SerialName("person_id") val personId: Long? = null,
    @SerialName("items") val items: List<LibrarySearchHit> = emptyList(),
    @SerialName("people") val people: List<LibrarySearchPerson> = emptyList(),
    @SerialName("suggestions") val suggestions: List<LibrarySearchSuggestion> = emptyList(),
    @SerialName("next_cursor") val nextCursor: String? = null,
    /**
     * 名称索引尚有待更新实体；查询已合并最新名称
     */
    @SerialName("index_pending") val indexPending: Boolean = false,
)

/**
 * 库存统计快照（台账变化时重算，查询时直接读取 library 表）。
 * **扫描进行中读到的是中间态，不是结论**：扫描按事务分批落账，文件先入账、
 * 随后才识别，所以 ``unidentified_count`` 在扫描途中会先冲高再回落（一次
 * 上万文件的扫描中途读到两千多、扫完是 0，两个数都是真的）。要判断"这个库
 * 还有多少待识别"，先看同一响应里的 ``scanning``：为 true 时这几个数只能当
 * 进度看。刻意不把统计改成"只在扫描结束后更新"——那会让扫描期间完全看不到
 * 进展，比抖动更糟。
 */
@Serializable
data class LibraryStats(
    /**
     * 在位且已识别的媒体条目数
     */
    @SerialName("item_count") val itemCount: Long = 0,
    /**
     * 在位文件总数（含待识别）
     */
    @SerialName("file_count") val fileCount: Long = 0,
    /**
     * 在位文件总大小（字节）
     */
    @SerialName("total_size_bytes") val totalSizeBytes: Long = 0,
    /**
     * 在位待识别文件数（不含已忽略）；scanning=true 时是中间态，扫完才是结论
     */
    @SerialName("unidentified_count") val unidentifiedCount: Long = 0,
    /**
     * 标记 missing 的文件数（缺失清单入口）
     */
    @SerialName("missing_count") val missingCount: Long = 0,
    /**
     * 在位且被用户忽略的文件数（不再参与识别，可在已忽略清单恢复）
     */
    @SerialName("ignored_count") val ignoredCount: Long = 0,
)

@Serializable
data class LibraryView(
    @SerialName("id") val id: Long = 0,
    @SerialName("name") val name: String = "",
    @SerialName("kind") val kind: MediaKind = "",
    /**
     * 身份来源：tmdb / local
     */
    @SerialName("source") val source: String = "",
    @SerialName("capabilities") val capabilities: LibraryCapabilitiesView = LibraryCapabilitiesView(),
    /**
     * 缺图时是否抓帧生成缩略图（本地内容封面、TMDB 无剧照的分集）
     */
    @SerialName("generate_thumbnails") val generateThumbnails: Boolean = false,
    /**
     * 是否生成并展示视频章节（默认关，按库打开）
     */
    @SerialName("extract_chapter_images") val extractChapterImages: Boolean = false,
    /**
     * 是否识别剧集的片头片尾（默认开，只对剧集库起作用）
     */
    @SerialName("detect_media_segments") val detectMediaSegments: Boolean = false,
    /**
     * 是否从首页汇总里排除
     */
    @SerialName("exclude_from_home") val excludeFromHome: Boolean = false,
    /**
     * 是否按作品系列自动生成合集（展示偏好）
     */
    @SerialName("auto_series_collections") val autoSeriesCollections: Boolean = false,
    /**
     * 可见范围：everyone=所有成员 / selected=指定成员
     */
    @SerialName("access_mode") val accessMode: String = "",
    /**
     * 超管本人是否可浏览本库内容
     */
    @SerialName("admin_visible") val adminVisible: Boolean = false,
    /**
     * 显式授权的成员 id（仅管理员可见，成员端恒空）
     */
    @SerialName("member_ids") val memberIds: List<Long> = emptyList(),
    /**
     * 当前请求主体能否浏览本库内容。成员端恒 true（看不到的库根本不在列表里）；超管端为 false 时表示只有管理权：首页显示带锁的管理卡片，海报墙/详情/播放不可用
     */
    @SerialName("viewer_access") val viewerAccess: Boolean = false,
    @SerialName("root_paths") val rootPaths: List<String> = emptyList(),
    /**
     * 主根路径（root_paths 第一项）
     */
    @SerialName("primary_root") val primaryRoot: String? = null,
    @SerialName("is_default") val isDefault: Boolean = false,
    /**
     * 收藏范围条件
     */
    @SerialName("match_rules") val matchRules: List<JsonObject> = emptyList(),
    /**
     * 扫描后自动清理已确认丢失的库存记录
     */
    @SerialName("auto_clear_missing") val autoClearMissing: Boolean = false,
    /**
     * 是否启用实时文件监控
     */
    @SerialName("realtime_watch") val realtimeWatch: Boolean = false,
    /**
     * 任一根路径落在网络挂载（NFS/SMB/fuse）上。这种库实时监控收不到远端变更，新文件靠定期对账发现——界面据此把话说清楚，而不是让开关看起来有效
     */
    @SerialName("network_mount") val networkMount: Boolean = false,
    /**
     * 封面是用户上传的自定义图（而非自动拼贴）。前端据此决定「恢复自动拼贴」按钮的形态，以及空库要不要照样出图
     */
    @SerialName("custom_cover") val customCover: Boolean = false,
    /**
     * 库级刮削偏好覆盖；空对象 = 全跟全局设置
     */
    @SerialName("scrape_overrides") val scrapeOverrides: JsonObject = JsonObject(emptyMap()),
    @SerialName("stats") val stats: LibraryStats = LibraryStats(),
    /**
     * 是否正在扫描
     */
    @SerialName("scanning") val scanning: Boolean = false,
    /**
     * 扫描实时进度
     */
    @SerialName("scan_progress") val scanProgress: ScanProgressView? = null,
    /**
     * 最近一次扫描结论
     */
    @SerialName("last_scan") val lastScan: LastScanView? = null,
    /**
     * 是否正在整理文件名
     */
    @SerialName("organizing") val organizing: Boolean = false,
    /**
     * 整理实时进度（与扫描进度同构）
     */
    @SerialName("organize_progress") val organizeProgress: ScanProgressView? = null,
    /**
     * 最近一次整理结论
     */
    @SerialName("last_organize") val lastOrganize: LastOrganizeView? = null,
    /**
     * 整库元数据刷新状态；没在刷为 null
     */
    @SerialName("metadata_refresh") val metadataRefresh: MetadataRefreshView? = null,
    /**
     * 整库生成章节的作业状态（排队/进行中）；没在生成为 null
     */
    @SerialName("chapter_job") val chapterJob: ChapterJobView? = null,
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("updated_at") val updatedAt: String = "",
)

/**
 * 条目的展示元数据：本地 NFO > 库内刮削档案 > TMDB 实时兜底；
 * 三个来源都拉不到时整体为 null（docs/design/metadata.md 第 5 节）。
 */
@Serializable
data class LocalMetaView(
    @SerialName("plot") val plot: String? = null,
    @SerialName("rating") val rating: Double? = null,
    @SerialName("runtime_minutes") val runtimeMinutes: Long? = null,
    @SerialName("genres") val genres: List<String> = emptyList(),
    @SerialName("directors") val directors: List<String> = emptyList(),
    /**
     * 从 person 关系表读取的结构化导演；空列表时前端回退 directors 姓名
     */
    @SerialName("director_credits") val directorCredits: List<DirectorView> = emptyList(),
    @SerialName("actors") val actors: List<ActorView> = emptyList(),
    /**
     * 来源 NFO 文件名（source=nfo 时给出）
     */
    @SerialName("nfo_name") val nfoName: String = "",
    /**
     * 信息出处：nfo=本地刮削 / db=库内档案 / tmdb=实时兜底
     */
    @SerialName("source") val source: String = "",
)

/**
 * 「我的设备」列表里的一台设备（登录设备或 Jellyfin 播放器）。
 */
@Serializable
data class LoginDeviceView(
    /**
     * 设备 id：登录设备为 ld-<n>，Jellyfin 播放器为 jf-<n>
     */
    @SerialName("id") val id: String = "",
    /**
     * web / ios / tvos / macos / android / cli / worker / manual / jellyfin
     */
    @SerialName("kind") val kind: String = "",
    /**
     * 给人看的类型名：浏览器、iOS App、命令行、Infuse……
     */
    @SerialName("kind_label") val kindLabel: String = "",
    /**
     * login=用密码登录的（改密即下线）；paired=配对或手工创建的（改密默认保留）
     */
    @SerialName("family") val family: String = "",
    @SerialName("name") val name: String = "",
    /**
     * full=与主人相同的权限；transcode=只能转码
     */
    @SerialName("scope") val scope: String = "",
    @SerialName("platform") val platform: String? = null,
    @SerialName("client_version") val clientVersion: String? = null,
    @SerialName("created_at") val createdAt: String = "",
    @SerialName("last_seen_at") val lastSeenAt: String? = null,
    @SerialName("last_seen_ip") val lastSeenIp: String? = null,
    /**
     * 网页会话的过期时间
     */
    @SerialName("expires_at") val expiresAt: String? = null,
    /**
     * 是不是发起本次请求的这台设备
     */
    @SerialName("current") val current: Boolean = false,
    /**
     * 此刻是否有一条活着的转码控制连接（只有转码器有长连接；其余设备恒为 false，在不在用看 last_seen_at）
     */
    @SerialName("connected") val connected: Boolean = false,
    /**
     * 能否改名（Jellyfin 播放器的名字由客户端上报，不能改）
     */
    @SerialName("renamable") val renamable: Boolean = false,
    /**
     * 主人：成员 id；0 = 超管
     */
    @SerialName("owner_id") val ownerId: Long = 0,
    @SerialName("owner_username") val ownerUsername: String = "",
    @SerialName("owner_nickname") val ownerNickname: String = "",
    /**
     * 推送状态；只有 App 类设备、且在设备列表里才有
     */
    @SerialName("push") val push: DevicePushView? = null,
)

/**
 * MKV 精简索引（docs/design/playback-qoe.md §9.12）：只含视频轨索引点的 Cues 元素。
 * App 的播放引擎在解复用器读 SeekHead 登记的 Cues 位置时直接给这份，不必再下载原索引
 * （字幕轨多的片子原索引有几百 KB 到几 MB，外网慢时要单独下好几秒）。
 * 索引点的数值与原文件逐位一致。
 */
@Serializable
data class MatroskaCuesView(
    @SerialName("offset") val offset: Long = 0,
    @SerialName("data") val data: String = "",
    @SerialName("original_bytes") val originalBytes: Long = 0,
)

/**
 * 内容形态：电影 / 剧集 / 其他视频 / 图片（docs/design/library-other-kind.md 3.1、
 * library-photo-kind.md 2.1）。
 * ``movie`` 与 ``tv`` 的取值与 TMDB 的路径段一致，在 ``source=tmdb`` 的
 * 识别/刮削路径里可直接拼接 URL；``video`` 是没有结构假设的单本视频
 * （家庭录像、自录内容），``photo`` 是单张图片（照片、截图），两者都只在
 * 本地来源下出现，永远不会进 TMDB 请求。形态描述结构，不描述题材也不
 * 描述来源。
 */
/** 取值：'movie', 'tv', 'video', 'photo' */
typealias MediaKind = String

/**
 * 整库刷新的实时状态——全量重刷很慢，用户要看到"到哪部了、在做什么"。
 * 随库列表一并返回（见 LibraryView.metadata_refresh），媒体库首页的库卡片
 * 因此不必额外请求就能显示刷新进度；单库页另有专用端点做 2 秒级的阶段
 * 刷新（首页 10 秒一轮的节奏跟不上阶段变化）。
 */
@Serializable
data class MetadataRefreshView(
    @SerialName("refreshing") val refreshing: Boolean = false,
    /**
     * 已完成条目数（含失败）
     */
    @SerialName("processed") val processed: Long = 0,
    @SerialName("total") val total: Long = 0,
    /**
     * 刮削失败的条目数（多为 TMDB 不可达）
     */
    @SerialName("failed") val failed: Long = 0,
    /**
     * 已请求停止，正在收尾
     */
    @SerialName("stopping") val stopping: Boolean = false,
    /**
     * 正在处理的条目及其阶段
     */
    @SerialName("active") val active: List<RefreshActiveView> = emptyList(),
)

/**
 * 侧边栏主导航的个人排序。
 * 只存**顺序**（导航项 id 的列表），不存导航项本身——导航有哪些项、叫什么、
 * 什么权限可见，全部由前端与权限决定，这里存下来的仅仅是"这个人希望它们按
 * 什么次序排"。
 * 因此本字段是提示而非契约，前端按"排过的按此顺序在前，没排过的按内置默认
 * 顺序追加在后"合并（见 apps/web/lib/sidebar-nav.ts）：
 * - 版本升级新增的导航入口，在存过排序的老用户那里也一定会出现（追加在后），
 * 不会因为不在这个列表里而永远消失——这是这类"存死一份顺序"功能最常见的事故；
 * - 已经不存在的 id（导航项被删）读取时直接忽略，无需迁移。
 * 上限 32 只是防脏数据无限增长的安全阀，不是产品限制（主导航实际只有个位数项）。
 */
@Serializable
data class NavUiPrefs(
    /**
     * 侧栏主导航的展示顺序（导航项 id）；空列表 = 用内置默认顺序
     */
    @SerialName("order") val order: List<String> = emptyList(),
)

/**
 * 人物页作品列表的一格：一部我库里的片 + 这个人在其中的身份。
 */
@Serializable
data class PersonCreditView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    @SerialName("kind") val kind: MediaKind = "",
    @SerialName("tmdb_id") val tmdbId: Long = 0,
    @SerialName("title") val title: String = "",
    @SerialName("year") val year: Long? = null,
    /**
     * 海报（优先本地刮削资产，回落 TMDB 图床）；都没有为 NULL
     */
    @SerialName("poster_url") val posterUrl: String? = null,
    /**
     * 任一拥有该条目文件的库 id，供前端跳条目详情页；文件已全部删除、只剩档案时为 NULL，前端渲染为不可点
     */
    @SerialName("library_id") val libraryId: Long? = null,
    /**
     * 身份：cast=演员 / director=导演（剧集为主创）
     */
    @SerialName("department") val department: String = "",
    /**
     * 饰演角色（仅 cast）
     */
    @SerialName("character") val character: String? = null,
)

/**
 * 人物页的完整数据。
 */
@Serializable
data class PersonView(
    @SerialName("tmdb_person_id") val tmdbPersonId: Long = 0,
    @SerialName("name") val name: String = "",
    @SerialName("original_name") val originalName: String? = null,
    /**
     * 头像（TMDB 图床，经前端缓存代理）；TMDB 无照片为 NULL
     */
    @SerialName("avatar_url") val avatarUrl: String? = null,
    /**
     * 库内作品，主演在前、同档按剧组主次顺序与年份倒序（见 PersonRepository）
     */
    @SerialName("credits") val credits: List<PersonCreditView> = emptyList(),
)

/**
 * 进度条上的章节刻度（docs/design/player-feel.md §2.C1）。
 * 只有起点与标题：预览图由 trickplay 雪碧图负责，章节图片再塞一份会把
 * 起播响应撑大好几倍，而进度条上根本画不下。
 */
@Serializable
data class PlaybackChapterMarkView(
    @SerialName("start_ms") val startMs: Long = 0,
    @SerialName("title") val title: String? = null,
)

/**
 * 播放器客户端事件上报：把浏览器侧的现场（MediaError 详情、播放器状态）
 * 落进服务端日志。iPhone 上的播放故障没有任何本地可看的控制台，服务端
 * 日志是唯一能拿到客户端真相的地方。
 */
@Serializable
data class PlaybackClientLogPayload(
    @SerialName("event") val event: String,
    @SerialName("detail") val detail: JsonObject? = null,
)

/**
 * 决策结果的三态并集。``outcome`` 决定其余字段哪些有值。
 * - ``plan``    —— 可以播，按 ``tier`` 走；
 * - ``consent`` —— 需要用户同意开启软件转码（§3.6）；
 * - ``rejected``—— 放不了，``reason`` / ``suggestion`` 面向用户。
 */
@Serializable
data class PlaybackDecisionView(
    @SerialName("outcome") val outcome: String = "",
    @SerialName("tier") val tier: Long? = null,
    @SerialName("file_id") val fileId: Long? = null,
    @SerialName("container") val container: String? = null,
    @SerialName("video") val video: VideoPlanView? = null,
    @SerialName("audio") val audio: AudioPlanView? = null,
    @SerialName("audio_tracks") val audioTracks: List<AudioTrackView> = emptyList(),
    @SerialName("subtitles") val subtitles: List<SubtitlePlanView> = emptyList(),
    @SerialName("degraded_from") val degradedFrom: Long? = null,
    @SerialName("disc") val disc: String? = null,
    @SerialName("disc_playlist") val discPlaylist: String? = null,
    @SerialName("cost_hint") val costHint: String? = null,
    @SerialName("can_self_enable") val canSelfEnable: Boolean? = null,
    @SerialName("setting_namespace") val settingNamespace: String? = null,
    @SerialName("setting_key") val settingKey: String? = null,
    @SerialName("reason") val reason: String = "",
    @SerialName("suggestion") val suggestion: String? = null,
)

/**
 * 播放页要的条目信息，只有播放器用得上的那几样。
 * 播放路由只带 ``media_item_id``——它以 ``(kind, tmdb_id)`` 为锚、幂等复用，
 * 比库自增 id 稳定得多，分享出去的地址不会因删库重建而失效（§6.10）。库归
 * 属由服务端按成员可见性解析，前端只在「退出播放跳回条目页」时用到它。
 */
@Serializable
data class PlaybackItemView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    @SerialName("library_id") val libraryId: Long = 0,
    @SerialName("kind") val kind: String = "",
    @SerialName("title") val title: String = "",
    @SerialName("year") val year: Long? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
)

/**
 * 一次标记：目标 + 要改成什么。
 * 目标的表达与 Jellyfin 的 Series / Season / Episode 三级一一对应：不带季集
 * = 整个条目（电影，或整剧级联到全部集）；只带季 = 整季；季集都带 = 单集。
 * 电影也可以像播放接口那样带哨兵 ``(0, 0)``，落到同一个单元。
 * ``played`` 与 ``favorite`` 至少给一个，没给的那个保持原值。
 */
@Serializable
data class PlaybackMarksRequest(
    @SerialName("media_item_id") val mediaItemId: Long,
    @SerialName("season_number") val seasonNumber: Long? = null,
    @SerialName("episode_number") val episodeNumber: Long? = null,
    @SerialName("played") val played: Boolean? = null,
    @SerialName("favorite") val favorite: Boolean? = null,
    @SerialName("device_id") val deviceId: String? = null,
)

/**
 * 目标在当前成员名下的已看 / 收藏状态。读接口与写接口同一形状，
 * 写完直接拿它刷新按钮，不必再查一次。
 */
@Serializable
data class PlaybackMarksView(
    @SerialName("played") val played: Boolean = false,
    @SerialName("is_favorite") val isFavorite: Boolean = false,
    @SerialName("unplayed_count") val unplayedCount: Long? = null,
)

/**
 * 一次播放结束时上报的记录。指标口径按 CTA-2066，不自创。
 * 带 ``attempt_id`` 的是 docs/design/playback-qoe.md 口径的收尾上报：按编号合并进服务端在
 * 会话接口建好的那一行，**所有结局都报**（看完、中途退出、出画前退出、失败、异常退出）。
 * 不带编号的是网页播放器的旧口径整行快照，原样落库。
 * 数值超出上下界会被夹住、列表与明细超限会被截断（记一行警告），不拒收。
 */
@Serializable
data class PlaybackMetricPayload(
    @SerialName("library_file_id") val libraryFileId: Long? = null,
    @SerialName("tier") val tier: Long,
    @SerialName("degraded_from") val degradedFrom: Long? = null,
    @SerialName("engine") val engine: String? = null,
    @SerialName("hw_backend") val hwBackend: String? = null,
    @SerialName("ttff_ms") val ttffMs: Long? = null,
    @SerialName("rebuffer_ms") val rebufferMs: Long? = null,
    @SerialName("rebuffer_count") val rebufferCount: Long? = null,
    @SerialName("seek_count") val seekCount: Long? = null,
    @SerialName("dropped_frames") val droppedFrames: Long? = null,
    @SerialName("total_frames") val totalFrames: Long? = null,
    @SerialName("watched_ms") val watchedMs: Long? = null,
    @SerialName("attempt_id") val attemptId: String? = null,
    @SerialName("outcome") val outcome: String? = null,
    @SerialName("media_item_id") val mediaItemId: Long? = null,
    @SerialName("season_number") val seasonNumber: Long? = null,
    @SerialName("episode_number") val episodeNumber: Long? = null,
    @SerialName("origin") val origin: String? = null,
    @SerialName("client") val client: String? = null,
    @SerialName("lab_scenario") val labScenario: String? = null,
    @SerialName("route") val route: String? = null,
    @SerialName("network_class") val networkClass: String? = null,
    @SerialName("interface") val `interface`: String? = null,
    @SerialName("app_version") val appVersion: String? = null,
    @SerialName("first_frame_ms") val firstFrameMs: Long? = null,
    @SerialName("playing_ms") val playingMs: Long? = null,
    @SerialName("user_wait_ms") val userWaitMs: Long? = null,
    @SerialName("error_kind") val errorKind: String? = null,
    @SerialName("error_category") val errorCategory: String? = null,
    @SerialName("error_stage") val errorStage: String? = null,
    @SerialName("detail") val detail: JsonObject? = null,
    @SerialName("log_tail") val logTail: String? = null,
)

/**
 * 策略保存请求。**全字段可选，None = 不动这一项**——同意弹窗只翻
 * software_transcode_enabled 一个开关。
 */
@Serializable
data class PlaybackPolicyPayload(
    @SerialName("software_transcode_enabled") val softwareTranscodeEnabled: Boolean? = null,
    @SerialName("trickplay_enabled") val trickplayEnabled: Boolean? = null,
    @SerialName("transcode_cache_enabled") val transcodeCacheEnabled: Boolean? = null,
)

/**
 * 播放策略的当前取值。字段与 PlaybackPolicySetting 一一对应。
 * 数字上限（并发、输出高度、缓存配额）不在这里——它们已改为按机器规格
 * 自动推导（services/playback/limits.py），不再是配置项。
 */
@Serializable
data class PlaybackPolicyView(
    @SerialName("software_transcode_enabled") val softwareTranscodeEnabled: Boolean = false,
    @SerialName("trickplay_enabled") val trickplayEnabled: Boolean = false,
    @SerialName("transcode_cache_enabled") val transcodeCacheEnabled: Boolean = false,
    @SerialName("hardware_available") val hardwareAvailable: Boolean = false,
    @SerialName("hw_backends") val hwBackends: List<String> = emptyList(),
)

/**
 * 一次观看状态上报。三种事件同一入口，与 Jellyfin 的 Playing /
 * Playing/Progress / Playing/Stopped 一一对应。
 */
@Serializable
data class PlaybackProgressRequest(
    @SerialName("media_item_id") val mediaItemId: Long,
    @SerialName("season_number") val seasonNumber: Long? = null,
    @SerialName("episode_number") val episodeNumber: Long? = null,
    @SerialName("event") val event: String? = null,
    @SerialName("position_ms") val positionMs: Long? = null,
    @SerialName("audio_track") val audioTrack: String? = null,
    @SerialName("subtitle_track") val subtitleTrack: String? = null,
    @SerialName("file_id") val fileId: Long? = null,
    @SerialName("device_id") val deviceId: String? = null,
    @SerialName("paused") val paused: Boolean? = null,
)

/**
 * 可跳过的一段（docs/design/skip-intro.md）：服务端整季比对认出来的，客户端只管用。
 * - ``intro`` 片头：在区间里显示「跳过片头」，点了跳到 ``end_ms``；
 * - ``outro`` 片尾：到 ``start_ms`` 就提前显示「即将播放下一集」；``to_end`` 为假时
 * 片尾后面还有内容（下集预告、彩蛋），按钮是「跳过片尾」；
 * - ``ad`` 已确认的广告、``preview`` 已确认的预告：分别显示「跳过广告」「跳过预告」，
 * 手动跳到段尾；
 * - ``other`` 尚未明确分类的重复段：显示「跳过此段」，不猜测为广告或片头。
 */
@Serializable
data class PlaybackSegmentView(
    @SerialName("type") val type: String = "",
    @SerialName("start_ms") val startMs: Long = 0,
    @SerialName("end_ms") val endMs: Long = 0,
    @SerialName("to_end") val toEnd: Boolean = false,
)

/**
 * 开会话请求：在决策请求上多一个起播位置。
 */
@Serializable
data class PlaybackSessionRequest(
    @SerialName("file_id") val fileId: Long? = null,
    @SerialName("media_item_id") val mediaItemId: Long? = null,
    @SerialName("season_number") val seasonNumber: Long? = null,
    @SerialName("episode_number") val episodeNumber: Long? = null,
    @SerialName("capability") val capability: ClientCapabilityIn,
    @SerialName("failed_tiers") val failedTiers: List<Long>? = null,
    @SerialName("audio_track") val audioTrack: String? = null,
    @SerialName("subtitle_track") val subtitleTrack: String? = null,
    @SerialName("max_height") val maxHeight: Long? = null,
    @SerialName("device_id") val deviceId: String? = null,
    @SerialName("downlink_bps") val downlinkBps: Long? = null,
    @SerialName("start_ms") val startMs: Long? = null,
    @SerialName("attempt_id") val attemptId: String? = null,
    @SerialName("client") val client: String? = null,
)

/**
 * 开会话的结果。
 * 三态里只有 ``plan`` 才会真的起会话；``consent`` / ``rejected`` 原样把
 * 决策带回前端，由它渲染弹窗或错误说明。
 */
@Serializable
data class PlaybackSessionView(
    @SerialName("decision") val decision: PlaybackDecisionView = PlaybackDecisionView(),
    @SerialName("session_id") val sessionId: String? = null,
    @SerialName("stream_url") val streamUrl: String? = null,
    @SerialName("progressive_segments") val progressiveSegments: Boolean = false,
    @SerialName("start_ms") val startMs: Long = 0,
    @SerialName("timeline") val timeline: String = "",
    @SerialName("subtitle_urls") val subtitleUrls: List<String> = emptyList(),
    @SerialName("master_url") val masterUrl: String? = null,
    @SerialName("hw_backend") val hwBackend: String? = null,
    @SerialName("watch") val watch: PlaybackStateView? = null,
    @SerialName("source") val source: PlaybackSourceView? = null,
    @SerialName("chapters") val chapters: List<PlaybackChapterMarkView> = emptyList(),
    @SerialName("segments") val segments: List<PlaybackSegmentView>? = null,
    @SerialName("matroska_cues") val matroskaCues: MatroskaCuesView? = null,
)

/**
 * 源文件的客观规格（台账真值），诊断面板「源 → 处理」层次的左半边。
 * Emby 式面板的关键是把「源是什么」与「我们对它做了什么」摆在一起——
 * 只报处理结果，用户看不出「1080p H264 明明能直通为什么在转码」这类问题。
 */
@Serializable
data class PlaybackSourceView(
    @SerialName("container") val container: String? = null,
    @SerialName("resolution") val resolution: String? = null,
    @SerialName("video_codec") val videoCodec: String? = null,
    @SerialName("hdr") val hdr: String? = null,
    @SerialName("bit_rate") val bitRate: Long? = null,
    @SerialName("frame_rate") val frameRate: Double? = null,
    @SerialName("size_bytes") val sizeBytes: Long? = null,
)

/**
 * 一个播放单元在当前成员名下的观看状态。续播与上报共用同一形状。
 */
@Serializable
data class PlaybackStateView(
    @SerialName("position_ms") val positionMs: Long = 0,
    @SerialName("played") val played: Boolean = false,
    @SerialName("play_count") val playCount: Long = 0,
    @SerialName("duration_ms") val durationMs: Long? = null,
    @SerialName("audio_track") val audioTrack: String? = null,
    @SerialName("subtitle_track") val subtitleTrack: String? = null,
    @SerialName("ended_by_admin") val endedByAdmin: Boolean = false,
)

@Serializable
data class ReelByteRangeView(
    /**
     * 起始字节
     */
    @SerialName("offset") val offset: Long = 0,
    /**
     * 长度
     */
    @SerialName("length") val length: Long = 0,
    /**
     * head 文件头 / index 索引 / start 起点后约 4 秒
     */
    @SerialName("purpose") val purpose: String = "",
)

@Serializable
data class ReelEpisodeView(
    /**
     * 季号
     */
    @SerialName("season") val season: Long = 0,
    /**
     * 集号
     */
    @SerialName("episode") val episode: Long = 0,
    /**
     * 集名
     */
    @SerialName("name") val name: String? = null,
    /**
     * 分集简介
     */
    @SerialName("overview") val overview: String? = null,
)

@Serializable
data class ReelItemView(
    /**
     * 片段标识（事件上报用）
     */
    @SerialName("id") val id: String = "",
    @SerialName("title") val title: ReelTitleView = ReelTitleView(),
    /**
     * 封面：起点那一帧；没有时是剧照
     */
    @SerialName("cover_url") val coverUrl: String? = null,
    @SerialName("segment") val segment: ReelSegmentView = ReelSegmentView(),
    @SerialName("play") val play: ReelPlayView = ReelPlayView(),
)

@Serializable
data class ReelPersonView(
    /**
     * 姓名
     */
    @SerialName("name") val name: String = "",
    /**
     * TMDB 影人 ID（打开人物页用）；只有姓名时为空
     */
    @SerialName("tmdb_person_id") val tmdbPersonId: Long? = null,
    /**
     * 头像（TMDB 图床地址）
     */
    @SerialName("avatar_url") val avatarUrl: String? = null,
)

/**
 * 怎么放这一条。mode=seek：自研引擎打开原片、从 segment.start_ms 起播。
 */
@Serializable
data class ReelPlayView(
    /**
     * 放法：seek=从原片中间起播（一期仅此一种）
     */
    @SerialName("mode") val mode: String = "",
    /**
     * seek：原片取流地址（带 /api/v1 的相对路径，含令牌）
     */
    @SerialName("stream_url") val streamUrl: String? = null,
    /**
     * seek：原片大小（片源字节缓存的键要用）
     */
    @SerialName("size_bytes") val sizeBytes: Long? = null,
    /**
     * seek：光盘的交付方式（同正片会话 decision.disc）——image=光盘镜像，stream_url 是镜像原字节；folder=原盘目录（BDMV / VIDEO_TS），按 GET /playback/files/{file_id}/disc 的清单（含主播放列表）逐个文件取；None=普通文件
     */
    @SerialName("disc") val disc: String? = null,
    /**
     * seek：起播音轨的同类型序号
     */
    @SerialName("audio_ordinal") val audioOrdinal: Long? = null,
    /**
     * seek：要显示的中文字幕；None 不开
     */
    @SerialName("subtitle") val subtitle: ReelSubtitleView? = null,
    /**
     * seek：上一条播放期间应预取的字节范围
     */
    @SerialName("prefetch") val prefetch: List<ReelByteRangeView> = emptyList(),
)

/**
 * 放原片的哪一段（原片时间轴，与怎么放无关）。
 */
@Serializable
data class ReelSegmentView(
    /**
     * 原片文件（台账行 id）
     */
    @SerialName("file_id") val fileId: Long = 0,
    /**
     * 起点（落在关键帧上）
     */
    @SerialName("start_ms") val startMs: Long = 0,
    /**
     * 终点（落在两句对白之间）
     */
    @SerialName("end_ms") val endMs: Long = 0,
    /**
     * 原片总长（剧集是这一集）
     */
    @SerialName("duration_ms") val durationMs: Long? = null,
    /**
     * 挑法：bitrate 码率最高段 / chapter 章节起点 / position 固定位置
     */
    @SerialName("method") val method: String = "",
)

@Serializable
data class ReelSubtitleView(
    /**
     * 内封字幕的同类型序号（embedded:<k> 的 k）
     */
    @SerialName("ordinal") val ordinal: Long = 0,
    @SerialName("language") val language: String? = null,
    @SerialName("title") val title: String? = null,
    @SerialName("codec") val codec: String? = null,
    /**
     * 只含这一段（前后各留几秒）的字幕文件地址（带 /api/v1 的相对路径，含令牌），时间戳是文件时间。放转码流、全屏片段模式用：读不到内封轨时靠它出字幕，不必等 NAS 通读整个文件抽整轨。只有能原样拷贝的文字轨才有（srt / ass），否则为 None
     */
    @SerialName("url") val url: String? = null,
    /**
     * url 那份字幕的格式：srt / ass
     */
    @SerialName("format") val format: String? = null,
)

/**
 * 这一条属于哪部片：展示用的信息。图片地址都是不带 /api/v1 的相对路径或完整外链。
 */
@Serializable
data class ReelTitleView(
    /**
     * 条目 id
     */
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    /**
     * 这一条的文件所在的媒体库（分享要用）
     */
    @SerialName("library_id") val libraryId: Long = 0,
    /**
     * 电影 / 剧集 / 其他
     */
    @SerialName("kind") val kind: String = "",
    /**
     * 片名
     */
    @SerialName("name") val name: String = "",
    /**
     * 年份
     */
    @SerialName("year") val year: Long? = null,
    /**
     * 评分（0～10）
     */
    @SerialName("rating") val rating: Double? = null,
    /**
     * 片长；剧集是这一集的时长
     */
    @SerialName("runtime_minutes") val runtimeMinutes: Long? = null,
    /**
     * 类型，最多 3 个
     */
    @SerialName("genres") val genres: List<String> = emptyList(),
    /**
     * 宣传语
     */
    @SerialName("tagline") val tagline: String? = null,
    /**
     * 简介（剧集是整剧的，分集简介在 episode 里）
     */
    @SerialName("overview") val overview: String? = null,
    /**
     * 本人收藏了没有（电影 / 整剧）
     */
    @SerialName("favorite") val favorite: Boolean = false,
    /**
     * 本人看过没有（电影看整部，剧集看这一集）
     */
    @SerialName("played") val played: Boolean = false,
    /**
     * 看了一半时的进度（1～99，同「继续观看」口径）；没看过、已看完为空
     */
    @SerialName("progress_percent") val progressPercent: Long? = null,
    /**
     * 电影是导演、剧集是主创，最多两位
     */
    @SerialName("directors") val directors: List<ReelPersonView> = emptyList(),
    /**
     * 海报
     */
    @SerialName("poster_url") val posterUrl: String? = null,
    /**
     * 横版剧照
     */
    @SerialName("backdrop_url") val backdropUrl: String? = null,
    /**
     * 片名 Logo（本地资产）
     */
    @SerialName("logo_url") val logoUrl: String? = null,
    /**
     * 剧集：这一段出自哪一集
     */
    @SerialName("episode") val episode: ReelEpisodeView? = null,
)

/**
 * 整库刷新中正在处理的一部片（并发若干路，故是列表）。
 */
@Serializable
data class RefreshActiveView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    @SerialName("title") val title: String = "",
    /**
     * 当前阶段：拉取 TMDB 档案 / 写入元数据 / 下载图片 / …
     */
    @SerialName("phase") val phase: String = "",
)

/**
 * 进行中扫描/整理的实时进度（前端在库封面上画进度环，两种任务共用）。
 * ``phase`` 是必填的：一次"扫描"内部分好几段（盘点 → 逐文件入账 →
 * 补齐图片资产），分子分母各段各算。前端**必须**按阶段选文案，否则
 * 进度走完文件数后还要跑几分钟资产，界面就会僵在"已处理 = 总数"上
 * 对用户撒谎（见 library_scan.ScanPhase）。
 */
@Serializable
data class ScanProgressView(
    /**
     * 进行中的阶段，取值见 library_scan.ScanPhase / organizing
     */
    @SerialName("phase") val phase: String = "",
    @SerialName("processed") val processed: Long = 0,
    /**
     * 总数；0 表示分母未知，前端画不确定态转圈
     */
    @SerialName("total") val total: Long = 0,
)

/**
 * 全站背景蒙版（.page-scrim）的样式偏好。
 * 蒙版是铺在背景大图之上、页面内容之下的一层深色模糊层，压住背景、
 * 突出内容（见 apps/web/app/globals.css 的 .page-scrim）。全站只有这
 * 一档蒙版（除「新任务」首页大图直出外，所有页面统一），两个可调项
 * 分别驱动前端 CSS 变量 ``--scrim-blur`` / ``--scrim-dark``：
 * - ``blur``：高斯模糊半径（px）。0 = 不模糊、背景大图清晰透出；越大背景
 * 越朦胧。
 * - ``dark``：压暗程度（蒙版底色的不透明度）。0 = 完全不压暗，1 = 全黑。
 * 默认值是实际调校后确定的出厂观感：中等模糊 + 近七成压暗，背景大图化为
 * 朦胧色块托住内容、又不至于抢走注意力；必须与前端 DEFAULT_UI_PREFS
 * 以及 globals.css 里 .page-scrim 的变量兜底值保持一致。
 */
@Serializable
data class ScrimUiPrefs(
    /**
     * 蒙版高斯模糊半径（px）：0 不模糊，越大背景越朦胧
     */
    @SerialName("blur") val blur: Double = 0.0,
    /**
     * 蒙版压暗程度：0 完全不压暗，1 全黑
     */
    @SerialName("dark") val dark: Double = 0.0,
)

/**
 * 一季的分集清单（分集横滚区数据源）。
 */
@Serializable
data class SeasonEpisodesView(
    @SerialName("season_number") val seasonNumber: Long = 0,
    @SerialName("episodes") val episodes: List<EpisodeView> = emptyList(),
)

/**
 * 系列里的一部作品：库里有没有、在追没在追。
 */
@Serializable
data class SeriesPartView(
    @SerialName("tmdb_id") val tmdbId: Long = 0,
    @SerialName("title") val title: String = "",
    @SerialName("release_date") val releaseDate: String? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
    /**
     * 库里已有的那条；null=缺这一部
     */
    @SerialName("media_item_id") val mediaItemId: Long? = null,
    /**
     * 已经在追（有订阅工单）
     */
    @SerialName("subscribed") val subscribed: Boolean = false,
)

/**
 * 当前主体的能力开关快照（前端据此裁剪入口；安全边界仍在后端 403）。
 */
@Serializable
data class SessionCapabilities(
    @SerialName("allow_subscribe") val allowSubscribe: Boolean = false,
    @SerialName("allow_search") val allowSearch: Boolean = false,
    @SerialName("allow_direct_download") val allowDirectDownload: Boolean = false,
)

/**
 * 当前登录状态（GET /auth/me 与登录成功后的返回体）。
 */
@Serializable
data class SessionView(
    @SerialName("username") val username: String = "",
    @SerialName("nickname") val nickname: String = "",
    /**
     * 头像相对 URL（含版本号）；未上传过头像时为空
     */
    @SerialName("avatar_url") val avatarUrl: String? = null,
    /**
     * admin=超级管理员；member=成员
     */
    @SerialName("role") val role: String = "",
    /**
     * 能力开关快照；管理员恒为全开
     */
    @SerialName("capabilities") val capabilities: SessionCapabilities = SessionCapabilities(),
    /**
     * 本次请求所用的登录设备；升级前签发的旧网页会话为空
     */
    @SerialName("device") val device: DeviceBrief? = null,
)

/**
 * 侧边栏（液态玻璃面板）的样式偏好。
 * 两个值直接对应前端 WebGL 着色器的参数（见 apps/web/lib/glass.ts）：
 * 侧栏玻璃的基底是 LiquidGlassCard 同款材质（见 apps/web/lib/glass.ts），
 * 三个值是在其上微调的滑杆，默认值即 Card 出厂观感：
 * - ``transparency``：玻璃透明程度。0 = Card 标准玻璃，1 = 玻璃完全
 * 隐去；对应 shader 的 u_opacity（材质整体淡出）。
 * - ``brightness``：玻璃明暗。-1 最暗 ~ 1 最亮，0 = 不加暗不提亮；
 * 对应 shader 的 tint 参数。
 * - ``depth``：玻璃厚度（边缘曲率带宽度，px）。越大越像厚玻璃、边缘折射带
 * 越宽；对应 shader 的 u_zRadius，过小会使高度场退化，故下限取 10。
 * 默认值是实际调校后确定的出厂观感（半透 + 略压暗 + 偏薄的边缘折射带），
 * 而非 Card 材质的原始参数；必须与前端 DEFAULT_UI_PREFS 保持一致。
 */
@Serializable
data class SidebarUiPrefs(
    /**
     * 玻璃透明程度：0 标准玻璃，1 完全隐去
     */
    @SerialName("transparency") val transparency: Double = 0.0,
    /**
     * 玻璃明暗：-1 最暗，1 最亮
     */
    @SerialName("brightness") val brightness: Double = 0.0,
    /**
     * 玻璃厚度（边缘曲率带宽度，px）
     */
    @SerialName("depth") val depth: Double = 0.0,
)

@Serializable
data class SubtitlePlanView(
    @SerialName("track_ref") val trackRef: String = "",
    @SerialName("kind") val kind: String = "",
    @SerialName("language") val language: String? = null,
    @SerialName("is_default") val isDefault: Boolean = false,
    @SerialName("is_ai") val isAi: Boolean = false,
    @SerialName("title") val title: String? = null,
    @SerialName("is_forced") val isForced: Boolean? = null,
)

/**
 * 一条字幕：内封轨（ffprobe）或外挂文件（目录发现）。
 */
@Serializable
data class SubtitleStreamView(
    /**
     * 内封轨编码（subrip/ass/pgs…）；外挂为文件扩展名
     */
    @SerialName("codec") val codec: String? = null,
    @SerialName("language") val language: String? = null,
    @SerialName("title") val title: String? = null,
    @SerialName("forced") val forced: Boolean = false,
    @SerialName("default") val default: Boolean = false,
    /**
     * 是否外挂字幕文件
     */
    @SerialName("external") val external: Boolean = false,
    /**
     * 外挂字幕的文件名
     */
    @SerialName("file_name") val fileName: String? = null,
)

/**
 * 不经用户操作时会放的音轨 / 字幕（与起播同一口径：本集记着的 > 沿用同剧上一集 >
 * 默认轨策略，见 services/playback/track_defaults）。详情页据此标「默认」并说明原因。
 */
@Serializable
data class TrackDefaultsView(
    /**
     * 将要放的音轨（中性引用 embedded:<k>）；没有音轨为 null
     */
    @SerialName("audio_track") val audioTrack: String? = null,
    /**
     * remembered 上次换的 / series 沿用上一集 / original_language 影片原声 / default_flag 片源标注的默认 / first 第一条 / none 没有音轨
     */
    @SerialName("audio_reason") val audioReason: String = "",
    /**
     * 音轨原因的一句中文，界面直接展示
     */
    @SerialName("audio_note") val audioNote: String = "",
    /**
     * 将要开的字幕（embedded:<k> / external:<文件名>）；null = 不开字幕
     */
    @SerialName("subtitle_track") val subtitleTrack: String? = null,
    /**
     * remembered / series / library_language 媒体库语言 / forced 强制字幕 / same_language_off 原声就是库语言 / no_language_match 没有库语言字幕 / external / default_flag / forced_only / none（后四个是没有库语言可比时的旧规则）
     */
    @SerialName("subtitle_reason") val subtitleReason: String = "",
    /**
     * 字幕原因的一句中文，界面直接展示
     */
    @SerialName("subtitle_note") val subtitleNote: String = "",
)

/**
 * 进度条缩略图索引。
 * `ready=false` 表示还在生成（或这部片生成不了）——前端表现为「暂无预览」，
 * 不影响播放。前端据 `interval_ms` 与格子尺寸算「第 t 秒在哪张图的哪一格」。
 */
@Serializable
data class TrickplayView(
    @SerialName("ready") val ready: Boolean = false,
    @SerialName("interval_ms") val intervalMs: Long = 0,
    @SerialName("tile_width") val tileWidth: Long = 0,
    @SerialName("tile_height") val tileHeight: Long = 0,
    @SerialName("columns") val columns: Long = 0,
    @SerialName("rows") val rows: Long = 0,
    @SerialName("count") val count: Long = 0,
    @SerialName("sheets") val sheets: List<String> = emptyList(),
)

/**
 * 全站界面样式偏好，按页面分组。新页面的设定加嵌套模型字段即可。
 */
@Serializable
data class UiPreferencesSetting(
    /**
     * 主题 id，取值见前端 lib/themes.ts 的注册表（silver / netflix）。存纯字符串并放宽校验：未知值由前端 normalizeThemeId 兜底为默认主题，老后端读到新主题 id 也不会整体拒绝（前向兼容）。
     */
    @SerialName("theme") val theme: String = "",
    /**
     * 桌面端（≥768px 视口）的主题 id 覆盖；空 = 跟随 theme。校验口径与 theme 相同（纯字符串、前端兜底未知值），2026-09 起桌面 / 移动端可分别选主题，见前端 lib/ui-prefs.tsx 的 resolveThemeId。
     */
    @SerialName("theme_desktop") val themeDesktop: String? = null,
    /**
     * 移动端（<768px 视口）的主题 id 覆盖；空 = 跟随 theme。
     */
    @SerialName("theme_mobile") val themeMobile: String? = null,
    /**
     * 侧边栏玻璃面板
     */
    @SerialName("sidebar") val sidebar: SidebarUiPrefs = SidebarUiPrefs(),
    /**
     * 全站背景蒙版
     */
    @SerialName("scrim") val scrim: ScrimUiPrefs = ScrimUiPrefs(),
    /**
     * 侧边栏主导航排序
     */
    @SerialName("nav") val nav: NavUiPrefs = NavUiPrefs(),
    /**
     * 媒体库首页的行清单
     */
    @SerialName("home") val home: HomeUiPrefs = HomeUiPrefs(),
)

/**
 * 媒体库首页「接下来继续」的一张卡片。
 * 卡片指向的**永远是还没看完的那个单元**——电影是它自己，剧集是从最近播放
 * 那一集起往后第一个没看完的。看完的作品不出卡，所以这里没有"已看完"态。
 */
@Serializable
data class UpNextItemView(
    @SerialName("media_item_id") val mediaItemId: Long = 0,
    @SerialName("library_id") val libraryId: Long = 0,
    @SerialName("kind") val kind: MediaKind = "",
    @SerialName("title") val title: String = "",
    @SerialName("year") val year: Long? = null,
    @SerialName("poster_url") val posterUrl: String? = null,
    /**
     * 海报宽高比（同海报墙 primary_aspect）
     */
    @SerialName("poster_aspect") val posterAspect: Double = 0.0,
    @SerialName("backdrop_url") val backdropUrl: String? = null,
    @SerialName("episode_still_url") val episodeStillUrl: String? = null,
    /**
     * 分集剧照的 TMDB 原图（电视等大屏用）
     */
    @SerialName("episode_still_original_url") val episodeStillOriginalUrl: String? = null,
    /**
     * 片名 Logo（透明底，本地资产优先）
     */
    @SerialName("logo_url") val logoUrl: String? = null,
    /**
     * 简介：剧集取卡片这一集的（没有则用整部剧的），电影取影片的
     */
    @SerialName("overview") val overview: String? = null,
    /**
     * 类型（如「剧情」「科幻」）
     */
    @SerialName("genres") val genres: List<String>? = null,
    @SerialName("season_number") val seasonNumber: Long = 0,
    @SerialName("episode_number") val episodeNumber: Long = 0,
    @SerialName("episode_title") val episodeTitle: String? = null,
    @SerialName("unwatched_ahead_count") val unwatchedAheadCount: Long = 0,
    @SerialName("position_ms") val positionMs: Long = 0,
    @SerialName("duration_ms") val durationMs: Long? = null,
    @SerialName("progress_percent") val progressPercent: Long? = null,
    /**
     * 指向的是下一集，而不是上次那一个
     */
    @SerialName("advanced") val advanced: Boolean = false,
    @SerialName("last_played_at") val lastPlayedAt: String = "",
)

/**
 * 「接下来继续」横排的数据载荷。
 */
@Serializable
data class UpNextView(
    @SerialName("items") val items: List<UpNextItemView> = emptyList(),
)

@Serializable
data class VideoPlanView(
    @SerialName("action") val action: String = "",
    @SerialName("codec") val codec: String? = null,
    @SerialName("height") val height: Long? = null,
    @SerialName("tone_map") val toneMap: Boolean = false,
    @SerialName("bitrate_cap_bps") val bitrateCapBps: Long? = null,
    @SerialName("burn_subtitle") val burnSubtitle: String? = null,
)

/**
 * 前端 ``MediaCapabilities.decodingInfo()`` 的一项视频探测结果。
 */
@Serializable
data class VideoSupportIn(
    @SerialName("codec") val codec: String,
    @SerialName("max_height") val maxHeight: Long? = null,
    @SerialName("smooth") val smooth: Boolean? = null,
    @SerialName("power_efficient") val powerEfficient: Boolean? = null,
)

