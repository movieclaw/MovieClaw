import { connection } from '@kit.NetworkKit';
import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ApiClient, ApiError, ApiQuery, QueryPair } from '../api/ApiClient';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';
import { Formatters } from '../common/Formatters';
import {
  FavoriteItemView,
  HomeRowPref,
  LibraryItemView,
  LibraryView,
  PlaybackHistoryClearView,
  UpNextItemView
} from '../api/Models';
import { LibraryHomePrefs, LibraryHomeStore } from './LibraryHomeStore';
import { LibraryCustomizeSheet } from './LibraryCustomizeSheet';
import { LibraryRouteParams } from './LibraryDetailPage';
import { CollectionRouteParams } from './CollectionDetailPage';
import { PlayerParams } from '../player/PlayerPage';
import { ChatParams } from '../agent/ChatPage';
import { TorrentParams } from '../search/TorrentResultsPage';
import { ReelsParams } from '../reels/ReelsPage';
import { RecycleParams } from './RecycleBinPage';
import { SubscriptionParams } from '../subscriptions/SubscriptionDetailPage';
import { ItemRouteParams } from './LibraryItemDetailPage';
import {
  CollectionRowKind,
  FavoritesKind,
  HomeRow,
  HomeRows,
  LibrariesKind,
  LibraryRowKind,
  UpNextKind
} from './HomeRows';
import {
  EmptyState,
  LibraryArtwork,
  LibraryKindMeta,
  LibraryPosterCell,
  LibraryProgressRing,
  LibrarySectionHeader,
  ScanPhase,
  episodeCode,
  favoriteLevelLabel,
  formatRecentAddition,
  libraryFromNow,
  libraryStatsSummary
} from './LibraryShared';

/** UpNextCard 的空默认值（ArkTS 组件属性必须有初值；父组件一定会覆盖） */
const EMPTY_UP_NEXT: UpNextItemView = {
  media_item_id: 0,
  library_id: 0,
  kind: 'movie',
  title: '',
  year: null,
  poster_url: null,
  poster_aspect: 0.66,
  backdrop_url: null,
  episode_still_url: null,
  season_number: 0,
  episode_number: 0,
  episode_title: null,
  unwatched_ahead_count: 0,
  position_ms: 0,
  duration_ms: null,
  progress_percent: null,
  advanced: false,
  last_played_at: ''
};

/** 横滚海报行里的一格（库行 / 合集行 / 收藏行统一形态，对应 iOS 端 PosterRowItem） */
class PosterRowItem {
  readonly id: number;
  readonly libraryId: number;
  readonly title: string;
  readonly year: number | null;
  /** 已解析成可请求的 URL；null = 无图 */
  readonly url: string | null;
  readonly aspect: number;
  /** 长按信息（最近添加的季集范围、入库时间、收藏层级） */
  readonly info: string[];

  constructor(id: number, libraryId: number, title: string, year: number | null,
    url: string | null, aspect: number, info: string[]) {
    this.id = id;
    this.libraryId = libraryId;
    this.title = title;
    this.year = year;
    this.url = url;
    this.aspect = aspect;
    this.info = info;
  }

  static fromItem(item: LibraryItemView, fallbackLibrary: number, origin: string): PosterRowItem {
    const info: string[] = [];
    if (item.kind === 'tv' && item.recent_addition !== null && item.recent_addition !== undefined) {
      const label: string | null = formatRecentAddition(item.recent_addition);
      if (label !== null) {
        info.push(label);
      }
    }
    if (item.added_at !== null && item.added_at !== undefined) {
      info.push(`${libraryFromNow(item.added_at)}入库`);
    }
    return new PosterRowItem(item.media_item_id, item.library_id ?? fallbackLibrary, item.title,
      item.year ?? null, ImageUrls.resolve(origin, item.poster_url, ImageVariant.posterCard),
      item.primary_aspect, info);
  }

  static fromFavorite(item: FavoriteItemView, origin: string): PosterRowItem {
    const level: string | null = favoriteLevelLabel(item.kind,
      item.favorite_season_number ?? null, item.favorite_episode_number ?? null);
    const info: string[] = level !== null ? [level] : [];
    return new PosterRowItem(item.media_item_id, item.library_id, item.title, item.year ?? null,
      ImageUrls.resolve(origin, item.poster_url, ImageVariant.posterCard), item.primary_aspect, info);
  }
}

/**
 * 首页行清单的数据源（LazyForEach 用）。
 *
 * 首页竖向外层是 List：每一行（接下来继续 / 收藏 / 我的媒体库 / 每个库一行「最近添加」/
 * 每个合集一行）都是一个 ListItem。行数 = 3 内置 + N 个可见库 + M 条自定义合集，
 * 一个库几十部时全量建树会一次建出几百个海报格——所以外层改成 List + LazyForEach，
 * 只建可视区附近的行。
 *
 * rows 每次 reload 整体重赋值（syncFromStore 里 HomeRows.build 返回全新数组，不是就地改字段），
 * 这里跟着整体换 + onDataReloaded；不做「内容没变就跳过」的指纹——中间某行条目更新了
 * 只看首尾 id 会漏掉（同 LibraryDetailPage.WallRowSource 的口径）。
 */
