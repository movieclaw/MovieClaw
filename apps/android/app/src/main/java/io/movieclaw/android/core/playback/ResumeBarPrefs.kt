package io.movieclaw.android.core.playback

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first

private val Context.resumeStore by preferencesDataStore(name = "mc_resume_bar")

/**
 * 「接下来继续」条的本机显示偏好（iOS `ResumeBarStore` 的对应物）。
 *
 * 右边的 ✕ 把这条叉掉：叉掉后一直不显示，直到**这台设备**又播了它。恢复不靠另调接口——
 * key 里带上叉掉那一刻的上次播放时间（`lastPlayedAt`），再播一次这个时间就变了，
 * 这条 key 不再匹配、卡片自然回来（iOS 同款：`.mediaItemId|season|episode|lastPlayedAt`）。
 * 存 DataStore，重启也不冒出来。
 */
@Singleton
class ResumeBarPrefs @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    /** key：`mediaItemId:season:episode:lastPlayedAt`（电影季集为 0/0） */
    suspend fun hiddenIds(): Set<String> =
        context.resumeStore.data.first()[KEY_HIDDEN] ?: emptySet()

    suspend fun hide(key: String) {
        context.resumeStore.edit { prefs ->
            // 同一单元只留最新一条：再叉一次换掉旧的（否则每叉一次都留一条陈旧 key）
            val unit = key.substringBeforeLast(':') + ":"
            val kept = (prefs[KEY_HIDDEN] ?: emptySet()).filterNot { it.startsWith(unit) }
            prefs[KEY_HIDDEN] = kept.toSet() + key
        }
    }

    companion object {
        val KEY_HIDDEN = stringSetPreferencesKey("up_next_hidden")

        fun keyOf(mediaItemId: Long, season: Int, episode: Int, lastPlayedAt: String?) =
            "$mediaItemId:$season:$episode:${lastPlayedAt.orEmpty()}"
    }
}
