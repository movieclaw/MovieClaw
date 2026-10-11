/**
 * 播放失败之后下一步做什么（与 iOS App 的 `FailurePolicy` 同一套规则，
 * apps/apple/MovieClaw/Features/Player/PlaybackRouting.swift；设计见 docs/design/player-engine.md §3、
 * docs/design/web-player.md §6.3 的 2026-10-01 补记）。纯函数，表驱动单测在 test/player-failure-policy.test.mjs。
 *
 * 2026-10-01 之前网页的规则是「出问题就降档」：断线、取流报错、长时间缺粮都走降档回路，
 * 线路慢时还会自动把直通档改成转码。iOS 在 2026-09-28 拍板「力保不降级」后，同一部片、
 * 同一条线路，App 上是继续缓冲、原地重连，网页上画质却被降了。现在两端对齐：
 *
 * 1. **网络问题不降档、不降码率。**线路慢只是缓冲（stall.ts 根本不报失败），要不要换低画质
 *    由用户决定（quality-suggestion.ts 的提示卡）。连接断了（取流报错、缓冲见底且持续没有
 *    字节）就同档原地重开（新会话 = 新取流令牌）；原文件直出先探片源取不取得到，404 说明
 *    文件不在了，一直取不到落错误页让用户重试——换转码要一样的线路，还要用户同意画质变差。
 * 2. **一时的解码问题先原位重开一次**（视频直通的档：直出 / 换封装 / 音频单转，降档就丢原画），
 *    3 分钟内再出问题才降档。
 * 3. **确定解不了才降档**（浏览器报格式不支持、转码档也解不动）。
 */

/** 失败的原因（由调用方归类） */
export type FailureCause =
  /** 断线、取流持续失败、缓冲见底且持续没有字节 */
  | "network"
  /** 一时的解码问题：缓冲够却不走、解码出错、持续掉帧 */
  | "decode"
  /** 确定解不了：浏览器报格式 / 编码不支持 */
  | "decode-final"
  /** 片源不在了（探片源回 404） */
  | "source-missing";

export type FailureResponse =
  /** 同档原地重开（新会话 = 新令牌）；原文件直出先等片源取得到 */
  | "reconnect"
  /** 同档原位重开一次（一时的解码问题） */
  | "retry"
  /** 原文件直出一直取不到片源：错误页，让用户检查网络后重试 */
  | "fail-network"
  /** 片源不在了：错误页说明 */
  | "fail-source-missing"
  /** 这一档放不了（或服务端流反复连不上）：逐级降档 */
  | "step-down";

export interface FailureInput {
  cause: FailureCause;
  /** 在直出原文件（档 0，没有服务端会话） */
  playsOriginalFile: boolean;
  /**
   * 直出的是网盘直链（取流地址 302 到网盘，探片源时看到的是跳转）。浏览器连不上网盘
   * 不等于服务器连不上：同档重开用完就降档，改由服务端读直链换封装 / 转码
   */
  remoteSource?: boolean;
  /** 视频直通（copy）：直出 / 换封装 / 音频单转，降档就丢原画 */
  copyVideo: boolean;
  /** 连接类失败还能同档重开（NetworkRestartBudget 没用完） */
  restartAllowed: boolean;
  /** 一时的解码问题还能原位重开一次（RetryBudget 没用完） */
  retryAllowed: boolean;
}

export function decideFailure(input: FailureInput): FailureResponse {
  switch (input.cause) {
    case "network":
      if (input.restartAllowed) return "reconnect";
      // 服务端流连续重开都没出画：多半是这一档的换封装 / 转码出了问题，按「这一档放不了」往下走；
      // 原文件直出连不上就是连不上，换什么都一样——网盘直链除外（见 remoteSource）
      return input.playsOriginalFile && !input.remoteSource ? "fail-network" : "step-down";
    case "source-missing":
      return "fail-source-missing";
    case "decode":
      return input.copyVideo && input.retryAllowed ? "retry" : "step-down";
    case "decode-final":
      return "step-down";
  }
}

/**
 * 连接类失败的同档重开额度：连续 2 次重开都没能放起来就不再算「网络问题」。
 * 真正放起来（playing）就清零——播了一小时断一次线，不该被一小时前的那次占额度。
 */
export const NETWORK_RESTART_LIMIT = 2;

export class NetworkRestartBudget {
  private count = 0;

  get consecutive(): number {
    return this.count;
  }

  /** 又一次网络类失败：还能同档重开返回 true（并记一次） */
  allowRestart(): boolean {
    if (this.count >= NETWORK_RESTART_LIMIT) return false;
    this.count += 1;
    return true;
  }

  reachedPlaying(): void {
    this.count = 0;
  }

  reset(): void {
    this.count = 0;
  }
}

/**
 * 一时的解码问题原位重开的额度：同一集 3 分钟内只重开一次。真解不了的，重开也一样——
 * 反复出问题说明不是一时的，再失败就降档。
 */
export const RETRY_WINDOW_MS = 180_000;

export class RetryBudget {
  private lastAt: number | null = null;

  /** 还能原位重开返回 true（并记下这一次） */
  allowRetry(now: number): boolean {
    if (this.lastAt !== null && now - this.lastAt < RETRY_WINDOW_MS) return false;
    this.lastAt = now;
    return true;
  }

  reset(): void {
    this.lastAt = null;
  }
}

/** 断线后探片源 / 重开会话的间隔（秒）：约 1 分钟，用完落错误页 */
export const RECONNECT_DELAYS_S = [2, 4, 8, 15, 15, 15] as const;

export class ReconnectBackoff {
  private index = 0;

  /** 下一次重试前等多少秒；用完返回 null */
  nextDelay(): number | null {
    if (this.index >= RECONNECT_DELAYS_S.length) return null;
    const delay = RECONNECT_DELAYS_S[this.index];
    this.index += 1;
    return delay;
  }

  reset(): void {
    this.index = 0;
  }
}

/** 探片源（取 1 个字节）的结论 */
export type SourceProbeVerdict = "reachable" | "missing" | "unreachable";

/**
 * 探片源的 HTTP 状态 → 结论。`null` = 请求本身没成功（断网、超时）。
 * 401 / 403 算取得到：令牌过期了，开新会话换张令牌就取得到。
 * `"redirect"` = 服务端把取流跳转到了网盘直链（strm 条目）：服务器在、条目在，算取得到——
 * 不跟着跳到网盘去探，跨域的网盘地址不给 CORS，fetch 跟过去只会报错。
 */
export function sourceProbeVerdict(status: number | "redirect" | null): SourceProbeVerdict {
  if (status === "redirect") return "reachable";
  if (status === null) return "unreachable";
  if ((status >= 200 && status < 300) || status === 401 || status === 403) return "reachable";
  if (status === 404) return "missing";
  return "unreachable";
}

/**
 * 重开会话的请求失败了，值不值得按退避再试：断网（HttpError 的 status 0）、超时、
 * 限流、服务端 5xx 是一时的；4xx 是服务端明确的拒绝（无权、文件不在），再试也一样。
 */
export function isTransientStatus(status: number): boolean {
  return status === 0 || status === 408 || status === 429 || status >= 500;
}
