/**
 * 播放模式决策（docs/design/web-player.md §13）。
 *
 * 一次会话建立后，「用哪个引擎、吃哪个地址、时间轴参照哪里、字幕由谁渲染」
 * 是**一组互相咬合的决定**，必须一次算清、处处引用同一份结果。这层的存在
 * 是几轮字幕 bug 换来的教训：此前这些决定散落在组件的渲染期布尔、effect
 * 里各自重算，同一逻辑写了两遍、七个分支点靠一个布尔松散关联——每改一处
 * 就在别处冒出新组合 bug。
 *
 * ## 模式矩阵
 *
 * | 引擎        | 触发条件                              | 地址        | 时间轴 | 字幕渲染 |
 * |------------|--------------------------------------|------------|--------|---------|
 * | direct     | 档 0（container != hls-fmp4）          | stream_url | 文件   | overlay |
 * | mse        | 有 MSE（full/managed），hls.js         | stream_url | 按会话 | overlay + PiP 补丁轨 |
 * | native-hls | 无 MSE 的原生 HLS 设备（或兜底）       | master_url | 文件   | system-track |
 * | native-hls | iPhone / iPad 播 HEVC（见下）         | stream_url | 文件   | overlay + PiP 补丁轨 |
 *
 * ## iPhone / iPad 的 HEVC 交给系统原生 HLS（2026-10-01 实测改判）
 *
 * ManagedMediaSource 喂 HEVC（典型是 4K HDR10 MKV 换封装直通）每次跳转后都要停 1～2 秒才动：
 * 跳到关键帧上也一样，去掉我们的播放器、只留 hls.js 也一样，hls.js 停止装载后还一样——是 WebKit
 * MSE 管线自己的，H.264 1080p 同样的测法跳完 0.1 秒就走。同一条流交给系统原生 HLS（AVPlayer）
 * 直接吃**媒体列表**：模拟器里真 iOS Safari 首帧 3.5 → 1.1 秒、缓冲内跳转 1.2～2.2 → 0.8～1.0 秒、
 * 远跳约 4 → 1.9 秒，从续播点起播也正常。
 *
 * 只能吃媒体列表、不能吃 master：带 master（服务端的，或按规范补齐 CODECS / VIDEO-RANGE 的）
 * 一律在首片前报 MEDIA_ERR_DECODE（早年实机上原生 HLS 首片报解码错误，多半也是这个原因）。字幕因此走
 * 自绘（master 的字幕组用不上），与无 MSE 老设备的兜底同一套。万一某台设备原生放不了，组件会就地
 * 改回 hls.js（`allowNativeHevc` = false），不降档。H.264 仍走 hls.js：它在 MSE 上跳转本来就快，
 * 还有分片字节数可算码率。
 *
 * ## 字幕渲染器只有两种，且整会话恒定
 *
 * - **overlay**：自绘层画在画面上（VTT 自绘 / ASS 走 JASSUB，位置锚定画面
 *   矩形）。PiP/系统全屏跟不进去，靠一条补丁 `<track>`（页面 JS 在进出时
 *   切显隐——MSE 模式下进 PiP 是用户手势触发，JS 活着，赌得起）。
 * - **system-track**：master 列表的 WEBVTT 字幕组，选中轨**常开**由系统在
 *   一切表面渲染；内联位置用 CSS 抬升修正（globals.css 的 cue-lift）。
 *   **不做任何「按表面切换显隐」**——iOS 滑回桌面自动进 PiP 时页面 JS
 *   冻结时机不可控，任何依赖时序的切换都会间歇性丢字幕（实测踩过）。
 */

import type { ClientCapability, PlaybackSession } from "@/lib/api/playback";

export type PlaybackEngineKind = "direct" | "mse" | "native-hls";
export type SubtitleRenderer = "overlay" | "system-track";

export interface PlaybackMode {
  engine: PlaybackEngineKind;
  /** 喂给引擎的地址（无 MSE 老设备的 native-hls 用 master；iPhone HEVC 的 native-hls 与其余用媒体列表 / 文件直出地址） */
  streamUrl: string;
  /** 时间轴参照点（毫秒）：文件时间 = originMs + currentTime*1000 */
  originMs: number;
  /** 字幕渲染器；整个会话恒定，绝不中途切换 */
  subtitleRenderer: SubtitleRenderer;
  /** overlay 模式下是否挂 PiP 补丁轨（direct 档 0 无会话字幕地址时不挂） */
  pipPatchTrack: boolean;
  /**
   * seek 越出已缓冲区间时是否要换会话重来。只有旧的会话相对制（EVENT
   * 列表只覆盖已转出的部分）需要；VOD 列表覆盖全片、档 0 是完整文件，
   * seek 都是播放器内跳转。
   */
  seekBeyondBufferedRestarts: boolean;
}

