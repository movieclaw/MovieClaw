import { Context } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  DiscoveredTitleView,
  DiscoveryPageSectionView,
  DiscoveryPageView
} from '../api/Models';

/**
 * 一行的状态（对应 iOS `DiscoverFeed.RowState`）：
 * 缺省 = 加载中（出骨架），FAILED = 失败（整行收起），LOADED = 渲染。
 */
export class DiscoverRowState {
  static readonly loading: number = 0;
  static readonly loaded: number = 1;
  static readonly failed: number = 2;
}

/**
 * 发现页的一行（对应 iOS `rows[ref]`）。
 */
@ObservedV2
export class DiscoverRow {
  readonly ref: string;
  readonly title: string;
  readonly supportsFullListing: boolean;
  @Trace state: number = DiscoverRowState.loading;
  @Trace items: DiscoveredTitleView[] = [];

  constructor(ref: string, title: string, supportsFullListing: boolean) {
    this.ref = ref;
    this.title = title;
    this.supportsFullListing = supportsFullListing;
  }
}

/** 整页失败（对应 iOS `DiscoverFeed.Failure`） */
@ObservedV2
export class DiscoverFailure {
  @Trace message: string;
  @Trace hint: string;

  constructor(message: string, hint: string = '') {
    this.message = message;
    this.hint = hint;
  }
}

/**
 * 一个视角（类型 × 数据源）的发现页数据（对应 iOS `DiscoverFeed` + 磁盘快照秒开）。
 */
@ObservedV2
export class DiscoverFeed {
  readonly mediaType: string;
  readonly provider: string;
  @Trace layout: DiscoveryPageView | null = null;
  /** null = 加载中；[] = 无 Hero 或失败；有值 = 轮播 */
  @Trace hero: DiscoveredTitleView[] | null = null;
  @Trace rows: DiscoverRow[] = [];
  @Trace failure: DiscoverFailure | null = null;
  /** 本进程内已从网络成功拉取过（磁盘快照恢复时保持 false，实现首帧秒开 + 静默重验） */
  loaded: boolean = false;

  constructor(mediaType: string, provider: string) {
    this.mediaType = mediaType;
    this.provider = provider;
  }

  declaresHero(): boolean {
    const page: DiscoveryPageView | null = this.layout;
    if (page === null) {
      return false;
    }
    for (const section of page.sections) {
      if (section.presentation === 'hero') {
        return true;
      }
    }
    return false;
  }

  rowSections(): DiscoveryPageSectionView[] {
    const page: DiscoveryPageView | null = this.layout;
    if (page === null) {
      return [];
    }
    const out: DiscoveryPageSectionView[] = [];
    for (const section of page.sections) {
      if (section.presentation !== 'hero') {
        out.push(section);
      }
    }
    return out;
  }

  allRowsFailed(): boolean {
    if (this.rows.length === 0) {
      return false;
    }
    for (const row of this.rows) {
      if (row.state !== DiscoverRowState.failed) {
        return false;
      }
    }
    return true;
  }

  findRow(ref: string): DiscoverRow | null {
    for (const row of this.rows) {
      if (row.ref === ref) {
        return row;
      }
    }
    return null;
  }
}

interface DiscoverRowSnapshot {
  ref: string;
  title: string;
  supportsFullListing: boolean;
  items: DiscoveredTitleView[];
}

interface DiscoverFeedSnapshot {
  key: string;
  mediaType: string;
  provider: string;
  layout: DiscoveryPageView;
  hero: DiscoveredTitleView[];
  rows: DiscoverRowSnapshot[];
}

interface DiscoverDiskSnapshot {
  origin: string;
  savedAt: number;
  feeds: DiscoverFeedSnapshot[];
}

/**
 * 视角缓存 + 沙箱磁盘快照（对应 iOS `DiscoverFeedStore` + `DiscoverSnapshots`）：
 * - 冷启动通过 `init(context)` 指定快照落盘路径；
 * - 首次读 `feed()` 时同步从磁盘恢复上一次的 Hero 与各行片单，首帧零白屏骨架；
 * - 随后 `DiscoverPage.load()` 后台静默重验并落盘最新快照。
 */
@ObservedV2
export class DiscoverStore {
  private static instance: DiscoverStore | null = null;

