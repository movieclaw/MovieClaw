import SwiftUI

/// 播放诊断面板（对应 Web `components/player/diagnostics-panel.tsx`，信息层次对标 Emby 的播放信息）。
///
/// 用户报「放不出来 / 很卡」时截这一张图：源规格、处理方式、有没有走显卡、掉帧、会话 id、判定理由、
/// 以及 App 独有的「用的哪个引擎、怎么渲染」全在里面。每一节先摆「源是什么」，下一行「→ 做了什么」。
/// 服务端快照由控制器每 2 秒拉一次（只在面板打开时，同 Web），本地引擎读数面板自己每秒拉一次。
struct PlayerDiagnosticsPanel: View {
    let controller: PlaybackController
    /// 面板高度：竖屏限在中线上方（不压住中央的播放键），横屏可以高一些（同 Web 的取舍）
    let height: CGFloat
    let close: () -> Void

    private static let tierLabels = [0: String(localized: .playerDiagnosticsTierDirect), 1: String(localized: .playerDiagnosticsTierRemux), 2: String(localized: .playerDiagnosticsTierAudioTranscode), 3: String(localized: .playerDiagnosticsTierHardware), 4: String(localized: .playerDiagnosticsTierSoftware)]
    private static let processingLabels = [
        "direct": String(localized: .playerDiagnosticsTierDirect), "remux": String(localized: .playerDiagnosticsProcessingRemux), "audio-transcode": String(localized: .playerDiagnosticsProcessingAudioTranscode),
        "transcode-pending": String(localized: .playerDiagnosticsProcessingPending), "local-hardware": String(localized: .playerDiagnosticsProcessingLocalHardware),
        "local-software": String(localized: .playerDiagnosticsProcessingLocalSoftware), "remote-hardware": String(localized: .playerDiagnosticsProcessingRemoteHardware),
    ]
    private static let locationLabels = ["client": String(localized: .playerDiagnosticsLocationClient), "nas": "NAS", "remote_worker": String(localized: .playerDiagnosticsLocationRemote)]
    private static let jobStateLabels = [
        "job.pending": String(localized: .playerDiagnosticsJobPending), "job.accepted": String(localized: .playerDiagnosticsJobAccepted), "job.progress": String(localized: .playerDiagnosticsJobProgress), "job.failed": String(localized: .playerDiagnosticsJobFailed), "job.finished": String(localized: .playerDiagnosticsJobFinished),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content(stats: controller.engine?.stats())
        }
    }

    @ViewBuilder
    private func content(stats: EngineStats?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: .playerControlsDiagnostics)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button(action: close) {
                    // 看得见的是 28pt 圆底，点击区域 44pt 并显式声明
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.14), in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // 排版上只占圆的大小：圆离面板上、右边都是 14，触控区向外溢出，不把标题行撑高
                .padding(-8)
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel(String(localized: .playerDiagnosticsClose))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let session = controller.session {
                        sections(session: session, stats: stats)
                    } else {
                        Text(String(localized: .playerDiagnosticsStartingSession)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .font(.system(size: 11.5))
        .padding(14)
        .frame(maxWidth: 340)
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 20))
        .glassEffect(PlayerGlass.panel, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-diagnostics")
    }

    @ViewBuilder
    private func sections(session: API.PlaybackSessionView, stats: EngineStats?) -> some View {
        let decision = session.decision
        let diagnostics = controller.serverDiagnostics
        let source = session.source

        Section(title: String(localized: .playerDiagnosticsEngine)) {
            SourceLine(controller.engine?.kind.label ?? "—")
            ForEach(stats?.details ?? [], id: \.self) { ActionLine($0) }
        }

        Section(title: String(localized: .playerDiagnosticsStream)) {
            SourceLine([(source?.container ?? decision.container ?? String(localized: .playerDiagnosticsUnknown)).uppercased(), mbps(source?.bitRate)].compactMap { $0 }.joined(separator: " · "))
            if controller.playsOriginalFile, decision.tier != 0 {
                ActionLine(String(localized: .playerDiagnosticsNativeDirect(Self.tierLabels[decision.tier ?? -1] ?? String(localized: .playerDiagnosticsUnknownTier))))
            } else {
                ActionLine(decision.tier == 0 ? String(localized: .playerDiagnosticsTierDirect) : String(localized: .playerDiagnosticsStreamTarget(Self.tierLabels[decision.tier ?? -1] ?? String(localized: .playerDiagnosticsUnknownTier))))
            }
            if decision.degradedFrom != nil { ActionLine(String(localized: .playerDiagnosticsDegraded), alert: true) }
        }

        Section(title: String(localized: .playerDiagnosticsExecution)) {
            let direct = controller.activeSessionId == nil
            let fallbackMode = direct ? "direct" : decision.tier == 1 ? "remux" : decision.tier == 2 ? "audio-transcode" : session.hwBackend != nil ? "transcode-pending" : "local-software"
            let mode = diagnostics?.processingMode ?? fallbackMode
            SourceLine(Self.processingLabels[mode] ?? mode)
            ActionLine(String(localized: .playerDiagnosticsLocationLine(diagnostics.map { Self.locationLabels[$0.executionLocation] ?? $0.executionLocation } ?? (direct ? String(localized: .playerDiagnosticsLocationDirect) : String(localized: .playerDiagnosticsReading)))))
            if let backend = diagnostics?.backend ?? session.hwBackend {
                ActionLine(String(localized: .playerDiagnosticsBackendLine(backend)) + (diagnostics?.encoder.map { " · \($0)" } ?? ""))
            }
            if let worker = diagnostics?.workerId {
                ActionLine("Worker：\(worker)" + (diagnostics?.workerOnline == true ? String(localized: .playerDiagnosticsOnline) : diagnostics?.workerOnline == false ? String(localized: .playerDiagnosticsOffline) : String(localized: .playerDiagnosticsSwitching)))
            }
            if diagnostics?.workerVersion != nil || diagnostics?.ffmpegVersion != nil {
                ActionLine([diagnostics?.workerVersion.map { "Worker \($0)" }, diagnostics?.ffmpegVersion.map { "ffmpeg \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            if diagnostics?.workerPlatform != nil || diagnostics?.workerArch != nil {
                ActionLine(String(localized: .playerDiagnosticsPlatformLine([diagnostics?.workerPlatform, diagnostics?.workerArch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))))
            }
            if let job = diagnostics?.jobId {
                ActionLine(String(localized: .playerDiagnosticsJobLine) + job + (diagnostics?.jobState.map { " · \(Self.jobStateLabels[$0] ?? $0)" } ?? "") + (diagnostics?.jobSpeed.map { " · \($0)" } ?? ""))
            }
            if let code = diagnostics?.jobExitCode { ActionLine(String(localized: .playerDiagnosticsExitCode(String(code))), alert: true) }
            if let error = diagnostics?.jobError, error != diagnostics?.sessionError { ActionLine("Worker：\(error)", alert: true) }
            if let tail = diagnostics?.jobStderrTail { ActionLine("ffmpeg stderr：\(tail)", alert: true) }
            if let error = diagnostics?.sessionError { ActionLine(error, alert: true) }
        }

        Section(title: String(localized: .mediaKindVideo)) {
            if let source {
                SourceLine([source.resolution, source.videoCodec?.uppercased(), source.hdr, source.frameRate.map { String(format: "%g fps", $0) }].compactMap { $0 }.joined(separator: " · "))
            }
            if let video = decision.video {
                if video.action == "copy" {
                    ActionLine(String(localized: .playerDiagnosticsCopy))
                } else {
                    ActionLine(String(localized: .playerDiagnosticsTranscode("\((video.codec ?? "h264").uppercased())\(video.height.map { " \($0)p" } ?? "")\(session.hwBackend.map { " · \($0)" } ?? String(localized: .playerDiagnosticsSoftware))\(video.toneMap ? String(localized: .playerDiagnosticsToneMap) : "")\(video.bitrateCapBps.map { String(localized: .playerDiagnosticsBandwidthCap(String(format: "%.2f", Double($0) / 1_000_000))) } ?? "")")))
                }
                if video.burnSubtitle != nil { ActionLine(String(localized: .playerDiagnosticsBurnedSubtitles)) }
            }
            let dropped = stats?.droppedFrames
            let ratio = (dropped != nil && (stats?.totalFrames ?? 0) > 0) ? Double(dropped!) / Double(stats!.totalFrames!) : 0
            Text(String(localized: .playerDiagnosticsFrameCount(dropped.map { "\($0) / \(stats?.totalFrames.map(String.init) ?? "?")" } ?? "—")))
                .foregroundStyle(ratio > 0.02 ? Color.red.opacity(0.8) : .white.opacity(0.75))
        }

        Section(title: String(localized: .playerDiagnosticsAudio)) {
            if let track = decision.audioTracks.first(where: { $0.ref == (controller.currentAudio ?? decision.audio?.trackRef) }) {
                SourceLine([LanguageLabel.of(track.language), track.codec?.uppercased(), track.channels.map { String(localized: .playerTracksChannels($0)) }].compactMap { $0 }.joined(separator: " ") + (track.isDefault ? String(localized: .playerDiagnosticsDefault) : ""))
            }
            if let audio = decision.audio {
                ActionLine(audio.action == "copy" || controller.playsOriginalFile ? String(localized: .playerDiagnosticsCopy) : String(localized: .playerDiagnosticsTranscode("\((audio.codec ?? "aac").uppercased())\(audio.channels.map { " \(String(localized: .playerTracksChannels($0)))" } ?? "")\(audio.downmix ? String(localized: .playerDiagnosticsDownmix) : "")")))
            }
        }

        Section(title: String(localized: .playerDiagnosticsTransfer)) {
            Text([
                stats?.engine ?? "—",
                mbps(stats?.bitrateBps.map { Int($0) }).map { String(localized: .playerDiagnosticsLiveBitrate($0)) },
                // 「带宽」是线路能跑多快（缓冲满了也保持实测值），顶栏「↓」是此刻在下多快，两者不是一个量
                PlaybackController.formatBandwidth(stats?.downlinkBps).map { String(localized: .playerDiagnosticsBandwidth($0)) },
                stats.map { String(localized: .playerDiagnosticsBuffer($0.bufferedSeconds)) },
                stats.map { String(localized: .playerDiagnosticsPlayhead($0.currentTimeSeconds)) },
            ].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.white.opacity(0.75))
            Text(controller.phase == .buffering ? String(localized: .playerDiagnosticsBuffering) : controller.paused ? String(localized: .playerDiagnosticsPaused) : String(localized: .playerDiagnosticsPlaying))
                .foregroundStyle(.white.opacity(0.75))
            // 「不丝滑」的量化行：上次跳转等了多久；卡顿不含 seek 造成的等待（同 Web qoe.ts 口径），两个数分开读
            let qoe = controller.qoeLive
            Text([
                qoe.lastSeekMs.map { String(localized: .playerDiagnosticsLastSeek(Double($0) / 1000)) },
                String(localized: .playerDiagnosticsRebufferCount(qoe.rebufferCount)) + (qoe.rebufferCount > 0 ? String(localized: .playerDiagnosticsRebufferTotal(Double(qoe.rebufferMs) / 1000)) : ""),
            ].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.white.opacity(0.75))
            Text(String(localized: .playerDiagnosticsSession(controller.activeSessionId ?? String(localized: .playerDiagnosticsNoSession))))
                .foregroundStyle(.white.opacity(0.5))
                .textSelection(.enabled)
        }

        if let diagnostics, let total = diagnostics.totalSegments {
            Section(title: String(localized: .playerDiagnosticsSegments)) {
                SourceLine(diagnostics.pendingSegments.first.map { String(localized: .playerDiagnosticsPendingSegment(segment($0))) }
                    ?? diagnostics.requestedSegment.map { String(localized: .playerDiagnosticsRequestedSegment(segment($0))) } ?? String(localized: .playerDiagnosticsNoPendingSegment))
                ActionLine(String(localized: .playerDiagnosticsProduced(segment(diagnostics.highestProducedSegment), segment(diagnostics.headSegment), total)))
                if let lead = diagnostics.leadSeconds {
                    ActionLine(String(localized: .playerDiagnosticsLead(Int(lead.rounded()), diagnostics.pauseReasons.contains("lead") ? String(localized: .playerDiagnosticsPauseLead) : diagnostics.pauseReasons.contains("disk") ? String(localized: .playerDiagnosticsPauseDisk) : "")))
                }
                ActionLine(String(localized: .playerDiagnosticsCache(Formatters.bytes(diagnostics.cacheBytes), diagnostics.cacheHit ? String(localized: .playerDiagnosticsCacheHit(diagnostics.cachedSegments)) : "")))
                if let failed = diagnostics.failedSegments.first {
                    ActionLine(String(localized: .playerDiagnosticsFailedSegment(segment(failed), diagnostics.failedSegments.count > 1 ? String(localized: .playerDiagnosticsMultipleSegments(diagnostics.failedSegments.count)) : String(localized: .playerDiagnosticsRetryUpload))), alert: true)
                }
                if let historical = diagnostics.historicalFailedSegments.first {
                    ActionLine(String(localized: .playerDiagnosticsHistoricalFailure(segment(historical), diagnostics.historicalFailedSegments.count > 1 ? String(localized: .playerDiagnosticsMultipleSegments(diagnostics.historicalFailedSegments.count)) : String(localized: .playerDiagnosticsBehindPlayhead))))
                }
                if let upload = diagnostics.recentUploads.first {
                    ActionLine(String(localized: .playerDiagnosticsLastUpload(uploadLabel(upload))), alert: upload.status >= 400)
                }
                if let wait = diagnostics.segmentWaitMs {
                    ActionLine(String(localized: .playerDiagnosticsLastSegmentWait(Double(wait) / 1000)) + (diagnostics.segmentStatus.map { " · HTTP \($0)" } ?? ""))
                }
            }
        }

        Text(decision.reason)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 4)
    }

    private func mbps(_ bps: Int?) -> String? {
        guard let bps, bps > 0 else { return nil }
        return String(format: bps >= 10_000_000 ? "%.0f Mbps" : "%.1f Mbps", Double(bps) / 1_000_000)
    }

    /// 「seg00012.m4s · 成功 · 2.1 MB · 2.1 MB 期望」（同 Web uploadLabel）
    private func uploadLabel(_ upload: API.PlaybackArtifactUploadView) -> String {
        let status = upload.status == 201 ? String(localized: .playerDiagnosticsSuccess) : "HTTP \(upload.status)"
        let expected = upload.contentLength.map { String(localized: .playerDiagnosticsExpectedBytes(Formatters.bytes($0))) } ?? (upload.transferEncoding == "chunked" ? "chunked" : nil)
        return [upload.name, status, Formatters.bytes(upload.receivedBytes), expected].compactMap { $0 }.joined(separator: " · ")
    }

    private func segment(_ index: Int?) -> String {
        guard let index, index >= 0 else { return "—" }
        return String(format: "seg%05d", index)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) { content }.padding(.leading, 12)
        }
    }
}

private struct SourceLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).fontWeight(.medium).foregroundStyle(.white.opacity(0.95)) }
}

private struct ActionLine: View {
    let text: String
    let alert: Bool
    init(_ text: String, alert: Bool = false) {
        self.text = text
        self.alert = alert
    }

    var body: some View {
        Text("\(Text("→ ").foregroundStyle(.white.opacity(0.4)))\(Text(text).foregroundStyle(alert ? Color.red.opacity(0.8) : .white.opacity(0.75)))")
    }
}
