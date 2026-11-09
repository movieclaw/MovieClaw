import { formatVideoResolution } from "./format.ts";

/**
 * 媒体库海报墙的角标：哪些角标该亮、亮成什么样（纯函数，带单测）。
 *
 * 数据全部来自海报墙接口本身（LibraryItem 的 rating / resolutions / dynamic_range /
 * has_atmos / air_status / has_chinese_subtitle / progress_percent / unplayed_count，
 * 后端随墙批量算好），卡片不为角标多发任何请求。开关存在界面偏好里
 * （`UiPreferences.poster_badges`，每个成员一份、跨设备同步），在「自定义首页」页设置。
 *
 * **默认全关**：改版前库存墙的海报上只有收藏的心——评分是刻意不印的（见
 * components/poster-wall.tsx 的 InventoryCell），老用户升级后墙面必须一格不变。
 */
export interface PosterBadgePrefs {
  rating: boolean;
  year: boolean;
  resolution: boolean;
  /** HDR / 杜比视界 / Atmos */
  format: boolean;
  /** 剧集「完结」；详情页标题旁的播出状态也跟着它与 airing */
  ended: boolean;
  /** 剧集「更新中」 */
  airing: boolean;
  chinese_subtitle: boolean;
  progress: boolean;
  unwatched: boolean;
  /** 顶部角标只在悬停 / 聚焦时显示；底部标记（中字、未看集数、进度条）不受影响 */
  hover_only: boolean;
  /** 评分低于它不显示评分角标；0 = 都显示 */
  min_rating: number;
}

/** 与后端 PosterBadgePrefs 的默认值一致：全关。 */
export const DEFAULT_POSTER_BADGES: PosterBadgePrefs = {
  rating: false,
  year: false,
  resolution: false,
  format: false,
  ended: false,
  airing: false,
  chinese_subtitle: false,
  progress: false,
  unwatched: false,
  hover_only: false,
  min_rating: 0,
};

/** 设置页逐个列出的开关，顺序即界面顺序（顶部 → 底部）。 */
export const POSTER_BADGE_TOGGLES = [
  "rating",
  "year",
  "resolution",
  "format",
  "ended",
  "airing",
  "chinese_subtitle",
  "unwatched",
  "progress",
] as const satisfies readonly (keyof PosterBadgePrefs)[];

/** 老后端 / 首帧缓存缺这一组或缺字段时逐项补默认；类型不对的值当作没设置。 */
export function normalizePosterBadges(data: unknown): PosterBadgePrefs {
  const raw = (data && typeof data === "object" ? data : {}) as Record<string, unknown>;
  const result = { ...DEFAULT_POSTER_BADGES };
  for (const key of [...POSTER_BADGE_TOGGLES, "hover_only"] as const) {
    if (typeof raw[key] === "boolean") result[key] = raw[key];
  }
  const min = raw.min_rating;
  if (typeof min === "number" && Number.isFinite(min)) {
    result.min_rating = Math.min(10, Math.max(0, min));
  }
  return result;
}

/** 角标用得上的条目字段（LibraryItem 的子集；老服务端没有的字段可缺）。 */
export interface PosterBadgeSource {
  kind: string;
  rating: number | null;
  year: number | null;
  resolutions: string[];
  air_status: "airing" | "ended" | null;
  dynamic_range?: string | null;
  has_atmos?: boolean;
  has_chinese_subtitle?: boolean;
  progress_percent?: number | null;
  unplayed_count?: number | null;
}

/** 一格最终要画的角标；全空 = 什么都不画。 */
export interface PosterBadgeSet {
  rating: number | null;
  year: number | null;
  status: "ended" | "airing" | null;
  resolution: string | null;
  /** 动态范围短标签与 Atmos，最多两枚 */
  formats: string[];
  chineseSubtitle: boolean;
  /** 1~99 */
  progress: number | null;
  /** 已格式化（超过 99 写 99+） */
  unwatched: string | null;
}

const DYNAMIC_RANGE_LABELS: Record<string, string> = {
  "Dolby Vision": "DV",
  "HDR10+": "HDR10+",
  HDR10: "HDR10",
  HLG: "HLG",
  HDR: "HDR",
};

/** 动态范围的角标短名：杜比视界写 DV，其余原样（认不出的也原样，不吞掉）。 */
export function dynamicRangeLabel(value: string | null | undefined): string | null {
  if (!value) return null;
  return DYNAMIC_RANGE_LABELS[value] ?? value;
}

/** 规格标签里最高的那档（resolutions 已是 2160p / 1080p … 的去重列表），显示为 4K / 1080p。 */
export function bestResolutionLabel(resolutions: readonly string[]): string | null {
  let best: { height: number; label: string } | null = null;
  for (const resolution of resolutions) {
    const match = /^(\d+)p?$/i.exec(resolution.trim());
    const height = match ? Number(match[1]) : /^(\d+)k$/i.test(resolution.trim()) ? 1000 * Number.parseInt(resolution, 10) : 0;
    if (!best || height > best.height) best = { height, label: formatVideoResolution(resolution) };
  }
  return best?.label ?? null;
}

export function posterBadges(item: PosterBadgeSource, prefs: PosterBadgePrefs): PosterBadgeSet {
  const isTv = item.kind === "tv";
  const rating =
    prefs.rating && item.rating != null && item.rating > 0 && item.rating >= prefs.min_rating
      ? item.rating
      : null;
  const status =
    isTv && item.air_status === "ended" && prefs.ended
      ? "ended"
      : isTv && item.air_status === "airing" && prefs.airing
        ? "airing"
        : null;
  const formats = prefs.format
    ? [dynamicRangeLabel(item.dynamic_range), item.has_atmos ? "Atmos" : null].filter(
        (label): label is string => Boolean(label),
      )
    : [];
  const progress = item.progress_percent;
  const unplayed = item.unplayed_count;
  return {
    rating,
    year: prefs.year && item.year ? item.year : null,
    status,
    resolution: prefs.resolution ? bestResolutionLabel(item.resolutions) : null,
    formats,
    chineseSubtitle: prefs.chinese_subtitle && Boolean(item.has_chinese_subtitle),
    progress: prefs.progress && progress != null && progress > 0 ? Math.min(100, progress) : null,
    unwatched:
      prefs.unwatched && isTv && unplayed != null && unplayed > 0
        ? unplayed > 99
          ? "99+"
          : String(unplayed)
        : null,
  };
}

/** 这一格有没有任何一枚角标要画（没有就完全走改版前的渲染路径） */
export function hasAnyBadge(set: PosterBadgeSet): boolean {
  return hasTopBadges(set) || set.chineseSubtitle || set.unwatched != null || set.progress != null;
}

/** 顶部那一排（评分 / 年份 / 状态 / 分辨率 / 格式）有没有东西 */
export function hasTopBadges(set: PosterBadgeSet): boolean {
  return Boolean(set.rating != null || set.year || set.status || set.resolution || set.formats.length);
}

/**
 * 详情页标题旁的播出状态。海报墙上「更新中」默认关是怕满屏标签；详情页只有一处，
 * 所以打开了任一状态角标，两种状态都标出来（与原用户脚本同一取舍）。
 */
export function detailAirStatus(
  kind: string,
  airStatus: "airing" | "ended" | null | undefined,
  prefs: PosterBadgePrefs,
): "airing" | "ended" | null {
  if (kind !== "tv" || !airStatus) return null;
  return prefs.ended || prefs.airing ? airStatus : null;
}
