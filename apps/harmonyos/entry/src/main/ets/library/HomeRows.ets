import { CollectionView, HomeRowPref, HomeRowPrefInput, LibraryView } from '../api/Models';

/**
 * 媒体库首页的「行清单」：合并规则与排序预设。逐行移植自 iOS 端
 * Features/Library/LibraryHomeRows.swift（口径即 Web lib/home-rows.ts）。
 *
 * 约定：存下来的是提示，不是契约——
 * - 存过的行按存的顺序在前；
 * - 没存过的内置行、每个可见库的默认行按出厂顺序补在后面（新版本加的内置行、新建的库一定看得到）；
 * - 指向已删库 / 不可见合集的行直接忽略；
 * - 空清单 = 出厂布局。
 *
 * 与 Web 共用同一份偏好，两端合并逻辑必须一致，否则同一账号两端看到的首页不同。
 */

/** 一档排序的方向档案（Web SortDirection）：自然方向与两个方向的人话 */
export class WallSortDirection {
  readonly naturalAsc: boolean;
  readonly asc: string;
  readonly desc: string;

  constructor(naturalAsc: boolean, asc: string, desc: string) {
    this.naturalAsc = naturalAsc;
    this.asc = asc;
    this.desc = desc;
  }

  /** 反转了自然方向才带 order（与 Web orderParam 同一条规矩） */
  orderParam(reversed: boolean): string | null {
    if (!reversed) {
      return null;
    }
    return this.naturalAsc ? 'desc' : 'asc';
  }

  /** 存下来的 order → 是否反转 */
  isReversed(order: string | null): boolean {
    if (order === null) {
      return false;
    }
    return (order === 'asc') !== this.naturalAsc;
  }
}

/** 海报墙各档排序的方向档案（Web lib/wall-sort.ts SORT_DIRECTIONS） */
export class WallSortDirections {
  static of(sort: string): WallSortDirection | null {
    if (sort === 'title' || sort === 'probing') {
      return new WallSortDirection(true, 'A→Z', 'Z→A');
    }
    if (sort === 'added_at' || sort === 'release_date' || sort === 'favorited_at') {
      return new WallSortDirection(false, '旧→新', '新→旧');
    }
    if (sort === 'rating') {
      return new WallSortDirection(false, '低→高', '高→低');
    }
    if (sort === 'runtime') {
      return new WallSortDirection(true, '短→长', '长→短');
    }
    if (sort === 'size') {
      return new WallSortDirection(false, '小→大', '大→小');
    }
    if (sort === 'last_played') {
      return new WallSortDirection(false, '远→近', '近→远');
    }
    return null;
  }
}

/** 库行 / 合集行可选的排序档（取值与海报墙同名，另含首页独有的 random） */
export class SortPreset {
  /** 推荐的行名（按库 × 方向） */
  readonly name: (library: string, reversed: boolean) => string;
  /** 不带库名的短标签（按方向） */
  readonly short: (reversed: boolean) => string;
  readonly direction: WallSortDirection | null;
  readonly hint: string;

  constructor(name: (library: string, reversed: boolean) => string,
    short: (reversed: boolean) => string, direction: WallSortDirection | null, hint: string) {
    this.name = name;
    this.short = short;
    this.direction = direction;
    this.hint = hint;
  }
}

/** 「我的收藏」行的排序档 */
export class FavoritesPreset {
  readonly name: (reversed: boolean) => string;
  readonly direction: WallSortDirection | null;
  readonly hint: string;

  constructor(name: (reversed: boolean) => string, direction: WallSortDirection | null, hint: string) {
    this.name = name;
    this.direction = direction;
    this.hint = hint;
  }
}

/** 行的来源：五种形状，instanceof 区分 */
export class HomeRowKind {
}
export class UpNextKind extends HomeRowKind {
}
export class FavoritesKind extends HomeRowKind {
  readonly sort: string;
  readonly reversed: boolean;

  constructor(sort: string, reversed: boolean) {
    super();
    this.sort = sort;
    this.reversed = reversed;
  }
}
export class LibrariesKind extends HomeRowKind {
}

/** 「按类型找电影 / 按类型找剧集」：跨库的类型格子行（对应 iOS `case genres(kind:libraries:)`） */
export class GenresKind extends HomeRowKind {
  readonly kind: string;

  constructor(kind: string) {
    super();
    this.kind = kind;
  }
}

/** 「全部电影 / 全部剧集」：同类型多个库合成一面墙（对应 iOS `case mediaKind`，只在自定义里添加） */
export class MediaKindRowKind extends HomeRowKind {
  readonly kind: string;
  readonly name: string;

