import type { EpisodeSeason, EpisodeWindow, SeasonOverview } from "@/lib/api/subscriptions";
import { formatList } from "./i18n/format.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import { appTranslator } from "./i18n/translate.ts";

/**
 * 订阅窗口：一季上千集时先订阅一部分（docs/design/subscription-episode-cap.md）。
 *
 * 判定都在服务端（episode_windows / episode_seasons），这里放三样东西：
 * 什么时候给用户看这个选项；订阅弹层里用户改动的草稿怎么变成提交内容；
 * 以及「这一季在不在播」——完结的超长季从第 1 集订起，在播的超长季订
 * 最新的 N 集且之后播出的照常进来，弹层文案随之不同。
 */

/**
 * 单季集数达到这个数才提供「先订阅一部分」。更短的季整季订阅就好，不给用户多出
 * 一个与他无关的选项（最少配置、最少交互）。长寿动画、日更剧、国产
 * 漫剧动辄上百上千集，一次全下既占磁盘也未必看得完。
 */
export const EPISODE_CAP_THRESHOLD = 100;

/** 超长的一季默认先订阅的集数；「继续订阅」「往前再订」每次都是这么多。 */
export const EPISODE_CAP_BATCH = 20;

type SeasonCounts = Pick<SeasonOverview, "season_number" | "episode_count" | "aired_count">;

/** 千分位的集数：1,043。 */
export function formatEpisodes(count: number): string {
  return count.toLocaleString("en-US");
}

/** 一季的总集数（弹层只有季概览，取宣称集数与已播集数中大的）。 */
export function seasonTotal(season: Pick<SeasonOverview, "episode_count" | "aired_count">): number {
  return Math.max(season.episode_count ?? 0, season.aired_count);
}

/** 这一季长到值得问一句「先订阅一部分吗」。特别季不算。 */
export function isLongSeason(season: SeasonCounts): boolean {
  return season.season_number > 0 && seasonTotal(season) >= EPISODE_CAP_THRESHOLD;
}

/**
 * 调整订阅时这一季能不能「先订阅一部分」：不看阈值（老剧中途上车，一季二十几集也
 * 可能想从第 N 集起，issue #950），至少两集才谈得上一部分；在播季按已播集数算。
 * 创建订阅的弹层仍只对超长季提供（isLongSeason），不给每一季都多出一行。
 */
export function canCapSeason(season: SeasonCounts, airing: boolean): boolean {
  return season.season_number > 0 && (airing ? season.aired_count : seasonTotal(season)) >= 2;
}

/**
 * 这一季是不是「在播」：剧还在播（TMDB status 为 Returning Series），而且它是
 * 最近一个开播的季。完结的超长季从第 1 集订起；在播的订最新一批——追这类剧的
 * 用户最想要的就是最新的几集。已在播的新一季还没有已播集时按完结季处理
 * （从第 1 集订起，反正也没有更早的集可补）。
 */
export function isAiringSeason(
  mediaStatus: string | null | undefined,
  seasons: readonly SeasonCounts[],
  seasonNumber: number,
): boolean {
  if (mediaStatus !== "Returning Series") return false;
  const started = seasons.filter((s) => s.season_number > 0 && s.aired_count > 0);
  return started.length > 0 && Math.max(...started.map((s) => s.season_number)) === seasonNumber;
}

/** 一季的订阅窗口：从第 start 集起（含），到第 end 集（含）；end=null 不设上界。 */
export interface CapWindow {
  start: number;
  end: number | null;
}

/**
 * 窗口给用户的读法。end 设值是「前 N 集」；end 不设时，在播季读作「最新 N 集」
 * （之后播出的照常进来），完结季读作「从第 N 集起」——同一个窗口，只是完结季
 * 没有新集可等，说「最新」会误导（issue #950）。
 */
export type WindowKind = "first" | "latest" | "from";

export function windowKind(win: Pick<CapWindow, "end">, airing: boolean): WindowKind {
  if (win.end !== null) return "first";
  return airing ? "latest" : "from";
}

/** 服务端给的窗口的读法：在播与否看它标的 airing；旧服务端不标时沿用旧读法（最新 N 集）。 */
export function windowKindOf(win: Pick<EpisodeWindow, "end" | "airing">): WindowKind {
  return windowKind(win, win.airing ?? true);
}

/**
 * 弹层里用户对窗口的改动：键缺失 = 没动过（超长的季按默认先订阅一批），
 * null = 用户选了「全部」，有值 = 用户改动后的窗口。存窗口本身而不是集数，
 * 在播季的「最新 N 集」随新集播出自动生长，保存时不悄悄滑动。
 */
export type CapDraft = Record<number, CapWindow | null>;

/** 窗口盖住整季（start=1 且不设上界，或 end 不低于总集数）就等于没设。 */
function normalizeWindow(window: CapWindow, total: number): CapWindow | null {
  const start = Math.max(1, Math.floor(window.start));
  const end = window.end === null ? null : Math.max(start, window.end);
  if (start === 1 && (end === null || end >= total)) return null;
  // 两头都收的混合窗口不是弹层能表达的：有 start 就按「从第 X 集起」处理
  return start > 1 ? { start, end: null } : { start: 1, end };
}

/** 没动过时这一季的默认窗口：完结季从第 1 集订一批；在播季订最新一批（end 不设上界）。 */
export function defaultWindow(season: SeasonCounts, airing: boolean): CapWindow | null {
  return airing
    ? { start: Math.max(1, season.aired_count - EPISODE_CAP_BATCH + 1), end: null }
    : { start: 1, end: EPISODE_CAP_BATCH };
}

