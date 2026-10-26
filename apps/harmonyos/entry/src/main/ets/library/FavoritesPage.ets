import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { FavoriteItemView, FavoritesView, LibraryGalleryGroupView } from '../api/Models';
import { ItemRouteParams } from './LibraryItemDetailPage';
import { AppFooter } from '../common/AppFooter';
import { GalleryDensity, GalleryPrefs, GalleryWall } from './GalleryWall';
import {
  WallSortDirection,
  WallSortDirections,
  WallSortMenu,
  WallSortOption,
  WallSortState
} from './LibraryWall';

/** 排序档（iOS `FavoritesView.sortOptions`：默认档叫「最近收藏」，其余同单库页） */
const SORT_OPTIONS: WallSortOption[] = [
  new WallSortOption('favorited_at', '最近收藏', WallSortDirections.of('favorited_at')),
  new WallSortOption('title', '按标题', WallSortDirections.of('title')),
  new WallSortOption('added_at', '最近添加', WallSortDirections.of('added_at')),
  new WallSortOption('release_date', '按上映时间', WallSortDirections.of('release_date')),
  new WallSortOption('rating', '按评分', WallSortDirections.of('rating')),
  new WallSortOption('runtime', '按片长', WallSortDirections.of('runtime')),
  new WallSortOption('size', '按体积', WallSortDirections.of('size')),
  new WallSortOption('last_played', '最近观看', WallSortDirections.of('last_played'))
];

const SORT_STORAGE_KEY: string = 'movieclaw.favorites.wall-sort';

/** 上次浏览的位置（按作品计）：先记在进程里（iOS/Web 存本机持久化，这里跨重启不记得） */
class FavoritesRecall {
  static offset: number = -1;
}

const PAGE_SIZE: number = 60;

/**
 * 收藏墙的行数据源（LazyForEach 用）。
 *
 * 收藏是跨库一面墙，分页每到 60 部就续一页；原来整面墙在 Scroll > Column 里用 Flex(wrap)
 * + ForEach 全量建，续到几百部全部留在树里。按 2 列切成行，每行是外层 List 的一个 ListItem，
 * LazyForEach 只建可视区附近的行（口径同 LibraryDetailPage.WallRowSource）。
 */
