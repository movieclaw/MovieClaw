import type { AppLocale } from "./i18n/negotiate.ts";
import { appTranslator } from "./i18n/translate.ts";
import { formatList } from "./i18n/format.ts";

export type DiscoverySort = "popular" | "rating" | "newest" | "most-rated";

export interface DiscoveryFilters {
  genreIds: number[];
  originCountry?: string;
  year?: number;
  ratingGte?: number;
  runtimeLte?: number;
  sort: DiscoverySort;
}

export const EMPTY_DISCOVERY_FILTERS: DiscoveryFilters = {
  genreIds: [],
  sort: "popular",
};

const COUNTRY_KEYS = [
  ["CN", "media.regions.mainlandChina"],
  ["US", "media.regions.unitedStates"],
  ["JP", "media.regions.japan"],
  ["KR", "media.regions.southKorea"],
  ["GB", "media.regions.unitedKingdom"],
  ["FR", "media.regions.france"],
  ["HK", "media.regions.chinaHongKong"],
  ["TW", "media.regions.chinaTaiwan"],
  ["IN", "media.regions.india"],
] as const;

const COUNTRY_LABELS = new Map(COUNTRY_KEYS.map(([code, key]) => [code as string, key]));
const SORT_LABELS = {
  popular: "media.filters.popular",
  rating: "media.filters.rated",
  newest: "media.filters.newest",
  "most-rated": "media.filters.mostRated",
} as const;

/** 排序的全部取值（菜单按这个顺序列出） */
export function discoverySorts(locale?: AppLocale): Array<[DiscoverySort, string]> {
  const t = appTranslator(locale);
  return (Object.entries(SORT_LABELS) as Array<[DiscoverySort, typeof SORT_LABELS[DiscoverySort]]>).map(([value, key]) => [value, t(key)]);
}
export function discoveryCountries(locale?: AppLocale): Array<[string, string]> {
  const t = appTranslator(locale);
  return COUNTRY_KEYS.map(([code, key]) => [code, t(key)]);
}
function countryLabel(code: string, locale?: AppLocale): string {
  const key = COUNTRY_LABELS.get(code);
  return key ? appTranslator(locale)(key) : code;
}
/** 最低评分、最长片长两个维度的可选档位 */
export const DISCOVERY_RATING_STEPS = [6, 7, 8, 9] as const;
export const DISCOVERY_RUNTIME_STEPS = [60, 90, 120, 150] as const;

type SearchValues = Record<string, string | string[] | undefined>;

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function validNumber(value: string | undefined, min: number, max: number): number | undefined {
  if (!value) return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= min && parsed <= max ? parsed : undefined;
}

/** URL 是筛选状态的唯一来源；无效或过期值安全忽略，不让分享链接破坏页面。 */
export function parseDiscoveryFilters(values: SearchValues): DiscoveryFilters {
  const sortValue = first(values.sort);
  const sort: DiscoverySort =
    sortValue === "rating" || sortValue === "newest" || sortValue === "most-rated"
      ? sortValue
      : "popular";
  const genres = (first(values.genres) ?? "")
    .split(",")
    .map(Number)
    .filter((value) => Number.isInteger(value) && value > 0);
  const country = first(values.country)?.toUpperCase();
  const year = validNumber(first(values.year), 1874, 2100);
  const ratingGte = validNumber(first(values.rating), 0, 10);
  const runtimeLte = validNumber(first(values.runtime), 1, 600);
  return {
    genreIds: [...new Set(genres)],
    sort,
    ...(country && /^[A-Z]{2}$/.test(country) ? { originCountry: country } : {}),
    ...(year !== undefined ? { year } : {}),
    ...(ratingGte !== undefined ? { ratingGte } : {}),
    ...(runtimeLte !== undefined ? { runtimeLte } : {}),
  };
}

export function discoveryFilterCount(filters: DiscoveryFilters): number {
  return (
    Number(filters.genreIds.length > 0) +
    Number(Boolean(filters.originCountry)) +
    Number(Boolean(filters.year)) +
    Number(filters.ratingGte !== undefined) +
    Number(Boolean(filters.runtimeLte)) +
    Number(filters.sort !== "popular")
  );
}

