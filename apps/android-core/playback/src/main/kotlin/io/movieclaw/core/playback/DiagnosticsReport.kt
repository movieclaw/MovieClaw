package io.movieclaw.core.playback

import io.movieclaw.core.model.generated.PlaybackArtifactUploadView
import io.movieclaw.core.model.generated.PlaybackDiagnosticsView
import io.movieclaw.core.model.generated.PlaybackSessionView
import java.util.Locale

/**
 * 播放诊断面板的内容（对照 Apple 端 PlayerDiagnosticsPanel 与 Web diagnostics-panel.tsx）。
 *
 * 用户报「放不出来 / 很卡」时截这一张：源规格、处理方式、有没有走显卡、掉帧、会话 id、判定理由，
 * 以及本机用的哪个解码器。每一节先摆「源是什么」（[DiagLine.Kind.Source]），下一行「→ 做了什么」
 * （[DiagLine.Kind.Action]）。纯函数：手机、电视只负责画，内容单测直接覆盖。
 */
data class DiagLine(val text: String, val kind: Kind = Kind.Plain, val alert: Boolean = false) {
    enum class Kind { Source, Action, Plain, Muted }
}

data class DiagSection(val title: String?, val lines: List<DiagLine>)

/** 本机引擎此刻的读数（控制器每秒采一次） */
data class EngineReading(
    val engine: String,
    /** 「→」下面的细节：通路、解码器、画面、音频交付…… */
    val details: List<String> = emptyList(),
    val droppedFrames: Long? = null,
    val totalFrames: Long? = null,
    val bitrateBps: Long? = null,
    val downlinkBps: Long? = null,
    val bufferedSeconds: Double = 0.0,
    val positionSeconds: Double = 0.0,
)

/** 起播状态与本次播放累计的卡顿（同 Web qoe.ts 口径：不含跳转造成的等待） */
data class PlaybackLive(
    val phase: Phase,
    val paused: Boolean,
    val activeSessionId: String?,
    val playsOriginalFile: Boolean,
    val currentAudio: String?,
    val rebufferCount: Long = 0,
    val rebufferMs: Long = 0,
)

object DiagnosticsReport {
    private val tierLabels = mapOf(0L to "原文件直出", 1L to "换壳直通", 2L to "换壳 + 转音轨", 3L to "硬件转码", 4L to "软件转码")
    private val processingLabels = mapOf(
        "direct" to "原文件直出", "remux" to "仅容器重封装", "audio-transcode" to "仅音频转码",
        "transcode-pending" to "硬件转码（执行端读取中）", "local-hardware" to "本地硬件转码",
        "local-software" to "本地软件转码", "remote-hardware" to "远程硬件转码",
    )
    private val locationLabels = mapOf("client" to "客户端", "nas" to "NAS", "remote_worker" to "远程 Worker")
    private val jobStateLabels = mapOf(
        "job.pending" to "排队中", "job.accepted" to "已接单", "job.progress" to "转码中",
        "job.failed" to "任务失败", "job.finished" to "已完成",
    )

