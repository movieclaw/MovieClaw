/**
 * 车机 / TV 海报墙的共享层：
 * - WallItem / WallPage / WallDataSource：墙格轻量模型、一页结果、LazyForEach 数据源
 *   （Car/Tv 各自的 XxxWallItem 继承 WallItem 只补差异字段）
 * - WallRow：筛选面板的一行（小节标题 / 选项）
 * - WallMode：四路复用的模式与键、排序方向、条件文案（纯函数，两端逐字共用）
 * - WallQuery / WallRawPage / WallFetch：按模式取一页的取数内核
 *   （库墙 / kind 跨库墙 / 合集 / 行墙 lib:col:favorites:genre；影人行墙由车机端自持）。
 * 取数返回原始服务端视图（WallRawPage），各端再映射成自己的墙格。
 */
import { MovieClawApi } from '../api/Endpoints';
import {
  FacetValueView,
  FavoritesView,
  LibraryFacetsView,
  LibraryItemView
} from '../api/Models';
import { AppModel } from '../common/AppModel';
import { HomeRows, WallSortDirection, WallSortDirections } from '../library/HomeRows';
import { ShellWallPrefs } from './ShellUiState';

/** 墙上一格的轻量模型基类（LazyForEach 数据源持有，不参与观察；Car/Tv 继承补差异） */
export class WallItem {
  /** LazyForEach 复用键（页内唯一即可） */
  readonly key: string;
  readonly itemId: number;
  /** 详情落点库；0 = 不知道（跨库墙里服务端没给就没法进详情） */
  readonly libraryId: number;
  readonly title: string;
  readonly year: number | null;
  /** 已解析并按显示宽度补 &w= 的海报 URL */
  readonly posterUrl: string;
  /** 已解析的剧照 URL（页面背景用，比海报宽） */
  readonly backdropUrl: string;

  constructor(key: string, itemId: number, libraryId: number, title: string,
    year: number | null, posterUrl: string, backdropUrl: string) {
    this.key = key;
    this.itemId = itemId;
    this.libraryId = libraryId;
    this.title = title;
    this.year = year;
    this.posterUrl = posterUrl;
    this.backdropUrl = backdropUrl;
  }

  /** 解析好的 URL 再按显示宽度补 &w=（后端按 w 降采样出图） */
  static sized(url: string | null, px: number): string {
    if (url === null) {
      return '';
    }
    return `${url}${url.includes('?') ? '&' : '?'}w=${px}`;
  }
}

/** 一页取数结果 */
export class WallPage {
  readonly items: WallItem[];
  /** 整份结果共几部；不知道为 null（收藏接口会给） */
  readonly total: number | null;

  constructor(items: WallItem[], total: number | null) {
    this.items = items;
    this.total = total;
  }
}

/** 海报墙的 LazyForEach 数据源：整批换 / 尾部追加 / 头部补页 */
export class WallDataSource implements IDataSource {
  private items: WallItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): WallItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /** 整批换成这一批（换排序） */
  setItems(items: WallItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  /** 尾部追加一页（向下翻） */
  append(items: WallItem[]): void {
    if (items.length === 0) {
      return;
    }
    const at: number = this.items.length;
    this.items = this.items.concat(items);
    for (const listener of this.listeners) {
      for (let i: number = 0; i < items.length; i++) {
        listener.onDataAdd(at + i);
      }
    }
  }

  /** 头部补一页（往回走）：逐条 onDataAdd，已建好的格子按 key 复用不重建 */
  prepend(items: WallItem[]): void {
    if (items.length === 0) {
      return;
    }
    this.items = items.concat(this.items);
    for (const listener of this.listeners) {
      for (let i: number = 0; i < items.length; i++) {
        listener.onDataAdd(i);
      }
    }
  }

  indexOfItem(itemId: number): number {
    for (let i: number = 0; i < this.items.length; i++) {
      if (this.items[i].itemId === itemId) {
        return i;
      }
    }
    return -1;
  }
}