/** 把 URL 筛选状态转为可扫读标签；类型名由后端本地化清单补齐。 */
export function discoveryFilterLabels(
  filters: DiscoveryFilters,
  genreNames: ReadonlyMap<number, string> = new Map(), locale?: AppLocale,
): string[] {
  const labels = filters.genreIds.map((id) => genreNames.get(id)).filter(Boolean) as string[];
  if (filters.genreIds.length > 0 && labels.length === 0) {
    labels.push(appTranslator(locale)("media.filters.genreCount", { count: filters.genreIds.length }));
  }
  if (filters.originCountry) {
    labels.push(countryLabel(filters.originCountry, locale));
  }
  if (filters.year) labels.push(appTranslator(locale)("media.filters.yearValue", { year: filters.year }));
  if (filters.ratingGte !== undefined) labels.push(appTranslator(locale)("media.filters.ratingValue", { rating: filters.ratingGte }));
  if (filters.runtimeLte) labels.push(appTranslator(locale)("media.filters.runtimeValue", { minutes: filters.runtimeLte }));
  if (filters.sort !== "popular") labels.push(appTranslator(locale)(SORT_LABELS[filters.sort]));
  return labels;
}

export function discoveryFiltersQuery(filters: DiscoveryFilters, source = "tmdb"): string {
  const params = new URLSearchParams();
  if (source !== "tmdb") params.set("source", source);
  if (filters.genreIds.length > 0) params.set("genres", filters.genreIds.join(","));
  if (filters.originCountry) params.set("country", filters.originCountry);
  if (filters.year) params.set("year", String(filters.year));
  if (filters.ratingGte !== undefined) params.set("rating", String(filters.ratingGte));
  if (filters.runtimeLte) params.set("runtime", String(filters.runtimeLte));
  if (filters.sort !== "popular") params.set("sort", filters.sort);
  return params.toString();
}

export function discoveryFiltersKey(filters: DiscoveryFilters): string {
  return discoveryFiltersQuery(filters);
}

/**
 * 组合发现的六个筛选维度，固定顺序（对应 iOS DiscoverFilter.swift 的 DiscoverFilterDimension）。
 * 右上角筛选菜单与结果页头部的条件胶囊都按这个顺序排：胶囊不按启用与否重排，
 * 改完一项原地变亮，手指下的东西不会跑位。
 */
export const DISCOVERY_FILTER_DIMENSIONS = [
  "genres",
  "country",
  "year",
  "rating",
  "runtime",
  "sort",
] as const;
export type DiscoveryFilterDimension = (typeof DISCOVERY_FILTER_DIMENSIONS)[number];

/** 维度名；年份与片长按电影 / 剧集换说法 */
export function discoveryDimensionTitle(
  dimension: DiscoveryFilterDimension,
  mediaType: string, locale?: AppLocale,
): string {
  const t = appTranslator(locale);
  const movie = mediaType === "movie";
  switch (dimension) {
    case "genres":
      return t("media.filters.genres");
    case "country":
      return t("media.filters.country");
    case "year":
      return movie ? t("media.filters.movieYear") : t("media.filters.tvYear");
    case "rating":
      return t("media.filters.rating");
    case "runtime":
      return movie ? t("media.filters.movieRuntime") : t("media.filters.tvRuntime");
    case "sort":
      return t("media.filters.sort");
  }
}

/**
 * 维度当前取值的可读文字；未启用返回 undefined（排序停在默认的「热门优先」也算未启用，
 * 与 discoveryFilterCount 同口径）。类型选多了或名字还没到（深链进来时清单在路上）时
 * 给计数，胶囊不至于被撑成一长条。
 */
