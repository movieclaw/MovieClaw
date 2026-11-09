import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { PageTopBar } from '../common/PageTopBar';
import { StaleLoadGuard } from '../common/StaleLoadGuard';
import { MovieClawApi } from '../api/Endpoints';
import { LibraryItemView, LibraryKindSummaryView } from '../api/Models';
import { ItemRouteParams } from './LibraryItemDetailPage';
import {
  LibraryInventoryCell,
  LibraryWallPager,
  WallSortDirections,
  WallSortMenu,
  WallSortOption,
  WallSortState
} from './LibraryWall';

/**
 * 跨库墙的路由参数（首页「按类型找」色块的落点）。
 *
 * 与 LibraryRouteParams 同理：**不要用 `instanceof` 判断**——`pushPathByName` 传过来的参数
 * 会被序列化，到 `onReady` 时已经是普通对象。按字段取值并校验。
 */
export class KindWallParams {
  readonly kind: string;
  /** TMDB 类型 id；null = 不筛类型（整面墙） */
  readonly genre: number | null;
  /** 类型中文名（做标题；类型格子里自带，端上不用再查 TMDB 类型表） */
  readonly genreLabel: string | null;

  constructor(kind: string, genre: number | null, genreLabel: string | null) {
    this.kind = kind;
    this.genre = genre;
    this.genreLabel = genreLabel;
  }

