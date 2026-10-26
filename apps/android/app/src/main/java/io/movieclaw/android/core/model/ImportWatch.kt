package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/*
 * 自动入库（设置 → 自动入库，原生页）：服务端 `schemas/import_watch.py` / routes/import_watch.py 的同构模型。
 * 一条规则 = 监听一个源目录，下载完成后按硬链接/复制搬进目标（指定库 / 自动路由 / 自定义目录）。
 */

/** 一条监听规则（`GET /import-watch`） */
@Serializable
data class ImportWatchView(
    val id: Long = 0,
    val sourcePath: String = "",
    /** hardlink / copy */
    val strategy: String = "hardlink",
    val libraryId: Long? = null,
    val libraryName: String? = null,
    val targetPath: String? = null,
    /** movie / tv / video（自定义目录或自动路由时的类型） */
    val kind: String? = null,
    /** 人话目标：库名 / 自定义目录（类型 · 路径） / 自动路由（类型） */
    val targetLabel: String = "",
    val processExisting: Boolean = true,
    /** 台账计数：imported / pending / failed / skipped / ignored */
    val stats: Map<String, Int> = emptyMap(),
    val importedFiles: Int = 0,
    val importedWorks: Int = 0,
    val createdAt: String? = null,
)

/** 新建 / 更新监听规则：指定库时 kind 为 null；自动路由或自定义目录时 libraryId 为 null */
@Serializable
data class ImportWatchPayload(
    val sourcePath: String,
    val strategy: String,
    val libraryId: Long? = null,
    val targetPath: String? = null,
    val kind: String? = null,
    val processExisting: Boolean = true,
)

/** 台账里的一条（`GET /import-watch/{id}/entries`） */
@Serializable
data class IngestEntryView(
    val id: Long = 0,
    val name: String = "",
    val entryPath: String = "",
    /** imported / pending / failed / skipped / ignored */
    val status: String = "",
    val message: String? = null,
    val importedCount: Int = 0,
    val attemptedAt: String? = null,
    /** 电影合集里待逐个认领的文件；普通条目为空 */
    val unresolvedFiles: List<String> = emptyList(),
)

@Serializable
data class IngestEntriesView(
    val counts: Map<String, Int> = emptyMap(),
    val entries: List<IngestEntryView> = emptyList(),
)

/** 认领：`entryFile` 仅在电影合集按文件认领时传 */
@Serializable
data class ClaimPayload(
    val tmdbId: Long,
    val entryFile: String? = null,
)
