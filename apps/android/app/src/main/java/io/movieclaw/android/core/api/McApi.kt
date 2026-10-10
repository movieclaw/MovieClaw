package io.movieclaw.android.core.api

import io.movieclaw.android.core.model.AgentAttachment
import io.movieclaw.android.core.model.AgentSessionStart
import io.movieclaw.android.core.model.FsBrowseView
import io.movieclaw.android.core.model.HandoffPrompt
import io.movieclaw.android.core.model.JobView
import io.movieclaw.android.core.model.HandoffRequest
import io.movieclaw.android.core.model.LibraryGalleryGroupView
import io.movieclaw.android.core.model.ActivePlaybackSession
import io.movieclaw.android.core.model.BootstrapStatus
import io.movieclaw.android.core.model.CastMember
import io.movieclaw.android.core.model.CollectionTitles
import io.movieclaw.android.core.model.CreateAdminRequest
import io.movieclaw.android.core.model.ChangePasswordRequest
import io.movieclaw.android.core.model.DeviceRenameRequest
import io.movieclaw.android.core.model.LoginDevice
import io.movieclaw.android.core.model.PlaybackMetricPayload
import io.movieclaw.android.core.model.TrickplayView
import io.movieclaw.android.core.model.UpgradeRunView
import io.movieclaw.android.core.model.PlaybackPolicy
import io.movieclaw.android.core.model.PlaybackPolicyPatchFull
import io.movieclaw.android.core.model.UpdateProfileRequest
import io.movieclaw.android.core.model.DeviceLoginRequest
import io.movieclaw.android.core.model.DeviceLoginView
import io.movieclaw.android.core.model.DiscoveredTitle
import io.movieclaw.android.core.model.DiscoveryPage
import io.movieclaw.android.core.model.DownloadSubmitRequest
import io.movieclaw.android.core.model.DispatchPreviewView
import io.movieclaw.android.core.model.DownloadTaskList
import io.movieclaw.android.core.model.FollowFutureRequest
import io.movieclaw.android.core.model.HealthView
import io.movieclaw.android.core.model.JobListView
import io.movieclaw.android.core.model.LibraryFacets
import io.movieclaw.android.core.model.LibraryIndexEntry
import io.movieclaw.android.core.model.LibraryItemDetailView
import io.movieclaw.android.core.model.LibraryItemView
import io.movieclaw.android.core.model.LibrarySearchGroup
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.MemberCreateRequest
import io.movieclaw.android.core.model.MemberPasswordReset
import io.movieclaw.android.core.model.MemberStatusRequest
import io.movieclaw.android.core.model.MemberUpdateRequest
import io.movieclaw.android.core.model.MemberView
import io.movieclaw.android.core.model.CleanResult
import io.movieclaw.android.core.model.LogContent
import io.movieclaw.android.core.model.LogDayList
import io.movieclaw.android.core.model.NetworkConfig
import io.movieclaw.android.core.model.NetworkTestResult
import io.movieclaw.android.core.model.StorageState
import io.movieclaw.android.core.model.UpdateCheck
import io.movieclaw.android.core.model.UpdateProgress
import io.movieclaw.android.core.model.UpdateStatus
import io.movieclaw.android.core.model.Notice
import io.movieclaw.android.core.model.PipelineHealth
import io.movieclaw.android.core.model.PlaybackActivityView
import io.movieclaw.android.core.model.PlaybackPolicyPatch
import io.movieclaw.android.core.model.PlaybackProgressRequest
import io.movieclaw.android.core.model.PlaybackSessionRequest
import io.movieclaw.android.core.model.PlaybackSessionView
import io.movieclaw.android.core.model.PlaybackHistoryView
import io.movieclaw.android.core.model.PlaybackWatchStatsView
import io.movieclaw.android.core.model.PlaybackStateView
import io.movieclaw.android.core.model.PrepareView
import io.movieclaw.android.core.model.SearchHistoryItem
import io.movieclaw.android.core.model.SeasonEpisodesView
import io.movieclaw.android.core.model.SharePublic
import io.movieclaw.android.core.model.ShareUnlockRequest
import io.movieclaw.android.core.model.SharedCollection
import io.movieclaw.android.core.model.SharedItem
import io.movieclaw.android.core.model.SessionAccepted
import io.movieclaw.android.core.model.SessionRename
import io.movieclaw.android.core.model.SessionRetry
import io.movieclaw.android.core.model.SessionSummary
import io.movieclaw.android.core.model.SessionTranscript
import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.model.SubscriptionCreateRequest
import io.movieclaw.android.core.model.RuleSetView
import io.movieclaw.android.core.model.SubscriptionCreateView
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.model.TitleDetails
import io.movieclaw.android.core.model.TitlePreviewRequest
import io.movieclaw.android.core.model.TitleSearchRequest
import io.movieclaw.android.core.model.TitleSearchView
import io.movieclaw.android.core.model.TodayArrival
import io.movieclaw.android.core.model.UpNextView
import io.movieclaw.android.core.model.PlaybackMarks
import io.movieclaw.android.core.model.PlaybackMarksRequest
import io.movieclaw.android.core.network.McEnvelope
import kotlinx.serialization.json.JsonElement
import okhttp3.MultipartBody
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.Multipart
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Part
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * M0/M1 手写端点(路径相对 <origin>/api/v1)。
 * 完整端点将由 scripts/gen_kotlin_api.py 从服务端 OpenAPI 生成后并入本包。
 */
interface McApi {

    @GET("health")
    suspend fun health(): HealthView

    @GET("auth/bootstrap")
    suspend fun bootstrapStatus(): McEnvelope<BootstrapStatus>

    @POST("auth/bootstrap")
    suspend fun bootstrapCreate(@Body body: CreateAdminRequest): McEnvelope<SessionView>

    @POST("auth/device/login")
    suspend fun deviceLogin(@Body body: DeviceLoginRequest): McEnvelope<DeviceLoginView>

    @GET("auth/me")
    suspend fun me(): McEnvelope<SessionView>

    @PUT("auth/profile")
    suspend fun updateProfile(@Body body: UpdateProfileRequest): McEnvelope<SessionView>

    @PUT("auth/password")
    suspend fun changePassword(@Body body: ChangePasswordRequest): McEnvelope<SessionView>

    @Multipart
    @POST("auth/avatar")
    suspend fun uploadAvatar(@Part file: MultipartBody.Part): McEnvelope<JsonElement>

    @GET("auth/devices")
    suspend fun devices(@Query("all") all: Boolean? = null): McEnvelope<List<LoginDevice>>

    /** 清理长期没用的设备：dry_run 只列出（确认框用），真跑就是注销。服务端永远不清当前这台和连着的转码器 */
    @POST("auth/devices/cleanup")
    suspend fun cleanupDevices(
        @Body body: io.movieclaw.android.core.model.DeviceCleanupRequest,
    ): McEnvelope<io.movieclaw.android.core.model.DeviceCleanupView>

