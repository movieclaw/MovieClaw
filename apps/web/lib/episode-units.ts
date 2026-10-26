import { appTranslator } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";

export interface EpisodeUnit {
  season_number: number;
  episode_number: number;
}

export interface EpisodeSeasonSummary {
  seasonNumber: number;
  episodes: number[];
}

export interface EpisodeUnitsSummary {
  kind: "movie" | "episodes";
  label: string;
  fullLabel: string;
  episodeCount: number;
  hiddenEpisodeCount: number;
  seasons: EpisodeSeasonSummary[];
}

interface EpisodeRange {
  seasonNumber: number;
  start: number;
  end: number;
}

const MAX_VISIBLE_RANGES = 3;
const FALLBACK_VISIBLE_RANGES = 2;

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

function buildRanges(season: EpisodeSeasonSummary): EpisodeRange[] {
  const ranges: EpisodeRange[] = [];
  for (const episode of season.episodes) {
    const previous = ranges[ranges.length - 1];
    if (previous && episode === previous.end + 1) {
      previous.end = episode;
      continue;
    }
    ranges.push({ seasonNumber: season.seasonNumber, start: episode, end: episode });
  }
  return ranges;
}

function rangeEpisodeCount(range: EpisodeRange): number {
  return range.end - range.start + 1;
}

/**
 * 把相邻的区间重新按季拼接。季号只在每季开头出现一次，既保留 SxxEyy
 * 的熟悉格式，也避免长列表反复占用横向空间。
 */
function formatRanges(ranges: EpisodeRange[], locale: AppLocale): string {
  const seasons: { seasonNumber: number; labels: string[] }[] = [];
  for (const range of ranges) {
    let season = seasons[seasons.length - 1];
    if (!season || season.seasonNumber !== range.seasonNumber) {
      season = { seasonNumber: range.seasonNumber, labels: [] };
      seasons.push(season);
    }
    season.labels.push(
      range.start === range.end
        ? `E${pad(range.start)}`
        : `E${pad(range.start)}–E${pad(range.end)}`,
    );
  }
  return seasons
    .map((season) => `S${pad(season.seasonNumber)}${season.labels.join(locale === "zh-Hans" ? "、" : ", ")}`)
    .join(" · ");
}

/**
 * 下载任务的季集摘要。连续集号压成区间；过于零散时只保留前两个区间，
 * 同时明确标出隐藏了多少集，完整列表交给任务卡的展开区域展示。
 */
export function summarizeEpisodeUnits(units: EpisodeUnit[], locale: AppLocale = requestLocale() ?? "zh-Hans"): EpisodeUnitsSummary | null {
  const t = appTranslator(locale);
  if (units.length === 0) return null;
  if (units.some((unit) => unit.season_number === 0 && unit.episode_number === 0)) {
    return {
      kind: "movie",
      label: t("media.kind.feature"),
      fullLabel: t("media.kind.feature"),
      episodeCount: 0,
      hiddenEpisodeCount: 0,
      seasons: [],
    };
  }

  const uniqueUnits = new Map<string, EpisodeUnit>();
  for (const unit of units) {
    uniqueUnits.set(`${unit.season_number}:${unit.episode_number}`, unit);
  }
  const sortedUnits = [...uniqueUnits.values()].sort(
    (left, right) =>
      left.season_number - right.season_number || left.episode_number - right.episode_number,
  );
  const seasons: EpisodeSeasonSummary[] = [];
  for (const unit of sortedUnits) {
    let season = seasons[seasons.length - 1];
    if (!season || season.seasonNumber !== unit.season_number) {
      season = { seasonNumber: unit.season_number, episodes: [] };
      seasons.push(season);
    }
    season.episodes.push(unit.episode_number);
  }

  const ranges = seasons.flatMap(buildRanges);
  const fullLabel = formatRanges(ranges, locale);
  if (ranges.length <= MAX_VISIBLE_RANGES) {
    return {
      kind: "episodes",
      label: fullLabel,
      fullLabel,
      episodeCount: sortedUnits.length,
      hiddenEpisodeCount: 0,
      seasons,
    };
  }

  const visibleRanges = ranges.slice(0, FALLBACK_VISIBLE_RANGES);
  const hiddenEpisodeCount = ranges
    .slice(FALLBACK_VISIBLE_RANGES)
    .reduce((total, range) => total + rangeEpisodeCount(range), 0);
  return {
    kind: "episodes",
    label: t("activity.tasks.moreEpisodes", { ranges: formatRanges(visibleRanges, locale), count: hiddenEpisodeCount }),
    fullLabel,
    episodeCount: sortedUnits.length,
    hiddenEpisodeCount,
    seasons,
  };
}
