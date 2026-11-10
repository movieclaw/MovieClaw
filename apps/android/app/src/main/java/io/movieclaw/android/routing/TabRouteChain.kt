package io.movieclaw.android.routing

import androidx.navigation.NavBackStackEntry

/** 单库墙的路由模式串：actor = 详情页演员卡带进来的演员名（本地/NFO 库没有影人页，看同库里他的作品） */
internal const val LIBRARY_ROUTE = "library/{libraryId}?name={name}&w={w}&sort={sort}&order={order}&actor={actor}"

/**
 * 每页签导航链（AppNav 的 `tabChains`）里「一层」记成什么 URL。
 *
 * 链按返回栈条目的**原始实参**还原 URL，可墙页上摘掉演员条件后，条目的实参里还带着 actor——
 * 平板切页签回来重放、或进程重建后重放，摘掉的演员又会套回去。所以摘掉时在条目自己的
 * `savedStateHandle` 里记一笔（随条目一起保存/恢复），还原 URL 时以它为准把 actor 去掉，
 * 并把链里这一层就地换成不带 actor 的那条。
 */
internal object TabRouteChain {
    private const val ACTOR_CLEARED = "movieclaw.actorCleared"

    /** 条目当前应记进链的 URL：原始实参还原，摘过演员的去掉 actor */
    fun routeOf(entry: NavBackStackEntry): String? {
        val filled = filledRouteOf(entry) ?: return null
        if (entry.arguments?.getString("actor") == null) return filled
        return if (entry.savedStateHandle.get<Boolean>(ACTOR_CLEARED) == true) withoutQuery(filled, "actor") else filled
    }

    /** 进了一层：同一层重复上报（重组/旋转/从下一层返回）不重复追加 */
    fun record(chain: List<String>, entry: NavBackStackEntry): List<String> {
        val route = routeOf(entry) ?: return chain
        return if (chain.lastOrNull() == route) chain else chain + route
    }

    /** 墙页摘掉了路由带来的演员：记到条目上，并把链里这一层换成不带 actor 的 */
    fun clearActor(chain: List<String>, entry: NavBackStackEntry): List<String> {
        if (entry.arguments?.getString("actor") == null) return chain
        val before = routeOf(entry) ?: return chain
        entry.savedStateHandle[ACTOR_CLEARED] = true
        return replaceLast(chain, before, routeOf(entry) ?: return chain)
    }

    /** 去掉 URL 里的一个查询参数（其余参数原样保留，含编码） */
    fun withoutQuery(route: String, name: String): String {
        val path = route.substringBefore('?')
        val kept = route.substringAfter('?', "").split('&')
            .filter { it.isNotEmpty() && it.substringBefore('=') != name }
        return if (kept.isEmpty()) path else path + "?" + kept.joinToString("&")
    }

    /** 链里最后一个 [old] 换成 [new]；没有就原样返回 */
    fun replaceLast(chain: List<String>, old: String, new: String): List<String> {
        val i = chain.lastIndexOf(old)
        return if (i < 0) chain else chain.toMutableList().also { it[i] = new }
    }
}
