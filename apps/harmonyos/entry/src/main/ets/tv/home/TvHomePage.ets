/**
 * TV 首页（US2）：焦点驱动大图区 + 按网页偏好渲染的横滑内容行（对应参考端 Home/TVHomeView.swift）。
 *
 * - 大图区：背景剧照铺整页（TvStageBackdrop，交叉淡入），左下文案块讲焦点停稳（0.16s 防抖，TvHomeFocus）
 *   的那部「接下来继续」；不自动轮播，焦点离开时停在最后看的那部。
 * - 内容行：HomeRows.build 按网页端首页偏好合并（偏好空/失败走默认行集），
 *   行数据复用 common/LibraryHomeStore（快照秒开 + 并发拉取 + 60s 轮询）；
 *   「按类型找」行的类型格子走 uiLibraryKindGenres 单独取。
 * - 默认焦点：「继续观看」第一张卡（页签锚点 tv_tab_anchor 也在它身上——侧边栏收起、
 *   二级页返回时 TvShell requestFocus 到它）；按确认直接续播。
 * - 行点击路由进 TvUiState 路由栈：详情 / 库墙 / 合集 / 类型墙（「查看全部」sourceKey
 *   与 LibraryHomeStore.fetchKey 同构，行墙 T024 按它取数）。
 */
import { AppModel } from '../../common/AppModel';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MovieClawApi } from '../../api/Endpoints';
import {
  CollectionView,
  FavoriteItemView,
  LibraryItemView,
  LibraryKindGenreView,
  LibraryView,
  ReelItemView,
  ReelPlayView,
  UpNextItemView
} from '../../api/Models';
import { HomeRow, HomeRows, UpNextKind, FavoritesKind, LibrariesKind, GenresKind,
  LibraryRowKind, CollectionRowKind } from '../../library/HomeRows';
import { LibraryHomePrefs, LibraryHomeStore } from '../../library/LibraryHomeStore';
import { ImageUrls } from '../../common/ImageUrls';
import {
  TvCollectionRoute,
  TvDetailRoute,
  TvHomeFocus,
  TvPlayRequest,
  TvRowWallRoute,
  TvUiState,
  TvWallRoute
} from '../model/TvUiState';
import { TvStageAction, TvStageBackdrop, TvStageBlock } from '../components/TvStage';
import { TvShelf, TvShelfCard } from '../components/TvShelf';
import { TvFocus } from '../components/TvFocus';
import { TvFormat, TvStateView } from '../components/TvCards';
import { TvPlayback } from '../player/TvAvPlayerEngine';
import { TvColors } from '../theme/TvTheme';
import { TvMetrics } from '../theme/TvTheme';

/**
 * 大图区文案源：把「继续观看 / 收藏 / 库行 / 合集行」的条目统一拍平。
 * 大图区只关心这些字段；继续观看条目信息最全（Logo/分集行/类型/简介/续播按钮），
 * 列表类条目服务端不给简介/类型/Logo，就显示剧照 + 片名 + 年份。
 */
class TvStageSource {
  readonly itemId: number;
  readonly libraryId: number | null;
  readonly title: string;
  readonly backdropRaw: string | null;
  readonly posterRaw: string | null;
  readonly logoRaw: string | null;
  readonly headline: string | null;
  readonly metaLine: string | null;
  readonly overview: string | null;
  readonly upNext: UpNextItemView | null;

  constructor(itemId: number, libraryId: number | null, title: string,
    backdropRaw: string | null, posterRaw: string | null, logoRaw: string | null,
    headline: string | null, metaLine: string | null, overview: string | null,
    upNext: UpNextItemView | null) {
    this.itemId = itemId;
    this.libraryId = libraryId;
    this.title = title;
    this.backdropRaw = backdropRaw;
    this.posterRaw = posterRaw;
    this.logoRaw = logoRaw;
    this.headline = headline;
    this.metaLine = metaLine;
    this.overview = overview;
    this.upNext = upNext;
  }

