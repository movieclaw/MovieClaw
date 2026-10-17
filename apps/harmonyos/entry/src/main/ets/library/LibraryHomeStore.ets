import { MovieClawApi } from '../api/Endpoints';
import {
  CollectionView,
  FavoritesView,
  HomeRowPref,
  LibraryItemView,
  LibraryView,
  UpNextItemView
} from '../api/Models';
import {
  CollectionRowKind,
  FavoritesKind,
  HomeRow,
  HomeRows,
  LibrariesKind,
  LibraryRowKind,
  UpNextKind
} from './HomeRows';

/**
 * 首页行清单偏好的进程内共享副本（对应 iOS 端 LibraryHomePrefs）。
 *
 * Web 把全站界面偏好放在一个 React Context 里；App 里只有媒体库首页（及后续的自定义页、
 * 合集页）用到 home.rows，放一个模块级单例即可。单例跨账号存活，所以副本记着属于谁
 * （服务器地址 + 用户名）：切换账号后第一次使用就作废旧副本重新拉。
 */
export class LibraryHomePrefs {
  static readonly shared: LibraryHomePrefs = new LibraryHomePrefs();
  /** null = 还没从服务器拉到 */
  rows: HomeRowPref[] | null = null;
  /** 副本所属账号（ownerKey） */
  private owner: string | null = null;

  static ownerKey(origin: string, username: string | null): string {
    return `${origin}|${username ?? ''}`;
  }

  /** 以这个账号的身份使用副本：换了账号就清空旧账号的行清单 */
  adopt(key: string): void {
    if (key === this.owner) {
      return;
    }
    this.owner = key;
    this.rows = null;
  }

  /** 接收一次拉取结果：拉取期间换了账号（或已有更新的副本）就丢弃 */
  accept(fetched: HomeRowPref[] | null, key: string): void {
    if (key !== this.owner || this.rows !== null) {
      return;
    }
    this.rows = fetched;
  }

  /** 确保副本属于这个账号且已拉到（失败保持 null，下一轮轮询再拉） */
  async ensureLoaded(api: MovieClawApi, key: string): Promise<void> {
    this.adopt(key);
    if (this.rows !== null) {
      return;
    }
    let fetched: HomeRowPref[] | null = null;
    try {
      const prefs = await api.uiPrefsShow();
      fetched = prefs.home.rows;
    } catch (error) {
      // 失败保持 null：写成 [] 会让「显示在首页」以空清单为底整份保存，覆盖用户自定义的行
    }
    this.accept(fetched, key);
  }
}

/** 收藏行的查询参数（行清单一定就能定，与库、合集无关） */
class FavoritesQuery {
  readonly unwatchedFirst: boolean;
  readonly sort: string;
  readonly order: string | null;

  constructor(unwatchedFirst: boolean, sort: string, order: string | null) {
    this.unwatchedFirst = unwatchedFirst;
    this.sort = sort;
    this.order = order;
  }

  equals(other: FavoritesQuery | null): boolean {
    if (other === null) {
      return false;
    }
    return this.unwatchedFirst === other.unwatchedFirst
      && this.sort === other.sort && this.order === other.order;
  }
}

/** 行清单里「接下来继续」「收藏」两行怎么取 */
class HomePlan {
  readonly upNext: boolean;
  readonly favorites: FavoritesQuery | null;

  constructor(upNext: boolean, favorites: FavoritesQuery | null) {
    this.upNext = upNext;
    this.favorites = favorites;
  }
}

/**
 * 媒体库首页的整页数据（对应 iOS 端 LibraryHomeStore，取数口径同 Web library-view.tsx）。
 *
 * 数据放在跟着账号走的共享对象里，页面只负责渲染：
 * - 刷新：库、接下来继续、收藏、各行条目按依赖并发取；
 * - 库状态、要取的行、合集都没变时不重拉各行条目（空闲时每 30 秒不必打 1+N 个请求）；
 * - 瞬时失败不清已有数据，只置 failed 让页面挂提示条；一次都没成功过才整页报错；
 * - 有库在扫描 / 整理时 busyUntil 往后 12 秒，页面据此保持 3 秒快轮询（同 Web recentlyBusy）。
 * 鸿蒙版暂不做磁盘快照（秒开由会话快照 + 首帧 loading 承接），结构留好了后续加。
 */
