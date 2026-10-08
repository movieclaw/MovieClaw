package io.movieclaw.android.core.playback

import io.movieclaw.android.core.session.TokenVault
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/** 已落库的成员播放变更；StateFlow 保留退出导航之前发生的变更。访客不发布。 */
@Singleton
class PlaybackDataEvents @Inject constructor() {
    data class Change(val identity: TokenVault.Identity, val revision: Long)
    private val mutable = MutableStateFlow<Change?>(null)
    val changes = mutable.asStateFlow()

    fun committed(identity: TokenVault.Identity) {
        mutable.value = Change(identity, (mutable.value?.revision ?: 0L) + 1L)
    }
}
