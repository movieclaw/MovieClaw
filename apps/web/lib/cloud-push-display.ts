/**
 * 「MovieClaw Cloud」「App 推送」「通知」三个设置分区的展示口径
 * （docs/design/cloud-push.md §1、§7、§8）。
 *
 * 单独成文件：状态 → 颜色、配对码倒计时、官网地址推导、限额读数这些规则
 * 三个分区共用，而且是能用测试锁住的纯逻辑（test/cloud-push-display.test.mjs）。
 * 这里的措辞直接上屏，改之前先想清楚它在页面上读起来是什么样。
 */

import type { CloudHealth } from "@/lib/api/cloud";
import type {
  DevicePushState,
  MyDeviceStatus,
  MyPushAttention,
  PushChannelView,
  PushQuota,
  PushTestResult,
  PushUncoveredApp,
  RelayProbeView,
} from "@/lib/api/push";

/** 状态色调：全站四档状态语义色（见 globals.css）+ 不承载信号的中性灰。 */
export type Tone = "ok" | "info" | "warn" | "danger" | "neutral";

export const TONE_COLOR: Record<Tone, string> = {
  ok: "var(--ok)",
  info: "var(--info)",
  warn: "var(--warn)",
  danger: "var(--danger)",
  // 与其他分区「未运行 / 已停用」同一个灰
  neutral: "#c0c4cc",
};

/* —— MovieClaw Cloud —— */

/** 官网默认地址：cloud_url 解析不出来时用它。 */
export const DEFAULT_CLOUD_SITE = "https://movieclaw.io";

/**
 * 由云端 API 地址推出官网地址：host 去掉开头的 `api.`，协议和端口原样保留。
 * https://api.movieclaw.io → https://movieclaw.io；
 * 开发者自己的云端（MOVIECLAW_CLOUD_URL）照同一条规则走。
 */