  constructor(kind: string, name: string) {
    super();
    this.kind = kind;
    this.name = name;
  }
}
export class LibraryRowKind extends HomeRowKind {
  readonly library: LibraryView;
  readonly sort: string;
  readonly reversed: boolean;
  readonly unwatched: boolean;
  readonly name: string;
  readonly builtin: boolean;

  constructor(library: LibraryView, sort: string, reversed: boolean,
    unwatched: boolean, name: string, builtin: boolean) {
    super();
    this.library = library;
    this.sort = sort;
    this.reversed = reversed;
    this.unwatched = unwatched;
    this.name = name;
    this.builtin = builtin;
  }
}
export class CollectionRowKind extends HomeRowKind {
  readonly collection: CollectionView;
  readonly sort: string;
  readonly reversed: boolean;
  readonly name: string;

  constructor(collection: CollectionView, sort: string, reversed: boolean, name: string) {
    super();
    this.collection = collection;
    this.sort = sort;
    this.reversed = reversed;
    this.name = name;
  }
}

/** 合并后的一行：来源已解析、排序与名字已落到具体值，首页直接消费 */
export class HomeRow {
  readonly id: string;
  readonly hidden: boolean;
  readonly kind: HomeRowKind;

  constructor(id: string, hidden: boolean, kind: HomeRowKind) {
    this.id = id;
    this.hidden = hidden;
    this.kind = kind;
  }

  /** 这一行显示的名字：用户起的优先，空则跟随默认（库行按排序推荐，合集行用合集名） */
  title(): string {
    if (this.kind instanceof FavoritesKind) {
      return '我的收藏';
    }
    if (this.kind instanceof LibraryRowKind) {
      return this.kind.name.length === 0
        ? HomeRows.preset(this.kind.sort).name(this.kind.library.name, this.kind.reversed)
        : this.kind.name;
    }
    if (this.kind instanceof CollectionRowKind) {
      return this.kind.name.length === 0 ? this.kind.collection.name : this.kind.name;
    }
    if (this.kind instanceof LibrariesKind) {
      return '我的媒体库';
    }
    return '接下来继续';
  }
}

/** 存下来的（sort, order）解析后的档位与方向 */
class ResolvedSort {
  readonly sort: string;
  readonly reversed: boolean;

  constructor(sort: string, reversed: boolean) {
    this.sort = sort;
    this.reversed = reversed;
  }
}

export class HomeRows {
  /** 库行 / 合集行可选的排序档 */
  static readonly allSorts: string[] =
    ['added_at', 'release_date', 'last_played', 'rating', 'random', 'title'];
  /** 「我的收藏」行的排序档 */
  static readonly favoritesSorts: string[] = ['unwatched_first', 'favorited_at', 'rating', 'title'];

  static preset(sort: string): SortPreset {
    if (sort === 'release_date') {
      return new SortPreset(
        (library: string, reversed: boolean): string => reversed ? `最早上映的${library}` : `最近上映的${library}`,
        (reversed: boolean): string => reversed ? '最早上映' : '最近上映',
        new WallSortDirection(false, '旧→新', '新→旧'), '上映时间');
    }
    if (sort === 'last_played') {
      // 反转 = 上次播放离现在最远的在前：「很久没看的」比「最早观看的」更像人话
      return new SortPreset(
        (library: string, reversed: boolean): string => reversed ? `很久没看的${library}` : `最近观看的${library}`,
        (reversed: boolean): string => reversed ? '很久没看' : '最近观看',
        new WallSortDirection(false, '远→近', '近→远'), '我播放过的，按上次播放时间');
    }
    if (sort === 'rating') {
      return new SortPreset(
        (library: string, reversed: boolean): string => reversed ? `评分最低的${library}` : `评分最高的${library}`,
        (reversed: boolean): string => reversed ? '评分最低' : '评分最高',
        new WallSortDirection(false, '低→高', '高→低'), '评分');
    }
    if (sort === 'random') {
      return new SortPreset(
        (library: string, _reversed: boolean): string => `随便看看 · ${library}`,
        (_reversed: boolean): string => '随便看看',
        null, '每天换一批');
    }
    if (sort === 'title') {
      return new SortPreset(
        (library: string, reversed: boolean): string => reversed ? `${library} Z–A` : `${library} A–Z`,
        (reversed: boolean): string => reversed ? 'Z–A' : 'A–Z',
        new WallSortDirection(true, 'A→Z', 'Z→A'), '片名');
    }
    // added_at（默认）
    return new SortPreset(
      (library: string, reversed: boolean): string => reversed ? `最早添加的${library}` : `最近添加的${library}`,
      (reversed: boolean): string => reversed ? '最早添加' : '最近添加',
      new WallSortDirection(false, '旧→新', '新→旧'), '入库时间');
  }

