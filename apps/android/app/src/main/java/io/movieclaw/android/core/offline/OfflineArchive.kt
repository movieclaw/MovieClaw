package io.movieclaw.android.core.offline

import kotlinx.serialization.builtins.serializer
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

// 离线下载的本机存档（docs/design/offline-download.md §3，与 iOS `OfflineModels` / `OfflineDisk` 同一格式）。
//
// 每个条目一个文件夹，文件夹本身就是事实来源：删文件夹即删干净。接口模型（详情、库、分集）原样存，
// 离线时原样喂给同一个页面；下面这几个是自有结构，都带 `format`，不认识的版本跳过、不崩。
//
//   filesDir/offline/<sha(实例号|用户名)>/
//     owner.json
//     items/<条目>/summary.json · detail.json · library.json · seasons/<季>.json · progress.json · images/
//     items/<条目>/units/<文件>/unit.json · playback.json · media.<扩展名> · media.part · subs/
//     viewings/<观看记录>.json

/** 本机副本属于哪台服务器上的哪个账号：按实例号认服务器（局域网 IP 与域名是同一台） */
@Serializable
data class OfflineOwner(
    val format: Int = 1,
    val instanceId: String,
    val username: String,
    /** 最近一次用的服务器地址（下载、补传都发到这里） */
    val origin: String,
) {
    val key: String get() = key(instanceId, username)

    val host: String get() = runCatching { java.net.URI(origin).host }.getOrNull() ?: origin

    companion object {
        fun key(instanceId: String, username: String): String =
            MessageDigest.getInstance("SHA-256").digest("$instanceId|$username".toByteArray())
                .take(16).joinToString("") { "%02x".format(it) }
    }
}

/** 一个播放单元（一部电影 / 一集）的本机副本：下载状态机 */
@Serializable
data class OfflineUnit(
    val format: Int = 1,
    val fileId: Long,
    val mediaItemId: Long,
    val season: Int,
    val episode: Int,
    /** original / 1080p / 720p / 480p */
    val profile: String,
    val profileLabel: String,
    val state: State,
    val expectedBytes: Long,
    val receivedBytes: Long = 0,
    /** 视频存盘的扩展名（原画按原容器，转码档 mp4） */
    val fileExtension: String,
    val exportId: String? = null,
    /** 这一集的剧照（下载中的卡片用；电影为空、用条目的横幅） */
    val stillUrl: String? = null,
    /** 失败原因（给人看的话） */
    val error: String? = null,
    /** 失败能不能自动重试（网络类、5xx、排队中能；无权限、文件没了、空间不足不能） */
    val retryable: Boolean = true,
    val attempts: Int = 0,
    /** 毫秒时间戳 */
    val nextRetryAt: Long? = null,
    val createdAt: Long,
    val completedAt: Long? = null,
    /** 本机打不开（引擎读不了）：提示重新下载 */
    val damaged: Boolean = false,
    /** 服务器还在排队转码（导出接口回 503）时它说的在等什么。内部仍按失败到点重试走，界面当成正常排队显示 */
    val transcodeWait: String? = null,
    /**
     * 已下部分对应的 ETag：续传时带 If-Range，服务端那份变了（导出重跑换了代号、洗版换了文件）就整份重给，
     * 不会拼出坏文件（iOS 由系统的续传数据带着它）
     */
    val etag: String? = null,
    /**
     * 下载顺序（§5.5），越小越先下。没调过为空、按加入时间排；「优先下载」或拖动排序后，进行中的单元整体重新编号
     * 0、1、2…，之后新加的按加入时间排在它们后面（与 iOS 同一字段、同一单位）
     */
    val queueOrder: Double? = null,
) {
    @Serializable
    enum class State {
        /** 拉清单、字幕、图片（要在线） */
        preparing,
        /** 等着轮到它下 */
        queued,
        downloading,
        /** 用户暂停（已下的字节留在 media.part，继续时 Range 续传） */
        paused,
        failed,
        done,
    }

    val unitKey: String get() = "$season-$episode"
    val isMovie: Boolean get() = season == 0 && episode == 0
    val playable: Boolean get() = state == State.done && !damaged
    /** 在排队等服务器转码（不是出错） */
    val waitingForTranscode: Boolean get() = state == State.failed && retryable && transcodeWait != null
    /** 界面上要用警告色、写「重试」的：真失败（排队转码不算）或文件损坏 */
    val needsAttention: Boolean get() = (state == State.failed && !waitingForTranscode) || damaged
    val isActive: Boolean get() = state != State.done
    /** 在下载队列里、迟早会轮到它：准备、排队、下载中，以及会自动重试的失败（含等转码）。暂停、要人处理的失败不算 */
    val inQueue: Boolean get() = when (state) {
        State.preparing, State.queued, State.downloading -> true
        State.failed -> retryable
        State.paused, State.done -> false
    }
    /** 能马上下（排队或下载中；等转码、准备中的这会儿轮不上） */
    val runnable: Boolean get() = state == State.queued || state == State.downloading
    val mediaFileName: String get() = "media.$fileExtension"

    val progressFraction: Double
        get() = if (expectedBytes <= 0) 0.0 else minOf(1.0, receivedBytes.toDouble() / expectedBytes)
}