    fun build(
        session: PlaybackSessionView?,
        server: PlaybackDiagnosticsView?,
        engine: EngineReading,
        live: PlaybackLive,
    ): List<DiagSection> {
        if (session == null) return listOf(DiagSection(null, listOf(DiagLine("正在建立播放会话…", DiagLine.Kind.Muted))))
        val decision = session.decision
        val source = session.source
        val tierLabel = tierLabels[decision.tier ?: -1] ?: "未知档位"
        val sections = mutableListOf<DiagSection>()

        sections += DiagSection("引擎", listOf(src(engine.engine)) + engine.details.map(::act))

        sections += DiagSection(
            "流媒体",
            buildList {
                add(src(listOfNotNull((source?.container ?: decision.container ?: "未知").uppercase(Locale.ROOT), mbps(source?.bitRate)).joinToString(" · ")))
                add(
                    act(
                        when {
                            live.playsOriginalFile && decision.tier != 0L -> "原文件直出（本机解码；服务端判定为$tierLabel）"
                            decision.tier == 0L -> "原文件直出"
                            else -> "HLS · fMP4（$tierLabel）"
                        },
                    ),
                )
                if (decision.degradedFrom != null) add(act("上一档播放失败，自动降档而来", alert = true))
            },
        )

        sections += DiagSection(
            "执行",
            buildList {
                val direct = live.activeSessionId == null
                val fallbackMode = when {
                    direct -> "direct"
                    decision.tier == 1L -> "remux"
                    decision.tier == 2L -> "audio-transcode"
                    session.hwBackend != null -> "transcode-pending"
                    else -> "local-software"
                }
                val mode = server?.processingMode?.takeIf { it.isNotEmpty() } ?: fallbackMode
                add(src(processingLabels[mode] ?: mode))
                add(act("位置：" + (server?.let { locationLabels[it.executionLocation] ?: it.executionLocation } ?: if (direct) "客户端直出" else "读取中")))
                (server?.backend ?: session.hwBackend)?.let { backend ->
                    add(act("后端：$backend" + (server?.encoder?.let { " · $it" } ?: "")))
                }
                server?.workerId?.let { worker ->
                    add(act("Worker：$worker" + when (server.workerOnline) { true -> " · 在线"; false -> " · 离线"; null -> " · 切换中" }))
                }
                if (server?.workerVersion != null || server?.ffmpegVersion != null) {
                    add(act(listOfNotNull(server.workerVersion?.let { "Worker $it" }, server.ffmpegVersion?.let { "ffmpeg $it" }).joinToString(" · ")))
                }
                server?.jobId?.let { job ->
                    add(act("任务：$job" + (server.jobState?.let { " · ${jobStateLabels[it] ?: it}" } ?: "") + (server.jobSpeed?.let { " · $it" } ?: "")))
                }
                server?.jobExitCode?.let { add(act("ffmpeg 退出码：$it", alert = true)) }
                server?.jobError?.takeIf { it != server.sessionError }?.let { add(act("Worker：$it", alert = true)) }
                server?.jobStderrTail?.let { add(act("ffmpeg stderr：$it", alert = true)) }
                server?.sessionError?.let { add(act(it, alert = true)) }
            },
        )

        sections += DiagSection(
            "视频",
            buildList {
                if (source != null) {
                    add(src(listOfNotNull(source.resolution, source.videoCodec?.uppercase(Locale.ROOT), source.hdr, source.frameRate?.let { "%s fps".format(Locale.US, trim(it)) }).joinToString(" · ")))
                }
                decision.video?.let { video ->
                    if (video.action == "copy" || live.playsOriginalFile) {
                        add(act("直通"))
                    } else {
                        val parts = buildString {
                            append((video.codec ?: "h264").uppercase(Locale.ROOT))
                            video.height?.let { append(" ${it}p") }
                            append(session.hwBackend?.let { " · $it" } ?: " · 软件")
                            if (video.toneMap) append(" · HDR 转 SDR")
                            video.bitrateCapBps?.let { append(" · 按线路限 %.2f Mbps".format(Locale.US, it / 1_000_000.0)) }
                        }
                        add(act("转码（$parts）"))
                    }
                    if (video.burnSubtitle != null) add(act("字幕压制进画面"))
                }
                val dropped = engine.droppedFrames
                val total = engine.totalFrames
                val ratio = if (dropped != null && total != null && total > 0) dropped.toDouble() / total else 0.0
                add(DiagLine("掉帧 " + (dropped?.let { "$it / ${total ?: "?"}" } ?: "—"), alert = ratio > 0.02))
            },
        )

        val track = decision.audioTracks.firstOrNull { it.ref == (live.currentAudio ?: decision.audio?.trackRef) }
        sections += DiagSection(
            "音频",
            buildList {
                track?.let {
                    add(src(listOfNotNull(LanguageLabel.of(it.language), it.codec?.uppercase(Locale.ROOT), it.channels?.let { c -> "$c 声道" }).joinToString(" ") + if (it.isDefault) "（默认）" else ""))
                }
                decision.audio?.let { audio ->
                    add(
                        act(
                            if (audio.action == "copy" || live.playsOriginalFile) {
                                "直通"
                            } else {
                                "转码（${(audio.codec ?: "aac").uppercase(Locale.ROOT)}${audio.channels?.let { " $it 声道" } ?: ""}${if (audio.downmix) " · 已降混" else ""}）"
                            },
                        ),
                    )
                }
            },
        )

        sections += DiagSection(
            "传输",
            listOf(
                DiagLine(
                    listOfNotNull(
                        mbps(engine.bitrateBps)?.let { "实时 $it" },
                        // 「带宽」是线路能跑多快（缓冲满了也保持实测值），不是此刻在下多快
                        bandwidth(engine.downlinkBps)?.let { "带宽 $it" },
                        "缓冲 %.1f 秒".format(Locale.US, engine.bufferedSeconds),
                        "播放头 %.1f 秒".format(Locale.US, engine.positionSeconds),
                    ).joinToString(" · "),
                ),
                DiagLine(if (live.phase == Phase.Buffering) "缓冲中" else if (live.paused) "已暂停" else "播放中"),
                DiagLine("卡顿 ${live.rebufferCount} 次" + if (live.rebufferCount > 0) " · 累计 %.1f 秒".format(Locale.US, live.rebufferMs / 1000.0) else ""),
                DiagLine("会话 ${live.activeSessionId ?: "无（直出）"}", DiagLine.Kind.Muted),
            ),
        )

        val total = server?.totalSegments
        if (server != null && total != null) {
            sections += DiagSection(
                "供片",
                buildList {
                    add(
                        src(
                            server.pendingSegments.firstOrNull()?.let { "等待 ${segment(it)}" }
                                ?: server.requestedSegment?.let { "最近请求 ${segment(it)}" }
                                ?: "当前无等待分片",
                        ),
                    )
                    add(act("连续产出 ${segment(server.highestProducedSegment)} · 头部 ${segment(server.headSegment)} · 共 $total 段"))
                    server.leadSeconds?.let { lead ->
                        add(
                            act(
                                "转码领先 ${Math.round(lead)} 秒" + when {
                                    "lead" in server.pauseReasons -> " · 已领先足够，转码暂停"
                                    "disk" in server.pauseReasons -> " · 磁盘空间告急，转码暂停"
                                    else -> ""
                                },
                            ),
                        )
                    }
                    add(act("NAS 会话缓存 ${bytes(server.cacheBytes)}" + if (server.cacheHit) " · 命中上次转码产物（${server.cachedSegments} 段免转）" else ""))
                    server.failedSegments.firstOrNull()?.let { failed ->
                        add(act("当前缺口 ${segment(failed)}" + if (server.failedSegments.size > 1) " 等 ${server.failedSegments.size} 段" else " · 上传失败待重试", alert = true))
                    }
                    server.historicalFailedSegments.firstOrNull()?.let { historical ->
                        add(act("历史失败 ${segment(historical)}" + if (server.historicalFailedSegments.size > 1) " 等 ${server.historicalFailedSegments.size} 段" else " · 已落后当前播放位置"))
                    }
                    server.recentUploads.firstOrNull()?.let { add(act("最近上传 ${uploadLabel(it)}", alert = it.status >= 400)) }
                    server.segmentWaitMs?.let { wait ->
                        add(act("最近供片等待 %.1f 秒".format(Locale.US, wait / 1000.0) + (server.segmentStatus?.let { " · HTTP $it" } ?: "")))
                    }
                },
            )
        }

        if (decision.reason.isNotBlank()) sections += DiagSection(null, listOf(DiagLine(decision.reason, DiagLine.Kind.Muted)))
        return sections
    }