  /** 继续观看条目：事实行「2023 · 古装 · 喜剧」，电影再加片长；类型只取前两个 */
  static fromUpNext(item: UpNextItemView): TvStageSource {
    const parts: string[] = [];
    if (item.year !== null && item.year !== undefined) {
      parts.push(`${item.year}`);
    }
    const genres: string[] = item.genres ?? [];
    for (let i = 0; i < genres.length && i < 2; i++) {
      parts.push(genres[i]);
    }
    if (item.kind !== 'tv') {
      const durationMs: number | null = item.duration_ms ?? null;
      if (durationMs !== null && durationMs >= 60000) {
        parts.push(TvFormat.duration(durationMs / 60000));
      }
    }
    return new TvStageSource(item.media_item_id, item.library_id, item.title,
      item.backdrop_url ?? item.episode_still_url ?? item.poster_url ?? null,
      item.poster_url ?? null, item.logo_url ?? null,
      item.kind === 'tv'
        ? TvFormat.episodeLine(item.season_number, item.episode_number, item.episode_title ?? null)
        : null,
      parts.length > 0 ? parts.join(' · ') : null,
      item.overview ?? null, item);
  }

  /** 收藏 / 库行 / 合集行条目 */
  static fromItem(itemId: number, libraryId: number | null, title: string,
    backdropRaw: string | null, posterRaw: string | null, year: number | null): TvStageSource {
    return new TvStageSource(itemId, libraryId, title, backdropRaw, posterRaw, null, null,
      year !== null ? `${year}` : null, null, null);
  }
}

@ComponentV2
export struct TvHomePage {
  /** 焦点防抖（0.16s 停稳切大图）+ 大图预告计时（停稳 2s 起，US9） */
  @Local focus: TvHomeFocus = new TvHomeFocus(null);
  @Local ui: TvUiState = TvUiState.shared;
  private pollId: number = -1;

  // —— 大图预告（US9）——

  /** 已解析好的完整播放地址；空串 = 不挂预告画面层 */
  @Local previewUrl: string = '';
  /** 起播毫秒（seek 模式；clip 恒 0） */
  @Local previewStartMs: number = 0;
  /** 代际：拆掉后迟到的取址回调全部作废 */
  private previewGeneration: number = 0;
  /** 放不了 / 放完的不再反复取（同参考端「取不到的不再反复取」） */
  private previewDone: Set<number> = new Set<number>();

  // —— 整页数据（@Local 副本；reload 后整批重赋值触发刷新） ——

  /** null = 还没加载到（含缓存） */
  @Local libraries: LibraryView[] | null = null;
  @Local failed: boolean = false;
  @Local rows: HomeRow[] = [];
  @Local upNext: UpNextItemView[] = [];
  @Local favoritesItems: FavoriteItemView[] = [];
  @Local favoritesTotal: number = 0;
  /** 「我的媒体库」行里接在库后面的合集（首页显示中的合集行，同一合集只放一张） */
  @Local pinnedCollections: CollectionView[] = [];
  @Local rowItems: Map<string, LibraryItemView[]> = new Map<string, LibraryItemView[]>();
  @Local genresByKind: Map<string, LibraryKindGenreView[]> = new Map<string, LibraryKindGenreView[]>();
  /** 每行拍好的卡片（行 id → 卡片数组） */
  @Local rowCards: Map<string, TvShelfCard[]> = new Map<string, TvShelfCard[]>();
  /** 首次拿到卡片后把焦点落到「继续观看」第一张卡（TV 上必须有焦点，方向键才有意义） */
  private didFocusAnchor: boolean = false;

  aboutToAppear(): void {
    this.reload();
    this.pollId = setInterval((): void => {
      this.reload();
    }, 60000);
  }

  aboutToDisappear(): void {
    if (this.pollId >= 0) {
      clearInterval(this.pollId);
      this.pollId = -1;
    }
    this.stopPreview();
    this.focus.reset();
  }

  // MARK: - 大图预告（US9：焦点停稳 2s → 取段 → 原地播；焦点移开/滚走/进详情播放即拆）

  /** 预告计时达成（previewKey 置位）→ 取段开播；移开（置空）→ 立即拆 */
  @Monitor('focus.previewKey')
  private onPreviewKeyChange(): void {
    const key: string | null = this.focus.previewKey;
    if (key === null) {
      this.stopPreview();
      return;
    }
    this.startPreview(key);
  }

  /** 二级页 / 播放器整屏覆盖前先行拆掉预告（clearPreview 会连带触发上面的拆除） */
  @Monitor('ui.routes', 'ui.playerRequest')
  private onCoverChange(): void {
    if (this.ui.routes.length > 0 || this.ui.playerRequest !== null) {
      this.focus.clearPreview();
    }
  }

