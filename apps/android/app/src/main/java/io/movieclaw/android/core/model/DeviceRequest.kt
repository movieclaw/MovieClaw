package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/** 一条待批准的设备接入请求（v0.31 `GET /auth/devices/requests/{user_code}`） */
@Serializable
data class DeviceRequestView(
    val userCode: String = "",
    /** ios / tvos / android / worker（转码器）/ cli … */
    val clientType: String = "",
    val clientName: String = "",
    /**
     * 请求来源 IP（帮用户判断是不是自己那台机器）；
     * 容器桥接网络会把源地址 NAT 掉，那种情况下为空串，界面如实说无法确定
     */
    val sourceIp: String = "",
    /** 剩余有效秒数 */
    val expiresIn: Int = 0,
    val platform: String? = null,
    val clientVersion: String? = null,
    /** 只有管理员能批准（转码器）；成员看到时应说明原因 */
    val requiresAdmin: Boolean = false,
)
