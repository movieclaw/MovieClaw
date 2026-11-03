/**
 * TV 海报墙（US5，对齐参考端 TVLibraryView / TVWallIndex / TVRowWallView）：
 * - 5 列海报网格，海报下不挂字；选中（悬浮/聚焦）那张的底部浮出「片名 · 年份」暗带（TvPosterCard band 模式）；
 * - 背景是选中条目剧照的放大模糊版，随选中交叉淡入（TvStageBackdrop + blur，快速滚动时防抖不逐张闪）；
 * - 标题行：大标题 + 条件摘要与总数 + 「排序与筛选」（排序 added_at/release_date/rating/title、
 *   「只看没看过的」、类型/年代/画质三档每项带命中数，0 部压暗；记忆经 TvUiState 以 tv_wall_ 前缀持久化）；
 * - 大库翻找（US5.3/US5.4）：窗口式分页（一页 60 部、离底三排取下一页、往回走补上一页）；
 *   排序为 title/release_date/rating 时右缘索引条（A–Z 拼音首字母 / 年份 / 评分档，空档压暗不可选），
 *   选中一档把窗口换成从那一档开始的一页；按住方向键快速滚动时屏幕中央浮出「2015 · 第 n 部/共 N 部」；
 * - 首页「查看全部」行墙（TvRowWallRoute 的 lib/col/favorites/genre 四种 sourceKey）与
 *   合集页（TvCollectionRoute）复用本组件：行墙没有排序与筛选，合集多一档「合集顺序」。
 *
 * 焦点三路统一（遥控器方向键 / 灵犀指针悬停 / 确认键）由 TvFocusable 承担。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { MovieClawApi } from '../../api/Endpoints';
import {
  FacetValueView,
  FavoritesView,
  LibraryFacetsView,
  LibraryIndexEntryView,
  LibraryItemView
} from '../../api/Models';
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { HomeRows, WallSortDirection, WallSortDirections } from '../../library/HomeRows';
import { TvCardCaption, TvPillButton, TvPosterCard, TvStateView } from '../components/TvCards';
import { TvFocus } from '../components/TvFocus';
import { TvStageBackdrop } from '../components/TvStage';
import { TvDetailRoute, TvRoute, TvUiState, TvWallPrefs } from '../model/TvUiState';
import { TvArt } from '../theme/TvTheme';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';

/** 海报墙列数（Apple TV 参考端一屏 5 列） */
const WALL_COLUMNS: number = 5;
/** 一页取多少部（整排 5 的倍数：补页时列位置不错开） */
const WALL_PAGE_SIZE: number = 60;
/** 连续两次焦点移动间隔小于此值（毫秒）= 按住方向键快速滚动，出中央定位提示 */
const QUICK_STEP_MS: number = 550;

/** 墙上一格的轻量模型（LazyForEach 数据源持有，不参与观察） */
export class TvWallItem {
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
  /** 按添加时间排序时的位置提示（「2026 年 8 月」） */
  readonly addedMonth: string | null;

  constructor(key: string, itemId: number, libraryId: number, title: string,
    year: number | null, posterUrl: string, backdropUrl: string, addedMonth: string | null) {
    this.key = key;
    this.itemId = itemId;
    this.libraryId = libraryId;
    this.title = title;
    this.year = year;
    this.posterUrl = posterUrl;
    this.backdropUrl = backdropUrl;
    this.addedMonth = addedMonth;
  }

  static fromView(view: LibraryItemView, origin: string, cellWidth: number): TvWallItem {
    const poster: string = TvWallItem.sized(
      ImageUrls.resolve(origin, view.poster_url ?? view.backdrop_url ?? null, null),
      TvArt.pxWidth(cellWidth));
    const backdropBase: string | null = ImageUrls.resolve(origin, view.backdrop_url ?? view.poster_url ?? null, null);
    const backdrop: string = backdropBase === null ? '' : TvWallItem.sized(backdropBase, 1280);
    return new TvWallItem(
      `w${view.media_item_id}`,
      view.media_item_id,
      view.library_id ?? 0,
      view.title,
      view.year ?? null,
      poster,
      backdrop,
      TvWallItem.addedMonth(view.added_at ?? null));
  }

  /** 解析好的 URL 再按显示宽度补 &w=（后端按 w 降采样出图） */
  private static sized(url: string | null, px: number): string {
    if (url === null) {
      return '';
    }
    return `${url}${url.includes('?') ? '&' : '?'}w=${px}`;
  }

  /** added_at 是 ISO 时间，只取年月做位置提示 */
  private static addedMonth(addedAt: string | null): string | null {
    if (addedAt === null || addedAt.length < 7) {
      return null;
    }
    const year: number = Number(addedAt.substring(0, 4));
    const month: number = Number(addedAt.substring(5, 7));
    if (Number.isNaN(year) || Number.isNaN(month) || year <= 0 || month < 1 || month > 12) {
      return null;
    }
    return `${year} 年 ${month} 月`;
  }
}

/** 一页取数结果 */
class TvWallPage {
  readonly items: TvWallItem[];
  /** 整份结果共几部；不知道为 null（收藏接口会给） */
  readonly total: number | null;

  constructor(items: TvWallItem[], total: number | null) {
    this.items = items;
    this.total = total;
  }
}

/** 索引条的一档（对齐参考端 TVWallIndexEntry） */
export class TvWallIndexEntry {
  /** 档名：首字母（A–Z / #）、年份（2023）、年代（1990s）、评分档（9+ / 更低 / 未评分） */
  readonly key: string;
  /** 索引条上写的字（「S」「2023」「90s」「<7」） */
  readonly label: string;
  /** 位置提示与预览里的大字（「S」「2023」「1990 年代」） */
  readonly title: string;
  /** 这一档有几部；0 = 空档（压暗、跳不过去） */
  readonly count: number;
  /** 这一档第一部在整份排序里的位置（/items?offset= 的取值）；空档为 null */
  readonly offset: number | null;

  constructor(key: string, label: string, title: string, count: number, offset: number | null) {
    this.key = key;
    this.label = label;
    this.title = title;
    this.count = count;
    this.offset = offset;
  }
}

/** 服务端跳转索引（item-index）→ 电视索引条（对齐参考端 TVWallIndex.swift） */
class TvWallIndex {
  /** 有索引条的排序：按标题（首字母）、按上映（年份）、按评分（分数档）；按添加时间没有有意义的分档 */
  static supports(sort: string): boolean {
    return sort === 'title' || sort === 'release_date' || sort === 'rating';
  }

  static entries(sort: string, reversed: boolean, raw: LibraryIndexEntryView[]): TvWallIndexEntry[] {
    if (sort === 'title') {
      return TvWallIndex.letters(reversed, raw);
    }
    if (sort === 'release_date') {
      return TvWallIndex.years(reversed, raw);
    }
    if (sort === 'rating') {
      return TvWallIndex.ratings(raw);
    }
    return [];
  }

