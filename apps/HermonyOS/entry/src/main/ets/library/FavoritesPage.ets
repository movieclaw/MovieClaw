import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { FavoriteItemView, FavoritesView } from '../api/Models';
import { ItemRouteParams } from './LibraryItemDetailPage';
import { AppFooter } from '../common/AppFooter';

/** 排序档（与单库墙同一套口径，对应 iOS `FavoritesView` 的排序） */
class FavSort {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const SORTS: FavSort[] = [
  new FavSort('added_at', '最近收藏'),
  new FavSort('release_date', '按上映时间'),
  new FavSort('title', '按标题'),
  new FavSort('rating', '按评分')
];

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
 * **没做**：图床浏览（iOS 的第二种形态）、「回到上次浏览的位置」。
 */
@ComponentV2
export struct FavoritesPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private loadingMore: boolean = false;
  private reachedEnd: boolean = false;
  /** 收藏墙的行数据源（LazyForEach 只建可视区附近的行） */
  private wallSource: FavoritesWallSource = new FavoritesWallSource();

  @Local private items: FavoriteItemView[] = [];
  @Local private total: number = 0;
  @Local private sort: string = 'added_at';
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private refreshing: boolean = false;
  @Local private showSort: boolean = false;

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
  }

  private async loadPage(offset: number): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    try {
      const view: FavoritesView = await api.playbackFavorites(PAGE_SIZE, offset, undefined, this.sort);
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

  private sortLabel(): string {
    for (const option of SORTS) {
      if (option.value === this.sort) {
        return option.label;
      }
    }
    return '最近收藏';
  }

  /** 每格落回它自己所属的库（跨库墙的关键：不能都往一个库跳） */
  private openItem(item: FavoriteItemView): void {
    this.navStack.pushPathByName('libraryItem',
      new ItemRouteParams(item.library_id, item.media_item_id));
  }

  private pickSort(value: string): void {
    if (value === this.sort) {
      return;
    }
    this.sort = value;
    this.showSort = false;
    this.load();
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
          // 右上角动作（原来挂在原生 menus 上；改自绘顶栏后要自己放）
          this.TopRight()
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
          this.Wall()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    // iOS `.navigationTitle("我的收藏")` inline：原生标题栏，返回按钮系统自带；
    // 右上角排序触发移入原生 menus（对应 iOS 工具栏）
    .hideTitleBar(true)
    .bindSheet($$this.showSort, this.SortSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        this.load();
      }
    })
  }

  /** 右上角动作：排序（原自绘顶栏右侧按钮） */
  @Builder
  TopRight() {
    SymbolGlyph($r('sys.symbol.line_3_horizontal'))
      .fontSize(18)
      .fontColor([Theme.textMuted])
      .width(36)
      .height(36)
      .onClick(() => {
        this.showSort = true;
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

  /** 海报墙：整面钉死 2:3，滚到底自动续（对应 iOS 的分页墙） */
  @Builder
  Wall() {
    Refresh({ refreshing: $$this.refreshing }) {
      // Scroll > Column > Flex 全量建改成 List + LazyForEach：按 2 列切行，每行一个 ListItem
      List() {
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
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
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

  @Builder
  SortSheet() {
    Column() {
      Text('排序')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .padding({ top: 16, bottom: 10 })
      ForEach(SORTS, (option: FavSort) => {
        Row({ space: 10 }) {
          Text(option.label)
            .fontSize(16)
            .fontColor(Theme.text)
            .layoutWeight(1)
          if (option.value === this.sort) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(16)
              .fontColor([Theme.accent])
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 13, bottom: 13 })
        .onClick(() => {
          this.pickSort(option.value);
        })
      }, (option: FavSort) => option.value)
    }
    .width('100%')
    .padding({ bottom: 20 })
  }
}
