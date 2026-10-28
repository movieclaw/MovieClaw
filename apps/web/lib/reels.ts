/**
 * 片段页（/reels）的纯逻辑：筛选条件、画质记忆、片段字幕（同 iOS `ReelFilterMenu` / `ReelsQuality` /
 * `ReelPlayer.clipSubtitles` 的对应部分）。单独成模块是为了进 node --test：只用相对路径与 `import type`。
 */

import { filterCount, filterQuery, type LibraryFilter } from "./library-filter.ts";
import type { ReelSubtitle } from "./api/reels.ts";
import type { SubtitleOption } from "./player/subtitles.ts";

// —— 筛选 ——

/**
 * 菜单里的维度（键与媒体库筛选同名，见 iOS `ReelFilterMenu.dimensions`）。维度与取值沿用**媒体库筛选**：
 * 刷片刷的是自己的片库，与媒体库墙同一批片子、同一套口径；另加刷片特有的电影 / 剧集（`kind`）与
 * 「只看没看过的」（`watch`）。
 */
export const REEL_DIMENSIONS = ["genres", "decades", "countries", "rating_gte", "runtimes"] as const;
export type ReelDimension = (typeof REEL_DIMENSIONS)[number];
export type ReelFilterKey = ReelDimension | "watch";

/** 筛选条件 → 查询串：`/reels` 与 `/reels/facets` 共用（菜单上写几部、点下去刷的就是这几部） */
export function reelFilterQuery(filter: LibraryFilter, kind: string | null, query: URLSearchParams): void {
  filterQuery(filter, query);
  if (kind) query.set("kind", kind);
}

/** 某一维当前勾着的取值（与 `/reels/facets` 的取值同形：字符串） */
export function reelFilterValues(filter: LibraryFilter, key: ReelFilterKey): string[] {
  switch (key) {
    case "genres":
      return (filter.genres ?? []).map(String);
    case "decades":
      return filter.decades ?? [];
    case "countries":
      return filter.countries ?? [];
    case "rating_gte":
      return filter.ratingGte == null ? [] : [String(filter.ratingGte)];
    case "runtimes":
      return filter.runtimes ?? [];
    case "watch":
      return filter.watch ? [filter.watch] : [];
  }
}

function flip<T>(list: T[] | undefined, value: T): T[] {
  const current = list ?? [];
  return current.includes(value) ? current.filter((v) => v !== value) : [...current, value];
}

/** 勾上 / 取消一个取值：维内多选；评分（下限）与观看状态是单选，再点一次取消 */
export function toggleReelFilter(filter: LibraryFilter, key: ReelFilterKey, value: string): LibraryFilter {
  switch (key) {
    case "genres":
      return { ...filter, genres: flip(filter.genres, Number(value)) };
    case "decades":
      return { ...filter, decades: flip(filter.decades, value) };
    case "countries":
      return { ...filter, countries: flip(filter.countries, value) };
    case "runtimes":
      return { ...filter, runtimes: flip(filter.runtimes, value) };
    case "rating_gte":
      return { ...filter, ratingGte: filter.ratingGte === Number(value) ? null : Number(value) };
    case "watch":
      return { ...filter, watch: filter.watch === value ? null : (value as LibraryFilter["watch"]) };
  }
}

/** 切到「其他」时只留观看状态：它没有 TMDB 档案，别的维度带过去只会把它筛空 */
export function watchOnly(filter: LibraryFilter): LibraryFilter {
  return filter.watch ? { watch: filter.watch } : {};
}

/**
 * 顶栏筛选键写什么（寸土寸金，同 iOS `ReelFilterMenu.buttonTitle`）：没条件写「全部」，只有一个条件写它的值，
 * 多个条件写「已筛选 N 项」。文案由调用方按类型渲染。
 */
export type ReelFilterSummary =
  | { type: "all" }
  | { type: "kind"; value: string }
  | { type: "unwatched" }
  | { type: "value"; key: ReelDimension; value: string }
  | { type: "count"; count: number };

export function reelFilterSummary(filter: LibraryFilter, kind: string | null): ReelFilterSummary {
  const count = filterCount(filter) + (kind ? 1 : 0);
  if (count === 0) return { type: "all" };
  if (count > 1) return { type: "count", count };
  if (kind) return { type: "kind", value: kind };
  if (filter.watch === "unwatched") return { type: "unwatched" };
  for (const key of REEL_DIMENSIONS) {
    const [value] = reelFilterValues(filter, key);
    if (value !== undefined) return { type: "value", key, value };
  }
  return { type: "count", count };
}

// —— 画质 ——

/** 片段能选的画质上限（原画之外），与正片的档位相同 */
export const REELS_QUALITY_HEIGHTS = [1080, 720, 480] as const;
const QUALITY_KEY = "movieclaw.reels.quality";

/**
 * 片段的画质上限；null = 原画（不限，交服务端按浏览器能力决定直出 / 转封装 / 转码）。
 *
 * 与正片按片记的画质分开（同 iOS `ReelsQuality`）：片段一条几十秒、每条都是别的片，只记一个值——在外面
 * 选了 720p，之后刷到的每一条都是 720p。iOS 还按在家 / 外网分开记、外网默认 720p；网页分不清网络环境
 * （同 lib/player/quality.ts），默认原画，卡了自己降。
 */
export function loadReelsQuality(): number | null {
  try {
    const stored = Number(window.localStorage.getItem(QUALITY_KEY));
    return (REELS_QUALITY_HEIGHTS as readonly number[]).includes(stored) ? stored : null;
  } catch {
    return null;
  }
}

export function saveReelsQuality(maxHeight: number | null): void {
  try {
    if (maxHeight === null) window.localStorage.removeItem(QUALITY_KEY);
    else window.localStorage.setItem(QUALITY_KEY, String(maxHeight));
  } catch {
    // 隐私模式写不进：这次刷片照样生效
  }
}

// —— 字幕 ——

/**
 * 片段字幕 → 字幕层要的轨（同 iOS `ReelPlayer.clipSubtitles`）：服务端只抽片段前后一小段，时间戳是文件时间。
 * srt 让服务端转成 VTT 交浏览器解析，ass 原样交 JASSUB。图形字幕没有文件（限了画质时由转码压进画面），返回 null。
 */
export function reelSubtitleTrack(subtitle: ReelSubtitle | null): SubtitleOption | null {
  if (!subtitle?.url) return null;
  const format = (subtitle.format ?? "").toLowerCase();
  const kind = format === "ass" || format === "ssa" ? "ass" : format === "srt" ? "vtt" : null;
  if (!kind) return null;
  const name = subtitle.title?.trim() || subtitle.language || `embedded:${subtitle.ordinal}`;
  return {
    ref: `embedded:${subtitle.ordinal}`,
    label: name,
    title: name,
    detail: format,
    kind,
    url: kind === "vtt" ? `${subtitle.url}&format=vtt` : subtitle.url,
    language: subtitle.language,
    isDefault: true,
    isAi: false,
  };
}

/** 要服务端压进画面的字幕：只有图形字幕（没有片段字幕文件）、且限了画质（反正要转码）时才压（同 iOS） */
export function reelBurnTrack(subtitle: ReelSubtitle | null, maxHeight: number | null): string {
  return subtitle && !subtitle.url && maxHeight !== null ? `embedded:${subtitle.ordinal}` : "off";
}
