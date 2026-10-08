package io.movieclaw.android.feature.search

import io.movieclaw.android.core.model.DownloadTargetPrefView
import io.movieclaw.android.core.model.DownloaderView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.ManualDownloadTargetView
import io.movieclaw.android.core.model.TorrentHit

/**
 * 下载 / 投递按钮的按行状态（终态不可再点，error 可重试）。
 * 口径照 iOS `TorrentSubmitState`：同一个种子在下载与投递两条链上各记一份。
 */
enum class TorrentSubmitState {
    IDLE, SUBMITTING, DONE, EXISTS, ERROR;

    val downloadLabel: String
        get() = when (this) {
            IDLE -> "下载"
            SUBMITTING -> "提交中…"
            DONE -> "已提交"
            EXISTS -> "已在下载器"
            ERROR -> "失败·重试"
        }

    val grabLabel: String
        get() = when (this) {
            IDLE -> "投给订阅"
            SUBMITTING -> "投递中…"
            DONE, EXISTS -> "已投递"
            ERROR -> "失败·重试"
        }
}

/**
 * 落点弹窗需要的种子身份切片（由 [TorrentHit] 提炼，照 iOS `DownloadTargetRequest`）。
 *
 * [identityTitle]/[identityYear]/[identityKind] 来自数据扩充层的 `attrs`：三件套齐全时
 * 服务端能自动收敛出唯一条目，走「自动入库」；缺任一项就只能让用户确认「这是哪部作品」。
 */
data class DownloadTargetRequest(
    val siteId: String,
    val downloadUrl: String,
    val torrentId: String?,
    val identityKind: String?,
    val identityTitle: String?,
    val identityYear: Int?,
    val subtitle: String?,
    /** 用户的搜索关键词：身份识别失败时服务端拿它检索 TMDB 候选 */
    val hint: String?,
    /** 记忆的桶键：站点声明的一级分类（缺省 other） */
    val category: String,
    /** 对应搜索结果行（下载按钮状态按行记） */
    val hitKey: String,
    /** 记忆失效等原因（显示在弹窗顶部，静默回落最让人困惑） */
    val reason: String? = null,
) {
    val id: String get() = "$siteId:$downloadUrl"

    companion object {
        private fun attrsTitle(hit: TorrentHit): String? =
            hit.attrs?.titlesZh?.firstOrNull() ?: hit.attrs?.titlesEn?.firstOrNull()

        fun of(hit: TorrentHit, keyword: String): DownloadTargetRequest? {
            val url = hit.downloadUrl?.takeIf { it.isNotBlank() } ?: return null
            val attrs = hit.attrs
            val kind = attrs?.mediaType?.takeIf { it == "movie" || it == "tv" }
            val title = attrsTitle(hit)
            val year = attrs?.year
            return DownloadTargetRequest(
                siteId = hit.siteId,
                downloadUrl = url,
                torrentId = hit.torrentId.ifBlank { null },
                identityKind = if (kind != null && title != null && year != null) kind else null,
                identityTitle = if (kind != null && title != null && year != null) title else null,
                identityYear = if (kind != null && title != null && year != null) year else null,
                subtitle = hit.subtitle.ifBlank { null },
                hint = keyword.trim().takeIf { it.isNotEmpty() },
                category = hit.category ?: "other",
                hitKey = hitKey(hit),
            )
        }
    }
}

/** 行键：站点 + 站点内种子 ID（同 iOS `rowKey`） */
fun hitKey(hit: TorrentHit): String = "${hit.siteId}:${hit.torrentId}"

/** 一个可选的保存目标（三层候选的渲染与提交共用一份计算） */
data class TargetOption(
    /** smart / dir:… / library:… / default */
    val id: String,
    val kind: Kind,
    val savePath: String? = null,
    val libraryId: Long? = null,
    val label: String,
    val detail: String? = null,
) {
    enum class Kind { SMART, DIR, LIBRARY, FALLBACK }
}

/**
 * 候选列表。管理员三层（智能入库 / 已配目录 / 下载器默认），成员两层（可见库 / 下载器默认）——
 * 下载器配置与智能入库预检都是超管接口，成员提交也不许带目录与下载器（服务端强制，见
 * `member-permissions-v2` §3.7 U7）。
 */
