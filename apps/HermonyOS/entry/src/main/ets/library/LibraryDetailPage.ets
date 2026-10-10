import { display, LengthMetrics } from '@kit.ArkUI';

import { Theme } from '../theme/AppTheme';
import { RecycleParams } from './RecycleBinPage';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  CollectionView,
  JobView,
  LastScanView,
  LibraryIndexEntryView,
  LibraryItemView,
  LibraryView,
  MetadataRefreshView,
  ScanProgressView, CollectionPayload } from '../api/Models';
import { JsonValue } from '../api/JsonValue';
import {
  EmptyState,
  LibraryKindMeta,
  ScanPhase,
  libraryBytes,
  libraryFromNow
} from './LibraryShared';
import {
  LibraryFilter,
  LibraryInventoryCell,
  LibraryWallPager,
  WallIndexBar,
  WallSortDirections,
  WallSortMenu,
  WallSortOption,
  WallSortState,
  fetchWallIndex,
  fetchWallItems
} from './LibraryWall';
import { LibraryFilterBar, LibraryFilterEmptyState } from './LibraryFilterBar';
import { AppFooter } from '../common/AppFooter';
import { LibraryCollectionsGrid } from './AllCollectionsPage';
import { ItemRouteParams } from './LibraryItemDetailPage';
import { CollectionRouteParams } from './CollectionDetailPage';
import { IssueParams } from './IssueDrawerPage';
import { LibraryFormSheet } from './LibraryFormSheet';
import { OrganizeSheet } from './OrganizeSheet';
import { SaveAsCollectionSheet } from './SaveAsCollectionSheet';

/** 单库页路由参数 */
export class LibraryRouteParams {
  readonly libraryId: number;

  constructor(libraryId: number) {
    this.libraryId = libraryId;
  }