  /** 排序预设按库类型裁剪：评分、上映对家庭录像与照片没有意义 */
  static sortsFor(kind: string): string[] {
    if (kind === 'photo') {
      return ['added_at', 'title', 'random'];
    }
    if (kind === 'video') {
      return ['added_at', 'last_played', 'title', 'random'];
    }
    return HomeRows.allSorts;
  }

  static favoritesPreset(sort: string): FavoritesPreset {
    if (sort === 'favorited_at') {
      return new FavoritesPreset(
        (reversed: boolean): string => reversed ? '最早收藏' : '最近收藏',
        new WallSortDirection(false, '旧→新', '新→旧'), '收藏时间');
    }
    if (sort === 'rating') {
      return new FavoritesPreset(
        (reversed: boolean): string => reversed ? '评分最低' : '评分最高',
        new WallSortDirection(false, '低→高', '高→低'), '评分');
    }
    if (sort === 'title') {
      return new FavoritesPreset(
        (reversed: boolean): string => reversed ? '片名 Z–A' : '片名 A–Z',
        new WallSortDirection(true, 'A→Z', 'Z→A'), '片名');
    }
    // unwatched_first（默认）
    return new FavoritesPreset(
      (_reversed: boolean): string => '未看优先',
      null, '没看完的在前，再按收藏时间');
  }

  /** 有类型色块行的库类型（TMDB 的类型表只分电影与剧集，同 iOS `genreKinds`） */
  private static readonly genreKinds: string[] = ['movie', 'tv'];

  /**
   * 出厂布局：接下来继续 → 我的收藏 → 我的媒体库 → **按类型找电影 → 按类型找剧集** → 每个库一行「最近添加」。
   *
   * 位置与 iOS `defaultRows` 一致（类型行紧跟「我的媒体库」）。
   * 「全部电影 / 全部剧集」那种聚合行**不进出厂布局**（iOS 的口径：要用户去「自定义首页」里主动加）。
   */
  private static defaultRows(libraries: LibraryView[]): HomeRow[] {
    const rows: HomeRow[] = [
      new HomeRow('up-next', false, new UpNextKind()),
      new HomeRow('favorites', false, new FavoritesKind('unwatched_first', false)),
      new HomeRow('libraries', false, new LibrariesKind())
    ];
    for (const kind of HomeRows.genreKinds) {
      if (HomeRows.librariesOfKind(libraries, kind).length > 0) {
        rows.push(new HomeRow(`genres:${kind}`, false, new GenresKind(kind)));
      }
    }
    for (const library of libraries) {
      if (!library.exclude_from_home) {
        rows.push(new HomeRow(`lib:${library.id}`, false,
          new LibraryRowKind(library, 'added_at', false, false, '', true)));
      }
    }
    return rows;
  }

  /** 某种类型的库（判断该不该出「按类型找」那一行） */
  private static librariesOfKind(libraries: LibraryView[], kind: string): LibraryView[] {
    const out: LibraryView[] = [];
    for (const library of libraries) {
      if (library.kind === kind) {
        out.push(library);
      }
    }
    return out;
  }

  /** 存下来的（sort, order）→（档位, 是否反转）；老偏好的 release_date_asc 归一成 release_date + 反转 */
  private static asRowSort(value: string | null, order: string | null, allowed: string[]): ResolvedSort {
    if (value === 'release_date_asc' && allowed.includes('release_date')) {
      return new ResolvedSort('release_date', true);
    }
    const sort: string = value !== null && allowed.includes(value) ? value : allowed[0];
    const direction: WallSortDirection | null = HomeRows.preset(sort).direction;
    return new ResolvedSort(sort, direction !== null ? direction.isReversed(order) : false);
  }

