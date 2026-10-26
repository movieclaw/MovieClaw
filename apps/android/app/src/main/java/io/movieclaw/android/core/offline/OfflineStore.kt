package io.movieclaw.android.core.offline

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * 离线本机库（docs/design/offline-download.md §3「每个条目一个文件夹 + JSON」）：
 *
 *   filesDir/offline/<mediaItemId>/<fileId>/
 *     pack.json   —— 服务端 manifest 原样（标题/海报/库/时长等离线展示数据）
 *     video.<ext> —— 正片（原画 = 原文件；转码档 = 导出 mp4）
 *     poster.jpg  —— 海报
 *     viewings.json —— 还没补传的本机观看记录
 *
 * 文件夹本身就是事实来源：删掉文件夹 = 删掉这个本机副本。
 * 在线时优先播本机副本（iOS 同语义）；观看进度先落盘，联网后按 viewing_id 幂等补传。
 */
@Singleton
class OfflineStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val repository: io.movieclaw.android.core.session.SessionRepository,
) {
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = false }

    /** 一个本机副本（一个播放单元的一个文件版本） */
    @Serializable
    data class Pack(
        val mediaItemId: Long,
        val fileId: Long,
        val seasonNumber: Int = 0,
        val episodeNumber: Int = 0,
        val title: String = "",
        val subtitle: String? = null,
        val libraryName: String = "",
        val posterUrl: String? = null,
        val container: String? = null,
        val profile: String = "original",
        val durationMs: Long? = null,
        val sizeBytes: Long = 0,
        /** 条目所属媒体库（下载列表点进详情用；老副本为 0 = 不知道） */
        val libraryId: Long = 0,
        /** 本机进度标了已看完（「建议删除已看完的」用它，iOS `localProgress(...).played`） */
        val played: Boolean = false,
    )

    /** 下载状态（下载器发布；Store 只管已落盘的副本与观看记录） */
    data class Progress(
        val fileId: Long,
        val title: String,
        val downloadedBytes: Long,
        val totalBytes: Long,
        val speedBps: Long,
        val paused: Boolean,
        val phase: String? = null,
    )

    /** 这台设备上的一个下载归属（origin + 账号）：iOS `OfflineOwner` 的对应物 */
    data class Owner(val key: String, val origin: String, val username: String) {
        val host: String get() = runCatching { java.net.URI(origin).host }.getOrNull() ?: origin
    }

    /** 其他账号在这台设备上的下载（只读汇总；点进去/删除见下载页） */
    data class OtherOwner(val owner: Owner, val items: Int, val bytes: Long)

    @Serializable
    private data class OwnerMeta(val origin: String = "", val username: String = "")

    private val baseRoot: File
        get() = File(context.filesDir, "offline").apply { mkdirs() }

    @Volatile private var activeOwner: Owner? = null

    private fun ownerDir(owner: Owner) = File(baseRoot, "owner_${owner.key}")

    /** 当前账号的目录；没登录时用一个空目录，绝不去动别人的副本 */
    private val root: File
        get() {
            val owner = activeOwner ?: ensureOwner()
            return owner?.let(::ownerDir) ?: File(baseRoot, "_none").apply { mkdirs() }
        }

    /**
     * 会话刚 READY、collect 还没跑到时下载就可能开始：这里同步从 SessionRepository 取一次归属，
     * 保证第一份副本不会写进 `_none`。
     */
    @Synchronized
    private fun ensureOwner(): Owner? {
        val ui = repository.ui.value
        val origin = ui.origin?.trimEnd('/') ?: return null
        val username = ui.session?.username ?: return null
        val owner = Owner(ownerKey(origin, username), origin, username)
        activeOwner = owner
        _ownerKey.value = owner.key
        ownerDir(owner).mkdirs()
        writeOwnerMeta(owner)
        migrateLegacy(owner)
        refreshOtherOwners()
        return owner
    }

    private val _packs = MutableStateFlow<List<Pack>>(emptyList())
    val packs: StateFlow<List<Pack>> = _packs.asStateFlow()

    private val _ownerKey = MutableStateFlow<String?>(null)

    /** 当前下载归属的键；下载器据此在切账号时停掉旧账号的任务 */
    val ownerKey: StateFlow<String?> = _ownerKey.asStateFlow()

    private val _otherOwners = MutableStateFlow<List<OtherOwner>>(emptyList())
    val otherOwners: StateFlow<List<OtherOwner>> = _otherOwners.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        scope.launch {
            repository.ui.collect { ui ->
                val owner = ui.origin?.trimEnd('/')?.let { origin ->
                    ui.session?.username?.let { username ->
                        Owner(ownerKey(origin, username), origin, username)
                    }
                }
                if (owner?.key != activeOwner?.key) {
                    activeOwner = owner
                    _ownerKey.value = owner?.key
                    if (owner != null) {
                        ownerDir(owner).mkdirs()
                        writeOwnerMeta(owner)
                        migrateLegacy(owner)
                        scan()
                    } else {
                        _packs.value = emptyList()
                    }
                    refreshOtherOwners()
                }
            }
        }
    }

    private fun ownerKey(origin: String, username: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest((origin.trimEnd('/') + "\n" + username).toByteArray())
        return digest.joinToString("") { "%02x".format(it) }.take(16)
    }

    private fun writeOwnerMeta(owner: Owner) {
        runCatching {
            File(ownerDir(owner), "owner.json").writeText(
                json.encodeToString(OwnerMeta(origin = owner.origin, username = owner.username)),
            )
        }
    }

    /** 旧版本把副本直接放在 filesDir/offline/<itemId>：归属确定后挪进当前账号目录一次 */
    private fun migrateLegacy(owner: Owner) {
        val target = ownerDir(owner)
        baseRoot.listFiles()?.filter { it.isDirectory && !it.name.startsWith("owner_") }.orEmpty().forEach { legacy ->
            if (legacy.name == "_none") return@forEach
            val dest = File(target, legacy.name)
            if (!dest.exists()) legacy.renameTo(dest) else legacy.deleteRecursively()
        }
    }

    private fun refreshOtherOwners() {
        val active = activeOwner?.key
        val list = baseRoot.listFiles()
            ?.filter { it.isDirectory && it.name.startsWith("owner_") }
            ?.mapNotNull { dir ->
                val key = dir.name.removePrefix("owner_")
                if (key == active) return@mapNotNull null
                val meta = runCatching {
                    json.decodeFromString<OwnerMeta>(File(dir, "owner.json").readText())
                }.getOrNull() ?: return@mapNotNull null
                if (meta.username.isBlank()) return@mapNotNull null
                var items = 0
                var bytes = 0L
                dir.listFiles()?.filter(File::isDirectory)?.forEach { itemDir ->
                    itemDir.listFiles()?.filter(File::isDirectory)?.forEach { fileDir ->
                        val pack = File(fileDir, "pack.json")
                        val video = fileDir.listFiles()?.firstOrNull { it.name.startsWith("video.") }
                        if (pack.isFile && video != null && video.length() > 0) {
                            items += 1
                            bytes += video.length()
                        }
                    }
                }
                OtherOwner(Owner(key, meta.origin, meta.username), items, bytes)
            }
            .orEmpty()
            .filter { it.items > 0 }
            .sortedBy { it.owner.username }
        _otherOwners.value = list
    }

    /** 删除其他账号在这台设备上的下载（只动副本，不动服务端） */
    fun deleteOwner(owner: Owner) {
        if (owner.key == activeOwner?.key) return
        File(baseRoot, "owner_${owner.key}").deleteRecursively()
        refreshOtherOwners()
    }

    fun unitDir(mediaItemId: Long, fileId: Long): File =
        File(File(root, mediaItemId.toString()), fileId.toString()).apply { mkdirs() }

    fun packFile(mediaItemId: Long, fileId: Long): File = File(unitDir(mediaItemId, fileId), "pack.json")
    fun posterFile(mediaItemId: Long, fileId: Long): File = File(unitDir(mediaItemId, fileId), "poster.jpg")
    fun viewingsFile(mediaItemId: Long, fileId: Long): File = File(unitDir(mediaItemId, fileId), "viewings.json")

    fun videoFile(mediaItemId: Long, fileId: Long, container: String?, ext: String = "mp4"): File {
        val ext0 = (container?.lowercase()?.takeIf { it.isNotBlank() } ?: ext).removePrefix(".")
        return File(unitDir(mediaItemId, fileId), "video.$ext0")
    }

    /** 重扫根目录（下载完成/删除后调用） */
    fun scan() {
        val list = mutableListOf<Pack>()
        root.listFiles(File::isDirectory)?.forEach { itemDir ->
            itemDir.listFiles(File::isDirectory)?.forEach { fileDir ->
                val pack = File(fileDir, "pack.json")
                val video = fileDir.listFiles()?.firstOrNull { it.name.startsWith("video.") }
                if (pack.isFile && video != null && video.length() > 0) {
                    runCatching {
                        val p = json.decodeFromString<Pack>(pack.readText())
                        list += p.copy(sizeBytes = video.length())
                    }
                }
            }
        }
        _packs.value = list.sortedBy { it.title }
    }

    fun savePack(pack: Pack) {
        packFile(pack.mediaItemId, pack.fileId).writeText(json.encodeToString(pack))
        scan()
    }

    fun hasFile(fileId: Long): Boolean = _packs.value.any { it.fileId == fileId }

    fun packFor(fileId: Long): Pack? = _packs.value.firstOrNull { it.fileId == fileId }

    /** 某一集（季 + 集）在本机的副本；电影用 0/0 */
    fun unitFor(mediaItemId: Long, season: Int, episode: Int): Pack? =
        _packs.value.firstOrNull {
            it.mediaItemId == mediaItemId && it.seasonNumber == season && it.episodeNumber == episode
        }

    fun packsOf(mediaItemId: Long): List<Pack> = _packs.value.filter { it.mediaItemId == mediaItemId }

    /** 本机剩余可用字节（选档面板的空间检查用） */
    fun freeBytes(): Long = runCatching {
        val stat = android.os.StatFs(context.filesDir.absolutePath)
        stat.availableBlocksLong * stat.blockSizeLong
    }.getOrDefault(Long.MAX_VALUE)

    fun delete(mediaItemId: Long, fileId: Long) {
        val itemDir = File(root, mediaItemId.toString())
        File(itemDir, fileId.toString()).deleteRecursively()
        if (itemDir.listFiles().isNullOrEmpty()) itemDir.deleteRecursively()
        scan()
    }

    fun totalBytes(): Long = _packs.value.sumOf { it.sizeBytes }

    /** 本机总容量（容量条的分母；取不到时给 null） */
    fun totalCapacityBytes(): Long? = runCatching {
        val stat = android.os.StatFs(context.filesDir.absolutePath)
        stat.totalBytes
    }.getOrNull()

    /** 标记这一集是否已看完（播放器退出时写；观看进度会补传，这里只是本机副本的「看完了」标记） */
    fun markPlayed(mediaItemId: Long, fileId: Long, played: Boolean) {
        val pack = packFor(fileId) ?: return
        val updated = pack.copy(played = played)
        savePack(updated)
    }

    fun deleteItem(mediaItemId: Long) {
        File(root, mediaItemId.toString()).deleteRecursively()
        scan()
    }

    // ── 本机观看记录（先落盘，联网补传；服务端按 viewing_id 幂等合并）──

    @Serializable
    data class PendingViewing(val record: io.movieclaw.android.core.model.OfflineViewingRecord)

    fun appendViewing(pack: Pack, record: io.movieclaw.android.core.model.OfflineViewingRecord) {
        val file = viewingsFile(pack.mediaItemId, pack.fileId)
        val list = runCatching {
            json.decodeFromString<List<PendingViewing>>(file.takeIf { it.isFile }?.readText() ?: "[]")
        }.getOrDefault(emptyList())
        file.writeText(json.encodeToString(list + PendingViewing(record)))
    }

    /** 把所有本机副本的待补传观看记录推给服务器；applied/stale 都算已处理（观看日志服务端照记） */
    suspend fun syncViewings(origin: String, api: io.movieclaw.android.core.api.McApi): Int {
        var pushed = 0
        _packs.value.forEach { pack ->
            val file = viewingsFile(pack.mediaItemId, pack.fileId)
            val list = runCatching {
                json.decodeFromString<List<PendingViewing>>(file.takeIf { it.isFile }?.readText() ?: "[]")
            }.getOrDefault(emptyList())
            if (list.isEmpty()) return@forEach
            val now = java.time.Instant.now().toString()
            val request = io.movieclaw.android.core.model.OfflineViewingsRequest(
                sentAt = now,
                records = list.map { it.record },
            )
            runCatching { api.playbackViewings(request) }
                .onSuccess {
                    file.delete()
                    pushed += list.size
                }
            // 失败留在盘上，下次再推（服务端幂等，重复推安全）
        }
        return pushed
    }
}