    @PATCH("auth/devices/{deviceId}")
    suspend fun renameDevice(
        @Path("deviceId") deviceId: String,
        @Body body: DeviceRenameRequest,
    ): McEnvelope<JsonElement>

    @DELETE("auth/devices/{deviceId}")
    suspend fun revokeDevice(@Path("deviceId") deviceId: String): McEnvelope<JsonElement>

    /* ---------------- 更新与维护 / 网络 / 日志(P2 设置区) ---------------- */

    /** 待更新快照（读库不触网）：「我的」页提醒组的「新版本 vX / 新识别模型 X」用它 */
    @GET("app/update/pending")
    suspend fun pendingUpdate(): McEnvelope<io.movieclaw.android.core.model.PendingUpdate>

    @GET("app/update/status")
    suspend fun updateStatus(): McEnvelope<UpdateStatus>

    @POST("app/update/check")
    suspend fun checkUpdate(): McEnvelope<UpdateCheck>

    @POST("app/update/apply")
    suspend fun applyUpdate(): McEnvelope<UpdateProgress>

    @GET("app/update/progress")
    suspend fun updateProgress(): McEnvelope<UpdateProgress>

    @GET("app/storage")
    suspend fun storageState(): McEnvelope<StorageState>

    @POST("app/storage/{key}/clean")
    suspend fun cleanStorage(@Path("key") key: String): McEnvelope<CleanResult>

    @GET("system/logs")
    suspend fun logDays(): McEnvelope<LogDayList>

    @GET("system/logs/{day}")
    suspend fun logContent(@Path("day") day: String): McEnvelope<LogContent>

    /** 列出服务器上某个目录下有哪些子目录（只读；服务端 `fs.browse`） */
    @GET("fs/browse")
    suspend fun fsBrowse(@Query("path") path: String? = null): McEnvelope<FsBrowseView>

    @GET("network/config")
    suspend fun networkConfig(): McEnvelope<NetworkConfig>

    @PUT("network/config")
    suspend fun saveNetworkConfig(@Body body: NetworkConfig): McEnvelope<NetworkConfig>

    @POST("network/test")
    suspend fun testNetwork(): McEnvelope<NetworkTestResult>

    /* ---------------- 家庭成员(P2 设置区) ---------------- */

    @GET("members")
    suspend fun members(): McEnvelope<List<MemberView>>

    @POST("members")
    suspend fun createMember(@Body body: MemberCreateRequest): McEnvelope<MemberView>

    @PUT("members/{memberId}")
    suspend fun updateMember(
        @Path("memberId") memberId: Int,
        @Body body: MemberUpdateRequest,
    ): McEnvelope<MemberView>

    @PUT("members/{memberId}/status")
    suspend fun setMemberStatus(
        @Path("memberId") memberId: Int,
        @Body body: MemberStatusRequest,
    ): McEnvelope<MemberView>

    @POST("members/{memberId}/reset-password")
    suspend fun resetMemberPassword(@Path("memberId") memberId: Int): McEnvelope<MemberPasswordReset>

    @POST("members/{memberId}/sign-out")
    suspend fun signOutMember(@Path("memberId") memberId: Int): McEnvelope<JsonElement>

    @DELETE("members/{memberId}")
    suspend fun deleteMember(@Path("memberId") memberId: Int): McEnvelope<JsonElement>

    /* ---------------- 播放策略(M2b/P2 设置区) ---------------- */

    @POST("playback/metrics")
    suspend fun reportMetrics(@Body body: PlaybackMetricPayload): McEnvelope<JsonElement>

    @GET("playback/files/{fileId}/trickplay")
    suspend fun trickplay(
        @Path("fileId") fileId: Long,
        @Query("token") token: String,
    ): McEnvelope<TrickplayView>

    @GET("playback/policy")
    suspend fun playbackPolicy(): McEnvelope<PlaybackPolicy>

    @PUT("playback/policy")
    suspend fun updatePlaybackPolicy(@Body body: PlaybackPolicyPatchFull): McEnvelope<PlaybackPolicy>

    /** 批准设备登录：按配对码取一条待批准的接入请求（批准页数据源） */
    @GET("auth/devices/requests/{userCode}")
    suspend fun deviceRequest(
        @Path("userCode", encoded = true) userCode: String,
    ): McEnvelope<io.movieclaw.android.core.model.DeviceRequestView>

    /** 批准接入（此刻才签发令牌，令牌归属批准者） */
    @POST("auth/devices/requests/{userCode}/approve")
    suspend fun approveDeviceRequest(
        @Path("userCode", encoded = true) userCode: String,
    ): McEnvelope<JsonElement>

    /** 拒绝接入 */
    @POST("auth/devices/requests/{userCode}/deny")
    suspend fun denyDeviceRequest(
        @Path("userCode", encoded = true) userCode: String,
    ): McEnvelope<JsonElement>

    @DELETE("auth/devices/current")
    suspend fun logoutCurrentDevice(): McEnvelope<JsonElement>

    /** 库封面：服务端合成的「氛围光货架」拼贴（iOS LibraryHomeView 用同一张） */
    @GET("libraries/{libraryId}/cover")
    suspend fun libraryCover(
        @Path("libraryId") libraryId: Long,
        @Query("v") version: String? = null,
    ): okhttp3.ResponseBody

    /** 创建媒体库（该类型首个库自动成为默认，并自动开始首次扫描） */
    @POST("libraries")
    suspend fun createLibrary(
        @Body body: io.movieclaw.android.core.model.LibraryPayload,
    ): McEnvelope<LibraryView>

    /** 更新媒体库（类型创建后不可改；变更根路径时要求库空闲） */
    @PUT("libraries/{libraryId}")
    suspend fun updateLibrary(
        @Path("libraryId") libraryId: Long,
        @Body body: io.movieclaw.android.core.model.LibraryPayload,
    ): McEnvelope<LibraryView>

    @GET("libraries")
    suspend fun libraries(): McEnvelope<List<LibraryView>>

    /* ---------------- 媒体库管理（管理页一库一行的 ⋯ 菜单） ---------------- */

    /** 扫描该库的根路径（后台执行）；已在扫会 409，UI 按 `scanning` 换成「停止扫描」 */
    @POST("libraries/{libraryId}/scan")
    suspend fun scanLibrary(@Path("libraryId") libraryId: Long): McEnvelope<JsonElement>

    /** 停止进行中的扫描（已入账的保留） */
    @POST("libraries/{libraryId}/scan/stop")
    suspend fun stopLibraryScan(@Path("libraryId") libraryId: Long): McEnvelope<JsonElement>