/**
 * 判断挂流完成后是否还需要由组件补一次首次 seek。
 *
 * 原生 HLS 的 DirectEngine 会在 loadedmetadata 中自己执行 JS seek；组件
 * 若再挂一个同样的监听器，Safari 可能把两次赋值当成两次 HLS 跳转，导致
 * 首个 init/segment 被取消后重拉，最终表现为笼统的 MEDIA_ERR_DECODE。
 */
export function shouldApplyPostAttachSeek(
  engine: PlaybackEngineKind,
  targetSeconds: number,
): boolean {
  return engine !== "native-hls" && targetSeconds > 1;
}

/**
 * 由会话与能力快照算出本次播放的完整模式。三态里只有 plan 会走到这里；
 * stream_url 缺失（consent/rejected）返回 null。
 */
export function resolvePlaybackMode(
  session: Pick<
    PlaybackSession,
    "stream_url" | "master_url" | "timeline" | "start_ms" | "decision"
  >,
  capability: Pick<ClientCapability, "mse" | "native_hls" | "is_mobile">,
  /** iPhone / iPad 的 HEVC 交给原生 HLS；原生已经失败过（组件就地改回 hls.js）时传 false */
  options: { allowNativeHevc?: boolean } = {},
): PlaybackMode | null {
  if (!session.stream_url) return null;

  const fileTimeline = session.timeline === "file";
  // 会话相对制的参照点是 start_ms；文件绝对制（VOD）分片时间戳就是文件
  // 时间，参照点为 0。档 0 直出没有偏移，也是 0。
  const originMs = fileTimeline ? 0 : session.start_ms;

  if (session.decision.container !== "hls-fmp4") {
    return {
      engine: "direct",
      streamUrl: session.stream_url,
      originMs: 0,
      subtitleRenderer: "overlay",
      pipPatchTrack: true,
      seekBeyondBufferedRestarts: false,
    };
  }

  // 没有 MSE 的老设备走系统原生 HLS，优先使用带字幕组的 master，保留原生字幕
  // 与全屏/AirPlay 的兜底能力。iOS 17+ 暴露的是 ManagedMediaSource，除了上面的
  // HEVC，都交给 hls.js。
  const nativeEligible =
    capability.mse === "none" &&
    capability.native_hls &&
    capability.is_mobile &&
    fileTimeline &&
    session.master_url;
  if (nativeEligible && session.master_url) {
    return {
      engine: "native-hls",
      streamUrl: session.master_url,
      originMs,
      subtitleRenderer: "system-track",
      pipPatchTrack: false,
      seekBeyondBufferedRestarts: false,
    };
  }

  const nativeHevc =
    options.allowNativeHevc !== false &&
    capability.mse === "managed" &&
    capability.native_hls &&
    capability.is_mobile &&
    fileTimeline &&
    session.decision.video?.codec === "hevc";
  if (nativeHevc) {
    return {
      engine: "native-hls",
      streamUrl: session.stream_url,
      originMs,
      subtitleRenderer: "overlay",
      pipPatchTrack: true,
      seekBeyondBufferedRestarts: false,
    };
  }

  if (capability.mse !== "none") {
    return {
      engine: "mse",
      streamUrl: session.stream_url,
      originMs,
      subtitleRenderer: "overlay",
      pipPatchTrack: true,
      seekBeyondBufferedRestarts: !fileTimeline,
    };
  }

  // 没有 MSE 的老设备兜底：原生 HLS 硬吃媒体列表。字幕仍走自绘（没有
  // master 字幕组可用），PiP 体验降级但能播。
  return {
    engine: "native-hls",
    streamUrl: session.stream_url,
    originMs,
    subtitleRenderer: "overlay",
    pipPatchTrack: true,
    seekBeyondBufferedRestarts: !fileTimeline,
  };
}

/**
 * system-track 模式：算每条系统字幕轨该处的 mode。
 *
 * 约定（四方一致，缺一处对位就断）：轨的顺序 = master 里 EXT-X-MEDIA 的
 * 顺序 = 服务端按 decision.subtitles 过滤文本轨（vtt/ass）的顺序 = 前端
 * subtitles.options 的顺序。selectedIndex = -1 表示关闭字幕。
 *
 * 选中轨恒 showing（理由见模块文档），其余 disabled。
 */
export function planSystemTrackModes(
  trackCount: number,
  selectedIndex: number,
): ("showing" | "disabled")[] {
  return Array.from({ length: trackCount }, (_, i) =>
    i === selectedIndex ? "showing" : "disabled",
  );
}