/** 条目的展示摘要（索引用的小文件）：离线首页、海报墙、存储页只读它 */
@Serializable
data class OfflineItemSummary(
    val format: Int = 1,
    val mediaItemId: Long,
    val libraryId: Long,
    val libraryName: String,
    val libraryKind: String,
    /** movie / tv / video */
    val kind: String,
    val title: String,
    val year: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val primaryAspect: Float = 0.6667f,
    /** 最近一次加下载的时间（离线海报墙「最近下载」排序） */
    val addedAt: Long,
)

/** 播放一个本机单元要的数据（与服务端会话里的同名字段一致；章节、片段、音轨原样存） */
@Serializable
data class OfflinePlaybackSpec(
    val format: Int = 1,
    val durationMs: Long? = null,
    val chapters: JsonElement? = null,
    val segments: JsonElement? = null,
    val audioTracks: JsonElement? = null,
    val defaultAudio: String? = null,
    val subtitles: List<Subtitle> = emptyList(),
    val resolution: String? = null,
    val videoCodec: String? = null,
    val container: String? = null,
) {
    @Serializable
    data class Subtitle(
        /** 播放器里的轨引用：一律 `external:<存盘文件名>`（原画档的内封轨由引擎自己读） */
        val ref: String,
        val fileName: String,
        /** vtt（文本）/ ass */
        val kind: String,
        val language: String? = null,
        val title: String? = null,
        val isDefault: Boolean = false,
        val isForced: Boolean = false,
        val isAi: Boolean = false,
        /** 服务端的原轨引用 */
        val sourceRef: String,
    )
}

/** 一个单元的本机续播点（离线续播、离线「接着看」） */
@Serializable
data class OfflineProgress(
    val positionMs: Long,
    val played: Boolean,
    val durationMs: Long? = null,
    val updatedAt: Long,
)

/** 一次本机播放（§7）：先落盘，能连上就发，服务端按编号合并 */
@Serializable
data class OfflineViewing(
    val format: Int = 1,
    val viewingId: String,
    val mediaItemId: Long,
    val season: Int,
    val episode: Int,
    val fileId: Long,
    val startedAt: Long,
    val updatedAt: Long,
    val startPositionMs: Long,
    val positionMs: Long,
    val watchedMs: Long,
    val completed: Boolean,
    val ended: Boolean,
    val durationMs: Long? = null,
    /** 有没有还没发出去的更新 */
    val dirty: Boolean,
    /** 记下它的那次启动：上次启动留下、又没结束的，是播放中被强退 / 崩溃，补传前先收尾 */
    val launch: String? = null,
)

/** 开始前至少留出的空间（预计大小之外） */
const val OFFLINE_RESERVE_BYTES: Long = 2L * 1024 * 1024 * 1024

/**
 * 存档的路径与读写。写一律原子（临时文件 + 改名），所有写都排在同一个单线程上：
 * 下载回调、删除、元数据刷新、进度写入不会互相踩。
 */
