// 由 apps/android-tv/scripts/gen_api.py 生成，勿手改。重新生成见脚本头部说明。

package io.movieclaw.androidtv.core.network.generated

import io.movieclaw.androidtv.core.model.McJson
import io.movieclaw.androidtv.core.model.generated.*
import io.movieclaw.androidtv.core.network.ApiTransport
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.serializer

/** 服务端接口（白名单见生成脚本 ENDPOINTS）。
 * 路径相对 `/api/v1`，信封 `{data}` 已拆掉。 */
class McApi(private val transport: ApiTransport) {
    /** Health check（`GET /health`） */
    suspend fun healthCheck(): HealthResponse {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/health", query, null, serializer<HealthResponse>(), enveloped = false)
    }

    /** 查询系统是否已完成首次初始化（`GET /auth/bootstrap`） */
    suspend fun authBootstrapStatus(): BootstrapStatus {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/auth/bootstrap", query, null, serializer<BootstrapStatus>(), enveloped = true)
    }

    /** 原生 App 用账号密码登录，换取设备令牌（明文仅返回这一次）（`POST /auth/device/login`） */
    suspend fun authDeviceLogin(body: DeviceLoginRequest): DeviceLoginView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/auth/device/login", query, McJson.encodeToJsonElement(body), serializer<DeviceLoginView>(), enveloped = true)
    }

    /** 设备发起接入请求，取得配对码（匿名）（`POST /auth/device/authorize`） */
    suspend fun authDeviceAuthorize(body: DeviceAuthorizeRequest): DeviceAuthorizeView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/auth/device/authorize", query, McJson.encodeToJsonElement(body), serializer<DeviceAuthorizeView>(), enveloped = true)
    }

    /** 设备轮询兑换令牌（匿名）（`POST /auth/device/token`） */
    suspend fun authDeviceToken(body: DeviceTokenRequest): DeviceTokenView? {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/auth/device/token", query, McJson.encodeToJsonElement(body), serializer<DeviceTokenView?>(), enveloped = true)
    }

    /** 查询当前登录状态（`GET /auth/me`） */
    suspend fun authMe(): SessionView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/auth/me", query, null, serializer<SessionView>(), enveloped = true)
    }

    /** 注销当前这台设备（退出登录 / 断开配对）（`DELETE /auth/devices/current`） */
    suspend fun authDevicesRevokeCurrent(): Unit {
        val query = emptyList<Pair<String, String>>()
        transport.send("DELETE", "/auth/devices/current", query, null, serializer<JsonElement?>(), enveloped = true)
    }

    /** 接下来继续（`GET /playback/up-next`） */
    suspend fun playbackUpNext(limit: Long? = null, thisDevice: Boolean? = null): UpNextView {
        val query = buildList<Pair<String, String>> {
            limit?.let { add("limit" to it.toString()) }
            thisDevice?.let { add("this_device" to it.toString()) }
        }
        return transport.send("GET", "/playback/up-next", query, null, serializer<UpNextView>(), enveloped = true)
    }

    /** 我的收藏（`GET /playback/favorites`） */
    suspend fun playbackFavorites(limit: Long? = null, offset: Long? = null, unwatchedFirst: Boolean? = null, sort: String? = null, order: String? = null): FavoritesView {
        val query = buildList<Pair<String, String>> {
            limit?.let { add("limit" to it.toString()) }
            offset?.let { add("offset" to it.toString()) }
            unwatchedFirst?.let { add("unwatched_first" to it.toString()) }
            sort?.let { add("sort" to it.toString()) }
            order?.let { add("order" to it.toString()) }
        }
        return transport.send("GET", "/playback/favorites", query, null, serializer<FavoritesView>(), enveloped = true)
    }

    /** 读取界面偏好（按页面分组的样式设定）（`GET /ui/preferences`） */
    suspend fun uiPrefsShow(): UiPreferencesSetting {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/ui/preferences", query, null, serializer<UiPreferencesSetting>(), enveloped = true)
    }

    /** 列出媒体库（含库存统计，可按类型过滤；默认只列当前身份可浏览的库）（`GET /libraries`） */
    suspend fun libraryList(kind: String? = null, scope: String? = null): List<LibraryView> {
        val query = buildList<Pair<String, String>> {
            kind?.let { add("kind" to it.toString()) }
            scope?.let { add("scope" to it.toString()) }
        }
        return transport.send("GET", "/libraries", query, null, serializer<List<LibraryView>>(), enveloped = true)
    }

    /** 海报行选中展开用的展示信息（批量：剧照 / Logo / 类型 / 片长 / 分级 / 简介）（`GET /libraries/showcase`） */
    suspend fun uiLibraryShowcase(ids: List<Long>): List<LibraryItemShowcaseView> {
        val query = buildList<Pair<String, String>> {
            ids.forEach { add("ids" to it.toString()) }
        }
        return transport.send("GET", "/libraries/showcase", query, null, serializer<List<LibraryItemShowcaseView>>(), enveloped = true)
    }

    /** 按类型的跨库海报墙（同一部片跨库只出现一次）（`GET /libraries/kinds/{kind}/items`） */
    suspend fun uiLibraryKindItems(kind: String, sort: String? = null, order: String? = null, limit: Long? = null, offset: Long? = null, g: String? = null, c: String? = null, d: String? = null, w: String? = null, ratingGte: Double? = null, rt: String? = null, lang: String? = null, res: String? = null, hdr: Boolean? = null, stock: String? = null, seriesKeys: String? = null): List<LibraryItemView> {
        val query = buildList<Pair<String, String>> {
            sort?.let { add("sort" to it.toString()) }
            order?.let { add("order" to it.toString()) }
            limit?.let { add("limit" to it.toString()) }
            offset?.let { add("offset" to it.toString()) }
            g?.let { add("g" to it.toString()) }
            c?.let { add("c" to it.toString()) }
            d?.let { add("d" to it.toString()) }
            w?.let { add("w" to it.toString()) }
            ratingGte?.let { add("rating_gte" to it.toString()) }
            rt?.let { add("rt" to it.toString()) }
            lang?.let { add("lang" to it.toString()) }
            res?.let { add("res" to it.toString()) }
            hdr?.let { add("hdr" to it.toString()) }
            stock?.let { add("stock" to it.toString()) }
            seriesKeys?.let { add("series_keys" to it.toString()) }
        }
        return transport.send("GET", "/libraries/kinds/${kind}/items", query, null, serializer<List<LibraryItemView>>(), enveloped = true)
    }

    /** 按类型跨库的 TMDB 类型分布（首页「按类型找电影 / 剧集」色块）（`GET /libraries/kinds/{kind}/genres`） */
    suspend fun uiLibraryKindGenres(kind: String): List<LibraryKindGenreView> {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/libraries/kinds/${kind}/genres", query, null, serializer<List<LibraryKindGenreView>>(), enveloped = true)
    }

    /** 合集列表（按元数据可见性过滤，成员为空的不列）（`GET /collections`） */
    suspend fun collectionList(libraryId: Long? = null, includeEmpty: Boolean? = null, includeHidden: Boolean? = null): List<CollectionView> {
        val query = buildList<Pair<String, String>> {
            libraryId?.let { add("library_id" to it.toString()) }
            includeEmpty?.let { add("include_empty" to it.toString()) }
            includeHidden?.let { add("include_hidden" to it.toString()) }
        }
        return transport.send("GET", "/collections", query, null, serializer<List<CollectionView>>(), enveloped = true)
    }

    /** 合集成员（与单库海报墙同一份聚合）（`GET /collections/{collection_id}/items`） */
    suspend fun collectionItemsList(collectionId: Long, limit: Long? = null, offset: Long? = null, sort: String? = null, order: String? = null): List<LibraryItemView> {
        val query = buildList<Pair<String, String>> {
            limit?.let { add("limit" to it.toString()) }
            offset?.let { add("offset" to it.toString()) }
            sort?.let { add("sort" to it.toString()) }
            order?.let { add("order" to it.toString()) }
        }
        return transport.send("GET", "/collections/${collectionId}/items", query, null, serializer<List<LibraryItemView>>(), enveloped = true)
    }

    /** 系列合集的「已有 N / 共 M」与缺片名单（`GET /collections/{collection_id}/series`） */
    suspend fun collectionSeriesGet(collectionId: Long): CollectionSeriesView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/collections/${collectionId}/series", query, null, serializer<CollectionSeriesView>(), enveloped = true)
    }

    /** 库内媒体条目的库存聚合（单库海报墙数据源）（`GET /libraries/{library_id}/items`） */
    suspend fun libraryItemsList(libraryId: Long, sort: String? = null, order: String? = null, limit: Long? = null, offset: Long? = null, identity: String? = null, g: String? = null, c: String? = null, d: String? = null, w: String? = null, ratingGte: Double? = null, rt: String? = null, lang: String? = null, res: String? = null, hdr: Boolean? = null, stock: String? = null, seriesKeys: String? = null): List<LibraryItemView> {
        val query = buildList<Pair<String, String>> {
            sort?.let { add("sort" to it.toString()) }
            order?.let { add("order" to it.toString()) }
            limit?.let { add("limit" to it.toString()) }
            offset?.let { add("offset" to it.toString()) }
            identity?.let { add("identity" to it.toString()) }
            g?.let { add("g" to it.toString()) }
            c?.let { add("c" to it.toString()) }
            d?.let { add("d" to it.toString()) }
            w?.let { add("w" to it.toString()) }
            ratingGte?.let { add("rating_gte" to it.toString()) }
            rt?.let { add("rt" to it.toString()) }
            lang?.let { add("lang" to it.toString()) }
            res?.let { add("res" to it.toString()) }
            hdr?.let { add("hdr" to it.toString()) }
            stock?.let { add("stock" to it.toString()) }
            seriesKeys?.let { add("series_keys" to it.toString()) }
        }
        return transport.send("GET", "/libraries/${libraryId}/items", query, null, serializer<List<LibraryItemView>>(), enveloped = true)
    }

    /** 筛选面板的候选值与计数（每一维排除自身条件后算）（`GET /libraries/{library_id}/facets`） */
    suspend fun libraryItemsFacets(libraryId: Long, tier: String? = null, g: String? = null, c: String? = null, d: String? = null, w: String? = null, ratingGte: Double? = null, rt: String? = null, lang: String? = null, res: String? = null, hdr: Boolean? = null, stock: String? = null, seriesKeys: String? = null): LibraryFacetsView {
        val query = buildList<Pair<String, String>> {
            tier?.let { add("tier" to it.toString()) }
            g?.let { add("g" to it.toString()) }
            c?.let { add("c" to it.toString()) }
            d?.let { add("d" to it.toString()) }
            w?.let { add("w" to it.toString()) }
            ratingGte?.let { add("rating_gte" to it.toString()) }
            rt?.let { add("rt" to it.toString()) }
            lang?.let { add("lang" to it.toString()) }
            res?.let { add("res" to it.toString()) }
            hdr?.let { add("hdr" to it.toString()) }
            stock?.let { add("stock" to it.toString()) }
            seriesKeys?.let { add("series_keys" to it.toString()) }
        }
        return transport.send("GET", "/libraries/${libraryId}/facets", query, null, serializer<LibraryFacetsView>(), enveloped = true)
    }

    /** 条目详情：基本信息 + NFO 本地刮削元数据 + 逐文件真实介质规格（`GET /libraries/{library_id}/items/{media_item_id}`） */
    suspend fun libraryItemsGet(libraryId: Long, mediaItemId: Long): LibraryItemDetailView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/libraries/${libraryId}/items/${mediaItemId}", query, null, serializer<LibraryItemDetailView>(), enveloped = true)
    }

    /** 剧集条目一季的分集清单（集名/简介/剧照 + 拥有状态，分集横滚区数据源）（`GET /libraries/{library_id}/items/{media_item_id}/episodes`） */
    suspend fun libraryItemsListEpisodes(libraryId: Long, mediaItemId: Long, seasonNumber: Long): SeasonEpisodesView {
        val query = buildList<Pair<String, String>> {
            add("season_number" to seasonNumber.toString())
        }
        return transport.send("GET", "/libraries/${libraryId}/items/${mediaItemId}/episodes", query, null, serializer<SeasonEpisodesView>(), enveloped = true)
    }

    /** 人物页：库内这个影人的档案与作品（`GET /people/{tmdb_person_id}`） */
    suspend fun peopleShow(tmdbPersonId: Long): PersonView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/people/${tmdbPersonId}", query, null, serializer<PersonView>(), enveloped = true)
    }

    /** 续播点与记忆轨（`GET /playback/resume`） */
    suspend fun playbackResume(mediaItemId: Long, seasonNumber: Long? = null, episodeNumber: Long? = null): PlaybackStateView {
        val query = buildList<Pair<String, String>> {
            add("media_item_id" to mediaItemId.toString())
            seasonNumber?.let { add("season_number" to it.toString()) }
            episodeNumber?.let { add("episode_number" to it.toString()) }
        }
        return transport.send("GET", "/playback/resume", query, null, serializer<PlaybackStateView>(), enveloped = true)
    }

    /** 已看 / 收藏状态（`GET /playback/marks`） */
    suspend fun playbackMarksGet(mediaItemId: Long, seasonNumber: Long? = null, episodeNumber: Long? = null): PlaybackMarksView {
        val query = buildList<Pair<String, String>> {
            add("media_item_id" to mediaItemId.toString())
            seasonNumber?.let { add("season_number" to it.toString()) }
            episodeNumber?.let { add("episode_number" to it.toString()) }
        }
        return transport.send("GET", "/playback/marks", query, null, serializer<PlaybackMarksView>(), enveloped = true)
    }

    /** 标记已看 / 收藏（`POST /playback/marks`） */
    suspend fun playbackMarksSet(body: PlaybackMarksRequest): PlaybackMarksView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/playback/marks", query, McJson.encodeToJsonElement(body), serializer<PlaybackMarksView>(), enveloped = true)
    }

    /** 媒体库名称、别名、拼音及人物搜索（相关度排序，稳定分页）（`GET /search/library`） */
    suspend fun searchLibrary(q: String? = null, personId: Long? = null, limit: Long? = null, cursor: String? = null): LibrarySearchView {
        val query = buildList<Pair<String, String>> {
            q?.let { add("q" to it.toString()) }
            personId?.let { add("person_id" to it.toString()) }
            limit?.let { add("limit" to it.toString()) }
            cursor?.let { add("cursor" to it.toString()) }
        }
        return transport.send("GET", "/search/library", query, null, serializer<LibrarySearchView>(), enveloped = true)
    }

    /** 开始播放（`POST /playback/sessions`） */
    suspend fun playbackSessionStart(body: PlaybackSessionRequest): PlaybackSessionView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/playback/sessions", query, McJson.encodeToJsonElement(body), serializer<PlaybackSessionView>(), enveloped = true)
    }

    /** 播放心跳（`POST /playback/sessions/{session_id}/ping`） */
    suspend fun playbackSessionPing(sessionId: String): JsonObject {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/playback/sessions/${sessionId}/ping", query, null, serializer<JsonObject>(), enveloped = true)
    }

    /** 结束播放（`DELETE /playback/sessions/{session_id}`） */
    suspend fun playbackSessionStop(sessionId: String): JsonObject {
        val query = emptyList<Pair<String, String>>()
        return transport.send("DELETE", "/playback/sessions/${sessionId}", query, null, serializer<JsonObject>(), enveloped = true)
    }

    /** 上报观看进度（`POST /playback/progress`） */
    suspend fun playbackProgress(body: PlaybackProgressRequest): PlaybackStateView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/playback/progress", query, McJson.encodeToJsonElement(body), serializer<PlaybackStateView>(), enveloped = true)
    }

    /** 保存播放策略（`PUT /playback/policy`） */
    suspend fun playbackPolicySet(body: PlaybackPolicyPayload): PlaybackPolicyView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("PUT", "/playback/policy", query, McJson.encodeToJsonElement(body), serializer<PlaybackPolicyView>(), enveloped = true)
    }

    /** 播放页条目信息（标题/海报/库归属）（`GET /playback/items/{media_item_id}`） */
    suspend fun playbackItemInfo(mediaItemId: Long): PlaybackItemView {
        val query = emptyList<Pair<String, String>>()
        return transport.send("GET", "/playback/items/${mediaItemId}", query, null, serializer<PlaybackItemView>(), enveloped = true)
    }

    /** 播放页一季的分集清单（切集/上一集下一集数据源）（`GET /playback/items/{media_item_id}/episodes`） */
    suspend fun playbackItemEpisodes(mediaItemId: Long, seasonNumber: Long): SeasonEpisodesView {
        val query = buildList<Pair<String, String>> {
            add("season_number" to seasonNumber.toString())
        }
        return transport.send("GET", "/playback/items/${mediaItemId}/episodes", query, null, serializer<SeasonEpisodesView>(), enveloped = true)
    }

    /** 进度条缩略图索引（`GET /playback/files/{file_id}/trickplay`） */
    suspend fun playbackFileTrickplay(fileId: Long, token: String): TrickplayView {
        val query = buildList<Pair<String, String>> {
            add("token" to token.toString())
        }
        return transport.send("GET", "/playback/files/${fileId}/trickplay", query, null, serializer<TrickplayView>(), enveloped = true)
    }

    /** 播放器客户端日志（`POST /playback/client-log`） */
    suspend fun playbackClientLog(body: PlaybackClientLogPayload): JsonObject {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/playback/client-log", query, McJson.encodeToJsonElement(body), serializer<JsonObject>(), enveloped = true)
    }

    /** 上报播放质量（`POST /playback/metrics`） */
    suspend fun playbackMetricReport(body: PlaybackMetricPayload): JsonObject {
        val query = emptyList<Pair<String, String>>()
        return transport.send("POST", "/playback/metrics", query, McJson.encodeToJsonElement(body), serializer<JsonObject>(), enveloped = true)
    }

    /** 大图预告：一部片停留后原地播放的那一段（`GET /reels/preview/{media_item_id}`） */
    suspend fun reelsPreview(mediaItemId: Long, source: String? = null, season: Long? = null, episode: Long? = null): ReelItemView? {
        val query = buildList<Pair<String, String>> {
            source?.let { add("source" to it.toString()) }
            season?.let { add("season" to it.toString()) }
            episode?.let { add("episode" to it.toString()) }
        }
        return transport.send("GET", "/reels/preview/${mediaItemId}", query, null, serializer<ReelItemView?>(), enveloped = true)
    }
}
