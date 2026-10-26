import { appTranslator } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import { formatDate } from "./i18n/format.ts";

/**
 * 活动总览（银玻璃，components/activity-overview.tsx）的纯逻辑：摘要文案、播放方式配色、
 * 7 天观看涨跌、刷流按站点开关状态汇总。对应原生 App 的 ActivityView.swift（摘要）、
 * NowPlayingRows.swift（播放方式）、ActivityDashboardRows.swift（7 天卡、刷流行）与
 * TaskCards.swift（ActivityBoostTotals / ActivityBoostSites）——两端文案逐字一致。
 *
 * 不碰 React、不发请求，可以直接进 node --test。
 */

import type { DownloadTask } from "@/lib/api/downloaders";
import type { PlaybackDelivery, PlaybackWatchStats } from "@/lib/api/playback";
import type { BoostPool, BoostPoolSite, BoostPoolTask } from "@/lib/api/sites";
// 值导入必须带 .ts 后缀的相对路径：本模块要进 node --test（见 tsconfig 注释）
import { formatBytes } from "./format.ts";

// ---------------------------------------------------------------------------
// 页头实时摘要
// ---------------------------------------------------------------------------

export interface SummaryPart {
  text: string;
  /** 需要处理：标红加粗 */
  alert?: boolean;
}

/**
 * 大标题下的一行实时摘要：「2 项需要处理 · 1 台设备在播放 · 5 个任务进行中」；
 * 什么都没有时「一切正常 · 现在没有人在看」；有事但没人在看时末尾补「现在没有人在看」。
 */
export function activitySummaryParts(counts: {
  attention: number;
  watching: number;
  downloading: number;
  active: number;
}, locale: AppLocale = requestLocale() ?? "zh-Hans"): SummaryPart[] {
  const t = appTranslator(locale);
  const parts: SummaryPart[] = [];
  if (counts.attention > 0) parts.push({ text: t("activity.overview.attentionCount", { count: counts.attention }), alert: true });
  if (counts.watching > 0) parts.push({ text: t("activity.overview.watchingCount", { count: counts.watching }) });
  if (counts.downloading > 0) parts.push({ text: t("activity.overview.downloadingCount", { count: counts.downloading }) });
  if (counts.active > 0) parts.push({ text: t("activity.overview.activeCount", { count: counts.active }) });
  if (parts.length === 0) return [{ text: t("activity.overview.healthy") }, { text: t("activity.overview.noOneWatching") }];
  if (counts.watching === 0) parts.push({ text: t("activity.overview.noOneWatching") });
  return parts;
}

// ---------------------------------------------------------------------------
// 正在播放：播放方式
// ---------------------------------------------------------------------------

/**
 * 播放方式小标的颜色，按对服务器的负担递进：直连绿、重封装与音频转码蓝、
 * 硬件转码橙（--warn）、软件转码红、远程转码紫（负担在别的机器上，单独一色）。
 */
export function deliveryColor(delivery: PlaybackDelivery): string {
  if (delivery.mode === "direct") return "var(--ok)";
  if (delivery.mode === "remux" || delivery.mode === "audio") return "var(--info)";
  if (delivery.execution_kind != null) {
    if (delivery.execution_kind === "remote") return "#c084fc";
    return delivery.execution_kind === "software" ? "var(--danger)" : "var(--warn)";
  }
  // i18n-ignore: legacy playback delivery discriminator; retain for old API responses.
  if (delivery.label === "远程转码") return "#c084fc";
  // i18n-ignore: legacy playback delivery discriminator; retain for old API responses.
  return delivery.label === "软件转码" ? "var(--danger)" : "var(--warn)";
}

/** 转码细节「输出规格 · 在哪转」；直连没有细节 */
export function deliveryDetail(delivery: PlaybackDelivery): string | null {
  if (delivery.mode === "direct") return null;
  const detail = [delivery.target, delivery.executor].filter(Boolean).join(" · ");
  return detail || null;
}

