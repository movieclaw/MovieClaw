package io.movieclaw.androidtv.system

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import io.movieclaw.androidtv.core.model.generated.UpNextItemView
import io.movieclaw.androidtv.core.network.ImageUrls
import io.movieclaw.androidtv.core.network.ServerAddress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File

/**
 * 系统首页的「继续观看」行（Apple 端 Top Shelf 的对应：TVTopShelfPublisher）：把首页的「接下来继续」前 8 部发布成
 * Watch Next 节目，选中直接续播（深链 `movieclaw://play/<条目>?season=&episode=`）。
 *
 * 图片接口要登录、系统桌面拉图不会带我们的令牌，所以先下载到本机，经 [WatchNextImageProvider] 只读交给系统
 * （同 Apple 端把图写进 App Group 给扩展读）。
 */
class WatchNextPublisher(private val context: Context, private val http: OkHttpClient) {
    private val prefs = context.getSharedPreferences("watch_next", Context.MODE_PRIVATE)
    private var lastFingerprint: Int? = null

    suspend fun publish(items: List<UpNextItemView>, server: ServerAddress, token: String) = withContext(Dispatchers.IO) {
        val picked = items.take(LIMIT)
        val fingerprint = (listOf(server.toString()) + picked.map { "${it.mediaItemId}-${it.seasonNumber}-${it.episodeNumber}-${it.progressPercent}" }).hashCode()
        if (fingerprint == lastFingerprint) return@withContext
        lastFingerprint = fingerprint
        try {
            removePublished()
            val dir = imageDir().apply { mkdirs() }
            dir.listFiles()?.forEach { it.delete() }
            val ids = mutableListOf<Long>()
            for (item in picked) {
                val episode = item.kind == "tv"
                val name = "${item.mediaItemId}-${item.seasonNumber}-${item.episodeNumber}.jpg"
                val raw = item.backdropUrl ?: (if (episode) item.episodeStillUrl else null) ?: item.posterUrl
                val image = ImageUrls.build(server, raw, 1280)?.let { url -> download(url.toString(), token, File(dir, name)) }
                val play = Uri.parse("movieclaw://play/${item.mediaItemId}" + if (episode) "?season=${item.seasonNumber}&episode=${item.episodeNumber}" else "")
                val program = WatchNextProgram.Builder()
                    .setType(if (episode) TvContractCompat.PreviewPrograms.TYPE_TV_EPISODE else TvContractCompat.PreviewPrograms.TYPE_MOVIE)
                    .setWatchNextType(if (item.positionMs > 0) TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE else TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_NEXT)
                    .setLastEngagementTimeUtcMillis(System.currentTimeMillis())
                    .setTitle(item.title)
                    .apply {
                        if (episode) {
                            setEpisodeTitle(item.episodeTitle ?: "第 ${item.episodeNumber} 集")
                            setSeasonNumber(item.seasonNumber.toInt())
                            setEpisodeNumber(item.episodeNumber.toInt())
                        }
                        item.durationMs?.let { setDurationMillis(it.toInt()) }
                        if (item.positionMs > 0) setLastPlaybackPositionMillis(item.positionMs.toInt())
                        if (image != null) {
                            setPosterArtUri(WatchNextImageProvider.uri(context, name))
                            setPosterArtAspectRatio(TvContractCompat.PreviewPrograms.ASPECT_RATIO_16_9)
                        }
                    }
                    .setIntentUri(play)
                    .setInternalProviderId("${item.mediaItemId}-${item.seasonNumber}-${item.episodeNumber}")
                    .build()
                context.contentResolver.insert(TvContractCompat.WatchNextPrograms.CONTENT_URI, program.toContentValues())
                    ?.let { ids += android.content.ContentUris.parseId(it) }
            }
            prefs.edit().putString(KEY_IDS, ids.joinToString(",")).apply()
        } catch (e: Exception) {
            // 不是每台电视都有 TvProvider（部分国产 ROM 阉掉了）：发不了就算了
            Log.w(TAG, "继续观看发布失败", e)
        }
    }

    /** 退出登录时清掉（同 Apple 端 TVTopShelfPublisher.clear） */
    @SuppressLint("RestrictedApi")
    suspend fun clear() = withContext(Dispatchers.IO) {
        lastFingerprint = null
        runCatching { removePublished() }
        imageDir().listFiles()?.forEach { it.delete() }
    }

    private fun removePublished() {
        prefs.getString(KEY_IDS, null)?.split(",")?.mapNotNull { it.toLongOrNull() }?.forEach { id ->
            runCatching { context.contentResolver.delete(TvContractCompat.buildWatchNextProgramUri(id), null, null) }
        }
        prefs.edit().remove(KEY_IDS).apply()
    }

    private fun download(url: String, token: String, target: File): File? = runCatching {
        http.newCall(Request.Builder().url(url).header("Authorization", "Bearer $token").build()).execute().use { resp ->
            if (!resp.isSuccessful) return null
            target.outputStream().use { out -> resp.body.byteStream().copyTo(out) }
            target
        }
    }.getOrNull()

    private fun imageDir() = File(context.cacheDir, WatchNextImageProvider.DIR)

    private companion object {
        const val TAG = "WatchNext"
        const val LIMIT = 8
        const val KEY_IDS = "program_ids"
    }
}