  static of(param: Object | undefined | null): KindWallParams {
    if (param === undefined || param === null) {
      return new KindWallParams('movie', null, null);
    }
    const raw: KindWallParams = param as KindWallParams;
    const kind: string = raw.kind === 'tv' || raw.kind === 'video' ? raw.kind : 'movie';
    const genre: number = raw.genre as number;
    const label: string = raw.genreLabel as string;
    return new KindWallParams(kind,
      Number.isFinite(genre) && genre > 0 ? Math.floor(genre) : null,
      typeof label === 'string' && label.length > 0 ? label : null);
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function LibraryKindWallBuilder() {
  LibraryKindWallPage()
}

/**
 * 墙的行数据源（LazyForEach 用）：把整窗的格子按列数切成行。
 * 与单库页的 WallRowSource 同一套（那边的类没导出，这里就地放一份）。
 */
class KindWallRowSource implements IDataSource {
  private rows: LibraryItemView[][] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): LibraryItemView[] {
    return this.rows[index];
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

  setItems(items: LibraryItemView[], columns: number): void {
    const rows: LibraryItemView[][] = [];
    for (let i: number = 0; i < items.length; i += columns) {
      rows.push(items.slice(i, i + columns));
    }
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * 按类型的跨库海报墙（对应 iOS `LibraryKindWallView`，Web kind-wall-view.tsx）：
 * 首页「按类型找电影 / 剧集」类型色块的落点。成员 = 当前身份可见、没被管理员排除出首页的
 * 同类型库；同一部片在 4K 库和普通库各有一份时只出现一格，点格子进服务端给的落点库。
 *
 * 刻意比单库页薄（同 Web / iOS）：没有筛选条与索引条，只有排序。
 * 从详情页返回只整窗对账（refresh），不清空窗口、不动滚动位置；换排序才回墙首。
 * 排序按类型各记一份（`movieclaw.library.kind-wall-sort.{kind}`，同 Web localStorage）。
 */
@Component
struct LibraryKindWallPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private kind: string = 'movie';
  private genre: number | null = null;
  private genreLabel: string | null = null;
  private pager: LibraryWallPager = new LibraryWallPager(60);
  /** 首载/换排序的代次守卫：连点排序时旧一轮 load() 晚醒（概况请求后到）会把
   * 分页器换回旧数据源——墙显示的还是旧排序。每个 await 后对代次，作废即弃 */
  private loadGuard: StaleLoadGuard = new StaleLoadGuard();
  /** 主墙的行数据源（LazyForEach 只建可视区附近的行） */
  private wallRows: KindWallRowSource = new KindWallRowSource();
  private scroller: Scroller = new Scroller();
  /** 墙数据的 @State 镜像：pager 本体不是响应式的，操作后整体抄过来触发刷新 */
  @State private wallItems: LibraryItemView[] | null = null;
  @State private wallStart: number = 0;
  @State private wallHasMore: boolean = false;
  @State private wallFailed: string | null = null;
  @State private sort: WallSortState = new WallSortState('default', false);
  /** 墙首取一次的概况：共几部、来自几个库（往下翻页时数量不变，不必每页多打一个请求） */
  @State private totalCount: number = 0;
  @State private libraryCount: number | null = null;
  @State private refreshing: boolean = false;
  @State private columns: number = Theme.posterColumns();

  private sortKey(): string {
    return `movieclaw.library.kind-wall-sort.${this.kind}`;
  }

  /**
   * 默认档是「最近添加」——这面墙从首页点进来顺序不该变。
   * 其余档与单库墙同一套；其他视频没有评分与上映时间，列出来只会排出一面按 id 的墙，按类型裁掉。
   */
  private sortOptions(): WallSortOption[] {
    const options: WallSortOption[] = [
      new WallSortOption('default', '最近添加', WallSortDirections.of('added_at')),
      new WallSortOption('title', '按标题', WallSortDirections.of('title'))
    ];
    if (this.kind !== 'video') {
      options.push(new WallSortOption('release_date', '按上映时间', WallSortDirections.of('release_date')));
      options.push(new WallSortOption('rating', '按评分', WallSortDirections.of('rating')));
    }
    options.push(new WallSortOption('runtime', '按片长', WallSortDirections.of('runtime')));
    options.push(new WallSortOption('size', '按体积', WallSortDirections.of('size')));
    options.push(new WallSortOption('last_played', '最近观看', WallSortDirections.of('last_played')));
    return options;
  }

  private allowedSorts(): string[] {
    return this.sortOptions().map((option: WallSortOption): string => option.value);
  }

  /** 实际请求的排序档：默认档就是「最近添加」（同 iOS effectiveSort） */
  private effectiveSort(): string {
    return this.sort.sort === 'default' ? 'added_at' : this.sort.sort;
  }

  private order(): string | null {
    const profile = WallSortDirections.of(this.effectiveSort());
    return profile === null ? null : profile.orderParam(this.sort.reversed);
  }

  private showRating(): boolean {
    return this.effectiveSort() === 'rating';
  }

  private kindLabel(): string {
    return this.kind === 'tv' ? '剧集' : this.kind === 'video' ? '视频' : '电影';
  }

  private title(): string {
    if (this.genreLabel !== null) {
      return this.genreLabel;
    }
    return `全部${this.kindLabel()}`;
  }

  /** 筛选参数 g：只带色块预设的这一个类型 */
  private genreQuery(): string | undefined {
    return this.genre === null ? undefined : `${this.genre}`;
  }

  /** 页头小字：类型墙报「N 部电影 · 来自 M 个库」；全部墙报「N 部作品」并说明去重口径 */
  private summaryLine(): string {
    if (this.wallItems === null) {
      return '正在读取…';
    }
    if (this.libraryCount === 0) {
      return `还没有可浏览的${this.kindLabel()}库`;
    }
    if (this.libraryCount !== null) {
      return this.genre === null
        ? `${this.totalCount} 部作品 · 来自 ${this.libraryCount} 个库，同一部片只算一次`
        : `${this.totalCount} 部${this.kindLabel()} · 来自 ${this.libraryCount} 个库`;
    }
    // 概况读失败时（libraryCount 为 null）只说口径，不挂一句永远的「正在读取」
    return '同一部片只算一次';
  }

  /** 总数与组成库只在墙首取一次（同 iOS loadSummary） */
  private async loadSummary(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const summary: LibraryKindSummaryView = await api.uiLibraryKindSummary(this.kind, this.genreQuery());
      this.totalCount = summary.item_count;
      this.libraryCount = summary.library_ids.length;
    } catch (error) {
      // 概况读失败：页头落到「同一部片只算一次」那句口径
    }
  }

  /** 首载 / 换排序：整面墙回墙首重载 */
  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const generation: number = this.loadGuard.begin();
    const kind: string = this.kind;
    const genreQuery: string | undefined = this.genreQuery();
    const sort: string = this.effectiveSort();
    const order: string | null = this.order();
    await this.loadSummary();
    if (!this.loadGuard.isCurrent(generation)) { return; }
    const fetch = (offset: number, limit: number): Promise<LibraryItemView[]> => {
      return api.uiLibraryKindItems(kind, sort, order ?? undefined, limit, offset, genreQuery);
    };
    await this.pager.reset(fetch, 0);
    if (!this.loadGuard.isCurrent(generation)) { return; }
    this.syncWall();
  }

  /** 从详情页返回 / 下拉：按已加载的页数整窗重拉（在详情页删掉的片要跟着消失），失败保留旧窗口 */
  private async refresh(): Promise<void> {
    await this.loadSummary();
    await this.pager.refresh();
    this.syncWall();
  }

  /** 把 pager 的窗口状态抄进 @State（整页重赋值触发刷新） */
  private syncWall(): void {
    this.wallItems = this.pager.items;
    this.wallRows.setItems(this.pager.items ?? [], this.columns);
    this.wallStart = this.pager.start;
    this.wallHasMore = this.pager.hasMore;
    this.wallFailed = this.pager.failed;
  }

  private onReachEnd(): void {
    const load = this.pager.loadMore();
    load.then((): void => {
      this.syncWall();
    });
  }

  private onSortPick(value: string): void {
    this.sort = new WallSortState(value, false);
    this.sort.save(this.sortKey());
    this.load();
  }

  private onSortToggleDirection(): void {
    this.sort = new WallSortState(this.sort.sort, !this.sort.reversed);
    this.sort.save(this.sortKey());
    this.load();
  }

  build() {
    NavDestination() {
      Column() {
        PageTopBar({
          title: this.title(),
          onBack: (): void => {
            this.navStack.pop();
          }
        })
        Refresh({ refreshing: $$this.refreshing }) {
          // 用 List 而不是 Scroll + Column：只有 List / Grid 这类容器才让 LazyForEach 按可视区建组件
          List({ scroller: this.scroller }) {
            ListItem() {
              this.Header()
            }
            if (this.wallFailed !== null && this.wallItems === null) {
              ListItem() {
                Column({ space: 14 }) {
                  Text('跨库墙加载失败')
                    .fontSize(15)
                    .fontColor(Theme.textMuted)
                  Text(this.wallFailed)
                    .fontSize(13)
                    .fontColor(Theme.textFaint)
                  Button('重试')
                    .fontSize(14)
                    .fontWeight(600)
                    .fontColor(Theme.text)
                    .backgroundColor(Theme.glassFill)
                    .borderRadius(18)
                    .border({ width: 1, color: Theme.line })
                    .padding({ left: 22, right: 22, top: 8, bottom: 8 })
                    .onClick(() => {
                      this.load();
                    })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 48 })
              }
            } else if (this.wallItems === null) {
              ListItem() {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color(Theme.textMuted)
                  .margin({ top: 40 })
              }
            } else if ((this.wallItems as LibraryItemView[]).length > 0) {
              LazyForEach(this.wallRows, (row: LibraryItemView[]) => {
                ListItem() {
                  this.WallRow(row)
                }
              }, (row: LibraryItemView[]) => row.map((item: LibraryItemView): string => `${item.media_item_id}`).join('-'))
              ListItem() {
                this.LoadMoreFooter(this.wallItems as LibraryItemView[])
              }
            }
            // 空墙不另占位：页头那句「还没有可浏览的…」已经把话说完（同 iOS）
            ListItem() {
              AppFooter()
            }
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .edgeEffect(EdgeEffect.None)
          .cachedCount(4)
          .contentEndOffset(Theme.tabBarInset)
          .onReachEnd(() => {
            this.onReachEnd();
          })
        }
        .onRefreshing(() => {
          this.refresh().then((): void => {
            this.refreshing = false;
          });
        })
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        const params: KindWallParams = KindWallParams.of(ctx.pathInfo.param as Object | undefined);
        this.kind = params.kind;
        this.genre = params.genre;
        this.genreLabel = params.genreLabel;
        this.sort = WallSortState.load(this.sortKey(), new WallSortState('default', false), this.allowedSorts());
        this.load();
      }
    })
    .onShown(() => {
      // 从详情页返回：整窗对账；首进的加载由 onReady 负责
      if (this.started && this.wallItems !== null) {
        this.refresh();
      }
    })
  }