fun computeTargetOptions(
    isAdmin: Boolean,
    target: ManualDownloadTargetView?,
    showOther: Boolean,
    downloader: DownloaderView?,
    memberLibraries: List<LibraryView>,
    request: DownloadTargetRequest,
): List<TargetOption> {
    if (!isAdmin) {
        val kind = request.identityKind
        val fit = memberLibraries.filter { it.kind != "photo" }
        val ordered = fit.filter { it.kind == kind } + fit.filter { it.kind != kind }
        return ordered.map { library ->
            TargetOption(
                id = "library:${library.id}",
                kind = TargetOption.Kind.LIBRARY,
                libraryId = library.id,
                label = "下载到「${library.name}」",
                detail = "${libraryKindLabel(library.kind)}；按库的设置决定保存目录，完成后自动入库",
            )
        } + TargetOption(
            id = "default",
            kind = TargetOption.Kind.FALLBACK,
            label = "下载器默认目录",
            detail = "由下载器按自身设置决定保存位置；不会自动整理入库",
        )
    }
    val result = mutableListOf<TargetOption>()
    if (target != null && target.status == "ready" && target.tmdbId != null &&
        target.libraryId != null && target.ok
    ) {
        val entryDir = target.entryDir ?: target.path
        val reason = target.routeReason.orEmpty()
        val detail = when (target.mode) {
            "watch" -> target.stagingPath?.let {
                "$reason；投递到自动入库的监听目录 ${target.path.orEmpty()}，完成后整理到 $it（外部流转回库根后入账）"
            } ?: "$reason；投递到自动入库的监听目录 ${target.path.orEmpty()}，完成后自动整理入库"
            "inplace" -> "$reason；直接下载到 ${trimPath(entryDir.orEmpty())}，完成后自动入账"
            else -> null
        }
        result += TargetOption(
            id = "smart",
            kind = TargetOption.Kind.SMART,
            label = "自动入库到「${target.libraryName.orEmpty()}」",
            detail = detail,
        )
    }
    if (showOther) {
        val seen = mutableSetOf<String>()
        val dirs = mutableListOf<Pair<String, String>>()
        downloader?.savePath?.let { dirs += it to "默认保存目录" }
        downloader?.pathMappings?.forEach { m ->
            if (m.local.isNotBlank() && m.local != downloader.savePath) dirs += m.local to "路径映射"
            seen += m.local
        }
        dirs.forEach { (path, source) ->
            val remote = remoteView(path, downloader?.pathMappings)
            result += TargetOption(
                id = "dir:$path",
                kind = TargetOption.Kind.DIR,
                savePath = path,
                label = path,
                detail = if (remote != path) "下载器视角：$remote（$source）" else source,
            )
        }
        result += TargetOption(
            id = "default",
            kind = TargetOption.Kind.FALLBACK,
            label = "下载器默认目录",
            detail = "不指定路径，由下载器按自身设置决定；movieclaw 不会自动整理入库",
        )
    }
    return result
}

/** 媒体库类型的中文名（DiscoverScreen.kindLabel 同口径；这里不跨包引用 UI 层的函数） */
fun libraryKindLabel(kind: String): String = when (kind) {
    "movie" -> "电影"
    "tv" -> "剧集"
    "photo" -> "图片"
    else -> "其他"
}

/** 目录比较用的归一化：去掉尾部斜杠（同 iOS `DownloadTargetPrefs.trim`） */
fun trimPath(path: String): String {
    var p = path
    while (p.length > 1 && p.endsWith("/")) p = p.dropLast(1)
    return p
}

/** 与后端 `translate_save_path` 同规则（仅用于展示下载器视角） */
fun remoteView(path: String, mappings: List<io.movieclaw.android.core.model.PathMapping>?): String {
    if (mappings.isNullOrEmpty()) return path
    var best: io.movieclaw.android.core.model.PathMapping? = null
    for (m in mappings) {
        val local = trimPath(m.local)
        if ((path == local || path.startsWith("$local/")) &&
            (best == null || local.length > trimPath(best!!.local).length)
        ) {
            best = m
        }
    }
    val chosen = best ?: return path
    val local = trimPath(chosen.local)
    return trimPath(chosen.remote) + path.drop(local.length)
}

/** 记住的固定目录已不在候选里（库被删、路径映射改了）：记忆失效，回落完整弹窗 */
fun isStaleDir(pref: DownloadTargetPrefView, dirs: Set<String>?): Boolean {
    if (pref.kind != "dir") return false
    val path = pref.savePath ?: return false
    val known = dirs ?: return false
    return trimPath(path) !in known
}

/** 记忆命中的原因说明（null = 记忆可用，直接弹确认条） */
fun rememberedPrefIssue(
    pref: DownloadTargetPrefView,
    request: DownloadTargetRequest,
    dirs: Set<String>?,
): String? = when {
    pref.kind == "smart" && request.identityKind == null ->
        "这条种子没解析出条目身份，用不了记住的「智能入库」，请确认是哪部作品。"
    pref.downloaderId != null && pref.downloaderName == null ->
        "上次使用的下载器已不可用，请重新选择保存位置。"
    isStaleDir(pref, dirs) ->
        "上次的保存位置 ${pref.savePath.orEmpty()} 已不存在，请重新选择。"
    else -> null
}

/** 下载器可选目录集合（判断记忆是否失效；null = 拉不到下载器，宁可不判失效） */
fun downloaderDirs(downloaders: List<DownloaderView>?): Set<String>? {
    val list = downloaders ?: return null
    val out = mutableSetOf<String>()
    for (d in list.filter { it.usable }) {
        d.savePath?.let { out += trimPath(it) }
        d.pathMappings?.forEach { out += trimPath(it.local) }
    }
    return out
}