  /**
   * 从 NavDestination 的路由参数里取出库 id；取不到返回 0。
   *
   * **不要用 `param instanceof LibraryRouteParams` 判断**：`pushPathByName` 传过来的参数
   * 会被序列化，到 `onReady` 时已经是个普通对象（真机/模拟器实测 `{"libraryId":1}`，
   * `instanceof` 恒为 false）。用它判断的话判断永远不成立、`start()` 永远不跑，
   * 页面就一直是「正在加载媒体库…」——这正是电影库/剧集库点进去没反应的原因。
   * 所以按字段取值并校验，不依赖原型链。
   */
  static idOf(param: Object | undefined | null): number {
    if (param === undefined || param === null) {
      return 0;
    }
    const raw: number = (param as LibraryRouteParams).libraryId;
    return Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : 0;
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function LibraryDetailBuilder() {
  LibraryDetailPage()
}

/**
 * 海报墙的行数据源（LazyForEach 用）。
 *
 * 墙按「行」喂给框架：一行的格子数由页面列数决定，所以换列数或换数据都要整批重设。
 * 用 LazyForEach 而不是 ForEach，是为了让框架只建可视区附近的行——60 格一次性建树
 * 实测在 UI 线程上要 51～122ms（见 docs/harmonyos-port.md）。
 *
 * 每次 setItems 都整体换、整体通知，不做「内容没变就跳过」的判断：
 * iOS 那边 pager.refresh() 也是每次都把新窗口整体赋值（`items = rows`），
 * 由 SwiftUI 按 id 自己 diff。这里等价的做法是整体换 + onDataReloaded——
 * LazyForEach 按 key 复用组件，键没变的行不会重建。**不要为了省几次重绘去加指纹跳过**：
 * 只看首尾 id 的指纹会把「中间某条的海报更新了」当成没变，墙就显示旧数据了（iOS 不会）。
 */
class WallRowSource implements IDataSource {
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

  /** 整批换成这一批行（与 iOS 的 `items = rows` 同语义） */
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
 * 单库页（对齐 iOS 端 Features/Library/LibraryDetailView.swift，口径即 Web library-detail-view.tsx）。
 *
 * 结构：库头（名称、默认/仅管理徽标、统计、最近扫描成绩单、健康状态胶囊）
 * → 作品 / 合集两个视图 → 作品视图里是筛选栏 + 排序 + 海报墙。
 * 墙是窗口式分页（每页 60），按标题排序时右侧 A–Z 跳转条；非刮削库按时间排、
 * 竖版与横版分两区；识别不出的文件单独一区「未识别」。
 * 管理员 ⋯ 菜单：待处理 / 扫描与停止 / 整理文件名 / 刷新元数据与停止 / 生成章节 / 编辑库。
 * 轮询：扫描或整理中 3 秒（结束后再快轮询 12 秒），入库中或刷新元数据中 10 秒，其余 30 秒。
 * 排序偏好全站共用一个键（在哪个库选了「按评分」，换个库还是按评分），同 Web。
 *
 * 本轮相对 iOS 的暂缓项：图床浏览 / 照片墙、待处理抽屉、整理文件名与编辑库面板、
 * 「回到上次浏览的位置」记忆——待后续版本补齐，其余交互与文案逐条对齐。
 */
@Component
struct LibraryDetailPage {
  private libraryId: number = 0;
  private navStack: NavPathStack = new NavPathStack();
  private permissions: Permissions = Permissions.none();
  private pager: LibraryWallPager = new LibraryWallPager(60);
  private scroller: Scroller = new Scroller();
  private pollTimer: number = -1;
  private started: boolean = false;

  @State private libraries: LibraryView[] | null = null;
  @State private loadFailed: boolean = false;
  @State private collections: CollectionView[] = [];
  @State private provisional: LibraryItemView[] = [];
  @State private index: LibraryIndexEntryView[] = [];
  @State private missingCount: number = 0;
  @State private unidentifiedCount: number = 0;
  @State private unidentifiedFiles: number = 0;
  @State private reviewCount: number = 0;
  @State private activeJobs: JobView[] = [];
  /** 墙数据的 @State 镜像：pager 本体不是响应式的，操作后整体抄过来触发刷新 */
  @State private wallItems: LibraryItemView[] | null = null;
  @State private wallStart: number = 0;
  @State private wallHasMore: boolean = false;
  @State private wallFailed: boolean = false;
  @State private filter: LibraryFilter = new LibraryFilter();
  @State private sort: WallSortState = new WallSortState('default', false);
  /** items / collections */
  @State private view: string = 'items';
  @State private showHiddenCollections: boolean = false;
  /** 扫描/整理结束后的 12 秒快轮询窗口（ms 时间戳） */
  @State private busyUntil: number = 0;
  @State private notice: string | null = null;
  @State private metaRefresh: MetadataRefreshView | null = null;
  @State private refreshing: boolean = false;
  /** 海报墙列数（按屏宽算：竖版最小列宽 140pt、列距 12，同 Web/iOS 口径） */
  @State private columns: number = Theme.posterColumns();
  /** 主墙的行数据源（LazyForEach 只建可视区附近的行） */
  private wallRows: WallRowSource = new WallRowSource();
  /** 墙顶在页面内容里的纵向位置：A–Z 跳转后把窗口第一格钉回视野顶部用的近似锚点 */
  private wallTopY: number = 0;
  private scrollOffset: number = 0;
  private scrollViewportTop: number = 0;
  /** 生成章节的确认面板 */
  @State private askingChapters: boolean = false;

  private static readonly sortStorageKey: string = 'movieclaw.library.wall-sort';
  private static readonly allSorts: string[] =
    ['default', 'title', 'added_at', 'release_date', 'rating', 'runtime', 'size', 'last_played'];

  aboutToAppear(): void {
    this.permissions = Permissions.fromSession(AppModel.shared.session);
    this.sort = WallSortState.load(LibraryDetailPage.sortStorageKey,
      new WallSortState('default', false), LibraryDetailPage.allSorts);
    // 列数由 Theme 统一算（2~4 列按屏宽自适应），这里不再自己量屏
    this.columns = Theme.posterColumns();
  }

  aboutToDisappear(): void {
    this.stopPolling();
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

  /** 轮询间隔：忙 3s / 刚结束 3s / 入库中或刷新元数据 10s / 空闲 30s（同 Web） */
  private pollInterval(): number {
    const library: LibraryView | null = this.library();
    if (library === null) {
      return 30;
    }
    if (library.scanning || library.organizing || Date.now() < this.busyUntil) {
      return 3;
    }
    if (this.importing() > 0 || this.refreshingMeta()) {
      return 10;
    }
    return 30;
  }

  // MARK: 派生（V1 组件不能写 getter，统一方法）

  private library(): LibraryView | null {
    const list: LibraryView[] | null = this.libraries;
    if (list === null) {
      return null;
    }
    for (const item of list) {
      if (item.id === this.libraryId) {
        return item;
      }
    }
    return null;
  }

  private canManage(): boolean {
    return this.permissions.canManageLibraries;
  }

  private busy(): boolean {
    const library: LibraryView | null = this.library();
    return library === null ? false : library.scanning || library.organizing;
  }

  /** 元数据刷新中：读 progress 接口的状态——库列表里的状态只看进程内，排队中的持久化作业看不到 */
  private refreshingMeta(): boolean {
    return this.metaRefresh !== null && this.metaRefresh.refreshing;
  }

  private importing(): number {
    if (this.busy()) {
      return 0;
    }
    const library: LibraryView | null = this.library();
    if (library === null || library.last_scan === null || library.last_scan === undefined) {
      return 0;
    }
    return library.last_scan.deferred;
  }

  /** 非刮削库（本地视频）：按时间排、竖版与横版分两区 */
  private timeline(): boolean {
    const library: LibraryView | null = this.library();
    return library === null ? false : !library.capabilities.scraped;
  }

  private probing(): boolean {
    const library: LibraryView | null = this.library();
    return library !== null && library.scanning && library.scan_progress !== null
      && library.scan_progress !== undefined && library.scan_progress.phase === 'probing';
  }

  private recentFirst(): boolean {
    return this.sort.sort === 'added_at' && !this.probing();
  }

  /** 实际请求的排序档（补探阶段强制按补探序） */
  private effectiveSort(): string {
    if (this.probing()) {
      return 'probing';
    }
    if (this.sort.sort !== 'default') {
      return this.sort.sort;
    }
    return this.timeline() ? 'release_date' : 'title';
  }

  private order(): string | null {
    if (this.effectiveSort() === 'probing') {
      return null;
    }
    const direction: WallSortDirections | null = null;
    const profile = WallSortDirections.of(this.effectiveSort());
    return profile === null ? null : profile.orderParam(this.sort.reversed);
  }

  /** 墙的取数口径（排序 + 方向 + 筛选），变化即整面墙从头重载 */
  private wallKey(): string {
    return `${this.effectiveSort()}|${this.order() ?? ''}|${this.filter.key()}`;
  }

  private sortOptions(): WallSortOption[] {
    const options: WallSortOption[] = [
      new WallSortOption('default', this.timeline() ? '按时间' : '按标题',
        WallSortDirections.of(this.timeline() ? 'release_date' : 'title')),
      new WallSortOption('added_at', '最近添加', WallSortDirections.of('added_at'))
    ];
    if (!this.timeline()) {
      options.push(new WallSortOption('release_date', '按上映时间', WallSortDirections.of('release_date')));
    }
    options.push(new WallSortOption('rating', '按评分', WallSortDirections.of('rating')));
    options.push(new WallSortOption('runtime', '按片长', WallSortDirections.of('runtime')));
    options.push(new WallSortOption('size', '按体积', WallSortDirections.of('size')));
    options.push(new WallSortOption('last_played', '最近观看', WallSortDirections.of('last_played')));
    return options;
  }

  private pendingCount(): number {
    return this.missingCount + this.unidentifiedCount + this.reviewCount;
  }

  private libraryJobs(): JobView[] {
    const id: string = `${this.libraryId}`;
    return this.activeJobs.filter((job: JobView): boolean => {
      return job.resources.some((resource): boolean => resource.resource_type === 'library' && resource.resource_id === id);
    });
  }

  /** ⋯ 菜单里有没有东西（同 Web hasMenuItems） */
  private hasMenuItems(): boolean {
    return this.canManage() || this.view === 'collections';
  }

  private hasSegmented(): boolean {
    const library: LibraryView | null = this.library();
    return library !== null && this.collections.length > 0;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  /**
   * 打开待处理事项（对应 iOS `IssueDrawer`）。
   * 页面上三个角标各带一个初始页签：缺失 / 待识别 / 身份复核。
   */
  private openIssues(tab: string = 'missing'): void {
    // 认领的 TMDB 引用类型由库类型决定（movie / tv），一并传给待处理抽屉
    const library: LibraryView | null = this.library();
    const kind: string = library !== null ? library.kind : 'movie';
    this.navStack.pushPathByName('issueDrawer', new IssueParams(this.libraryId, tab, kind === 'movie'));
  }

  /** 弹层槽位：空串=关，edit=编辑库，organize=整理文件名（一个组件只能绑一个 bindSheet） */
  @State private sheetKind: string = '';
  @State private showSheet: boolean = false;

  private openSheet(kind: string): void {
    this.sheetKind = kind;
    this.showSheet = true;
  }

  /** 唯一的弹层内容：按 sheetKind 切换 */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'saveCollection') {
      SaveAsCollectionSheet({
        libraryId: this.libraryId,
        filter: this.filter,
        onSaved: (view: CollectionView): void => {
          // 刚存的合集要马上在 chip 行里看得见
          this.reload();
        },
        onClose: (): void => {
          this.showSheet = false;
        }
      })
    } else if (this.sheetKind === 'chapters') {
      this.ChaptersSheet()
    } else if (this.sheetKind === 'organize') {
      OrganizeSheet({
        libraryId: this.libraryId,
        onStarted: (): void => {
          this.reload();
        },
        onClose: (): void => {
          this.showSheet = false;
        }
      })
    } else {
      LibraryFormSheet({
        libraryId: this.libraryId,
        onSaved: (view: LibraryView): void => {
          this.reload();
        },
        onClose: (): void => {
          this.showSheet = false;
        }
      })
    }
  }


  private comingSoon(feature: string): void {
    this.toast(`「${feature}」建设中，将在后续版本开放`);
  }

  /** 弹窗用的条目清单文案 */
  private static bullets(lead: string, items: string[]): string {
    const lines: string[] = [lead];
    for (const item of items) {
      lines.push(`• ${item}`);
    }
    return lines.join('\n');
  }

  private percent(progress: ScanProgressView | null | undefined): number | null {
    if (progress === null || progress === undefined || progress.total <= 0) {
      return null;
    }
    return Math.min(100, Math.round(progress.processed / progress.total * 100));
  }

  // MARK: 加载

  private start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.reload();
    this.reloadWall();
    this.reloadCollections();
    this.probeMetaRefresh();
  }

  private async reload(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const id: number = this.libraryId;
    const manage: boolean = this.canManage();
    try {
      // 库列表先 await：它是页面的门槛，回来了就能从「正在加载」进到正文
      const libs: LibraryView[] = await api.libraryList(undefined, 'all');
      this.libraries = libs;
      this.loadFailed = false;
      // 整库元数据刷新可能是别处发起的（首页卡片、其他设备、定时任务）：库列表里带着状态，据此补种
      for (const item of libs) {
        if (item.id === id && item.metadata_refresh !== null && item.metadata_refresh !== undefined
          && item.metadata_refresh.refreshing && !(this.metaRefresh !== null && this.metaRefresh.refreshing)) {
          this.metaRefresh = item.metadata_refresh;
        }
      }
      // 剩下的几路互不依赖，一起发、一起等（对应 iOS 端的 `async let ... await (...)`）。
      // 逐个 await 的话首屏耗时是这几路之和——管理员要串 5 个往返，弱网/大库上和网页能差出好几秒。
      const rest: Promise<void>[] = [this.loadProvisional(id)];
      if (manage) {
        rest.push(this.loadMissing(id));
        rest.push(this.loadUnidentified(id));
        rest.push(this.loadReview(id));
        rest.push(this.loadJobs());
      }
      await Promise.all(rest);

      if (this.busy()) {
        this.busyUntil = Date.now() + 12000;
      }
      await this.pager.refresh();
      this.syncWall();
      if (this.effectiveSort() === 'title' || this.effectiveSort() === 'release_date') {
        try {
          this.index = await fetchWallIndex(api, id, this.filter, this.effectiveSort(), this.order());
        } catch (error) {
          // 索引拿不到就先不显示 A–Z 条，下一轮轮询再试
        }
      }
    } catch (error) {
      this.loadFailed = true;
    }
    this.scheduleNextPoll();
  }

  /** 未识别条目（按文件名展示的那一区）；拉不到就当没有，不影响正式墙 */
  private async loadProvisional(id: number): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.provisional = await api.libraryItemsList(id, 'added_at', undefined, 200, undefined, 'provisional');
    } catch (error) {
      this.provisional = [];
    }
  }

