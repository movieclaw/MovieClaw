/**
 * 车机海报墙（US4，对齐 TV 端 tv/library/TvLibraryWall.ets 的触屏裁剪版）：
 * - 海报网格：列数按内容宽弹性计算（1260vp 画布上 5 列、格宽约 198vp，全部触控目标 ≥48vp）；
 *   图下常显「片名 · 年份」（触屏没有获焦浮现，信息常显符合 3 秒注视原则）。
 * - 背景 = 最近按下的那张海报对应剧照的放大模糊版（触屏无焦点，以按压代替选中，防抖不逐张闪）。
 * - 标题行：大标题 + 条件摘要与总数 + 「排序与筛选」大按钮（排序 added_at/release_date/rating/title、
 *   「只看没看过的」、类型/年代/画质三档每项带命中数，0 部压暗；记忆经 CarUiState 以 car_wall_ 前缀持久化）。
 * - 筛选面板是右侧抽屉（大触控行 ≥48vp），点底罩或「完成」收起；返回键先收抽屉再退页。
 * - 大库翻找：窗口式分页（一页 = 列数 × 12、离底三排取下一页、往回走补上一页），
 *   不整库加载。TV 端的右缘索引条/中央定位提示是遥控器方向键的配套（快速滚动定位），触屏直滚直点，不搬。
 * - 首页「查看全部」行墙（CarRowWallRoute 的 lib/col/favorites/genre 四种 sourceKey）与
 *   合集页（CarCollectionRoute）复用本组件：行墙没有排序与筛选，合集多一档「合集顺序」。
 *
 * 另含 CarLibraryTab：媒体库页签（库卡 + 合集卡网格，点按进对应墙）。
 */
import { MovieClawApi } from '../../api/Endpoints';
import {
  CollectionView,
  FacetValueView,
  FavoritesView,
  LibraryFacetsView,
  LibraryItemView,
  LibraryView,
  PersonCreditView,
  PersonView
} from '../../api/Models';
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { HomeRows, WallSortDirection, WallSortDirections } from '../../library/HomeRows';
import { RemoteImage } from '../../common/RemoteImage';
import {
  CarCollectionRoute,
  CarDetailRoute,
  CarRoute,
  CarUiState,
  CarWallPrefs,
  CarWallRoute
} from '../model/CarUiState';
import {
  CarLibraryCard,
  CarPillButton,
  CarPosterCard,
  CarStateView
} from '../components/CarCards';
import { CarArt } from '../theme/CarTheme';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';
import { CarMotion } from '../theme/CarTheme';
import { CarType } from '../theme/CarTheme';

/** 网格格最小宽（vp）：列数按内容宽从此往上算 */
const WALL_MIN_CELL: number = 186;
/** 列数上下限 */
const WALL_MAX_COLUMNS: number = 9;
const WALL_MIN_COLUMNS: number = 4;
/** 墙背景剧照的请求宽（px）：模糊背景不需要全分辨率 */
const WALL_BACKDROP_PX: number = 960;
/** 按压换背景的防抖（毫秒） */
const WALL_BACKDROP_DEBOUNCE_MS: number = 200;

/** 墙上一格的轻量模型（LazyForEach 数据源持有，不参与观察） */
export class CarWallItem {
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

  static fromView(view: LibraryItemView, origin: string, cellWidth: number): CarWallItem {
    const poster: string = CarWallItem.sized(
      ImageUrls.resolve(origin, view.poster_url ?? view.backdrop_url ?? null, null),
      CarArt.pxWidth(cellWidth));
    const backdropBase: string | null = ImageUrls.resolve(origin, view.backdrop_url ?? view.poster_url ?? null, null);
    const backdrop: string = backdropBase === null ? '' : CarWallItem.sized(backdropBase, WALL_BACKDROP_PX);
    return new CarWallItem(
      `w${view.media_item_id}`,
      view.media_item_id,
      view.library_id ?? 0,
      view.title,
      view.year ?? null,
      poster,
      backdrop);
  }

