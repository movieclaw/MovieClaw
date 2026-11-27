import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { MovieClawApi } from '../api/Endpoints';
import { OfflineManifestView, OfflineProfileView } from '../api/Models';
import { OfflineDownloader } from './OfflineDownloader';
import { OfflineStore } from './OfflineStore';
import { OfflineProgress, OfflineUnit, OfflineUnitState } from './OfflineModels';
import {
  SmartCachePrefs,
  WatchedEpisodeRecord,
  pickSmartOfflineProfile,
  selectEvictableWatchedFileIds,
  shouldTriggerSmartPrefetch
} from './OfflineSmartCacheModel';

const SMART_STORE_NAME: string = 'movieclaw_ui';
const KEY_PREFETCH: string = 'offline_smart_prefetch_wifi';
const KEY_EVICT: string = 'offline_smart_auto_evict';
const KEY_KEEP: string = 'offline_smart_keep_count';

/**
 * 离线追剧智能预缓管理单例（`@ObservedV2`）：
 * - 持久化用户开关（Wi-Fi 自动预缓下一集 / 看完自动删旧集 / 保留集数）；
 * - 播放进度超过 40% 且位于 Wi-Fi 时自动静默缓存本季下一集；
 * - 播完一集后自动回收超出保留上限的已看完本机剧集。
 */
@ObservedV2
export class OfflineSmartCache {
  private static instance: OfflineSmartCache | null = null;

  /** 惰性单例：避开类初始化期在 @ObservedV2 安装观察钩子前构造实例导致 @Trace 失效 */
  static get shared(): OfflineSmartCache {
    if (OfflineSmartCache.instance === null) {
      OfflineSmartCache.instance = new OfflineSmartCache();
    }
    return OfflineSmartCache.instance;
  }

  @Trace wifiPrefetchNext: boolean = false;
  @Trace autoEvictWatched: boolean = false;
  @Trace keepWatchedCount: number = 1;

  private store: preferences.Preferences | null = null;
  private ready: Promise<void> | null = null;
  private readonly prefetchedFileIds: Set<number> = new Set<number>();

  private constructor() {
  }

  init(context: Context): void {
    if (this.ready !== null) {
      return;
    }
    this.ready = preferences.getPreferences(context, SMART_STORE_NAME)
      .then((store: preferences.Preferences): void => {
        this.store = store;
        const p = store.getSync(KEY_PREFETCH, false);
        const e = store.getSync(KEY_EVICT, false);
        const k = store.getSync(KEY_KEEP, 1);
        if (typeof p === 'boolean') {
          this.wifiPrefetchNext = p;
        }
        if (typeof e === 'boolean') {
          this.autoEvictWatched = e;
        }
        if (typeof k === 'number' && Number.isFinite(k) && k >= 0 && k <= 5) {
          this.keepWatchedCount = Math.floor(k);
        }
      })
      .catch((): void => {
      });
  }

  setWifiPrefetchNext(enabled: boolean): void {
    this.wifiPrefetchNext = enabled;
    this.persist(KEY_PREFETCH, enabled);
  }

  setAutoEvictWatched(enabled: boolean): void {
    this.autoEvictWatched = enabled;
    this.persist(KEY_EVICT, enabled);
  }

  setKeepWatchedCount(count: number): void {
    const clamped: number = Math.max(0, Math.min(5, Math.floor(count)));
    this.keepWatchedCount = clamped;
    this.persist(KEY_KEEP, clamped);
  }

  prefs(): SmartCachePrefs {
    const p: SmartCachePrefs = new SmartCachePrefs();
    p.wifiPrefetchNext = this.wifiPrefetchNext;
    p.autoEvictWatched = this.autoEvictWatched;
    p.keepWatchedCount = this.keepWatchedCount;
    return p;
  }

  /** 播放途中触发：Wi-Fi 且播过 40% 时自动静默预缓本季下一集 */
  maybePrefetchNext(api: MovieClawApi | null, nextFileId: number, positionMs: number, durationMs: number): void {
    if (api === null || nextFileId <= 0 || this.prefetchedFileIds.has(nextFileId)) {
      return;
    }
    const store: OfflineStore = OfflineStore.shared;
    if (store.owner === null || !store.serverSupported) {
      return;
    }
    const existing: OfflineUnit | undefined = store.units.get(nextFileId);
    const alreadyCached: boolean = existing !== undefined && existing.state !== OfflineUnitState.failed;
    if (!shouldTriggerSmartPrefetch(this.prefs(), OfflineSmartCache.isWifiNow(), positionMs, durationMs,
      nextFileId, alreadyCached)) {
      return;
    }
    this.prefetchedFileIds.add(nextFileId);
    api.offlineManifest(nextFileId)
      .then((manifest: OfflineManifestView): void => {
        const chosen: OfflineProfileView | null = pickSmartOfflineProfile(manifest.profiles, '1080p');
        if (chosen !== null) {
          OfflineDownloader.shared.start(manifest, chosen);
        }
      })
      .catch((): void => {
        this.prefetchedFileIds.delete(nextFileId);
      });
  }

  /** 看完一集或手动触发：回收超出保留数的已看本机剧集副本 */
  maybeEvictWatched(currentPlayingFileId: number): number {
    if (!this.autoEvictWatched) {
      return 0;
    }
    const store: OfflineStore = OfflineStore.shared;
    const watched: WatchedEpisodeRecord[] = [];
    for (const unit of store.units.values()) {
      if (!unit.playable || unit.episode <= 0) {
        continue;
      }
      const prog: OfflineProgress | null = store.localProgress(unit.mediaItemId, unit.season, unit.episode);
      if (prog !== null && prog.played) {
        watched.push(new WatchedEpisodeRecord(
          unit.fileId, unit.mediaItemId, unit.episode, prog.updatedAt > 0 ? prog.updatedAt : (unit.completedAt ?? 0)));
      }
    }
    const toDelete: number[] = selectEvictableWatchedFileIds(this.prefs(), watched, currentPlayingFileId);
    for (const fileId of toDelete) {
      OfflineDownloader.shared.delete(fileId);
    }
    return toDelete.length;
  }

  private static isWifiNow(): boolean {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(handle);
      return caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI);
    } catch (_err) {
      return false;
    }
  }

  private persist(key: string, value: preferences.ValueType): void {
    const run = async (): Promise<void> => {
      if (this.ready !== null) {
        await this.ready;
      }
      if (this.store === null) {
        return;
      }
      try {
        await this.store.put(key, value);
        await this.store.flush();
      } catch (_err) {
      }
    };
    run();
  }
}