export class LibraryHomeStore {
  static readonly shared: LibraryHomeStore = new LibraryHomeStore();
  /** 每行取的条数（同 Web） */
  static readonly rowCount: number = 20;

  libraries: LibraryView[] | null = null;
  collections: CollectionView[] = [];
  upNext: UpNextItemView[] | null = null;
  favorites: FavoritesView | null = null;
  itemsByKey: Map<string, LibraryItemView[]> = new Map<string, LibraryItemView[]>();
  /** 各行条目至少到过一次 */
  rowsLoaded: boolean = false;
  /** 最近一次刷新失败（页面据此挂提示条 / 整页报错） */
  failed: boolean = false;
  /** 扫描 / 整理结束后的 12 秒快轮询窗口，epoch 毫秒 */
  busyUntil: number = 0;

  private owner: string | null = null;
  /** 各行条目上次拉取时的输入指纹（库状态、要取的行、合集），没变就不重拉 */
  private rowsFingerprint: string | null = null;
  private refreshedAt: number | null = null;
  private inFlight: Promise<void> | null = null;

  /** 以这个账号的身份使用：换了账号就清空旧账号的数据 */
  adopt(key: string): void {
    if (key === this.owner) {
      return;
    }
    this.owner = key;
    this.libraries = null;
    this.collections = [];
    this.upNext = null;
    this.favorites = null;
    this.itemsByKey = new Map<string, LibraryItemView[]>();
    this.rowsLoaded = false;
    this.failed = false;
    this.busyUntil = 0;
    this.rowsFingerprint = null;
    this.refreshedAt = null;
    this.inFlight = null;
  }

  /** 刷新整页；并发调用合并为同一次 */
  async reload(api: MovieClawApi, key: string): Promise<void> {
    this.adopt(key);
    if (this.inFlight !== null) {
      await this.inFlight;
      return;
    }
    const task: Promise<void> = this.load(api, key);
    this.inFlight = task;
    try {
      await task;
    } finally {
      this.inFlight = null;
    }
  }