    /** 整库刷新元数据（全部已识别条目重刮，可恢复后台作业） */
    @POST("libraries/{libraryId}/metadata/refresh")
    suspend fun refreshLibraryMetadata(@Path("libraryId") libraryId: Long): McEnvelope<JsonElement>

    @POST("libraries/{libraryId}/metadata/refresh/stop")
    suspend fun stopLibraryMetadataRefresh(@Path("libraryId") libraryId: Long): McEnvelope<JsonElement>

    /** 生成整库章节场景图（force=true 已有的也重新生成） */
    @POST("libraries/{libraryId}/chapter-images")
    suspend fun generateLibraryChapters(
        @Path("libraryId") libraryId: Long,
        @Query("force") force: Boolean = false,
    ): McEnvelope<JsonElement>

    /** 开始整理：按规范命名批量改名归位（改名直落磁盘，调用前应先看预览） */
    @POST("libraries/{libraryId}/file-organizations")
    suspend fun organizeLibrary(@Path("libraryId") libraryId: Long): McEnvelope<JsonElement>

    /** 设为该类型的默认库 */
    @POST("libraries/{libraryId}/default-selection")
    suspend fun setDefaultLibrary(@Path("libraryId") libraryId: Long): McEnvelope<JsonElement>

    /** 重排媒体库展示顺序：必须一次给全所有库的 id（漏/多/重复都拒绝） */
    @PUT("libraries/display-order")
    suspend fun reorderLibraries(@Body body: JsonElement): McEnvelope<JsonElement>

    /** 删除媒体库（不动磁盘文件；其订阅回落到该类型默认库；扫描/整理中会 409） */
    @DELETE("libraries/{libraryId}")
    suspend fun deleteLibrary(@Path("libraryId") libraryId: Long): McEnvelope<JsonElement>

    /* ---------------- 刷片 / 片段（docs/design/reels.md） ---------------- */

    /**
     * 取一页片段。第一页不带 seed，服务端生成后随响应返回；翻页时原样带回。
     * 筛选与媒体库同一组参数（g/c/d/rating_gte/rt/w），外加 kind。
     */
    @GET("reels")
    suspend fun reels(
        @Query("seed") seed: Long? = null,
        @Query("offset") offset: Int = 0,
        @Query("limit") limit: Int = 10,
        /** App 会放的方式；一期只有 seek（为将来预剪的 clip 留口子） */
        @Query("modes") modes: String = "seek",
        @Query("kind") kind: String? = null,
        @Query("g") genres: String? = null,
        @Query("c") countries: String? = null,
        @Query("d") decades: String? = null,
        @Query("rating_gte") ratingGte: Float? = null,
        @Query("rt") runtimes: String? = null,
        @Query("w") watch: String? = null,
    ): McEnvelope<io.movieclaw.android.core.model.ReelFeedView>

    /** 刷片筛选菜单的候选值与计数（与 /reels 同一组参数；为 0 的档 UI 置灰） */
    @GET("reels/facets")
    suspend fun reelFacets(
        @Query("kind") kind: String? = null,
        @Query("g") genres: String? = null,
        @Query("c") countries: String? = null,
        @Query("d") decades: String? = null,
        @Query("rating_gte") ratingGte: Float? = null,
        @Query("rt") runtimes: String? = null,
        @Query("w") watch: String? = null,
    ): McEnvelope<io.movieclaw.android.core.model.ReelFacetsView>

    /** 刷片事件批量上报（只落 reel_event 表，不写观看记录；失败即丢） */
    @POST("reels/events")
    suspend fun reportReelEvents(
        @Body body: io.movieclaw.android.core.model.ReelEventBatch,
    ): McEnvelope<io.movieclaw.android.core.model.ReelEventResult>

    @GET("libraries/{libraryId}/items")
    suspend fun libraryItems(
        @Path("libraryId") libraryId: Long,
        @Query("limit") limit: Int = 60,
        @Query("offset") offset: Int = 0,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
        @Query("g") genres: String? = null,
        @Query("c") countries: String? = null,
        @Query("d") decades: String? = null,
        @Query("w") watch: String? = null,
        @Query("rating_gte") ratingGte: Float? = null,
        @Query("rt") runtimes: String? = null,
        @Query("lang") languages: String? = null,
        @Query("res") resolutions: String? = null,
        @Query("hdr") hdr: Boolean? = null,
        @Query("stock") stock: String? = null,
    ): McEnvelope<List<LibraryItemView>>

    /**
     * 按类型的跨库墙概况（首页「全部电影」行与墙页头）：由可见、没被排除出首页的
     * 同类型库聚合，同一部片跨库只算一部。
     * `g` = 按 TMDB 类型收窄（首页类型色块的落点墙用它，页头计数要跟着筛后口径走，
     * 与 Web / iOS 同一条参数、同一个接口）。
     */
    @GET("libraries/kinds/{kind}")
    suspend fun libraryKindSummary(
        @Path("kind") kind: String,
        @Query("w") watch: String? = null,
        @Query("g") genres: String? = null,
    ): McEnvelope<io.movieclaw.android.core.model.LibraryKindSummaryView>

    /** 按类型的跨库海报墙（首页类型行 + 点「查看全部」进去的那面墙）；每格自带落点库 */
    /** 首页「按类型找电影 / 剧集」色块：一个 TMDB 类型 + 跨库部数 + 最近入库的封面剧照 */
    @GET("libraries/kinds/{kind}/genres")
    suspend fun libraryKindGenres(
        @Path("kind") kind: String,
    ): McEnvelope<List<io.movieclaw.android.core.model.LibraryKindGenreView>>

    @GET("libraries/kinds/{kind}/items")
    suspend fun libraryKindItems(
        @Path("kind") kind: String,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
        @Query("limit") limit: Int = 60,
        @Query("offset") offset: Int = 0,
        @Query("w") watch: String? = null,
        /** TMDB genre id（逗号分隔，维内 OR）——色块点进来带 g=value 开墙 */
        @Query("g") genres: String? = null,
    ): McEnvelope<List<LibraryItemView>>

    /** 筛选面板候选值与计数(与 /items 共用同一组筛选参数) */
    @GET("libraries/{libraryId}/facets")
    suspend fun libraryFacets(
        @Path("libraryId") libraryId: Long,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
        @Query("g") genres: String? = null,
        @Query("c") countries: String? = null,
        @Query("d") decades: String? = null,
        @Query("w") watch: String? = null,
        @Query("rating_gte") ratingGte: Float? = null,
        @Query("rt") runtimes: String? = null,
        @Query("lang") languages: String? = null,
        @Query("res") resolutions: String? = null,
        @Query("hdr") hdr: Boolean? = null,
        @Query("stock") stock: String? = null,
    ): McEnvelope<LibraryFacets>