/** 筛选面板里的一行（小节标题 / 选项） */
export class WallRow {
  /** option | header */
  readonly key: string;
  readonly kind: string;
  readonly label: string;
  readonly countText: string | null;
  readonly selected: boolean;
  readonly dimmed: boolean;
  readonly onPick: (() => void) | null;

  constructor(key: string, kind: string, label: string, countText: string | null,
    selected: boolean, dimmed: boolean, onPick: (() => void) | null) {
    this.key = key;
    this.kind = kind;
    this.label = label;
    this.countText = countText;
    this.selected = selected;
    this.dimmed = dimmed;
    this.onPick = onPick;
  }

  static header(key: string, label: string): WallRow {
    return new WallRow(key, 'header', label, null, false, false, null);
  }

  static option(key: string, label: string, countText: string | null, selected: boolean,
    dimmed: boolean, onPick: () => void): WallRow {
    return new WallRow(key, 'option', label, countText, selected, dimmed, onPick);
  }
}

/** 墙的四路复用模式与条件文案（纯函数，两端逐字共用） */
export class WallMode {
  /** 四路复用的数据源模式：rowWall / collection / kind / library */
  static of(sourceKey: string, collectionId: number, kindSource: string): string {
    if (sourceKey !== '') {
      return 'rowWall';
    }
    if (collectionId > 0) {
      return 'collection';
    }
    if (kindSource !== '') {
      return 'kind';
    }
    return 'library';
  }

  /** 排序与筛选记忆的存储键；行墙没有面板，不记 */
  static wallKeyOf(mode: string, libraryId: number, kindSource: string, collectionId: number): string {
    if (mode === 'library') {
      return `${libraryId}`;
    }
    if (mode === 'kind') {
      return `kind_${kindSource}`;
    }
    if (mode === 'collection') {
      return `col_${collectionId}`;
    }
    return '';
  }

  static sortKeysOf(mode: string): string[] {
    if (mode === 'collection') {
      return ['collection', 'added_at', 'release_date', 'rating', 'title'];
    }
    return ['added_at', 'release_date', 'rating', 'title'];
  }

  static defaultSortOf(mode: string): string {
    return mode === 'collection' ? 'collection' : 'added_at';
  }

  static isReversed(prefs: ShellWallPrefs): boolean {
    const direction: WallSortDirection | null = WallSortDirections.of(prefs.sort);
    if (direction === null) {
      return false;
    }
    return direction.isReversed(prefs.order.length === 0 ? null : prefs.order);
  }

  static orderParam(prefs: ShellWallPrefs): string | undefined {
    const direction: WallSortDirection | null = WallSortDirections.of(prefs.sort);
    if (direction === null) {
      return undefined;
    }
    return direction.orderParam(WallMode.isReversed(prefs)) ?? undefined;
  }

  static sortLabel(prefs: ShellWallPrefs, sort: string): string {
    if (sort === 'collection') {
      return '合集顺序';
    }
    return HomeRows.preset(sort).short(WallMode.isReversed(prefs));
  }

  static picksActive(prefs: ShellWallPrefs): boolean {
    return prefs.genre !== null || prefs.decade !== null || prefs.resolution !== null;
  }

  /** 画质档展示名：HDR / 4K 按习惯叫法 */
  static qualityTitle(prefs: ShellWallPrefs): string {
    const value: string | null = prefs.resolution;
    if (value === null) {
      return '';
    }
    if (value === 'hdr') {
      return 'HDR';
    }
    if (value === '2160p') {
      return '4K';
    }
    return value;
  }

  /** 分辨率按习惯叫法：2160p 写「4K」 */
  static resolutionLabel(facet: FacetValueView): string {
    return facet.value === '2160p' ? '4K' : facet.label;
  }

  /** 年代档展示名（服务端的「2010s」→「2010 年代」） */
  static decadeTitle(value: string): string {
    if (value.length === 5 && value.endsWith('s')) {
      const year: number = Number(value.substring(0, 4));
      if (!Number.isNaN(year) && year > 0) {
        return `${value.substring(0, 4)} 年代`;
      }
    }
    return value;
  }

