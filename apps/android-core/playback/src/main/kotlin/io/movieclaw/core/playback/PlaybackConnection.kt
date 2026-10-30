package io.movieclaw.core.playback

import io.movieclaw.core.network.ServerAddress

/** 同一轮播放协商的 API 通道和媒体入口快照。 */
data class PlaybackConnection(val backend: PlaybackBackend, val server: ServerAddress)
