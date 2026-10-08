package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * `/search/library` 的响应 —— 媒体库搜索的相关度契约（v0.31 起，三端同一份）。
 *
 * 旧的 `/search/library-items`（按库分组 + 组内拼音排序）已在 v0.31 **删除**：
 * 它把人物带出的结果埋进按首字母排的库里，搜「ST」时 Stephen Lang 的《阿凡达》
 * 会排在《三体》后面。新契约按相关度平铺，命中原因服务端直接给好（`match.label`）。
 */
@Serializable
data class LibrarySearchView(
    val query: String = "",
    /** 选定人物下钻（只看这个人的库内作品） */
    val personId: Int? = null,
    val items: List<LibrarySearchHit> = emptyList(),
    val people: List<LibrarySearchPerson> = emptyList(),
    /** 输入即联想的候选（与结果卡片同一份命中原因） */
    val suggestions: List<LibrarySearchSuggestion> = emptyList(),
    /** 游标分页：不给 = 没有下一页 */
    val nextCursor: String? = null,
    /** 名称索引尚有待更新实体；查询已合并最新名称（UI 可忽略，或给个小提示） */
    val indexPending: Boolean = false,
)

/** 一条命中：条目 + 它在哪些库 + 为什么命中 */
@Serializable
data class LibrarySearchHit(
    val item: LibraryItemView,
    /** 同一部片在多个可见库里都有时，详情落点按这里选 */
    val libraryIds: List<Long> = emptyList(),
    val match: LibrarySearchMatch,
)

/** 可解释的命中证据（原始名称保留，客户端不必知道拼音索引实现） */
@Serializable
data class LibrarySearchMatch(
    val type: String = "",
    val sourceField: String = "",
    val matchedName: String = "",
    /** 人话：「标题：三体」「演员：史蒂芬·朗」「片名拼音」 */
    val label: String = "",
    /** 命中的是人物时给人物 id */
    val personId: Int? = null,
)

/** 人物行的一格：点它下钻这个人的库内作品 */
@Serializable
data class LibrarySearchPerson(
    val id: Int,
    /** TMDB 影人 ID：打开库内影人页（与演职员入口同一页）；连旧服务端时可能缺 */
    val tmdbPersonId: Int? = null,
    val name: String = "",
    val profilePath: String? = null,
    /** 头像地址：本地已下载给本地，否则 TMDB 图床；没有照片为空 */
    val avatarUrl: String? = null,
    val itemCount: Int = 0,
    val match: LibrarySearchMatch? = null,
)

/** 输入即联想的一条候选 */
@Serializable
data class LibrarySearchSuggestion(
    /** title / person */
    val type: String = "title",
    val text: String = "",
    /** 为什么联想到它（如「演员：李一桐」） */
    val label: String? = null,
    val mediaItemId: Long? = null,
    val personId: Int? = null,
)
