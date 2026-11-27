import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { UpNextItemView } from '../api/Models';

const WIDGET_STORE_NAME: string = 'movieclaw_widget';
const KEY_PAYLOAD: string = 'payload_v1';
const KEY_FORM_IDS: string = 'form_ids_v1';

export interface WidgetSnapshot {
  hasItem: boolean;
  title: string;
  subtitle: string;
  progressPercent: number;
  remainingText: string;
  libraryId: number;
  mediaItemId: number;
  season: number;
  episode: number;
  positionMs: number;
}

function formatRemainingText(positionMs: number, durationMs: number | null | undefined): string {
  if (durationMs === null || durationMs === undefined || durationMs <= 0) {
    return '';
  }
  const remainMin: number = Math.max(1, Math.round((durationMs - positionMs) / 60000));
  if (remainMin >= 60) {
    return `剩 ${Math.floor(remainMin / 60)} 小时 ${remainMin % 60} 分`;
  }
  return `剩 ${remainMin} 分钟`;
}

/** 纯函数：从「继续观看」列表构造桌面服务卡片绑定数据（供单测与运行期共用） */
export function buildWidgetSnapshotFromUpNext(items: UpNextItemView[] | null): WidgetSnapshot {
  if (items === null || items.length === 0) {
    return {
      hasItem: false,
      title: '暂无在看影片',
      subtitle: '轻触打开媒体库开始观影',
      progressPercent: 0,
      remainingText: '',
      libraryId: 0,
      mediaItemId: 0,
      season: 0,
      episode: 0,
      positionMs: 0
    };
  }
  const first: UpNextItemView = items[0];
  const isTv: boolean = first.kind === 'tv';
  const epTitle: string = (first.episode_title ?? '').trim();
  const sub: string = isTv
    ? (epTitle.length > 0
      ? `S${first.season_number}E${first.episode_number} · ${epTitle}`
      : `第 ${first.season_number} 季 第 ${first.episode_number} 集`)
    : (first.year !== null && first.year !== undefined ? `${first.year} · 电影` : '电影');
  const pct: number = Math.max(0, Math.min(100, Math.round(first.progress_percent ?? 0)));
  return {
    hasItem: true,
    title: first.title,
    subtitle: sub,
    progressPercent: pct,
    remainingText: formatRemainingText(first.position_ms, first.duration_ms),
    libraryId: first.library_id,
    mediaItemId: first.media_item_id,
    season: isTv ? first.season_number : 0,
    episode: isTv ? first.episode_number : 0,
    positionMs: first.position_ms
  };
}

export function snapshotToFormPayload(snap: WidgetSnapshot, dimension: number = 3): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['dimension'] = dimension;
  out['hasItem'] = snap.hasItem;
  out['title'] = snap.title;
  out['subtitle'] = snap.subtitle;
  out['progressPercent'] = snap.progressPercent;
  out['remainingText'] = snap.remainingText;
  out['libraryId'] = snap.libraryId;
  out['mediaItemId'] = snap.mediaItemId;
  out['season'] = snap.season;
  out['episode'] = snap.episode;
  out['positionMs'] = snap.positionMs;
  return out;
}

/**
 * 鸿蒙桌面服务卡片（2×2 / 2×4「继续观看」万能卡片）状态同步中心：
 * 仅依赖 `@kit.ArkData` 与 `@kit.AbilityKit`，通过注入式 `formUpdater` 回调更新卡片，
 * 既支持主进程与 FormExtension 独立进程共享快照，也保证宿主机单测零未模拟 Kit 依赖。
 */
export class WidgetSync {
  static readonly shared: WidgetSync = new WidgetSync();

  private context: Context | null = null;
  private cached: WidgetSnapshot = buildWidgetSnapshotFromUpNext(null);
  private updater: ((formIds: string[], payload: Record<string, Object>) => void) | null = null;

  init(context: Context, updater?: (formIds: string[], payload: Record<string, Object>) => void): void {
    this.context = context;
    if (updater !== undefined) {
      this.updater = updater;
    }
    this.loadCached(context).catch((): void => {
    });
  }

  bindUpdater(updater: (formIds: string[], payload: Record<string, Object>) => void): void {
    this.updater = updater;
  }