  /** 整份排序里第 offset 部落在哪一档（取起点不超过 offset 的最后一档） */
  static entryAt(offset: number, entries: TvWallIndexEntry[]): TvWallIndexEntry | null {
    let best: TvWallIndexEntry | null = null;
    let bestOffset: number = -1;
    for (const entry of entries) {
      const at: number = entry.offset === null ? Number.MAX_SAFE_INTEGER : entry.offset;
      if (at <= offset && at >= bestOffset) {
        best = entry;
        bestOffset = at;
      }
    }
    return best;
  }

  /** 年代档在电视上写成「2010 年代」（服务端的展示名是「2010s」） */
  static decadeTitle(value: string): string {
    if (value.length === 5 && value.endsWith('s')) {
      const year: number = Number(value.substring(0, 4));
      if (!Number.isNaN(year) && year > 0) {
        return `${value.substring(0, 4)} 年代`;
      }
    }
    return value;
  }

  /** 按标题：A–Z 加 #（# 在最后，同服务端的排序）全部列出，库里没有的字母压暗——字母表不缺字 */
  private static letters(reversed: boolean, raw: LibraryIndexEntryView[]): TvWallIndexEntry[] {
    const keys: string[] = [];
    for (let i: number = 0; i < 26; i++) {
      keys.push(String.fromCharCode(65 + i));
    }
    keys.push('#');
    if (reversed) {
      keys.reverse();
    }
    const out: TvWallIndexEntry[] = [];
    for (const key of keys) {
      let count: number = 0;
      let offset: number | null = null;
      for (const entry of raw) {
        if (entry.initial === key) {
          count = entry.count;
          offset = entry.offset;
          break;
        }
      }
      out.push(new TvWallIndexEntry(key, key, key, count, offset));
    }
    return out;
  }

  /** 按上映：每年一档，2000 年以前按年代并档；最新一年在最上；服务端回年档还是月档都并得起 */
  private static years(reversed: boolean, raw: LibraryIndexEntryView[]): TvWallIndexEntry[] {
    const counts: Map<string, number> = new Map<string, number>();
    const offsets: Map<string, number> = new Map<string, number>();
    let unknownCount: number = 0;
    let unknownOffset: number = -1;
    for (const entry of raw) {
      const year: number = Number(entry.initial.substring(0, 4));
      if (entry.initial.length < 4 || Number.isNaN(year)) {
        // 「未知」：没有上映日期的，服务端排在最后
        unknownCount += entry.count;
        if (unknownOffset < 0 || entry.offset < unknownOffset) {
          unknownOffset = entry.offset;
        }
        continue;
      }
      const key: string = year >= 2000 ? `${year}` : `${Math.floor(year / 10) * 10}s`;
      const known: number | undefined = counts.get(key);
      counts.set(key, (known === undefined ? 0 : known) + entry.count);
      const at: number | undefined = offsets.get(key);
      if (at === undefined || entry.offset < at) {
        offsets.set(key, entry.offset);
      }
    }
    const yearKeys: string[] = [];
    const decadeKeys: string[] = [];
    for (const key of counts.keys()) {
      if (key.endsWith('s')) {
        decadeKeys.push(key);
      } else {
        yearKeys.push(key);
      }
    }
    yearKeys.sort((a: string, b: string): number => Number(b) - Number(a));
    decadeKeys.sort((a: string, b: string): number => Number(b.substring(0, 4)) - Number(a.substring(0, 4)));
    let keys: string[] = yearKeys.concat(decadeKeys);
    if (reversed) {
      keys = keys.slice().reverse();
    }
    const out: TvWallIndexEntry[] = [];
    for (const key of keys) {
      const count: number = counts.get(key) ?? 0;
      const offset: number | null = offsets.get(key) ?? null;
      const decade: boolean = key.endsWith('s');
      out.push(new TvWallIndexEntry(key,
        decade ? key.substring(2) : key,
        decade ? TvWallIndex.decadeTitle(key) : key,
        count, offset));
    }
    if (unknownCount > 0) {
      out.push(new TvWallIndexEntry('unknown', '?', '未知年份', unknownCount,
        unknownOffset < 0 ? null : unknownOffset));
    }
    return out;
  }

  /** 按评分：服务端给几档就几档（9+ / 8+ / 7+ / 更低 / 未评分） */
  private static ratings(raw: LibraryIndexEntryView[]): TvWallIndexEntry[] {
    const out: TvWallIndexEntry[] = [];
    for (const entry of raw) {
      let label: string = entry.initial;
      let title: string = entry.initial;
      if (entry.initial === '9+') {
        label = '9+';
        title = '9 分以上';
      } else if (entry.initial === '8+') {
        label = '8+';
        title = '8 分以上';
      } else if (entry.initial === '7+') {
        label = '7+';
        title = '7 分以上';
      } else if (entry.initial === '更低') {
        label = '<7';
        title = '7 分以下';
      } else if (entry.initial === '未评分') {
        label = '—';
        title = '未评分';
      }
      out.push(new TvWallIndexEntry(entry.initial, label, title, entry.count, entry.offset));
    }
    return out;
  }
}