    private fun src(text: String) = DiagLine(text, DiagLine.Kind.Source)
    private fun act(text: String, alert: Boolean = false) = DiagLine(text, DiagLine.Kind.Action, alert)

    internal fun mbps(bps: Long?): String? {
        if (bps == null || bps <= 0) return null
        return if (bps >= 10_000_000) "%.0f Mbps".format(Locale.US, bps / 1_000_000.0) else "%.1f Mbps".format(Locale.US, bps / 1_000_000.0)
    }

    private fun bandwidth(bps: Long?): String? = mbps(bps)

    private fun trim(value: Double): String = if (value % 1.0 == 0.0) value.toLong().toString() else "%.3f".format(Locale.US, value).trimEnd('0').trimEnd('.')

    internal fun segment(index: Long?): String = if (index == null || index < 0) "—" else "seg%05d".format(Locale.US, index)

    internal fun bytes(value: Long): String = when {
        value >= 1L shl 30 -> "%.1f GB".format(Locale.US, value / (1L shl 30).toDouble())
        value >= 1L shl 20 -> "%.1f MB".format(Locale.US, value / (1L shl 20).toDouble())
        value >= 1L shl 10 -> "%.0f KB".format(Locale.US, value / (1L shl 10).toDouble())
        else -> "$value B"
    }

    /** 「seg00012.m4s · 成功 · 2.1 MB · 2.1 MB 期望」（同 Web uploadLabel） */
    private fun uploadLabel(upload: PlaybackArtifactUploadView): String {
        val status = if (upload.status == 201L) "成功" else "HTTP ${upload.status}"
        val expected = upload.contentLength?.let { "${bytes(it)} 期望" } ?: if (upload.transferEncoding == "chunked") "chunked" else null
        return listOfNotNull(upload.name, status, bytes(upload.receivedBytes), expected).joinToString(" · ")
    }
}