  private async load(api: MovieClawApi, key: string): Promise<void> {
    const prefs: LibraryHomePrefs = LibraryHomePrefs.shared;
    try {
      // 偏好：拉到为止。行清单决定要取哪些数据，只有全新安装第一次打开才先等它
      if (prefs.rows === null) {
        await prefs.ensureLoaded(api, key);
      }
      const planned: HomePlan = LibraryHomeStore.plan(prefs.rows ?? []);
      // 接下来继续、收藏两行只看行清单，和偏好、库、合集同时发请求
      const libsTask: Promise<LibraryView[]> = api.libraryList(undefined, 'all');
      const colsTask: Promise<CollectionView[]> =
        api.collectionList().catch((): CollectionView[] => this.collections);
      const upNextTask: Promise<UpNextItemView[] | null> =
        LibraryHomeStore.fetchUpNext(api, planned.upNext);
      const favoritesTask: Promise<FavoritesView | null> =
        LibraryHomeStore.fetchFavorites(api, planned.favorites);
      const libs: LibraryView[] = await libsTask;
      const cols: CollectionView[] = await colsTask;
      if (this.owner !== key) {
        return;
      }
      this.failed = false;
      this.libraries = libs;
      this.collections = cols;
      let busy: boolean = false;
      for (const library of libs) {
        if (library.scanning || library.organizing) {
          busy = true;
          break;
        }
      }
      if (busy) {
        this.busyUntil = Date.now() + 12000;
      }

      // 各行条目：库状态、要取的行、合集都没变时跳过
      const rowPrefs: HomeRowPref[] = prefs.rows ?? [];
      const visibleRows: HomeRow[] = HomeRows.build(rowPrefs, libs, cols)
        .filter((row: HomeRow): boolean => !row.hidden);
      const fetches: Map<string, () => Promise<LibraryItemView[]>> =
        LibraryHomeStore.rowFetches(visibleRows, libs, api);
      const fingerprint: string = LibraryHomeStore.fingerprint(libs, fetches, cols);
      if (fingerprint !== this.rowsFingerprint) {
        const next: Map<string, LibraryItemView[]> = await LibraryHomeStore.fetchRows(fetches);
        if (this.owner !== key) {
          return;
        }
        this.rowsFingerprint = fingerprint;
        this.itemsByKey = next;
        this.rowsLoaded = true;
      }

      // 刷新到的偏好若改了这两行的取法（极少见：别处刚改过自定义首页），按新的再取一次
      let latestUpNext: UpNextItemView[] | null = await upNextTask;
      let latestFavorites: FavoritesView | null = await favoritesTask;
      const actual: HomePlan = LibraryHomeStore.plan(rowPrefs);
      if (actual.upNext !== planned.upNext) {
        latestUpNext = await LibraryHomeStore.fetchUpNext(api, actual.upNext);
      }
      if (!LibraryHomeStore.favoritesEqual(actual.favorites, planned.favorites)) {
        latestFavorites = await LibraryHomeStore.fetchFavorites(api, actual.favorites);
      }
      if (this.owner !== key) {
        return;
      }
      if (latestUpNext !== null) {
        this.upNext = latestUpNext;
      } else if (this.upNext === null) {
        this.upNext = [];
      }
      if (latestFavorites !== null) {
        this.favorites = latestFavorites;
      } else if (this.favorites === null) {
        this.favorites = { items: [], total: 0 };
      }
      this.refreshedAt = Date.now();
    } catch (error) {
      if (this.owner === key) {
        this.failed = true;
      }
    }
  }

  /** 一行取数的缓存键：同一个库同一种排序同一方向（同一个未看开关）只请求一次 */
  static fetchKey(row: HomeRow): string {
    if (row.kind instanceof LibraryRowKind) {
      const kind = row.kind;
      return `lib:${kind.library.id}:${kind.sort}:${kind.reversed}:${kind.unwatched}`;
    }
    if (row.kind instanceof CollectionRowKind) {
      const kind = row.kind;
      return `col:${kind.collection.id}:${kind.sort}:${kind.reversed}`;
    }
    return row.id;
  }

  /** 库卡片封面用的那批条目，与默认的「最近添加」行共用一份 */
  static coverKey(libraryId: number): string {
    return `lib:${libraryId}:added_at:false:false`;
  }

  private static plan(rowPrefs: HomeRowPref[]): HomePlan {
    const rows: HomeRow[] = HomeRows.build(rowPrefs, [], [])
      .filter((row: HomeRow): boolean => !row.hidden);
    let favorites: FavoritesQuery | null = null;
    for (const row of rows) {
      if (row.kind instanceof FavoritesKind) {
        const kind = row.kind;
        // 「未看优先」是首页这一行的默认（全量页不传，保持收藏时间序）
        favorites = new FavoritesQuery(
          kind.sort === 'unwatched_first',
          kind.sort === 'unwatched_first' ? 'favorited_at' : kind.sort,
          HomeRows.favoritesPreset(kind.sort).direction?.orderParam(kind.reversed) ?? null);
        break;
      }
    }
    let upNext: boolean = false;
    for (const row of rows) {
      if (row.kind instanceof UpNextKind) {
        upNext = true;
        break;
      }
    }
    return new HomePlan(upNext, favorites);
  }

  private static favoritesEqual(a: FavoritesQuery | null, b: FavoritesQuery | null): boolean {
    if (a === null && b === null) {
      return true;
    }
    if (a === null || b === null) {
      return false;
    }
    return a.equals(b);
  }

