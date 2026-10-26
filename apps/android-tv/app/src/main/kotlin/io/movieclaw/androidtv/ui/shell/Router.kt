package io.movieclaw.androidtv.ui.shell

import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList

/** 侧边栏的页签（TVNavigation.swift MainTab）。发现 / 订阅暂不提供（同 Apple TV 版，docs/design/tvos-app.md §3.3） */
enum class MainTab { Account, Search, Home }

/** 压在页签上的二级页（AppRoute） */
sealed interface Route {
    data class Item(val libraryId: Long, val itemId: Long) : Route
    data class Library(val id: Long) : Route
    data class Collection(val id: Long, val name: String) : Route
    data class Person(val tmdbId: Long, val name: String, val avatar: String?, val fromItem: Long?) : Route
    data class RowWall(val title: String, val source: WallSource) : Route
    data object About : Route
    data class License(val componentName: String) : Route
}

/** 一面海报墙从哪儿取数（TVRowWallView 的 source） */
sealed interface WallSource {
    data class Library(val id: Long, val sort: String, val reversed: Boolean, val unwatched: Boolean, val count: Long? = null) : WallSource
    data class MediaKind(val kind: String, val sort: String, val reversed: Boolean, val unwatched: Boolean) : WallSource
    data class Collection(val id: Long, val sort: String, val reversed: Boolean) : WallSource
    data class Genre(val kind: String, val genre: Long, val count: Long) : WallSource
    data class Favorites(val sort: String, val reversed: Boolean, val total: Long?) : WallSource
}

/** 一次起播请求（PlayRequest）：季集为 null 是电影；[startSeconds] 为 null 由服务端按续播点起，0 从头播放 */
data class PlayRequest(
    val mediaItemId: Long,
    val seasonNumber: Long? = null,
    val episodeNumber: Long? = null,
    val startSeconds: Long? = null,
    val fileId: Long? = null,
)

/**
 * 导航（TVRouter）：每个页签各自一个栈、各自记住浏览位置；播放器盖在整个界面之上。
 */
@Stable
class Router {
    var tab by mutableStateOf(MainTab.Home)
        private set
    val stacks: Map<MainTab, SnapshotStateList<Route>> = MainTab.entries.associateWith { mutableStateListOf() }
    var player by mutableStateOf<PlayRequest?>(null)
        private set
    /** 每次关掉播放器 +1：首页、详情页据此刷新（续播点、看过的标记） */
    var playbackClosed by mutableStateOf(0)
        private set
    /** 刚播完的是哪一部（详情页据此只在是自己时刷新） */
    var lastPlayed by mutableStateOf<PlayRequest?>(null)
        private set

    val stack: SnapshotStateList<Route> get() = stacks.getValue(tab)

    /** 选中页签；选的就是当前页签时退回它的根页 */
    fun select(target: MainTab) {
        if (target == tab) stacks.getValue(target).clear() else tab = target
    }

    fun push(route: Route) {
        stack += route
    }

    fun pop(): Boolean {
        if (stack.isEmpty()) return false
        stack.removeAt(stack.lastIndex)
        return true
    }

    fun play(request: PlayRequest) {
        player = request
    }

    fun closePlayer() {
        lastPlayed = player
        player = null
        playbackClosed++
    }
}

val LocalRouter = compositionLocalOf<Router> { error("LocalRouter 未提供") }
