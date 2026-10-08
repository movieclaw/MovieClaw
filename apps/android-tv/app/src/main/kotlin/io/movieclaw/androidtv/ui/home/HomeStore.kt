package io.movieclaw.androidtv.ui.home

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.movieclaw.androidtv.core.model.generated.CollectionView
import io.movieclaw.androidtv.core.model.generated.FavoritesView
import io.movieclaw.androidtv.core.model.generated.HomeRowPref
import io.movieclaw.androidtv.core.model.generated.LibraryItemShowcaseView
import io.movieclaw.androidtv.core.model.generated.LibraryItemView
import io.movieclaw.androidtv.core.model.generated.LibraryKindGenreView
import io.movieclaw.androidtv.core.model.generated.LibraryView
import io.movieclaw.androidtv.core.model.generated.UpNextItemView
import io.movieclaw.androidtv.core.network.generated.McApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * 首页数据（LibraryHomeStore.swift）：偏好、库、合集、接下来继续、收藏并发取；再按合并出的行各自取条目，
 * 输入（库状态、要取的行、合集）没变就不重拉各行。刷新失败保留已有数据，一次都没成功过才整页报错。
 */
@Stable
class HomeStore(private val api: McApi) {
    var libraries by mutableStateOf<List<LibraryView>?>(null)
        private set
    var collections by mutableStateOf<List<CollectionView>>(emptyList())
        private set
    var upNext by mutableStateOf<List<UpNextItemView>?>(null)
        private set
    var favorites by mutableStateOf<FavoritesView?>(null)
        private set
    var itemsByKey by mutableStateOf<Map<String, List<LibraryItemView>>>(emptyMap())
        private set
    var genresByKind by mutableStateOf<Map<String, List<LibraryKindGenreView>>>(emptyMap())
        private set
    var prefs by mutableStateOf<List<HomeRowPref>?>(null)
        private set
    var failed by mutableStateOf(false)
        private set
    /** 展开海报行的补充信息（背景图、Logo、简介、类型、片长、分级），每部只取一次 */
    var showcase by mutableStateOf<Map<Long, LibraryItemShowcaseView>>(emptyMap())
        private set
    private val showcaseRequested = mutableSetOf<Long>()
    private var fingerprint: Int? = null
    private var inFlight: Deferred<Unit>? = null

    val rows: List<HomeRows.Row>
        get() = libraries?.let { HomeRows.build(prefs.orEmpty(), it, collections) }.orEmpty()

    /** 刷新整页；并发调用合并为同一次 */
    suspend fun reload() = coroutineScope {
        inFlight?.let { if (it.isActive) return@coroutineScope it.await() }
        val task = async { load() }
        inFlight = task
        task.await()
    }