  /** 影人作品墙的一格（peopleShow 的 credit：只有海报，背景也用海报） */
  static fromCredit(credit: PersonCreditView, origin: string, cellWidth: number): CarWallItem {
    const posterBase: string | null = ImageUrls.resolve(origin, credit.poster_url ?? null, null);
    const poster: string = posterBase === null ? '' : CarWallItem.sized(posterBase, CarArt.pxWidth(cellWidth));
    const backdrop: string = posterBase === null ? '' : CarWallItem.sized(posterBase, WALL_BACKDROP_PX);
    return new CarWallItem(
      `w${credit.media_item_id}`,
      credit.media_item_id,
      credit.library_id ?? 0,
      credit.title,
      credit.year ?? null,
      poster,
      backdrop);
  }

  /** 解析好的 URL 再按显示宽度补 &w=（后端按 w 降采样出图） */
  private static sized(url: string | null, px: number): string {
    if (url === null) {
      return '';
    }
    return `${url}${url.includes('?') ? '&' : '?'}w=${px}`;
  }
}

/** 一页取数结果 */
class CarWallPage {
  readonly items: CarWallItem[];
  /** 整份结果共几部；不知道为 null（收藏接口会给） */
  readonly total: number | null;

  constructor(items: CarWallItem[], total: number | null) {
    this.items = items;
    this.total = total;
  }
}