/** 海报墙的 LazyForEach 数据源：整批换 / 尾部追加 / 头部补页 */
class TvWallDataSource implements IDataSource {
  private items: TvWallItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): TvWallItem {
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

  /** 整批换成这一批（换排序 / 跳档） */
  setItems(items: TvWallItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  /** 尾部追加一页（向下翻） */
  append(items: TvWallItem[]): void {
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

  /** 头部补一页（往回走 / 跳档后补上面）：逐条 onDataAdd，已建好的格子按 key 复用不重建 */
  prepend(items: TvWallItem[]): void {
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
class TvWallRow {
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

  static header(key: string, label: string): TvWallRow {
    return new TvWallRow(key, 'header', label, null, false, false, null);
  }

  static option(key: string, label: string, countText: string | null, selected: boolean,
    dimmed: boolean, onPick: () => void): TvWallRow {
    return new TvWallRow(key, 'option', label, countText, selected, dimmed, onPick);
  }
}

/** 筛选面板的一个选项行：金色对勾 = 已选；命中数靠右；0 部压暗不可选 */
@ComponentV2
struct TvWallOptionRow {
  @Param label: string = '';
  @Param countText: string | null = null;
  @Param selected: boolean = false;
  @Param dimmed: boolean = false;
  @Param focusKey: string = '';
  @Param onPick: (() => void) | null = null;
  @Local active: boolean = false;

  build() {
    Row({ space: 12 }) {
      Text(this.selected ? '✓' : '')
        .fontSize(16)
        .fontWeight(700)
        .fontColor('#ffd47a')
        .width(18)
      Text(this.label)
        .fontSize(18)
        .fontWeight(this.selected ? 600 : FontWeight.Medium)
        .fontColor(this.active ? TvColors.text : TvColors.textMuted)
        .maxLines(1)
        .layoutWeight(1)
      if (this.countText !== null) {
        Text(this.countText)
          .fontSize(14)
          .fontColor(TvColors.textFaint)
      }
    }
    .height(54)
    .padding({ left: 18, right: 18 })
    .borderRadius(12)
    .backgroundColor(this.active ? TvColors.glassFillHover : Color.Transparent)
    .opacity(this.dimmed ? 0.35 : 1)
    .focusable(!this.dimmed)
    .key(this.focusKey)
    .onFocus((): void => {
      this.active = true;
    })
    .onBlur((): void => {
      this.active = false;
    })
    .onHover((isHover: boolean): void => {
      this.active = isHover;
    })
    .onClick((): void => {
      if (this.dimmed) {
        return;
      }
      const cb = this.onPick;
      if (cb !== null) {
        cb();
      }
    })
  }
}

/** 索引条的一格：平时灰字（当前档白字、空档几乎看不见），获得焦点时白底黑字放大 */
@ComponentV2
struct TvWallRailButton {
  @Param label: string = '';
  /** 年份这类多位数的档用小一号的字 */
  @Param small: boolean = false;
  @Param entryHeight: number = 24;
  @Param dimmed: boolean = false;
  @Param current: boolean = false;
  @Param focusKey: string = '';
  @Param onPick: (() => void) | null = null;
  @Local active: boolean = false;

  build() {
    Text(this.label)
      .fontSize(this.small ? 12 : 14)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.active ? '#0b0d12'
        : (this.dimmed ? 'rgba(243, 245, 249, 0.16)'
          : (this.current ? TvColors.text : 'rgba(243, 245, 249, 0.5)')))
      .textAlign(TextAlign.Center)
      .width(this.small ? 58 : 44)
      .height(this.entryHeight)
      .borderRadius(this.entryHeight / 2)
      .backgroundColor(this.active ? TvColors.text : Color.Transparent)
      .scale({
        x: this.active ? 1.15 : 1,
        y: this.active ? 1.15 : 1
      })
      .focusable(!this.dimmed)
      .key(this.focusKey)
      .onFocus((): void => {
        this.active = true;
      })
      .onBlur((): void => {
        this.active = false;
      })
      .onHover((isHover: boolean): void => {
        this.active = isHover;
      })
      .onClick((): void => {
        if (this.dimmed) {
          return;
        }
        const cb = this.onPick;
        if (cb !== null) {
          cb();
        }
      })
  }
}

/**
 * 海报墙页面：媒体库（TvWallRoute）/ 跨库类型墙（TvWallRoute.kindSource）/
 * 合集（TvCollectionRoute）/ 首页一行的「查看全部」（TvRowWallRoute）四路复用。
 */
@ComponentV2
export struct TvLibraryWall {
  /** 所属路由实例（注册页面级返回处理用：先收面板再退页） */
  @Param route: TvRoute = new TvRoute('wall');
  @Param libraryId: number = 0;
  /** kind 跨库墙的媒体类型（movie/tv）；单库墙为空串 */
  @Param kindSource: string = '';
  @Param collectionId: number = 0;
  /** 行墙数据源形状：lib:/col:/favorites:/genre:（与首页行取数同构） */
  @Param sourceKey: string = '';
  @Param title: string = '';

  /** 响应式状态（@Local）：build 依赖这些 */
  @Local loading: boolean = true;
  @Local failed: string | null = null;
  @Local total: number | null = null;
  @Local facets: LibraryFacetsView | null = null;
  @Local indexEntries: TvWallIndexEntry[] = [];
  @Local prefs: TvWallPrefs = new TvWallPrefs();
  @Local backdropUrl: string = '';
  @Local panelOpen: boolean = false;
  @Local hudVisible: boolean = false;
  @Local hudTitle: string = '';
  @Local hudDetail: string = '';
  @Local cellWidth: number = 218;
  @Local startOffset: number = 0;
  @Local focusedItemId: number = -1;

  /** 非响应式状态 */
  private readonly wallSource: TvWallDataSource = new TvWallDataSource();
  private readonly wallScroller: Scroller = new Scroller();
  /** 焦点键后缀：同一面墙可能叠多层（墙 A 上开墙 B），key 不能撞 */
  private readonly salt: string = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  private hasMore: boolean = true;
  private loadingMore: boolean = false;
  private loadingPrev: boolean = false;
  private generation: number = 0;
  private quickSteps: number = 0;
  private lastMoveAt: number = 0;
  private firstVisibleIndex: number = 0;
  private backdropTimer: number = -1;
  private hudTimer: number = -1;
  private panelFocusTimer: number = -1;
  private gridFocusTimer: number = -1;

  aboutToAppear(): void {
    TvUiState.shared.registerRouteBack(this.route, (): boolean => this.handlePanelBack());
    const key: string = this.wallKey();
    if (key !== '') {
      TvUiState.shared.wallPrefs(key)
        .then((prefs: TvWallPrefs): void => {
          if (this.sortKeys().indexOf(prefs.sort) < 0) {
            prefs.sort = this.defaultSort();
          }
          this.prefs = prefs;
          this.reload();
        })
        .catch((): void => {
          this.reload();
        });
    } else {
      this.reload();
    }
  }

  aboutToDisappear(): void {
    TvUiState.shared.unregisterRouteBack(this.route);
    if (this.backdropTimer >= 0) {
      clearTimeout(this.backdropTimer);
      this.backdropTimer = -1;
    }
    if (this.hudTimer >= 0) {
      clearTimeout(this.hudTimer);
      this.hudTimer = -1;
    }
    if (this.panelFocusTimer >= 0) {
      clearTimeout(this.panelFocusTimer);
      this.panelFocusTimer = -1;
    }
    if (this.gridFocusTimer >= 0) {
      clearTimeout(this.gridFocusTimer);
      this.gridFocusTimer = -1;
    }
  }

  // MARK: - 布局

  build() {
    Stack() {
      // 背景：选中条目剧照的放大模糊版，交叉淡入
      Stack() {
        TvStageBackdrop({ imageUrl: this.backdropUrl })
      }
      .width('100%')
      .height('100%')
      .blur(16)

      // 压暗一层，海报在上面够突出
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.35)')

      // 内容：面板开着时收起来（焦点不可达，方向键不会掉进面板后面的网格）
      Column() {
        this.Header()
        this.Body()
      }
      .width('100%')
      .height('100%')
      .visibility(this.panelOpen ? Visibility.None : Visibility.Visible)

      if (this.railVisible()) {
        this.Rail()
      }

      if (this.hudVisible && !this.panelOpen) {
        this.Hud()
      }

      if (this.panelOpen) {
        this.PanelScrim()
        this.Panel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
  }

  /** 标题行：大标题 + 条件摘要与总数 + 「排序与筛选」 */
  @Builder
  private Header() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .maxLines(1)
        if (this.summaryText() !== null) {
          Text(this.summaryText() ?? '')
            .fontSize(16)
            .fontColor(TvColors.textMuted)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.canFilter()) {
        TvPillButton({
          label: `排序与筛选 · ${this.sortLabel(this.prefs.sort)}`,
          focusKey: this.filterKey(),
          onActivate: (): void => {
            this.openPanel();
          }
        })
      }
    }
    .width('100%')
    .padding({ left: TvMetrics.edge, right: TvMetrics.edge, top: 26, bottom: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /** 网格 / 加载中 / 失败 / 空态 */
  @Builder
  private Body() {
    if (this.loading) {
      Stack() {
        LoadingProgress()
          .width(52)
          .height(52)
          .color(TvColors.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
    } else if (this.failed !== null) {
      Stack() {
        TvStateView({
          symbol: $r('sys.symbol.wifi'),
          title: '加载失败',
          message: this.failed,
          actionTitle: '重试',
          defaultFocusAction: true,
          onAction: (): void => {
            this.reload();
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
    } else if (this.wallSource.totalCount() === 0) {
      Stack() {
        this.EmptyState()
      }
      .width('100%')
      .layoutWeight(1)
    } else {
      this.WallGrid()
    }
  }

  /** 5 列海报网格：海报下不挂字，选中那格的底部浮出「片名 · 年份」暗带 */
  @Builder
  private WallGrid() {
    Grid(this.wallScroller) {
      LazyForEach(this.wallSource, (item: TvWallItem) => {
        GridItem() {
          TvPosterCardItem({
            item: item,
            cellWidth: this.cellWidth,
            focusKey: this.cardKey(item.itemId),
            onOpen: (): void => {
              this.openItem(item);
            },
            onCardFocus: (): void => {
              this.onCardFocus(item);
            }
          })
        }
      }, (item: TvWallItem) => item.key)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
    .columnsGap(TvMetrics.cardGap)
    .rowsGap(TvMetrics.rowGap)
    .cachedCount(2)
    .padding({ left: TvMetrics.edge, right: TvMetrics.edge, bottom: 60 })
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .fadingEdge(false)
    .onScrollIndex((first: number, last: number): void => {
      this.onGridScroll(first, last);
    })
    .onReachEnd((): void => {
      this.loadMore();
    })
    .onAreaChange((_old: Area, area: Area) => {
      this.measureCells(area);
    })
  }

  /** 空态：没加条件 = 真的没内容；加了条件 = 给一条「清除全部条件」的出路 */
  @Builder
  private EmptyState() {
    if (this.picksActive() || this.prefs.unwatched) {
      TvStateView({
        symbol: $r('sys.symbol.film'),
        title: '没有符合条件的影片',
        message: this.emptyMessage(),
        actionTitle: '清除全部条件',
        defaultFocusAction: true,
        onAction: (): void => {
          this.clearAll();
        }
      })
    } else {
      TvStateView({
        symbol: $r('sys.symbol.film'),
        title: '这里还没有内容'
      })
    }
  }

  /** 右缘索引条：A–Z / 年份 / 评分档，空档压暗；当前所在档白字 */
  @Builder
  private Rail() {
    Column() {
      ForEach(this.indexEntries, (entry: TvWallIndexEntry) => {
        TvWallRailButton({
          label: entry.label,
          small: this.railSmall(),
          entryHeight: this.railEntryHeight(),
          dimmed: entry.count === 0,
          current: entry.key === this.railCurrentKey(),
          focusKey: `tv_wall_${this.salt}_rail_${entry.key}`,
          onPick: (): void => {
            this.jump(entry);
          }
        })
      }, (entry: TvWallIndexEntry) => entry.key)
    }
    .padding({ top: 10, bottom: 10 })
    .position({ x: '100%', y: '50%' })
    .markAnchor({ x: '100%', y: '50%' })
    .offset({ x: -5 })
  }

  /** 快速滚动时屏幕中央的定位提示（「2015 · 第 1204 部 / 共 3000 部」） */
  @Builder
  private Hud() {
    Column({ space: 10 }) {
      Text(this.hudTitle)
        .fontSize(this.hudTitle.length > 3 ? 44 : 80)
        .fontWeight(FontWeight.Bold)
        .fontColor(TvColors.text)
        .maxLines(1)
      Text(this.hudDetail)
        .fontSize(20)
        .fontColor(TvColors.textMuted)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .constraintSize({ minWidth: 260, minHeight: 170 })
    .padding({ left: 40, right: 40, top: 20, bottom: 20 })
    .borderRadius(32)
    .backgroundColor('rgba(16, 18, 24, 0.84)')
    .hitTestBehavior(HitTestMode.None)
  }

  /** 面板底罩：点一下收起 */
  @Builder
  private PanelScrim() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0, 0, 0, 0.55)')
      .onClick((): void => {
        this.closePanel();
      })
  }

  /** 排序与筛选面板：排序 / 只看没看过的 / 类型 / 年代 / 画质（每项带命中数） */
  @Builder
  private Panel() {
    Column() {
      Text('排序与筛选')
        .fontSize(22)
        .fontWeight(600)
        .fontColor(TvColors.text)
        .margin({ bottom: 10 })

      List({ space: 2 }) {
        ForEach(this.panelRows(), (row: TvWallRow) => {
          ListItem() {
            if (row.kind === 'header') {
              Text(row.label)
                .fontSize(13)
                .fontWeight(600)
                .fontColor(TvColors.textFaint)
                .padding({ left: 20, top: 14, bottom: 6 })
                .width('100%')
            } else {
              TvWallOptionRow({
                label: row.label,
                countText: row.countText,
                selected: row.selected,
                dimmed: row.dimmed,
                focusKey: row.key,
                onPick: row.onPick
              })
            }
          }
        }, (row: TvWallRow) => row.key)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .fadingEdge(false)
    }
    .width(480)
    .height(620)
    .padding({ left: 20, right: 20, top: 22, bottom: 18 })
    .borderRadius(24)
    .backgroundColor('rgba(14, 16, 22, 0.95)')
    .border({ width: 1, color: TvColors.line })
  }

  // MARK: - 模式与键

  /** 四路复用的数据源模式 */
  private mode(): string {
    if (this.sourceKey !== '') {
      return 'rowWall';
    }
    if (this.collectionId > 0) {
      return 'collection';
    }
    if (this.kindSource !== '') {
      return 'kind';
    }
    return 'library';
  }

  /** 排序与筛选记忆的存储键；行墙没有面板，不记 */
  private wallKey(): string {
    const mode: string = this.mode();
    if (mode === 'library') {
      return `${this.libraryId}`;
    }
    if (mode === 'kind') {
      return `kind_${this.kindSource}`;
    }
    if (mode === 'collection') {
      return `col_${this.collectionId}`;
    }
    return '';
  }

  private sortKeys(): string[] {
    if (this.mode() === 'collection') {
      return ['collection', 'added_at', 'release_date', 'rating', 'title'];
    }
    return ['added_at', 'release_date', 'rating', 'title'];
  }

  private defaultSort(): string {
    return this.mode() === 'collection' ? 'collection' : 'added_at';
  }

  private canFilter(): boolean {
    return this.mode() !== 'rowWall';
  }

  private cardKey(itemId: number): string {
    return `tv_wall_${this.salt}_item_${itemId}`;
  }

  private filterKey(): string {
    return `tv_wall_${this.salt}_filter`;
  }

  private isReversed(): boolean {
    const direction: WallSortDirection | null = WallSortDirections.of(this.prefs.sort);
    if (direction === null) {
      return false;
    }
    return direction.isReversed(this.prefs.order.length === 0 ? null : this.prefs.order);
  }

  private orderParam(): string | undefined {
    const direction: WallSortDirection | null = WallSortDirections.of(this.prefs.sort);
    if (direction === null) {
      return undefined;
    }
    return direction.orderParam(this.isReversed()) ?? undefined;
  }

  private sortLabel(sort: string): string {
    if (sort === 'collection') {
      return '合集顺序';
    }
    return HomeRows.preset(sort).short(this.isReversed());
  }

  // MARK: - 条件与文案

  private picksActive(): boolean {
    return this.prefs.genre !== null || this.prefs.decade !== null || this.prefs.resolution !== null;
  }

  private genreTitle(): string {
    const facets: LibraryFacetsView | null = this.facets;
    if (facets !== null && this.prefs.genre !== null) {
      for (const facet of facets.genres) {
        if (facet.value === this.prefs.genre) {
          return facet.label;
        }
      }
    }
    return '类型';
  }

  private qualityTitle(): string {
    const value: string | null = this.prefs.resolution;
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

  /** 标题旁的条件摘要（「科幻 · 2010 年代 · 未看 · 516 部」） */
  private summaryText(): string | null {
    const parts: string[] = this.conditionParts();
    if (this.total !== null) {
      parts.push(`${this.total} 部`);
    }
    return parts.length === 0 ? null : parts.join(' · ');
  }

  private conditionParts(): string[] {
    const parts: string[] = [];
    if (this.prefs.genre !== null) {
      parts.push(this.genreTitle());
    }
    if (this.prefs.decade !== null) {
      parts.push(TvWallIndex.decadeTitle(this.prefs.decade));
    }
    if (this.prefs.resolution !== null) {
      parts.push(this.qualityTitle());
    }
    if (this.prefs.unwatched) {
      parts.push('未看');
    }
    return parts;
  }

  private emptyMessage(): string {
    const parts: string[] = this.conditionParts();
    if (parts.length === 0) {
      return '换一个条件试试';
    }
    return `「${parts.join(' · ')}」下没有影片，换一个条件试试`;
  }

  /** 分辨率在电视上按习惯叫法：2160p 写「4K」 */
  private resolutionLabel(facet: FacetValueView): string {
    return facet.value === '2160p' ? '4K' : facet.label;
  }

  // MARK: - 取数

  private reload(): void {
    this.generation += 1;
    const gen: number = this.generation;
    this.loading = true;
    this.failed = null;
    this.hasMore = true;
    this.loadingMore = false;
    this.loadingPrev = false;
    this.startOffset = 0;
    this.focusedItemId = -1;
    this.quickSteps = 0;
    this.indexEntries = [];
    this.backdropUrl = '';
    this.hudVisible = false;
    this.wallSource.setItems([]);
    if (this.mode() === 'library') {
      this.loadFacets(gen);
      this.loadIndex(gen);
    }
    this.fetchPage(0, WALL_PAGE_SIZE)
      .then((page: TvWallPage): void => {
        if (gen !== this.generation) {
          return;
        }
        this.wallSource.setItems(page.items);
        this.startOffset = 0;
        if (page.total !== null) {
          this.total = page.total;
        }
        this.hasMore = page.items.length >= WALL_PAGE_SIZE;
        this.loading = false;
        this.focusFirstCard();
      })
      .catch((error: BusinessError): void => {
        if (gen !== this.generation) {
          return;
        }
        this.loading = false;
        const message: string | undefined = error.message;
        this.failed = message !== undefined && message.length > 0 ? message : '加载失败';
      });
  }

  /** 筛选面板的候选值与计数（每一维排除自身条件后算；画质维度要 tier=all 才有） */
  private loadFacets(gen: number): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const prefs: TvWallPrefs = this.prefs;
    const g: string | undefined = prefs.genre ?? undefined;
    const d: string | undefined = prefs.decade ?? undefined;
    const w: string | undefined = prefs.unwatched ? 'unwatched' : undefined;
    const res: string | undefined =
      prefs.resolution !== null && prefs.resolution !== 'hdr' ? prefs.resolution : undefined;
    const hdr: boolean | undefined = prefs.resolution === 'hdr' ? true : undefined;
    api.libraryItemsFacets(this.libraryId, 'all', g, undefined, d, w,
      undefined, undefined, undefined, res, hdr)
      .then((view: LibraryFacetsView): void => {
        if (gen !== this.generation) {
          return;
        }
        this.facets = view;
        this.total = view.total;
      })
      .catch((): void => {
      });
  }

  /** 索引条原始数据（按标题/上映/评分排序才有） */
  private loadIndex(gen: number): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || !TvWallIndex.supports(this.prefs.sort)) {
      return;
    }
    const prefs: TvWallPrefs = this.prefs;
    const g: string | undefined = prefs.genre ?? undefined;
    const d: string | undefined = prefs.decade ?? undefined;
    const w: string | undefined = prefs.unwatched ? 'unwatched' : undefined;
    const res: string | undefined =
      prefs.resolution !== null && prefs.resolution !== 'hdr' ? prefs.resolution : undefined;
    const hdr: boolean | undefined = prefs.resolution === 'hdr' ? true : undefined;
    api.uiLibraryItemsIndex(this.libraryId, prefs.sort, this.orderParam(), g, undefined, d, w,
      undefined, undefined, undefined, res, hdr)
      .then((raw: LibraryIndexEntryView[]): void => {
        if (gen !== this.generation) {
          return;
        }
        this.indexEntries = TvWallIndex.entries(prefs.sort, this.isReversed(), raw);
      })
      .catch((): void => {
      });
  }

  /** 按模式取一页（offset 是整份结果里的位置，窗口式分页的核心） */
  private fetchPage(offset: number, limit: number): Promise<TvWallPage> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return Promise.reject<TvWallPage>(new Error('未连接服务器'));
    }
    const mode: string = this.mode();
    if (mode === 'library' || mode === 'kind') {
      const prefs: TvWallPrefs = this.prefs;
      if (mode === 'library') {
        const g: string | undefined = prefs.genre ?? undefined;
        const d: string | undefined = prefs.decade ?? undefined;
        const w: string | undefined = prefs.unwatched ? 'unwatched' : undefined;
        const res: string | undefined =
          prefs.resolution !== null && prefs.resolution !== 'hdr' ? prefs.resolution : undefined;
        const hdr: boolean | undefined = prefs.resolution === 'hdr' ? true : undefined;
        return api.libraryItemsList(this.libraryId, prefs.sort, this.orderParam(), limit, offset,
          undefined, g, undefined, d, w, undefined, undefined, undefined, res, hdr)
          .then((views: LibraryItemView[]): TvWallPage => this.pageOf(views, null));
      }
      return api.uiLibraryKindItems(this.kindSource, prefs.sort, this.orderParam(), limit, offset,
        undefined, undefined, undefined, prefs.unwatched ? 'unwatched' : undefined)
        .then((views: LibraryItemView[]): TvWallPage => this.pageOf(views, null));
    }
    if (mode === 'collection') {
      const own: boolean = this.prefs.sort === 'collection';
      const sort: string | undefined = own ? undefined : this.prefs.sort;
      const order: string | undefined = own ? undefined : this.orderParam();
      return api.collectionItemsList(this.collectionId, limit, offset, sort, order)
        .then((views: LibraryItemView[]): TvWallPage => this.pageOf(views, null));
    }
    return this.fetchRowWallPage(api, offset, limit);
  }

  /** 行墙取数：sourceKey 与首页那一行同一套参数，进来看到的顺序和行里一致 */
  private fetchRowWallPage(api: MovieClawApi, offset: number, limit: number): Promise<TvWallPage> {
    const parts: string[] = this.sourceKey.split(':');
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
        .then((views: LibraryItemView[]): TvWallPage => this.pageOf(views, null));
    }
    if (parts[0] === 'col' && parts.length >= 4) {
      const id: number = Number(parts[1]);
      const sort: string = parts[2];
      const reversed: boolean = parts[3] === 'true';
      const direction: WallSortDirection | null = WallSortDirections.of(sort);
      const order: string | undefined = direction === null
        ? undefined : (direction.orderParam(reversed) ?? undefined);
      return api.collectionItemsList(id, limit, offset, sort, order)
        .then((views: LibraryItemView[]): TvWallPage => this.pageOf(views, null));
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
        .then((view: FavoritesView): TvWallPage => this.pageOf(view.items, view.total));
    }
    if (parts[0] === 'genre' && parts.length >= 3) {
      const kind: string = parts[1];
      const value: string = parts[2];
      // 类型格子墙：按 TMDB 类型筛好的跨库墙，最近添加在前
      return api.uiLibraryKindItems(kind, 'added_at', undefined, limit, offset, value)
        .then((views: LibraryItemView[]): TvWallPage => this.pageOf(views, null));
    }
    return Promise.reject<TvWallPage>(new Error('未知的数据源'));
  }

  /** 服务端视图 → 墙上的轻量格（收藏条目与库存条目字段同名，直接走同一映射） */
  private pageOf(views: LibraryItemView[], total: number | null): TvWallPage {
    const origin: string = AppModel.origin();
    const items: TvWallItem[] = [];
    for (const view of views) {
      items.push(TvWallItem.fromView(view, origin, this.cellWidth));
    }
    return new TvWallPage(items, total);
  }

  /** 离窗口底还有三排就取下一页：按住方向键滚下去时，下一页已经在路上 */
  private loadMore(): void {
    if (this.loading || this.failed !== null || this.loadingMore || !this.hasMore) {
      return;
    }
    if (this.total !== null && this.startOffset + this.wallSource.totalCount() >= this.total) {
      this.hasMore = false;
      return;
    }
    const gen: number = this.generation;
    this.loadingMore = true;
    const from: number = this.startOffset + this.wallSource.totalCount();
    this.fetchPage(from, WALL_PAGE_SIZE)
      .then((page: TvWallPage): void => {
        this.loadingMore = false;
        if (gen !== this.generation) {
          return;
        }
        if (page.items.length === 0) {
          this.hasMore = false;
          return;
        }
        this.wallSource.append(page.items);
        if (page.total !== null) {
          this.total = page.total;
        }
        if (page.items.length < WALL_PAGE_SIZE) {
          this.hasMore = false;
        }
      })
      .catch((): void => {
        this.loadingMore = false;
      });
  }

  /** 往上补一页：补进来后把滚动位置顶回去，原来那几排在屏幕上纹丝不动 */
  private loadPrevious(): void {
    if (this.loading || this.failed !== null || this.loadingPrev || this.startOffset <= 0) {
      return;
    }
    const gen: number = this.generation;
    const prevStart: number = Math.max(0, this.startOffset - WALL_PAGE_SIZE);
    const count: number = this.startOffset - prevStart;
    const keepIndex: number = this.firstVisibleIndex;
    const scroller: Scroller = this.wallScroller;
    this.loadingPrev = true;
    this.fetchPage(prevStart, count)
      .then((page: TvWallPage): void => {
        this.loadingPrev = false;
        if (gen !== this.generation) {
          return;
        }
        if (page.items.length > 0) {
          const added: number = page.items.length;
          this.wallSource.prepend(page.items);
          this.startOffset = prevStart;
          // 等网格按新窗口排好版再把视口顶回去（同一帧里滚，内容高度还是旧的）
          setTimeout((): void => {
            scroller.scrollToIndex(keepIndex + added, false);
          }, 40);
        }
      })
      .catch((): void => {
        this.loadingPrev = false;
      });
  }

  /** 索引条跳转：窗口换成从这一档开始的一页，焦点交给这一档的第一张 */
  private jump(entry: TvWallIndexEntry): void {
    if (entry.offset === null) {
      return;
    }
    const target: number = entry.offset;
    const aligned: number = target - target % WALL_COLUMNS;
    const gen: number = this.generation + 1;
    this.generation = gen;
    this.fetchPage(aligned, WALL_PAGE_SIZE)
      .then((page: TvWallPage): void => {
        if (gen !== this.generation) {
          return;
        }
        this.wallSource.setItems(page.items);
        this.startOffset = aligned;
        this.hasMore = page.items.length >= WALL_PAGE_SIZE;
        if (page.total !== null) {
          this.total = page.total;
        }
        let position: number = target - aligned;
        if (position >= page.items.length) {
          position = page.items.length - 1;
        }
        if (position < 0) {
          return;
        }
        const item: TvWallItem = page.items[position];
        this.showHudAt(entry.title, target);
        const scroller: Scroller = this.wallScroller;
        const itemId: number = item.itemId;
        setTimeout((): void => {
          scroller.scrollToIndex(position, false, ScrollAlign.CENTER);
          this.focusedItemId = itemId;
          TvFocus.request(this.getUIContext(), this.cardKey(itemId));
        }, 60);
      })
      .catch((): void => {
      });
  }

  // MARK: - 焦点与滚动

  private onGridScroll(first: number, last: number): void {
    this.firstVisibleIndex = first;
    if (last >= this.wallSource.totalCount() - WALL_COLUMNS * 3) {
      this.loadMore();
    }
    if (first <= 2 && this.startOffset > 0) {
      this.loadPrevious();
    }
  }

  /** 一张海报获得焦点/被悬浮：快速滚动检测 + 背景防抖 + 两头的窗口续页 */
  private onCardFocus(item: TvWallItem): void {
    this.focusedItemId = item.itemId;
    const now: number = Date.now();
    if (now - this.lastMoveAt < QUICK_STEP_MS) {
      this.quickSteps += 1;
    } else {
      this.quickSteps = 0;
    }
    this.lastMoveAt = now;
    const position: number = this.wallSource.indexOfItem(item.itemId);
    if (position < 0) {
      return;
    }
    const absolute: number = this.startOffset + position;
    if (this.quickSteps >= 2) {
      const title: string | null = this.positionTitle(item, absolute);
      if (title !== null) {
        this.showHudAt(title, absolute);
      }
    }
    this.scheduleBackdrop(item);
    if (position >= this.wallSource.totalCount() - WALL_COLUMNS * 3) {
      this.loadMore();
    }
    if (position < WALL_COLUMNS * 3 && this.startOffset > 0) {
      this.loadPrevious();
    }
  }

  /** 焦点停稳再换背景：按住方向键一路滚过去不逐张闪 */
  private scheduleBackdrop(item: TvWallItem): void {
    if (this.backdropTimer >= 0) {
      clearTimeout(this.backdropTimer);
      this.backdropTimer = -1;
    }
    const delay: number = this.quickSteps >= 2 ? 450 : 220;
    const itemId: number = item.itemId;
    const url: string = item.backdropUrl;
    this.backdropTimer = setTimeout((): void => {
      this.backdropTimer = -1;
      if (this.focusedItemId === itemId) {
        this.backdropUrl = url;
      }
    }, delay);
  }

  /** 中央定位提示；1.2 秒自动收 */
  private showHudAt(title: string, position: number): void {
    this.hudTitle = title;
    this.hudDetail = this.total !== null
      ? `第 ${position + 1} 部 / 共 ${this.total} 部`
      : `第 ${position + 1} 部`;
    this.hudVisible = true;
    if (this.hudTimer >= 0) {
      clearTimeout(this.hudTimer);
    }
    this.hudTimer = setTimeout((): void => {
      this.hudTimer = -1;
      this.hudVisible = false;
    }, 1200);
  }

  /** 当前所在档的大字：有索引条用档名；按添加时间写「2026 年 8 月」 */
  private positionTitle(item: TvWallItem, absolute: number): string | null {
    if (this.indexEntries.length > 0) {
      const entry: TvWallIndexEntry | null = TvWallIndex.entryAt(absolute, this.indexEntries);
      return entry === null ? null : entry.title;
    }
    if (this.prefs.sort === 'added_at') {
      return item.addedMonth;
    }
    return null;
  }

  private measureCells(area: Area): void {
    const width: Length = area.width;
    if (typeof width !== 'number' || width <= 0) {
      return;
    }
    const cell: number = (width - TvMetrics.edge * 2 - TvMetrics.cardGap * (WALL_COLUMNS - 1)) / WALL_COLUMNS;
    if (cell > 0 && Math.abs(cell - this.cellWidth) > 0.5) {
      this.cellWidth = cell;
    }
  }

  /** 首张海报拿焦点（只在顶层路由上：底下还压着别的页时不抢） */
  private focusFirstCard(): void {
    if (this.panelOpen || this.wallSource.totalCount() === 0) {
      return;
    }
    const ui: TvUiState = TvUiState.shared;
    if (ui.routes.length === 0 || ui.routes[ui.routes.length - 1] !== this.route) {
      return;
    }
    const first: TvWallItem = this.wallSource.getData(0);
    if (this.gridFocusTimer >= 0) {
      clearTimeout(this.gridFocusTimer);
    }
    this.gridFocusTimer = setTimeout((): void => {
      this.gridFocusTimer = -1;
      TvFocus.request(this.getUIContext(), this.cardKey(first.itemId));
    }, 150);
  }

  private openItem(item: TvWallItem): void {
    const libraryId: number = item.libraryId > 0
      ? item.libraryId
      : (this.mode() === 'library' ? this.libraryId : 0);
    if (libraryId <= 0) {
      return;
    }
    TvUiState.shared.pushRoute(new TvDetailRoute(libraryId, item.itemId));
  }

  // MARK: - 索引条辅助

  private railVisible(): boolean {
    return this.indexEntries.length > 0 && !this.loading && this.failed === null
      && this.wallSource.totalCount() > 0 && !this.panelOpen;
  }

  /** 条上各档高度：档多压一压，档少放宽 */
  private railEntryHeight(): number {
    const count: number = Math.max(1, this.indexEntries.length);
    return Math.max(16, Math.min(26, Math.floor(640 / count)));
  }

  /** 有多位数档（年份）时整条用小一号的字与更宽的格 */
  private railSmall(): boolean {
    for (const entry of this.indexEntries) {
      if (entry.label.length > 2) {
        return true;
      }
    }
    return false;
  }

  /** 当前所在的档（最近获焦那张落在哪一档） */
  private railCurrentKey(): string {
    const position: number = this.wallSource.indexOfItem(this.focusedItemId);
    if (position >= 0) {
      const entry: TvWallIndexEntry | null =
        TvWallIndex.entryAt(this.startOffset + position, this.indexEntries);
      if (entry !== null) {
        return entry.key;
      }
      return '';
    }
    for (const entry of this.indexEntries) {
      if (entry.count > 0) {
        return entry.key;
      }
    }
    return '';
  }

  // MARK: - 排序与筛选面板

  private openPanel(): void {
    this.panelOpen = true;
    if (this.panelFocusTimer >= 0) {
      clearTimeout(this.panelFocusTimer);
    }
    this.panelFocusTimer = setTimeout((): void => {
      this.panelFocusTimer = -1;
      const rows: TvWallRow[] = this.panelRows();
      for (const row of rows) {
        if (row.kind === 'option') {
          TvFocus.request(this.getUIContext(), row.key);
          return;
        }
      }
    }, 80);
  }

  private closePanel(): void {
    this.panelOpen = false;
    if (this.panelFocusTimer >= 0) {
      clearTimeout(this.panelFocusTimer);
    }
    this.panelFocusTimer = setTimeout((): void => {
      this.panelFocusTimer = -1;
      if (this.canFilter()) {
        TvFocus.request(this.getUIContext(), this.filterKey());
      }
    }, 60);
  }

  /** 返回键分级的第一站：面板开着先收面板（经 TvUiState.registerRouteBack 注册） */
  private handlePanelBack(): boolean {
    if (this.panelOpen) {
      this.closePanel();
      return true;
    }
    return false;
  }

  /** 面板全部行（小节标题 + 选项），键稳定供 ForEach 复用与 requestFocus 定位 */
  private panelRows(): TvWallRow[] {
    const rows: TvWallRow[] = [];
    if (!this.canFilter()) {
      return rows;
    }
    const mode: string = this.mode();
    const prefs: TvWallPrefs = this.prefs;
    const salt: string = this.salt;

    rows.push(TvWallRow.header(`${salt}_h_sort`, '排序'));
    const sorts: string[] = this.sortKeys();
    for (const sort of sorts) {
      rows.push(TvWallRow.option(
        `${salt}_opt_sort_${sort}`,
        this.sortLabel(sort),
        null,
        prefs.sort === sort,
        false,
        (): void => {
          this.changeSort(sort);
        }));
    }

    if (mode === 'library' || mode === 'kind') {
      rows.push(TvWallRow.header(`${salt}_h_watch`, '观看状态'));
      rows.push(TvWallRow.option(
        `${salt}_opt_unwatched`,
        '只看没看过的',
        null,
        prefs.unwatched,
        false,
        (): void => {
          this.toggleUnwatched();
        }));
    }

    if (mode === 'library') {
      const facets: LibraryFacetsView | null = this.facets;
      if (facets !== null) {
        rows.push(TvWallRow.header(`${salt}_h_genre`, '类型'));
        rows.push(TvWallRow.option(
          `${salt}_opt_g_all`,
          '全部',
          null,
          prefs.genre === null,
          false,
          (): void => {
            this.pickGenre(null);
          }));
        for (const facet of facets.genres) {
          const value: string = facet.value;
          rows.push(TvWallRow.option(
            `${salt}_opt_g_${value}`,
            facet.label,
            `${facet.count} 部`,
            prefs.genre === value,
            facet.count === 0 && prefs.genre !== value,
            (): void => {
              this.pickGenre(value);
            }));
        }

        rows.push(TvWallRow.header(`${salt}_h_decade`, '年代'));
        rows.push(TvWallRow.option(
          `${salt}_opt_d_all`,
          '全部',
          null,
          prefs.decade === null,
          false,
          (): void => {
            this.pickDecade(null);
          }));
        for (const facet of facets.decades) {
          const value: string = facet.value;
          rows.push(TvWallRow.option(
            `${salt}_opt_d_${value}`,
            TvWallIndex.decadeTitle(value),
            `${facet.count} 部`,
            prefs.decade === value,
            facet.count === 0 && prefs.decade !== value,
            (): void => {
              this.pickDecade(value);
            }));
        }

        rows.push(TvWallRow.header(`${salt}_h_quality`, '画质'));
        rows.push(TvWallRow.option(
          `${salt}_opt_q_all`,
          '全部',
          null,
          prefs.resolution === null,
          false,
          (): void => {
            this.pickQuality(null);
          }));
        for (const facet of facets.resolutions) {
          const value: string = facet.value;
          rows.push(TvWallRow.option(
            `${salt}_opt_q_${value}`,
            this.resolutionLabel(facet),
            `${facet.count} 部`,
            prefs.resolution === value,
            facet.count === 0 && prefs.resolution !== value,
            (): void => {
              this.pickQuality(value);
            }));
        }
        for (const facet of facets.hdr) {
          if (facet.value !== '1') {
            continue;
          }
          rows.push(TvWallRow.option(
            `${salt}_opt_q_hdr`,
            facet.label,
            `${facet.count} 部`,
            prefs.resolution === 'hdr',
            facet.count === 0 && prefs.resolution !== 'hdr',
            (): void => {
              this.pickQuality('hdr');
            }));
        }
      }
    }

    if (this.picksActive()) {
      rows.push(TvWallRow.header(`${salt}_h_clear`, ''));
      rows.push(TvWallRow.option(
        `${salt}_opt_clear`,
        '清除筛选',
        null,
        false,
        false,
        (): void => {
          this.clearPicks();
        }));
    }

    rows.push(TvWallRow.header(`${salt}_h_done`, ''));
    rows.push(TvWallRow.option(
      `${salt}_opt_done`,
      '完成',
      null,
      false,
      false,
      (): void => {
        this.closePanel();
      }));
    return rows;
  }

  // MARK: - 条件变更（都走 mutatePrefs：换实例触发重渲 + 尽力持久化 + 整墙刷新）

  private changeSort(sort: string): void {
    if (this.prefs.sort === sort) {
      return;
    }
    this.mutatePrefs((prefs: TvWallPrefs): void => {
      prefs.sort = sort;
    });
    this.reload();
  }

  private toggleUnwatched(): void {
    this.mutatePrefs((prefs: TvWallPrefs): void => {
      prefs.unwatched = !prefs.unwatched;
    });
    this.reload();
  }

  private pickGenre(value: string | null): void {
    this.mutatePrefs((prefs: TvWallPrefs): void => {
      prefs.genre = value;
    });
    this.reload();
  }

  private pickDecade(value: string | null): void {
    this.mutatePrefs((prefs: TvWallPrefs): void => {
      prefs.decade = value;
    });
    this.reload();
  }

  private pickQuality(value: string | null): void {
    this.mutatePrefs((prefs: TvWallPrefs): void => {
      prefs.resolution = value;
    });
    this.reload();
  }

  /** 面板里的「清除筛选」：只清类型/年代/画质，保留排序与「只看没看过的」 */
  private clearPicks(): void {
    this.mutatePrefs((prefs: TvWallPrefs): void => {
      prefs.genre = null;
      prefs.decade = null;
      prefs.resolution = null;
    });
    this.reload();
  }

  /** 筛空页上的「清除全部条件」：连「只看没看过的」一起清 */
  private clearAll(): void {
    this.mutatePrefs((prefs: TvWallPrefs): void => {
      prefs.genre = null;
      prefs.decade = null;
      prefs.resolution = null;
      prefs.unwatched = false;
    });
    this.reload();
  }

  private mutatePrefs(action: (prefs: TvWallPrefs) => void): void {
    const next: TvWallPrefs = new TvWallPrefs();
    next.sort = this.prefs.sort;
    next.order = this.prefs.order;
    next.unwatched = this.prefs.unwatched;
    next.genre = this.prefs.genre;
    next.decade = this.prefs.decade;
    next.resolution = this.prefs.resolution;
    next.watch = this.prefs.watch;
    action(next);
    this.prefs = next;
    const key: string = this.wallKey();
    if (key !== '') {
      TvUiState.shared.saveWallPrefs(key, next);
    }
  }
}

/**
 * 网格里的海报格：包一层组件让 LazyForEach 的 itemGenerator 保持极简，
 * 焦点回调（onFocusGained 只在激活沿上报 true）挂在这层。
 */
@ComponentV2
struct TvPosterCardItem {
  @Param item: TvWallItem = new TvWallItem('', 0, 0, '', null, '', '', null);
  @Param cellWidth: number = 218;
  @Param focusKey: string = '';
  @Param onOpen: (() => void) | null = null;
  @Param onCardFocus: (() => void) | null = null;

  build() {
    TvPosterCard({
      title: this.item.title,
      subtitle: this.item.year === null ? null : `${this.item.year}`,
      imageUrl: this.item.posterUrl,
      cardWidth: this.cellWidth,
      caption: TvCardCaption.band,
      focusKey: this.focusKey,
      onActivate: (): void => {
        const cb = this.onOpen;
        if (cb !== null) {
          cb();
        }
      },
      onFocusGained: (active: boolean): void => {
        if (active) {
          const cb = this.onCardFocus;
          if (cb !== null) {
            cb();
          }
        }
      }
    })
  }
}
