package io.movieclaw.android.core.session

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.tabBarStore by preferencesDataStore(name = "mc_tabbar")

/**
 * 底栏形态开关（A/B 对比试用）：开 = 新液态玻璃底栏（弹簧胶囊 / 按压辉光 / 高光边 /
 * 收缩形态对齐 / 拖动擦选），关 = 当前形态。记在本机，默认关。
 *
 * 这是**试用开关**，不是正式设置：两边对齐稳定后会删掉一边。
 */
@Singleton
class TabBarPrefs @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    val liquid: Flow<Boolean> = context.tabBarStore.data.map { it[KEY_LIQUID] ?: false }

    suspend fun setLiquid(on: Boolean) {
        context.tabBarStore.edit { it[KEY_LIQUID] = on }
    }

    private companion object {
        val KEY_LIQUID = booleanPreferencesKey("liquid_tabbar")
    }
}
