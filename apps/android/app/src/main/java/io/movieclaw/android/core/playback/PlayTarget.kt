package io.movieclaw.android.core.playback

/** 一次点播目标:详情页/继续观看卡 → 播放器会话的中转载荷 */
data class PlayTarget(
    val mediaItemId: Long,
    val libraryId: Long,
    val kind: String,
    val title: String,
    val subtitle: String? = null,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    /**
     * 详情页里选好的起播轨（中性引用 `embedded:N` / `external:文件名`）。
     * null = 没选过，交给服务端的轨记忆决定（本集记着的 > 沿用上一集 > 默认轨策略）。
     */
    val preferredAudio: String? = null,
    val preferredSubtitle: String? = null,
    /**
     * 片源是原盘（ISO 镜像 / BDMV 目录）。本机引擎读不了盘内结构——mpv 没编 libbluray，
     * 见 [DeviceCapability.probe] 的说明。带上它，协商时就不申报 `universal`：
     * 服务端会明确拒绝镜像，或把 BDMV 目录按主播放列表拼接成 HLS（不重编码），
     * 而不是把一堆我们解析不了的字节丢过来。
     */
    val discSource: Boolean = false,
    /**
     * 起播位置（毫秒，原片时间轴）。null = 交给服务端按观看状态定（续播点）。
     * 刷片的「全屏观看」用它：把这一段的起点带过去，而不是从续播点接着放。
     */
    val startMs: Long? = null,
)
