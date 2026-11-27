/**
 * TV 首页（US2 + 影院增强）：
 * - 焦点驱动大图区 + ClearLogo 交叉淡入 + 2s 停稳原地高光预告片（`reelsPreview`）+ 4s 无操作影院退让模式；
 * - 内容行：支持「接下来继续」「收藏」「我的高分作品（RatedKind）」「我的媒体库」「按类型找」及自定义库/合集行；
 * - 继续观看卡快捷操作弹窗（菜单键 / 长按呼出：继续播放 / 从头播放 / 查看详情 / 标为已看完）。
 */
import { KeyCode } from '@kit.InputKit';
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { formatUserStars } from '../../common/StarRatingBar';
import { MovieClawApi } from '../../api/Endpoints';
import {
  CollectionView,
  FavoriteItemView,
  LibraryItemView,
  LibraryKindGenreView,
  LibraryView,
  PlaybackMarksRequest,
  ReelItemView,
  UpNextItemView
} from '../../api/Models';
import {
  CollectionRowKind,
  FavoritesKind,
  GenresKind,
  HomeRow,
  HomeRows,
  LibrariesKind,
  LibraryRowKind,
  RatedKind,
  UpNextKind
} from '../../library/HomeRows';
import { LibraryHomePrefs, LibraryHomeStore } from '../../library/LibraryHomeStore';
import { playbackUrl } from '../../playback/PhoneMedia';
import { TvFormat, TvPillButton, TvStateView } from '../components/TvCards';
import { TvFocus } from '../components/TvFocus';
import { TvShelf, TvShelfCard } from '../components/TvShelf';
import { TvStageAction, TvStageBackdrop, TvStageBlock } from '../components/TvStage';
import {
  TvCollectionRoute,
  TvDetailRoute,
  TvHomeFocus,
  TvPlayRequest,
  TvRowWallRoute,
  TvUiState,
  TvWallRoute
} from '../model/TvUiState';
import { TvPlayback } from '../playback/TvPlaybackHost';
import { TvColors, TvMetrics, TvType } from '../theme/TvTheme';

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

  static fromItem(itemId: number, libraryId: number | null, title: string,
    backdropRaw: string | null, posterRaw: string | null, year: number | null,
    userRating: number | null = null): TvStageSource {
    const parts: string[] = [];
    if (year !== null) {
      parts.push(`${year}`);
    }
    if (userRating !== null && userRating > 0) {
      parts.push(`★ ${formatUserStars(userRating)}`);
    }
    return new TvStageSource(itemId, libraryId, title, backdropRaw, posterRaw, null, null,
      parts.length > 0 ? parts.join(' · ') : null, null, null);
  }
}

@ComponentV2
export struct TvHomePage {
  @Local focus: TvHomeFocus = new TvHomeFocus(null);
  @Local ui: TvUiState = TvUiState.shared;
  private pollId: number = -1;

  // —— 大图预告与 4s 静置影院退让（US9+）——
  @Local previewUrl: string = '';
  @Local previewStartMs: number = 0;
  @Local previewEndMs: number = 0;
  @Local idleYield: boolean = false;
  private previewGeneration: number = 0;
  private previewDone: Set<number> = new Set<number>();
  private yieldTimer: number = -1;

  // —— 继续观看快捷操作弹窗 ——
  @Local menuUpNext: UpNextItemView | null = null;

  // —— 整页数据 ——
  @Local libraries: LibraryView[] | null = null;
  @Local failed: boolean = false;
  @Local rows: HomeRow[] = [];
  @Local upNext: UpNextItemView[] = [];
  @Local favoritesItems: FavoriteItemView[] = [];
  @Local favoritesTotal: number = 0;
  @Local ratedItems: LibraryItemView[] = [];
  @Local ratedTotal: number = 0;
  @Local pinnedCollections: CollectionView[] = [];
  @Local rowItems: Map<string, LibraryItemView[]> = new Map<string, LibraryItemView[]>();
  @Local genresByKind: Map<string, LibraryKindGenreView[]> = new Map<string, LibraryKindGenreView[]>();
  @Local rowCards: Map<string, TvShelfCard[]> = new Map<string, TvShelfCard[]>();
  private didFocusAnchor: boolean = false;

  aboutToAppear(): void {
    this.ui.pageBackHandler = (): boolean => {
      if (this.menuUpNext !== null) {
        this.closeUpNextMenu();
        return true;
      }
      if (this.idleYield) {
        this.wakeFromYield();
        return true;
      }
      return false;
    };
    this.reload();
    this.pollId = setInterval((): void => {
      this.reload();
    }, 60000);
  }

  aboutToDisappear(): void {
    this.ui.pageBackHandler = null;
    if (this.pollId >= 0) {
      clearInterval(this.pollId);
      this.pollId = -1;
    }
    this.disarmYieldTimer();
    this.stopPreview();
    this.focus.reset();
  }

