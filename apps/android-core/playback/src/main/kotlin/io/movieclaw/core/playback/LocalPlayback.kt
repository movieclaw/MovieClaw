package io.movieclaw.core.playback

import io.movieclaw.core.model.generated.PlaybackItemView
import io.movieclaw.core.model.generated.PlaybackSessionView
import io.movieclaw.core.model.generated.SeasonEpisodesView

/**
 * 本机副本（离线下载，docs/design/offline-download.md §6；对照 Apple 端 `PlaybackController.startLocal`）：
 * 这一集（这部电影）在手机上有下完的副本时直接放本机文件，不建服务端会话、不心跳。
 * 手机端实现它；电视不做离线，不传。
 */
interface LocalPlaybackSource {
    /** 本机目录读完为止：冷启动直达播放时先等它，不然判成「没有副本」去连服务器 */
    suspend fun awaitLoaded() = Unit

    /**
     * 这个单元有能播的本机副本：给一个与服务端会话同形的会话（`stream_url` 是 `file://`，旁挂字幕也是本机文件）
     * 和这次播放的观看记录。没有返回 null，照常走服务器。[startMs] 为 null 时由它定续播点（在线时问服务器）。
     */
    suspend fun open(unit: PlaybackUnit, startMs: Long?): LocalPlayback?

    /** 条目信息：离线时取本机的；在线时照常问服务器（[remote]），问不到而本机有副本时回落本机 */
    suspend fun itemInfo(mediaItemId: Long, remote: suspend () -> PlaybackItemView): PlaybackItemView = remote()

    /** 分集：本机有这部剧的副本时，离线（或连不上）取本机存档，「在库」= 本机有，下一集只在本机有的集里找 */
    suspend fun episodes(mediaItemId: Long, season: Long, remote: suspend () -> SeasonEpisodesView): SeasonEpisodesView = remote()

    /** 引擎打不开本机文件：标成「已损坏」，提示重新下载。返回 true = 在线、可以改走服务器接着放 */
    fun damaged(unit: PlaybackUnit, fileId: Long): Boolean

    /** 能不能改走服务器（在线）：本机放得卡（掉帧）时据此决定换服务器转码还是接着放 */
    fun canUseServer(): Boolean = false
}

/** 一次本机播放：会话 + 观看记录 */
class LocalPlayback(val session: PlaybackSessionView, val viewing: LocalViewing)

/**
 * 本机播放的观看记录（§7）：本机播放一律走这条，流式播放照旧实时上报，两条不混用。
 * 先落盘再发：每 10 秒、暂停、退后台时写一次，能连上就发，连不上攒着、回来后补传。
 */
interface LocalViewing {
    /** 播放读数（每秒一次）：只有在播的墙钟时间算观看时长 */
    fun tick(positionMs: Long, playing: Boolean, durationMs: Long?)

    /** 暂停、退后台：立即落一次盘并尝试发出 */
    fun checkpoint()

    /** 这次播放结束（退出、换集、播完） */
    fun finish(positionMs: Long, completed: Boolean)
}