class FavoritesWallSource implements IDataSource {
  private rows: FavoriteItemView[][] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): FavoriteItemView[] {
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

  setItems(items: FavoriteItemView[], columns: number): void {
    const rows: FavoriteItemView[][] = [];
    for (let i: number = 0; i < items.length; i += columns) {
      rows.push(items.slice(i, i + columns));
    }
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function FavoritesBuilder() {
  FavoritesPage()
}

/**
 * 我的收藏（对应 iOS `FavoritesView` / Web `favorites-view`，路由 `/library/favorites`）。
 *
 * 它是**跨库的一面墙**：与 Jellyfin 客户端里点的心同一份名单，分页拉（每页 60），
 * 整面墙钉死 2:3，**每格落回它自己所属的库**。
 *
 * 首页收藏行的「查看全部 N 部」进这里（原来那是个「建设中」的三点菜单，
 * 库行与合集行的「查看全部」也共用它——本轮一并接上各自的目的地）。
 *
 * 排序与单库页同一套（`WallSortMenu`：八档 + 当前档再点一次翻转方向，记在本机）；
 * 进来时若上次滑得够深，底部弹「回到上次浏览的位置」，点一下续页跳回去。
 *
 * 两种形态共用同一份排序（iOS `FavoritesView`）：
 * - 海报墙：`GET /playback/favorites` 分页（每页 60），整面墙钉死 2:3；
 * - 图床浏览：`GET /playback/favorites/gallery`（`GalleryWall`），灯箱里的心可取消收藏。
 * 「回到上次位置」两种形态共用一条记录（都按作品计；图廊下点胶囊换图廊窗口）。
 */
@ComponentV2
export struct FavoritesPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private loadingMore: boolean = false;
  private reachedEnd: boolean = false;
  /** 收藏墙的行数据源（LazyForEach 只建可视区附近的行） */
  private wallSource: FavoritesWallSource = new FavoritesWallSource();
  private scroller: Scroller = new Scroller();

  @Local private items: FavoriteItemView[] = [];
  @Local private total: number = 0;
  @Local private sort: WallSortState = WallSortState.load(SORT_STORAGE_KEY,
    new WallSortState('favorited_at', false), FavoritesPage.sortValues());
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private refreshing: boolean = false;
  /** 进来时上次滑得够深：底部弹「回到上次浏览的位置」（按作品计；-1 = 不弹） */
  @Local private recallOffer: number = -1;
  /** 图床浏览（第二种形态；偏好记在进程里） */
  @Local private galleryMode: boolean = GalleryPrefs.galleryMode;
  @Local private galleryGrouped: boolean = GalleryPrefs.grouped;
  @Local private galleryDensity: string = GalleryPrefs.densityName;
  /** 图廊窗口起点（「回到上次位置」在图廊下跳这里） */
  @Local private galleryStart: number = 0;

  private static sortValues(): string[] {
    const values: string[] = [];
    for (const option of SORT_OPTIONS) {
      values.push(option.value);
    }
    return values;
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async load(): Promise<void> {
    this.items = [];
    this.reachedEnd = false;
    this.loading = true;
    await this.loadPage(0);
    this.loading = false;
    // 上次滑得够深且还在总数内：弹「回到上次浏览的位置」（不足一屏就不打扰）
    const last: number = FavoritesRecall.offset;
    this.recallOffer = last >= this.columns * 3 && last < this.total ? last : -1;
  }

  private async loadPage(offset: number): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    try {
      // 不翻转方向不带 order，服务端按自然方向排（同 Web orderParam 的规矩）
      const direction: WallSortDirection | null = WallSortDirections.of(this.sort.sort);
      const order: string | null = direction === null ? null : direction.orderParam(this.sort.reversed);
      const view: FavoritesView = await api.playbackFavorites(PAGE_SIZE, offset, undefined,
        this.sort.sort, order === null ? undefined : order);
      if (offset === 0) {
        this.items = view.items;
      } else {
        for (const item of view.items) {
          this.items.push(item);
        }
      }
      this.wallSource.setItems(this.items, this.columns);
      this.total = view.total;
      if (view.items.length < PAGE_SIZE) {
        this.reachedEnd = true;
      }
      this.failed = false;
      this.errorMessage = '';
    } catch (error) {
      if (this.items.length === 0) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
      this.reachedEnd = true;
    } finally {
      this.loadingMore = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  /** 每格落回它自己所属的库（跨库墙的关键：不能都往一个库跳） */
  private openItem(item: FavoriteItemView): void {
    this.navStack.pushPathByName('libraryItem',
      new ItemRouteParams(item.library_id, item.media_item_id));
  }

  private onSortPick(value: string): void {
    if (this.sort.sort === value) {
      return;
    }
    // V2 下换整个对象（WallSortState 没 @Trace，原地改不触发刷新）
    this.sort = new WallSortState(value, false);
    this.sort.save(SORT_STORAGE_KEY);
    this.galleryStart = 0;
    this.load();
  }

  private onSortToggleDirection(): void {
    this.sort = new WallSortState(this.sort.sort, !this.sort.reversed);
    this.sort.save(SORT_STORAGE_KEY);
    this.galleryStart = 0;
    this.load();
  }

  /** 图床浏览开关（两种形态共用同一份排序与位置记录） */
  private toggleGallery(): void {
    this.galleryMode = !this.galleryMode;
    GalleryPrefs.galleryMode = this.galleryMode;
    this.galleryStart = 0;
  }

  /** 图廊取数：与海报墙同一份排序口径 */
  private fetchGallery(offset: number, limit: number): Promise<LibraryGalleryGroupView[]> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return Promise.resolve<LibraryGalleryGroupView[]>([]);
    }
    const direction: WallSortDirection | null = WallSortDirections.of(this.sort.sort);
    const order: string | null = direction === null ? null : direction.orderParam(this.sort.reversed);
    return api.playbackFavoritesGallery(limit, offset, this.sort.sort,
      order === null ? undefined : order);
  }

  /** 图廊滚动回报：与海报墙写同一条位置记录（都按作品计） */
  private recordGalleryOffset(offset: number): void {
    FavoritesRecall.offset = offset;
    if (this.recallOffer >= 0 && offset >= this.recallOffer) {
      this.recallOffer = -1;
    }
  }

  /** 「回到上次浏览的位置」：海报墙续页跳回去；图廊把窗口换成从那部作品开始 */
  private async jumpToRecall(): Promise<void> {
    const target: number = this.recallOffer;
    this.recallOffer = -1;
    if (target <= 0) {
      return;
    }
    if (this.galleryMode) {
      // 图廊按作品分页：窗口换成从那部作品开始
      this.galleryStart = target;
      return;
    }
    while (this.items.length <= target && !this.reachedEnd) {
      await this.loadPage(this.items.length);
    }
    this.scroller.scrollToIndex(Math.floor(target / this.columns));
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        // 自绘顶栏：原生标题栏在沉浸式布局下不避让状态栏（会压住时钟、返回键上半截点不动）
        Row() {
          PageTopBar({ title: '我的收藏', onBack: (): void => {
          this.navStack.pop();
        }})
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        if (this.failed) {
          this.ErrorState()
        } else if (this.loading) {
          this.LoadingState()
        } else if (this.items.length === 0) {
          this.EmptyState()
        } else {
          // 内容 + 底部的「回到上次浏览的位置」胶囊
          Stack({ alignContent: Alignment.Bottom }) {
            Column() {
              this.Header()
              if (this.galleryMode) {
                GalleryWall({
                  fetch: (offset: number, limit: number): Promise<LibraryGalleryGroupView[]> => {
                    return this.fetchGallery(offset, limit);
                  },
                  reloadKey: `${this.sort.sort}:${this.sort.reversed}`,
                  startOffset: this.galleryStart,
                  grouped: this.galleryGrouped,
                  densityName: this.galleryDensity,
                  onOpenItem: (group: LibraryGalleryGroupView): void => {
                    this.navStack.pushPathByName('libraryItem',
                      new ItemRouteParams(group.library_id, group.media_item_id));
                  },
                  onFirstVisible: (offset: number): void => {
                    this.recordGalleryOffset(offset);
                  }
                })
                  .layoutWeight(1)
              } else {
                this.Wall()
              }
            }
            .width('100%')
            .height('100%')
            if (this.recallOffer >= 0) {
              this.RecallPill()
            }
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS `.navigationTitle("我的收藏")` inline：原生标题栏，返回按钮系统自带
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        this.load();
      }
    })
  }

  @Builder
  LoadingState() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(Theme.textMuted)
      Text('正在加载收藏…')
        .fontSize(14)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ErrorState() {
    Column({ space: 12 }) {
      Text('收藏加载失败')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(this.errorMessage)
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Text('重试')
        .fontSize(14)
        .fontWeight(600)
        .fontColor(Theme.accentStrong)
        .padding({ left: 20, right: 20, top: 9, bottom: 9 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(18)
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.heart'))
        .fontSize(30)
        .fontColor([Theme.textFaint])
      Text('还没有收藏')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('在影片详情页点「收藏」，就会出现在这里。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 收藏墙的一行（两列，整面钉死 2:3） */
  /** 一行几列：跟媒体库 / 合集详情同一个口径（2~4 列，按屏宽自适应） */
  private columns: number = Theme.posterColumns();

  @Builder
  WallRow(row: FavoriteItemView[]) {
    Row({ space: 12 }) {
      ForEach(row, (item: FavoriteItemView) => {
        Column({ space: 6 }) {
          RemoteImage({
            url: ImageUrls.resolve(AppModel.origin(), item.poster_url, ImageVariant.posterCard) ?? ''
          })
            .width('100%')
            .aspectRatio(Theme.posterAspect)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.cardRadius)
            .clip(true)
          Text(item.title)
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.text)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.cellSubtitle(item))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .margin({ bottom: 18 })
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {
          this.openItem(item);
        })
      }, (item: FavoriteItemView) => `${item.library_id}-${item.media_item_id}`)
      // 最后一行不足列数时补等宽空位，卡片不会被拉宽
      ForEach(this.emptySlots(row.length), (slot: number) => {
        Column().layoutWeight(1)
      }, (slot: number) => `slot-${slot}`)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 补位序号（最后一行用） */
  private emptySlots(filled: number): number[] {
    const slots: number[] = [];
    for (let i: number = filled; i < this.columns; i++) {
      slots.push(i);
    }
    return slots;
  }

  /** 头部：摘要 + 排序 + 图床浏览开关（两种形态共用同一份排序，同 iOS header） */
  @Builder
  Header() {
    Column({ space: 10 }) {
      Text(`${this.total} 部作品 · 与 Jellyfin 客户端里点的心同一份`)
        .fontSize(13)
        .fontColor(Theme.textMuted)
      Row({ space: 10 }) {
        WallSortMenu({
          options: SORT_OPTIONS,
          sort: this.sort,
          onPick: (value: string): void => {
            this.onSortPick(value);
          },
          onToggleDirection: (): void => {
            this.onSortToggleDirection();
          }
        })
        if (this.galleryMode) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.dial'))
              .fontSize(15)
              .fontColor([Theme.text])
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(10)
              .fontColor([Theme.textMuted])
          }
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.line })
          .bindMenu(this.GalleryPrefMenu())
        }
        Blank()
        Row() {
          SymbolGlyph(this.galleryMode ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.rectangle_stack'))
            .fontSize(16)
            .fontColor([Theme.textMuted])
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.glassFill)
        .borderRadius(18)
        .border({ width: 1, color: Theme.line })
        .onClick(() => {
          this.toggleGallery();
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4, bottom: 10 })
  }

  /** 看图的浏览偏好（⋯ 菜单，同 Web WallPrefItems）：按作品分组 + 瀑布流密度 */
  @Builder
  GalleryPrefMenu() {
    Menu() {
      MenuItem({ content: `按作品分组${this.galleryGrouped ? ' ✓' : ''}` })
        .onClick(() => {
          this.galleryGrouped = !this.galleryGrouped;
          GalleryPrefs.grouped = this.galleryGrouped;
        })
      ForEach(GalleryDensity.all, (density: GalleryDensity) => {
        MenuItem({ content: `密度：${density.label}${this.galleryDensity === density.name ? ' ✓' : ''}` })
          .onClick(() => {
            this.galleryDensity = density.name;
            GalleryPrefs.densityName = density.name;
          })
      }, (density: GalleryDensity) => density.name)
    }
  }

  /** 海报墙：整面钉死 2:3，滚到底自动续（对应 iOS 的分页墙） */
  @Builder
  Wall() {
    Refresh({ refreshing: $$this.refreshing }) {
      // Scroll > Column > Flex 全量建改成 List + LazyForEach：按 2 列切行，每行一个 ListItem
      List({ scroller: this.scroller }) {
        LazyForEach(this.wallSource, (row: FavoriteItemView[]) => {
          ListItem() {
            this.WallRow(row)
          }
        }, (row: FavoriteItemView[]) => row.map((item: FavoriteItemView): string =>
          `${item.library_id}-${item.media_item_id}`).join('-'))
        ListItem() {
          AppFooter()
        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.None)
      .cachedCount(4)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: Theme.tabBarInset })
      .onReachEnd(() => {
        if (!this.reachedEnd && !this.loadingMore) {
          this.loadPage(this.items.length);
        }
      })
      .onScrollIndex((first: number) => {
        // 记下视口第一行所在的位置（按作品计）；滑过上次的位置，胶囊让位
        const offset: number = first * this.columns;
        FavoritesRecall.offset = offset;
        if (this.recallOffer >= 0 && offset >= this.recallOffer) {
          this.recallOffer = -1;
        }
      })
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .layoutWeight(1)
    .width('100%')
  }

  /** 底部胶囊：「回到上次浏览的位置」/ ✕ 不再提示 */
  @Builder
  RecallPill() {
    Row({ space: 4 }) {
      Text('回到上次浏览的位置')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#0b0d12')
        .padding({ left: 16, right: 4, top: 9, bottom: 9 })
        .onClick(() => {
          this.jumpToRecall();
        })
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(12)
        .fontColor(['rgba(0,0,0,0.55)'])
        .padding(6)
        .margin({ right: 10 })
        .onClick(() => {
          this.recallOffer = -1;
        })
    }
    .backgroundColor(Theme.accent)
    .borderRadius(19)
    .margin({ bottom: 18 })
    .shadow({ radius: 14, color: 'rgba(0,0,0,0.35)', offsetY: 4 })
  }

  private cellSubtitle(item: FavoriteItemView): string {
    const parts: string[] = [];
    const year: number | null = item.year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    const rating: number | null = item.rating ?? null;
    if (rating !== null && rating > 0) {
      parts.push(`★ ${rating.toFixed(1)}`);
    }
    return parts.join('  ·  ');
  }
}