    /** 海报墙跳转索引(sort/order 必须与 /items 一致,offset 才对得上) */
    @GET("libraries/{libraryId}/item-index")
    suspend fun libraryItemIndex(
        @Path("libraryId") libraryId: Long,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
        @Query("g") genres: String? = null,
        @Query("c") countries: String? = null,
        @Query("d") decades: String? = null,
        @Query("w") watch: String? = null,
        @Query("rating_gte") ratingGte: Float? = null,
        @Query("rt") runtimes: String? = null,
        @Query("lang") languages: String? = null,
        @Query("res") resolutions: String? = null,
        @Query("hdr") hdr: Boolean? = null,
        @Query("stock") stock: String? = null,
    ): McEnvelope<List<LibraryIndexEntry>>

    @GET("libraries/{libraryId}/items/{itemId}")
    suspend fun libraryItemDetail(
        @Path("libraryId") libraryId: Long,
        @Path("itemId") itemId: Long,
    ): McEnvelope<LibraryItemDetailView>

    @GET("libraries/{libraryId}/items/{itemId}/episodes")
    suspend fun seasonEpisodes(
        @Path("libraryId") libraryId: Long,
        @Path("itemId") itemId: Long,
        @Query("season_number") seasonNumber: Int,
    ): McEnvelope<SeasonEpisodesView>

    @GET("playback/up-next")
    suspend fun upNext(@Query("limit") limit: Int = 24): McEnvelope<UpNextView>

    @POST("playback/sessions")
    suspend fun startPlaybackSession(@Body body: PlaybackSessionRequest): McEnvelope<PlaybackSessionView>

    @POST("playback/sessions/{sessionId}/ping")
    suspend fun pingPlaybackSession(@Path("sessionId") sessionId: String): McEnvelope<JsonElement>

    @DELETE("playback/sessions/{sessionId}")
    suspend fun stopPlaybackSession(@Path("sessionId") sessionId: String): McEnvelope<JsonElement>

    /* ---------------- 收藏 / 合集 / 回收站 / 重复文件 ---------------- */

    /**
     * 我的收藏。首页横滚行用 `unwatchedFirst = true`（把还没看完的整体提前）+ 前 20 条；
     * 「全部收藏」海报墙按 offset 滚动加载、排序档与单库海报墙对齐（sort / order）。
     */
    @GET("playback/favorites")
    suspend fun favorites(
        @Query("limit") limit: Int = 60,
        @Query("offset") offset: Int = 0,
        @Query("unwatched_first") unwatchedFirst: Boolean = false,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
    ): McEnvelope<io.movieclaw.android.core.model.FavoritesPageView>

    /**
     * 「我的收藏」图廊（图床浏览模式）：与 [favorites] 同一份名单与顺序（sort / order 传同一个值），
     * 一组 = 一部作品的全部图（海报 / 剧照 / 分集剧照 / 章节场景图），**按作品分页**。
     * 没有任何图的作品也占一组，一页的组数恒等于作品数。
     */
    @GET("playback/favorites/gallery")
    suspend fun favoritesGallery(
        @Query("limit") limit: Int = 24,
        @Query("offset") offset: Int = 0,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
    ): McEnvelope<List<LibraryGalleryGroupView>>

    /**
     * 合集列表。返回的是**数组**（`data: CollectionView[]`，不是分页对象）。
     * 默认不返回成员为 0 的合集——点进去空无一物的合集是纯粹的死路，只有管理界面才需要 includeEmpty。
     */
    @GET("collections")
    suspend fun collections(
        @Query("library_id") libraryId: Long? = null,
        @Query("include_empty") includeEmpty: Boolean? = null,
        @Query("include_hidden") includeHidden: Boolean? = null,
    ): McEnvelope<List<io.movieclaw.android.core.model.CollectionView>>

    @GET("collections/{collectionId}")
    suspend fun collection(
        @Path("collectionId") id: Long,
    ): McEnvelope<io.movieclaw.android.core.model.CollectionView>

    /** 合集成员：与单库海报墙同一份聚合，卡片因此长得一模一样（首页合集行也用这个） */
    @GET("collections/{collectionId}/items")
    suspend fun collectionItems(
        @Path("collectionId") id: Long,
        @Query("limit") limit: Int = 60,
        @Query("offset") offset: Int = 0,
        @Query("sort") sort: String? = null,
        @Query("order") order: String? = null,
    ): McEnvelope<List<io.movieclaw.android.core.model.LibraryItemView>>

    @GET("libraries/trashed-files")
    suspend fun trashedFiles(): McEnvelope<JsonElement>

    @POST("libraries/trashed-files/restore")
    suspend fun restoreTrashed(@Body body: JsonElement): McEnvelope<JsonElement>

    @GET("libraries/duplicate-files")
    suspend fun duplicateFiles(): McEnvelope<JsonElement>

    @POST("libraries/duplicate-files/scan")
    suspend fun scanDuplicates(): McEnvelope<JsonElement>

    /* ---------------- 条目内单个文件（详情页文件区的三个动作，iOS `LibraryItemDetailView` 同款） ---------------- */

    /**
     * 从磁盘删除条目的单个文件（含同名 NFO/字幕/图片附属文件）。
     * 该条目在本库只剩这一行台账（含缺失行）时，服务端会升级为**整条目删除**——
     * 结果里的 `errors` 为空即表示删成功了，调用方据「是不是最后一个文件」决定要不要离开详情页。
     */
    @DELETE("libraries/{libraryId}/items/{mediaItemId}/files/{fileId}")
    suspend fun deleteLibraryFile(
        @Path("libraryId") libraryId: Long,
        @Path("mediaItemId") mediaItemId: Long,
        @Path("fileId") fileId: Long,
        /** 勾选的附加选项键（逗号分隔）；没勾不传，旧服务端不认识也不受影响 */
        @Query("options") options: String? = null,
    ): McEnvelope<io.movieclaw.android.core.model.ItemDeleteResultView>

    /** 删除前预览：删除弹窗里的附加选项（各自勾上会发生什么）。只读 */
    @GET("libraries/{libraryId}/items/{mediaItemId}/delete-preview")
    suspend fun deletePreview(
        @Path("libraryId") libraryId: Long,
        @Path("mediaItemId") mediaItemId: Long,
        /** 只删这个文件时传；不传 = 删除整部 */
        @Query("file_id") fileId: Long? = null,
    ): McEnvelope<io.movieclaw.android.core.model.ItemDeletePreviewView>

    /** 立即清理一个待回收的文件（真删磁盘，不等保留期） */
    @POST("libraries/{libraryId}/items/{mediaItemId}/files/{fileId}/purge")
    suspend fun purgeLibraryFile(
        @Path("libraryId") libraryId: Long,
        @Path("mediaItemId") mediaItemId: Long,
        @Path("fileId") fileId: Long,
    ): McEnvelope<JsonElement>

