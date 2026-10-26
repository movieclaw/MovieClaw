import { appTranslator, type AppMessageKey } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import { formatList } from "./i18n/format.ts";

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
export function cloudReportsInfoUrl(cloudUrl: string | null | undefined,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return `${cloudSiteOrigin(cloudUrl)}/${locale === "zh-Hans" ? "zh" : "en"}/privacy#server-reports`;
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
export function connectedAccountLine(accountDisplay: string | null | undefined,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const display = accountDisplay?.trim();
  const t = appTranslator(locale);
  return display ? t("settings.cloudConnect.accountLine", { account: display }) : t("settings.cloudConnect.ownAccountLine");
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
export function pairingFailureText(status: string, message: string | null | undefined,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  if (message?.trim()) return message.trim();
  const t = appTranslator(locale);
  if (status === "denied") return t("settings.cloudConnect.failureDenied");
  if (status === "expired") return t("settings.cloudConnect.failureExpired");
  return t("settings.cloudConnect.failureIncomplete");
}

/**
 * 连接异常时的横幅色调：续签失败但令牌还有效是「系统在自己处理」（warn）；
 * 令牌过期、版本不受支持时官方推送已经停了，要人处理（danger）。正常不出横幅。
 */
export function healthTone(health: CloudHealth | null | undefined): Tone | null {
  if (!health || health === "ok") return null;
  return health === "unreachable" ? "warn" : "danger";
}

const HEALTH_FALLBACK: Record<Exclude<CloudHealth, "ok">, AppMessageKey> = {
  unreachable: "settings.cloudConnect.healthUnreachable",
  expired: "settings.cloudConnect.healthExpired",
  unsupported: "settings.cloudConnect.healthUnsupported",
};

export function healthMessage(
  health: CloudHealth | null | undefined,
  message: string | null | undefined,
  locale: AppLocale = requestLocale() ?? "zh-Hans",
): string {
  if (message?.trim()) return message.trim();
  if (!health || health === "ok") return "";
  return Object.hasOwn(HEALTH_FALLBACK, health) ? appTranslator(locale)(HEALTH_FALLBACK[health]) : "";
}

/** 云端服务通知只有 info / warning 两档。 */
export function noticeTone(level: string): Tone {
  return level === "warning" ? "warn" : "info";
}

const CAPABILITY_LABEL: Record<string, AppMessageKey> = {
  push: "settings.cloudConnect.capabilityPush",
  remote: "settings.cloudConnect.capabilityRemote",
  control: "settings.cloudConnect.capabilityControl",
};

export function capabilityLabel(id: string, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  return Object.hasOwn(CAPABILITY_LABEL, id) ? appTranslator(locale)(CAPABILITY_LABEL[id]) : id;
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
export function capabilityRows(scopes: string[], capabilities: string[],
  locale: AppLocale = requestLocale() ?? "zh-Hans"): CapabilityRow[] {
  const ordered = [
    "push",
    ...scopes.filter((id) => id !== "push"),
    ...capabilities.filter((id) => id !== "push" && !scopes.includes(id)),
  ];
  return [...new Set(ordered)].map((id) => ({
    id,
    label: capabilityLabel(id, locale),
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

const CHANNEL_STATE_FALLBACK: Record<string, AppMessageKey> = {
  ok: "settings.pushChannels.stateOk",
  warning: "settings.pushChannels.stateWarning",
  error: "settings.pushChannels.stateError",
  inactive: "settings.pushChannels.stateInactive",
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
  locale: AppLocale = requestLocale() ?? "zh-Hans",
): { tone: Tone; label: string } {
  const t = appTranslator(locale);
  if (officialAwaitingCloud(channel, cloudState)) return { tone: "neutral", label: t("settings.pushChannels.stateUnactivated") };
  return {
    tone: channelTone(channel.state),
    label: channel.status_text?.trim() || (Object.hasOwn(CHANNEL_STATE_FALLBACK, channel.state) ? t(CHANNEL_STATE_FALLBACK[channel.state]) : channel.state),
  };
}

const AUTH_MODE_LABEL: Record<string, AppMessageKey> = {
  issuer: "settings.pushChannels.authIssuer",
  static: "settings.pushChannels.token",
  none: "settings.pushChannels.authNone",
};

/** 鉴权方式给人看的说法；null（还没拉到过 /v1/info）返回 null，调用方不写这一段。 */
export function authModeLabel(mode: string | null | undefined,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  if (!mode) return null;
  return Object.hasOwn(AUTH_MODE_LABEL, mode) ? appTranslator(locale)(AUTH_MODE_LABEL[mode]) : mode;
}

/**
 * 通道行的细节：地址 · 鉴权方式 · 能推送的 Bundle ID。分隔点前用不换行空格，
 * 窄屏折行时点留在上一行行尾，不会有哪一行以「·」开头。
 * 官方通道不写：地址、鉴权方式和官方 App 的 Bundle ID 都由 MovieClaw Cloud 决定，对用户没有意义。
 */
export function channelDetails(
  channel: Pick<PushChannelView, "kind" | "url" | "auth_mode" | "topics">,
  locale: AppLocale = requestLocale() ?? "zh-Hans",
): string {
  if (channel.kind === "official") return "";
  return [channel.url, authModeLabel(channel.auth_mode, locale), channel.topics.join(", ")]
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
export function quotaLabel(quota: Pick<PushQuota, "limit" | "used">,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const { limit, used } = quota;
  const t = appTranslator(locale);
  if (limit != null && limit > 0) {
    if (used == null) return t("settings.pushChannels.quotaLimit", { limit });
    if (used >= limit) return t("settings.pushChannels.quotaExhausted", { limit });
    return t("settings.pushChannels.quotaUsedLimit", { used, limit });
  }
  return used != null ? t("settings.pushChannels.quotaUsed", { used }) : null;
}

/** 剩不到 5% 时实例只发提醒类通知（§3），额度条转黄提示；之前不占状态色。 */
export function quotaTone(quota: Pick<PushQuota, "limit" | "used">): Tone | null {
  const { limit, used } = quota;
  if (limit == null || limit <= 0 || used == null) return null;
  return used >= limit * 0.95 ? "warn" : null;
}

/** 通道行上的设备数：「3 台设备」；0 台不写（没有就不提）。 */
export function channelDeviceCount(count: number, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  return count > 0 ? appTranslator(locale)("settings.pushChannels.deviceCount", { count }) : null;
}

/**
 * 有 App 版本登记了推送却没有任何可用通道时，App 推送页顶部那一句：
 * 「有 1 台设备用的是自己打包的 App（com.friend.mc），没有能推送它的通道」。
 * 没有缺口返回 null，页面什么都不提示。
 */
export function uncoveredSummary(uncovered: PushUncoveredApp[],
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  if (uncovered.length === 0) return null;
  const devices = uncovered.reduce((sum, entry) => sum + entry.device_count, 0);
  const topics = uncovered.map((entry) => entry.topic).join(locale === "zh-Hans" ? "、" : ", ");
  return appTranslator(locale)("settings.pushChannels.uncovered", { count: devices, topics });
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
}, locale: AppLocale = requestLocale() ?? "zh-Hans"): string | null {
  const { probe } = input;
  const t = appTranslator(locale);
  if (!probe || input.probedUrl !== input.url.trim()) return t("settings.pushChannels.checkFirst");
  if (!probe.reachable) return t("settings.pushChannels.checkUnreachable");
  if (probe.error?.trim()) return probe.error.trim();
  if (probe.auth_mode === "issuer") return t("settings.pushChannels.issuerBlocker");
  if (relayNeedsToken(probe.auth_mode) && !input.token.trim()) return t("settings.pushChannels.tokenRequired");
  if (!input.name.trim()) return t("settings.pushChannels.nameRequired");
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
export function groupEvents<T extends { group: string; group_id?: string | null }>(
  events: T[],
): { group: string; id?: string; items: T[] }[] {
  const groups: { group: string; id?: string; items: T[] }[] = [];
  for (const event of events) {
    const id = event.group_id ?? event.group;
    const existing = groups.find((g) => (g.id ?? g.group) === id);
    if (existing) existing.items.push(event);
    else groups.push({ group: event.group, items: [event], ...(event.group_id != null ? { id } : {}) });
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
  if (status === "no_channel" || status === "permission_denied" || status === "unsupported_build")
    return "warn";
  if (status === "bad_token") return "danger";
  return "neutral";
}

const DEVICE_PUSH_FALLBACK: Record<string, AppMessageKey> = {
  unsupported_build: "settings.devices.push.unsupportedBuild",
  no_channel: "settings.devices.push.noChannel",
  permission_denied: "settings.devices.push.permissionDenied",
  bad_token: "settings.devices.push.badToken",
  not_registered: "settings.devices.push.notRegistered",
};

/**
 * 「设备」页每台设备下面那一行推送说明：能收到（或根本不是 App）就什么都不写，
 * 收不到才写原因——以后端的 status_text 为准，缺了才补。
 */
export function devicePushNote(
  push: DevicePushState | null | undefined,
  locale: AppLocale = requestLocale() ?? "zh-Hans",
): { tone: Tone; text: string } | null {
  if (!push || push.status === "ok") return null;
  const text = push.status_text?.trim() || (Object.hasOwn(DEVICE_PUSH_FALLBACK, push.status) ? appTranslator(locale)(DEVICE_PUSH_FALLBACK[push.status]) : null) || push.status;
  return { tone: myDeviceTone(push.status), text };
}

/** 「通知」页顶部提示里的一行：「iPad：系统通知已关闭，在这台设备的设置里打开」。 */
export function attentionLine(item: Pick<MyPushAttention, "device_name" | "status" | "status_text">,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const reason = item.status_text?.trim() || (Object.hasOwn(DEVICE_PUSH_FALLBACK, item.status) ? t(DEVICE_PUSH_FALLBACK[item.status]) : null) || item.status;
  return t("settings.notificationPreferences.reasonLine", { name: item.device_name, reason });
}

/** 测试按钮旁的说明：发给几台；一台都没有时告诉人设备从哪来。 */
export function testTargetHint(readyDevices: number, imAccounts = 0,
  locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const targets = [
    readyDevices > 0 ? t("settings.notificationPreferences.devices", { count: readyDevices }) : "",
    imAccounts > 0 ? t("settings.notificationPreferences.imAccounts", { count: imAccounts }) : "",
  ].filter(Boolean);
  return targets.length > 0
    ? t("settings.notificationPreferences.testTargets", { targets: locale === "zh-Hans" ? targets.join("和 ") : formatList(targets, locale) })
    : t("settings.notificationPreferences.noTargetsHint");
}

/**
 * 测试通知的回执：发出去几台，其余的逐台说原因。只有 ok 算干干净净送达；
 * 别的结果（包括「通道暂时不可用，稍后自动重试」这类已排队的）都把服务端
 * 的说明带上——sent 怎么算以服务端为准。
 */
export function summarizePushTest(result: PushTestResult, locale: AppLocale = requestLocale() ?? "zh-Hans"): {
  tone: "success" | "error";
  message: string;
} {
  const t = appTranslator(locale);
  const notes = result.results
    .filter((r) => r.result !== "ok")
    .map((r) => t("settings.notificationPreferences.reasonLine", { name: r.device_name, reason: r.message?.trim() || t("settings.notificationPreferences.notSent") }))
    .join(locale === "zh-Hans" ? "；" : "; ");
  if (result.sent > 0) {
    // IM 也是通知渠道，回执里单说（device_id 为 im），不算进「台设备」
    const im = result.results.some((r) => r.device_id === "im" && r.result === "ok");
    const devices = result.sent - (im ? 1 : 0);
    const targets = [devices > 0 ? t("settings.notificationPreferences.devices", { count: devices }) : "", im ? "IM" : ""].filter(Boolean);
    const target = locale === "zh-Hans" ? targets.join("和 ") : formatList(targets, locale);
    return {
      tone: "success",
      message: notes
        ? t("settings.notificationPreferences.partialReceipt", { target, notes })
        : t("settings.notificationPreferences.sentReceipt", { target, hint: devices > 0 ? t("settings.notificationPreferences.checkPhone") : t("settings.notificationPreferences.checkIm") }),
    };
  }
  return {
    tone: "error",
    message: notes ? t("settings.notificationPreferences.failedReceipt", { notes }) : t("settings.notificationPreferences.noDevices"),
  };
}
