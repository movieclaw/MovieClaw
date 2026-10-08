package io.movieclaw.android.core.session

import androidx.compose.runtime.staticCompositionLocalOf
import io.movieclaw.android.core.model.SessionView

/**
 * 权限快照（同 Web `lib/permissions.ts` / iOS `Permissions.swift`）。
 *
 * 客户端据此裁剪入口，**安全边界始终在后端 403**——这里只是不让人点了再被拒。
 * 三个能力开关由 `SessionView.capabilities` 下发，超管恒为全真。
 */
data class Permissions(
    val isAdmin: Boolean = false,
    val canSubscribe: Boolean = false,
    /** 资源搜索（PT 站点）。媒体库内搜索不受此开关限制 */
    val canSearch: Boolean = false,
    val canDirectDownload: Boolean = false,
) {
    val canManageLibraries: Boolean get() = isAdmin
    val canManageSubscriptions: Boolean get() = isAdmin

    /**
     * 订阅详情「手动选种」/ 资源结果「投给订阅」：先搜资源、再把选中的种子投给下载器，
     * 所以要同时具备订阅、资源搜索与一键下载三项能力；订阅归属（只能投给自己发起的订阅）
     * 由后端校验（member-permissions-v2 §3.7）。
     */
    val canGrabForSubscription: Boolean
        get() = isAdmin || (canSubscribe && canSearch && canDirectDownload)

    companion object {
        val None = Permissions()

        fun of(session: SessionView?): Permissions {
            if (session == null) return None
            val admin = session.role == "admin"
            return Permissions(
                isAdmin = admin,
                canSubscribe = admin || session.capabilities.allowSubscribe,
                canSearch = admin || session.capabilities.allowSearch,
                canDirectDownload = admin || session.capabilities.allowDirectDownload,
            )
        }
    }
}

/**
 * 当前账号权限，由 `MovieClawRoot` 注入（换账号即整体重建）。
 * 页面读它裁剪入口，不再各自注入 SessionRepository 判断角色。
 */
val LocalPermissions = staticCompositionLocalOf { Permissions.None }

/**
 * 头像徽标字：中文取首字，拉丁字母取前两位大写（同 Web `initialsOf` / iOS `SessionView.initials`）。
 * 昵称留空时回退用户名；都没有给「?」——底栏与「我的」页头像共用，两处口径一致。
 */
fun SessionView?.initials(): String {
    val name = (this?.nickname?.takeIf { it.isNotBlank() } ?: this?.username ?: "").trim()
    if (name.isEmpty()) return "?"
    val first = name.first()
    return if (first.code in 0x4E00..0x9FFF) first.toString() else name.take(2).uppercase()
}