    /** 把待回收的文件恢复为在位版本 */
    @POST("libraries/{libraryId}/items/{mediaItemId}/files/{fileId}/restore")
    suspend fun restoreLibraryFile(
        @Path("libraryId") libraryId: Long,
        @Path("mediaItemId") mediaItemId: Long,
        @Path("fileId") fileId: Long,
    ): McEnvelope<JsonElement>

    /* ---------------- 条目状态：已看 / 收藏 ---------------- */

    /**
     * 目标的已看 / 收藏状态（详情页心与对勾的初始态）。
     * 与 Jellyfin 的 UserPlayedItems / UserFavoriteItems 同一个服务：
     * Infuse 里看到的与这里点的完全一致。
     */
    @GET("playback/marks")
    suspend fun playbackMarks(
        @Query("media_item_id") mediaItemId: Long,
        @Query("season_number") seasonNumber: Int? = null,
        @Query("episode_number") episodeNumber: Int? = null,
    ): McEnvelope<PlaybackMarks>

    /** 标记已看 / 收藏；**只传要改的那一项**，服务端返回写完后的状态。 */
    @POST("playback/marks")
    suspend fun setPlaybackMarks(@Body body: PlaybackMarksRequest): McEnvelope<PlaybackMarks>

    /**
     * 取一条字幕的内容（libass 渲染用）。
     * track 是中性轨引用：`external:<文件名>` / `embedded:<序号>`；
     * token 用会话流地址里的**签名令牌**（与取流同一个）。
     * 返回原始字节（可能是 SRT / ASS），交给 SubtitleAss 统一成 ASS。
     *
     * `startMs/endMs`（文件时间）走**窗口抽取**：只抽这一段。内封轨整轨要服务端通读
     * 整个容器（实测 5.7 GB / 39.7 秒），窗口走单独的闸门、几秒就回来——先用它把
     * 字幕画上，整轨到了再整表替换。整轨已有缓存时窗口直接给整轨。
     */
    @retrofit2.http.Streaming
    @GET("playback/files/{fileId}/subtitles")
    suspend fun subtitleContent(
        @Path("fileId") fileId: Long,
        @Query("track") track: String,
        @Query("token") token: String,
        @Query("format") format: String? = null,
        @Query("start_ms") startMs: Long? = null,
        @Query("end_ms") endMs: Long? = null,
    ): okhttp3.ResponseBody

    /**
     * 内封字幕预热：服务端登记后**立即返回**（`pending`），后台把这条轨抽好落缓存。
     * 与播放旁挂共用同一份产物；**不随请求断开取消**——快速切集、离开播放页也不白读
     * （服务端 `subtitles/preview`，详情页的字幕徽章用的是同一个口子）。
     */
    @GET("libraries/files/{fileId}/subtitles/preview")
    suspend fun subtitlePreview(
        @Path("fileId") fileId: Long,
        @Query("track") track: String,
    ): McEnvelope<JsonElement>

    /**
     * AI 字幕生成·预检（管理员）：只读 DB 与现成产物、**不读视频**——客户端 20 秒超时，
     * 超了就是异常。参数变了就重发（客户端要先把在途请求掐掉，免得同一大文件起多次抽取）。
     */
    @GET("libraries/files/{fileId}/subtitles/generation-preview")
    suspend fun subtitleGenerationPreview(
        @Path("fileId") fileId: Long,
        @Query("target_language") targetLanguage: String = "chs",
        @Query("secondary_language") secondaryLanguage: String? = null,
        @Query("source_candidate_key") sourceCandidateKey: String? = null,
    ): McEnvelope<io.movieclaw.android.core.model.SubtitleGenPreviewView>

    /** AI 字幕生成·启动（管理员）：202 + 任务视图；同参数的重复请求会返回既有任务 */
    @POST("libraries/files/{fileId}/subtitles/generations")
    suspend fun startSubtitleGeneration(
        @Path("fileId") fileId: Long,
        @Body body: io.movieclaw.android.core.model.SubtitleGenStartPayload,
    ): McEnvelope<JobView>

    /** 删除一条外挂字幕（含 AI 产物）；filename 是不含目录的文件名 */
    @DELETE("libraries/files/{fileId}/subtitles")
    suspend fun deleteFileSubtitle(
        @Path("fileId") fileId: Long,
        @Query("filename") filename: String,
    ): McEnvelope<JsonElement>

    @POST("playback/progress")
    suspend fun reportProgress(@Body body: PlaybackProgressRequest): McEnvelope<PlaybackStateView>

    /** 观看统计（管理员）：当前周期与上一周期成对返回，还有逐日与"星期×小时"矩阵 */
    /** 立即换种：为这条停滞的下载找同品质替代源（旧任务保留到新源产生真实进度） */
    @POST("downloaders/{downloaderId}/torrents/{infoHash}/replace")
    suspend fun replaceDownloadTask(
        @Path("downloaderId") downloaderId: Int,
        @Path("infoHash") infoHash: String,
    ): McEnvelope<JsonElement>

    /** 删除下载任务；deleteFiles=true 时连已下载文件一起删（默认不删） */
    @DELETE("downloaders/{downloaderId}/torrents/{infoHash}")
    suspend fun deleteDownloadTask(
        @Path("downloaderId") downloaderId: Int,
        @Path("infoHash") infoHash: String,
        @Query("delete_files") deleteFiles: Boolean = false,
    ): McEnvelope<JsonElement>

    @GET("playback/stats/watch")
    suspend fun playbackWatchStats(
        @Query("days") days: Int = 7,
        @Query("tz_offset") tzOffsetMinutes: Int = 480,
        @Query("scope") scope: String = "visible",
        /** 钻取到某个成员；null = 全部 */
        @Query("member_id") memberId: Int? = null,
    ): McEnvelope<PlaybackWatchStatsView>

    /** 播放流水（管理员）：谁、什么时候、看了什么、看了多久 */
    @GET("playback/history")
    suspend fun playbackHistory(
        @Query("limit") limit: Int = 20,
        @Query("before") before: Long? = null,
    ): McEnvelope<PlaybackHistoryView>

    @GET("playback/resume")
    suspend fun resumeState(
        @Query("media_item_id") mediaItemId: Long,
        @Query("season_number") seasonNumber: Int = 0,
        @Query("episode_number") episodeNumber: Int = 0,
    ): McEnvelope<PlaybackStateView>

    @PUT("playback/policy")
    suspend fun savePlaybackPolicy(@Body body: PlaybackPolicyPatch): McEnvelope<JsonElement>

    /* ---------------- 搜索(M2) ---------------- */

    @POST("search/titles")
    suspend fun searchTitles(@Body body: TitleSearchRequest): McEnvelope<TitleSearchView>

