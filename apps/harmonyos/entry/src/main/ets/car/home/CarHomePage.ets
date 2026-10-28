/**
 * 车机首页（US2）：继续观看大卡置顶（一键续播）+ 按网页偏好渲染的横滑内容行。
 * 对应参考端 TV 端 tv/home/TvHomePage.ets 的触屏裁剪版：
 * - 大卡区：继续观看第一条铺满内容宽（CarContinueCard，宽屏左信息右内容），点一下直接续播；
 *   「接下来继续」行展示第 2 条起的其余条目（第 1 条由大卡承接，不重复）。
 * - 内容行：HomeRows.build 按网页端首页偏好合并（偏好空/失败走默认行集），
 *   行数据复用 common/LibraryHomeStore（快照秒开 + 并发拉取 + 60s 轮询）；
 *   「按类型找」行的类型格子走 uiLibraryKindGenres 单独取。
 * - 收藏行以横版大卡展示（spec AC2），点击进详情。
 * - 行点击路由进 CarUiState 路由栈：详情 / 库墙 / 合集 / 类型墙（「查看全部」sourceKey
 *   与 LibraryHomeStore.fetchKey 同构，行墙 T014 按它取数）。
 * - 无任何内容时显示引导态（去媒体库浏览）。
 */
import { AppModel } from '../../common/AppModel';
import { MovieClawApi } from '../../api/Endpoints';
import {
  CollectionView,
  FavoriteItemView,
  LibraryItemView,
  LibraryKindGenreView,
  LibraryView,
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
  UpNextKind
} from '../../library/HomeRows';
import { LibraryHomePrefs, LibraryHomeStore } from '../../library/LibraryHomeStore';
import { ImageUrls } from '../../common/ImageUrls';
import {
  CarCollectionRoute,
  CarDetailRoute,
  CarPlayRequest,
  CarRowWallRoute,
  CarTab,
  CarUiState,
  CarWallRoute
} from '../model/CarUiState';
import { CarContinueCard, CarFormat, CarStateView } from '../components/CarCards';
import { CarRowCard, CarShelf } from '../components/CarRows';
import { CarPlayback } from '../player/CarAvPlayerEngine';
import { CarColors } from '../theme/CarTheme';
import { CarMetrics } from '../theme/CarTheme';

