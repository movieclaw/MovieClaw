@file:androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)

package io.movieclaw.android.core.session

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.playback.SourceByteCache
import javax.inject.Inject
import javax.inject.Singleton

/**
 * 退出登录 / 移除账号时的本机缓存清理（iOS `PageSnapshots.remove` 那套的对应物）。
 *
 * iOS 的快照按「服务器 + 账号」分目录、退出即删；我的图片缓存与片源字节缓存是
 * **跨账号共用**的，所以这里只能整份清掉——不清的话，换账号后同一 URL 的图、
 * 同一个文件的字节还会命中上一个账号留下的缓存。
 * 会话令牌与账号表由 `SessionRepository` 自己清，这里只管展示/播放缓存。
 */
@Singleton
class SessionCacheCleaner @Inject constructor(
    @ApplicationContext private val context: Context,
    private val imageLoaders: io.movieclaw.android.core.designsystem.ImageLoaders,
    private val homeSnapshots: LibraryHomeSnapshotStore,
) {
    suspend fun clear() {
        runCatching { imageLoaders.clear() }
        runCatching { SourceByteCache.clear(context) }
        runCatching { homeSnapshots.clear() }
    }
}