    @GET("search/library-items")
    suspend fun searchLibraryItems(@Query("keyword") keyword: String): McEnvelope<List<LibrarySearchGroup>>

    /**
     * 媒体库搜索（v0.31 起三端同一份）：相关度排序、人物单独成行、命中原因、
     * 游标分页。旧的 `/search/library-items` 已被服务端**删除**——连老接口的客户端
     * 在 v0.31 服务器上会直接 404。
     */
    @GET("search/library")
    suspend fun searchLibrary(
        @Query("q") q: String,
        /** 选定人物（点人物行下钻：只看这个人的库内作品） */
        @Query("person_id") personId: Int? = null,
        @Query("limit") limit: Int = 24,
        @Query("cursor") cursor: String? = null,
    ): McEnvelope<io.movieclaw.android.core.model.LibrarySearchView>

    @GET("search/history")
    suspend fun searchHistory(): McEnvelope<List<SearchHistoryItem>>

    @DELETE("search/history")
    suspend fun clearSearchHistory(): McEnvelope<JsonElement>

    @DELETE("search/history/{historyId}")
    suspend fun deleteSearchHistory(@Path("historyId") historyId: Long): McEnvelope<JsonElement>

    /* ---------------- 下载提交 / 落点预检 ---------------- */

    @POST("downloaders/submit")
    suspend fun submitDownload(
        @Body body: DownloadSubmitRequest,
    ): McEnvelope<io.movieclaw.android.core.model.DownloadSubmitView>

    /** 手动下载弹窗的只读预检：识别条目 → 库路由 → 投递目录（成员只提交 library_id） */
    @POST("downloaders/resolve-target")
    suspend fun resolveDownloadTarget(
        @Body body: io.movieclaw.android.core.model.ManualDownloadTargetRequest,
    ): McEnvelope<io.movieclaw.android.core.model.ManualDownloadTargetView>

    /** 我的保存位置记忆（按种子分类）；有记忆时点「下载」先弹确认条 */
    @GET("downloaders/target-prefs")
    suspend fun downloadTargetPrefs(): McEnvelope<List<io.movieclaw.android.core.model.DownloadTargetPrefView>>

    /** 「不再记住」某个分类的保存位置（幂等） */
    @DELETE("downloaders/target-prefs/{category}")
    suspend fun forgetDownloadTargetPref(
        @Path("category") category: String,
    ): McEnvelope<JsonElement>

    /** 下载器列表（脱敏）：落点弹窗的「其他保存位置」用它列目录候选 */
    @GET("downloaders")
    suspend fun downloaders(): McEnvelope<List<io.movieclaw.android.core.model.DownloaderView>>

    /** 手动选种：把搜索结果里选中一条种子投给订阅（跳过规则组过滤，身份匹配照常） */
    @POST("subscriptions/{subscriptionId}/selected-torrent-downloads")
    suspend fun grabSubscriptionTorrent(
        @Path("subscriptionId") subscriptionId: Long,
        @Body body: io.movieclaw.android.core.model.GrabPayload,
    ): McEnvelope<io.movieclaw.android.core.model.GrabResultView>

    /* ---------------- 通知中心 ---------------- */

    @GET("system/notices")
    suspend fun notices(): McEnvelope<List<Notice>>

    @POST("system/notices/{noticeId}/dismiss")
    suspend fun dismissNotice(@Path("noticeId") noticeId: Long): McEnvelope<JsonElement>

    /* ---------------- 订阅(M2b) ---------------- */

    @GET("subscriptions")
    suspend fun subscriptions(): McEnvelope<List<SubscriptionView>>

    @GET("subscriptions/today-arrivals")
    suspend fun todayArrivalsFull(
        /**
         * focus=只回最近有安排的那一天（网页首页「今日可能入库」）；
         * week=整周按日期原样返回——订阅首页的 Hero 轮播与「日程」日期条都要整周，
         * iOS 订阅首页用的就是 `window: "week"`（服务端 `subscriptions.list-today-arrivals`）
         */
        @Query("window") window: String = "week",
    ): McEnvelope<List<io.movieclaw.android.core.model.TodayArrivalFull>>

    @GET("subscriptions/recent-arrivals")
    suspend fun recentArrivals(
        @Query("days") days: Int = 7,
        @Query("limit") limit: Int = 12,
    ): McEnvelope<List<io.movieclaw.android.core.model.RecentArrivalView>>

    @GET("subscriptions/today-arrivals")
    suspend fun todayArrivals(): McEnvelope<List<TodayArrival>>

    @GET("subscriptions/automation-readiness")
    suspend fun automationReadiness(): McEnvelope<PipelineHealth>

    @POST("subscriptions/title-preview")
    suspend fun titlePreview(@Body body: TitlePreviewRequest): McEnvelope<PrepareView>

    @POST("subscriptions")
    suspend fun createSubscription(@Body body: SubscriptionCreateRequest): McEnvelope<SubscriptionCreateView>

    @GET("subscriptions/{subscriptionId}")
    suspend fun subscription(@Path("subscriptionId") subscriptionId: Long): McEnvelope<SubscriptionView>

    /**
     * 部分更新：不传的字段保持不变。**用 JsonObject 而不是数据类**——全局 Json 开了
     * encodeDefaults，数据类会把没设的字段一并序列化成 null，而 `library_id: null`
     * 在服务端是"清除指定库、回到默认路由"的意思（不是"不变"），会误伤。
     */
    @PATCH("subscriptions/{subscriptionId}")
    suspend fun updateSubscription(
        @Path("subscriptionId") subscriptionId: Long,
        @Body body: kotlinx.serialization.json.JsonObject,
    ): McEnvelope<kotlinx.serialization.json.JsonElement>

    /** 投递路由预检（管理员）：选库/选规则组时即时提示"下载会落到哪、能否自动入库" */
    @GET("subscriptions/download-routing-preview")
    suspend fun downloadRoutingPreview(
        @Query("kind") kind: String,
        @Query("library_id") libraryId: Long? = null,
        @Query("tmdb_id") tmdbId: Int? = null,
        @Query("title") title: String? = null,
        @Query("year") year: Int? = null,
    ): McEnvelope<DispatchPreviewView>

    @GET("rule-sets")
    suspend fun ruleSets(): McEnvelope<List<RuleSetView>>

    @PATCH("subscriptions/{subscriptionId}/follow-future")
    suspend fun setFollowFuture(
        @Path("subscriptionId") subscriptionId: Long,
        @Body body: FollowFutureRequest,
    ): McEnvelope<JsonElement>

    @GET("subscriptions/{subscriptionId}/activities")
    suspend fun subscriptionActivities(
        @Path("subscriptionId") id: Long,
        @Query("limit") limit: Int = 50,
    ): McEnvelope<List<io.movieclaw.android.core.model.SubActivityView>>