  /** 条件摘要的各段（「科幻 · 2010 年代 · 未看」；类型标签由调用端按 facets 给） */
  static conditionParts(prefs: ShellWallPrefs, genreLabel: string): string[] {
    const parts: string[] = [];
    if (prefs.genre !== null) {
      parts.push(genreLabel);
    }
    if (prefs.decade !== null) {
      parts.push(WallMode.decadeTitle(prefs.decade));
    }
    if (prefs.resolution !== null) {
      parts.push(WallMode.qualityTitle(prefs));
    }
    if (prefs.unwatched) {
      parts.push('未看');
    }
    return parts;
  }

  /** 筛空时的文案 */
  static emptyMessage(prefs: ShellWallPrefs, genreLabel: string): string {
    const parts: string[] = WallMode.conditionParts(prefs, genreLabel);
    if (parts.length === 0) {
      return '换一个条件试试';
    }
    return `「${parts.join(' · ')}」下没有影片，换一个条件试试`;
  }
}

/** 一面墙的取数参数（fetchViews 按它分派四路模式） */
export class WallQuery {
  mode: string = 'library';
  libraryId: number = 0;
  /** kind 跨库墙的媒体类型（movie/tv）；单库墙为空串 */
  kindSource: string = '';
  collectionId: number = 0;
  /** 行墙数据源形状：lib:/col:/favorites:/genre:（与首页行取数同构） */
  sourceKey: string = '';
}

/** 取数内核的一页原始结果（服务端视图；调用端映射成自己的墙格） */
export class WallRawPage {
  readonly views: LibraryItemView[];
  /** 整份结果共几部；不知道为 null（收藏接口会给） */
  readonly total: number | null;

  constructor(views: LibraryItemView[], total: number | null) {
    this.views = views;
    this.total = total;
  }
}

/** 按模式取一页的取数内核（库墙 / kind 墙 / 合集 / 行墙，两端逐字共用） */
export class WallFetch {
  /** 筛选面板的候选值与计数（每一维排除自身条件后算；画质维度要 tier=all 才有） */
  static facets(api: MovieClawApi, libraryId: number,
    prefs: ShellWallPrefs): Promise<LibraryFacetsView> {
    const g: string | undefined = prefs.genre ?? undefined;
    const d: string | undefined = prefs.decade ?? undefined;
    const w: string | undefined = prefs.unwatched ? 'unwatched' : undefined;
    const res: string | undefined =
      prefs.resolution !== null && prefs.resolution !== 'hdr' ? prefs.resolution : undefined;
    const hdr: boolean | undefined = prefs.resolution === 'hdr' ? true : undefined;
    return api.libraryItemsFacets(libraryId, 'all', g, undefined, d, w,
      undefined, undefined, undefined, res, hdr);
  }

  /** 按模式取一页原始视图（offset 是整份结果里的位置，窗口式分页的核心） */
  static fetchViews(api: MovieClawApi, query: WallQuery, prefs: ShellWallPrefs,
    offset: number, limit: number): Promise<WallRawPage> {
    const mode: string = query.mode;
    if (mode === 'library' || mode === 'kind') {
      if (mode === 'library') {
        const g: string | undefined = prefs.genre ?? undefined;
        const d: string | undefined = prefs.decade ?? undefined;
        const w: string | undefined = prefs.unwatched ? 'unwatched' : undefined;
        const res: string | undefined =
          prefs.resolution !== null && prefs.resolution !== 'hdr' ? prefs.resolution : undefined;
        const hdr: boolean | undefined = prefs.resolution === 'hdr' ? true : undefined;
        return api.libraryItemsList(query.libraryId, prefs.sort, WallMode.orderParam(prefs),
          limit, offset, undefined, g, undefined, d, w, undefined, undefined, undefined, res, hdr)
          .then((views: LibraryItemView[]): WallRawPage => new WallRawPage(views, null));
      }
      return api.uiLibraryKindItems(query.kindSource, prefs.sort, WallMode.orderParam(prefs),
        limit, offset, undefined, undefined, undefined, prefs.unwatched ? 'unwatched' : undefined)
        .then((views: LibraryItemView[]): WallRawPage => new WallRawPage(views, null));
    }
    if (mode === 'collection') {
      const own: boolean = prefs.sort === 'collection';
      const sort: string | undefined = own ? undefined : prefs.sort;
      const order: string | undefined = own ? undefined : WallMode.orderParam(prefs);
      return api.collectionItemsList(query.collectionId, limit, offset, sort, order)
        .then((views: LibraryItemView[]): WallRawPage => new WallRawPage(views, null));
    }
    return WallFetch.fetchRowWallViews(api, query.sourceKey, offset, limit);
  }

