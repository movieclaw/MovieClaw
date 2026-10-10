/**
 * 长剧集分段选集（docs/design/long-season-episode-ranges.md）：按集号每 50 集一段，
 * 一切以「接着看的那一集」（锚点）为准。纯函数，分集区与全部分集面板共用。
 */

export const EPISODE_RANGE_SIZE = 50;

/** 一段：段序号（第 floor((集号-1)/50) 段）+ 段内实际首末集号 */
export interface EpisodeRange {
  index: number;
  first: number;
  last: number;
}

/** 锚点计算只用到的分集字段 */
interface AnchorEpisode {
  episode_number: number;
  owned: boolean;
  played: boolean;
  position_ms: number;
}

export function episodeRangeIndex(episodeNumber: number): number {
  return Math.floor(Math.max(0, episodeNumber - 1) / EPISODE_RANGE_SIZE);
}

/** 段名用段内实际首末集号：`1–50`、`1151–1186`（en dash） */
export function episodeRangeLabel(range: EpisodeRange): string {
  return `${range.first}–${range.last}`;
}

/** 一季的段：超过 50 集才分段，否则为空（界面保持改版前的样子）；空段不出现 */
export function episodeRanges(episodeNumbers: number[]): EpisodeRange[] {
  if (episodeNumbers.length <= EPISODE_RANGE_SIZE) return [];
  const result: EpisodeRange[] = [];
  for (const number of [...episodeNumbers].sort((a, b) => a - b)) {
    const index = episodeRangeIndex(number);
    const last = result[result.length - 1];
    if (last && last.index === index) last.last = number;
    else result.push({ index, first: number, last: number });
  }
  return result;
}

/** 某集所在的段 */
export function rangeContaining(
  ranges: EpisodeRange[],
  episodeNumber: number,
): EpisodeRange | undefined {
  const index = episodeRangeIndex(episodeNumber);
  return ranges.find((range) => range.index === index);
}

/** 进某一段时落在哪一集：段里有锚点就是锚点，否则段首 */
export function rangeEntry(range: EpisodeRange, anchor: number | null): number {
  return anchor != null && episodeRangeIndex(anchor) === range.index ? anchor : range.first;
}

/**
 * 本季接着看的那一集：服务端给的 resume_episode 优先（与首页「接下来继续」同规则）；
 * 本季没播放过（或分享页这类不给锚点的接口）退回客户端规则：
 * 第一个看了一半的 → 第一个没看过的 → 第一集，有片源的优先。
 * 不拿客户端扫描结果覆盖服务端锚点——长剧里「第一个没看过的」可能是几百集前跳过的那一集。
 */
export function seasonAnchor(data: {
  episodes: AnchorEpisode[];
  resume_episode?: number | null;
}): number | null {
  const { episodes, resume_episode: resume } = data;
  if (resume != null && episodes.some((e) => e.episode_number === resume)) return resume;
  const owned = episodes.filter((e) => e.owned);
  const hit =
    owned.find((e) => e.position_ms > 0) ??
    owned.find((e) => !e.played) ??
    owned[0] ??
    episodes[0];
  return hit?.episode_number ?? null;
}