class HomeRowSource implements IDataSource {
  private rows: HomeRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): HomeRow {
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

  /** 整批换成这一批首页行 */
  setRows(rows: HomeRow[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * 「接下来继续」横卡（对应 iOS 端 UpNextCard / Web up-next-row）：
 * 分集剧照或背景图、续播进度、「还有 N 集」，中央常驻空心播放键直接进播放器
 * （触摸屏没有悬停，藏起来等于不存在）；点卡片进条目详情。
 */
@Component
struct UpNextCard {
  item: UpNextItemView = EMPTY_UP_NEXT;
  origin: string = '';
  /** 点卡片进条目详情（本组件是独立 struct，拿不到 navStack，由首页压栈） */
  onOpen: (item: UpNextItemView) => void = () => {
  };
  /** 中央播放键：直接开播（宿主负责压栈） */
  onPlay: (item: UpNextItemView) => void = () => {
  };
  /** 剧照地址在、但图加载失败：剧集印集号、电影退回海报模糊铺底（同 Web 的 fallback） */
  @State private artFailed: boolean = false;

  private isEpisode(): boolean {
    return this.item.kind === 'tv';
  }

  private code(): string | null {
    return this.isEpisode() ? episodeCode(this.item.season_number, this.item.episode_number) : null;
  }

  private context(): string {
    if (this.isEpisode()) {
      const parts: string[] = [];
      const code: string | null = this.code();
      if (code !== null) {
        parts.push(code);
      }
      const title: string | null = this.item.episode_title ?? null;
      if (title !== null && title.length > 0) {
        parts.push(title);
      }
      return parts.join(' · ');
    }
    const year: number | null = this.item.year ?? null;
    return year === null ? '' : `${year}`;
  }

  private artUrl(): string | null {
    const raw: string | null = this.isEpisode()
      ? (this.item.episode_still_url ?? null)
      : (this.item.backdrop_url ?? null);
    return ImageUrls.resolve(this.origin, raw, ImageVariant.landscapeCard);
  }

  private posterFallbackUrl(): string | null {
    return ImageUrls.resolve(this.origin, this.item.poster_url, ImageVariant.card(this.item.poster_aspect));
  }

  /** 「已播 / 总时长」：只在看了一半时出现（四舍五入到秒，同 Web） */
  private clockText(): string | null {
    const duration: number | null = this.item.duration_ms ?? null;
    if (this.item.position_ms <= 0 || duration === null || duration <= 0) {
      return null;
    }
    return `${Formatters.clock(Math.round(this.item.position_ms / 1000))} / ${Formatters.clock(Math.round(duration / 1000))}`;
  }

  /** 第三行：为什么它在这儿 */
  private stateLabel(): string {
    const ago: string = libraryFromNow(this.item.last_played_at);
    if (this.item.advanced) {
      return `${ago}看完上一集`;
    }
    const percent: number | null = this.item.progress_percent ?? null;
    if (this.item.position_ms > 0 && percent !== null && this.clockText() === null) {
      return `${ago}看到 ${percent}%`;
    }
    if (this.item.position_ms > 0) {
      return `${ago}看过一段`;
    }
    return `${ago}打开过`;
  }

  private comingSoon(feature: string): void {
    this.getUIContext().getPromptAction().showToast({ message: `「${feature}」建设中` });
  }

  @Builder
  FallbackArtwork() {
    if (this.isEpisode()) {
      LibraryArtwork({ url: '', frameAspect: 16 / 9, fallbackText: this.code() })
    } else {
      LibraryArtwork({
        url: this.posterFallbackUrl() ?? '',
        imageAspect: this.item.poster_aspect,
        frameAspect: 16 / 9,
        fallbackText: (this.item.poster_url ?? null) === null ? this.item.title : null
      })
    }
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.artUrl() !== null && !this.artFailed) {
          RemoteImage({
            url: this.artUrl() ?? '',
            onResult: (ok: boolean): void => {
              // 失败兜底要等渲染周期外再切，避免构建中改状态
              if (!ok) {
                setTimeout((): void => {
                  this.artFailed = true;
                }, 0);
              }
            }
          })
            .width('100%')
            .height('100%')
        } else {
          this.FallbackArtwork()
        }
        // 底部渐变，衬托时钟与进度条
        Column()
          .width('100%')
          .height(56)
          .linearGradient({ angle: 90, colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0.75)', 1]] })
        // 左下角：时钟 + 续播进度
        Column({ space: 4 }) {
          if (this.clockText() !== null) {
            Text(this.clockText() ?? '')
              .fontSize(11)
              .fontWeight(600)
              .fontColor('rgba(255, 255, 255, 0.85)')
          }
          if ((this.item.progress_percent ?? null) !== null) {
            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width('100%')
                .height(3)
                .borderRadius(1.5)
                .backgroundColor('rgba(255, 255, 255, 0.25)')
              Column()
                .width(`${this.item.progress_percent}%`)
                .height(3)
                .borderRadius(1.5)
                .backgroundColor(Theme.accent2)
            }
            .width('100%')
          } else if (this.item.position_ms > 0) {
            Column()
              .width('100%')
              .height(3)
              .borderRadius(1.5)
              .backgroundColor('rgba(159, 176, 201, 0.6)')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(8)
        // 右上角：还有 N 集
        Row() {
          if (this.isEpisode() && this.item.unwatched_ahead_count > 0) {
            Text(`还有 ${this.item.unwatched_ahead_count} 集`)
              .fontSize(11)
              .fontWeight(600)
              .fontColor('#D1FAE5')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('rgba(5, 46, 34, 0.76)')
              .borderRadius(11)
              .border({ width: 1, color: 'rgba(166, 242, 209, 0.25)' })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Top)
        .padding(8)
        // 中央常驻播放键
        Row() {
          Column() {
            SymbolGlyph($r('sys.symbol.play_fill'))
              .fontSize(17)
              .fontColor(['#ffffff'])
          }
          .width(42)
          .height(42)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(21)
          .border({ width: 1.5, color: 'rgba(255, 255, 255, 0.75)' })
          .shadow({ radius: 5, color: 'rgba(0, 0, 0, 0.45)', offsetY: 2 })
          .onClick(() => {
            // 「接下来继续」点开直接看：带上季集与续播位置
            this.onPlay(this.item);
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .aspectRatio(16 / 9)
      .borderRadius(Theme.cardRadius)
      .clip(true)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.08)' })
      .shadow({ radius: 14, color: 'rgba(0, 0, 0, 0.38)', offsetY: 10 })
      .onClick(() => {
        this.onOpen(this.item);
      })

      Column({ space: 2 }) {
        Text(this.item.title)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.context().length > 0) {
          Text(this.context())
            .fontSize(13)
            .fontColor(Theme.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.stateLabel())
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 8 })
    }
    .width(200)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onOpen(this.item);
    })
  }
}

/**
 * 媒体库首页（对应 iOS 端 LibraryHomeView，Web library-view.tsx）：
 * 标题统计 + 按偏好合并出的行清单——接下来继续 / 我的收藏 / 我的媒体库（库卡片 +
 * 扫描进度环）/ 每库一行 / 合集行。只负责「看」，排序与行的增删改收进自定义页。
 *
 * 刷新策略同 Web：扫描/整理中 3 秒一轮（结束后再保持 12 秒快轮询），元数据刷新 5 秒，
 * 有文件等待入账 10 秒，空闲 30 秒。瞬时失败不清已有数据，只挂提示条；
 * 一次都没成功过才整页报错。
 */
@Component
export struct LibraryHomeView {
  /** 页签内导航栈（LibraryNavHost 注入）：库卡片 → 单库页，全部合集等 */
  navStack: NavPathStack = new NavPathStack();
  /** 菜单里点「自定义首页」时宿主把它加一；这里接住并弹层 */
  @Prop @Watch('onCustomizeSignal') customizeSignal: number = 0;
  private permissions: Permissions = Permissions.none();
  /** 整页数据在跟着账号走的共享对象里；这里只持 @State 副本，reload 后整体重赋值 */
  @State private libraries: LibraryView[] | null = null;
  @State private visibleLibraries: LibraryView[] = [];
  @State private collections: number[] = [];
  @State private upNext: UpNextItemView[] = [];
  @State private favoritesItems: PosterRowItem[] = [];
  @State private favoritesTotal: number = 0;
  @State private rowItems: Record<string, LibraryItemView[]> = {};
  @State private rows: HomeRow[] = [];
  @State private failed: boolean = false;
  /** 扫描/整理结束后的 12 秒快轮询窗口还没过（同 Web recentlyBusy） */
  @State private recentlyBusy: boolean = false;
  @State private refreshing: boolean = false;
  /** 「清空某个媒体库的观看记录」选择框 */
  @State private pickerLibraryId: number | null = null;
  @State private clearingBusy: boolean = false;
  /** 轮询定时器句柄；-1 = 没在轮询 */
  private pollTimer: number = -1;
  /** 竖向列表的滚动器（外层 Scroll 换成 List 后保留，口径不变） */
  private scroller: Scroller = new Scroller();
  /** 首页行清单的懒加载数据源（LazyForEach 只建可视区附近的行） */
  private rowSource: HomeRowSource = new HomeRowSource();

  aboutToAppear(): void {
    this.permissions = Permissions.fromSession(AppModel.shared.session);
    this.reload();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  // MARK: 加载与轮询

  private async reload(): Promise<void> {
    this.stopPolling();
    const api = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const client = AppModel.shared.client;
    const session = AppModel.shared.session;
    const key: string = LibraryHomePrefs.ownerKey(client !== null ? client.origin : '',
      session === null ? null : session.username);
    await LibraryHomeStore.shared.reload(api, key);
    this.syncFromStore();
    this.scheduleNextPoll();
  }

  /** 把共享 Store 的数据抄进 @State 副本（整页重赋值触发刷新） */
  private syncFromStore(): void {
    const store = LibraryHomeStore.shared;
    const origin: string = AppModel.origin();
    this.libraries = store.libraries;
    this.visibleLibraries = (store.libraries ?? [])
      .filter((library: LibraryView): boolean => library.viewer_access);
    this.collections = store.collections.map((collection): number => collection.id);
    this.upNext = store.upNext ?? [];
    this.favoritesItems = store.favorites !== null
      ? store.favorites.items.map((item: FavoriteItemView): PosterRowItem => PosterRowItem.fromFavorite(item, origin))
      : [];
    this.favoritesTotal = store.favorites !== null ? store.favorites.total : 0;
    this.failed = store.failed;
    this.recentlyBusy = store.busyUntil > Date.now();
    const prefsRows: HomeRowPref[] | null = LibraryHomePrefs.shared.rows;
    this.rows = HomeRows.build(prefsRows ?? [], store.libraries ?? [], store.collections)
      .filter((row: HomeRow): boolean => !row.hidden);
    const record: Record<string, LibraryItemView[]> = {};
    store.itemsByKey.forEach((items: LibraryItemView[], key: string) => {
      record[key] = items;
    });
    this.rowItems = record;
    this.rowSource.setRows(this.rows);
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private scheduleNextPoll(): void {
    this.stopPolling();
    this.pollTimer = setTimeout((): void => {
      this.pollTimer = -1;
      this.reload();
    }, this.pollInterval() * 1000);
  }

  /** 轮询间隔：忙 3s / 刷元数据 5s / 有待入账 10s / 空闲 30s（同 Web） */
  private pollInterval(): number {
    const libs: LibraryView[] = this.libraries ?? [];
    for (const lib of libs) {
      if (lib.scanning || lib.organizing) {
        return 3;
      }
    }
    if (this.recentlyBusy) {
      return 3;
    }
    for (const lib of libs) {
      if (lib.metadata_refresh !== null && lib.metadata_refresh !== undefined && lib.metadata_refresh.refreshing) {
        return 5;
      }
    }
    for (const lib of libs) {
      if (!lib.scanning && !lib.organizing && (lib.last_scan?.deferred ?? 0) > 0) {
        return 10;
      }
    }
    return 30;
  }

  // MARK: 小工具

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  /** 弹层槽位：空串=关，libraryPicker=选媒体库，customize=自定义首页 */
  @State private sheetKind: string = '';
  @State private showSheet: boolean = false;

  onCustomizeSignal(): void {
    if (this.customizeSignal > 0) {
      this.sheetKind = 'customize';
      this.showSheet = true;
    }
  }

  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'customize') {
      LibraryCustomizeSheet({
        onClose: (): void => {
          this.showSheet = false;
          this.syncFromStore();
        }
      })
    } else {
      this.LibraryPickerSheet()
    }
  }

  /** 新建媒体库（对应 iOS 的 `ManageCreateLibraryForm` 向导） */
  private openCreateLibrary(): void {
    this.navStack.pushPathByName('libraryCreate', null);
  }

  /** 尚未建成的子页面统一以「建设中」承接 */
  private comingSoon(feature: string): void {
    this.toast(`「${feature}」建设中，将在后续版本开放`);
  }

  private canManageLibraries(): boolean {
    return this.permissions.canManageLibraries;
  }

  private statsText(): string {
    if (this.failed && this.libraries === null) {
      return '暂时无法获取媒体库统计，正在自动重试';
    }
    return libraryStatsSummary(this.libraries === null ? null : this.visibleLibraries);
  }

  /** 库行 / 合集行各自的条目（已换成海报格要的形态） */
  private rowPosterItems(row: HomeRow): PosterRowItem[] {
    const items: LibraryItemView[] = this.rowItems[LibraryHomeStore.fetchKey(row)] ?? [];
    const origin: string = AppModel.origin();
    let fallback: number = 0;
    if (row.kind instanceof LibraryRowKind) {
      fallback = row.kind.library.id;
    } else if (row.kind instanceof CollectionRowKind) {
      fallback = row.kind.collection.library_id ?? 0;
    }
    return items.map((item: LibraryItemView): PosterRowItem => PosterRowItem.fromItem(item, fallback, origin));
  }

  /** 库卡片封面与默认「最近添加」行共用一份条目：有素材才请求服务端拼贴 */
  private libraryHasPosters(library: LibraryView): boolean {
    const items: LibraryItemView[] = this.rowItems[LibraryHomeStore.coverKey(library.id)] ?? [];
    return items.length > 0;
  }

  private libraryBusy(library: LibraryView): boolean {
    return library.scanning || library.organizing
      || (library.metadata_refresh !== null && library.metadata_refresh !== undefined
        && library.metadata_refresh.refreshing);
  }

  private busyProcessed(library: LibraryView): number | null {
    if (library.scanning && library.scan_progress !== null && library.scan_progress !== undefined) {
      return library.scan_progress.processed;
    }
    if (library.organizing && library.organize_progress !== null && library.organize_progress !== undefined) {
      return library.organize_progress.processed;
    }
    if (library.metadata_refresh !== null && library.metadata_refresh !== undefined
      && library.metadata_refresh.refreshing) {
      return library.metadata_refresh.processed;
    }
    return null;
  }

  private busyTotal(library: LibraryView): number | null {
    if (library.scanning && library.scan_progress !== null && library.scan_progress !== undefined) {
      return library.scan_progress.total;
    }
    if (library.organizing && library.organize_progress !== null && library.organize_progress !== undefined) {
      return library.organize_progress.total;
    }
    if (library.metadata_refresh !== null && library.metadata_refresh !== undefined
      && library.metadata_refresh.refreshing) {
      return library.metadata_refresh.total;
    }
    return null;
  }

  private busyLabel(library: LibraryView): string {
    if (library.scanning) {
      return ScanPhase.label(library.scan_progress?.phase ?? null);
    }
    if (library.organizing) {
      return '整理中';
    }
    return '刷新元数据';
  }

  /** 元数据刷新进行中时，正在处理的那一条（「标题 · 阶段」） */
  private refreshingActiveLine(library: LibraryView): string | null {
    const refresh = library.metadata_refresh;
    if (refresh === null || refresh === undefined || !refresh.refreshing || refresh.active.length === 0) {
      return null;
    }
    return `${refresh.active[0].title} · ${refresh.active[0].phase}`;
  }

  /** 扫描结束后有待入账文件时挂「N 个新文件入库中」 */
  private libraryImporting(library: LibraryView): number {
    if (this.libraryBusy(library)) {
      return 0;
    }
    return library.last_scan?.deferred ?? 0;
  }

  // MARK: 清空观看记录

  private confirmClearHistory(which: number): void {
    const now = new Date();
    let label: string = '';
    let description: string = '';
    let sinceIso: string | null = null;
    if (which === 0) {
      label = '今天的观看记录';
      sinceIso = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString();
      description = '今天播放过的作品，续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。';
    } else if (which === 1) {
      label = '最近一周的观看记录';
      sinceIso = new Date(now.getTime() - 7 * 86400 * 1000).toISOString();
      description = '最近 7 天播放过的作品，续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。';
    } else {
      label = '全部观看记录';
      description = '所有作品的续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录；应用更新前的自动备份仍包含历史记录。';
    }
    AlertDialog.show({
      title: `清空${label}？`,
      message: description,
      primaryButton: {
        value: '清空',
        fontColor: Theme.danger,
        action: (): void => {
          this.performClearHistory(label, sinceIso);
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
        }
      }
    });
  }

  private async performClearHistory(label: string, sinceIso: string | null): Promise<void> {
    const client: ApiClient | null = AppModel.shared.client;
    if (client === null) {
      return;
    }
    const pairs: QueryPair[] = [{ key: 'scope', value: 'all' }];
    if (sinceIso !== null) {
      pairs.push({ key: 'since', value: sinceIso });
    }
    try {
      const result = await client.delWithMessage<PlaybackHistoryClearView>(
        '/playback/history' + ApiQuery.build(pairs), null);
      if (sinceIso !== null) {
        this.toast(result.data.deleted_states > 0 ? `已清空${label}` : `${label}里没有可清除的记录`);
      } else {
        this.toast(result.message.length > 0 ? result.message : '已清空全部观看记录');
      }
      await this.reload();
    } catch (error) {
      const err = error as Error;
      this.toast(err instanceof ApiError ? err.message : '清空观看记录失败，请稍后重试');
    }
  }

  private openLibraryPicker(): void {
    this.pickerLibraryId = this.visibleLibraries.length > 0 ? this.visibleLibraries[0].id : null;
    this.clearingBusy = false;
    this.sheetKind = 'libraryPicker';
                this.showSheet = true;
  }

  private pickerButtonTitle(): string {
    if (this.clearingBusy) {
      return '清空中…';
    }
    for (const library of this.visibleLibraries) {
      if (library.id === this.pickerLibraryId) {
        return `清空「${library.name}」`;
      }
    }
    return '清空';
  }

  private async submitLibraryClear(): Promise<void> {
    const client: ApiClient | null = AppModel.shared.client;
    const libraryId: number | null = this.pickerLibraryId;
    if (client === null || libraryId === null || this.clearingBusy) {
      return;
    }
    this.clearingBusy = true;
    const pairs: QueryPair[] = [
      { key: 'scope', value: 'library' },
      { key: 'library_id', value: libraryId }
    ];
    try {
      const result = await client.delWithMessage<PlaybackHistoryClearView>(
        '/playback/history' + ApiQuery.build(pairs), null);
      this.toast(result.message.length > 0 ? result.message : '已清空该库的观看记录');
      this.showSheet = false;
      await this.reload();
    } catch (error) {
      const err = error as Error;
      this.toast(err instanceof ApiError ? err.message : '清空观看记录失败，请稍后重试');
    } finally {
      this.clearingBusy = false;
    }
  }

  // MARK: 片段入口

  /** 片段直接播原片，蜂窝/计费网络先确认一次（一期鸿蒙只识别蜂窝） */
  private openReels(): void {
    this.checkCellular().then((cellular: boolean): void => {
      if (cellular) {
        AlertDialog.show({
          title: '正在使用移动网络',
          message: '片段直接播放原片，可能很耗流量：4K 影片看完一段约 300MB。确定进入吗？',
          primaryButton: {
            value: '进入',
            action: (): void => {
              this.enterReels();
            }
          },
          secondaryButton: {
            value: '取消',
            action: (): void => {
            }
          }
        });
      } else {
        this.enterReels();
      }
    });
  }

  /** 真正进片段页：`ReelsParams` 的 libraryId 传 0 = 全库混排（这里是多库首页，没有单个库） */
  private enterReels(): void {
    this.navStack.pushPathByName('reels', new ReelsParams(0));
  }

  private async checkCellular(): Promise<boolean> {
    try {
      const netHandle: connection.NetHandle = await connection.getDefaultNet();
      const capabilities: connection.NetCapabilities = await connection.getNetCapabilities(netHandle);
      return capabilities.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR);
    } catch (error) {
      // 拿不到网络能力时不拦人
      return false;
    }
  }

  // MARK: 布局

  build() {
    Column() {
      Refresh({ refreshing: $$this.refreshing }) {
        // 用 List 而不是 Scroll + Column：只有 List / Grid / Swiper / WaterFlow 这类容器
        // 才让 LazyForEach 按可视区建组件。首页每一行分节是一个 ListItem（见 Content）。
        List({ scroller: this.scroller }) {
          ListItem() {
            this.StatsHeader()
          }
          this.Content()
          ListItem() {
            AppFooter()
          }
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.None)
        // 可视区上下各多缓存几行，快速滑动时少建少销毁
        .cachedCount(4)
        .padding({ bottom: Theme.tabBarInset })
      }
      .onRefreshing(() => {
        this.reload().then((): void => {
          this.refreshing = false;
        });
      })
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    // **一个组件只能绑一个 bindSheet**（后绑的覆盖前面的），所以合成单槽位 + 内容切换
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }


  /** 统计行 */
  @Builder
  StatsHeader() {
    Text(this.statsText())
      .fontSize(15)
      .fontColor(Theme.textMuted)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4 })
  }

  @Builder
  Content() {
    if (this.libraries === null && !this.failed) {
      ListItem() {
        Row({ space: 10 }) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color(Theme.textMuted)
          Text('正在加载媒体库…')
            .fontSize(15)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 64 })
      }
    } else if (this.libraries === null && this.failed) {
      ListItem() {
        Column({ space: 12 }) {
          Text('媒体库加载失败')
            .fontSize(15)
            .fontColor(Theme.textMuted)
          Text('重试')
            .fontSize(15)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(20)
            .border({ width: 1, color: Theme.lineStrong })
            .onClick(() => {
              this.reload();
            })
        }
        .width('100%')
        .padding({ top: 64 })
      }
    } else {
      if (this.failed) {
        ListItem() {
          this.FailedBanner()
        }
      }
      if ((this.libraries ?? []).length === 0) {
        ListItem() {
          EmptyState({
            systemImage: $r('sys.symbol.film'),
            title: this.canManageLibraries() ? '为收藏准备一个家' : '还没有可浏览的媒体库',
            message: this.canManageLibraries()
              ? '创建电影库或剧集库，选好根目录后，订阅完成的内容会自动整理到这里。'
              : '当前账号暂时没有可浏览的媒体库，请联系管理员分配媒体库权限。',
            actionTitle: this.canManageLibraries() ? '创建第一个媒体库' : null,
            onAction: this.canManageLibraries()
              ? (): void => {
                this.openCreateLibrary();
              }
              : null
          })
            .padding({ top: 40 })
        }
      } else if (this.rows.length === 0) {
        ListItem() {
          this.AllHiddenBox()
        }
      } else {
        // 首页各分节行：LazyForEach 只建可视区附近的行（外层是 List，见 build）
        LazyForEach(this.rowSource, (row: HomeRow) => {
          ListItem() {
            this.RowView(row)
          }
        }, (row: HomeRow) => row.id)
      }
    }
  }

  /** 瞬时失败提示条：已有数据继续显示，自动重试 */
  @Builder
  FailedBanner() {
    Column() {
      Text('与后端通信失败，正在自动重试；下方显示的是最近一次成功加载的数据')
        .fontSize(13)
        .fontColor('#FCE68A')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .width('100%')
        .backgroundColor('rgba(251, 191, 36, 0.1)')
        .borderRadius(12)
        .border({ width: 1, color: 'rgba(251, 191, 36, 0.25)' })
    }
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16 })
    .width('100%')
  }

  /** 所有行都被隐藏了 */
  @Builder
  AllHiddenBox() {
    Column() {
      Column({ space: 6 }) {
        Text('首页空空如也')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text('所有行都被隐藏了。到「自定义首页」挑几行回来，或恢复默认。')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
        Text('自定义首页')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.lineStrong })
          .margin({ top: 10 })
          .onClick(() => {
            this.sheetKind = 'customize';
            this.showSheet = true;
          })
      }
      .padding({ left: 24, right: 24, top: 32, bottom: 32 })
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.15)', radius: 16, style: BorderStyle.Dashed })
    }
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 64 })
    .width('100%')
  }

  /**
   * 「查看全部」的去处。
   *
   * 抽成方法而不是在 `@Builder` 里写闭包，是因为**闭包会丢掉 `instanceof` 的类型收窄**
   * （`@Builder` 里又不许写 `const` 存一份），写成方法就能把收窄后的类型当参数传进来。
   */
  private moreForLibrary(kind: LibraryRowKind): () => void {
    return (): void => {
      this.navStack.pushPathByName('libraryDetail', new LibraryRouteParams(kind.library.id));
    };
  }

  private moreForCollection(kind: CollectionRowKind): () => void {
    return (): void => {
      this.navStack.pushPathByName('collectionDetail',
        new CollectionRouteParams(kind.collection.id, kind.collection.library_id ?? 0));
    };
  }

  @Builder
  RowView(row: HomeRow) {
    if (row.kind instanceof UpNextKind) {
      this.UpNextRow(row)
    } else if (row.kind instanceof FavoritesKind) {
      this.FavoritesRow(row)
    } else if (row.kind instanceof LibrariesKind) {
      this.LibrariesRow(row)
    } else if (row.kind instanceof LibraryRowKind) {
      // @Builder 里不能写 const，直接内联
      this.PosterRow(row.title(), '查看全部', this.rowPosterItems(row),
        this.moreForLibrary(row.kind as LibraryRowKind))
    } else if (row.kind instanceof CollectionRowKind) {
      this.PosterRow(row.title(), '查看全部', this.rowPosterItems(row),
        this.moreForCollection(row.kind as CollectionRowKind))
    }
  }

  @Builder
  UpNextRow(row: HomeRow) {
    if (this.upNext.length > 0) {
      Column({ space: 12 }) {
        this.UpNextHeader(row.title())
        Scroll() {
          Row({ space: 12 }) {
            ForEach(this.upNext, (item: UpNextItemView) => {
              UpNextCard({
                item: item,
                origin: AppModel.origin(),
                onOpen: (picked: UpNextItemView): void => {
                  this.navStack.pushPathByName('libraryItem',
                    new ItemRouteParams(picked.library_id, picked.media_item_id));
                },
                onPlay: (picked: UpNextItemView): void => {
                  this.navStack.pushPathByName('player', new PlayerParams(
                    picked.media_item_id, 0, picked.season_number, picked.episode_number,
                    picked.position_ms));
                }
              })
            }, (item: UpNextItemView) => `${item.media_item_id}`)
          }
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .padding({ top: 24 })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 「接下来继续」标题 + 右侧 ⋯（清空观看记录菜单） */
  @Builder
  UpNextHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(20)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize(17)
        .fontWeight(600)
        .fontColor([Theme.textMuted])
        .width(30)
        .height(30)
        .bindMenu(this.WatchHistoryMenu())
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    .alignItems(VerticalAlign.Bottom)
  }

  /** ⋯：今天 / 最近一周 / 全部 / 某个媒体库（同 Web WatchHistoryMenu） */
  @Builder
  WatchHistoryMenu() {
    Menu() {
      MenuItemGroup() {
        MenuItem({ content: '清空今天的观看记录…' })
          .onClick(() => {
            this.confirmClearHistory(0);
          })
        MenuItem({ content: '清空最近一周的观看记录…' })
          .onClick(() => {
            this.confirmClearHistory(1);
          })
        MenuItem({ content: '清空全部观看记录…' })
          .onClick(() => {
            this.confirmClearHistory(2);
          })
      }
      MenuItemGroup() {
        MenuItem({ content: '清空某个媒体库的观看记录…' })
          .onClick(() => {
            this.openLibraryPicker();
          })
      }
    }
  }

  @Builder
  FavoritesRow(row: HomeRow) {
    if (this.favoritesItems.length > 0) {
      this.PosterRow(row.title(), `查看全部 ${this.favoritesTotal} 部`, this.favoritesItems, (): void => {
        this.navStack.pushPathByName('favorites', null);
      })
    }
  }

  @Builder
  LibrariesRow(row: HomeRow) {
    if (this.visibleLibraries.length > 0) {
      Column({ space: 12 }) {
        LibrarySectionHeader({
          title: row.title(),
          trailingText: this.collections.length > 0 ? '全部合集 ›' : '',
          onTrailing: this.collections.length > 0
            ? (): void => {
              this.navStack.pushPathByName('allCollections', null);
            }
            : null
        })
        Scroll() {
          Row({ space: 14 }) {
            ForEach(this.visibleLibraries, (library: LibraryView) => {
              Column() {
                this.LibraryCard(library)
              }
              .width(230)
              .onClick(() => {
                this.navStack.pushPathByName('libraryDetail', new LibraryRouteParams(library.id));
              })
            }, (library: LibraryView) => `${library.id}`)
          }
          .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .padding({ top: 24 })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /** 库卡片：服务端拼贴封面 + 库名 +「默认」；扫描/整理/刷元数据时封面归进度环 */
  @Builder
  LibraryCard(library: LibraryView) {
    Column({ space: 10 }) {
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({ angle: 135, colors: [['#1C212E', 0], ['#0F121C', 1]] })
        SymbolGlyph(LibraryKindMeta.symbol(library.kind))
          .fontSize(40)
          .fontColor(['rgba(255, 255, 255, 0.13)'])
        if (this.libraryHasPosters(library) || library.custom_cover) {
          RemoteImage({
            url: ImageUrls.resolve(AppModel.origin(), `/libraries/${library.id}/cover`, null) ?? '',
            placeholderSymbol: LibraryKindMeta.symbol(library.kind)
          })
            .width('100%')
            .height('100%')
        }
        if (this.libraryBusy(library)) {
          Column({ space: 4 }) {
            LibraryProgressRing({
              processed: this.busyProcessed(library),
              total: this.busyTotal(library),
              ringSize: 62
            })
            Text(this.busyLabel(library))
              .fontSize(12)
              .fontWeight(600)
              .fontColor('rgba(255, 255, 255, 0.85)')
            if (this.refreshingActiveLine(library) !== null) {
              Text(this.refreshingActiveLine(library) ?? '')
                .fontSize(11)
                .fontColor('rgba(255, 255, 255, 0.6)')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .padding({ left: 12, right: 12 })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(0, 0, 0, 0.55)')
        } else if (this.libraryImporting(library) > 0) {
          Row() {
            Row({ space: 6 }) {
              Circle()
                .width(6)
                .height(6)
                .fill(Theme.info)
              Text(`${this.libraryImporting(library)} 个新文件入库中`)
                .fontSize(11)
                .fontWeight(600)
                .fontColor(Theme.info)
            }
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor('rgba(0, 0, 0, 0.55)')
            .borderRadius(11)
            .border({ width: 1, color: 'rgba(127, 176, 255, 0.35)' })
          }
          .width('100%')
          .height('100%')
          .alignItems(VerticalAlign.Bottom)
          .justifyContent(FlexAlign.Start)
          .padding(8)
        }
      }
      .width('100%')
      .aspectRatio(2.1)
      .borderRadius(Theme.cardRadius)
      .clip(true)
      .border({ width: 1, color: 'rgba(255, 255, 255, 0.1)' })
      Row({ space: 8 }) {
        Text(library.name)
          .fontSize(17)
          .fontWeight(600)
          .fontColor('#ffffff')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (library.is_default) {
          Text('默认')
            .fontSize(11)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.8)')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor('rgba(255, 255, 255, 0.1)')
            .borderRadius(9)
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)' })
        }
      }
      .padding({ left: 8, right: 8 })
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 横滚海报行（收藏行 / 库行 / 合集行统一形态） */
  @Builder
  PosterRow(title: string, moreTitle: string, items: PosterRowItem[], onMore: () => void) {
    Column({ space: 12 }) {
      LibrarySectionHeader({
        title: title,
        trailingText: moreTitle,
        onTrailing: (): void => {
          onMore();
        }
      })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(items, (item: PosterRowItem) => {
            Column() {
              LibraryPosterCell({
                title: item.title,
                year: item.year,
                url: item.url ?? '',
                imageAspect: item.aspect,
                frameAspect: Theme.posterAspect
              })
            }
            .width(124)
            .onClick(() => {
              this.navStack.pushPathByName('libraryItem', new ItemRouteParams(item.libraryId, item.id));
            })
            .bindContextMenu(this.PosterInfoMenu(item), ResponseType.LongPress)
          }, (item: PosterRowItem) => `${item.id}`)
        }
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .padding({ top: 24 })
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 长按海报：最近添加的季集范围、入库时间、收藏层级 */
  @Builder
  PosterInfoMenu(item: PosterRowItem) {
    Menu() {
      ForEach(item.info, (line: string) => {
        MenuItem({ content: line })
      }, (line: string) => line)
    }
  }

  /** 「清空某个媒体库的观看记录」选择框（同 Web ClearLibraryHistoryDialog） */
  @Builder
  LibraryPickerSheet() {
    Column() {
      Row() {
        Text('清空某个媒体库的观看记录')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
          .layoutWeight(1)
          .maxLines(1)
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .onClick(() => {
            this.showSheet = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 8 })

      Column() {
        if (this.visibleLibraries.length === 0) {
          Text('没有可浏览的媒体库')
            .fontSize(15)
            .fontColor(Theme.textMuted)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        }
        ForEach(this.visibleLibraries, (library: LibraryView) => {
          Row({ space: 10 }) {
            Text(library.name)
              .fontSize(15)
              .fontColor(Theme.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.pickerLibraryId === library.id) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(16)
                .fontColor([Theme.accentStrong])
            }
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 12 })
          .onClick(() => {
            this.pickerLibraryId = library.id;
          })
        }, (library: LibraryView) => `${library.id}-${this.pickerLibraryId === library.id ? '1' : '0'}`)
      }
      .width('100%')

      Text('选中库里所有作品的续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。')
        .fontSize(12)
        .fontColor(Theme.textMuted)
        .padding({ left: 20, right: 20, top: 12 })
        .width('100%')

      Text(this.pickerButtonTitle())
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.danger)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .margin({ left: 20, right: 20, top: 8 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(12)
        .opacity(this.pickerLibraryId !== null && !this.clearingBusy ? 1 : 0.4)
        .enabled(this.pickerLibraryId !== null && !this.clearingBusy)
        .onClick(() => {
          this.submitLibraryClear();
        })
    }
    .width('100%')
    .padding({ bottom: 24 })
  }
}