    /**
     * 在途种子的实时下载快照（详情页 5 秒轮询；无在途时零请求）。
     * 成员也能读自己发起/关注的订阅，但服务端把种子名、下载器名与报错置空——
     * 只给进度、速度与剩余时间。
     */
    @GET("subscriptions/{subscriptionId}/active-downloads")
    suspend fun activeDownloads(
        @Path("subscriptionId") id: Long,
    ): McEnvelope<List<io.movieclaw.android.core.model.SubscriptionDownloadView>>

    @POST("subscriptions/{subscriptionId}/missing-resource-searches")
    suspend fun searchMissingResources(@Path("subscriptionId") id: Long): McEnvelope<JsonElement>

    /** 触发一轮洗版；`rule_set_id` 只有超管会被服务端采纳（成员走「沿用当前规则组」的路） */
    @POST("subscriptions/{subscriptionId}/upgrade-runs")
    suspend fun upgradeRun(
        @Path("subscriptionId") id: Long,
        @Body body: io.movieclaw.android.core.model.UpgradeRunPayload,
    ): McEnvelope<UpgradeRunView>

    @PATCH("subscriptions/{subscriptionId}/tracking-state")
    suspend fun setTrackingState(
        @Path("subscriptionId") id: Long,
        @Body body: io.movieclaw.android.core.model.TrackingStateRequest,
    ): McEnvelope<JsonElement>

    @DELETE("subscriptions/{subscriptionId}")
    suspend fun deleteSubscription(@Path("subscriptionId") subscriptionId: Long): McEnvelope<JsonElement>

    /* ---------------- 活动中心(M2b) ---------------- */

    @GET("jobs")
    suspend fun jobs(
        @Query("active_only") activeOnly: Boolean = false,
        /** 只要某一类任务（如 `subtitle.generate`） */
        @Query("job_type") jobType: String? = null,
        /** 按资源过滤（`library_file` + resource_id = 文件台账 id） */
        @Query("resource_type") resourceType: String? = null,
        @Query("resource_id") resourceId: Long? = null,
        @Query("status") status: String? = null,
        @Query("limit") limit: Int? = null,
    ): McEnvelope<JobListView>

    /** 单个任务的当前状态（删除附加选项的后续任务等跟进用） */
    @GET("jobs/{jobId}")
    suspend fun job(@Path("jobId") jobId: String): McEnvelope<JobView>

    /** 停止任务：返回 `{cancelled, job}`，job 是停止请求之后的任务快照 */
    @POST("jobs/{jobId}/cancel")
    suspend fun cancelJob(@Path("jobId") jobId: String): McEnvelope<io.movieclaw.android.core.model.JobCancelView>

    @POST("jobs/{jobId}/retry")
    suspend fun retryJob(@Path("jobId") jobId: String): McEnvelope<JsonElement>

    @POST("jobs/{jobId}/dismiss")
    suspend fun dismissJob(@Path("jobId") jobId: String): McEnvelope<JsonElement>

    /** 撤销忽略：把这条从「已结束」里放回「需要处理」 */
    @POST("jobs/{jobId}/undismiss")
    suspend fun undismissJob(@Path("jobId") jobId: String): McEnvelope<JsonElement>

    /** 一次忽略所有失败任务（网页「全部忽略」） */
    @POST("jobs/dismiss-all")
    suspend fun dismissAllJobs(): McEnvelope<JsonElement>

    @GET("downloaders/tasks")
    suspend fun downloadTasks(): McEnvelope<DownloadTaskList>

    @GET("playback/activity")
    suspend fun playbackActivity(@Query("scope") scope: String = "visible"): McEnvelope<PlaybackActivityView>

    @POST("playback/activity/sessions/{deviceId}/end")
    suspend fun endPlaybackSession(@Path("deviceId") deviceId: String): McEnvelope<JsonElement>

    /* ---------------- 发现页与标题详情(M2c) ---------------- */

    /**
     * 界面偏好（按页面分组的样式设定）。`home.rows` 就是媒体库首页的行清单——
     * 自定义首页页读它、改它，返回首页立即生效（iOS LibraryHomePrefs 同一份）。
     */
    @GET("ui/preferences")
    suspend fun uiPreferences(): McEnvelope<io.movieclaw.android.core.model.UiPreferencesSetting>

    /**
     * 保存界面偏好。后端是**整体覆盖**：调用方要以刚拉到的完整偏好为底，只换 `home.rows`——
     * 只发一个 home 会把主题 / 侧栏 / 蒙版 / 主导航都写回默认值。
     */
    @PUT("ui/preferences")
    suspend fun updateUiPreferences(
        @Body body: io.movieclaw.android.core.model.UiPreferencesSetting,
    ): McEnvelope<io.movieclaw.android.core.model.UiPreferencesSetting>

    /**
     * 发现页展示编排（分区引用与呈现方式）。服务端这条路由**只认 provider**
     * （`/ui/discovery/{media_type}?provider=`，网页与 iOS 也只发它）——筛选不走这里，
     * 条件生效时正文换成 [discoverTitles] 的结果网格。
     */
    @GET("ui/discovery/{mediaType}")
    suspend fun discoveryPage(
        @Path("mediaType") mediaType: String,
        /** tmdb / douban */
        @Query("provider") source: String? = null,
    ): McEnvelope<DiscoveryPage>

    /** 发现页筛选（chips 用的可选值：类型/国家/年份/评分/片长） */
    @GET("discover/filters")
    suspend fun discoveryFilters(@Query("media_type") mediaType: String = "movie"): McEnvelope<JsonElement>

    /**
     * 筛选结果（服务端 `discover.filter-titles`：TMDB 原生 discover 分页 + 平铺列表）。
     * 参数名逐项对齐契约——**此前这四个名字都是错的**（`genres`/`country`/`rating`/`runtime`），
     * 服务端对不认识的参数静默忽略，表现就是「条件点了没反应」：
     * `genre_ids` 是**重复参数**（`genre_ids=35&genre_ids=18`，不是逗号串）、`origin_country`
     * （ISO 两字母）、`rating_gte`、`runtime_lte`。这条路由是 TMDB 专属，**没有** provider/source
     * 参数——豆瓣源不给筛选（见 DiscoverScreen 按 tmdb 收窄入口）。
     */
    @GET("discover/titles")
    suspend fun discoverTitles(
        @Query("media_type") mediaType: String = "movie",
        @Query("genre_ids") genreIds: List<String>? = null,
        @Query("origin_country") originCountry: String? = null,
        @Query("year") year: String? = null,
        @Query("rating_gte") ratingGte: String? = null,
        @Query("runtime_lte") runtimeLte: String? = null,
        @Query("sort") sort: String? = null,
        @Query("page") page: Int = 1,
    ): McEnvelope<JsonElement>