export function cloudSiteOrigin(cloudUrl: string | null | undefined): string {
  if (!cloudUrl) return DEFAULT_CLOUD_SITE;
  let url: URL;
  try {
    url = new URL(cloudUrl);
  } catch {
    return DEFAULT_CLOUD_SITE;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return DEFAULT_CLOUD_SITE;
  const host = url.host.startsWith("api.") ? url.host.slice("api.".length) : url.host;
  return `${url.protocol}//${host}`;
}

/** 「在官网管理」：官网上这个账号名下的服务器列表。 */
export function cloudInstancesUrl(cloudUrl: string | null | undefined): string {
  return `${cloudSiteOrigin(cloudUrl)}/instances`;
}

/** 官网隐私政策里「你的服务器会发给我们什么」那一节：连接后上报什么、为什么、能不能关。 */
export function cloudReportsInfoUrl(cloudUrl: string | null | undefined): string {
  return `${cloudSiteOrigin(cloudUrl)}/zh/privacy#server-reports`;
}

/** 链接给人读的样子：去掉协议头和末尾斜杠，如 movieclaw.io/activate。 */
export function displayUrl(uri: string): string {
  return uri.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").replace(/\/+$/, "");
}

/** 链接的主机名（按钮文案「打开 movieclaw.io 批准」用）。 */
export function displayHost(uri: string): string {
  return displayUrl(uri).split("/")[0];
}

/** 「已连接到 y•••@gmail.com 的 MovieClaw 账号」；云端给的是空串时不硬造一个账号名。 */
export function connectedAccountLine(accountDisplay: string | null | undefined): string {
  const display = accountDisplay?.trim();
  return display ? `已连接到 ${display} 的 MovieClaw 账号` : "已连接到你的 MovieClaw 账号";
}

/** 距 expiresAt 还剩多少秒（向上取整，过期为 0）；解析不出来按已过期算。 */
export function secondsLeft(expiresAt: string, now: number): number {
  const at = Date.parse(expiresAt);
  if (Number.isNaN(at)) return 0;
  return Math.max(0, Math.ceil((at - now) / 1000));
}

/** 倒计时读数：581 → 「9:41」。 */
export function formatCountdown(totalSeconds: number): string {
  const seconds = Math.max(0, Math.floor(totalSeconds));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/**
 * 配对没走完时的说明：优先用服务端的话，没有就按状态给一句。
 * 倒计时走完而服务端还没来得及改状态时，调用方按 expired、不带 message 传进来。
 */
export function pairingFailureText(status: string, message: string | null | undefined): string {
  if (message?.trim()) return message.trim();
  if (status === "denied") return "这次连接在 MovieClaw 官网上被拒绝了。";
  if (status === "expired") return "配对码已过期。";
  return "配对没有完成，请重新获取配对码。";
}

/**
 * 连接异常时的横幅色调：续签失败但令牌还有效是「系统在自己处理」（warn）；
 * 令牌过期、版本不受支持时官方推送已经停了，要人处理（danger）。正常不出横幅。
 */
export function healthTone(health: CloudHealth | null | undefined): Tone | null {
  if (!health || health === "ok") return null;
  return health === "unreachable" ? "warn" : "danger";
}

const HEALTH_FALLBACK: Record<Exclude<CloudHealth, "ok">, string> = {
  unreachable: "暂时连不上 MovieClaw Cloud，正在自动重试，令牌过期前官方推送不受影响。",
  expired: "和 MovieClaw Cloud 的连接已过期，官方推送已停用。检查网络或代理设置后立即同步一次。",
  unsupported: "这个版本的 MovieClaw 已不再受官方推送支持，升级后会自动恢复。",
};

export function healthMessage(
  health: CloudHealth | null | undefined,
  message: string | null | undefined,
): string {
  if (message?.trim()) return message.trim();
  if (!health || health === "ok") return "";
  return HEALTH_FALLBACK[health] ?? "";
}

/** 云端服务通知只有 info / warning 两档。 */
export function noticeTone(level: string): Tone {
  return level === "warning" ? "warn" : "info";
}

const CAPABILITY_LABEL: Record<string, string> = {
  push: "官方推送",
  remote: "远程访问",
  control: "远程控制",
};

export function capabilityLabel(id: string): string {
  return CAPABILITY_LABEL[id] ?? id;
}

export interface CapabilityRow {
  id: string;
  label: string;
  granted: boolean;
}

/**
 * 「权限和能力」清单，完全按数据渲染：官方推送打头（这一期的主角，没授予也要
 * 写明），其余已授予的随后；云端提供了、这台服务器还没授予的排最后，标「即将推出」。
 * 云端没提供的能力一个字也不写——不替云端预告它还没有的东西。
 */
export function capabilityRows(scopes: string[], capabilities: string[]): CapabilityRow[] {
  const ordered = [
    "push",
    ...scopes.filter((id) => id !== "push"),
    ...capabilities.filter((id) => id !== "push" && !scopes.includes(id)),
  ];
  return [...new Set(ordered)].map((id) => ({
    id,
    label: capabilityLabel(id),
    granted: scopes.includes(id),
  }));
}

/* —— App 推送：通道 —— */

export function channelTone(state: string): Tone {
  if (state === "ok") return "ok";
  if (state === "warning") return "warn";
  if (state === "error") return "danger";
  return "neutral";
}

const CHANNEL_STATE_FALLBACK: Record<string, string> = {
  ok: "正常",
  warning: "需要注意",
  error: "出错了",
  inactive: "未启用",
};

/** 官方通道因为没连接 MovieClaw Cloud 而未激活：行内写「未激活」并引导去连接。 */
export function officialAwaitingCloud(
  channel: Pick<PushChannelView, "kind" | "state">,
  cloudState: string,
): boolean {
  return channel.kind === "official" && channel.state === "inactive" && cloudState !== "connected";
}

export function channelPill(
  channel: Pick<PushChannelView, "kind" | "state" | "status_text">,
  cloudState: string,
): { tone: Tone; label: string } {
  if (officialAwaitingCloud(channel, cloudState)) return { tone: "neutral", label: "未激活" };
  return {
    tone: channelTone(channel.state),
    label: channel.status_text?.trim() || CHANNEL_STATE_FALLBACK[channel.state] || channel.state,
  };
}

const AUTH_MODE_LABEL: Record<string, string> = {
  issuer: "签发方令牌",
  static: "令牌",
  none: "无鉴权",
};

/** 鉴权方式给人看的说法；null（还没拉到过 /v1/info）返回 null，调用方不写这一段。 */
export function authModeLabel(mode: string | null | undefined): string | null {
  if (!mode) return null;
  return AUTH_MODE_LABEL[mode] ?? mode;
}

/**
 * 通道行的细节：地址 · 鉴权方式 · 能推送的 Bundle ID。分隔点前用不换行空格，
 * 窄屏折行时点留在上一行行尾，不会有哪一行以「·」开头。
 * 官方通道不写：地址、鉴权方式和官方 App 的 Bundle ID 都由 MovieClaw Cloud 决定，对用户没有意义。
 */
export function channelDetails(
  channel: Pick<PushChannelView, "kind" | "url" | "auth_mode" | "topics">,
): string {
  if (channel.kind === "official") return "";
  return [channel.url, authModeLabel(channel.auth_mode), channel.topics.join(", ")]
    .filter((part) => part)
    .join("\u00a0· ");
}

/**
 * 额度条的宽度（0–100）；上限或用量缺一个就不画条（返回 null）。
 * 用了哪怕一条也至少给 1%：5000 条里用掉 3 条按比例画出来是一根看不见的线，
 * 会被读成「还没用过」。
 */
export function quotaPercent(quota: Pick<PushQuota, "limit" | "used">): number | null {
  const { limit, used } = quota;
  if (limit == null || limit <= 0 || used == null) return null;
  if (used <= 0) return 0;
  return Math.min(100, Math.max(1, (used / limit) * 100));
}

/**
 * 额度读数：「今天已用 132 / 5000 条」，用完时直说用完了。官方通道还没推送过时
 * 只有云端给的上限（「每天最多 5000 条」）；两样都没有返回 null，整块不显示。
 */
export function quotaLabel(quota: Pick<PushQuota, "limit" | "used">): string | null {
  const { limit, used } = quota;
  if (limit != null && limit > 0) {
    if (used == null) return `每天最多 ${limit} 条`;
    if (used >= limit) return `今天的 ${limit} 条已用完`;
    return `今天已用 ${used} / ${limit} 条`;
  }
  return used != null ? `今天已用 ${used} 条` : null;
}

/** 剩不到 5% 时实例只发提醒类通知（§3），额度条转黄提示；之前不占状态色。 */
export function quotaTone(quota: Pick<PushQuota, "limit" | "used">): Tone | null {
  const { limit, used } = quota;
  if (limit == null || limit <= 0 || used == null) return null;
  return used >= limit * 0.95 ? "warn" : null;
}

/** 通道行上的设备数：「3 台设备」；0 台不写（没有就不提）。 */
export function channelDeviceCount(count: number): string | null {
  return count > 0 ? `${count} 台设备` : null;
}

/**
 * 有 App 版本登记了推送却没有任何可用通道时，App 推送页顶部那一句：
 * 「有 1 台设备用的是自己打包的 App（com.friend.mc），没有能推送它的通道」。
 * 没有缺口返回 null，页面什么都不提示。
 */
export function uncoveredSummary(uncovered: PushUncoveredApp[]): string | null {
  if (uncovered.length === 0) return null;
  const devices = uncovered.reduce((sum, entry) => sum + entry.device_count, 0);
  const topics = uncovered.map((entry) => entry.topic).join("、");
  return `有 ${devices} 台设备用的是自己打包的 App（${topics}），没有能推送它的通道`;
}

/* —— 添加自建中继 —— */

/**
 * 这个鉴权方式要不要填令牌：static 和不认识的方式都要（中继协议第 3 节：不认识的
 * 方式也照样带上配置的令牌）；none 不要；issuer 这里加不了；没声明的不强求。
 * 与服务端 services/push/channels.needs_token 同一规则。
 */
export function relayNeedsToken(mode: string | null | undefined): boolean {
  return !!mode && mode !== "none" && mode !== "issuer";
}

/**
 * 保存键为什么还不能按；能保存返回 null。检测结果决定后面的表单：
 * 要令牌的必须填令牌，none 不用填，issuer 这里加不了（要签发方的令牌）。
 * 连上了但加不了（协议不兼容等）时服务端把原因写在 error 里。
 * 地址在检测之后又改过，结果就作废，要重新检测。
 */
export function relayAddBlocker(input: {
  probe: Pick<RelayProbeView, "reachable" | "auth_mode" | "error"> | null;
  probedUrl: string;
  url: string;
  token: string;
  name: string;
}): string | null {
  const { probe } = input;
  if (!probe || input.probedUrl !== input.url.trim()) return "先检测中继地址";
  if (!probe.reachable) return "中继连不上，检查地址后重新检测";
  if (probe.error?.trim()) return probe.error.trim();
  if (probe.auth_mode === "issuer") return "这个中继需要签发方的令牌，暂不支持在这里添加";
  if (relayNeedsToken(probe.auth_mode) && !input.token.trim()) return "填写中继的令牌";
  if (!input.name.trim()) return "给中继起个名字";
  return null;
}

/** 检测通过后名称的默认值：地址的主机名（用户没填过名称时才用）。 */
export function relayNameFromUrl(url: string): string {
  try {
    return new URL(url.trim()).hostname;
  } catch {
    return "";
  }
}

/* —— 我的通知 —— */

/** 事件按 group 分组，组和组内顺序都照后端给的顺序。 */
export function groupEvents<T extends { group: string }>(
  events: T[],
): { group: string; items: T[] }[] {
  const groups: { group: string; items: T[] }[] = [];
  for (const event of events) {
    const existing = groups.find((g) => g.group === event.group);
    if (existing) existing.items.push(event);
    else groups.push({ group: event.group, items: [event] });
  }
  return groups;
}

/** 这个库现在算不算勾上：null = 全部（含以后新建的）都算。 */
export function libraryChecked(libraryIds: number[] | null, id: number): boolean {
  return libraryIds == null || libraryIds.includes(id);
}

/**
 * 勾 / 取消一个库之后要存什么：
 * - 从「全部」里取消一个 → 换成明确的列表（剩下的那些）；
 * - 再勾回来也保持明确列表——「全部（含以后新建的）」只由「全部」那个快捷键选；
 * - 一个都不剩 → 等于不想收了：关掉开关，库选择回到「全部」，下次打开就是全部。
 * 列表只算看得见的库（visibleIds）：看不见的库本来就不推，留着只会让人困惑。
 */
export function toggleLibrary(
  libraryIds: number[] | null,
  visibleIds: number[],
  id: number,
  checked: boolean,
): { libraryIds: number[] | null; turnOff: boolean } {
  const current = visibleIds.filter((v) => libraryChecked(libraryIds, v));
  const next = checked
    ? visibleIds.filter((v) => v === id || current.includes(v))
    : current.filter((v) => v !== id);
  // 一个都不剩 = 关掉这一项，选择回到全部（下次打开就是全选）；勾满了 = 全部（含以后新建的）
  if (next.length === 0) return { libraryIds: null, turnOff: true };
  if (next.length === visibleIds.length) return { libraryIds: null, turnOff: false };
  return { libraryIds: next, turnOff: false };
}

export function myDeviceTone(status: MyDeviceStatus | string): Tone {
  if (status === "ok") return "ok";
  if (status === "no_channel" || status === "permission_denied") return "warn";
  if (status === "bad_token") return "danger";
  return "neutral";
}

const DEVICE_PUSH_FALLBACK: Record<string, string> = {
  no_channel: "这个版本的 App 没有能用的推送通道",
  permission_denied: "系统通知已关闭，在这台设备的设置里打开",
  bad_token: "推送令牌失效了，打开一次 MovieClaw App 会重新登记",
  not_registered: "还没有登记推送，用 MovieClaw App 登录后会自动登记",
};

/**
 * 「设备」页每台设备下面那一行推送说明：能收到（或根本不是 App）就什么都不写，
 * 收不到才写原因——以后端的 status_text 为准，缺了才补。
 */
export function devicePushNote(
  push: DevicePushState | null | undefined,
): { tone: Tone; text: string } | null {
  if (!push || push.status === "ok") return null;
  const text = push.status_text?.trim() || DEVICE_PUSH_FALLBACK[push.status] || push.status;
  return { tone: myDeviceTone(push.status), text };
}

/** 「通知」页顶部提示里的一行：「iPad：系统通知已关闭，在这台设备的设置里打开」。 */
export function attentionLine(item: Pick<MyPushAttention, "device_name" | "status" | "status_text">): string {
  const reason = item.status_text?.trim() || DEVICE_PUSH_FALLBACK[item.status] || item.status;
  return `${item.device_name}：${reason}`;
}

/** 测试按钮旁的说明：发给几台；一台都没有时告诉人设备从哪来。 */
export function testTargetHint(readyDevices: number): string {
  return readyDevices > 0
    ? `发给你的 ${readyDevices} 台设备`
    : "还没有能收到通知的设备：用 MovieClaw App 登录后会出现";
}

/**
 * 测试通知的回执：发出去几台，其余的逐台说原因。只有 ok 算干干净净送达；
 * 别的结果（包括「通道暂时不可用，稍后自动重试」这类已排队的）都把服务端
 * 的说明带上——sent 怎么算以服务端为准。
 */
export function summarizePushTest(result: PushTestResult): {
  tone: "success" | "error";
  message: string;
} {
  const notes = result.results
    .filter((r) => r.result !== "ok")
    .map((r) => `${r.device_name}：${r.message?.trim() || "没有发出去"}`)
    .join("；");
  if (result.sent > 0) {
    return {
      tone: "success",
      message: notes
        ? `测试通知已发给 ${result.sent} 台设备。${notes}`
        : `测试通知已发给 ${result.sent} 台设备，看看手机吧`,
    };
  }
  return {
    tone: "error",
    message: notes ? `测试通知没有发出去。${notes}` : "没有能收通知的设备",
  };
}