  /** 把存下来的清单与当前可见的库、合集合并成首页要渲染的行 */
  static build(prefs: HomeRowPref[], libraries: LibraryView[], collections: CollectionView[]): HomeRow[] {
    const visible: LibraryView[] =
      libraries.filter((library: LibraryView): boolean => library.viewer_access);
    const defaults: HomeRow[] = HomeRows.defaultRows(visible);
    if (prefs.length === 0) {
      return defaults;
    }
    const libById: Map<number, LibraryView> = new Map<number, LibraryView>();
    for (const library of visible) {
      if (!libById.has(library.id)) {
        libById.set(library.id, library);
      }
    }
    const colById: Map<number, CollectionView> = new Map<number, CollectionView>();
    for (const collection of collections) {
      if (!colById.has(collection.id)) {
        colById.set(collection.id, collection);
      }
    }
    const seen: Set<string> = new Set<string>();
    const rows: HomeRow[] = [];
    for (const pref of prefs) {
      if (seen.has(pref.id)) {
        continue;
      }
      const row: HomeRow | null = HomeRows.resolve(pref, libById, colById);
      if (row === null) {
        continue;
      }
      seen.add(pref.id);
      rows.push(row);
    }
    // 没存过的内置行追加在末尾（版本升级新增的入口不能消失）
    for (const row of defaults) {
      if (row.kind instanceof LibraryRowKind) {
        continue;
      }
      if (seen.has(row.id)) {
        continue;
      }
      seen.add(row.id);
      rows.push(row);
    }
    // 没存过的库补一条默认行，插在最后一条库行之后（没有库行时插在「我的媒体库」之后）
    const missing: HomeRow[] = defaults.filter((row: HomeRow): boolean => {
      return row.kind instanceof LibraryRowKind && !seen.has(row.id);
    });
    if (missing.length > 0) {
      let at: number = rows.length;
      let anchor: number = -1;
      for (let i: number = rows.length - 1; i >= 0; i--) {
        if (rows[i].kind instanceof LibraryRowKind) {
          anchor = i;
          break;
        }
      }
      if (anchor < 0) {
        for (let i: number = 0; i < rows.length; i++) {
          if (rows[i].kind instanceof LibrariesKind) {
            anchor = i;
            break;
          }
        }
      }
      if (anchor >= 0) {
        at = anchor + 1;
      }
      for (let i: number = missing.length - 1; i >= 0; i--) {
        rows.splice(at, 0, missing[i]);
      }
    }
    return rows;
  }

  private static resolve(pref: HomeRowPref, libById: Map<number, LibraryView>,
    colById: Map<number, CollectionView>): HomeRow | null {
    const hidden: boolean = pref.hidden === true;
    if (pref.id === 'up-next') {
      return new HomeRow('up-next', hidden, new UpNextKind());
    }
    if (pref.id === 'libraries') {
      return new HomeRow('libraries', hidden, new LibrariesKind());
    }
    if (pref.id === 'favorites') {
      const sort: string = pref.sort !== null && pref.sort !== undefined
        && HomeRows.favoritesSorts.includes(pref.sort) ? pref.sort : 'unwatched_first';
      const direction: WallSortDirection | null = HomeRows.favoritesPreset(sort).direction;
      return new HomeRow('favorites', hidden,
        new FavoritesKind(sort, direction !== null ? direction.isReversed(pref.order ?? null) : false));
    }
    if (pref.id.startsWith('lib:')) {
      // 管理员勾了「从首页排除」的库：默认行不出现，存过也一样
      const id: number = Number(pref.id.substring(4));
      if (!Number.isInteger(id)) {
        return null;
      }
      const library: LibraryView | undefined = libById.get(id);
      if (library === undefined || library.exclude_from_home) {
        return null;
      }
      return HomeRows.libraryRow(pref, library, true);
    }
    if (!pref.id.startsWith('row:')) {
      return null;
    }
    const cid: number | null = pref.collection_id ?? null;
    if (cid !== null) {
      const collection: CollectionView | undefined = colById.get(cid);
      if (collection === undefined) {
        return null;
      }
      // 没存排序时沿用合集自己的序（含方向）
      const resolved: ResolvedSort = pref.sort !== null && pref.sort !== undefined
        ? HomeRows.asRowSort(pref.sort, pref.order ?? null, HomeRows.allSorts)
        : HomeRows.asRowSort(collection.sort, null, HomeRows.allSorts);
      return new HomeRow(pref.id, hidden,
        new CollectionRowKind(collection, resolved.sort, resolved.reversed, (pref.name ?? '').trim()));
    }
    const lid: number | null = pref.library_id ?? null;
    if (lid !== null) {
      const library: LibraryView | undefined = libById.get(lid);
      if (library === undefined) {
        return null;
      }
      return HomeRows.libraryRow(pref, library, false);
    }
    return null;
  }

  private static libraryRow(pref: HomeRowPref, library: LibraryView, builtin: boolean): HomeRow {
    const resolved: ResolvedSort =
      HomeRows.asRowSort(pref.sort ?? null, pref.order ?? null, HomeRows.sortsFor(library.kind));
    // 「最近观看」只要播过的，与「只看没看过的」互斥：以排序为准，开关作废
    return new HomeRow(pref.id, pref.hidden === true, new LibraryRowKind(
      library, resolved.sort, resolved.reversed,
      pref.unwatched === true && resolved.sort !== 'last_played',
      (pref.name ?? '').trim(), builtin));
  }
}