    /** TMDB 影人页 */
    @GET("discover/people/{tmdbPersonId}")
    suspend fun discoveredPerson(@Path("tmdbPersonId") id: Int): McEnvelope<JsonElement>

    /** 库内影人页 */
    @GET("people/{tmdbPersonId}")
    suspend fun libraryPerson(@Path("tmdbPersonId") id: Int): McEnvelope<JsonElement>

    @GET("discover/collections/{collectionRef}/titles")
    suspend fun collectionTitles(
        @Path("collectionRef", encoded = true) collectionRef: String,
        @Query("limit") limit: Int = 24,
        @Query("page") page: Int = 1,
    ): McEnvelope<CollectionTitles>

    /** title_ref 形如 tmdb:movie:123 / douban:456,原样透传(encoded = true) */
    @GET("discover/titles/{titleRef}")
    suspend fun titleDetails(
        @Path("titleRef", encoded = true) titleRef: String,
    ): McEnvelope<TitleDetails>

    /* ---------------- AI Agent 会话(M3) ---------------- */

    @GET("sessions")
    suspend fun sessions(
        @Query("limit") limit: Int = 50,
        @Query("offset") offset: Int = 0,
    ): McEnvelope<List<SessionSummary>>

    @GET("sessions/{sessionId}")
    suspend fun sessionTranscript(@Path("sessionId") sessionId: String): McEnvelope<SessionTranscript>

    /** session_id 留空 = 新建会话;传入 = 在既有会话里继续发消息 */
    @POST("sessions")
    suspend fun startAgentSession(@Body body: AgentSessionStart): McEnvelope<SessionAccepted>

    /**
     * 待处理事项 → Agent 诊断工单（`POST /agent-handoff`，网页 `lib/api/handoff.ts` 同款）。
     * 拿到的 `prompt` 直接作为新会话的首条消息提交给 `sessions`。
     */
    @POST("agent-handoff")
    suspend fun agentHandoff(@Body body: HandoffRequest): McEnvelope<HandoffPrompt>

    /** 已接入的模型供应商；**空数组 = 未配置**（AI 入口的门禁口径） */
    @GET("llm/providers")
    suspend fun llmProviders(): McEnvelope<List<io.movieclaw.android.core.model.LlmProviderView>>

    /** 可接入的供应商预设（含各自的模型目录） */
    @GET("llm/presets")
    suspend fun llmPresets(): McEnvelope<List<io.movieclaw.android.core.model.LlmPresetView>>

    /** 新建供应商；返回写入后的实例（API Key 不回传），状态先 pending、后台自动测试连接 */
    @POST("llm/providers")
    suspend fun createLlmProvider(
        @Body body: io.movieclaw.android.core.model.LlmProviderPayload,
    ): McEnvelope<io.movieclaw.android.core.model.LlmProviderView>

    /** 编辑供应商（每次都要重新填 API Key：已保存的密钥不回显） */
    @PUT("llm/providers/{providerId}")
    suspend fun updateLlmProvider(
        @Path("providerId") providerId: Int,
        @Body body: io.movieclaw.android.core.model.LlmProviderPayload,
    ): McEnvelope<io.movieclaw.android.core.model.LlmProviderView>

    /** 手动重测连接 */
    @POST("llm/providers/{providerId}/verify")
    suspend fun verifyLlmProvider(
        @Path("providerId") providerId: Int,
    ): McEnvelope<io.movieclaw.android.core.model.LlmProviderView>

    @DELETE("llm/providers/{providerId}")
    suspend fun deleteLlmProvider(@Path("providerId") providerId: Int): McEnvelope<JsonElement>

    @POST("sessions/{sessionId}/stop")
    suspend fun stopAgentSession(@Path("sessionId") sessionId: String): McEnvelope<JsonElement>

    @POST("sessions/{sessionId}/retry")
    suspend fun retryAgentSession(
        @Path("sessionId") sessionId: String,
        @Body body: SessionRetry,
    ): McEnvelope<SessionAccepted>

    @POST("sessions/{sessionId}/compact-context")
    suspend fun compactAgentContext(@Path("sessionId") sessionId: String): McEnvelope<JsonElement>

    /** 从已有上下文创建独立的新会话（`POST /sessions/{id}/fork`）；源会话保持不变 */
    @POST("sessions/{sessionId}/fork")
    suspend fun forkSession(
        @Path("sessionId") sessionId: String,
    ): McEnvelope<SessionTranscript>

    @PATCH("sessions/{sessionId}")
    suspend fun renameSession(
        @Path("sessionId") sessionId: String,
        @Body body: SessionRename,
    ): McEnvelope<JsonElement>

    @DELETE("sessions/{sessionId}")
    suspend fun deleteSession(@Path("sessionId") sessionId: String): McEnvelope<JsonElement>

    /* ---------------- 访客分享(P2) ---------------- */

    @GET("share/{slug}")
    suspend fun sharePublic(@Path("slug") slug: String): McEnvelope<SharePublic>

    @POST("share/{slug}/unlock")
    suspend fun shareUnlock(
        @Path("slug") slug: String,
        @Body body: ShareUnlockRequest,
    ): McEnvelope<SharePublic>

    @GET("share/{slug}/item")
    suspend fun shareItem(@Path("slug") slug: String): McEnvelope<SharedItem>

    @GET("share/{slug}/collection")
    suspend fun shareCollection(@Path("slug") slug: String): McEnvelope<SharedCollection>

    @GET("share/{slug}/episodes")
    suspend fun shareEpisodes(
        @Path("slug") slug: String,
        @Query("season_number") seasonNumber: Int,
    ): McEnvelope<SeasonEpisodesView>

    @POST("share/{slug}/playback/sessions")
    suspend fun startShareSession(
        @Path("slug") slug: String,
        @Body body: PlaybackSessionRequest,
    ): McEnvelope<PlaybackSessionView>

    @POST("share/{slug}/playback/progress")
    suspend fun shareProgress(
        @Path("slug") slug: String,
        @Body body: PlaybackProgressRequest,
    ): McEnvelope<PlaybackStateView>

    @POST("share/{slug}/playback/sessions/{sessionId}/ping")
    suspend fun pingShareSession(
        @Path("slug") slug: String,
        @Path("sessionId") sessionId: String,
    ): McEnvelope<JsonElement>

    @DELETE("share/{slug}/playback/sessions/{sessionId}")
    suspend fun stopShareSession(
        @Path("slug") slug: String,
        @Path("sessionId") sessionId: String,
    ): McEnvelope<JsonElement>

    @Multipart
    @POST("sessions/attachments")
    suspend fun uploadAgentAttachment(@Part file: MultipartBody.Part): McEnvelope<AgentAttachment>
}