  static get shared(): DiscoverStore {
    if (DiscoverStore.instance === null) {
      DiscoverStore.instance = new DiscoverStore();
    }
    return DiscoverStore.instance;
  }

  private feeds: Map<string, DiscoverFeed> = new Map<string, DiscoverFeed>();
  private cachePath: string | null = null;
  private restoredOrigin: string | null = null;

  init(context: Context): void {
    this.cachePath = context.cacheDir + '/discover-cache.json';
  }

  /** 按当前服务器 origin 尝试恢复磁盘快照（幂等） */
  ensureRestored(origin: string): void {
    if (origin.length === 0 || this.restoredOrigin === origin || this.cachePath === null) {
      return;
    }
    this.restoredOrigin = origin;
    try {
      const file: fileIo.File = fileIo.openSync(this.cachePath, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          return;
        }
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
        text = decoder.decodeToString(new Uint8Array(buf));
      } finally {
        fileIo.closeSync(file);
      }
      const parsed: DiscoverDiskSnapshot = JSON.parse(text) as DiscoverDiskSnapshot;
      if (parsed.origin !== origin || !Array.isArray(parsed.feeds)) {
        return;
      }
      for (const snap of parsed.feeds) {
        const existing: DiscoverFeed | undefined = this.feeds.get(snap.key);
        const target: DiscoverFeed = existing !== undefined
          ? existing
          : new DiscoverFeed(snap.mediaType, snap.provider);
        if (!target.loaded && target.layout === null) {
          target.layout = snap.layout;
          target.hero = snap.hero;
          const restoredRows: DiscoverRow[] = [];
          for (const r of snap.rows) {
            const row: DiscoverRow = new DiscoverRow(r.ref, r.title, r.supportsFullListing);
            row.items = r.items;
            row.state = DiscoverRowState.loaded;
            restoredRows.push(row);
          }
          target.rows = restoredRows;
        }
        this.feeds.set(snap.key, target);
      }
    } catch (_err) {
    }
  }

  /** 将已成功加载的视角落盘 */
  saveSnapshot(origin: string): void {
    if (this.cachePath === null || origin.length === 0) {
      return;
    }
    try {
      const list: DiscoverFeedSnapshot[] = [];
      this.feeds.forEach((feed: DiscoverFeed, key: string): void => {
        if (feed.layout === null) {
          return;
        }
        const rows: DiscoverRowSnapshot[] = [];
        for (const r of feed.rows) {
          if (r.state === DiscoverRowState.loaded) {
            const rowSnap: DiscoverRowSnapshot = {
              ref: r.ref,
              title: r.title,
              supportsFullListing: r.supportsFullListing,
              items: r.items
            };
            rows.push(rowSnap);
          }
        }
        const feedSnap: DiscoverFeedSnapshot = {
          key: key,
          mediaType: feed.mediaType,
          provider: feed.provider,
          layout: feed.layout,
          hero: feed.hero ?? [],
          rows: rows
        };
        list.push(feedSnap);
      });
      if (list.length === 0) {
        return;
      }
      const disk: DiscoverDiskSnapshot = {
        origin: origin,
        savedAt: Date.now(),
        feeds: list
      };
      const file: fileIo.File = fileIo.openSync(
        this.cachePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, JSON.stringify(disk));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_err) {
    }
  }

  feed(mediaType: string, provider: string, origin: string = ''): DiscoverFeed {
    if (origin.length > 0) {
      this.ensureRestored(origin);
    }
    const key: string = `${mediaType}:${provider}`;
    const hit: DiscoverFeed | undefined = this.feeds.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const made: DiscoverFeed = new DiscoverFeed(mediaType, provider);
    this.feeds.set(key, made);
    return made;
  }

  invalidateAll(): void {
    this.feeds.forEach((feed: DiscoverFeed): void => {
      feed.loaded = false;
    });
  }
}

/** 版面声明的第一个 Hero 区 ref；没有则返回空串（对应 iOS `heroRef`） */
export function heroRefOf(page: DiscoveryPageView): string {
  for (const section of page.sections) {
    if (section.presentation === 'hero') {
      return section.collection_ref;
    }
  }
  return '';
}
