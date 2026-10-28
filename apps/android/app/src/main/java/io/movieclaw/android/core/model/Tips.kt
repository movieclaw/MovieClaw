package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/* ══════════ 使用提示（docs/design/tips.md） ══════════ */

/** 一条提示的展示与作废情况；没出现在列表里的提示 = 从没展示过、仍有效 */
@Serializable
data class TipRecordView(
    val tipId: String = "",
    val displayCount: Int = 0,
    val firstDisplayedAt: String? = null,
    val lastDisplayedAt: String? = null,
    val invalidatedAt: String? = null,
    val invalidatedReason: String? = null,
)

/** 我的提示状态（事件计数这一端还没用上，不解析） */
@Serializable
data class TipStateView(
    val tips: List<TipRecordView> = emptyList(),
)

/** 作废原因：`action_performed` 用过了提示说的功能，`closed` 用户关掉 */
@Serializable
data class InvalidateTipRequest(
    val reason: String? = null,
)
