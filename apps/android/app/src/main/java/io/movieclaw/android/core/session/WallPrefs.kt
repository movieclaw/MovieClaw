package io.movieclaw.android.core.session

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first

private val Context.wallStore by preferencesDataStore(name = "mc_wall_prefs")

/**
 * 海报墙 / 图廊的本机偏好（iOS `WallSortState` + `GalleryPrefs`，键名沿用 Web 的 localStorage 键）：
 * 排序档与方向、图床浏览开关、是否按作品分组、瀑布流密度。
 *
 * 只是本机的便利设置，**不是账号数据**——所以不进服务端，也不随账号切换清理。
 */
@Singleton
class WallPrefs @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    data class Snapshot(
        val sort: String = "default",
        val reversed: Boolean = false,
        val galleryMode: Boolean = false,
        val galleryGrouped: Boolean = true,
        /** compact / standard / loose */
        val galleryDensity: String = "standard",
    )

    suspend fun read(): Snapshot = context.wallStore.data.first().let { prefs ->
        Snapshot(
            sort = prefs[KEY_SORT] ?: "default",
            reversed = prefs[KEY_SORT_REVERSED] ?: false,
            galleryMode = prefs[KEY_GALLERY_MODE] ?: false,
            galleryGrouped = prefs[KEY_GALLERY_GROUPED] ?: true,
            galleryDensity = prefs[KEY_GALLERY_DENSITY] ?: "standard",
        )
    }

    suspend fun saveSort(sort: String, reversed: Boolean) {
        context.wallStore.edit { it[KEY_SORT] = sort; it[KEY_SORT_REVERSED] = reversed }
    }

    suspend fun saveGalleryMode(on: Boolean) {
        context.wallStore.edit { it[KEY_GALLERY_MODE] = on }
    }

    suspend fun saveGalleryGrouped(on: Boolean) {
        context.wallStore.edit { it[KEY_GALLERY_GROUPED] = on }
    }

    suspend fun saveGalleryDensity(value: String) {
        context.wallStore.edit { it[KEY_GALLERY_DENSITY] = value }
    }

    companion object {
        // 「movieclaw.favorites.wall-sort」等键名与 iOS/Web 同一套，方便对照排查
        val KEY_SORT = stringPreferencesKey("movieclaw.favorites.wall-sort")
        val KEY_SORT_REVERSED = booleanPreferencesKey("movieclaw.favorites.wall-sort-reversed")
        val KEY_GALLERY_MODE = booleanPreferencesKey("movieclaw.library.gallery-mode")
        val KEY_GALLERY_GROUPED = booleanPreferencesKey("movieclaw.library.gallery-grouped")
        val KEY_GALLERY_DENSITY = stringPreferencesKey("movieclaw.photo-wall.density")
    }
}
