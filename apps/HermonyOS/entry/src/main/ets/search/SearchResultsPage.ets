import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { Formatters } from '../common/Formatters';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { DiscoveredTitleView, TitleSearchPayload, TitleSearchView } from '../api/Models';
import { DiscoverDetailParams } from '../discover/DiscoverDetailPage';
import { TorrentParams } from './TorrentResultsPage';
import { SearchAccess } from './SearchAccess';
import { LibrarySearchResults } from './LibrarySearchResults';

/** 搜索竖向（与搜索首页共用同一套取值） */
export class SearchMode {
  static readonly library: string = 'library';
  static readonly media: string = 'media';
  static readonly torrent: string = 'torrent';
}

/** 结果页搜索词胶囊回传草稿的 AppStorage 键（与搜索首页共用，值由首页解析后清掉） */
const DRAFT_STORAGE_KEY: string = 'mc_search_draft';

/**
 * 搜索结果页的路由参数。
 * 同前几页：路由参数会被序列化，**不要用 `instanceof`**，按字段取值。
 * `snapshotId` 非 0 = 从历史回放快照（结果页秒开，顶上提示快照年龄）。
 */
export class SearchParams {
  readonly keyword: string;
  readonly mode: string;
  readonly snapshotId: number;

  constructor(keyword: string, mode: string, snapshotId: number = 0) {
    this.keyword = keyword;
    this.mode = mode;
    this.snapshotId = snapshotId;
  }