/**
 * 客户端 · 设备名，如「Web · Safari · iPhone」：
 * - 自家客户端的「MovieClaw 」品牌前缀没有信息量，去掉；
 * - 设备名里已有某段以客户端名打头时不再重复（「Apple TV」+「Apple TV · tvOS 27.0」→
 *   「Apple TV · tvOS 27.0」，「iOS」+「iPhone · iOS 27.0」→「iPhone · iOS 27.0」）。
 */
export function deviceLabel(client: string, deviceName: string, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const name = client.startsWith("MovieClaw ") ? client.slice("MovieClaw ".length) : client;
  if (!deviceName) return name || t("activity.overview.unknownDevice");
  const repeats = deviceName
    .split(" · ")
    .some((part) => part === name || part.startsWith(`${name} `));
  if (!name || repeats) return deviceName;
  return `${name} · ${deviceName}`;
}

// ---------------------------------------------------------------------------
// 观看统计：7 天摘要卡
// ---------------------------------------------------------------------------

export interface WeeklyDelta {
  text: string;
  tone: "up" | "flat" | "down";
}

/** 较前 7 天的涨跌；上一周期不可比（服务端还没攒够日志）时不显示 */
export function weeklyDelta(stats: PlaybackWatchStats, locale: AppLocale = requestLocale() ?? "zh-Hans"): WeeklyDelta | null {
  const t = appTranslator(locale);
  if (!stats.previous_available) return null;
  const current = stats.current.watched_ms;
  const previous = stats.previous.watched_ms;
  if (previous <= 0) return current > 0 ? { text: t("activity.overview.weeklyNew"), tone: "up" } : null;
  const ratio = Math.round(((current - previous) / previous) * 100);
  if (ratio === 0) return { text: t("activity.overview.weeklyFlat"), tone: "flat" };
  return ratio > 0
    ? { text: t("activity.overview.weeklyUp", { percent: ratio }), tone: "up" }
    : { text: t("activity.overview.weeklyDown", { percent: -ratio }), tone: "down" };
}


/** "2026-09-26" → 「六」；解析不了原样返回 */
export function weekdayLabel(date: string, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const [year, month, day] = date.split("-").map(Number);
  if (!year || !month || !day) return date;
  return formatDate(new Date(year, month - 1, day), { weekday: locale === "zh-Hans" ? "narrow" : "short" }, locale);
}

// ---------------------------------------------------------------------------
// 刷流做种
// ---------------------------------------------------------------------------

/** 刷流实时汇总（↑/↓ 总速度、已上传、已下载）：总览一行与刷流页页头共用 */
export function boostTotals(tasks: DownloadTask[]) {
  const sum = (pick: (task: DownloadTask) => number | null) =>
    tasks.reduce((total, task) => total + (pick(task) ?? 0), 0);
  return {
    count: tasks.length,
    upSpeed: sum((t) => t.upspeed_bytes),
    downSpeed: sum((t) => t.dlspeed_bytes),
    uploaded: sum((t) => t.uploaded_bytes),
    downloaded: sum((t) => t.completed_bytes),
  };
}

/** 按上行速度倒序（正在出力的浮在最前），同速按累计上传——静默种子之间顺序也稳定 */
export function sortBoostTasks(tasks: DownloadTask[]): DownloadTask[] {
  return [...tasks].sort(
    (a, b) =>
      (b.upspeed_bytes ?? 0) - (a.upspeed_bytes ?? 0) ||
      (b.uploaded_bytes ?? 0) - (a.uploaded_bytes ?? 0),
  );
}

export type BoostMode = "running" | "paused" | "off";

export interface BoostSite {
  id: string;
  name: string;
  mode: BoostMode;
  tasks: DownloadTask[];
  /** 后端的在池概况（保留期、待清理数）；pool 没取到时为 undefined */
  pool?: BoostPoolSite;
}