/**
 * 点「先订阅一部分」时给的窗口：默认那一批，但保证真的截掉了一段——季不到一批
 * 那么长时，默认值会盖住整季，点了看起来没反应。
 */
export function partWindow(season: SeasonCounts, airing: boolean): CapWindow {
  return airing
    ? { start: Math.max(2, season.aired_count - EPISODE_CAP_BATCH + 1), end: null }
    : { start: 1, end: Math.max(1, Math.min(EPISODE_CAP_BATCH, seasonTotal(season) - 1)) };
}

/**
 * 这一季当前生效的窗口；null = 订阅整季（选了全部、窗口盖住整季，或不长的季没动过）。
 * 草稿里有值就以草稿为准，不论季长短：调整订阅能给短季设窗口，存量订阅里经接口
 * 设过的窗口也原样保留。
 */
export function effectiveWindow(
  season: SeasonCounts,
  draft: CapDraft,
  airing: boolean,
): CapWindow | null {
  const value = draft[season.season_number];
  if (value !== undefined) {
    return value === null ? null : normalizeWindow(value, seasonTotal(season));
  }
  return isLongSeason(season) ? defaultWindow(season, airing) : null;
}

/** 提交给服务端的窗口：只含被勾选、且确实截断了本季的季。 */
export function capsPayload(
  seasons: readonly SeasonCounts[],
  selected: ReadonlySet<number>,
  draft: CapDraft,
  mediaStatus: string | null | undefined,
): Record<number, CapWindow> {
  const caps: Record<number, CapWindow> = {};
  for (const season of seasons) {
    if (!selected.has(season.season_number)) continue;
    const win = effectiveWindow(
      season,
      draft,
      isAiringSeason(mediaStatus, seasons, season.season_number),
    );
    if (win !== null) caps[season.season_number] = win;
  }
  return caps;
}

/**
 * 已有订阅的草稿起点：订阅范围内每一季都记下它现在的窗口（没有窗口就是明确的
 * 「全部」），免得存量订阅一打开调整弹层就被默认值悄悄改成「先订阅一批」。
 * 弹层里新勾上的超长季没有记录，仍按默认先订阅一批。
 */
export function draftFromSeasons(seasons: readonly EpisodeSeason[] | null | undefined): CapDraft {
  const draft: CapDraft = {};
  for (const season of seasons ?? []) {
    draft[season.season_number] = season.window ? { ...season.window } : null;
  }
  return draft;
}

/** 详情页已设的窗口 {季号: 窗口}（整体替换提交时，未改的季原样带回）。 */
export function currentWindows(seasons: readonly EpisodeSeason[] | null | undefined) {
  const windows: Record<number, CapWindow> = {};
  for (const season of seasons ?? []) {
    if (season.window) windows[season.season_number] = { ...season.window };
  }
  return windows;
}

/** 两份窗口是否相同（与键顺序无关）。 */
export function sameWindows(a: Record<number, CapWindow>, b: Record<number, CapWindow>): boolean {
  const keys = Object.keys(a);
  return (
    keys.length === Object.keys(b).length &&
    keys.every((key) => {
      const x = a[Number(key)];
      const y = b[Number(key)];
      return x.start === y.start && x.end === y.end;
    })
  );
}

/** 把某一季的窗口改成 next 之后的完整窗口表；next 盖住整季就去掉这一季的窗口。 */
export function windowsAfter(
  current: Record<number, CapWindow>,
  next: CapWindow | null,
  seasonNumber: number,
  total: number,
): Record<number, CapWindow> {
  const windows = { ...current };
  const normalized = next === null ? null : normalizeWindow(next, total);
  if (normalized === null) delete windows[seasonNumber];
  else windows[seasonNumber] = normalized;
  return windows;
}

/**
 * 在播窗口订阅的集数：「已订阅最新 N 集」里的 N。锚定**已播**集数（宣称的集数
 * 可能还没播到），拿不到已播数时退回窗口的总集数（TMDB 已录的最大集号）。
 */
export function windowCount(
  win: EpisodeWindow,
  airedBySeason?: Readonly<Record<number, number>>,
): number {
  const aired = airedBySeason?.[win.season_number];
  return Math.max(1, (aired ?? win.total) - win.start + 1);
}

/** 详情页「收录范围」：第 1 季（前 20 集）、第 2 季（最新 25 集）、第 3 季（第 120 集起）。 */
export function rangeLabel(
  selectedSeasons: readonly number[],
  windows: readonly EpisodeWindow[] | null | undefined,
  airedBySeason?: Readonly<Record<number, number>>,
  locale: AppLocale = requestLocale() ?? "zh-Hans",
): string {
  const t = appTranslator(locale);
  const bySeason = new Map((windows ?? []).map((win) => [win.season_number, win]));
  const parts = selectedSeasons.map((season) => {
    const name = season === 0 ? t("media.season.specials") : t("media.season.title", { number: season });
    const win = bySeason.get(season);
    if (win === undefined) return name;
    switch (windowKindOf(win)) {
      case "latest":
        return t("subscription.cap.rangeLatest", { name, count: windowCount(win, airedBySeason) });
      case "from":
        return t("subscription.cap.rangeFrom", { name, start: win.start });
      default:
        return t("subscription.cap.rangeFirst", { name, count: win.end ?? 0 });
    }
  });
  return formatList(parts, locale, { type: "unit", style: "short" });
}