  @Monitor('focus.previewKey')
  private onPreviewKeyChange(): void {
    const key: string | null = this.focus.previewKey;
    if (key === null) {
      this.stopPreview();
      return;
    }
    this.startPreview(key);
  }

  @Monitor('ui.routes', 'ui.playerRequest')
  private onCoverChange(): void {
    if (this.ui.routes.length > 0 || this.ui.playerRequest !== null) {
      this.focus.clearPreview();
    }
  }

  private armYieldTimer(): void {
    this.disarmYieldTimer();
    this.yieldTimer = setTimeout((): void => {
      this.yieldTimer = -1;
      if (this.previewUrl !== '' && this.menuUpNext === null) {
        this.getUIContext().animateTo({ duration: 680, curve: Curve.EaseInOut }, (): void => {
          this.idleYield = true;
        });
      }
    }, 4000);
  }

  private disarmYieldTimer(): void {
    if (this.yieldTimer >= 0) {
      clearTimeout(this.yieldTimer);
      this.yieldTimer = -1;
    }
  }

  private wakeFromYield(): void {
    if (this.idleYield) {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.idleYield = false;
      });
    }
    if (this.previewUrl !== '') {
      this.armYieldTimer();
    }
  }

  /** 焦点停稳 2s 后拉取高光预告段并在背景无感淡入播放 */
  private async startPreview(key: string): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    const src: TvStageSource | null = this.stageSourceByKey(key);
    if (api === null || src === null || this.previewDone.has(src.itemId)) {
      return;
    }
    const gen: number = ++this.previewGeneration;
    const isTv: boolean = src.upNext !== null && src.upNext.kind === 'tv';
    const season: number | undefined = isTv && src.upNext !== null ? src.upNext.season_number : undefined;
    const episode: number | undefined = isTv && src.upNext !== null ? src.upNext.episode_number : undefined;
    try {
      const reel: ReelItemView | null = await api.reelsPreview(src.itemId, undefined, season, episode, 'seek,clip');
      if (gen !== this.previewGeneration || reel === null) {
        if (reel === null) {
          this.previewDone.add(src.itemId);
        }
        return;
      }
      const isClip: boolean = reel.play.mode === 'clip';
      const rawUrl: string | null = isClip ? (reel.play.clip_url ?? null) : (reel.play.stream_url ?? null);
      if (rawUrl === null || rawUrl.length === 0) {
        this.previewDone.add(src.itemId);
        return;
      }
      this.previewStartMs = isClip ? 0 : reel.segment.start_ms;
      this.previewEndMs = isClip ? 0 : reel.segment.end_ms;
      this.previewUrl = playbackUrl(AppModel.origin(), rawUrl);
      this.armYieldTimer();
    } catch (_err) {
      if (gen === this.previewGeneration) {
        this.previewDone.add(src.itemId);
      }
    }
  }

  private stopPreview(): void {
    this.previewGeneration++;
    this.disarmYieldTimer();
    this.previewUrl = '';
    this.previewStartMs = 0;
    this.previewEndMs = 0;
    this.idleYield = false;
  }

  private onPreviewEnded(): void {
    this.markPreviewDone();
    this.focus.clearPreview();
  }

  private onPreviewFailed(): void {
    this.markPreviewDone();
    this.focus.clearPreview();
  }

  private markPreviewDone(): void {
    const key: string | null = this.focus.previewKey;
    if (key === null) {
      return;
    }
    const src: TvStageSource | null = this.stageSourceByKey(key);
    if (src !== null) {
      this.previewDone.add(src.itemId);
    }
  }

  // MARK: - 加载

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

  private syncFromStore(): void {
    const store = LibraryHomeStore.shared;
    const prefs = LibraryHomePrefs.shared;
    this.libraries = store.libraries;
    this.failed = store.failed;
    this.upNext = store.upNext ?? [];
    const favorites = store.favorites;
    this.favoritesItems = favorites !== null ? favorites.items : [];
    this.favoritesTotal = favorites !== null ? favorites.total : 0;
    const rated = store.rated;
    this.ratedItems = rated !== null ? rated.items : [];
    this.ratedTotal = rated !== null ? rated.total : 0;
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
    if (row.kind instanceof RatedKind) {
      for (const item of this.ratedItems) {
        const card: TvShelfCard = TvShelfCard.fromItem(item, origin, false);
        const rawKey: string = `rated_${item.media_item_id}`;
        const ratedCard: TvShelfCard = new TvShelfCard(rawKey, card.kind, card.title);
        ratedCard.imageUrl = card.imageUrl;
        ratedCard.subtitle = card.subtitle;
        ratedCard.caption = card.caption;
        const stars: string = formatUserStars(item.user_rating ?? 0);
        if (stars.length > 0) {
          ratedCard.badge = `★ ${stars}`;
        }
        out.push(ratedCard);
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

  // MARK: - 大图区

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
    const rated: LibraryItemView | null = this.findRated(key);
    if (rated !== null) {
      return TvStageSource.fromItem(rated.media_item_id, rated.library_id ?? null, rated.title,
        rated.backdrop_url ?? rated.poster_url ?? null, rated.poster_url ?? null, rated.year ?? null,
        rated.user_rating ?? null);
    }
    const item: LibraryItemView | null = this.findItem(key);
    if (item !== null) {
      return TvStageSource.fromItem(item.media_item_id, item.library_id ?? null, item.title,
        item.backdrop_url ?? item.poster_url ?? null, item.poster_url ?? null, item.year ?? null);
    }
    return null;
  }

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
          this.resume(item, null);
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

  // MARK: - 行交互与快捷菜单

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

  private cardFocusChanged(row: HomeRow, card: TvShelfCard, active: boolean): void {
    this.wakeFromYield();
    if (active && (row.kind instanceof UpNextKind || row.kind instanceof FavoritesKind
      || row.kind instanceof RatedKind || row.kind instanceof LibraryRowKind
      || row.kind instanceof CollectionRowKind)) {
      this.focus.focusCard(card.key);
    }
  }

  private resume(item: UpNextItemView, startMsOverride: number | null): void {
    this.focus.clearPreview();
    const isEpisode: boolean = item.kind === 'tv';
    const request: TvPlayRequest = new TvPlayRequest(
      item.library_id,
      item.media_item_id,
      isEpisode ? item.season_number : null,
      isEpisode ? item.episode_number : null,
      null,
      startMsOverride,
      item.title,
      isEpisode ? TvFormat.episodeLine(item.season_number, item.episode_number, item.episode_title ?? null) : null,
      isEpisode
    );
    TvPlayback.begin(request);
    TvUiState.shared.openPlayer(request);
  }

  private openUpNextMenu(item: UpNextItemView): void {
    this.focus.clearPreview();
    this.menuUpNext = item;
    setTimeout((): void => {
      TvFocus.request(this.getUIContext(), 'tv_upnext_menu_play');
    }, 80);
  }

  private closeUpNextMenu(): void {
    this.menuUpNext = null;
    setTimeout((): void => {
      TvFocus.request(this.getUIContext(), 'tv_tab_anchor');
    }, 60);
  }

  private async markUpNextPlayed(item: UpNextItemView): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const isTv: boolean = item.kind === 'tv';
    const body: PlaybackMarksRequest = {
      media_item_id: item.media_item_id,
      season_number: isTv ? item.season_number : null,
      episode_number: isTv ? item.episode_number : null,
      played: true
    };
    this.closeUpNextMenu();
    try {
      await api.playbackMarksSet(body);
      await this.reload();
    } catch (_err) {
    }
  }

  private activateCard(row: HomeRow, card: TvShelfCard): void {
    if (card.kind === 'landscape') {
      const item: UpNextItemView | null = this.findUpNext(card.key);
      if (item !== null) {
        this.resume(item, null);
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
        TvUiState.shared.pushRoute(new TvRowWallRoute(`genre:${card.mediaKind}:${genre.value}`, genre.label));
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

  private canSeeAll(row: HomeRow): boolean {
    return row.kind instanceof FavoritesKind || row.kind instanceof RatedKind
      || row.kind instanceof LibraryRowKind || row.kind instanceof CollectionRowKind;
  }

  private seeAllTotal(row: HomeRow): number | null {
    if (row.kind instanceof FavoritesKind) {
      return this.favoritesTotal;
    }
    if (row.kind instanceof RatedKind) {
      return this.ratedTotal;
    }
    if (row.kind instanceof LibraryRowKind) {
      return row.kind.seeAllTotal();
    }
    if (row.kind instanceof CollectionRowKind) {
      return row.kind.collection.item_count;
    }
    return null;
  }

  private openSeeAll(row: HomeRow): void {
    if (row.kind instanceof FavoritesKind) {
      const kind = row.kind;
      TvUiState.shared.pushRoute(new TvRowWallRoute(`favorites:${kind.sort}:${kind.reversed}`, row.title()));
      return;
    }
    if (row.kind instanceof RatedKind) {
      TvUiState.shared.pushRoute(new TvRowWallRoute('rated', row.title()));
      return;
    }
    if (row.kind instanceof LibraryRowKind || row.kind instanceof CollectionRowKind) {
      TvUiState.shared.pushRoute(new TvRowWallRoute(LibraryHomeStore.fetchKey(row), row.title()));
    }
  }

  // MARK: - 按卡片 key 回找数据

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

  private findRated(key: string): LibraryItemView | null {
    for (const item of this.ratedItems) {
      if (`rated_${item.media_item_id}` === key) {
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

  private detailLibraryId(row: HomeRow, card: TvShelfCard): number | null {
    const favorite: FavoriteItemView | null = this.findFavorite(card.key);
    if (favorite !== null) {
      return favorite.library_id;
    }
    const rated: LibraryItemView | null = this.findRated(card.key);
    if (rated !== null && rated.library_id !== null && rated.library_id !== undefined) {
      return rated.library_id;
    }
    const item: LibraryItemView | null = this.findItem(card.key);
    if (item !== null && item.library_id !== null && item.library_id !== undefined) {
      return item.library_id;
    }
    if (row.kind instanceof LibraryRowKind) {
      return row.kind.library.id;
    }
    if (row.kind instanceof CollectionRowKind) {
      return row.kind.collection.library_id ?? null;
    }
    return null;
  }

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
        previewEndMs: this.previewEndMs,
        onPreviewEnded: (): void => {
          this.onPreviewEnded();
        },
        onPreviewFailed: (): void => {
          this.onPreviewFailed();
        }
      })
      this.Body()
      if (this.menuUpNext !== null) {
        this.UpNextMenuModal(this.menuUpNext as UpNextItemView)
      }
    }
    .width('100%')
    .height('100%')
    .onKeyEvent((event: KeyEvent): boolean => {
      if (event.type === KeyType.Down) {
        this.wakeFromYield();
        if (event.keyCode === KeyCode.KEYCODE_MENU && this.menuUpNext === null) {
          const settled: string | null = this.focus.settledKey;
          const target: UpNextItemView | null = settled !== null ? this.findUpNext(settled) : null;
          if (target !== null) {
            this.openUpNextMenu(target);
            return true;
          }
        }
      }
      return false;
    })
    .onMouse((): void => {
      this.wakeFromYield();
    })
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
            Column().height(30)
          }
          Column({ space: TvMetrics.rowGap }) {
            ForEach(this.rows, (row: HomeRow) => {
              this.RowView(row)
            }, (row: HomeRow) => row.id)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .opacity(this.idleYield ? 0.18 : 1.0)
          Column().height(TvMetrics.edge)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .fadingEdge(false)
      .onWillScroll((): void => {
        this.wakeFromYield();
      })
    }
  }

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
    .onVisibleAreaChange([0.0, 0.3], (_isVisible: boolean, currentRatio: number): void => {
      if (currentRatio < 0.3 && this.previewUrl !== '') {
        this.focus.clearPreview();
      }
    })
  }

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

  @Builder
  private UpNextMenuModal(item: UpNextItemView) {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.68)')
        .onClick((): void => {
          this.closeUpNextMenu();
        })

      Column({ space: 18 }) {
        Text(item.title)
          .fontSize(TvType.playerTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .maxLines(1)
        if (item.kind === 'tv') {
          Text(TvFormat.episodeLine(item.season_number, item.episode_number, item.episode_title ?? null))
            .fontSize(TvType.footnote)
            .fontColor(TvColors.textMuted)
            .maxLines(1)
        }
        Column({ space: 12 }) {
          TvPillButton({
            label: item.position_ms > 0 ? '继续播放' : '播放',
            prominent: true,
            icon: $r('sys.symbol.play_fill'),
            focusKey: 'tv_upnext_menu_play',
            defaultFocused: true,
            onActivate: (): void => {
              this.closeUpNextMenu();
              this.resume(item, null);
            }
          })
          if (item.position_ms > 0) {
            TvPillButton({
              label: '从头播放',
              prominent: false,
              icon: $r('sys.symbol.backward_end_fill'),
              onActivate: (): void => {
                this.closeUpNextMenu();
                this.resume(item, 0);
              }
            })
          }
          TvPillButton({
            label: '查看详情',
            prominent: false,
            icon: $r('sys.symbol.info_circle'),
            onActivate: (): void => {
              this.closeUpNextMenu();
              TvUiState.shared.pushRoute(new TvDetailRoute(item.library_id, item.media_item_id));
            }
          })
          TvPillButton({
            label: '标为已看完',
            prominent: false,
            icon: $r('sys.symbol.checkmark_circle'),
            onActivate: (): void => {
              this.markUpNextPlayed(item);
            }
          })
          TvPillButton({
            label: '取消',
            prominent: false,
            onActivate: (): void => {
              this.closeUpNextMenu();
            }
          })
        }
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 6 })
      }
      .width(460)
      .padding({ left: 36, right: 36, top: 32, bottom: 32 })
      .borderRadius(24)
      .backgroundColor('rgba(16, 18, 26, 0.96)')
      .border({ width: 1, color: TvColors.lineStrong })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