  private startPreview(key: string): void {
    // TODO(dbg): 临时禁用预告，验证 XComponent 表面层是否吞掉窗口触摸输入；原实现验证后恢复
    if (key !== null && key.length >= 0) {
      return;
    }
  }

  /** 拆掉在播预告：代际推进作废取址回调，画面层卸载（声音随之停） */
  private stopPreview(): void {
    this.previewGeneration++;
    this.previewUrl = '';
    this.previewStartMs = 0;
  }

  /** 放完：这一部不再重播，淡回剧照收尾 */
  private onPreviewEnded(): void {
    this.markPreviewDone();
    this.focus.clearPreview();
  }

  /** 放不了（原片、读不出索引、解码失败……）：保持剧照不提示，这一部不再反复取 */
  private onPreviewFailed(): void {
    this.markPreviewDone();
    this.focus.clearPreview();
  }

  private markPreviewDone(): void {
    const key: string | null = this.focus.previewKey;
    if (key === null) {
      return;
    }
    const item: UpNextItemView | null = this.findUpNext(key);
    if (item !== null) {
      this.previewDone.add(item.media_item_id);
    }
  }

  // MARK: - 加载（快照先上屏，网络完成二次刷新；60s 轮询同手机端口径）

  private async reload(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const client = AppModel.shared.client;
    const session = AppModel.shared.session;
    const key: string = LibraryHomePrefs.ownerKey(client !== null ? client.origin : '',
      session === null ? null : session.username);
    const settled: Promise<void> = LibraryHomeStore.shared.reload(api, key);
    this.syncFromStore();
    await settled;
    this.syncFromStore();
    this.loadGenres(api);
  }

  /** 把共享 Store 的数据抄进 @Local 副本并重拍卡片 */
  private syncFromStore(): void {
    const store = LibraryHomeStore.shared;
    const prefs = LibraryHomePrefs.shared;
    this.libraries = store.libraries;
    this.failed = store.failed;
    this.upNext = store.upNext ?? [];
    const favorites = store.favorites;
    this.favoritesItems = favorites !== null ? favorites.items : [];
    this.favoritesTotal = favorites !== null ? favorites.total : 0;
    const rows: HomeRow[] = HomeRows.build(prefs.rows ?? [], store.libraries ?? [], store.collections)
      .filter((row: HomeRow): boolean => !row.hidden);
    this.rows = rows;
    this.pinnedCollections = TvHomePage.pinnedCollections(rows);
    const items: Map<string, LibraryItemView[]> = new Map<string, LibraryItemView[]>();
    store.itemsByKey.forEach((list: LibraryItemView[], itemKey: string): void => {
      items.set(itemKey, list);
    });
    this.rowItems = items;
    this.rebuildCards();
  }

  /** 「我的媒体库」里接在库后面的合集：首页显示中的合集行，同一合集只放一张（同网页与手机） */
  private static pinnedCollections(rows: HomeRow[]): CollectionView[] {
    const out: CollectionView[] = [];
    const seen: Set<number> = new Set<number>();
    for (const row of rows) {
      if (row.kind instanceof CollectionRowKind) {
        const kind = row.kind;
        if (!seen.has(kind.collection.id)) {
          seen.add(kind.collection.id);
          out.push(kind.collection);
        }
      }
    }
    return out;
  }

  /** 「按类型找电影 / 剧集」行各自的类型格子（并发取，取完重拍卡片） */
  private async loadGenres(api: MovieClawApi): Promise<void> {
    const kinds: string[] = [];
    for (const row of this.rows) {
      if (row.kind instanceof GenresKind) {
        const kind = row.kind;
        if (!kinds.includes(kind.kind)) {
          kinds.push(kind.kind);
        }
      }
    }
    if (kinds.length === 0) {
      return;
    }
    const next: Map<string, LibraryKindGenreView[]> = new Map<string, LibraryKindGenreView[]>();
    const tasks: Promise<void>[] = [];
    for (const kind of kinds) {
      tasks.push(api.uiLibraryKindGenres(kind)
        .then((list: LibraryKindGenreView[]): void => {
          next.set(kind, list);
        })
        .catch((): void => {
        }));
    }
    await Promise.all(tasks);
    this.genresByKind = next;
    this.rebuildCards();
  }

