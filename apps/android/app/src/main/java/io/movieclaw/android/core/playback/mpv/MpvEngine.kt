package io.movieclaw.android.core.playback.mpv

import android.content.Context
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import io.movieclaw.android.core.playback.EngineSource
import io.movieclaw.android.core.playback.EngineTrack
import io.movieclaw.android.core.playback.EngineTracks
import io.movieclaw.android.core.playback.PlayerEngine
import io.movieclaw.android.core.playback.Sidecar
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * MPV 万能内核(AetherEngine 的 Android 对位):
 *   libmpv(vo=gpu-next + gpu-context=android)直渲 SurfaceView,不经过任何纹理管线;
 *   VC-1/MPEG-2/TrueHD/PGS 本地全解,ASS 特效字幕由内核内置 libass 渲染进视频。
 * Surface 契约与 mpv-android 官方一致(按已验证的版本实现):
 *   attach = 全局引用 + wid;detach = wid=0 → vo=null;尺寸唯一入口 = android-surface-size。
 */
class MpvEngine(private val context: Context) : PlayerEngine {

    val surfaceView: SurfaceView = SurfaceView(context)

    private var handle = 0L
    private var released = false
    private var desiredPlaying = true
    private var desiredSpeed = 1.0f
    private var pendingInitialAudioIndex: Int? = null
    private var loadedGenerationBeforeOpen = 0L

    /** 引擎自己的字幕渲染：默认关（字幕一律交本机叠层）；只有光盘镜像才翻成开 */
    private var subtitleRendering = false

    /** FILE_LOADED 后才补落文件选项，避免 loadfile 的异步重置覆盖宿主选择。 */
    private var visibilityAppliedForFile = false
    private var surfaceReady = false
    private val pending = ArrayDeque<(Surface) -> Unit>()
    private val cacheDir = File(context.cacheDir, "mpv_stream_cache").apply { mkdirs() }
    private val fontsDir = File(context.filesDir, "fonts").apply { mkdirs() }

