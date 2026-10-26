import { appTranslator } from "../i18n/translate.ts";

/**
 * 停顿归因：分清「解码器卡住」「线路慢」与「连接断了」（与 iOS App 的 `StallWatch` 同一套规则，
 * apps/apple/MovieClaw/Features/Player/PlaybackWatchdogs.swift）。
 *
 * 只看「currentTime 不动」会把处置完全不同的三件事混为一谈：
 *
 * - **解码器卡住**（缓冲里明明还有 ≥3 秒却放不动）：坏流的最常见表现不是报错，而是
 *   解码器悄悄停住、界面永远转圈。先原地推两把（见 shouldNudge），推不动 8 秒判失败。
 * - **线路慢**（缓冲见底，但字节还在进来）：这**不是失败**，一直等——转圈下显示实时加载
 *   速度，用户可以暂停攒缓冲；反复卡或一次等太久由换画质提示（quality-suggestion.ts）
 *   问用户要不要降画质。2026-09-28 iOS 拍板「网络问题不是降级信号」：原来这里等满时限就
 *   判「缺粮」，网页因此会自动转码降画质（2026-10-01 改为与 App 一致）。
 * - **连接断了**（缓冲见底且连续十几秒一个字节都没收到）：判 dead，同档原地重开
 *   （failure-policy.ts）。原文件直出 15 秒；服务端流（转码器赶片时本来就会一阵阵没有
 *   字节）给足 45 秒。
 */

/** 有数据却不前进，判定为解码卡死的秒数。 */
export const STALL_TIMEOUT_S = 8;

/** 「解码卡死」判定要求的最小前方缓冲（秒）。

只有缓冲里**明确还有一大段**却播不动，才够格叫解码卡死。转码会话里
buffered 的尾巴就是「已经转出来的全部」，播放头贴着尾巴跑时前方常剩
0.5~2 秒——那是**追上了编码器**（starve 语义，值得等 45 秒），不是浏览器
吃不下码流。烧录/软转会话起步慢，按 0.5 秒的旧阈值 8 秒就误判降档，
表现为「选个 PGS 字幕先给我降了一档」（真机踩中）。真正的解码卡死
（buffered 里躺着十几秒就是不走）仍然 8 秒内抓住。 */
export const DECODE_STALL_MIN_BUFFER_S = 3;
/**
 * 服务端流（档 1～4 的会话分片）：缓冲见底后连续多少秒没有收到字节，判定连接断了。
 *
 * 取值要压得住「转码起步慢」这种正常情况：转码会话刚起来时编码器要先追上首帧，
 * 一阵阵没有字节是常事。
 */
export const SERVER_DEAD_S = 45;
/**
 * 档 0 直出：缓冲见底后连续多少秒没有收到字节，判定连接断了。直出没有转码器可等，
 * 十几秒一个字节都没到只可能是断了（线路慢的话字节是在进来的，不会走到这里）。
 */
export const DIRECT_DEAD_S = 15;
/** 小于这个秒数的前方缓冲视同没有——四舍五入的抖动不该被当成"有数据"。 */

export type StallVerdict = "ok" | "decode-stalled" | "dead";

/** 有数据却不动时，先「推一把」再谈判死的起点（秒）。 */
export const NUDGE_AT_S = 3;
/** 一次停滞里最多推几把；推完仍不动才够格进入 decode-stalled 判定。 */
export const MAX_NUDGES = 2;
/** 推一把的幅度（秒）：跳进缓冲区间内的下一个瞬间，重新触发解码管线。 */
export const NUDGE_STEP_S = 0.1;