  currentPayload(dimension: number = 3): Record<string, Object> {
    return snapshotToFormPayload(this.cached, dimension);
  }

  publishUpNext(items: UpNextItemView[] | null): void {
    const snap: WidgetSnapshot = buildWidgetSnapshotFromUpNext(items);
    this.cached = snap;
    if (this.context !== null) {
      this.persistAndPush(this.context, snap).catch((): void => {
      });
    }
  }

  async registerForm(formId: string, dimension: number, context: Context): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences = await this.openFreshStore(context);
      const dims: Record<string, number> = await this.readFormDimensions(store);
      if (dims[formId] !== dimension) {
        dims[formId] = dimension;
        await store.put(KEY_FORM_IDS, JSON.stringify(dims));
        await store.flush();
      }
      const raw: string = await store.get(KEY_PAYLOAD, '') as string;
      if (raw.length > 0) {
        this.cached = JSON.parse(raw) as WidgetSnapshot;
      }
      if (this.updater !== null) {
        this.updater([formId], snapshotToFormPayload(this.cached, dimension));
      }
    } catch (_err) {
    }
  }

  async refreshForm(formId: string, context: Context): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences = await this.openFreshStore(context);
      const raw: string = await store.get(KEY_PAYLOAD, '') as string;
      if (raw.length > 0) {
        this.cached = JSON.parse(raw) as WidgetSnapshot;
      }
      const dims: Record<string, number> = await this.readFormDimensions(store);
      const dim: number = dims[formId] !== undefined && dims[formId] > 0 ? dims[formId] : 3;
      if (this.updater !== null) {
        this.updater([formId], snapshotToFormPayload(this.cached, dim));
      }
    } catch (_err) {
    }
  }

  async unregisterForm(formId: string, context: Context): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences = await this.openFreshStore(context);
      const dims: Record<string, number> = await this.readFormDimensions(store);
      const next: Record<string, number> = {};
      const keys: string[] = Object.keys(dims);
      for (const id of keys) {
        if (id !== formId) {
          next[id] = dims[id];
        }
      }
      await store.put(KEY_FORM_IDS, JSON.stringify(next));
      await store.flush();
    } catch (_err) {
    }
  }

  private async openFreshStore(context: Context): Promise<preferences.Preferences> {
    try {
      await preferences.removePreferencesFromCache(context, WIDGET_STORE_NAME);
    } catch (_err) {
    }
    return preferences.getPreferences(context, WIDGET_STORE_NAME);
  }

  private async loadCached(context: Context): Promise<void> {
    try {
      const store: preferences.Preferences = await this.openFreshStore(context);
      const raw: string = await store.get(KEY_PAYLOAD, '') as string;
      if (raw.length > 0) {
        this.cached = JSON.parse(raw) as WidgetSnapshot;
      }
    } catch (_err) {
    }
  }

  private async persistAndPush(context: Context, snap: WidgetSnapshot): Promise<void> {
    try {
      const store: preferences.Preferences = await this.openFreshStore(context);
      await store.put(KEY_PAYLOAD, JSON.stringify(snap));
      await store.flush();
      const dims: Record<string, number> = await this.readFormDimensions(store);
      const ids: string[] = Object.keys(dims);
      if (ids.length > 0 && this.updater !== null) {
        for (const id of ids) {
          const dim: number = dims[id] > 0 ? dims[id] : 3;
          this.updater([id], snapshotToFormPayload(snap, dim));
        }
      }
    } catch (_err) {
    }
  }

  private async readFormDimensions(store: preferences.Preferences): Promise<Record<string, number>> {
    const raw: string = await store.get(KEY_FORM_IDS, '{}') as string;
    const out: Record<string, number> = {};
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (Array.isArray(parsed)) {
        const legacy: string[] = parsed as string[];
        for (const id of legacy) {
          if (id.length > 0) {
            out[id] = 3;
          }
        }
        return out;
      }
      const record: Record<string, Object> = parsed as Record<string, Object>;
      if (record !== null && record !== undefined) {
        const keys: string[] = Object.keys(record);
        for (const k of keys) {
          const v: number = Number(record[k]);
          out[k] = Number.isFinite(v) && v > 0 ? v : 3;
        }
      }
      return out;
    } catch (_err) {
      return out;
    }
  }
}