    /**
     * try 必须包在 coroutineScope **外面**：里面的 async 失败时，除了 await 抛异常，还会取消整个作用域、由
     * coroutineScope 在返回处再抛一次——包在里面接不住，异常一路冒到 LaunchedEffect 让 App 崩溃
     * （故障注入实测：断网时首页 60 秒一次的刷新撞上就闪退，看着片也一样）。
     */
    private suspend fun load() = try {
        coroutineScope {
            val prefsTask = async { runCatching { api.uiPrefsShow().home.rows }.getOrNull() }
            val libsTask = async { api.libraryList(scope = "all") }
            val colsTask = async { runCatching { api.collectionList() }.getOrNull() }
            val planned = HomeRows.build(prefs.orEmpty(), emptyList(), emptyList()).filter { !it.hidden }
            val upNextTask = async { if (planned.any { it.kind == HomeRows.Kind.UpNext }) runCatching { api.playbackUpNext(limit = ROW_COUNT).items }.getOrNull() else emptyList() }
            val favoritesKind = planned.firstNotNullOfOrNull { it.kind as? HomeRows.Kind.Favorites }
            val favoritesTask = async { favoritesKind?.let { fetchFavorites(it) } }
            val libs = libsTask.await()
            val cols = colsTask.await() ?: collections
            prefsTask.await()?.let { prefs = it }
            failed = false
            libraries = libs
            collections = cols
            val visible = HomeRows.build(prefs.orEmpty(), libs, cols).filter { !it.hidden }
            val fetches = rowFetches(visible, libs)
            val genreKinds = visible.mapNotNull { (it.kind as? HomeRows.Kind.Genres)?.kind }
            val print = listOf(libs, fetches.keys.sorted(), genreKinds, cols).hashCode()
            val rowsTask = if (print == fingerprint) null else async {
                fetches.map { (key, fetch) -> async { key to (runCatching { fetch() }.getOrNull() ?: emptyList()) } }.awaitAll().toMap()
            }
            val genresTask = if (print == fingerprint) null else async {
                genreKinds.map { kind -> async { kind to (runCatching { api.uiLibraryKindGenres(kind) }.getOrNull() ?: emptyList()) } }.awaitAll().toMap()
            }
            // 刷新到的偏好若改了这两行的取法，按新的再取一次
            val actualFavorites = visible.firstNotNullOfOrNull { it.kind as? HomeRows.Kind.Favorites }
            val latestUpNext = upNextTask.await()
            val latestFavorites = if (actualFavorites != favoritesKind) actualFavorites?.let { fetchFavorites(it) } else favoritesTask.await()
            upNext = latestUpNext ?: upNext ?: emptyList()
            favorites = latestFavorites ?: favorites ?: FavoritesView()
            if (rowsTask != null) {
                itemsByKey = rowsTask.await()
                genresByKind = genresTask?.await().orEmpty()
                fingerprint = print
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        failed = true
    }

    private suspend fun fetchFavorites(kind: HomeRows.Kind.Favorites): FavoritesView? = runCatching {
        // 「未看优先」是首页这一行的默认（全量页不传，保持收藏时间序）
        val unwatchedFirst = kind.sort == "unwatched_first"
        api.playbackFavorites(
            limit = ROW_COUNT,
            offset = 0,
            unwatchedFirst = unwatchedFirst,
            sort = if (unwatchedFirst) "favorited_at" else kind.sort,
            order = HomeRows.favoritesDirection(kind.sort)?.orderParam(kind.reversed),
        )
    }.getOrNull()

    private fun rowFetches(rows: List<HomeRows.Row>, libs: List<LibraryView>): Map<String, suspend () -> List<LibraryItemView>> {
        val fetches = linkedMapOf<String, suspend () -> List<LibraryItemView>>()
        for (row in rows) {
            when (val k = row.kind) {
                is HomeRows.Kind.Library -> {
                    val watch = if (k.sort == "last_played") "seen" else if (k.unwatched) "unwatched" else null
                    val order = HomeRows.preset(k.sort).direction?.orderParam(k.reversed)
                    fetches[HomeRows.fetchKey(row)] = { api.libraryItemsList(k.library.id, sort = k.sort, order = order, limit = ROW_COUNT, w = watch) }
                }
                is HomeRows.Kind.MediaKind -> {
                    val watch = if (k.sort == "last_played") "seen" else if (k.unwatched) "unwatched" else null
                    val order = HomeRows.preset(k.sort).direction?.orderParam(k.reversed)
                    fetches[HomeRows.fetchKey(row)] = { api.uiLibraryKindItems(k.kind, sort = k.sort, order = order, limit = ROW_COUNT, w = watch) }
                }
                is HomeRows.Kind.Collection -> {
                    val order = HomeRows.preset(k.sort).direction?.orderParam(k.reversed)
                    fetches[HomeRows.fetchKey(row)] = { api.collectionItemsList(k.collection.id, limit = ROW_COUNT, sort = k.sort, order = order) }
                }
                else -> Unit
            }
        }
        return fetches
    }

    /** 展开海报行要用的补充信息：缺哪部取哪部，每部只请求一次 */
    suspend fun loadShowcase(ids: List<Long>) {
        val missing = ids.filter { showcaseRequested.add(it) }
        if (missing.isEmpty()) return
        val rows = runCatching { api.uiLibraryShowcase(missing) }.getOrNull() ?: return
        showcase = showcase + rows.associateBy { it.mediaItemId }
    }

    companion object {
        const val ROW_COUNT = 20L
    }
}
