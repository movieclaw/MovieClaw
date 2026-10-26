@file:OptIn(UnstableApi::class)

package io.movieclaw.core.playback.disc

import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.source.ClippingMediaSource
import androidx.media3.exoplayer.source.ConcatenatingMediaSource2
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.ExtractorsFactory
import io.movieclaw.core.model.generated.PlaybackBlurayView

/**
 * 服务端的剪辑清单 → Exo 的媒体源（disc-clip-play.md §4.3）：每段剪辑按播放列表的 IN / OUT 裁好，首尾相接成一条。
 * 播放器上的位置就是播放列表时间（0 = 第一段的 IN），与服务端的进度、章节、缩略图、片头片尾同一口径。
 */
object BluRaySource {
    /** 清单里有地址解析不了的剪辑时返回 null */
    fun build(view: PlaybackBlurayView, item: MediaItem, network: DataSource.Factory, resolve: (String) -> String?): MediaSource? {
        if (view.clips.isEmpty()) return null
        val streams = BluRayStreams(view.audio, view.subtitles)
        val m2ts = M2tsDataSource.Factory(network)
        val builder = ConcatenatingMediaSource2.Builder().setMediaItem(item)
        for (clip in view.clips) {
            val url = resolve(clip.url) ?: return null
            val seekMap = BluRayClipExtractor.seekMap(clip)
            val extractors = ExtractorsFactory { arrayOf(BluRayClipExtractor(seekMap, streams)) }
            val progressive = ProgressiveMediaSource.Factory(m2ts, extractors).createMediaSource(MediaItem.fromUri(url))
            val clipped = ClippingMediaSource.Builder(progressive)
                .setStartPositionUs(BluRayClipExtractor.ptsToUs(clip.inTime))
                .setEndPositionUs(BluRayClipExtractor.ptsToUs(clip.outTime))
                .build()
            builder.add(clipped, (clip.outTime - clip.inTime) / 45)
        }
        return builder.build()
    }
}
