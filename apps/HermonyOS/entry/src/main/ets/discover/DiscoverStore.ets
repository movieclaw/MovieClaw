import { MovieClawApi } from '../api/Endpoints';
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
 *
 * `@ObservedV2` + `@Trace`：`state` / `items` 是**原地改**的（加载中 → 已加载），
 * 靠 V2 的字段级订阅让 `DiscoverRowView` 自己重绘。
 * 老写法（V1）做不到这点，只能把状态编进 `ForEach` 的 key 里逼框架重建整行——
 * 那个补丁已经删掉了，见 docs/harmonyos-port.md §10。
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
 * 一个视角（类型 × 数据源）的发现页数据（对应 iOS `DiscoverFeed`）。
 *
 * 三态约定（与 iOS、Web 一致）：hero = null 加载中（出骨架）/ 空数组 无或失败（收起）/ 有值轮播；
 * 每行缺省 = 加载中，FAILED = 失败（收起），LOADED = 渲染。
 *
 * 所有会变的字段都是 `@Trace`：页面直接读它们，改了就自动重绘，
 * 不需要「读出来拷进 @State」这一步（V1 必须那样，见 §10）。
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
  /** 首次进入该视角才拉取；已拉过就直接恢复（对应 iOS `loaded`） */
  loaded: boolean = false;

  constructor(mediaType: string, provider: string) {
    this.mediaType = mediaType;
    this.provider = provider;
  }

  /** 版面里声明了 Hero 区（对应 iOS `declaresHero`） */
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

  /** 除 Hero 外的常规行（对应 iOS `rowSections`） */
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

  /** 常规行全部失败（且没有一行成功）→ 整页错误态（对应 iOS `allRowsFailed`） */
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

/**
 * 视角缓存（对应 iOS `DiscoverFeedStore`）：同一个「类型:数据源」只建一个 feed，
 * 切回来直接恢复，不重新拉。
 */
@ObservedV2
export class DiscoverStore {
  private static instance: DiscoverStore | null = null;

  /** 惰性单例：静态字段初始化器早于 @ObservedV2 生效，那样建的实例不会被观察 */
  static get shared(): DiscoverStore {
    if (DiscoverStore.instance === null) {
      DiscoverStore.instance = new DiscoverStore();
    }
    return DiscoverStore.instance;
  }
  private feeds: Map<string, DiscoverFeed> = new Map<string, DiscoverFeed>();

  feed(mediaType: string, provider: string): DiscoverFeed {
    const key: string = `${mediaType}:${provider}`;
    const hit: DiscoverFeed | undefined = this.feeds.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const made: DiscoverFeed = new DiscoverFeed(mediaType, provider);
    this.feeds.set(key, made);
    return made;
  }

  /** 院线地区变更：其余视角下次进入时重新拉取（对应 iOS `invalidateAll`） */
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
