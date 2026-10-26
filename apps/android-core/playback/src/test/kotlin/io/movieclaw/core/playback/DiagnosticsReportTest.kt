package io.movieclaw.core.playback

import io.movieclaw.core.model.generated.AudioPlanView
import io.movieclaw.core.model.generated.AudioTrackView
import io.movieclaw.core.model.generated.PlaybackDecisionView
import io.movieclaw.core.model.generated.PlaybackDiagnosticsView
import io.movieclaw.core.model.generated.PlaybackSessionView
import io.movieclaw.core.model.generated.PlaybackSourceView
import io.movieclaw.core.model.generated.VideoPlanView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 播放诊断面板的内容：对照 Apple 端 PlayerDiagnosticsPanel 的分节与措辞 */
class DiagnosticsReportTest {
    private val engine = EngineReading(
        engine = "ExoPlayer（Media3）",
        details = listOf("通路 服务端 HLS 流", "视频 c2.mtk.hevc.decoder（硬解）"),
        droppedFrames = 30,
        totalFrames = 1000,
        bitrateBps = 8_000_000,
        downlinkBps = 42_000_000,
        bufferedSeconds = 12.34,
        positionSeconds = 228.0,
    )

    private fun lines(sections: List<DiagSection>, title: String?) =
        sections.first { it.title == title }.lines.map { it.text }

    @Test fun `no session yet says so`() {
        val sections = DiagnosticsReport.build(null, null, engine, live(sessionId = null))
        assertEquals("正在建立播放会话…", sections.single().lines.single().text)
    }

    @Test fun `hardware transcode shows source then what was done`() {
        val session = PlaybackSessionView(
            decision = PlaybackDecisionView(
                tier = 3,
                container = "mkv",
                video = VideoPlanView(action = "transcode", codec = "h264", height = 1080, toneMap = true),
                audio = AudioPlanView(action = "transcode", trackRef = "embedded:1", codec = "aac", channels = 2, downmix = true),
                audioTracks = listOf(AudioTrackView(ref = "embedded:1", codec = "eac3", channels = 6, language = "eng", isDefault = true)),
                degradedFrom = 1,
                reason = "源片关键帧索引尚未就绪，已改为转码",
            ),
            sessionId = "s1",
            hwBackend = "vaapi",
            source = PlaybackSourceView(container = "mkv", resolution = "2160p", videoCodec = "hevc", hdr = "HDR10", bitRate = 15_000_000, frameRate = 23.976),
        )
        val server = PlaybackDiagnosticsView(
            processingMode = "local-hardware",
            executionLocation = "nas",
            backend = "vaapi",
            encoder = "h264_vaapi",
            totalSegments = 600,
            headSegment = 10,
            highestProducedSegment = 40,
            leadSeconds = 180.4,
            pauseReasons = listOf("lead"),
            cacheBytes = 3L shl 20,
            failedSegments = listOf(12),
        )
        val sections = DiagnosticsReport.build(session, server, engine, live(sessionId = "s1"))

        assertEquals(listOf("ExoPlayer（Media3）", "通路 服务端 HLS 流", "视频 c2.mtk.hevc.decoder（硬解）"), lines(sections, "引擎"))
        assertEquals(listOf("MKV · 15 Mbps", "HLS · fMP4（硬件转码）", "上一档播放失败，自动降档而来"), lines(sections, "流媒体"))
        assertEquals(listOf("本地硬件转码", "位置：NAS", "后端：vaapi · h264_vaapi"), lines(sections, "执行"))
        val video = lines(sections, "视频")
        assertEquals("2160p · HEVC · HDR10 · 23.976 fps", video[0])
        assertEquals("转码（H264 1080p · vaapi · HDR 转 SDR）", video[1])
        assertEquals("掉帧 30 / 1000", video[2])
        // 掉帧 3% 超过 2% 标红
        assertTrue(sections.first { it.title == "视频" }.lines[2].alert)
        assertEquals(listOf("英语 EAC3 6 声道（默认）", "转码（AAC 2 声道 · 已降混）"), lines(sections, "音频"))
        val transfer = lines(sections, "传输")
        assertEquals("实时 8.0 Mbps · 带宽 42 Mbps · 缓冲 12.3 秒 · 播放头 228.0 秒", transfer[0])
        assertEquals("会话 s1", transfer.last())
        val supply = lines(sections, "供片")
        assertEquals("当前无等待分片", supply[0])
        assertEquals("连续产出 seg00040 · 头部 seg00010 · 共 600 段", supply[1])
        assertEquals("转码领先 180 秒 · 已领先足够，转码暂停", supply[2])
        assertEquals("NAS 会话缓存 3.0 MB", supply[3])
        assertTrue(supply[4].startsWith("当前缺口 seg00012"))
        // 判定理由放在最后
        assertEquals("源片关键帧索引尚未就绪，已改为转码", sections.last().lines.single().text)
    }

    @Test fun `original file played locally says so even if the server planned a remux`() {
        val session = PlaybackSessionView(
            decision = PlaybackDecisionView(tier = 1, video = VideoPlanView(action = "copy"), audio = AudioPlanView(action = "copy")),
            sessionId = "s2",
        )
        val sections = DiagnosticsReport.build(session, null, engine, live(sessionId = null, original = true))
        assertEquals("原文件直出（本机解码；服务端判定为换壳直通）", lines(sections, "流媒体")[1])
        assertEquals(listOf("原文件直出", "位置：客户端直出"), lines(sections, "执行"))
        assertEquals("会话 无（直出）", lines(sections, "传输").last())
        // 没有服务端快照就没有「供片」一节
        assertTrue(sections.none { it.title == "供片" })
    }

    private fun live(sessionId: String?, original: Boolean = false) = PlaybackLive(
        phase = Phase.Playing,
        paused = false,
        activeSessionId = sessionId,
        playsOriginalFile = original,
        currentAudio = null,
    )
}
