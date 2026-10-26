"use client";

import { useLocale, useTranslations } from "next-intl";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { appTranslator } from "@/lib/i18n/translate";
import { useEffect, useState } from "react";

import type { PlaybackDiagnostics, PlaybackSession } from "@/lib/api/playback";
import { formatBandwidth } from "@/lib/player/bandwidth";
import type { EngineStats, PlaybackEngine } from "@/lib/player/engine";
import type { QoeLiveStats } from "@/lib/player/qoe";
import { languageLabel } from "@/lib/language-labels";

/**
 * 诊断面板（docs/design/web-player.md §6.5，信息层次对标 Emby 的播放信息）。
 *
 * 这一屏是**开源项目支持成本的直接节省**：用户报「放不出来 / 很卡」时，截这
 * 一张图，源规格、处理方式、有没有走显卡、掉帧、会话 id、判定理由全在里面，
 * 一来一回就能定位，不用反复问「你的浏览器是什么版本」。
 *
 * **层次照 Emby：每一节先摆「源是什么」，下一行「→ 我们对它做了什么」。**
 * 只报处理结果的面板回答不了用户真正的疑问——「1080p H264 明明能直通，为什么
 * 在转码」这类问题必须把源和处理摆在一起才看得出来。
 */

const BACKEND_LABELS: Record<string, string> = {
  videotoolbox: "VideoToolbox",
  vaapi: "VAAPI",
  qsv: "Intel QSV",
  nvenc: "NVENC",
};

/** 掉帧率高于这个比例就标红：能解但解不动，通常是该降一档了。 */
const DROP_ALERT_RATIO = 0.02;