/**
 * 该不该推一把（hls.js 的 nudge-on-stall 同款思路）。
 *
 * iOS 的 AVPlayer 在会话重启 + seek 之后会出现「缓冲明明覆盖播放头、
 * paused=false、readyState=3，就是不走」的 wedge（2026-08-26 真机日志实证：
 * buffered 1100.1-1112.1、播放头 1103.91、停滞 8 秒被误判成解码卡死而降档）。
 * 微调 currentTime 能把解码管线重新踢活，代价近乎为零；真正的坏流推不动，
 * 推满 MAX_NUDGES 次后仍停滞照旧走 decode-stalled 降档——只是把判死起点
 * 从 8 秒推迟到最坏约 3+3+8 秒，换取 wedge 场景不再白白重开整路会话。
 */
export function shouldNudge(input: {
  stalledFor: number;
  nudges: number;
  bufferedAhead: number;
  /** HTMLMediaElement.readyState：< 3（HAVE_FUTURE_DATA）说明还在预滚 */
  readyState: number;
  /** 本次挂流后 currentTime 是否真正前进过 */
  everAdvanced: boolean;
}): boolean {
  // 两道硬闸（2026-08-26 真机回归的教训）：起播预滚阶段 AVPlayer 的
  // currentTime 本来就不动，此时改 currentTime 会把预滚管线冲掉重来——
  // 表现为永远起不了播、看门狗降档、会话反复重开狂闪黑屏。wedge 的定义
  // 是「播着播着楞住」，所以必须真正播起来过、且 readyState 已到
  // HAVE_FUTURE_DATA 才有资格推。
  if (!input.everAdvanced || input.readyState < 3) return false;
  return (
    input.stalledFor >= NUDGE_AT_S &&
    input.nudges < MAX_NUDGES &&
    input.bufferedAhead >= DECODE_STALL_MIN_BUFFER_S
  );
}

export interface StallInput {
  paused: boolean;
  ended: boolean;
  seeking: boolean;
  /** 距上次采样，currentTime 是否前进过 */
  advanced: boolean;
  /** currentTime 前方还有多少秒缓冲 */
  bufferedAhead: number;
  /** 已经连续停顿了多少秒 */
  stalledFor: number;
  /** 缓冲见底期间连续多少秒一个字节都没收到（有字节进来就清零） */
  silentFor: number;
  /** 断线判定的秒数；不传按服务端流的 SERVER_DEAD_S，档 0 传 DIRECT_DEAD_S */
  deadLimitS?: number;
}

/**
 * 一次采样的判定。暂停、结束、拖动中一律不算停顿——用户自己按的暂停不该
 * 被当成故障。缓冲见底时只看字节还在不在进来：在进来就是线路慢，不算失败。
 */
export function classifyStall(input: StallInput): StallVerdict {
  if (input.paused || input.ended || input.seeking || input.advanced) return "ok";
  if (input.bufferedAhead >= DECODE_STALL_MIN_BUFFER_S) {
    return input.stalledFor >= STALL_TIMEOUT_S ? "decode-stalled" : "ok";
  }
  return input.silentFor >= (input.deadLimitS ?? SERVER_DEAD_S) ? "dead" : "ok";
}

/** 判定 → 面向用户的中文原因。用户报障时这句话就是全部线索。 */
export function stallReason(
  verdict: Exclude<StallVerdict, "ok">,
  deadLimitS: number = SERVER_DEAD_S,
): string {
  if (verdict === "decode-stalled") {
    return appTranslator()("player.errors.decodeStall", { seconds: STALL_TIMEOUT_S });
  }
  return deadLimitS < SERVER_DEAD_S
    ? appTranslator()("player.errors.directStall", { seconds: deadLimitS })
    : appTranslator()("player.errors.serverStall", { seconds: deadLimitS });
}

/** `currentTime` 前方的连续缓冲秒数；不在任何缓冲区间内记 0。 */
export function bufferedAhead(video: {
  currentTime: number;
  buffered: { length: number; start(i: number): number; end(i: number): number };
}): number {
  for (let i = 0; i < video.buffered.length; i += 1) {
    if (video.buffered.start(i) <= video.currentTime && video.buffered.end(i) >= video.currentTime) {
      return video.buffered.end(i) - video.currentTime;
    }
  }
  return 0;
}