@ComponentV2
export struct CarHomePage {
  private pollId: number = -1;

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
  @Local rowCards: Map<string, CarRowCard[]> = new Map<string, CarRowCard[]>();

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
  }

  // MARK: - 加载（快照先上屏，网络完成二次刷新；60s 轮询同 TV 端口径）

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
    this.pinnedCollections = CarHomePage.pinnedCollections(rows);
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

  /** 每行数据 → CarRowCard */
  private rebuildCards(): void {
    const origin: string = AppModel.origin();
    const cards: Map<string, CarRowCard[]> = new Map<string, CarRowCard[]>();
    for (const row of this.rows) {
      cards.set(row.id, this.cardsForRow(row, origin));
    }
    this.rowCards = cards;
  }

  private cardsForRow(row: HomeRow, origin: string): CarRowCard[] {
    const out: CarRowCard[] = [];
    if (row.kind instanceof UpNextKind) {
      // 第 1 条由置顶大卡承接，行里展示其余条目
      for (let i = 1; i < this.upNext.length; i++) {
        out.push(CarRowCard.fromUpNext(this.upNext[i], origin));
      }
      return out;
    }
    if (row.kind instanceof FavoritesKind) {
      for (const item of this.favoritesItems) {
        out.push(CarRowCard.fromFavorite(item, origin));
      }
      return out;
    }
    if (row.kind instanceof LibrariesKind) {
      const libraries: LibraryView[] = this.libraries ?? [];
      for (const library of libraries) {
        if (library.viewer_access) {
          out.push(CarRowCard.fromLibrary(library, origin));
        }
      }
      for (const collection of this.pinnedCollections) {
        out.push(CarRowCard.fromCollection(collection, origin));
      }
      return out;
    }
    if (row.kind instanceof GenresKind) {
      const kind = row.kind;
      const genres: LibraryKindGenreView[] = this.genresByKind.get(kind.kind) ?? [];
      for (const genre of genres) {
        out.push(CarRowCard.fromGenre(genre, kind.kind, origin));
      }
      return out;
    }
    if (row.kind instanceof LibraryRowKind || row.kind instanceof CollectionRowKind) {
      const items: LibraryItemView[] = this.rowItems.get(LibraryHomeStore.fetchKey(row)) ?? [];
      for (const item of items) {
        out.push(CarRowCard.fromItem(item, origin));
      }
    }
    return out;
  }

  // MARK: - 置顶大卡（继续观看第一条）

  private heroItem(): UpNextItemView | null {
    return this.upNext.length > 0 ? this.upNext[0] : null;
  }

  private heroImageUrl(): string {
    const item: UpNextItemView | null = this.heroItem();
    if (item === null) {
      return '';
    }
    const isEpisode: boolean = item.kind === 'tv';
    const raw: string | null = isEpisode
      ? (item.episode_still_url ?? item.backdrop_url ?? item.poster_url ?? null)
      : (item.backdrop_url ?? item.poster_url ?? null);
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), raw, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1920`;
  }

  /** 事实行「2023 · 古装 · 喜剧」，电影再加片长；类型只取前两个 */
  private heroMetaLine(): string | null {
    const item: UpNextItemView | null = this.heroItem();
    if (item === null) {
      return null;
    }
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
        parts.push(CarFormat.duration(durationMs / 60000));
      }
    }
    return parts.length > 0 ? parts.join(' · ') : null;
  }

  private heroProgress(): number {
    const item: UpNextItemView | null = this.heroItem();
    if (item === null) {
      return 0;
    }
    return (item.progress_percent ?? 0) / 100;
  }

  // MARK: - 行交互

  private cardsOf(row: HomeRow): CarRowCard[] {
    return this.rowCards.get(row.id) ?? [];
  }

  private hasContent(): boolean {
    if (this.heroItem() !== null) {
      return true;
    }
    for (const row of this.rows) {
      if (this.cardsOf(row).length > 0) {
        return true;
      }
    }
    return false;
  }

  /** mini 条封面：剧集优先分集剧照，电影取背景图 */
  private coverOf(item: UpNextItemView): string {
    const isEpisode: boolean = item.kind === 'tv';
    const raw: string | null = isEpisode
      ? (item.episode_still_url ?? item.backdrop_url ?? item.poster_url ?? null)
      : (item.backdrop_url ?? item.poster_url ?? null);
    return ImageUrls.resolve(AppModel.origin(), raw, null) ?? '';
  }

  /** 按确认直接续播（续播点由服务端按这一集 / 这部片的进度给） */
  private resume(item: UpNextItemView): void {
    const isEpisode: boolean = item.kind === 'tv';
    const request: CarPlayRequest = new CarPlayRequest(
      item.library_id,
      item.media_item_id,
      isEpisode ? item.season_number : null,
      isEpisode ? item.episode_number : null,
      null,
      null,
      item.title,
      isEpisode ? CarFormat.episodeLine(item.season_number, item.episode_number, item.episode_title ?? null) : null,
      this.coverOf(item),
      isEpisode);
    // playback-first：按下播放先预建会话（不等播放器视图挂载）
    CarPlayback.begin(request);
    CarUiState.shared.openPlayer(request);
  }

  private activateCard(row: HomeRow, card: CarRowCard): void {
    const ui: CarUiState = CarUiState.shared;
    if (row.kind instanceof UpNextKind) {
      const item: UpNextItemView | null = this.findUpNext(card.key);
      if (item !== null) {
        this.resume(item);
      }
      return;
    }
    if (row.kind instanceof FavoritesKind) {
      const favorite: FavoriteItemView | null = this.findFavorite(card.key);
      if (favorite !== null) {
        ui.pushRoute(new CarDetailRoute(favorite.library_id, favorite.media_item_id));
      }
      return;
    }
    if (card.kind === 'library') {
      if (card.collection) {
        const collection: CollectionView | null = this.findCollection(card.key);
        if (collection !== null) {
          ui.pushRoute(new CarCollectionRoute(collection.id, collection.name));
        }
      } else {
        const library: LibraryView | null = this.findLibrary(card.key);
        if (library !== null) {
          ui.pushRoute(new CarWallRoute(library.id, library.name, null));
        }
      }
      return;
    }
    if (card.kind === 'genre') {
      const genre: LibraryKindGenreView | null = this.findGenre(card.key);
      if (genre !== null) {
        ui.pushRoute(new CarRowWallRoute(
          `genre:${card.mediaKind}:${genre.value}`, genre.label));
      }
      return;
    }
    if (card.kind === 'poster') {
      const libraryId: number | null = this.detailLibraryId(row, card);
      if (libraryId !== null) {
        ui.pushRoute(new CarDetailRoute(libraryId, this.itemIdOf(card.key)));
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
      CarUiState.shared.pushRoute(new CarRowWallRoute(
        `favorites:${kind.sort}:${kind.reversed}`, row.title()));
      return;
    }
    if (row.kind instanceof LibraryRowKind || row.kind instanceof CollectionRowKind) {
      CarUiState.shared.pushRoute(new CarRowWallRoute(LibraryHomeStore.fetchKey(row), row.title()));
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
  private detailLibraryId(row: HomeRow, card: CarRowCard): number | null {
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

  /** 卡片 key（item_34）里的条目 id */
  private itemIdOf(key: string): number {
    const parts: string[] = key.split('_');
    return Number(parts[parts.length - 1]);
  }

  // MARK: - 布局

  build() {
    if (this.libraries === null) {
      if (this.failed) {
        CarStateView({
          symbol: $r('sys.symbol.wifi'),
          title: '连不上服务器',
          message: '首页加载失败，请检查网络后重试。',
          actionTitle: '重试',
          onAction: (): void => {
            this.reload();
          }
        })
      } else {
        Column() {
          LoadingProgress()
            .width(44)
            .height(44)
            .color(CarColors.textMuted)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    } else if (!this.hasContent()) {
      CarStateView({
        symbol: $r('sys.symbol.film'),
        title: '媒体库里还没有内容',
        message: '在网页或手机上添加媒体库并扫描后，影片会出现在这里。',
        actionTitle: '去媒体库',
        onAction: (): void => {
          CarUiState.shared.selectTab(CarTab.library);
        }
      })
    } else {
      Scroll() {
        Column({ space: CarMetrics.rowGap }) {
          this.HeroSection()
          ForEach(this.rows, (row: HomeRow) => {
            this.RowView(row)
          }, (row: HomeRow) => row.id)
          // 底部留白：给 mini 播控条（US6）与滚动收尾留余量
          Column()
            .height(120)
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

  /** 置顶大卡：继续观看第一条（没有续播记录时留一段呼吸空间） */
  @Builder
  private HeroSection() {
    if (this.heroItem() !== null) {
      Column() {
        CarContinueCard({
          title: this.heroItem()?.title ?? '',
          headline: this.heroItem()?.kind === 'tv'
            ? CarFormat.episodeLine(this.heroItem()?.season_number ?? 0,
            this.heroItem()?.episode_number ?? 0, this.heroItem()?.episode_title ?? null)
            : null,
          metaLine: this.heroMetaLine(),
          imageUrl: this.heroImageUrl(),
          progress: this.heroProgress(),
          badge: this.heroItem()?.advanced === true ? '下一集' : null,
          remainingText: this.heroRemainingText(),
          onActivate: (): void => {
            const item: UpNextItemView | null = this.heroItem();
            if (item !== null) {
              this.resume(item);
            }
          }
        })
      }
      .width('100%')
      .padding({ left: CarMetrics.edge, right: CarMetrics.edge })
    } else {
      Column()
        .height(24)
    }
  }

  private heroRemainingText(): string | null {
    const item: UpNextItemView | null = this.heroItem();
    if (item === null || item.position_ms <= 0) {
      return null;
    }
    return CarFormat.remaining(item.position_ms, item.duration_ms ?? null);
  }

  /** 首页的一行（「接下来继续」剩余项/ 收藏大卡 / 媒体库 / 类型 / 库行 / 合集行） */
  @Builder
  private RowView(row: HomeRow) {
    if (this.cardsOf(row).length > 0) {
      CarShelf({
        title: row.title(),
        cards: this.cardsOf(row),
        seeAll: this.canSeeAll(row),
        seeAllTotal: this.seeAllTotal(row),
        onActivate: (card: CarRowCard): void => {
          this.activateCard(row, card);
        },
        onSeeAll: (): void => {
          this.openSeeAll(row);
        }
      })
    }
  }
}
