package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * M0 手写模型:只包含当前页面用到的字段。
 * JSON 全局启用 ignoreUnknownKeys + SnakeCase 命名映射(见 NetworkModule.json),
 * 服务端新增字段不会破坏解码;代码生成管线(§4.2)就绪后由生成物接管。
 */

@Serializable
data class DeviceClientInfo(
    val kind: String = "android",
    val name: String,
    val installationId: String,
    val clientVersion: String,
    val platform: String,
)

@Serializable
data class DeviceLoginRequest(
    val username: String,
    val password: String,
    val client: DeviceClientInfo,
)

@Serializable
data class CreateAdminRequest(val username: String, val password: String)

@Serializable
data class BootstrapStatus(val initialized: Boolean = true)

/** GET /api/v1/health —— 公开端点,非信封结构 */
@Serializable
data class HealthView(
    val status: String? = null,
    val service: String? = null,
    val environment: String? = null,
    val specHash: String? = null,
)

@Serializable
data class LoginDeviceView(
    val id: String? = null,
    val name: String? = null,
    val kind: String? = null,
    val platform: String? = null,
)

@Serializable
data class SessionView(
    val username: String,
    val nickname: String? = null,
    val avatarUrl: String? = null,
    val role: String = "member",
    val capabilities: Capabilities = Capabilities(),
) {
    @Serializable
    data class Capabilities(
        val allowSubscribe: Boolean = false,
        val allowSearch: Boolean = false,
        val allowDirectDownload: Boolean = false,
    )
}

@Serializable
data class DeviceLoginView(
    val token: String,
    val device: LoginDeviceView? = null,
    val session: SessionView,
)

@Serializable
data class LibraryStats(
    val itemCount: Int = 0,
    val fileCount: Int = 0,
    val totalSizeBytes: Long = 0,
    /** 在位待识别文件数（scanning=true 时是中间态，扫完才是结论） */
    val unidentifiedCount: Int = 0,
    /** 标记 missing 的文件数——管理页「待处理文件」胶囊用它 */
    val missingCount: Int = 0,
    val ignoredCount: Int = 0,
)

@Serializable
data class LibraryView(
    val id: Long,
    val name: String,
    val kind: String = "movie",
    val source: String = "tmdb",
    val excludeFromHome: Boolean = false,
    val viewerAccess: Boolean = true,
    /** 默认库（成员落点弹窗按它预选同类型的库；管理页有「默认」徽标） */
    val isDefault: Boolean = false,
    val rootPaths: List<String> = emptyList(),
    /** 主根路径（root_paths 第一项）；管理页根目录行用它 */
    val primaryRoot: String? = null,
    /** 可见范围：everyone=所有成员 / selected=指定成员 */
    val accessMode: String = "everyone",
    /** 显式授权的成员 id（仅管理员可见；成员端恒空） */
    val memberIds: List<Long> = emptyList(),
    /** 任一根路径落在网络挂载（NFS/SMB/fuse）：实时监控收不到远端变更 */
    val networkMount: Boolean = false,
    /** 正在扫描（管理页的「在跑任务」与行内状态都用它） */
    val scanning: Boolean = false,
    /** 正在整理文件名 */
    val organizing: Boolean = false,
    /** 整库元数据刷新状态；null = 没在刷 */
    val metadataRefresh: kotlinx.serialization.json.JsonElement? = null,
    /** 整库生成章节的作业状态；null = 没在生成 */
    val chapterJob: kotlinx.serialization.json.JsonElement? = null,
    /** 服务端预算好的库存统计（iOS libraryStatsSummary 用的就是它） */
    val stats: LibraryStats = LibraryStats(),
)

@Serializable
data class UpNextItem(
    val mediaItemId: Long,
    val libraryId: Long,
    val kind: String = "movie",
    val title: String,
    val year: Int? = null,
    val posterUrl: String? = null,
    val posterAspect: Float = 2f / 3f,
    val backdropUrl: String? = null,
    val episodeStillUrl: String? = null,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val episodeTitle: String? = null,
    val unwatchedAheadCount: Int = 0,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val progressPercent: Int = 0,
    /** 卡片已经翻过篇：最近播放那一集看完了，这张卡指向它之后的下一集 */
    val advanced: Boolean = false,
    val lastPlayedAt: String? = null,
)

@Serializable
data class UpNextView(val items: List<UpNextItem> = emptyList())

/** `GET /fs/browse` 的一条子目录（服务端 schemas/fs.py；只含目录） */
@Serializable
data class FsEntry(val name: String, val path: String)

/** `GET /fs/browse` 的结果：当前位置 + 上级（根目录为 null）+ 子目录列表（按名排序） */
@Serializable
data class FsBrowseView(
    val path: String,
    val parent: String? = null,
    val entries: List<FsEntry> = emptyList(),
)