  static of(param: Object | undefined | null): SearchParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: SearchParams = param as SearchParams;
    const keyword: string = raw.keyword;
    if (keyword === undefined || keyword === null || keyword.length === 0) {
      return null;
    }
    const mode: string = raw.mode;
    const snapshotId: number = raw.snapshotId;
    return new SearchParams(keyword,
      mode === undefined || mode === null ? SearchMode.library : mode,
      Number.isFinite(snapshotId) ? Math.floor(snapshotId) : 0);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function SearchResultsBuilder() {
  SearchResultsPage()
}

/**
 * 影视搜索分区的数据源（LazyForEach 用）：海报按两列一行切块（对应 iOS `DiscoverGrid.wideColumns`），
 * 结果整批回来时整体换、整体 onDataReloaded。
 */
class TitleRowsSource implements IDataSource {
  private rows: DiscoveredTitleView[][] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): DiscoveredTitleView[] {
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

  setTitles(titles: DiscoveredTitleView[]): void {
    const rows: DiscoveredTitleView[][] = [];
    for (let i: number = 0; i < titles.length; i += 2) {
      const end: number = Math.min(i + 2, titles.length);
      const row: DiscoveredTitleView[] = [];
      for (let j: number = i; j < end; j++) {
        row.push(titles[j]);
      }
      rows.push(row);
    }
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

/**
 * 「影视」垂直（对齐 iOS `MediaSearchResultsView`）：`POST /search/titles` 同时搜豆瓣与 TMDB，
 * 两个来源分区并列（没有可靠对齐键，不合并去重），单边失败只在该分区提示；
 * 两边都空时给「搜索站点资源」逃生入口。
 * 快照回放读历史留存结果，不访问上游；快照缺失（被清理/老数据）回退实时搜索。
 * 独立成组件：父页用 `.visibility` 切换保活（切走不卸载、切回不重搜）。
 */
@ComponentV2
export struct MediaSearchResultsView {
  @Require @Param keyword: string;
  @Require @Param navStack: NavPathStack;
  /** 有资源搜索权限才给「搜索站点资源」逃生入口 */
  @Param canTorrent: boolean = false;
  /** 从历史回放时的快照 id；0 = 实时搜索 */
  @Param snapshotId: number = 0;

  @Local private douban: DiscoveredTitleView[] = [];
  @Local private tmdb: DiscoveredTitleView[] = [];
  @Local private doubanError: string = '';
  @Local private tmdbError: string = '';
  @Local private loading: boolean = true;
  /** 快照回放的时间；非空 = 正在看快照（同 iOS snapshotAt） */
  @Local private snapshotAt: string = '';
  private activeSnapshot: number = 0;
  private doubanSource: TitleRowsSource = new TitleRowsSource();
  private tmdbSource: TitleRowsSource = new TitleRowsSource();

  aboutToAppear(): void {
    this.activeSnapshot = this.snapshotId;
    this.load();
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  /** 加载（同 iOS load）：快照优先，缺失回退实时 */
  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = true;
    this.doubanError = '';
    this.tmdbError = '';
    this.snapshotAt = '';
    if (this.activeSnapshot > 0) {
      try {
        const snap = await api.searchHistorySnapshot(this.activeSnapshot);
        this.splitBySource(snap.items);
        this.snapshotAt = snap.snapshot_at;
        this.loading = false;
        return;
      } catch (error) {
        // 快照缺失（被清理/老数据）回退实时搜索
      }
    }
    try {
      const payload: TitleSearchPayload = { query: this.keyword, save_history: true };
      const view: TitleSearchView = await api.searchTitles(payload);
      this.splitBySource(view.titles);
      for (const status of view.providers) {
        if (!status.success) {
          const message: string = status.message ?? '';
          if (status.provider === 'douban') {
            this.doubanError = message.length > 0 ? message : '豆瓣搜索失败';
          } else if (status.provider === 'tmdb') {
            this.tmdbError = message.length > 0 ? message : 'TMDB 搜索失败';
          }
        }
      }
    } catch (error) {
      const message: string = this.messageOf(error);
      this.doubanError = message;
      this.tmdbError = message;
    } finally {
      this.loading = false;
    }
  }

  private splitBySource(titles: DiscoveredTitleView[]): void {
    const douban: DiscoveredTitleView[] = [];
    const tmdb: DiscoveredTitleView[] = [];
    for (const title of titles) {
      if (title.provider === 'douban') {
        douban.push(title);
      } else {
        tmdb.push(title);
      }
    }
    this.douban = douban;
    this.tmdb = tmdb;
    this.doubanSource.setTitles(douban);
    this.tmdbSource.setTitles(tmdb);
  }

  /** 丢掉快照重新实时搜索（同 iOS onResearch） */
  private research(): void {
    this.activeSnapshot = 0;
    this.load();
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '影视搜索失败，请稍后重试';
  }

  private openTitle(item: DiscoveredTitleView): void {
    this.navStack.pushPathByName('discoverDetail', new DiscoverDetailParams(item.title_ref));
  }

  private titleSubtitle(item: DiscoveredTitleView): string {
    const parts: string[] = [];
    const year: number | null = item.release_year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    if ((item.provider_rating ?? 0) > 0) {
      parts.push(`★ ${item.provider_rating.toFixed(1)}`);
    }
    if (this.inLibrary(item)) {
      parts.push('已入库');
    }
    return parts.join('  ·  ');
  }

  private inLibrary(item: DiscoveredTitleView): boolean {
    const status = item.library_status;
    return status !== null && status !== undefined && (status.library_count ?? 0) > 0;
  }

  build() {
    List() {
      // 快照回放：快照年龄 + 重新搜索（关键词不在这里重复，顶栏胶囊已经写着）
      if (this.snapshotAt.length > 0) {
        ListItem() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.clock'))
              .fontSize(13)
              .fontColor([Theme.textMuted])
            Text(`${Formatters.relative(this.snapshotAt)}的快照`)
              .fontSize(12)
              .fontColor(Theme.textMuted)
            Text('重新搜索')
              .fontSize(12)
              .fontWeight(600)
              .fontColor(Theme.accentStrong)
              .onClick(() => {
                this.research();
              })
            Blank()
          }
          .width('100%')
          .padding({ top: 8, bottom: 4 })
        }
      }
      if (this.loading) {
        // 骨架屏：两列六格（同 iOS LazyVGrid 骨架）
        ListItem() {
          Column({ space: 16 }) {
            ForEach([0, 1, 2], (rowIndex: number) => {
              Row({ space: 12 }) {
                Column()
                  .layoutWeight(1)
                  .aspectRatio(Theme.posterAspect)
                  .borderRadius(Theme.cardRadius)
                  .backgroundColor(Theme.surface)
                Column()
                  .layoutWeight(1)
                  .aspectRatio(Theme.posterAspect)
                  .borderRadius(Theme.cardRadius)
                  .backgroundColor(Theme.surface)
              }
              .width('100%')
            }, (rowIndex: number) => `${rowIndex}`)
          }
          .width('100%')
          .padding({ top: 12 })
        }
      } else if (this.douban.length === 0 && this.tmdb.length === 0
        && this.doubanError.length === 0 && this.tmdbError.length === 0) {
        // 两边都空：说明 + 「搜索站点资源」逃生入口（有资源权限才给）
        ListItem() {
          Column({ space: 8 }) {
            Text('没有找到相关影视条目')
              .fontSize(16)
              .fontWeight(600)
              .fontColor(Theme.text)
            Text('换个关键词试试；如果找的是非影视资源，可以直接搜索站点。')
              .fontSize(13)
              .fontColor(Theme.textMuted)
              .textAlign(TextAlign.Center)
            if (this.canTorrent) {
              Text('搜索站点资源')
                .fontSize(14)
                .fontWeight(600)
                .fontColor(Theme.accentStrong)
                .padding({ left: 20, right: 20, top: 9, bottom: 9 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(18)
                .border({ width: 1, color: Theme.lineStrong })
                .margin({ top: 8 })
                .onClick(() => {
                  this.navStack.pushPathByName('torrents', new TorrentParams(this.keyword));
                })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 60, left: 24, right: 24 })
        }
      } else {
        this.SourceSection('豆瓣', this.douban, this.doubanError, this.doubanSource)
        this.SourceSection('TMDB', this.tmdb, this.tmdbError, this.tmdbSource)
      }
      // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
      ListItem() {
        AppFooter({ topSpace: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .cachedCount(4)
    .padding({ left: 20, right: 20 })
    .padding({ bottom: Theme.tabBarInset })
  }

  /** 单来源分区：标签 + 共 N 条结果 → 错误/空/两列海报（同 iOS section） */
  @Builder
  SourceSection(label: string, titles: DiscoveredTitleView[], error: string, source: TitleRowsSource) {
    ListItem() {
      Row({ space: 10 }) {
        Text(label)
          .fontSize(13)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor('rgba(205,214,230,0.12)')
          .borderRadius(10)
        if (titles.length > 0) {
          Text(`共 ${titles.length} 条结果`)
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
      }
      .width('100%')
      .padding({ top: 12, bottom: 8 })
    }
    if (error.length > 0) {
      ListItem() {
        Text(error)
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
      }
    } else if (titles.length === 0) {
      ListItem() {
        Text('该来源没有找到相关条目')
          .fontSize(13)
          .fontColor(Theme.textMuted)
          .width('100%')
      }
    } else {
      LazyForEach(source, (row: DiscoveredTitleView[]) => {
        ListItem() {
          Row({ space: 12 }) {
            ForEach(row, (item: DiscoveredTitleView) => {
              this.TitleCard(item)
            }, (item: DiscoveredTitleView) => item.title_ref)
          }
          .width('100%')
        }
      }, (row: DiscoveredTitleView[], index: number) => `${label}-${index}-${row.length}`)
    }
  }

  /** 影视条目卡（同 iOS DiscoverPosterCard）：海报 + 片名 + 年份/评分/已入库 */
  @Builder
  TitleCard(item: DiscoveredTitleView) {
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
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.titleSubtitle(item))
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openTitle(item);
    })
  }
}

/**
 * 搜索结果页（对齐 iOS `Features/Search/SearchResultsView.swift`）。
 *
 * - 顶栏中间是**搜索词胶囊**：点它回搜索首页、关键词已填好（同 iOS keywordCapsule）；
 * - 下一行是垂直选项卡「媒体库 | 影视」（按权限裁剪；站点资源是独立结果页，不在本页挂载）。
 *   各垂直**惰性挂载 + 切换保活**：切走只隐藏、不卸载，切回来不重搜；
 * - **影视**：`MediaSearchResultsView`（豆瓣 / TMDB 分区 + 快照横幅 + 逃生入口）；
 * - **媒体库**：复用 `LibrarySearchResults`（关键词固定，一次加载 + 续页）。
 */
@ComponentV2
export struct SearchResultsPage {
  private navStack: NavPathStack = new NavPathStack();
  @Local private keyword: string = '';
  @Local private mode: string = SearchMode.media;
  private snapshotId: number = 0;
  private started: boolean = false;

  @Local private access: SearchAccess = SearchAccess.notReady();
  /** 惰性挂载：真正切到的垂直才发起请求；切走保留结果（同 iOS visited） */
  @Local private visitedLibrary: boolean = false;
  @Local private visitedMedia: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  /** 本页托管的垂直（站点资源走独立的 TorrentResultsPage）：媒体库 + 影视，按权限裁剪 */
  private visibleVerticals(): string[] {
    const modes: string[] = [];
    if (this.access.canLibrary) {
      modes.push(SearchMode.library);
    }
    if (this.access.canMedia) {
      modes.push(SearchMode.media);
    }
    return modes;
  }

  private verticalLabel(mode: string): string {
    return mode === SearchMode.media ? '影视' : '媒体库';
  }

  // MARK: 取数

  private async resolveAccess(): Promise<void> {
    const permissions = Permissions.fromSession(AppModel.shared.session);
    this.access = await SearchAccess.resolve(this.api(), permissions);
    // 落点垂直没权限：落到本页第一个可用垂直（快照跟着丢，同 iOS initialize）
    if (!this.access.allows(this.mode) || this.visibleVerticals().indexOf(this.mode) < 0) {
      const available: string[] = this.visibleVerticals();
      if (available.length > 0) {
        this.mode = available[0];
      }
    }
    this.visitCurrent();
  }

  /** 惰性挂载：给切到的垂直打个已访问标记（组件首次挂载时自己发起请求） */
  private visitCurrent(): void {
    if (this.mode === SearchMode.media) {
      this.visitedMedia = true;
    } else if (this.mode === SearchMode.library) {
      this.visitedLibrary = true;
    }
  }

  private switchVertical(target: string): void {
    if (target === this.mode) {
      return;
    }
    this.mode = target;
    this.visitCurrent();
  }

  /** 搜索词胶囊：点它回搜索首页改词重搜（同 iOS keywordCapsule → router.editSearch） */
  private editSearch(): void {
    const draft: Record<string, string> = { 'keyword': this.keyword, 'mode': this.mode };
    AppStorage.setOrCreate(DRAFT_STORAGE_KEY, JSON.stringify(draft));
    this.navStack.pop();
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        if (this.access.ready && this.visibleVerticals().length > 1) {
          this.VerticalTabs()
        }
        if (!this.access.ready) {
          Column() {
            LoadingProgress()
              .width(26)
              .height(26)
              .color(Theme.textMuted)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // 切换保活：两个垂直都常驻，切走只隐藏（同 iOS opacity + allowsHitTesting）
          Stack() {
            if (this.visitedLibrary) {
              LibrarySearchResults({
                keyword: this.keyword,
                live: false,
                navStack: this.navStack,
                onSwitchToMedia: this.access.canMedia
                  ? (): void => {
                    this.switchVertical(SearchMode.media);
                  }
                  : null
              })
                .visibility(this.mode === SearchMode.library ? Visibility.Visible : Visibility.None)
            }
            if (this.visitedMedia) {
              MediaSearchResultsView({
                keyword: this.keyword,
                navStack: this.navStack,
                canTorrent: this.access.canTorrent,
                snapshotId: this.snapshotId
              })
                .visibility(this.mode === SearchMode.media ? Visibility.Visible : Visibility.None)
            }
          }
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: SearchParams | null = SearchParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.keyword = params.keyword;
        this.mode = params.mode;
        this.snapshotId = params.snapshotId;
        if (this.snapshotId > 0) {
          // 从历史回放快照：只有影视分区有快照
          this.mode = SearchMode.media;
        }
        this.resolveAccess();
      }
    })
  }

  /** 返回 + 搜索词胶囊（对应 iOS 顶栏居中的玻璃胶囊） */
  @Builder
  TopBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .onClick(() => {
          this.navStack.pop();
        })
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(14)
          .fontColor([Theme.textMuted])
        Text(this.keyword)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .constraintSize({ maxWidth: 260 })
      .height(40)
      .padding({ left: 16, right: 16 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(20)
      .border({ width: 1, color: Theme.lineStrong })
      .onClick(() => {
        this.editSearch();
      })
      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.statusBarInset + 6, bottom: 6 })
  }

  /** 垂直选项卡（对应 iOS 顶部分段 Picker） */
  @Builder
  VerticalTabs() {
    Row({ space: 8 }) {
      ForEach(this.visibleVerticals(), (mode: string) => {
        Text(this.verticalLabel(mode))
          .fontSize(14)
          .fontColor(this.mode === mode ? '#0b0d12' : Theme.textMuted)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.mode === mode ? Theme.accent : Theme.glassFill)
          .borderRadius(16)
          .onClick(() => {
            this.switchVertical(mode);
          })
      }, (mode: string) => mode)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 10 })
  }
}