export function discoveryDimensionSummary(
  dimension: DiscoveryFilterDimension,
  filters: DiscoveryFilters,
  genreNames: ReadonlyMap<number, string> = new Map(), locale?: AppLocale,
): string | undefined {
  switch (dimension) {
    case "genres": {
      const ids = filters.genreIds;
      if (ids.length === 0) return undefined;
      const names = ids.map((id) => genreNames.get(id)).filter(Boolean) as string[];
      if (names.length === ids.length && names.length <= 2) return formatList(names, locale);
      return names.length > 0 ? appTranslator(locale)("media.filters.genreSummary", { name: names[0], count: ids.length }) : appTranslator(locale)("media.filters.genreCount", { count: ids.length });
    }
    case "country":
      return filters.originCountry
        ? (countryLabel(filters.originCountry, locale))
        : undefined;
    case "year":
      return filters.year ? appTranslator(locale)("media.filters.yearValue", { year: filters.year }) : undefined;
    case "rating":
      return filters.ratingGte !== undefined ? appTranslator(locale)("media.filters.ratingValue", { rating: filters.ratingGte }) : undefined;
    case "runtime":
      return filters.runtimeLte ? appTranslator(locale)("media.filters.runtimeValue", { minutes: filters.runtimeLte }) : undefined;
    case "sort":
      return filters.sort === "popular" ? undefined : appTranslator(locale)(SORT_LABELS[filters.sort]);
  }
}

/** 撤掉一个维度的条件（排序回到「热门优先」） */
export function clearDiscoveryDimension(
  filters: DiscoveryFilters,
  dimension: DiscoveryFilterDimension,
): DiscoveryFilters {
  const next = { ...filters };
  switch (dimension) {
    case "genres":
      next.genreIds = [];
      break;
    case "country":
      delete next.originCountry;
      break;
    case "year":
      delete next.year;
      break;
    case "rating":
      delete next.ratingGte;
      break;
    case "runtime":
      delete next.runtimeLte;
      break;
    case "sort":
      next.sort = "popular";
      break;
  }
  return next;
}

/**
 * 右上角筛选键上的字（照 App Store「App」页右上角的类别按钮）：只写类型——
 * 没选是「全部」，选一个写类型名，选多个写「动作等 2 个」。其他维度不在这里表达：
 * 一有条件就进了结果页，头部胶囊已把每一项写清楚。
 */
export function discoveryFilterButtonTitle(
  filters: DiscoveryFilters,
  genreNames: ReadonlyMap<number, string> = new Map(), locale?: AppLocale,
): string {
  const t = appTranslator(locale);
  const [first] = filters.genreIds;
  if (first === undefined) return t("media.filters.all");
  const name = genreNames.get(first);
  if (filters.genreIds.length === 1) return name ?? appTranslator(locale)("media.filters.genreCount", { count: 1 });
  return name ? appTranslator(locale)("media.filters.genreSummary", { name, count: filters.genreIds.length }) : appTranslator(locale)("media.filters.genreCount", { count: filters.genreIds.length });
}

/** 单选维度当前值的字符串形式（菜单单选组用）；未启用为 ""，排序给实际档位 */
export function discoveryDimensionValue(
  filters: DiscoveryFilters,
  dimension: Exclude<DiscoveryFilterDimension, "genres">,
): string {
  switch (dimension) {
    case "country":
      return filters.originCountry ?? "";
    case "year":
      return filters.year ? String(filters.year) : "";
    case "rating":
      return filters.ratingGte === undefined ? "" : String(filters.ratingGte);
    case "runtime":
      return filters.runtimeLte ? String(filters.runtimeLte) : "";
    case "sort":
      return filters.sort;
  }
}

/** 把单选维度设成菜单选中的值；"" 表示「不限」（排序为「热门优先」） */
export function withDiscoveryDimension(
  filters: DiscoveryFilters,
  dimension: Exclude<DiscoveryFilterDimension, "genres">,
  value: string,
): DiscoveryFilters {
  const next = clearDiscoveryDimension(filters, dimension);
  if (!value) return next;
  switch (dimension) {
    case "country":
      return { ...next, originCountry: value };
    case "year":
      return { ...next, year: Number(value) };
    case "rating":
      return { ...next, ratingGte: Number(value) };
    case "runtime":
      return { ...next, runtimeLte: Number(value) };
    case "sort":
      return { ...next, sort: value as DiscoverySort };
  }
}