  private static async fetchUpNext(api: MovieClawApi, wanted: boolean): Promise<UpNextItemView[] | null> {
    if (!wanted) {
      return null;
    }
    try {
      const view = await api.playbackUpNext(LibraryHomeStore.rowCount);
      return view.items;
    } catch (error) {
      return null;
    }
  }

  private static async fetchFavorites(api: MovieClawApi, query: FavoritesQuery | null): Promise<FavoritesView | null> {
    if (query === null) {
      return null;
    }
    try {
      return await api.playbackFavorites(LibraryHomeStore.rowCount, 0, query.unwatchedFirst,
        query.sort, query.order ?? undefined);
    } catch (error) {
      return null;
    }
  }

  /** 各行条目并发取回；单行失败按空行处理（同 Web） */
  private static async fetchRows(fetches: Map<string, () => Promise<LibraryItemView[]>>):
  Promise<Map<string, LibraryItemView[]>> {
    const next: Map<string, LibraryItemView[]> = new Map<string, LibraryItemView[]>();
    const keys: string[] = Array.from(fetches.keys());
    const tasks: Promise<void>[] = [];
    for (const key of keys) {
      const fetch: (() => Promise<LibraryItemView[]>) | undefined = fetches.get(key);
      if (fetch === undefined) {
        continue;
      }
      tasks.push(fetch()
        .then((items: LibraryItemView[]): void => {
          next.set(key, items);
        })
        .catch((): void => {
          next.set(key, []);
        }));
    }
    await Promise.all(tasks);
    return next;
  }

  /** 显示中的行各自要打的请求，按缓存键去重；排序与截断交给服务端 */
  private static rowFetches(rows: HomeRow[], libs: LibraryView[], api: MovieClawApi):
  Map<string, () => Promise<LibraryItemView[]>> {
    const fetches: Map<string, () => Promise<LibraryItemView[]>> =
      new Map<string, () => Promise<LibraryItemView[]>>();
    const limit: number = LibraryHomeStore.rowCount;
    for (const row of rows) {
      if (row.kind instanceof LibraryRowKind) {
        const kind = row.kind;
        // 「最近观看」行只要播过的（w=seen）
        const watch: string | undefined =
          kind.sort === 'last_played' ? 'seen' : (kind.unwatched ? 'unwatched' : undefined);
        const order: string | undefined =
          HomeRows.preset(kind.sort).direction?.orderParam(kind.reversed) ?? undefined;
        const id: number = kind.library.id;
        const sort: string = kind.sort;
        fetches.set(LibraryHomeStore.fetchKey(row), (): Promise<LibraryItemView[]> =>
          api.libraryItemsList(id, sort, order, limit, undefined, undefined, undefined,
            undefined, undefined, watch));
      } else if (row.kind instanceof CollectionRowKind) {
        const kind = row.kind;
        const order: string | undefined =
          HomeRows.preset(kind.sort).direction?.orderParam(kind.reversed) ?? undefined;
        const id: number = kind.collection.id;
        const sort: string = kind.sort;
        fetches.set(LibraryHomeStore.fetchKey(row), (): Promise<LibraryItemView[]> =>
          api.collectionItemsList(id, limit, undefined, sort, order));
      } else if (row.kind instanceof LibrariesKind) {
        // 库卡片封面与默认的「最近添加」行共用一份条目
        for (const library of libs) {
          if (!library.viewer_access) {
            continue;
          }
          const key: string = LibraryHomeStore.coverKey(library.id);
          if (!fetches.has(key)) {
            const id: number = library.id;
            fetches.set(key, (): Promise<LibraryItemView[]> =>
              api.libraryItemsList(id, 'added_at', undefined, limit));
          }
        }
      }
    }
    return fetches;
  }

  /** 指纹：库状态、要取的行、合集，任一变化才重拉各行条目 */
  private static fingerprint(libs: LibraryView[], fetches: Map<string, () => Promise<LibraryItemView[]>>,
    cols: CollectionView[]): string {
    const keys: string[] = Array.from(fetches.keys()).sort();
    return `${JSON.stringify(libs)}#${keys.join(',')}#${JSON.stringify(cols)}`;
  }
}
