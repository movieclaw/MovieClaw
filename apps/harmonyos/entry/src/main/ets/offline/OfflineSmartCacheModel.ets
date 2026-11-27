import { OfflineProfileView } from '../api/Models';

/**
 * 离线追剧智能预缓与自动清理策略（纯逻辑，零 Kit 依赖，可直接进主机单测）：
 * - Wi-Fi 下追剧播过 40% 自动静默预缓下一集，通勤/飞行零等待；
 * - 看完的已下载剧集可按「保留最近 N 集」自动回收旧集空间。
 */
export class SmartCachePrefs {
  wifiPrefetchNext: boolean = false;
  autoEvictWatched: boolean = false;
  keepWatchedCount: number = 1;
  preferredProfile: string = '1080p';
}

export class WatchedEpisodeRecord {
  readonly fileId: number;
  readonly mediaItemId: number;
  readonly episode: number;
  readonly watchedAtMs: number;

  constructor(fileId: number, mediaItemId: number, episode: number, watchedAtMs: number) {
    this.fileId = fileId;
    this.mediaItemId = mediaItemId;
    this.episode = episode;
    this.watchedAtMs = watchedAtMs;
  }
}

/** 是否触发 Wi-Fi 自动预缓下一集 */
export function shouldTriggerSmartPrefetch(
  prefs: SmartCachePrefs,
  isWifi: boolean,
  positionMs: number,
  durationMs: number,
  nextFileId: number,
  alreadyCached: boolean
): boolean {
  if (!prefs.wifiPrefetchNext || !isWifi || nextFileId <= 0 || alreadyCached) {
    return false;
  }
  if (durationMs < 60000 || positionMs <= 0) {
    return false;
  }
  return (positionMs / durationMs) >= 0.4;
}

/** 从离线清单的可用画质档中挑选最匹配的目标档位 */
export function pickSmartOfflineProfile(
  profiles: OfflineProfileView[] | null | undefined,
  preferred: string
): OfflineProfileView | null {
  if (profiles === null || profiles === undefined || profiles.length === 0) {
    return null;
  }
  for (const p of profiles) {
    if (p.profile === preferred) {
      return p;
    }
  }
  for (const fallback of ['1080p', '720p', 'original']) {
    for (const p of profiles) {
      if (p.profile === fallback) {
        return p;
      }
    }
  }
  return profiles[0];
}

/** 选出需要自动清理的已看剧集 fileId（按最新观看降序保留前 keepWatchedCount 集，永不删当前正在播放的文件） */
export function selectEvictableWatchedFileIds(
  prefs: SmartCachePrefs,
  records: WatchedEpisodeRecord[],
  currentPlayingFileId: number
): number[] {
  if (!prefs.autoEvictWatched || records.length === 0) {
    return [];
  }
  const keep: number = Math.max(0, prefs.keepWatchedCount);
  const candidates: WatchedEpisodeRecord[] = [];
  for (const r of records) {
    if (r.episode > 0 && r.fileId > 0 && r.fileId !== currentPlayingFileId) {
      candidates.push(r);
    }
  }
  if (candidates.length <= keep) {
    return [];
  }
  candidates.sort((a: WatchedEpisodeRecord, b: WatchedEpisodeRecord): number => {
    if (b.watchedAtMs !== a.watchedAtMs) {
      return b.watchedAtMs - a.watchedAtMs;
    }
    return b.episode - a.episode;
  });
  const evict: number[] = [];
  for (let i: number = keep; i < candidates.length; i++) {
    evict.push(candidates[i].fileId);
  }
  return evict;
}
