package io.movieclaw.android.core.offline

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

private val Context.offlinePrefsStore by preferencesDataStore(name = "mc_offline")

/**
 * 离线下载的本机设置（对齐 iOS `OfflineSettings`）：
 * - [allowCellular] 默认关 = 只在 Wi-Fi 下下载（iOS 同款）；
 * - [lastProfile] 上次选的档位，下次打开选档面板默认选它。
 */
@Singleton
class OfflinePrefs @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    val allowCellular: StateFlow<Boolean> = context.offlinePrefsStore.data
        .map { it[KEY_CELLULAR] ?: false }
        .stateIn(scope, SharingStarted.Eagerly, false)

    val lastProfile: StateFlow<String?> = context.offlinePrefsStore.data
        .map { it[KEY_PROFILE] }
        .stateIn(scope, SharingStarted.Eagerly, null)

    suspend fun setAllowCellular(on: Boolean) {
        context.offlinePrefsStore.edit { it[KEY_CELLULAR] = on }
    }

    suspend fun setLastProfile(profile: String) {
        context.offlinePrefsStore.edit { it[KEY_PROFILE] = profile }
    }

    private companion object {
        val KEY_CELLULAR = booleanPreferencesKey("allow_cellular")
        val KEY_PROFILE = stringPreferencesKey("last_profile")
    }
}
