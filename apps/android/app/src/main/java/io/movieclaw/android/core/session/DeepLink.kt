package io.movieclaw.android.core.session

import io.movieclaw.android.core.model.ShareLink
import io.movieclaw.android.core.network.ServerAddress
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 深链中继:Activity 解析出的分享链接放这里,根状态机消费后导航。
 * 访客分享**不需要登录**,所以它与会话状态并行处理。
 */
@Singleton
class DeepLinkBus @Inject constructor() {
    private val _pendingShare = MutableStateFlow<ShareLink?>(null)
    val pendingShare: StateFlow<ShareLink?> = _pendingShare.asStateFlow()

    fun publish(link: ShareLink) {
        _pendingShare.value = link
    }

    fun consume(): ShareLink? = _pendingShare.value?.also { _pendingShare.value = null }

    /** 从 intent data 解析:movieclaw://share/<slug>?origin=… 或 https://host/s/<slug> */
    fun parse(uri: String?): ShareLink? {
        if (uri.isNullOrEmpty()) return null
        val parsed = runCatching { android.net.Uri.parse(uri) }.getOrNull() ?: return null
        val scheme = parsed.scheme?.lowercase() ?: return null
        if (scheme == "movieclaw") {
            if (parsed.host != "share") return null
            val slug = parsed.pathSegments.firstOrNull() ?: return null
            val origin = parsed.getQueryParameter("origin") ?: return null
            val normalized = ServerAddress.normalize(origin) ?: return null
            return ShareLink(origin = normalized.origin, slug = slug)
        }
        if (scheme != "http" && scheme != "https") return null
        val segments = parsed.pathSegments ?: return null
        if (segments.size < 2 || segments[0] != "s") return null
        val slug = segments[1]
        val port = if (parsed.port > 0) ":${parsed.port}" else ""
        return ShareLink(origin = "$scheme://${parsed.host}$port", slug = slug)
    }
}