  /** 页头：概况一行 + 排序菜单（墙有货才给菜单，同 iOS header） */
  @Builder
  Header() {
    Column({ space: 12 }) {
      Text(this.summaryLine())
        .fontSize(14)
        .fontColor(Theme.textMuted)
      if (this.wallItems !== null && (this.wallItems as LibraryItemView[]).length > 0) {
        WallSortMenu({
          options: this.sortOptions(),
          sort: this.sort,
          onPick: (value: string): void => {
            this.onSortPick(value);
          },
          onToggleDirection: (): void => {
            this.onSortToggleDirection();
          }
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 12 })
  }

  /**
   * 一行格子：末行不满时补空位，保持每格等宽、左对齐（同 LazyVGrid）。
   * 页面左右边距与行间距都挂在行上——主墙的每一行是独立的 ListItem，外层容器加不上内边距。
   */
  @Builder
  WallRow(row: LibraryItemView[]) {
    Row({ space: 12 }) {
      ForEach(row, (item: LibraryItemView) => {
        Column() {
          LibraryInventoryCell({
            item: item,
            // 每格落回服务端给的落点库（同一部片跨库只出现一格，格子各回各家）
            libraryId: item.library_id ?? 0,
            frameAspect: this.kind === 'video' ? 16 / 9 : Theme.posterAspect,
            showRating: this.showRating(),
            onOpen: (opened: LibraryItemView): void => {
              this.navStack.pushPathByName('libraryItem',
                new ItemRouteParams(opened.library_id ?? 0, opened.media_item_id));
            }
          })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }, (item: LibraryItemView) => `${item.media_item_id}`)
      ForEach(this.emptySlots(row), (slot: number) => {
        Column()
          .layoutWeight(1)
      }, (slot: number) => `${slot}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 20 })
  }

  /** 墙尾的加载指示：文案报窗口进度 */
  @Builder
  LoadMoreFooter(items: LibraryItemView[]) {
    if (this.wallHasMore) {
      Row({ space: 8 }) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color(Theme.textFaint)
        Text(`加载中…（第 ${this.wallStart + 1}–${this.wallStart + items.length} 部 / 共 ${Math.max(this.totalCount, this.wallStart + items.length)} 部）`)
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 20, bottom: 20 })
    }
  }

  /** 最后一行的空位序号（0..n） */
  private emptySlots(row: LibraryItemView[]): number[] {
    const slots: number[] = [];
    for (let i: number = row.length; i < this.columns; i++) {
      slots.push(i);
    }
    return slots;
  }
}