  /** 每行数据 → TvShelfCard；第一个有卡的行的第一张卡拿默认焦点与页签锚点 */
  private rebuildCards(): void {
    const origin: string = AppModel.origin();
    const cards: Map<string, TvShelfCard[]> = new Map<string, TvShelfCard[]>();
    for (const row of this.rows) {
      cards.set(row.id, this.cardsForRow(row, origin));
    }
    this.rowCards = cards;
    for (const row of this.rows) {
      const list: TvShelfCard[] = cards.get(row.id) ?? [];
      if (list.length > 0) {
        list[0].defaultFocused = true;
        list[0].focusKey = 'tv_tab_anchor';
        this.focusAnchorOnce();
        return;
      }
    }
  }

  /**
   * 首屏卡片是异步加载出来的，defaultFocus 只在页面首次展示时生效——数据晚到就落空，
   * 遥控器方向键会「按了没反应」。这里在锚点卡真正挂上后显式要一次焦点。
   */
  private focusAnchorOnce(): void {
    if (this.didFocusAnchor) {
      return;
    }
    this.didFocusAnchor = true;
    setTimeout((): void => {
      if (this.ui.routes.length > 0 || this.ui.playerRequest !== null) {
        return;
      }
      TvFocus.request(this.getUIContext(), 'tv_tab_anchor');
    }, 200);
  }

  private cardsForRow(row: HomeRow, origin: string): TvShelfCard[] {
    const out: TvShelfCard[] = [];
    if (row.kind instanceof UpNextKind) {
      for (const item of this.upNext) {
        out.push(TvShelfCard.fromUpNext(item, origin, false));
      }
      return out;
    }
    if (row.kind instanceof FavoritesKind) {
      for (const item of this.favoritesItems) {
        out.push(TvShelfCard.fromFavorite(item, origin, false));
      }
      return out;
    }
    if (row.kind instanceof LibrariesKind) {
      const libraries: LibraryView[] = this.libraries ?? [];
      for (const library of libraries) {
        if (library.viewer_access) {
          out.push(TvShelfCard.fromLibrary(library, origin, false));
        }
      }
      for (const collection of this.pinnedCollections) {
        out.push(TvShelfCard.fromCollection(collection, origin, false));
      }
      return out;
    }
    if (row.kind instanceof GenresKind) {
      const kind = row.kind;
      const genres: LibraryKindGenreView[] = this.genresByKind.get(kind.kind) ?? [];
      for (const genre of genres) {
        out.push(TvShelfCard.fromGenre(genre, kind.kind, origin, false));
      }
      return out;
    }
    if (row.kind instanceof LibraryRowKind || row.kind instanceof CollectionRowKind) {
      const items: LibraryItemView[] = this.rowItems.get(LibraryHomeStore.fetchKey(row)) ?? [];
      for (const item of items) {
        out.push(TvShelfCard.fromItem(item, origin, false));
      }
    }
    return out;
  }

  // MARK: - 大图区（焦点停稳的那张条目卡；焦点离开时停在最后看的那部）

  /** 焦点停稳的卡片 → 大图区文案源；upnext/fav/item 三处回查，查不到回落继续观看第一条 */
  private stageSource(): TvStageSource | null {
    const settled: string | null = this.focus.settledKey;
    if (settled !== null) {
      const byKey: TvStageSource | null = this.stageSourceByKey(settled);
      if (byKey !== null) {
        return byKey;
      }
    }
    return this.upNext.length > 0 ? TvStageSource.fromUpNext(this.upNext[0]) : null;
  }

  private stageSourceByKey(key: string): TvStageSource | null {
    const up: UpNextItemView | null = this.findUpNext(key);
    if (up !== null) {
      return TvStageSource.fromUpNext(up);
    }
    const fav: FavoriteItemView | null = this.findFavorite(key);
    if (fav !== null) {
      return TvStageSource.fromItem(fav.media_item_id, fav.library_id, fav.title,
        fav.backdrop_url ?? fav.poster_url ?? null, fav.poster_url ?? null, fav.year ?? null);
    }
    const item: LibraryItemView | null = this.findItem(key);
    if (item !== null) {
      return TvStageSource.fromItem(item.media_item_id, item.library_id ?? null, item.title,
        item.backdrop_url ?? item.poster_url ?? null, item.poster_url ?? null, item.year ?? null);
    }
    return null;
  }