/**
 * 刷流种子按来源站点的开关状态分组。
 *
 * 关掉刷流不会删种：已下好的种子留在下载器里继续满速做种（暂停只是每种限速），引擎也
 * 不再汰换——所以「还有刷流种子」不等于「刷流开着」。`pool` 为 null（还没取到或取失败）
 * 时一律当作运行中，不替用户下「已关闭」的结论。
 */
export function boostSites(tasks: DownloadTask[], pool: BoostPool | null, locale: AppLocale = requestLocale() ?? "zh-Hans") {
  const t = appTranslator(locale);
  const poolSites = new Map((pool?.sites ?? []).map((site) => [site.site_id, site]));
  const bySite = new Map<string, DownloadTask[]>();
  for (const task of tasks) {
    const key = task.site_id ?? "";
    const bucket = bySite.get(key);
    if (bucket) bucket.push(task);
    else bySite.set(key, [task]);
  }
  const sites: BoostSite[] = [...bySite.entries()]
    .map(([id, siteTasks]) => {
      const info = poolSites.get(id);
      const mode: BoostMode = !pool
        ? "running"
        : info?.boost_enabled
          ? info.boost_paused
            ? "paused"
            : "running"
          : "off";
      const name = siteTasks[0]?.site_name || info?.site_name || (id || t("activity.overview.unknownSite"));
      return { id, name, mode, tasks: siteTasks, pool: info };
    })
    .sort((a, b) => b.tasks.length - a.tasks.length);
  const taskStates = new Map<string, BoostPoolTask>(
    (pool?.tasks ?? []).map((task) => [task.info_hash.toLowerCase(), task]),
  );
  return {
    sites,
    taskStates,
    /** 某个状态下的种子数 */
    count: (mode: BoostMode) =>
      sites.filter((site) => site.mode === mode).reduce((n, site) => n + site.tasks.length, 0),
    /** 已请求清理、等着自动删除的种子数 */
    scheduledCount: (pool?.tasks ?? []).filter((task) => task.cleanup_scheduled).length,
  };
}

/**
 * 总览上的刷流一行：按站点开关状态说清楚——全关了是「刷流已关闭 · N 个种子仍在做种」，
 * 全暂停是「刷流已暂停 · N 个种子限速做种」，否则「刷流做种」并补上部分关闭 / 暂停 /
 * 待删除；只有一切正常时才报已上传总量（ActivityDashboardRows.swift 的 ActivityBoostSummaryRow）。
 */
export function boostSummary(tasks: DownloadTask[], pool: BoostPool | null, locale: AppLocale = requestLocale() ?? "zh-Hans") {
  const t = appTranslator(locale);
  const totals = boostTotals(tasks);
  const sites = boostSites(tasks, pool, locale);
  const off = sites.count("off");
  const paused = sites.count("paused");
  const scheduled = sites.scheduledCount;
  const allOff = off === totals.count;
  const allPaused = paused === totals.count;
  const mode: BoostMode = allOff ? "off" : allPaused ? "paused" : "running";
  const parts = [
    allOff
      ? t("activity.overview.boostSeeding", { count: totals.count })
      : allPaused
        ? t("activity.overview.boostLimited", { count: totals.count })
        : t("activity.boost.torrentCount", { count: totals.count }),
    `↑ ${formatBytes(totals.upSpeed)}/s`,
    !allOff && off > 0 ? t("activity.overview.boostSiteOff", { count: off }) : null,
    !allPaused && paused > 0 ? t("activity.overview.boostPaused", { count: paused }) : null,
    scheduled > 0 ? t("activity.overview.boostScheduled", { count: scheduled }) : null,
    allOff || off > 0 || paused > 0 || scheduled > 0
      ? null
      : t("activity.boost.uploadedSize", { size: formatBytes(totals.uploaded) }),
  ];
  return {
    mode,
    title: allOff ? t("activity.boost.off") : allPaused ? t("activity.boost.paused") : t("activity.boost.heading"),
    detail: parts.filter((part): part is string => part != null).join(" · "),
  };
}