object OfflineDisk {
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "offline-disk").apply { isDaemon = true } }
    val dispatcher = executor.asCoroutineDispatcher()

    /** 自有结构的编解码；接口模型用 App 的网络 Json（蛇形命名）原样存 */
    val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

    lateinit var root: File
        private set

    fun init(filesDir: File) {
        if (::root.isInitialized) return
        root = File(filesDir, "offline").apply { mkdirs() }
    }

    fun ownerDir(key: String) = File(root, key)
    fun itemsDir(key: String) = File(ownerDir(key), "items")
    fun itemDir(key: String, itemId: Long) = File(itemsDir(key), itemId.toString())
    fun unitDir(key: String, itemId: Long, fileId: Long) = File(itemDir(key, itemId), "units/$fileId")
    fun imagesDir(key: String, itemId: Long) = File(itemDir(key, itemId), "images")
    fun viewingsDir(key: String) = File(ownerDir(key), "viewings")

    fun ownerFile(key: String) = File(ownerDir(key), "owner.json")
    fun summaryFile(key: String, itemId: Long) = File(itemDir(key, itemId), "summary.json")
    fun detailFile(key: String, itemId: Long) = File(itemDir(key, itemId), "detail.json")
    fun libraryFile(key: String, itemId: Long) = File(itemDir(key, itemId), "library.json")
    fun seasonFile(key: String, itemId: Long, season: Int) = File(itemDir(key, itemId), "seasons/$season.json")
    fun progressFile(key: String, itemId: Long) = File(itemDir(key, itemId), "progress.json")
    fun unitFile(key: String, itemId: Long, fileId: Long) = File(unitDir(key, itemId, fileId), "unit.json")
    fun playbackFile(key: String, itemId: Long, fileId: Long) = File(unitDir(key, itemId, fileId), "playback.json")
    fun partFile(key: String, itemId: Long, fileId: Long) = File(unitDir(key, itemId, fileId), "media.part")
    fun viewingFile(key: String, id: String) = File(viewingsDir(key), "$id.json")

    /** 在写盘线程上做一件事并等它做完：与排着的删除、状态写入保持先后 */
    suspend fun <T> perform(work: () -> T): T = withContext(dispatcher) { work() }

    /** 排到写盘线程上，不等 */
    fun enqueue(work: () -> Unit) {
        executor.execute { runCatching(work) }
    }

    fun <T> write(serializer: KSerializer<T>, value: T, file: File) = writeText(json.encodeToString(serializer, value), file)

    fun <T> read(serializer: KSerializer<T>, file: File): T? =
        runCatching { json.decodeFromString(serializer, file.readText()) }.getOrNull()

    fun writeText(text: String, file: File) = writeBytes(text.toByteArray(), file)

    fun writeBytes(bytes: ByteArray, file: File) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, ".${file.name}.tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) {
            file.delete()
            if (!tmp.renameTo(file)) throw java.io.IOException("写入失败：${file.name}")
        }
    }

    fun remove(file: File) {
        file.deleteRecursively()
    }

    fun children(dir: File): List<File> = dir.listFiles()?.toList().orEmpty()

    /** 目录下全部文件的大小（存储页「其他账号」的占用） */
    fun size(dir: File): Long = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    /** 本机还剩多少空间 */
    fun availableBytes(): Long? = runCatching { android.os.StatFs(root.absolutePath).availableBytes }.getOrNull()

    /** 手机的总容量（存储页的容量条） */
    fun totalCapacity(): Long? = runCatching { android.os.StatFs(root.absolutePath).totalBytes }.getOrNull()

    /** 一个账号存档的全部内容（启动时在后台读一遍，每个文件都很小） */
    data class Snapshot(
        val items: Map<Long, OfflineItemSummary> = emptyMap(),
        val units: Map<Long, OfflineUnit> = emptyMap(),
        val progress: Map<Long, Map<String, OfflineProgress>> = emptyMap(),
    )

    private val progressSerializer = kotlinx.serialization.builtins.MapSerializer(
        String.serializer(), OfflineProgress.serializer(),
    )

    fun readProgress(file: File): Map<String, OfflineProgress>? = read(progressSerializer, file)

    fun writeProgress(map: Map<String, OfflineProgress>, file: File) = write(progressSerializer, map, file)

    fun loadSnapshot(key: String): Snapshot {
        val items = mutableMapOf<Long, OfflineItemSummary>()
        val units = mutableMapOf<Long, OfflineUnit>()
        val progress = mutableMapOf<Long, Map<String, OfflineProgress>>()
        for (itemDir in children(itemsDir(key))) {
            val itemId = itemDir.name.toLongOrNull() ?: continue
            val summary = read(OfflineItemSummary.serializer(), File(itemDir, "summary.json"))?.takeIf { it.format == 1 } ?: continue
            var hasUnit = false
            for (unitDir in children(File(itemDir, "units"))) {
                val unitFile = File(unitDir, "unit.json")
                var unit = read(OfflineUnit.serializer(), unitFile)?.takeIf { it.format == 1 } ?: continue
                // 下完了却没来得及标（改名与写状态之间被杀）：视频文件只在下载完整结束后才改名进来，文件在就是下完了
                if (unit.state != OfflineUnit.State.done) {
                    val media = File(unitDir, unit.mediaFileName)
                    if (media.isFile && media.length() > 0) {
                        unit = unit.copy(
                            state = OfflineUnit.State.done, receivedBytes = media.length(), expectedBytes = media.length(),
                            completedAt = unit.completedAt ?: System.currentTimeMillis(),
                        )
                        runCatching { write(OfflineUnit.serializer(), unit, unitFile) }
                    } else {
                        // 没下完的：已下的字节在 media.part 里
                        val part = File(unitDir, "media.part")
                        if (part.isFile) unit = unit.copy(receivedBytes = part.length())
                    }
                }
                units[unit.fileId] = unit
                hasUnit = true
            }
            if (!hasUnit) {
                // 单元都删光了还剩个空条目（删除中途被杀）：收拾掉
                remove(itemDir)
                continue
            }
            items[itemId] = summary
            readProgress(File(itemDir, "progress.json"))?.let { progress[itemId] = it }
        }
        return Snapshot(items, units, progress)
    }

    /** 图片键 → 存盘文件名（按图片键的摘要起名，任何显示宽度都用同一张） */
    fun imageFileName(key: String, ext: String): String =
        MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).take(16).joinToString("") { "%02x".format(it) } + ".$ext"

    fun safeName(raw: String): String {
        val cleaned = raw.map { if (it.isLetterOrDigit() || it in "._-") it else '_' }.joinToString("")
        return if (cleaned.isEmpty()) "file" else cleaned.take(80)
    }
}