function formatMbps(bps: number | null | undefined): string | null {
  if (!bps) return null;
  return `${(bps / 1_000_000).toFixed(bps >= 10_000_000 ? 0 : 1)} Mbps`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KiB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MiB`;
  return `${(bytes / 1024 ** 3).toFixed(2)} GiB`;
}

function segmentLabel(index: number | null | undefined): string {
  if (index == null || index < 0) return "—";
  return `seg${String(index).padStart(5, "0")}`;
}

function uploadLabel(upload: PlaybackDiagnostics["recent_uploads"][number], locale: AppLocale): string {
  const t = appTranslator(locale);
  const status = upload.status === 201 ? t("player.diagnostics.success") : `HTTP ${upload.status}`;
  const expected =
    upload.content_length == null
      ? upload.transfer_encoding === "chunked"
        ? "chunked"
        : null
      : t("player.diagnostics.expectedBytes", { size: formatBytes(upload.content_length) });
  return [upload.name, status, formatBytes(upload.received_bytes), expected]
    .filter(Boolean)
    .join(" · ");
}

/** 节标题 + 内容：Emby 式两级缩进。 */
function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <p className="font-semibold text-white/60">{title}</p>
      <div className="mt-0.5 space-y-0.5 pl-3">{children}</div>
    </div>
  );
}

/** 源行：白色主体字，一节的「左半边」。 */
function SourceLine({ children }: { children: React.ReactNode }) {
  return <p className="font-medium text-white/95">{children}</p>;
}

/** 处理行：→ 开头，弱一档的颜色——读的顺序就是数据流的方向。 */
function ActionLine({ children, alert }: { children: React.ReactNode; alert?: boolean }) {
  return (
    <p className={alert ? "text-red-300" : "text-white/75"}>
      <span className="mr-1 text-white/40">→</span>
      {children}
    </p>
  );
}

export function DiagnosticsPanel({
  session,
  engine,
  qoe,
  landscape,
  diagnostics,
  onClose,
}: {
  session: PlaybackSession;
  engine: PlaybackEngine | null;
  /** 实时 QoE 读数（跳转耗时、卡顿）。用函数而非快照：数据源在播放器的
   *  ref 里逐事件归约，面板按自己的节奏拉取即可，不用逼播放器每次事件都
   *  重渲染 */
  qoe: () => QoeLiveStats;
  /** 横屏中（真方向锁或 iOS 伪横屏）。见下方注释：伪横屏时视口仍是竖的，
   *  `max-md:` 按视口宽度判断会选错布局，必须由这个状态拍板 */
  landscape: boolean;
  /** 服务端会话快照；直出档没有会话时为 null。 */
  diagnostics: PlaybackDiagnostics | null;
  onClose: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();
  const TIER_LABELS: Record<number, string> = {
    0: t("player.diagnostics.tier.direct"),
    1: t("player.diagnostics.tier.remux"),
    2: t("player.diagnostics.tier.audioTranscode"),
    3: t("player.diagnostics.tier.hardware"),
    4: t("player.diagnostics.tier.software"),
  };

  const PROCESSING_LABELS: Record<string, string> = {
    direct: t("player.diagnostics.tier.direct"),
    remux: t("player.diagnostics.processing.remux"),
    "audio-transcode": t("player.diagnostics.processing.audioTranscode"),
    "transcode-pending": t("player.diagnostics.processing.pending"),
    "local-hardware": t("player.diagnostics.processing.localHardware"),
    "local-software": t("player.diagnostics.processing.localSoftware"),
    "remote-hardware": t("player.diagnostics.processing.remoteHardware"),
  };

  const LOCATION_LABELS: Record<string, string> = {
    client: t("player.diagnostics.location.client"),
    nas: "NAS",
    remote_worker: t("player.diagnostics.location.remote"),
  };

  const JOB_STATE_LABELS: Record<string, string> = {
    "job.pending": t("player.diagnostics.job.pending"),
    "job.accepted": t("player.diagnostics.job.accepted"),
    "job.progress": t("player.diagnostics.job.progress"),
    "job.failed": t("player.diagnostics.job.failed"),
    "job.finished": t("player.diagnostics.job.finished"),
  };

  const READY_STATE_LABELS: Record<number, string> = {
    0: t("player.diagnostics.ready.none"),
    1: t("player.diagnostics.ready.metadata"),
    2: t("player.diagnostics.ready.current"),
    3: t("player.diagnostics.ready.future"),
    4: t("player.diagnostics.ready.enough"),
  };

  const NETWORK_STATE_LABELS: Record<number, string> = {
    0: t("player.diagnostics.network.idle"),
    1: t("player.diagnostics.network.loading"),
    2: t("player.diagnostics.network.loaded"),
    3: t("player.diagnostics.network.empty"),
  };

  const [stats, setStats] = useState<EngineStats | null>(null);
  const [qoeStats, setQoeStats] = useState<QoeLiveStats | null>(null);

  useEffect(() => {
    // 1 秒一次：再快没有信息量（掉帧与码率本身就是秒级统计），只会白烧主线程
    const pull = () => {
      if (engine) setStats(engine.stats());
      setQoeStats(qoe());
    };
    const timer = window.setInterval(pull, 1000);
    pull();
    return () => window.clearInterval(timer);
    // qoe 是读 ref 的稳定闭包，不进依赖：进了会因父组件每次渲染新建闭包
    // 而让定时器反复拆装
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [engine]);

  const { decision, source } = session;
  const dropRatio =
    stats?.droppedFrames != null && stats.totalFrames
      ? stats.droppedFrames / stats.totalFrames
      : 0;

  // —— 流媒体节：容器层的「源 → 协议」 ——
  const sourceContainer = [
    (source?.container ?? decision.container ?? t("player.diagnostics.unknown")).toUpperCase(),
    formatMbps(source?.bit_rate),
  ]
    .filter(Boolean)
    .join(" · ");
  const streamTarget =
    decision.tier === 0
      ? t("player.diagnostics.tier.direct")
      : t("player.diagnostics.streamTarget", { tier: TIER_LABELS[decision.tier ?? -1] ?? t("player.diagnostics.unknownTier") });

  const fallbackProcessingMode =
    session.session_id == null
      ? "direct"
      : decision.tier === 1
        ? "remux"
        : decision.tier === 2
          ? "audio-transcode"
          : session.hw_backend
            ? "transcode-pending"
            : "local-software";
  const processingMode = diagnostics?.processing_mode ?? fallbackProcessingMode;
  const processingLabel = PROCESSING_LABELS[processingMode] ?? processingMode;
  const locationLabel = diagnostics
    ? LOCATION_LABELS[diagnostics.execution_location] ?? diagnostics.execution_location
    : session.session_id == null
      ? t("player.diagnostics.location.direct")
      : t("player.diagnostics.reading");
  const backendLabel = diagnostics?.backend
    ? BACKEND_LABELS[diagnostics.backend] ?? diagnostics.backend
    : session.hw_backend
      ? BACKEND_LABELS[session.hw_backend] ?? session.hw_backend
      : null;
  const latestUpload = diagnostics?.recent_uploads[0] ?? null;
  const failedSegment = diagnostics?.failed_segments[0];
  const historicalFailedSegment = diagnostics?.historical_failed_segments[0];
  const pendingSegment = diagnostics?.pending_segments[0];

  // —— 视频节 ——
  const videoSource = source
    ? [
        source.resolution,
        source.video_codec?.toUpperCase(),
        source.hdr,
        source.frame_rate ? `${source.frame_rate.toFixed(3).replace(/\.?0+$/, "")} fps` : null,
      ]
        .filter(Boolean)
        .join(" · ")
    : null;
  const videoCopy = decision.video?.action === "copy";
  const videoAction = decision.video
    ? videoCopy
      ? t("player.diagnostics.copy")
      : t("player.diagnostics.transcode", { format: `${(decision.video.codec ?? "h264").toUpperCase()}${
          decision.video.height ? ` ${decision.video.height}p` : ""
        }${session.hw_backend ? ` · ${session.hw_backend}` : t("player.diagnostics.software")}${
          decision.video.tone_map ? t("player.diagnostics.toneMap") : ""
        }${
          // 按实测带宽压过码率要摆出来：否则用户会以为画质设置坏了（§C）
          decision.video.bitrate_cap_bps
            ? t("player.diagnostics.bandwidthCap", { value: (decision.video.bitrate_cap_bps / 1_000_000).toFixed(2) })
            : ""
        }` })
    : null;

  // —— 音频节：源行来自候选轨列表里「这次放的那条」 ——
  const activeTrack = decision.audio_tracks.find(
    (track) => track.ref === decision.audio?.track_ref,
  );
  const audioSource = activeTrack
    ? [
        activeTrack.language ? languageLabel(activeTrack.language, locale) : null,
        activeTrack.codec?.toUpperCase(),
        activeTrack.channels ? t("player.tracks.channels", { count: activeTrack.channels }) : null,
      ]
        .filter(Boolean)
        .join(" ") + (activeTrack.is_default ? t("player.diagnostics.default") : "")
    : null;
  const audioCopy = decision.audio?.action === "copy";
  const audioAction = decision.audio
    ? audioCopy
      ? t("player.diagnostics.copy")
      : t("player.diagnostics.transcode", { format: `${(decision.audio.codec ?? "aac").toUpperCase()}${
          decision.audio.channels ? ` ${t("player.tracks.channels", { count: decision.audio.channels })}` : ""
        }${decision.audio.downmix ? t("player.diagnostics.downmix") : ""}` })
    : null;

  return (
    <div
      /*
       * 外观照 YouTube 的 Stats for nerds：**一块半透明的黑，仅此而已**。
       *
       * noautohide：media-controller 在用户无操作时把普通子元素统一淡出，
       * 这块面板要一直挂到用户点关闭为止、与控制条显隐互不相干（Emby 同款
       * 行为）——不豁免的话表现为「鼠标一停诊断信息就消失」。
       *
       * 位置照它放在画面左上，但有两条约束是真机截图逼出来的：
       *
       * - **`top` 必须自己叠 `--safe-top`**。顶栏也叠了它，PWA（black-translucent
       *   + viewport-fit=cover）里状态栏把顶栏整体往下推 59px，面板不跟着让就
       *   正好压在片名那一行上。面板是半透明的，压上去不是"盖住"而是"透出来"，
       *   两组文字叠在一起谁也读不了——真机截图里就是这个样子。
       * - **不能长到盖住中央的播放键**。竖屏宽度不够，面板必然横跨屏幕中线，
       *   而播放/退进十秒那一簇就在画面正中；面板挡住它，用户要先关诊断才能
       *   暂停。所以竖屏限高到中线上方一档（`50% - top - 3rem`），超出滚动。
       *   宽屏不受这条约束：面板 320px 靠左，与居中的按钮簇在横向上本就错开，
       *   那里只留一个防撑破的兜底限高。
       *
       * 竖屏/宽屏怎么判：**横屏状态优先，`max-md:` 只兜竖屏的班**。iOS 伪
       * 横屏是把容器旋转 90°，视口还是竖着的 390px——按视口宽度判断会继续
       * 用竖屏布局，面板横跨 844px 的旋转容器（真机截图证实）。所以横屏时
       * 由 landscape 状态直接切到宽屏那组类，与视口无关。
       *
       * z-10，比中央簇（z-20）**低**：手机横屏只有 320~390pt 高，320px 宽的
       * 面板与中央簇必然相交，谁躲谁都躲不开。YouTube 的答案是传输控件画在
       * Stats for nerds 上层——面板是被动读数，退十秒不能被它埋掉。面板的
       * 关闭键在自己右上角，不在相交区，两边都点得到。
       *
       * `left` 用 max(1.5rem, --safe-left)：伪横屏下布局左边就是物理顶边，
       * --safe-left 被重映射成状态栏高度（globals.css 的 .player-fake-landscape），
       * 桌面上它是 0、退化回原来的 1.5rem。
       *
       * 限高一律配 `overflow-y-auto`：判定理由那段长度不可控（多轨、降档、
       * HDR 处置都会往里加句子），撑破了会一路盖到控制条上。
       *
       * 刻意不用站内浮层的 .menu-surface（磨砂玻璃 + 高光描边 + 大投影）：
       * 那套语言是给「压在内容上、等你操作完就走」的菜单用的，而这块面板会
       * 挂在画面角上几十分钟，越素越好。圆角保留——播放器里不该出现方角牌子。
       *
       * 顺带解决的一件事：磨砂一走，backdrop-filter 也就没了。面板长时间叠在
       * 视频上，每帧重采样模糊是掉帧的头号大户（globals 里的 QoE 注释），而
       * 诊断面板恰恰是用来量掉帧的，不能自己污染读数。
       */
      {...{ noautohide: "" }}
      className={`
        absolute z-10 overflow-y-auto overscroll-contain rounded-[14px] bg-black/70 px-3.5 py-2.5 text-[11.5px] leading-relaxed
        left-[max(1.5rem,var(--safe-left))] top-[calc(4.5rem_+_var(--safe-top))] w-[320px] max-h-[calc(100%-12rem)]
        ${
          landscape
            ? ""
            : `max-md:left-[max(0.75rem,var(--safe-left))] max-md:right-[max(0.75rem,var(--safe-right))]
               max-md:w-auto max-md:max-h-[calc(50%_-_4.5rem_-_var(--safe-top)_-_2.5rem)]`
        }
      `}
    >
      <div className="mb-1.5 flex items-center justify-between">
        <h3 className="text-[12px] font-semibold text-white/90">{t("player.controls.diagnostics")}</h3>
        <button
          type="button"
          onClick={onClose}
          aria-label={t("player.diagnostics.close")}
          className="-mr-1 grid size-6 place-items-center rounded-full text-white/50 transition-colors hover:bg-white/10 hover:text-white"
        >
          <svg viewBox="0 0 24 24" className="size-3.5" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" aria-hidden>
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
      </div>

      <div className="space-y-2">
        <Section title={t("player.diagnostics.stream")}>
          <SourceLine>{sourceContainer}</SourceLine>
          <ActionLine>{streamTarget}</ActionLine>
          {decision.degraded_from != null ? (
            <ActionLine alert>{t("player.diagnostics.degraded")}</ActionLine>
          ) : null}
        </Section>

        <Section title={t("player.diagnostics.execution")}>
          <SourceLine>{processingLabel}</SourceLine>
          <ActionLine>{t("player.diagnostics.locationLine", { location: locationLabel })}</ActionLine>
          {backendLabel ? (
            <ActionLine>
              {t("player.diagnostics.backendLine", { backend: backendLabel })}
              {diagnostics?.encoder ? ` · ${diagnostics.encoder}` : null}
            </ActionLine>
          ) : null}
          {diagnostics?.worker_id ? (
            <ActionLine>
              Worker：<span className="break-all">{diagnostics.worker_id}</span>
              {diagnostics.worker_online === true
                ? t("player.diagnostics.online")
                : diagnostics.worker_online === false
                  ? t("player.diagnostics.offline")
                  : t("player.diagnostics.switching")}
            </ActionLine>
          ) : null}
          {diagnostics?.worker_version || diagnostics?.ffmpeg_version ? (
            <ActionLine>
              {diagnostics.worker_version ? `Worker ${diagnostics.worker_version}` : null}
              {diagnostics.worker_version && diagnostics.ffmpeg_version ? " · " : null}
              {diagnostics.ffmpeg_version ? `ffmpeg ${diagnostics.ffmpeg_version}` : null}
            </ActionLine>
          ) : null}
          {diagnostics?.worker_platform || diagnostics?.worker_arch ? (
            <ActionLine>
              {t("player.diagnostics.platformLine", { platform: [diagnostics.worker_platform, diagnostics.worker_arch].filter(Boolean).join(" · ") })}
            </ActionLine>
          ) : null}
          {diagnostics?.job_id ? (
            <ActionLine>
              {t("player.diagnostics.jobLine")}<span className="break-all">{diagnostics.job_id}</span>
              {diagnostics.job_state
                ? ` · ${JOB_STATE_LABELS[diagnostics.job_state] ?? diagnostics.job_state}`
                : null}
              {diagnostics.job_speed ? ` · ${diagnostics.job_speed}` : null}
            </ActionLine>
          ) : null}
          {diagnostics?.job_exit_code != null ? (
            <ActionLine alert>{t("player.diagnostics.exitCode", { code: diagnostics.job_exit_code })}</ActionLine>
          ) : null}
          {diagnostics?.job_error && diagnostics.job_error !== diagnostics.session_error ? (
            <ActionLine alert>
              <span className="break-all">Worker：{diagnostics.job_error}</span>
            </ActionLine>
          ) : null}
          {diagnostics?.job_stderr_tail ? (
            <ActionLine alert>
              <span className="break-all">ffmpeg stderr：{diagnostics.job_stderr_tail}</span>
            </ActionLine>
          ) : null}
          {diagnostics?.session_error ? (
            <ActionLine alert>
              <span className="break-all">{diagnostics.session_error}</span>
            </ActionLine>
          ) : null}
        </Section>

        <Section title={t("player.diagnostics.video")}>
          {videoSource ? <SourceLine>{videoSource}</SourceLine> : null}
          {videoAction ? <ActionLine>{videoAction}</ActionLine> : null}
          {decision.video?.burn_subtitle ? <ActionLine>{t("player.diagnostics.burnedSubtitles")}</ActionLine> : null}
          <div className={dropRatio > DROP_ALERT_RATIO ? "text-red-300" : "text-white/75"}>
            {t("player.diagnostics.droppedFrames")}{" "}
            <span className="tnum">
              {stats?.droppedFrames != null
                ? `${stats.droppedFrames} / ${stats.totalFrames ?? "?"}`
                : "—"}
            </span>
          </div>
        </Section>

        <Section title={t("player.diagnostics.audio")}>
          {audioSource ? <SourceLine>{audioSource}</SourceLine> : null}
          {audioAction ? <ActionLine>{audioAction}</ActionLine> : null}
        </Section>

        <Section title={t("player.diagnostics.transfer")}>
          <p className="text-white/75">
            {[
              stats?.engine ?? "—",
              formatMbps(stats?.bitrate) && t("player.diagnostics.liveBitrate", { value: formatMbps(stats?.bitrate)! }),
              // 带宽与实时码率并排：带宽贴着码率跑说明线路吃得下、卡的是
              // 服务端转码；带宽远低于码率说明就是线路不够。单看任一个都会误诊。
              // 「带宽」是线路能跑多快（缓冲满了也保持实测值），顶栏「↓」是此刻在下多快，两者不是一个量
              formatBandwidth(stats?.downlinkBps ?? null) &&
                t("player.diagnostics.bandwidth", { value: formatBandwidth(stats?.downlinkBps ?? null)! }),
              stats ? t("player.diagnostics.buffer", { seconds: stats.bufferedSeconds.toFixed(1) }) : null,
              stats ? t("player.diagnostics.playhead", { seconds: stats.currentTimeSeconds.toFixed(1) }) : null,
            ]
              .filter(Boolean)
              .join(" · ")}
          </p>
          {stats ? (
            <p className="text-white/75">
              {[
                t("player.diagnostics.mediaState", { state: READY_STATE_LABELS[stats.readyState] ?? `readyState ${stats.readyState}` }),
                t("player.diagnostics.networkState", { state: NETWORK_STATE_LABELS[stats.networkState] ?? `networkState ${stats.networkState}` }),
                stats.seeking ? t("player.diagnostics.seeking") : stats.paused ? t("player.diagnostics.paused") : t("player.diagnostics.playing"),
              ]
                .filter(Boolean)
                .join(" · ")}
            </p>
          ) : null}
          {/* 「不丝滑」的量化行：用户拖一下进度条，这里马上告诉他等了多少秒；
              卡顿计数不含 seek 造成的等待（qoe.ts 的口径），所以这两个数字
              可以分开读——前者是跳转体验，后者是网络/转码跟不跟得上 */}
          <p className="text-white/75">
            {[
              qoeStats?.lastSeekMs != null
                ? t("player.diagnostics.lastSeek", { seconds: (qoeStats.lastSeekMs / 1000).toFixed(1) })
                : null,
              qoeStats
                ? t("player.diagnostics.rebuffer", { count: qoeStats.rebufferCount,
                    total: qoeStats.rebufferCount > 0 ? t("player.diagnostics.rebufferTotal", { seconds: (qoeStats.rebufferMs / 1000).toFixed(1) }) : "",
                  })
                : null,
            ]
              .filter(Boolean)
              .join(" · ")}
          </p>
          <p className="tnum break-all text-white/50">
            {t("player.diagnostics.session", { session: session.session_id ?? t("player.diagnostics.noSession") })}
          </p>
        </Section>

        {diagnostics?.total_segments != null ? (
          <Section title={t("player.diagnostics.segments")}>
            <SourceLine>
              {pendingSegment != null
                ? t("player.diagnostics.pendingSegment", { segment: segmentLabel(pendingSegment) })
                : diagnostics.requested_segment != null
                  ? t("player.diagnostics.requestedSegment", { segment: segmentLabel(diagnostics.requested_segment) })
                  : t("player.diagnostics.noPendingSegment")}
            </SourceLine>
            <ActionLine>
              {t("player.diagnostics.produced", { produced: segmentLabel(diagnostics.highest_produced_segment), head: segmentLabel(diagnostics.head_segment), count: diagnostics.total_segments })}
            </ActionLine>
            {diagnostics.lead_seconds != null ? (
              // 领先量与挂起态：用户问「为什么转码停了」时这一行直接作答——
              // 停是因为已经领先够多（闭环节流，§A），不是转不动
              <ActionLine>
                {t("player.diagnostics.lead", { seconds: Math.round(diagnostics.lead_seconds), pause: diagnostics.pause_reasons?.includes("lead")
                  ? t("player.diagnostics.pauseLead") : diagnostics.pause_reasons?.includes("disk") ? t("player.diagnostics.pauseDisk") : "" })}
              </ActionLine>
            ) : null}
            <ActionLine>
              {t("player.diagnostics.cache", { size: formatBytes(diagnostics.cache_bytes), hit: diagnostics.cache_hit ? t("player.diagnostics.cacheHit", { count: diagnostics.cached_segments ?? 0 }) : "" })}
            </ActionLine>
            {failedSegment != null ? (
              <ActionLine alert>
                {t("player.diagnostics.failedSegment", { segment: segmentLabel(failedSegment), details: diagnostics.failed_segments.length > 1
                  ? t("player.diagnostics.multipleSegments", { count: diagnostics.failed_segments.length }) : t("player.diagnostics.retryUpload") })}
              </ActionLine>
            ) : null}
            {historicalFailedSegment != null ? (
              <ActionLine>
                {t("player.diagnostics.historicalFailure", { segment: segmentLabel(historicalFailedSegment), details: diagnostics.historical_failed_segments.length > 1
                  ? t("player.diagnostics.multipleSegments", { count: diagnostics.historical_failed_segments.length }) : t("player.diagnostics.behindPlayhead") })}
              </ActionLine>
            ) : null}
            {latestUpload ? (
              <ActionLine alert={latestUpload.status >= 400}>
                {t("player.diagnostics.lastUpload", { upload: uploadLabel(latestUpload, locale) })}
              </ActionLine>
            ) : null}
            {diagnostics.segment_wait_ms != null ? (
              <ActionLine>
                {t("player.diagnostics.lastSegmentWait", { seconds: (diagnostics.segment_wait_ms / 1000).toFixed(1) })}
                {diagnostics.segment_status != null
                  ? ` · HTTP ${diagnostics.segment_status}`
                  : null}
              </ActionLine>
            ) : null}
          </Section>
        ) : null}
      </div>

      <p className="mt-2 border-t border-white/10 pt-1.5 leading-relaxed text-white/60">
        {decision.reason}
      </p>
    </div>
  );
}
