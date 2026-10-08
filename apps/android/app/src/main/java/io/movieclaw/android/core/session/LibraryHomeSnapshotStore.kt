package io.movieclaw.android.core.session

import io.movieclaw.android.core.AppScopes

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.model.CollectionView
import io.movieclaw.android.core.model.FavoriteItemView
import io.movieclaw.android.core.model.KindRow
import io.movieclaw.android.core.model.LibraryItemView
import io.movieclaw.android.core.model.LibraryKindGenreView
import io.movieclaw.android.core.model.LibraryView
import io.movieclaw.android.core.model.UpNextItem
import io.movieclaw.android.core.model.HomeRowPref
import java.io.File
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * 媒体库整页快照（iOS `PageSnapshots` + `LibraryHomeStore` 的 stale-while-revalidate 对应物）。
 *
 * 上次加载成功的数据按「服务器 + 账号」（owner 取 SHA-256 当文件名）存 `cacheDir`；
 * 冷启动**先原样画出来**（第一帧就是上次离开时的完整页面），再静默刷新换新。
 * 只存能序列化的零件：行清单（`rows`）在恢复时用 `HomeRows.build` 重建成行，
 * 各行条目按行 id 对上——与站内两份实现的合并口径始终是同一份。
 *
 * 约定：版本不符/解码失败直接丢弃（App 升级改了模型就自动作废）；退出登录 / 移除账号即删。
 */
@Serializable
data class LibraryHomeSnapshot(
    val version: Int = VERSION,
    val libraries: List<LibraryView> = emptyList(),
    val collections: List<CollectionView> = emptyList(),
    val upNext: List<UpNextItem> = emptyList(),
    val favorites: List<FavoriteItemView> = emptyList(),
    val favoriteTotal: Int = 0,
    val rows: List<HomeRowPref> = emptyList(),
    /** 行 id → 该行的条目（`HomeRows.build` 重建后 id 稳定，对得上） */
    val rowItems: Map<String, List<LibraryItemView>> = emptyMap(),
    val genresByKind: Map<String, List<LibraryKindGenreView>> = emptyMap(),
    val kindRows: List<KindRow> = emptyList(),
) {
    companion object {
        /** 快照格式版本：结构有不兼容改动时 +1，旧文件自动作废（iOS 同款） */
        const val VERSION = 1
    }
}

@Singleton
class LibraryHomeSnapshotStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val json: Json,
) {
    private val scope = AppScopes.io("LibraryHomeSnapshotStore")

    private fun directory(): File = File(context.cacheDir, "home-snapshots").apply { mkdirs() }

    private fun fileFor(owner: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray())
            .joinToString("") { "%02x".format(it) }.take(32)
        return File(directory(), "library-home-$digest.json")
    }

    // 上次写盘的指纹：没变就不重写（收藏一下、轮询回包都不必反复落盘）
    @Volatile private var lastWritten: String? = null

    suspend fun read(owner: String): LibraryHomeSnapshot? = withContext(Dispatchers.IO) {
        runCatching {
            val file = fileFor(owner)
            if (!file.exists()) return@runCatching null
            json.decodeFromString<LibraryHomeSnapshot>(file.readText())
                .takeIf { it.version == LibraryHomeSnapshot.VERSION }
        }.getOrNull()
    }

    fun write(owner: String, snapshot: LibraryHomeSnapshot) {
        val text = runCatching { json.encodeToString(snapshot) }.getOrNull() ?: return
        if (text == lastWritten) return
        lastWritten = text
        scope.launch {
            runCatching { fileFor(owner).writeText(text) }
        }
    }

    /** 退出登录 / 移除账号时清掉（快照按账号存，别让换账号后还画着上一个账号的数据） */
    fun clear() {
        lastWritten = null
        scope.launch { runCatching { directory().deleteRecursively() } }
    }
}
