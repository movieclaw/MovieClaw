package io.movieclaw.android.core.playback

import io.movieclaw.android.core.model.UpNextItem

/**
 * 把各处的数据模型折成 [PlayTarget]。
 * 之前这个映射散在发现页里，媒体库页也要用，集中一处避免两份漂移。
 */
object PlayTargetFactory {

    /** 「接下来继续」条目 → 播放目标（带季/集，字幕行交给调用方） */
    fun fromUpNext(item: UpNextItem, subtitle: String? = null): PlayTarget = PlayTarget(
        mediaItemId = item.mediaItemId,
        libraryId = item.libraryId,
        kind = item.kind,
        title = item.title,
        subtitle = subtitle,
        seasonNumber = item.seasonNumber,
        episodeNumber = item.episodeNumber,
    )
}