  /** 大图区背景：整部剧的背景图优先（分集剧照最多 1080p 且容易剧透），再退剧照、海报 */
  private stageBackdropUrl(): string {
    const stage: TvStageSource | null = this.stageSource();
    if (stage === null) {
      return '';
    }
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), stage.backdropRaw, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1920`;
  }

  private stageTitle(): string {
    const stage: TvStageSource | null = this.stageSource();
    return stage === null ? '' : stage.title;
  }

  private stageLogoUrl(): string {
    const stage: TvStageSource | null = this.stageSource();
    if (stage === null) {
      return '';
    }
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), stage.logoRaw, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1900`;
  }

  private stageHeadline(): string | null {
    const stage: TvStageSource | null = this.stageSource();
    return stage === null ? null : stage.headline;
  }

  private stageMetaLine(): string | null {
    const stage: TvStageSource | null = this.stageSource();
    return stage === null ? null : stage.metaLine;
  }

  private stageOverview(): string | null {
    const stage: TvStageSource | null = this.stageSource();
    return stage === null ? null : stage.overview;
  }

  private stageActions(): TvStageAction[] {
    const stage: TvStageSource | null = this.stageSource();
    if (stage === null) {
      return [];
    }
    const actions: TvStageAction[] = [];
    if (stage.upNext !== null) {
      const item: UpNextItemView = stage.upNext;
      actions.push(new TvStageAction('play',
        item.position_ms > 0 ? '继续播放' : '播放', true,
        $r('sys.symbol.play_fill'), (): void => {
          this.resume(item);
        }));
      actions.push(new TvStageAction('details', '详情', false,
        $r('sys.symbol.info_circle'), (): void => {
          TvUiState.shared.pushRoute(new TvDetailRoute(item.library_id, item.media_item_id));
        }));
      return actions;
    }
    const libraryId: number | null = stage.libraryId;
    if (libraryId !== null) {
      actions.push(new TvStageAction('details', '详情', true,
        $r('sys.symbol.info_circle'), (): void => {
          TvUiState.shared.pushRoute(new TvDetailRoute(libraryId, stage.itemId));
        }));
    }
    return actions;
  }

  // MARK: - 行交互

  private cardsOf(row: HomeRow): TvShelfCard[] {
    return this.rowCards.get(row.id) ?? [];
  }

  private hasContent(): boolean {
    for (const row of this.rows) {
      if (this.cardsOf(row).length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 条目行的卡焦点变化：继续观看 / 收藏 / 库行 / 合集行都驱动大图区（0.16s 防抖在 TvHomeFocus） */
  private cardFocusChanged(row: HomeRow, card: TvShelfCard, active: boolean): void {
    if (active && (row.kind instanceof UpNextKind || row.kind instanceof FavoritesKind
      || row.kind instanceof LibraryRowKind || row.kind instanceof CollectionRowKind)) {
      this.focus.focusCard(card.key);
    }
  }

  /** 按确认直接续播（续播点由服务端按这一集 / 这部片的进度给） */
  private resume(item: UpNextItemView): void {
    this.focus.clearPreview();
    const isEpisode: boolean = item.kind === 'tv';
    // playback-first：先建引擎预协商，再挂播放器视图（视图 adopt 接管）
    const request: TvPlayRequest = new TvPlayRequest(
      item.library_id,
      item.media_item_id,
      isEpisode ? item.season_number : null,
      isEpisode ? item.episode_number : null,
      null,
      null,
      item.title,
      isEpisode ? TvFormat.episodeLine(item.season_number, item.episode_number, item.episode_title ?? null) : null,
      isEpisode);
    TvPlayback.begin(request);
    TvUiState.shared.openPlayer(request);
  }

  private activateCard(row: HomeRow, card: TvShelfCard): void {
    hilog.info(0x0000, 'DbgTap', 'ACTIVATE kind=%{public}s key=%{public}s', card.kind, card.key);
    if (card.kind === 'landscape') {
      const item: UpNextItemView | null = this.findUpNext(card.key);
      if (item !== null) {
        this.resume(item);
      }
      return;
    }
    if (card.kind === 'library') {
      if (card.collection) {
        const collection: CollectionView | null = this.findCollection(card.key);
        if (collection !== null) {
          TvUiState.shared.pushRoute(new TvCollectionRoute(collection.id, collection.name));
        }
      } else {
        const library: LibraryView | null = this.findLibrary(card.key);
        if (library !== null) {
          TvUiState.shared.pushRoute(new TvWallRoute(library.id, library.name, null));
        }
      }
      return;
    }
    if (card.kind === 'genre') {
      const genre: LibraryKindGenreView | null = this.findGenre(card.key);
      if (genre !== null) {
        TvUiState.shared.pushRoute(new TvRowWallRoute(
          `genre:${card.mediaKind}:${genre.value}`, genre.label));
      }
      return;
    }
    if (card.kind === 'poster') {
      const libraryId: number | null = this.detailLibraryId(row, card);
      if (libraryId !== null) {
        TvUiState.shared.pushRoute(new TvDetailRoute(libraryId, this.itemIdOf(card.key)));
      }
    }
  }

  /** 行尾「查看全部」：只有收藏 / 库行 / 合集行有 */
  private canSeeAll(row: HomeRow): boolean {
    return row.kind instanceof FavoritesKind || row.kind instanceof LibraryRowKind
      || row.kind instanceof CollectionRowKind;
  }

  /** 尾卡上写的总数：只在确切知道时写（「最近观看」「只看未看」的量不知道） */
  private seeAllTotal(row: HomeRow): number | null {
    if (row.kind instanceof FavoritesKind) {
      return this.favoritesTotal;
    }
    if (row.kind instanceof LibraryRowKind) {
      const kind = row.kind;
      return !kind.unwatched && kind.sort !== 'last_played' ? kind.library.stats.item_count : null;
    }
    if (row.kind instanceof CollectionRowKind) {
      const kind = row.kind;
      return kind.collection.item_count;
    }
    return null;
  }

  /** 行墙数据源：与这一行同一套取数参数（排序、正倒序、只看未看），进来看到的顺序和行里一致 */
  private openSeeAll(row: HomeRow): void {
    if (row.kind instanceof FavoritesKind) {
      const kind = row.kind;
      TvUiState.shared.pushRoute(new TvRowWallRoute(
        `favorites:${kind.sort}:${kind.reversed}`, row.title()));
      return;
    }
    if (row.kind instanceof LibraryRowKind || row.kind instanceof CollectionRowKind) {
      TvUiState.shared.pushRoute(new TvRowWallRoute(LibraryHomeStore.fetchKey(row), row.title()));
    }
  }

  // MARK: - 按卡片 key 回找数据（行/卡片都不持有业务对象，路由参数从这里取）

  private findUpNext(key: string): UpNextItemView | null {
    for (const item of this.upNext) {
      if (`upnext_${item.media_item_id}` === key) {
        return item;
      }
    }
    return null;
  }

  private findLibrary(key: string): LibraryView | null {
    const libraries: LibraryView[] = this.libraries ?? [];
    for (const library of libraries) {
      if (`library_${library.id}` === key) {
        return library;
      }
    }
    return null;
  }

  private findCollection(key: string): CollectionView | null {
    for (const collection of this.pinnedCollections) {
      if (`collection_${collection.id}` === key) {
        return collection;
      }
    }
    return null;
  }

  private findGenre(key: string): LibraryKindGenreView | null {
    for (const row of this.rows) {
      if (row.kind instanceof GenresKind) {
        const kind = row.kind;
        const genres: LibraryKindGenreView[] = this.genresByKind.get(kind.kind) ?? [];
        for (const genre of genres) {
          if (`genre_${kind.kind}_${genre.value}` === key) {
            return genre;
          }
        }
      }
    }
    return null;
  }

  private findFavorite(key: string): FavoriteItemView | null {
    for (const item of this.favoritesItems) {
      if (`fav_${item.media_item_id}` === key) {
        return item;
      }
    }
    return null;
  }

  private findItem(key: string): LibraryItemView | null {
    const lists: LibraryItemView[][] = Array.from(this.rowItems.values());
    for (const list of lists) {
      for (const item of list) {
        if (`item_${item.media_item_id}` === key) {
          return item;
        }
      }
    }
    return null;
  }

  /** 海报卡的详情落点库：条目自带的优先，没有用行本身的库（单库墙 / 合集所在库） */
  private detailLibraryId(row: HomeRow, card: TvShelfCard): number | null {
    const favorite: FavoriteItemView | null = this.findFavorite(card.key);
    if (favorite !== null) {
      return favorite.library_id;
    }
    const item: LibraryItemView | null = this.findItem(card.key);
    if (item !== null && item.library_id !== null && item.library_id !== undefined) {
      return item.library_id;
    }
    if (row.kind instanceof LibraryRowKind) {
      const kind = row.kind;
      return kind.library.id;
    }
    if (row.kind instanceof CollectionRowKind) {
      const kind = row.kind;
      return kind.collection.library_id ?? null;
    }
    return null;
  }

  /** 卡片 key（fav_12 / item_34）里的条目 id */
  private itemIdOf(key: string): number {
    const parts: string[] = key.split('_');
    return Number(parts[parts.length - 1]);
  }

  // MARK: - 布局

  build() {
    Stack() {
      TvStageBackdrop({
        imageUrl: this.stageBackdropUrl(),
        kenBurns: true,
        previewUrl: this.previewUrl,
        previewStartMs: this.previewStartMs,
        onPreviewEnded: (): void => {
          this.onPreviewEnded();
        },
        onPreviewFailed: (): void => {
          this.onPreviewFailed();
        }
      })
      this.Body()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private Body() {
    if (this.libraries === null) {
      if (this.failed) {
        TvStateView({
          symbol: $r('sys.symbol.wifi'),
          title: '连不上服务器',
          message: '首页加载失败，请检查网络后重试。',
          actionTitle: '重试',
          defaultFocusAction: true,
          onAction: (): void => {
            this.reload();
          }
        })
      } else {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(TvColors.textMuted)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    } else if (!this.hasContent()) {
      TvStateView({
        symbol: $r('sys.symbol.film'),
        title: '媒体库里还没有内容',
        message: '在网页或手机上添加媒体库并扫描后，影片会出现在这里。'
      })
    } else {
      Scroll() {
        Column({ space: TvMetrics.rowGap }) {
          if (this.stageSource() !== null) {
            this.StageSection()
          } else {
            // 没有大图区时第一行别和标签栏贴在一起
            Column()
              .height(30)
          }
          ForEach(this.rows, (row: HomeRow) => {
            this.RowView(row)
          }, (row: HomeRow) => row.id)
          Column()
            .height(TvMetrics.edge)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .fadingEdge(false)
    }
  }

  /** 首屏上半块：焦点停稳那部的文案 + 继续播放/详情（底部露出一截「接下来继续」） */
  @Builder
  private StageSection() {
    Column() {
      TvStageBlock({
        title: this.stageTitle(),
        logoUrl: this.stageLogoUrl(),
        headline: this.stageHeadline(),
        metaLine: this.stageMetaLine(),
        overview: this.stageOverview(),
        overviewLines: 2,
        actions: this.stageActions(),
        defaultFocusFirstAction: false,
        bottomInset: 24
      })
    }
    .height(430)
    .width('100%')
    // 大图滚走了（触控板滑动、焦点不动）：预告即停（US9「滚走即停」）
    .onVisibleAreaChange([0.0, 0.3], (isVisible: boolean, currentRatio: number): void => {
      if (currentRatio < 0.3 && this.previewUrl !== '') {
        this.focus.clearPreview();
      }
    })
  }

  /** 首页的一行（「接下来继续」/ 收藏 / 媒体库 / 类型 / 库行 / 合集行） */
  @Builder
  private RowView(row: HomeRow) {
    if (this.cardsOf(row).length > 0) {
      TvShelf({
        title: row.title(),
        cards: this.cardsOf(row),
        seeAll: this.canSeeAll(row),
        seeAllTotal: this.seeAllTotal(row),
        onActivate: (card: TvShelfCard): void => {
          this.activateCard(row, card);
        },
        onCardFocus: (card: TvShelfCard, active: boolean): void => {
          this.cardFocusChanged(row, card, active);
        },
        onSeeAll: (): void => {
          this.openSeeAll(row);
        }
      })
    }
  }
}
