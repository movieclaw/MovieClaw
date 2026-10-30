import { EpisodeView, SeasonEpisodesView } from '../api/Models';

/**
 * 长剧集分段选集（对齐 iOS `EpisodeRanges` + docs/design/long-season-episode-ranges.md）：
 * 按集号每 50 集一段，段名用段内实际首末集号；超过 50 集才分段，否则不分（界面保持原样）。
 */

/** 长剧集分段选集的一段 */
export class EpisodeRange {
  readonly index: number;
  readonly first: number;
  readonly last: number;

  constructor(index: number, first: number, last: number) {
    this.index = index;
    this.first = first;
    this.last = last;
  }

  /** 段名：「首–末」（如 1–50） */
  label(): string {
    return `${this.first}–${this.last}`;
  }

  contains(episodeNumber: number): boolean {
    return EpisodeRanges.indexOf(episodeNumber) === this.index;
  }
}

export class EpisodeRanges {
  static readonly size: number = 50;

  static indexOf(episodeNumber: number): number {
    return Math.floor(Math.max(0, episodeNumber - 1) / EpisodeRanges.size);
  }

  /** 一季的段：不超过 50 集返回空（不分段）；空段不出现 */
  static ranges(episodes: EpisodeView[]): EpisodeRange[] {
    if (episodes.length <= EpisodeRanges.size) {
      return [];
    }
    const numbers: number[] = [];
    for (const episode of episodes) {
      numbers.push(episode.episode_number);
    }
    numbers.sort((a: number, b: number): number => a - b);
    const result: EpisodeRange[] = [];
    for (const number of numbers) {
      const index: number = EpisodeRanges.indexOf(number);
      const last: EpisodeRange | undefined = result.length > 0 ? result[result.length - 1] : undefined;
      if (last !== undefined && last.index === index) {
        result[result.length - 1] = new EpisodeRange(index, last.first, number);
      } else {
        result.push(new EpisodeRange(index, number, number));
      }
    }
    return result;
  }

  /** 某集所在的段 */
  static rangeContaining(episodeNumber: number, ranges: EpisodeRange[]): EpisodeRange | null {
    for (const range of ranges) {
      if (range.contains(episodeNumber)) {
        return range;
      }
    }
    return null;
  }

  /** 进某一段时落在哪一集：段里有锚点就是锚点，否则段首 */
  static entry(range: EpisodeRange, anchor: number | null): number {
    if (anchor !== null && range.contains(anchor)) {
      return anchor;
    }
    return range.first;
  }
}

/**
 * 一季里「接着看的那一集」的客户端规则（对齐 iOS `LibraryShared.resumeEpisode`）：
 * 看了一半的（含看完后重看到一半的）→ 第一集没看过的 → 第一集（有片源的优先）。
 */
export function clientResumeEpisode(episodes: EpisodeView[]): EpisodeView | null {
  if (episodes.length === 0) {
    return null;
  }
  const owned: EpisodeView[] = [];
  for (const episode of episodes) {
    if (episode.owned) {
      owned.push(episode);
    }
  }
  if (owned.length === 0) {
    return episodes[0];
  }
  for (const episode of owned) {
    if (episode.position_ms > 0) {
      return episode;
    }
  }
  for (const episode of owned) {
    if (!episode.played) {
      return episode;
    }
  }
  return owned[0];
}

/**
 * 本季接着看的那一集（对齐 iOS `SeasonEpisodesView.anchorEpisode`）：
 * 服务端给的锚点（`resume_episode`）优先；本季没播放过、或旧服务端没给时退回客户端规则。
 */
export function anchorEpisode(view: SeasonEpisodesView): EpisodeView | null {
  const serverNumber: number | null = view.resume_episode ?? null;
  if (serverNumber !== null) {
    for (const episode of view.episodes) {
      if (episode.episode_number === serverNumber) {
        return episode;
      }
    }
  }
  return clientResumeEpisode(view.episodes);
}

/** 本季有没有观看记录（任一集看过或看了一半）——「接着看」标签只在有记录时标 */
export function watchedAnyEpisode(view: SeasonEpisodesView): boolean {
  for (const episode of view.episodes) {
    if (episode.played || episode.position_ms > 0) {
      return true;
    }
  }
  return false;
}

/**
 * 分集列表 ForEach 的 key：季 + 集号 + 影响行渲染的状态。
 * 只拿集号当 key 时，换季（两季的 E1..EN 撞号）或同季刷新（入库/已看/进度变了）
 * 都会被 ForEach 判成「同一项」而跳过重建，行上冻着上一份旧数据——
 * 「日历卡已入库 6、分集却行行未入库」就是这么来的。
 */
export function episodeRowKey(season: number, episode: EpisodeView): string {
  return `${season}-${episode.episode_number}-${episode.owned ? 'o' : 'x'}-${episode.played ? 'p' : 'x'}`
    + `-${Math.round(episode.progress_percent ?? 0)}-${episode.position_ms}`
    + `-${episode.name ?? ''}-${episode.air_date ?? ''}-${episode.still_url ?? ''}`;
}