/** 海报墙的 LazyForEach 数据源：整批换 / 尾部追加 / 头部补页 */
class CarWallDataSource implements IDataSource {
  private items: CarWallItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): CarWallItem {
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
  setItems(items: CarWallItem[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  /** 尾部追加一页（向下翻） */
  append(items: CarWallItem[]): void {
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
  prepend(items: CarWallItem[]): void {
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

/** 筛选抽屉里的一行（小节标题 / 选项） */
class CarWallRow {
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

  static header(key: string, label: string): CarWallRow {
    return new CarWallRow(key, 'header', label, null, false, false, null);
  }

  static option(key: string, label: string, countText: string | null, selected: boolean,
    dimmed: boolean, onPick: () => void): CarWallRow {
    return new CarWallRow(key, 'option', label, countText, selected, dimmed, onPick);
  }
}

/** 筛选抽屉的一个选项行：对勾 = 已选；命中数靠右；0 部压暗不可选；整行触控目标 ≥48vp */
@ComponentV2
struct CarWallOptionRow {
  @Param label: string = '';
  @Param countText: string | null = null;
  @Param selected: boolean = false;
  @Param dimmed: boolean = false;
  @Param onPick: (() => void) | null = null;
  @Local pressed: boolean = false;

  build() {
    Row({ space: 12 }) {
      Text(this.selected ? '✓' : '')
        .fontSize(16)
        .fontWeight(700)
        .fontColor(CarColors.accent)
        .width(20)
      Text(this.label)
        .fontSize(CarType.body)
        .fontWeight(this.selected ? 600 : FontWeight.Medium)
        .fontColor(this.selected ? CarColors.text : CarColors.textMuted)
        .maxLines(1)
        .layoutWeight(1)
      if (this.countText !== null) {
        Text(this.countText)
          .fontSize(CarType.footnote)
          .fontColor(CarColors.textFaint)
      }
    }
    .height(52)
    .padding({ left: 16, right: 16 })
    .borderRadius(12)
    .backgroundColor(this.pressed ? CarColors.glassFillHover : Color.Transparent)
    .opacity(this.dimmed ? 0.35 : 1)
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
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
 * 海报墙页面：媒体库（CarWallRoute）/ 跨库类型墙（CarWallRoute.kindSource）/
 * 合集（CarCollectionRoute）/ 首页一行的「查看全部」（CarRowWallRoute）四路复用。
 */
@ComponentV2
export struct CarLibraryWall {
  /** 所属路由实例（注册页面级返回处理用：先收抽屉再退页） */
  @Param route: CarRoute = new CarRoute('wall');
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
  @Local prefs: CarWallPrefs = new CarWallPrefs();
  @Local backdropUrl: string = '';
  @Local panelOpen: boolean = false;
  @Local columns: number = 5;
  @Local cellWidth: number = 198;

  /** 非响应式状态 */
  private readonly wallSource: CarWallDataSource = new CarWallDataSource();
  private readonly wallScroller: Scroller = new Scroller();
  /** ForEach 键后缀：同一面墙可能叠多层（墙 A 上开墙 B），key 不能撞 */
  private readonly salt: string = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  private hasMore: boolean = true;
  private loadingMore: boolean = false;
  private loadingPrev: boolean = false;
  private generation: number = 0;
  private startOffset: number = 0;
  private firstVisibleIndex: number = 0;
  private pressedItemId: number = -1;
  private backdropTimer: number = -1;

  aboutToAppear(): void {
    CarUiState.shared.registerRouteBack(this.route, (): boolean => this.handlePanelBack());
    const key: string = this.wallKey();
    if (key !== '') {
      CarUiState.shared.wallPrefs(key)
        .then((prefs: CarWallPrefs): void => {
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
    CarUiState.shared.unregisterRouteBack(this.route);
    if (this.backdropTimer >= 0) {
      clearTimeout(this.backdropTimer);
      this.backdropTimer = -1;
    }
  }

  // MARK: - 布局

  build() {
    Stack() {
      // 背景：最近按下那张海报对应剧照的放大模糊版
      Stack() {
        RemoteImage({ url: this.backdropUrl, placeholderText: '' })
      }
      .width('100%')
      .height('100%')
      .blur(16)

      // 压暗一层，海报在上面够突出
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.35)')

      // 内容：抽屉开着时收起来（点不到底下的网格）
      Column() {
        this.Header()
        this.Body()
      }
      .width('100%')
      .height('100%')
      .visibility(this.panelOpen ? Visibility.None : Visibility.Visible)

      if (this.panelOpen) {
        this.PanelScrim()
        this.Panel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CarColors.bg)
  }

  /** 标题行：大标题 + 条件摘要与总数 + 「排序与筛选」 */
  @Builder
  private Header() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
          .maxLines(1)
        if (this.summaryText() !== null) {
          Text(this.summaryText() ?? '')
            .fontSize(CarType.footnote)
            .fontColor(CarColors.textMuted)
            .maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.canFilter()) {
        CarPillButton({
          label: `排序与筛选 · ${this.sortLabel(this.prefs.sort)}`,
          onActivate: (): void => {
            this.openPanel();
          }
        })
      }
    }
    .width('100%')
    .padding({ left: CarMetrics.edge, right: CarMetrics.edge, top: 22, bottom: 14 })
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
          .color(CarColors.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
    } else if (this.failed !== null) {
      Stack() {
        CarStateView({
          symbol: $r('sys.symbol.wifi'),
          title: '加载失败',
          message: this.failed,
          actionTitle: '重试',
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

  /** 海报网格：列数按内容宽弹性计算；图下常显「片名 · 年份」 */
  @Builder
  private WallGrid() {
    Grid(this.wallScroller) {
      LazyForEach(this.wallSource, (item: CarWallItem) => {
        GridItem() {
          CarWallGridItem({
            item: item,
            cellWidth: this.cellWidth,
            onOpen: (): void => {
              this.openItem(item);
            },
            onPressed: (): void => {
              this.onCardPressed(item);
            }
          })
        }
      }, (item: CarWallItem) => item.key)
    }
    .columnsTemplate(this.columnsTemplate())
    .columnsGap(CarMetrics.wallGap)
    .rowsGap(CarMetrics.rowGap)
    .cachedCount(2)
    .padding({ left: CarMetrics.edge, right: CarMetrics.edge, bottom: 60 })
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
      CarStateView({
        symbol: $r('sys.symbol.film'),
        title: '没有符合条件的影片',
        message: this.emptyMessage(),
        actionTitle: '清除全部条件',
        onAction: (): void => {
          this.clearAll();
        }
      })
    } else {
      CarStateView({
        symbol: $r('sys.symbol.film'),
        title: '这里还没有内容'
      })
    }
  }

  /** 抽屉底罩：点一下收起 */
  @Builder
  private PanelScrim() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0, 0, 0, 0.55)')
      .transition(TransitionEffect.OPACITY)
      .onClick((): void => {
        this.closePanel();
      })
  }

  /** 排序与筛选抽屉（右侧滑入）：排序 / 只看没看过的 / 类型 / 年代 / 画质（每项带命中数） */
  @Builder
  private Panel() {
    Row() {
      Blank()
      Column() {
        Row() {
          Text('排序与筛选')
            .fontSize(CarType.rowTitle)
            .fontWeight(600)
            .fontColor(CarColors.text)
            .layoutWeight(1)
          // 收起按钮（触控目标 ≥48vp）
          Stack() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(18)
              .fontColor([CarColors.textMuted])
          }
          .width(CarMetrics.minTouch)
          .height(CarMetrics.minTouch)
          .borderRadius(999)
          .backgroundColor(CarColors.surfaceRaised)
          .onClick((): void => {
            this.closePanel();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 6 })

        List({ space: 2 }) {
          ForEach(this.panelRows(), (row: CarWallRow) => {
            ListItem() {
              if (row.kind === 'header') {
                Text(row.label)
                  .fontSize(13)
                  .fontWeight(600)
                  .fontColor(CarColors.textFaint)
                  .padding({ left: 16, top: 14, bottom: 6 })
                  .width('100%')
              } else {
                CarWallOptionRow({
                  label: row.label,
                  countText: row.countText,
                  selected: row.selected,
                  dimmed: row.dimmed,
                  onPick: row.onPick
                })
              }
            }
          }, (row: CarWallRow) => row.key)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .fadingEdge(false)
      }
      .width(440)
      .height('100%')
      .padding({ left: 22, right: 22, top: 26, bottom: 18 })
      .backgroundColor('rgba(11, 13, 18, 0.97)')
      .border({ width: { left: 1 }, color: CarColors.line })
      .transition(TransitionEffect.translate({ x: 440 }))
    }
    .width('100%')
    .height('100%')
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
      parts.push(CarLibraryWall.decadeTitle(this.prefs.decade));
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

  /** 分辨率按习惯叫法：2160p 写「4K」 */
  private resolutionLabel(facet: FacetValueView): string {
    return facet.value === '2160p' ? '4K' : facet.label;
  }

  /** 年代档展示名（服务端的「2010s」→「2010 年代」） */
  private static decadeTitle(value: string): string {
    if (value.length === 5 && value.endsWith('s')) {
      const year: number = Number(value.substring(0, 4));
      if (!Number.isNaN(year) && year > 0) {
        return `${value.substring(0, 4)} 年代`;
      }
    }
    return value;
  }

  // MARK: - 取数

  /** 一页取多少部：列数的整倍数（补页时列位置不错开） */
  private pageSize(): number {
    return this.columns * 12;
  }

  private reload(): void {
    this.generation += 1;
    const gen: number = this.generation;
    this.loading = true;
    this.failed = null;
    this.hasMore = true;
    this.loadingMore = false;
    this.loadingPrev = false;
    this.startOffset = 0;
    this.pressedItemId = -1;
    this.backdropUrl = '';
    this.wallSource.setItems([]);
    if (this.mode() === 'library') {
      this.loadFacets(gen);
    }
    this.fetchPage(0, this.pageSize())
      .then((page: CarWallPage): void => {
        if (gen !== this.generation) {
          return;
        }
        this.wallSource.setItems(page.items);
        this.startOffset = 0;
        if (page.total !== null) {
          this.total = page.total;
        }
        this.hasMore = page.items.length >= this.pageSize();
        this.loading = false;
        // 背景先给第一张，不等地按
        if (page.items.length > 0) {
          this.pressedItemId = page.items[0].itemId;
          this.backdropUrl = page.items[0].backdropUrl;
        }
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

  /** 筛选抽屉的候选值与计数（每一维排除自身条件后算；画质维度要 tier=all 才有） */
  private loadFacets(gen: number): void {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const prefs: CarWallPrefs = this.prefs;
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

  /** 按模式取一页（offset 是整份结果里的位置，窗口式分页的核心） */
  private fetchPage(offset: number, limit: number): Promise<CarWallPage> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return Promise.reject<CarWallPage>(new Error('未连接服务器'));
    }
    const mode: string = this.mode();
    if (mode === 'library' || mode === 'kind') {
      const prefs: CarWallPrefs = this.prefs;
      if (mode === 'library') {
        const g: string | undefined = prefs.genre ?? undefined;
        const d: string | undefined = prefs.decade ?? undefined;
        const w: string | undefined = prefs.unwatched ? 'unwatched' : undefined;
        const res: string | undefined =
          prefs.resolution !== null && prefs.resolution !== 'hdr' ? prefs.resolution : undefined;
        const hdr: boolean | undefined = prefs.resolution === 'hdr' ? true : undefined;
        return api.libraryItemsList(this.libraryId, prefs.sort, this.orderParam(), limit, offset,
          undefined, g, undefined, d, w, undefined, undefined, undefined, res, hdr)
          .then((views: LibraryItemView[]): CarWallPage => this.pageOf(views, null));
      }
      return api.uiLibraryKindItems(this.kindSource, prefs.sort, this.orderParam(), limit, offset,
        undefined, undefined, undefined, prefs.unwatched ? 'unwatched' : undefined)
        .then((views: LibraryItemView[]): CarWallPage => this.pageOf(views, null));
    }
    if (mode === 'collection') {
      const own: boolean = this.prefs.sort === 'collection';
      const sort: string | undefined = own ? undefined : this.prefs.sort;
      const order: string | undefined = own ? undefined : this.orderParam();
      return api.collectionItemsList(this.collectionId, limit, offset, sort, order)
        .then((views: LibraryItemView[]): CarWallPage => this.pageOf(views, null));
    }
    return this.fetchRowWallPage(api, offset, limit);
  }

  /** 行墙取数：sourceKey 与首页那一行同一套参数，进来看到的顺序和行里一致 */
  private fetchRowWallPage(api: MovieClawApi, offset: number, limit: number): Promise<CarWallPage> {
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
        .then((views: LibraryItemView[]): CarWallPage => this.pageOf(views, null));
    }
    if (parts[0] === 'col' && parts.length >= 4) {
      const id: number = Number(parts[1]);
      const sort: string = parts[2];
      const reversed: boolean = parts[3] === 'true';
      const direction: WallSortDirection | null = WallSortDirections.of(sort);
      const order: string | undefined = direction === null
        ? undefined : (direction.orderParam(reversed) ?? undefined);
      return api.collectionItemsList(id, limit, offset, sort, order)
        .then((views: LibraryItemView[]): CarWallPage => this.pageOf(views, null));
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
        .then((view: FavoritesView): CarWallPage => this.pageOf(view.items, view.total));
    }
    if (parts[0] === 'genre' && parts.length >= 3) {
      const kind: string = parts[1];
      const value: string = parts[2];
      // 类型格子墙：按 TMDB 类型筛好的跨库墙，最近添加在前
      return api.uiLibraryKindItems(kind, 'added_at', undefined, limit, offset, value)
        .then((views: LibraryItemView[]): CarWallPage => this.pageOf(views, null));
    }
    if (parts[0] === 'person' && parts.length >= 2) {
      // 影人作品墙：peopleShow 一次给全量 credits，本地按 offset/limit 开窗翻页
      const personId: number = Number(parts[1]);
      const origin: string = AppModel.origin();
      const cellWidth: number = this.cellWidth;
      return api.peopleShow(personId)
        .then((view: PersonView): CarWallPage => {
          const items: CarWallItem[] = [];
          const credits: PersonCreditView[] = view.credits.slice(offset, offset + limit);
          for (const credit of credits) {
            items.push(CarWallItem.fromCredit(credit, origin, cellWidth));
          }
          return new CarWallPage(items, view.credits.length);
        });
    }
    return Promise.reject<CarWallPage>(new Error('未知的数据源'));
  }

  /** 服务端视图 → 墙上的轻量格（收藏条目与库存条目字段同名，直接走同一映射） */
  private pageOf(views: LibraryItemView[], total: number | null): CarWallPage {
    const origin: string = AppModel.origin();
    const items: CarWallItem[] = [];
    for (const view of views) {
      items.push(CarWallItem.fromView(view, origin, this.cellWidth));
    }
    return new CarWallPage(items, total);
  }

  /** 离窗口底还有三排就取下一页：手指往下滚时，下一页已经在路上 */
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
    this.fetchPage(from, this.pageSize())
      .then((page: CarWallPage): void => {
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
        if (page.items.length < this.pageSize()) {
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
    const prevStart: number = Math.max(0, this.startOffset - this.pageSize());
    const count: number = this.startOffset - prevStart;
    const keepIndex: number = this.firstVisibleIndex;
    const scroller: Scroller = this.wallScroller;
    this.loadingPrev = true;
    this.fetchPage(prevStart, count)
      .then((page: CarWallPage): void => {
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

  // MARK: - 滚动、背景与打开

  private onGridScroll(first: number, last: number): void {
    this.firstVisibleIndex = first;
    if (last >= this.wallSource.totalCount() - this.columns * 3) {
      this.loadMore();
    }
    if (first <= 2 && this.startOffset > 0) {
      this.loadPrevious();
    }
  }

  /** 按下一张海报：换背景（防抖） + 两头的窗口续页 */
  private onCardPressed(item: CarWallItem): void {
    this.pressedItemId = item.itemId;
    this.scheduleBackdrop(item);
    const position: number = this.wallSource.indexOfItem(item.itemId);
    if (position < 0) {
      return;
    }
    if (position >= this.wallSource.totalCount() - this.columns * 3) {
      this.loadMore();
    }
    if (position < this.columns * 3 && this.startOffset > 0) {
      this.loadPrevious();
    }
  }

  /** 按压停稳再换背景：一路按过去不逐张闪 */
  private scheduleBackdrop(item: CarWallItem): void {
    if (this.backdropTimer >= 0) {
      clearTimeout(this.backdropTimer);
      this.backdropTimer = -1;
    }
    const itemId: number = item.itemId;
    const url: string = item.backdropUrl;
    this.backdropTimer = setTimeout((): void => {
      this.backdropTimer = -1;
      if (this.pressedItemId === itemId) {
        this.backdropUrl = url;
      }
    }, WALL_BACKDROP_DEBOUNCE_MS);
  }

  /** 列数与格宽：按内容宽弹性计算（不假设 1260vp 定宽） */
  private measureCells(area: Area): void {
    const width: Length = area.width;
    if (typeof width !== 'number' || width <= 0) {
      return;
    }
    const usable: number = width - CarMetrics.edge * 2;
    let cols: number = Math.floor((usable + CarMetrics.wallGap) / (WALL_MIN_CELL + CarMetrics.wallGap));
    if (cols < WALL_MIN_COLUMNS) {
      cols = WALL_MIN_COLUMNS;
    }
    if (cols > WALL_MAX_COLUMNS) {
      cols = WALL_MAX_COLUMNS;
    }
    const cell: number = (usable - CarMetrics.wallGap * (cols - 1)) / cols;
    if (cell > 0 && (cols !== this.columns || Math.abs(cell - this.cellWidth) > 0.5)) {
      this.columns = cols;
      this.cellWidth = cell;
    }
  }

  /** Grid 的列模板串（'1fr 1fr ...' × 列数） */
  private columnsTemplate(): string {
    let out: string = '';
    for (let i: number = 0; i < this.columns; i++) {
      if (i > 0) {
        out += ' ';
      }
      out += '1fr';
    }
    return out;
  }

  private openItem(item: CarWallItem): void {
    const libraryId: number = item.libraryId > 0
      ? item.libraryId
      : (this.mode() === 'library' ? this.libraryId : 0);
    if (libraryId <= 0) {
      return;
    }
    CarUiState.shared.pushRoute(new CarDetailRoute(libraryId, item.itemId));
  }

  // MARK: - 排序与筛选抽屉

  private openPanel(): void {
    this.getUIContext().animateTo(
      { duration: CarMotion.panelMs, curve: Curve.EaseOut },
      (): void => {
        this.panelOpen = true;
      });
  }

  private closePanel(): void {
    this.getUIContext().animateTo(
      { duration: CarMotion.panelMs, curve: Curve.EaseOut },
      (): void => {
        this.panelOpen = false;
      });
  }

  /** 返回键分级的第一站：抽屉开着先收抽屉（经 CarUiState.registerRouteBack 注册） */
  private handlePanelBack(): boolean {
    if (this.panelOpen) {
      this.closePanel();
      return true;
    }
    return false;
  }

  /** 抽屉全部行（小节标题 + 选项），键稳定供 ForEach 复用 */
  private panelRows(): CarWallRow[] {
    const rows: CarWallRow[] = [];
    if (!this.canFilter()) {
      return rows;
    }
    const mode: string = this.mode();
    const prefs: CarWallPrefs = this.prefs;
    const salt: string = this.salt;

    rows.push(CarWallRow.header(`${salt}_h_sort`, '排序'));
    const sorts: string[] = this.sortKeys();
    for (const sort of sorts) {
      rows.push(CarWallRow.option(
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
      rows.push(CarWallRow.header(`${salt}_h_watch`, '观看状态'));
      rows.push(CarWallRow.option(
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
        rows.push(CarWallRow.header(`${salt}_h_genre`, '类型'));
        rows.push(CarWallRow.option(
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
          rows.push(CarWallRow.option(
            `${salt}_opt_g_${value}`,
            facet.label,
            `${facet.count} 部`,
            prefs.genre === value,
            facet.count === 0 && prefs.genre !== value,
            (): void => {
              this.pickGenre(value);
            }));
        }

        rows.push(CarWallRow.header(`${salt}_h_decade`, '年代'));
        rows.push(CarWallRow.option(
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
          rows.push(CarWallRow.option(
            `${salt}_opt_d_${value}`,
            CarLibraryWall.decadeTitle(value),
            `${facet.count} 部`,
            prefs.decade === value,
            facet.count === 0 && prefs.decade !== value,
            (): void => {
              this.pickDecade(value);
            }));
        }

        rows.push(CarWallRow.header(`${salt}_h_quality`, '画质'));
        rows.push(CarWallRow.option(
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
          rows.push(CarWallRow.option(
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
          rows.push(CarWallRow.option(
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
      rows.push(CarWallRow.header(`${salt}_h_clear`, ''));
      rows.push(CarWallRow.option(
        `${salt}_opt_clear`,
        '清除筛选',
        null,
        false,
        false,
        (): void => {
          this.clearPicks();
        }));
    }

    rows.push(CarWallRow.header(`${salt}_h_done`, ''));
    rows.push(CarWallRow.option(
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

  // MARK: - 条件变更（都走 mutatePrefs：换实例触发重渲 + 持久化 + 整墙刷新）

  private changeSort(sort: string): void {
    if (this.prefs.sort === sort) {
      return;
    }
    this.mutatePrefs((prefs: CarWallPrefs): void => {
      prefs.sort = sort;
    });
    this.reload();
  }

  private toggleUnwatched(): void {
    this.mutatePrefs((prefs: CarWallPrefs): void => {
      prefs.unwatched = !prefs.unwatched;
    });
    this.reload();
  }

  private pickGenre(value: string | null): void {
    this.mutatePrefs((prefs: CarWallPrefs): void => {
      prefs.genre = value;
    });
    this.reload();
  }

  private pickDecade(value: string | null): void {
    this.mutatePrefs((prefs: CarWallPrefs): void => {
      prefs.decade = value;
    });
    this.reload();
  }

  private pickQuality(value: string | null): void {
    this.mutatePrefs((prefs: CarWallPrefs): void => {
      prefs.resolution = value;
    });
    this.reload();
  }

  /** 抽屉里的「清除筛选」：只清类型/年代/画质，保留排序与「只看没看过的」 */
  private clearPicks(): void {
    this.mutatePrefs((prefs: CarWallPrefs): void => {
      prefs.genre = null;
      prefs.decade = null;
      prefs.resolution = null;
    });
    this.reload();
  }

  /** 筛空页上的「清除全部条件」：连「只看没看过的」一起清 */
  private clearAll(): void {
    this.mutatePrefs((prefs: CarWallPrefs): void => {
      prefs.genre = null;
      prefs.decade = null;
      prefs.resolution = null;
      prefs.unwatched = false;
    });
    this.reload();
  }

  private mutatePrefs(action: (prefs: CarWallPrefs) => void): void {
    const next: CarWallPrefs = new CarWallPrefs();
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
      CarUiState.shared.saveWallPrefs(key, next);
    }
  }
}

/**
 * 网格里的一格：包一层组件让 LazyForEach 的 itemGenerator 保持极简，
 * 按压回调（换背景）挂在这层。
 */
@ComponentV2
struct CarWallGridItem {
  @Param item: CarWallItem = new CarWallItem('', 0, 0, '', null, '', '');
  @Param cellWidth: number = 198;
  @Param onOpen: (() => void) | null = null;
  @Param onPressed: (() => void) | null = null;

  build() {
    CarPosterCard({
      title: this.item.title,
      subtitle: this.item.year === null ? null : `${this.item.year}`,
      imageUrl: this.item.posterUrl,
      cardWidth: this.cellWidth,
      onActivate: this.onOpen,
      onPressed: this.onPressed
    })
  }
}

/**
 * 媒体库页签：库卡 + 合集卡网格（CarLibraryCard 大卡），点按进对应墙。
 * 与首页「我的媒体库」行的差别：这里是完整清单（含空库），可当全库入口。
 */
@ComponentV2
export struct CarLibraryTab {
  @Local loading: boolean = true;
  @Local failed: string | null = null;
  @Local libraries: LibraryView[] = [];
  @Local collections: CollectionView[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private reload(): void {
    this.loading = true;
    this.failed = null;
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.loading = false;
      this.failed = '未连接服务器';
      return;
    }
    Promise.all([
      api.libraryList(undefined, 'all').catch((): LibraryView[] => []),
      api.collectionList().catch((): CollectionView[] => [])
    ])
      .then((results: Object[]): void => {
        const libraries: LibraryView[] = results[0] as LibraryView[];
        const collections: CollectionView[] = results[1] as CollectionView[];
        this.libraries = libraries.filter((library: LibraryView): boolean => library.viewer_access);
        this.collections = collections;
        this.loading = false;
      })
      .catch((error: BusinessError): void => {
        this.loading = false;
        const message: string | undefined = error.message;
        this.failed = message !== undefined && message.length > 0 ? message : '加载失败';
      });
  }

  build() {
    if (this.loading) {
      Stack() {
        LoadingProgress()
          .width(52)
          .height(52)
          .color(CarColors.textMuted)
      }
      .width('100%')
      .height('100%')
    } else if (this.failed !== null) {
      CarStateView({
        symbol: $r('sys.symbol.wifi'),
        title: '加载失败',
        message: this.failed,
        actionTitle: '重试',
        onAction: (): void => {
          this.reload();
        }
      })
    } else if (this.libraries.length === 0 && this.collections.length === 0) {
      CarStateView({
        symbol: $r('sys.symbol.square_grid_2x2'),
        title: '这里还没有媒体库'
      })
    } else {
      this.content()
    }
  }

  @Builder
  private content() {
    Scroll() {
      Column() {
        Text('媒体库')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(CarColors.text)
          .maxLines(1)
          .width('100%')

        if (this.libraries.length > 0) {
          this.sectionTitle(`媒体库 · ${this.libraries.length}`)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.libraries, (library: LibraryView) => {
              CarLibraryCard({
                name: library.name,
                count: library.stats.item_count,
                imageUrl: this.coverUrl(`/libraries/${library.id}/cover`),
                onActivate: (): void => {
                  CarUiState.shared.pushRoute(new CarWallRoute(library.id, library.name, null));
                }
              })
                .margin({ right: 24, bottom: 24 })
            }, (library: LibraryView) => `lib_${library.id}`)
          }
          .width('100%')
        }

        if (this.collections.length > 0) {
          this.sectionTitle(`合集 · ${this.collections.length}`)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.collections, (collection: CollectionView) => {
              CarLibraryCard({
                name: collection.name,
                count: collection.item_count,
                imageUrl: this.coverUrl(`/collections/${collection.id}/cover`),
                collection: true,
                onActivate: (): void => {
                  CarUiState.shared.pushRoute(
                    new CarCollectionRoute(collection.id, collection.name));
                }
              })
                .margin({ right: 24, bottom: 24 })
            }, (collection: CollectionView) => `col_${collection.id}`)
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge, top: 22, bottom: 120 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .fadingEdge(false)
  }

  @Builder
  private sectionTitle(title: string) {
    Text(title)
      .fontSize(CarType.rowTitle)
      .fontWeight(600)
      .fontColor(CarColors.textMuted)
      .maxLines(1)
      .width('100%')
      .margin({ top: 22, bottom: 16 })
  }

  /** 库/合集货架封面（服务端拼好的 21:10），解析后按卡宽补 &w= 降采样 */
  private coverUrl(path: string): string {
    const url: string | null = ImageUrls.resolve(AppModel.origin(), path, null);
    if (url === null) {
      return '';
    }
    return `${url}${url.includes('?') ? '&' : '?'}w=${CarArt.pxWidth(CarMetrics.libraryCardWidth)}`;
  }
}