    private val holderCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            val hadHandle = handle != 0L
            surfaceReady = true
            holder.surface?.let { surface ->
                while (pending.isNotEmpty()) pending.removeFirst().invoke(surface)
            }
            if (hadHandle && handle != 0L) {
                MpvNative.nativeAttachSurface(handle, holder.surface)
                MpvNative.nativeSetProperty(handle, "vo", "gpu-next")
            }
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            if (handle != 0L) {
                MpvNative.nativeSetProperty(handle, "android-surface-size", "${width}x$height")
            }
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            surfaceReady = false
            if (handle != 0L) {
                MpvNative.nativeSetProperty(handle, "vo", "null")
                MpvNative.nativeDetachSurface(handle)
            }
        }
    }

    init {
        surfaceView.holder.addCallback(holderCallback)
    }

    private fun setProperty(name: String, value: String) {
        if (handle != 0L) MpvNative.nativeSetProperty(handle, name, value)
    }

    /** 内核选项配方:全部来自真机实证(每条理由见设计方案 §6.2) */
    private fun applyCoreOptions() {
        setProperty("vo", "gpu-next")
        setProperty("gpu-context", "android")
        // 字幕一律由本机叠层画（`SubtitleCues` 解析成纯文本 cue，字号/位置/背景按用户设置）：
        // mpv 默认会自动选中内封字幕轨并用 libass 再画一层——实机反馈「一大一小两个字幕、还重叠」
        // （4K HDR10 走 mpv 时抓到：mpv 选 --sid=1 渲染 + 本机叠层同时画）。
        // 只压可见性不动 sid：光盘镜像（PGS/盘内文本轨）那条路径要靠 mpv 自己渲染，
        // `setEngineSubtitleRendering(true)` 翻回 `sub-visibility=yes` 就能接上。
        setProperty("sub-visibility", "no")
        setProperty("hwdec", "mediacodec,mediacodec-copy")
        setProperty("osc", "no")
        setProperty("tone-mapping", "auto")
        setProperty("hdr-compute-peak", "no")
        setProperty("scale", "bilinear")
        setProperty("cscale", "bilinear")
        setProperty("dscale", "bilinear")
        setProperty("dither-depth", "no")
        setProperty("video-sync", "audio")
        setProperty("vd", "-magicyuv")
        // 刻意不开 reconnect_on_http_error:302/4xx 签名过期必须上抛换流
        setProperty(
            "stream-lavf-o",
            "timeout=10000000,reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=30",
        )
        setProperty("cache", "yes")
        setProperty("cache-on-disk", "yes")
        setProperty("cache-dir", cacheDir.absolutePath)
        setProperty("demuxer-max-bytes", "67108864")
        setProperty("demuxer-max-back-bytes", "16777216")
        setProperty("demuxer-readahead-secs", "60")
        setProperty("cache-secs", "300")
        setProperty("cache-pause-wait", "3")
        setProperty("cache-pause-initial", "no")
        setProperty("ao", "audiotrack,opensles")
        setProperty("audio-channels", "stereo")
        setProperty("ad", "lavc")
        setProperty("sub-fonts-dir", fontsDir.absolutePath)
    }

    override fun open(source: EngineSource, sidecars: List<Sidecar>) {
        if (released) return
        // sidecars 仍由上层字幕叠层处理。
        visibilityAppliedForFile = false
        pendingInitialAudioIndex = source.initialAudioRef
            ?.takeIf { it.startsWith("embedded:") }
            ?.removePrefix("embedded:")?.toIntOrNull()?.takeIf { it >= 0 }
        pending.clear() // Surface 未就绪时，替换起播请求，不排队打开已过期的源。
        runWhenSurface { surface ->
            if (handle == 0L) {
                handle = MpvNative.nativeCreate(surface)
                if (handle != 0L) applyCoreOptions()
            }
            if (handle != 0L) {
                if (surfaceView.width > 0 && surfaceView.height > 0) {
                    MpvNative.nativeSetProperty(
                        handle,
                        "android-surface-size",
                        "${surfaceView.width}x${surfaceView.height}",
                    )
                }
                MpvNative.nativeSetProperty(
                    handle,
                    "start",
                    if (source.startPositionMs > 0) "${source.startPositionMs / 1000.0}" else "none",
                )
                loadedGenerationBeforeOpen = fileLoadedGeneration()
                MpvNative.nativeCommand(handle, "loadfile \"${source.url}\" replace")
                // 关键时序：`sub-visibility` 是 mpv 的**每文件选项**——loadfile 时会被配置默认值
                // （yes）重置，所以「建句柄时设一次」保不住（实机：灵魂摆渡仍被 mpv 画了一层，
                // 和本机叠层叠成两个）。加载之后立刻再落一次，按粘住的开关值来。
                applyDesiredPlaybackState()
                applySubtitleVisibility()
            }
        }
    }

    /** 引擎自己的字幕渲染开关（外挂叠层接管时为 false）——句柄没建也记住，建好/加载后补上 */
    private fun applySubtitleVisibility() {
        if (handle == 0L) return
        MpvNative.nativeSetProperty(handle, "sub-visibility", if (subtitleRendering) "yes" else "no")
        android.util.Log.i("McMpv", "字幕渲染=${if (subtitleRendering) "引擎（光盘镜像）" else "本机叠层"}")
    }

    private fun runWhenSurface(block: (Surface) -> Unit) {
        val surface = if (surfaceReady) surfaceView.holder.surface else null
        if (surface != null) {
            block(surface)
        } else {
            pending.add(block)
        }
    }

    private fun getSecondsMs(name: String): Long =
        if (handle == 0L) {
            0L
        } else {
            val seconds = MpvNative.nativeGetProperty(handle, name)?.toDoubleOrNull() ?: 0.0
            (seconds * 1000).toLong()
        }

    private fun fileLoadedGeneration(): Long = if (handle == 0L) 0L else
        MpvNative.nativeGetProperty(handle, "movieclaw-file-loaded")?.toLongOrNull() ?: 0L

    private fun applyDesiredPlaybackState() {
        setProperty("pause", if (desiredPlaying) "no" else "yes")
        setProperty("speed", "$desiredSpeed")
    }

    override fun positionMs(): Long {
        if (!visibilityAppliedForFile && fileLoadedGeneration() > loadedGenerationBeforeOpen) {
            visibilityAppliedForFile = true
            applyDesiredPlaybackState()
            applySubtitleVisibility()
            pendingInitialAudioIndex?.let { index ->
                trackIds("audio").getOrNull(index)?.let { id -> setProperty("aid", "$id") }
            }
            pendingInitialAudioIndex = null
        }
        return getSecondsMs("time-pos")
    }

    override fun durationMs(): Long = getSecondsMs("duration")

    override fun isPlaying(): Boolean {
        if (handle == 0L) return false
        return MpvNative.nativeGetProperty(handle, "pause")?.let { it == "no" } ?: false
    }

    override fun setPlaying(playing: Boolean) {
        desiredPlaying = playing
        setProperty("pause", if (playing) "no" else "yes")
    }

    override fun seekTo(playerMs: Long) {
        if (handle != 0L) {
            MpvNative.nativeCommand(handle, "seek ${(playerMs.coerceAtLeast(0)) / 1000.0} absolute")
        }
    }

    override fun seekBy(deltaMs: Long) {
        if (handle != 0L) {
            MpvNative.nativeCommand(handle, "seek ${deltaMs / 1000.0}")
        }
    }

    override fun setSpeed(speed: Float) {
        desiredSpeed = speed
        setProperty("speed", "$speed")
    }

    /** track-list JSON 中按类型取轨道 id 序(升序),与服务端枚举序对齐 */
    private fun trackIds(type: String): List<Int> {
        if (handle == 0L) return emptyList()
        val raw = MpvNative.nativeGetProperty(handle, "track-list") ?: return emptyList()
        return runCatching {
            Json.parseToJsonElement(raw).jsonArray.mapNotNull { element ->
                val obj = element.jsonObject
                if (obj["type"]?.jsonPrimitive?.content == type) obj["id"]?.jsonPrimitive?.intOrNull else null
            }.sorted()
        }.getOrDefault(emptyList())
    }

    override fun embeddedTracks(): EngineTracks {
        if (handle == 0L) return EngineTracks()
        val raw = MpvNative.nativeGetProperty(handle, "track-list") ?: return EngineTracks()
        return runCatching {
            val all = Json.parseToJsonElement(raw).jsonArray.mapNotNull { element ->
                val o = element.jsonObject
                val type = o["type"]?.jsonPrimitive?.content ?: return@mapNotNull null
                if (type != "audio" && type != "sub") return@mapNotNull null
                EngineTrack(
                    id = o["id"]?.jsonPrimitive?.intOrNull ?: return@mapNotNull null,
                    language = o["lang"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() },
                    title = o["title"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() },
                    codec = o["codec"]?.jsonPrimitive?.contentOrNull,
                    channels = o["demux-channel-count"]?.jsonPrimitive?.intOrNull ?: 0,
                    selected = o["selected"]?.jsonPrimitive?.booleanOrNull ?: false,
                ).let { it to type }
            }
            EngineTracks(
                audio = all.filter { it.second == "audio" }.map { it.first }.sortedBy { it.id },
                subtitle = all.filter { it.second == "sub" }.map { it.first }.sortedBy { it.id },
            )
        }.getOrDefault(EngineTracks())
    }

    override fun setSubtitleRendering(enabled: Boolean) {
        subtitleRendering = enabled
        // 句柄还没建（surface 未挂）时不能丢：记住值，open/建句柄后会补上（原来是 `if (handle != 0L)`
        // 静默丢弃——实机里调用发生在 surface 挂上之前 0.4 秒，开关等于没生效）
        applySubtitleVisibility()
    }

    override fun selectAudioIndex(index: Int) {
        pendingInitialAudioIndex = null
        trackIds("audio").getOrNull(index)?.let { setProperty("aid", "$it") }
    }

    override fun selectTextIndex(index: Int?) {
        if (index == null) {
            setProperty("sid", "no")
            return
        }
        trackIds("sub").getOrNull(index)?.let { setProperty("sid", "$it") }
    }

    /** mpv 的缓冲停顿状态(对应 Exo 的 STATE_BUFFERING) */
    override fun isBuffering(): Boolean =
        handle != 0L && MpvNative.nativeGetProperty(handle, "paused-for-cache") == "yes"

    override fun release() {
        released = true
        surfaceView.holder.removeCallback(holderCallback)
        surfaceReady = false
        if (handle != 0L) {
            MpvNative.nativeDestroy(handle)
            handle = 0L
        }
        pending.clear()
    }
}