  /** 待处理计数：缺失文件 */
  private async loadMissing(id: number): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.missingCount = (await api.libraryMissingList(id)).length;
    } catch (error) {
      this.loadFailed = true;
    }
  }

  /** 待处理计数：未识别文件（按组汇总文件数） */
  private async loadUnidentified(id: number): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      const unknown = await api.libraryIdentificationListUnidentifiedFiles(id);
      this.unidentifiedCount = unknown.length;
      let files: number = 0;
      for (const group of unknown) {
        files += group.file_count;
      }
      this.unidentifiedFiles = files;
    } catch (error) {
      this.loadFailed = true;
    }
  }

  /** 待处理计数：身份复核 */
  private async loadReview(id: number): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.reviewCount = (await api.libraryIdentificationListReviewCases(id)).length;
    } catch (error) {
      this.loadFailed = true;
    }
  }

  /** 进行中的后台任务（墙上「正在读取规格」等文案要用） */
  private async loadJobs(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.activeJobs = (await api.jobsList(undefined, undefined, undefined, undefined, true, 100)).items;
    } catch (error) {
      this.loadFailed = true;
    }
  }


  private async reloadCollections(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    try {
      this.collections = await api.collectionList(this.libraryId, undefined, this.showHiddenCollections);
    } catch (error) {
      // 拉不到就保留旧列表
    }
    if (this.collections.length === 0 && this.view === 'collections') {
      this.view = 'items';
    }
  }

  /** 排序 / 筛选变了：整面墙回到墙首重载，索引条跟着换 */
  private async reloadWall(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.index = [];
    const filter: LibraryFilter = this.filter;
    const sort: string = this.effectiveSort();
    const order: string | null = this.order();
    const libraryId: number = this.libraryId;
    const fetch = (offset: number, limit: number): Promise<LibraryItemView[]> => {
      return fetchWallItems(api, libraryId, filter, sort, order, limit, offset)
        .catch((error: Error): LibraryItemView[] => {
          if (error instanceof ApiError && error.status === 404) {
            // 超管不在浏览范围内：墙对当前身份不存在
            return [];
          }
          throw error;
        });
    };
    await this.pager.reset(fetch, 0);
    this.syncWall();
    if (sort === 'title' || sort === 'release_date') {
      try {
        this.index = await fetchWallIndex(api, libraryId, filter, sort, order);
      } catch (error) {
        this.index = [];
      }
    }
  }

  /** 把 pager 的窗口状态抄进 @State（整页重赋值触发刷新） */
  private syncWall(): void {
    this.wallItems = this.pager.items;
    this.wallRows.setItems(this.pager.items ?? [], this.columns);
    this.wallStart = this.pager.start;
    this.wallHasMore = this.pager.hasMore;
    this.wallFailed = this.pager.failed !== null;
  }

  private async probeMetaRefresh(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || !this.canManage()) {
      return;
    }
    try {
      this.metaRefresh = await api.libraryMetadataGetRefreshStatus(this.libraryId);
    } catch (error) {
      // 探不到就当没在刷新
    }
  }

  // MARK: 排序 / 筛选改动入口（clone → 改 → 整体替换；口径变了才重载墙）

  private onSortPick(value: string): void {
    const previous: string = this.wallKey();
    this.sort = new WallSortState(value, false);
    this.sort.save(LibraryDetailPage.sortStorageKey);
    if (this.wallKey() !== previous) {
      this.reloadWall();
    }
  }

  private onSortToggleDirection(): void {
    const previous: string = this.wallKey();
    this.sort = new WallSortState(this.sort.sort, !this.sort.reversed);
    this.sort.save(LibraryDetailPage.sortStorageKey);
    if (this.wallKey() !== previous) {
      this.reloadWall();
    }
  }

  private onFilterToggle(dim: string, value: string): void {
    const previous: string = this.wallKey();
    const next: LibraryFilter = this.filter.clone();
    next.toggle(dim, value);
    this.filter = next;
    if (this.wallKey() !== previous) {
      this.reloadWall();
    }
  }

  private onFilterRemove(dim: string, value: string): void {
    const previous: string = this.wallKey();
    const next: LibraryFilter = this.filter.clone();
    next.remove(dim, value);
    this.filter = next;
    if (this.wallKey() !== previous) {
      this.reloadWall();
    }
  }

  private onFilterClear(): void {
    if (this.filter.isEmpty()) {
      return;
    }
    this.filter = new LibraryFilter();
    this.reloadWall();
  }

  private onApplyRules(rules: JsonValue[]): void {
    this.filter = LibraryFilter.fromRules(rules);
    this.reloadWall();
  }

  // MARK: 墙滚动（触底追加、到顶补上一页、A–Z 跳转后滚回墙首）

  private onReachEnd(): Promise<void> {
    const load = this.pager.loadMore();
    return load.then((): void => {
      this.syncWall();
    });
  }

  private onReachTop(): Promise<void> {
    if (this.wallStart <= 0) {
      return Promise.resolve();
    }
    const load = this.pager.loadPrevious();
    return load.then((): void => {
      this.syncWall();
    });
  }

  private onIndexJump(offset: number): void {
    const jump = this.pager.jump(offset);
    jump.then((): void => {
      this.syncWall();
      this.scrollToWallTop();
    });
  }

  private scrollToWallTop(): void {
    this.scroller.scrollTo({ xOffset: 0, yOffset: this.wallTopY, animation: { duration: 0 } });
  }

  // MARK: 管理动作

  private scanLabel(library: LibraryView): string {
    if (!library.scanning) {
      return '扫描库';
    }
    const stoppable: boolean = library.scan_progress !== null && library.scan_progress !== undefined
      && library.scan_progress.phase !== 'reidentifying';
    if (stoppable) {
      const percent: number | null = this.percent(library.scan_progress);
      return percent === null ? '停止扫描' : `停止扫描 ${percent}%`;
    }
    return `${ScanPhase.label(library.scan_progress === null || library.scan_progress === undefined
      ? null : library.scan_progress.phase)}…`;
  }

  private metaLabel(library: LibraryView): string {
    if (this.refreshingMeta() && this.metaRefresh !== null) {
      const meta: MetadataRefreshView = this.metaRefresh;
      return meta.total > 0 ? `停止刷新 ${meta.processed}/${meta.total}` : '停止刷新';
    }
    return library.capabilities.scraped ? '刷新元数据'
      : library.capabilities.playable ? '重新读取 NFO 与封面' : '重新生成封面';
  }

  private chapterLabel(library: LibraryView): string {
    const job = library.chapter_job;
    if (job === null || job === undefined) {
      return '生成章节';
    }
    if (job.stopping) {
      return '正在停止生成章节';
    }
    if (job.status !== 'running' && job.status !== 'cancelling') {
      return '生成章节排队中';
    }
    if (job.total <= 0) {
      return '正在生成章节';
    }
    return `正在生成章节 ${Math.min(100, Math.round(job.processed / job.total * 100))}%`;
  }

  private toggleScan(library: LibraryView): void {
    this.notice = null;
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    if (library.scanning) {
      api.libraryScanStop(this.libraryId).then((): void => {
        this.reload();
      }).catch((error: Error): void => {
        this.notice = error instanceof Error ? error.message : `${error}`;
      });
      return;
    }
    AlertDialog.show({
      title: `扫描「${library.name}」？`,
      message: LibraryDetailPage.bullets('本次扫描会检查库文件夹的最新变化：', [
        '找出新增的影片文件，自动识别并加入媒体库',
        '标记已经不在硬盘上的文件（记录保留，文件回来自动恢复）',
        '为新入库的影片补齐简介、海报等信息',
        '首次扫描会读取每个文件的画质与音轨信息，文件多时较慢、可随时停止',
        '不会移动、修改或删除你的任何文件'
      ]),
      primaryButton: {
        value: '开始扫描',
        fontColor: Theme.accentStrong,
        action: (): void => {
          api.libraryScanStart(this.libraryId).then((): void => {
            this.reload();
          }).catch((error: Error): void => {
            this.notice = error.message;
          });
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
        }
      }
    });
  }

  private toggleMetaRefresh(library: LibraryView): void {
    this.notice = null;
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    if (this.refreshingMeta()) {
      api.libraryMetadataStopRefresh(this.libraryId).then((): void => {
        this.probeMetaRefresh();
        this.reload();
      }).catch((error: Error): void => {
        this.notice = error.message;
      });
      return;
    }
    const caps = library.capabilities;
    const title: string = !caps.scraped && caps.playable
      ? `重新读取「${library.name}」的 NFO 与封面？` : `刷新「${library.name}」的元数据？`;
    const message: string = !caps.scraped && caps.playable
      ? LibraryDetailPage.bullets('本次会为库里的全部视频：', [
        '重新读取视频旁同名的 NFO 文件，标题、简介、系列等以 NFO 为准',
        'NFO 里写了系列（<set>）的，按库设置自动归进系列合集',
        '重新生成封面',
        '不联网，不会修改或删除你的文件'
      ])
      : LibraryDetailPage.bullets('本次刷新会为库里的全部影片：', [
        '重新获取最新的简介、评分、演职员和剧集信息',
        '海报或背景图有更新时重新下载（你手动锁定的不动）',
        '同步更新影片文件夹里的海报和 NFO 信息文件',
        '影片较多时需要一段时间，可随时停止',
        '不会移动、修改或删除你的视频文件'
      ]);
    const confirmTitle: string = !caps.scraped && caps.playable ? '开始读取' : '开始刷新';
    AlertDialog.show({
      title: title,
      message: message,
      primaryButton: {
        value: confirmTitle,
        fontColor: Theme.accentStrong,
        action: (): void => {
          api.libraryMetadataRefreshLibrary(this.libraryId).then((): void => {
            this.probeMetaRefresh();
            this.reload();
          }).catch((error: Error): void => {
            this.notice = error.message;
          });
        }
      },
      secondaryButton: {
        value: '取消',
        action: (): void => {
        }
      }
    });
  }

  private startChapters(force: boolean): void {
    this.askingChapters = false;
    this.notice = null;
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.libraryChapterImagesGenerate(this.libraryId, force).then((): void => {
      this.toast(force ? '已开始重新生成章节，可在任务中心查看进度' : '已开始生成章节，可在任务中心查看进度');
      this.reload();
    }).catch((error: Error): void => {
      this.toast(error.message);
    });
  }

  /** 这一格正被后台处理的文案：整库刷新阶段 > 后台任务 > 扫描补探 */
  private workingLabel(item: LibraryItemView): string | null {
    if (this.metaRefresh !== null) {
      for (const active of this.metaRefresh.active) {
        if (active.media_item_id === item.media_item_id) {
          return active.phase;
        }
      }
    }
    const id: string = `${item.media_item_id}`;
    for (const job of this.activeJobs) {
      const hit: boolean = job.resources.some((resource): boolean =>
        resource.resource_type === 'media_item' && resource.resource_id === id);
      if (hit) {
        return `${job.status === 'blocked' ? '需要处理' : '后台任务'} · ${job.progress.message}`;
      }
    }
    return this.probing() && item.probe_pending_count > 0 ? '正在读取规格' : null;
  }

  // MARK: 布局

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          this.StateContent()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.bg)
        // 库头大图铺到状态栏下面（沉浸），所以顶栏是浮在上面的
        this.TopBar()
      }
      .width('100%')
      .height('100%')
    }
    /*
     * **不用系统的 `.title()` / `.menus()` 标题栏**：沉浸式布局下它不避让状态栏，
     * 返回键会被画进状态栏里——既压住左上角的时钟，上半截还点不动（实测：点 y=95 无反应、
     * 点 y=150 才行）。按条目详情页的做法自绘顶栏。
     */
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const id: number = LibraryRouteParams.idOf(ctx.pathInfo.param as Object | undefined);
      if (id > 0) {
        this.libraryId = id;
        this.start();
      }
    })
    // **一个组件只能绑一个 bindSheet**（实测：绑两次只有后一个生效），所以合成单槽位 + 内容切换
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  /** 自绘顶栏：返回 + 库名（+ 右上角 ⋯），高度把状态栏算进去 */
  @Builder
  TopBar() {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .backgroundColor('rgba(0,0,0,0.35)')
        .borderRadius(19)
        .onClick(() => {
          this.navStack.pop();
        })
      Text(this.library() !== null ? (this.library() as LibraryView).name : '')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      this.TopRight()
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.statusBarInset + 6, bottom: 6 })
  }

  /** 右上角动作：⋯ 菜单 + 忙态圆点（对应 iOS `topBarTrailing actionsMenu`） */
  @Builder
  TopRight() {
    if (this.library() !== null && this.hasMenuItems()) {
      Stack({ alignContent: Alignment.TopEnd }) {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(22)
          .fontColor([Theme.textMuted])
          .width(38)
          .height(38)
          .bindMenu(this.ActionsMenu())
        if (this.busy() || this.refreshingMeta()) {
          Circle()
            .width(6)
            .height(6)
            .fill(Theme.info)
            .margin({ top: 4, right: 4 })
        }
      }
      .width(38)
      .height(38)
    }
  }

  /** 作品 / 合集分段切换（iOS 放在导航 principal；原生标题占主位后落到库头下方居中） */
  @Builder
  SegmentedBar() {
    if (this.hasSegmented()) {
      Row() {
        this.Segmented()
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 4, bottom: 4 })
    }
  }

  @Builder
  Segmented() {
    Row() {
      Text('作品')
        .fontSize(13)
        .fontWeight(600)
        .fontColor(this.view === 'items' ? Theme.text : Theme.textMuted)
        .padding({ left: 16, right: 16, top: 5, bottom: 5 })
        .backgroundColor(this.view === 'items' ? 'rgba(255, 255, 255, 0.16)' : Color.Transparent)
        .borderRadius({ topLeft: 9, bottomLeft: 9 })
        .onClick(() => {
          if (this.view !== 'items') {
            this.view = 'items';
          }
        })
      Text('合集')
        .fontSize(13)
        .fontWeight(600)
        .fontColor(this.view === 'collections' ? Theme.text : Theme.textMuted)
        .padding({ left: 16, right: 16, top: 5, bottom: 5 })
        .backgroundColor(this.view === 'collections' ? 'rgba(255, 255, 255, 0.16)' : Color.Transparent)
        .borderRadius({ topRight: 9, bottomRight: 9 })
        .onClick(() => {
          if (this.view !== 'collections') {
            this.view = 'collections';
          }
        })
    }
    .backgroundColor('rgba(255, 255, 255, 0.06)')
    .borderRadius(9)
  }

  /** 加载中 / 失败 / 不存在 / 正常页的分支 */
  @Builder
  StateContent() {
    if (this.loadFailed && this.libraries === null) {
      Column({ space: 12 }) {
        Text('媒体库加载失败')
          .fontSize(15)
          .fontColor(Theme.textMuted)
        Text('与后端通信失败')
          .fontSize(13)
          .fontColor(Theme.textFaint)
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
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.libraries === null) {
      Column({ space: 10 }) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.textMuted)
        Text('正在加载媒体库…')
          .fontSize(15)
          .fontColor(Theme.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.library() !== null) {
      this.Page(this.library() as LibraryView)
    } else {
      Column() {
        EmptyState({
          systemImage: $r('sys.symbol.folder_badge_ellipsis'),
          title: '这个媒体库不存在（可能已被删除）',
          actionTitle: '返回媒体库',
          onAction: (): void => {
            this.navStack.pop();
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  Page(library: LibraryView) {
    Stack({ alignContent: Alignment.End }) {
      Refresh({ refreshing: $$this.refreshing }) {
        // 用 List 而不是 Scroll + Column：只有 List / Grid / Swiper / WaterFlow 这类容器
        // 才让 LazyForEach 按可视区建组件。墙的每一行是一个 ListItem（见 WallRows）。
        List({ scroller: this.scroller }) {
          ListItem() {
            this.Header(library)
          }
          ListItem() {
            this.SegmentedBar()
          }
          if (!library.viewer_access) {
            ListItem() {
              this.HiddenContent()
            }
          } else if (this.view === 'collections') {
            ListItem() {
              LibraryCollectionsGrid({
                collections: this.collections,
                libraryId: this.libraryId,
                onOpen: (collection: CollectionView): void => {
                  this.navStack.pushPathByName('collectionDetail', new CollectionRouteParams(collection.id, this.libraryId));
                }
              })
                .padding({ top: 20 })
            }
          } else {
            this.WallItems(library)
          }
          // 墙顶锚点：A–Z 跳转后回到这里（连库头一起滚出视野，只看到墙）
          ListItem() {
            Column()
              .width('100%')
              .height(1)
              .onAreaChange((oldArea: Area, newArea: Area) => {
                this.wallTopY = this.areaY(newArea) - this.scrollViewportTop + this.scrollOffset;
              })
          }
          // 页脚：品牌联合声明，复用全局 AppFooter（包在 ListItem 里跟随滚动）
          ListItem() {
            AppFooter({ topSpace: 0 })
          }
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.None)
        // 墙可视区上下各多缓存几行，快速滑动时少建少销毁
        .cachedCount(4)
        .padding({ bottom: Theme.tabBarInset })
        .onReachEnd(() => {
          this.onReachEnd();
        })
        // List 没有 onScrollEdge，到顶用 onReachStart（同 Scroll 的 Edge.Top）
        .onReachStart(() => {
          this.onReachTop();
        })
        .onDidScroll((xOffset: number, yOffset: number) => {
          this.scrollOffset += yOffset;
        })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.scrollViewportTop = this.areaY(newArea);
        })
      }
      .onRefreshing(() => {
        this.reload().then((): void => {
          this.reloadCollections();
          this.probeMetaRefresh();
          this.refreshing = false;
        });
      })
      .layoutWeight(1)
      .width('100%')

      if (this.effectiveSort() === 'title' && this.view === 'items' && this.index.length > 0) {
        WallIndexBar({
          entries: this.index,
          reversed: this.order() !== null,
          active: null,
          onJump: (offset: number): void => {
            this.onIndexJump(offset);
          }
        })
          .margin({ right: 2 })
      }
    }
    .width('100%')
    .height('100%')
  }

  // MARK: 库头

  @Builder
  Header(library: LibraryView) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(library.name)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (library.is_default) {
          Text('默认')
            .fontSize(11)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.9)')
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor('rgba(255, 255, 255, 0.12)')
            .borderRadius(9)
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.14)' })
        }
        if (!library.viewer_access) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.lock_fill'))
              .fontSize(11)
              .fontColor([Theme.warning])
            Text('仅管理')
              .fontSize(11)
              .fontWeight(600)
              .fontColor(Theme.warning)
          }
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor('rgba(251, 191, 36, 0.12)')
          .borderRadius(9)
        }
      }
      .width('100%')
      Text(`${LibraryKindMeta.label(library.kind)}库 · ${library.stats.item_count} ${library.kind === 'photo' ? '张' : '部作品'} · ${library.stats.file_count} 个文件 · ${libraryBytes(library.stats.total_size_bytes)}`)
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (library.last_scan !== null && library.last_scan !== undefined && !this.busy()) {
        Text(this.lastScanText(library.last_scan))
          .fontSize(13)
          .fontColor('rgba(255, 255, 255, 0.45)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      if (this.canManage()) {
        this.HealthChips(library)
      }
      if (this.loadFailed) {
        this.Banner('与后端通信失败，正在自动重试；下方显示的是最近一次成功加载的数据', Theme.warning)
      }
      if (this.notice !== null) {
        this.Banner(this.notice ?? '', Theme.danger)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 顶部让开浮在上面的自绘顶栏（返回 + 库名 + ⋯，高约 44）——不然两个库名会叠在一起
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 52 })
  }

  private lastScanText(scan: LastScanView): string {
    let text: string = `最近扫描 ${libraryFromNow(scan.finished_at)}${scan.cancelled ? '（手动停止，未扫完）' : ''} · 新入账 ${scan.scanned}（识别 ${scan.identified} / 未识别 ${scan.unidentified}）`;
    if (scan.retried > 0) {
      text += ` · 重试识别 ${scan.retried} 个待识别文件`;
    }
    if (scan.marked_missing > 0) {
      text += ` · 标记丢失 ${scan.marked_missing}`;
    }
    if (scan.cleared_missing > 0) {
      text += ` · 清理丢失记录 ${scan.cleared_missing}`;
    }
    if (scan.deferred > 0) {
      text += ` · ${scan.deferred} 个写入中暂缓（稍后自动补扫）`;
    }
    if (scan.errors.length > 0) {
      text += ` · ${scan.errors[0]}`;
    }
    return text;
  }

  /** 面积变化里的 Y 坐标（API 24 起 globalPosition.y 是 Length，可能是字符串） */
  private areaY(area: Area): number {
    const y: Length = area.globalPosition.y ?? 0;
    return typeof y === 'number' ? y : 0;
  }

  /** 忙态胶囊文案（@Builder 里不能声明局部变量，这里抽成方法） */
  private busyChipText(library: LibraryView): string {
    const progress: ScanProgressView | null = library.scanning
      ? (library.scan_progress ?? null) : (library.organize_progress ?? null);
    if (progress === null) {
      return '正在处理…';
    }
    const counts: string = progress.total > 0 ? ` ${progress.processed}/${progress.total}` : '';
    return `${ScanPhase.label(progress.phase)}${counts} · ${ScanPhase.hint(progress.phase)}`;
  }

  /** ⋯ 菜单里取当前库（@Builder 里不能声明局部变量） */
  private menuLibrary(): LibraryView {
    return this.library() as LibraryView;
  }

  /** 扫描项是否可点（重复取值会让 TS 丢失收窄，所以整段判断抽成方法） */
  private scanMenuItemEnabled(): boolean {
    const library: LibraryView = this.menuLibrary();
    const progress: ScanProgressView | null = library.scan_progress ?? null;
    if (this.busy() && !library.scanning) {
      return false;
    }
    if (library.scanning && progress !== null && progress.phase === 'reidentifying') {
      return false;
    }
    return true;
  }

  @Builder
  HealthChips(library: LibraryView) {
    if (this.busy() || this.importing() > 0 || this.libraryJobs().length > 0
      || this.missingCount > 0 || this.unidentifiedCount > 0 || this.reviewCount > 0) {
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        if (this.busy()) {
          this.Chip(Theme.info, null, this.busyChipText(library))
        }
        if (this.importing() > 0) {
          this.Chip(Theme.info, Theme.info, `已发现 ${this.importing()} 个新文件 · 写入完成后自动入库`)
        }
        if (this.libraryJobs().length > 0) {
          this.Chip(Theme.info, Theme.info, `${this.libraryJobs().length} 个后台任务正在处理库内影片`)
        }
        if (this.missingCount > 0) {
          Text(`${this.missingCount} 个条目缺失`)
            .fontSize(13)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.6)')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('rgba(255, 255, 255, 0.072)')
            .borderRadius(16)
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.21)' })
            .onClick(() => {
              this.openIssues('missing');
            })
        }
        if (this.unidentifiedCount > 0) {
          Text(`${this.unidentifiedFiles} 个文件待识别${this.unidentifiedCount > 1 ? ` · ${this.unidentifiedCount} 组` : ''}`)
            .fontSize(13)
            .fontWeight(600)
            .fontColor(Theme.warning)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('rgba(251, 191, 36, 0.12)')
            .borderRadius(16)
            .border({ width: 1, color: 'rgba(251, 191, 36, 0.35)' })
            .onClick(() => {
              this.openIssues('unidentified');
            })
        }
        if (this.reviewCount > 0) {
          Text(`${this.reviewCount} 个条目待复核身份`)
            .fontSize(13)
            .fontWeight(600)
            .fontColor(Theme.warning)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('rgba(251, 191, 36, 0.12)')
            .borderRadius(16)
            .border({ width: 1, color: 'rgba(251, 191, 36, 0.35)' })
            .onClick(() => {
              this.openIssues('review');
            })
        }
      }
      .width('100%')
      .padding({ top: 2 })
    }
  }

  /** 状态胶囊：文字色 + 可选圆点 */
  @Builder
  Chip(color: string, dot: string | null, text: string) {
    Row({ space: 6 }) {
      if (dot !== null) {
        Circle()
          .width(6)
          .height(6)
          .fill(dot)
      }
      Text(text)
        .fontSize(13)
        .fontWeight(600)
        .fontColor(color)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .backgroundColor(`${color}1f`)
    .borderRadius(16)
    .border({ width: 1, color: `${color}59` })
  }

  @Builder
  Banner(text: string, color: string) {
    Text(text)
      .fontSize(13)
      .fontColor(color)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .width('100%')
      .backgroundColor(`${color}1a`)
      .borderRadius(10)
      .border({ width: 1, color: `${color}40` })
      .margin({ top: 4 })
  }

  /** 不在可见范围：内容隐藏，管理与设置仍可用 */
  @Builder
  HiddenContent() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.lock_fill'))
        .fontSize(36)
        .fontColor(['rgba(255, 255, 255, 0.28)'])
      Text('内容已隐藏：你不在这个库的可见范围内。\n设置、扫描与待处理仍可使用；把自己加入可见范围即可浏览。')
        .fontSize(15)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      if (this.canManage()) {
        Text('把我加入可见范围')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.lineStrong })
          .onClick(() => {
            this.openSheet('edit');
          })
      }
    }
    .width('100%')
    .padding({ top: 64, left: Theme.pagePadding, right: Theme.pagePadding })
    .alignItems(HorizontalAlign.Center)
  }

  // MARK: 墙

  /**
   * 作品视图的内容（List 的直接子项）。
   * 空态、筛空、加载中、主墙、未识别区各占一个 ListItem。
   */
  @Builder
  WallItems(library: LibraryView) {
    if (this.wallItems !== null && (this.wallItems as LibraryItemView[]).length === 0
      && this.provisional.length === 0 && !this.filter.isEmpty()) {
      ListItem() {
        Column() {
          this.FilterControls()
          LibraryFilterEmptyState({
            libraryId: this.libraryId,
            filter: this.filter,
            onRemove: (dim: string, value: string): void => {
              this.onFilterRemove(dim, value);
            },
            onClear: (): void => {
              this.onFilterClear();
            }
          })
            .margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    } else if (this.wallItems !== null && (this.wallItems as LibraryItemView[]).length === 0
      && this.provisional.length === 0) {
      ListItem() {
        Text(`这个库还没有内容。\n${this.canManage()
          ? '点右上角菜单里的「扫描库」把已有影片识别入库；订阅内容下载完成后也会自动进来。'
          : '订阅内容下载并入库后会显示在这里。'}`)
          .fontSize(15)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 64, left: Theme.pagePadding, right: Theme.pagePadding })
      }
    } else {
      ListItem() {
        Column() {
          this.FilterControls()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 16 })
      }
      this.WallRows(library)
      if (this.provisional.length > 0) {
        ListItem() {
          this.ProvisionalSection()
        }
      }
    }
  }

  /**
   * 主墙的各行。
   *
   * 这是懒加载的落点：**LazyForEach 只有用在具备懒加载能力的容器里才会按可视区建组件**
   * （List / Grid / Swiper / WaterFlow）。放在 Scroll 里的 Column 中会退化成全量构建——
   * 实测 20 行全部被取一遍（docs/harmonyos-port.md 记了这次实验）。
   * 未识别区与分区墙数据量小，各占一个 ListItem 即可。
   */
  @Builder
  WallRows(library: LibraryView) {
    if (this.wallItems === null) {
      ListItem() {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.textMuted)
          .margin({ top: 40 })
      }
    } else if (this.timeline()) {
      // 非刮削库：竖版/横版分两区，行数有限，整块建
      ListItem() {
        this.TimelineSections(this.wallItems as LibraryItemView[])
      }
      ListItem() {
        this.LoadMoreFooter(this.wallItems as LibraryItemView[])
      }
    } else {
      LazyForEach(this.wallRows, (row: LibraryItemView[]) => {
        ListItem() {
          this.WallRow(row, library.capabilities.default_aspect > 1 ? 16 / 9 : Theme.posterAspect,
            this.showRating())
        }
      }, (row: LibraryItemView[]) => row.map((item: LibraryItemView): string => `${item.media_item_id}`).join('-'))
      ListItem() {
        this.LoadMoreFooter(this.wallItems as LibraryItemView[])
      }
    }
  }

  @Builder
  FilterControls() {
    Column({ space: 10 }) {
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
      LibraryFilterBar({
        libraryId: this.libraryId,
        filter: this.filter,
        collections: this.collections,
        onToggle: (dim: string, value: string): void => {
          this.onFilterToggle(dim, value);
        },
        onRemove: (dim: string, value: string): void => {
          this.onFilterRemove(dim, value);
        },
        onClear: (): void => {
          this.onFilterClear();
        },
        onApplyRules: (rules: JsonValue[]): void => {
          this.onApplyRules(rules);
        },
        onOpenCollection: (collection: CollectionView): void => {
          this.navStack.pushPathByName('collectionDetail', new CollectionRouteParams(collection.id, this.libraryId));
        },
        onShowAllCollections: (): void => {
          this.view = 'collections';
        },
        onSaveAsCollection: (): void => {
          this.openSheet('saveCollection');
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 16 })
  }

  /**
   * 非刮削库（家庭录像、照片库）：画面比例混着竖版和横版，按比例拆成两区渲染，
   * 免得同一行里海报和缩略图被同一个框比例撑变形（对应 iOS LibraryDetailView 的 timeline 分支）。
   * 只有一类时不分区，整墙按那一类的比例铺。
   */
  @Builder
  TimelineSections(items: LibraryItemView[]) {
    Column({ space: 0 }) {
      if (this.timelineSplit(items)) {
        this.TimelineSectionTitle('海报', 0)
        this.Grid(this.timelinePosters(items), Theme.posterAspect, this.showRating())
        this.TimelineSectionTitle('缩略图', 24)
        this.Grid(this.timelineThumbs(items), 16 / 9, this.showRating())
      } else {
        // 只剩一类：没有竖版就是全横版，否则全竖版
        this.Grid(items, this.timelineHasPosters(items) ? Theme.posterAspect : 16 / 9, this.showRating())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 竖版条目（画面比 < 1） */
  private timelinePosters(items: LibraryItemView[]): LibraryItemView[] {
    return items.filter((item: LibraryItemView): boolean => item.primary_aspect < 1);
  }

  /** 横版条目（画面比 >= 1） */
  private timelineThumbs(items: LibraryItemView[]): LibraryItemView[] {
    return items.filter((item: LibraryItemView): boolean => item.primary_aspect >= 1);
  }

  /** 两类都有才分区；只有一类时不分（同 iOS 的 `!posters.isEmpty, !thumbs.isEmpty`） */
  private timelineSplit(items: LibraryItemView[]): boolean {
    return this.timelinePosters(items).length > 0 && this.timelineThumbs(items).length > 0;
  }

  /** 不分区时：有竖版就整墙按海报比例铺，没有就整墙按 16:9（同 iOS 的 `grid(items, wide: posters.isEmpty)`） */
  private timelineHasPosters(items: LibraryItemView[]): boolean {
    return items.some((item: LibraryItemView): boolean => item.primary_aspect < 1);
  }

  /** 当前排序/筛选下是否显示评分角标（同 iOS posterWall 的 showRating） */
  private showRating(): boolean {
    return this.sort.sort === 'rating' || this.filter.ratingGte !== null;
  }

  /** 分区小标题（对应 iOS sectionTitle；topGap 是「缩略图」上多留的那 24） */
  @Builder
  TimelineSectionTitle(text: string, topGap: number) {
    Text(text)
      .fontSize(17)
      .fontWeight(600)
      .fontColor(Theme.text)
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: topGap, bottom: 12 })
  }

  /**
   * 一行格子（主墙与分区墙共用）：末行不满时补空位，保持每格等宽、左对齐（同 LazyVGrid）。
   * 页面左右边距与行间距都挂在行上——主墙的每一行是一个独立的 ListItem，外层容器加不上内边距。
   */
  @Builder
  WallRow(row: LibraryItemView[], frameAspect: number, showRating: boolean) {
    Row({ space: 12 }) {
      ForEach(row, (item: LibraryItemView) => {
        Column() {
          LibraryInventoryCell({
            item: item,
            libraryId: this.libraryId,
            frameAspect: frameAspect,
            showRating: showRating,
            working: this.workingLabel(item),
            onOpen: (opened: LibraryItemView): void => {
              this.navStack.pushPathByName('libraryItem',
                new ItemRouteParams(this.libraryId, opened.media_item_id));
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

  /** 分区墙 / 未识别区用：这两处数据量小且不常变，整批建更省事（主墙走 WallRows 的 LazyForEach） */
  @Builder
  Grid(items: LibraryItemView[], frameAspect: number, showRating: boolean) {
    Column() {
      ForEach(this.chunked(items, this.columns), (row: LibraryItemView[]) => {
        this.WallRow(row, frameAspect, showRating)
      }, (row: LibraryItemView[]) => row.map((item: LibraryItemView): string => `${item.media_item_id}`).join('-'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 最后一行的空位序号（0..n） */
  private emptySlots(row: LibraryItemView[]): number[] {
    const slots: number[] = [];
    for (let i: number = row.length; i < this.columns; i++) {
      slots.push(i);
    }
    return slots;
  }

  private chunked(items: LibraryItemView[], size: number): LibraryItemView[][] {
    const rows: LibraryItemView[][] = [];
    for (let i: number = 0; i < items.length; i += size) {
      rows.push(items.slice(i, i + size));
    }
    return rows;
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
        Text(`加载中…（第 ${this.wallStart + 1}–${this.wallStart + items.length} 部 / 共 ${Math.max((this.library() as LibraryView).stats.item_count, this.wallStart + items.length)}）`)
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 20, bottom: 20 })
    }
  }

  /** 未识别区：按文件名展示，可以直接播放；认领身份后会并入上方的正式条目 */
  @Builder
  ProvisionalSection() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text(`未识别 ${this.provisional.length}`)
            .fontSize(17)
            .fontWeight(600)
            .fontColor('rgba(255, 255, 255, 0.85)')
          Text('按文件名展示，可以直接播放；认领身份后会并入上方的正式条目。')
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.canManage()) {
          Text('去待处理认领')
            .fontSize(13)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(18)
            .border({ width: 1, color: Theme.line })
            .onClick(() => {
              this.openIssues('unidentified');
            })
        }
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      this.Grid(this.provisional, 16 / 9, false)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 32 })
  }

  // MARK: ⋯ 菜单

  @Builder
  ActionsMenu() {
    Menu() {
      if (this.canManage() && this.library() !== null) {
        MenuItem({ content: this.pendingCount() > 0 ? `待处理 ${this.pendingCount()}` : '待处理' })
          .onClick(() => {
            this.openIssues('missing');
          })
        MenuItem({ content: this.scanLabel(this.menuLibrary()) })
          .enabled(this.scanMenuItemEnabled())
          .onClick(() => {
            this.toggleScan(this.menuLibrary());
          })
        if (this.menuLibrary().capabilities.naming) {
          MenuItem({ content: this.menuLibrary().organizing
            ? `整理中…${this.percent(this.menuLibrary().organize_progress) === null ? '' : ` ${this.percent(this.menuLibrary().organize_progress)}%`}`
            : '整理文件名' })
            .onClick(() => {
              this.openSheet('organize');
            })
        }
        MenuItem({ content: this.metaLabel(this.menuLibrary()) })
          .onClick(() => {
            this.toggleMetaRefresh(this.menuLibrary());
          })
        if (this.menuLibrary().extract_chapter_images) {
          MenuItem({ content: this.chapterLabel(this.menuLibrary()) })
            .enabled(!this.busy() && (this.menuLibrary().chapter_job === null
              || this.menuLibrary().chapter_job === undefined))
            .onClick(() => {
              this.openSheet('chapters');
            })
        }
        MenuItem({ content: '重复文件' })
          .onClick(() => {
            this.navStack.pushPathByName('duplicates', null);
          })
        MenuItem({ content: '回收站' })
          .onClick(() => {
            // 只显示当前这个库的（跨库的回收站在「更多」里进，见下）
            this.navStack.pushPathByName('recycleBin', new RecycleParams(this.libraryId));
          })
        MenuItem({ content: '编辑库' })
          .onClick(() => {
            this.openSheet('edit');
          })
      }
      if (this.view === 'collections') {
        MenuItem({ content: this.showHiddenCollections ? '不显示已隐藏的合集' : '显示已隐藏的合集' })
          .onClick(() => {
            this.showHiddenCollections = !this.showHiddenCollections;
            this.reloadCollections();
          })
      }
    }
  }

  /** 生成章节的确认面板（iOS 是三键弹窗，这里用半屏面板承载同款文案与三选） */
  @Builder
  ChaptersSheet() {
    Column({ space: 14 }) {
      Text(`为「${this.library() === null ? '' : (this.library() as LibraryView).name}」生成章节？`)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
      Text(LibraryDetailPage.bullets('后台低优先级执行，可在任务中心观察或取消：', [
        '只处理章节图还缺的文件（含上次没抓完、图丢了的），已经齐的不动',
        '每个文件按章节数定位读取若干次，网络挂载的库会有读取流量',
        '不会移动、修改或删除你的视频文件'
      ]) + '\n\n选「已有的章节也重新生成」会按当前章节与合成策略全部重新生成，你手动选定的图不会被覆盖。')
        .fontSize(14)
        .fontColor(Theme.textMuted)
        .lineHeight(20)
        .width('100%')
      Text('开始生成')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.accentStrong)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(14)
        .border({ width: 1, color: Theme.lineStrong })
        .onClick(() => {
          this.startChapters(false);
        })
      Text('已有的章节也重新生成')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 14 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(14)
        .border({ width: 1, color: Theme.line })
        .onClick(() => {
          this.startChapters(true);
        })
      Text('取消')
        .fontSize(16)
        .fontColor(Theme.textMuted)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.askingChapters = false;
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 20, bottom: 24 })
  }
}