  /**
   * 行墙取数：sourceKey 与首页那一行同一套参数，进来看到的顺序和行里一致
   * （影人 person: 行墙由车机端自持，不走这里）。
   */
  static fetchRowWallViews(api: MovieClawApi, sourceKey: string,
    offset: number, limit: number): Promise<WallRawPage> {
    const parts: string[] = sourceKey.split(':');
    if (parts[0] === 'lib' && parts.length >= 5) {
      const id: number = Number(parts[1]);
      const sort: string = parts[2];
      const reversed: boolean = parts[3] === 'true';
      const unwatched: boolean = parts[4] === 'true';
      const direction: WallSortDirection | null = WallSortDirections.of(sort);
      const order: string | undefined = direction === null
        ? undefined : (direction.orderParam(reversed) ?? undefined);
      // 「最近观看」行只要播过的（w=seen），同首页取数
      const watch: string | undefined = sort === 'last_played'
        ? 'seen' : (unwatched ? 'unwatched' : undefined);
      return api.libraryItemsList(id, sort, order, limit, offset,
        undefined, undefined, undefined, undefined, watch)
        .then((views: LibraryItemView[]): WallRawPage => new WallRawPage(views, null));
    }
    if (parts[0] === 'col' && parts.length >= 4) {
      const id: number = Number(parts[1]);
      const sort: string = parts[2];
      const reversed: boolean = parts[3] === 'true';
      const direction: WallSortDirection | null = WallSortDirections.of(sort);
      const order: string | undefined = direction === null
        ? undefined : (direction.orderParam(reversed) ?? undefined);
      return api.collectionItemsList(id, limit, offset, sort, order)
        .then((views: LibraryItemView[]): WallRawPage => new WallRawPage(views, null));
    }
    if (parts[0] === 'favorites' && parts.length >= 3) {
      const sort: string = parts[1];
      const reversed: boolean = parts[2] === 'true';
      // 「未看优先」是首页收藏行的一档：进来时换成收藏时间序
      const unwatchedFirst: boolean = sort === 'unwatched_first';
      const actualSort: string = unwatchedFirst ? 'favorited_at' : sort;
      const direction: WallSortDirection | null =
        HomeRows.favoritesPreset(sort).direction ?? null;
      const order: string | undefined = direction === null
        ? undefined : (direction.orderParam(reversed) ?? undefined);
      return api.playbackFavorites(limit, offset, unwatchedFirst, actualSort, order)
        .then((view: FavoritesView): WallRawPage => new WallRawPage(view.items, view.total));
    }
    if (parts[0] === 'genre' && parts.length >= 3) {
      const kind: string = parts[1];
      const value: string = parts[2];
      // 类型格子墙：按 TMDB 类型筛好的跨库墙，最近添加在前
      return api.uiLibraryKindItems(kind, 'added_at', undefined, limit, offset, value)
        .then((views: LibraryItemView[]): WallRawPage => new WallRawPage(views, null));
    }
    return Promise.reject<WallRawPage>(new Error('未知的数据源'));
  }

  /** 影人行墙的 personId（sourceKey 形如 person:<tmdbPersonId>；不是影人墙返回 null） */
  static personIdOf(sourceKey: string): number | null {
    const parts: string[] = sourceKey.split(':');
    if (parts[0] === 'person' && parts.length >= 2) {
      return Number(parts[1]);
    }
    return null;
  }

  /** 服务端在位吗（取数前兜底判断用） */
  static hasApi(): boolean {
    return AppModel.shared.api !== null;
  }
}
