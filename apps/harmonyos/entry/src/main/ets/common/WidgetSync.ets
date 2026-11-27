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
      const store: preferences.Preferences = await preferences.getPreferences(context, WIDGET_STORE_NAME);
      const ids: string[] = await this.readFormIds(store);
      if (!ids.includes(formId)) {
        ids.push(formId);
        await store.put(KEY_FORM_IDS, JSON.stringify(ids));
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
      const store: preferences.Preferences = await preferences.getPreferences(context, WIDGET_STORE_NAME);
      const raw: string = await store.get(KEY_PAYLOAD, '') as string;
      if (raw.length > 0) {
        this.cached = JSON.parse(raw) as WidgetSnapshot;
      }
      if (this.updater !== null) {
        this.updater([formId], snapshotToFormPayload(this.cached, 3));
      }
    } catch (_err) {
    }
  }

  async unregisterForm(formId: string, context: Context): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, WIDGET_STORE_NAME);
      const ids: string[] = (await this.readFormIds(store)).filter((id: string): boolean => id !== formId);
      await store.put(KEY_FORM_IDS, JSON.stringify(ids));
      await store.flush();
    } catch (_err) {
    }
  }

  private async loadCached(context: Context): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, WIDGET_STORE_NAME);
      const raw: string = await store.get(KEY_PAYLOAD, '') as string;
      if (raw.length > 0) {
        this.cached = JSON.parse(raw) as WidgetSnapshot;
      }
    } catch (_err) {
    }
  }

  private async persistAndPush(context: Context, snap: WidgetSnapshot): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, WIDGET_STORE_NAME);
      await store.put(KEY_PAYLOAD, JSON.stringify(snap));
      await store.flush();
      const ids: string[] = await this.readFormIds(store);
      if (ids.length > 0 && this.updater !== null) {
        this.updater(ids, snapshotToFormPayload(snap, 3));
      }
    } catch (_err) {
    }
  }

  private async readFormIds(store: preferences.Preferences): Promise<string[]> {
    const raw: string = await store.get(KEY_FORM_IDS, '[]') as string;
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (_err) {
      return [];
    }
  }
}
