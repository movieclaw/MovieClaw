package io.movieclaw.android.core.playback

/**
 * 双内核统一调用面:PlaybackController 与播放器 UI 不感知具体引擎。
 * position/duration 等读数一律为「播放器相对时间」;文件绝对时间换算在 controller。
 * 所有方法要求在主线程调用(ExoPlayer 线程约束;mpv API 线程安全,统一收紧)。
 */
interface PlayerEngine {
    fun open(source: EngineSource, sidecars: List<Sidecar> = emptyList())
    fun positionMs(): Long
    fun durationMs(): Long
    fun isPlaying(): Boolean
    fun setPlaying(playing: Boolean)
    fun seekTo(playerMs: Long)
    fun seekBy(deltaMs: Long)
    fun setSpeed(speed: Float)

    /** 按容器/轨道顺序选择音轨(与服务端 audio_tracks 枚举序一致) */
    fun selectAudioIndex(index: Int) {}

    /** 选择文本字幕轨;null = 关闭字幕 */
    fun selectTextIndex(index: Int?) {}

    /**
     * 字幕渲染开关：外挂 libass 叠层接管时**必须关掉引擎自己的字幕渲染**，
     * 否则两层叠着画——上层是引擎的（带黑框），看起来就像"libass 也没去掉黑框"。
     * Exo 关文本轨类型；mpv 关 sub-visibility（保留选中的 sid，便于随时切回来）。
     */
    fun setSubtitleRendering(enabled: Boolean) {}

    /**
     * 从**引擎自己**读到的内封轨（音轨 / 字幕）。
     *
     * 服务端读不了光盘镜像的盘内结构，镜像的轨清单只能由引擎在本机读出
     * （iOS `AudioOption.engineOptions` / `SubtitleTracks.adoptEngineSubtitles` 同理）。
     * 返回空表示引擎还没解析出来（刚起播时正常）。
     */
    fun embeddedTracks(): EngineTracks = EngineTracks()

    /** 是否卡在中转/缓冲(降质看门狗用) */
    fun isBuffering(): Boolean = false

    fun release()
}

data class EngineTrack(
    /** 引擎内部的轨 id（mpv 的 aid/sid） */
    val id: Int,
    val language: String? = null,
    val title: String? = null,
    val codec: String? = null,
    val channels: Int = 0,
    val selected: Boolean = false,
)

/** 引擎读到的轨清单（按 id 升序，与 selectAudioIndex/selectTextIndex 的下标口径一致） */
data class EngineTracks(
    val audio: List<EngineTrack> = emptyList(),
    val subtitle: List<EngineTrack> = emptyList(),
) {
    val isEmpty: Boolean get() = audio.isEmpty() && subtitle.isEmpty()
}

data class EngineSource(
    val url: String,
    val hls: Boolean,
    val startPositionMs: Long,
    /** 媒体通知/锁屏展示用(标题、副标题、海报) */
    val title: String = "",
    val subtitle: String? = null,
    val artworkUrl: String? = null,
    /** 服务端随会话下发的 MKV 精简索引（档 0 直出才有）：Exo 按 SeekHead 读 Cues 时直接给 */
    val matroskaCues: io.movieclaw.android.core.model.MatroskaCuesView? = null,
    /**
     * 起播要放的那条音轨（中性引用 `embedded:N`）——**服务端计划里的那条**（用户这次选的
     * 或按记忆/默认轨策略挑的）。引擎解析出轨道后要按它落轨：以前只在界面上打勾，
     * 引擎放的是容器标注的默认轨，于是"菜单勾着国语、耳朵听的是日语"。
     */
    val initialAudioRef: String? = null,
    /**
     * 片源字节缓存的键（`SourceByteCache.key(fileId, size)`）：给了就挂缓存层，
     * 放过的字节落盘，同一个文件下次起播直接读本地（正片与刷片共用一份，见 SourceByteCache）。
     */
    val cacheKey: String? = null,
    /** 装载后是否直接播（预起下一条时 false：装载到片段起点停着，滑过去才播） */
    val autoplay: Boolean = true,
)

/** 外挂字幕旁挂载荷(Exo 合流;MPV 后续走 sub-add) */
data class Sidecar(val url: String, val mime: String, val language: String?)
