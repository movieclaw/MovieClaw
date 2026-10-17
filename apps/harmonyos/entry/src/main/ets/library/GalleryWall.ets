import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { NavStacks } from '../common/ShareLinks';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { MovieClawApi } from '../api/Endpoints';
import { ApiError } from '../api/ApiClient';
import { LibraryGalleryGroupView, LibraryGalleryImageView, PlaybackMarksView } from '../api/Models';
import { PlayerParams } from '../player/PlayerPage';
import { ItemRouteParams } from './LibraryItemDetailPage';

/**
 * 图床浏览模式的瀑布流墙（对应 iOS `LibraryGalleryWall` / Web `components/video-gallery.tsx`）。
 *
 * 把每部作品的海报、剧照、分集剧照与章节场景图铺成一面瀑布流：
 * - **最短列放置**（Pinterest 原版算法）：比例在渲染前已知（扫描入账时读的原图尺寸），
 *   每张放进当前最短的一列，不等图片加载、零抖动；极端比例夹到 [0.5, 2]；
 * - **按作品分组**（默认）：一部作品一段标题（可点进详情）+ 一面墙；关掉分组后
 *   整份的图混成一条瀑布流，纯看图最沉浸；
 * - 瓦片上只有「已收藏」那颗心一个常驻角标（状态不是分类，不牵走视线）；
 * - 点图开灯箱（全屏翻图），底栏是「播放 / 收藏 / 详情」：章节图从那一帧起播、
 *   分集剧照播那一集；心收藏的是整部作品，与详情页那颗是同一颗；
 * - 按作品分页（一页 24 部），滑近底部自动要下一页；灯箱翻到末尾也会要。
 *
 * 三个来源（单库 / 合集 / 收藏）共用：数据经 `fetch` 闭包注入。
 * 「回到上次位置」：宿主改 `startOffset` 就把窗口换成从那部作品开始的一页；
 * 滚动时经 `onFirstVisible` 回报视口里第一部作品在整份排序里的位置（按作品计）。
 *
 * **本轮暂缓**：灯箱双指缩放（先 Contain 看全图）、收藏角标在分组关掉时的精细刷新
 * （不分段时心变动会整面重铺，代价可接受）。
 */

/** 瀑布流密度（iOS `GalleryDensity` / Web PhotoWallDensity）：目标列宽 + 最少列数 + 间距 */
export class GalleryDensity {
  readonly name: string;
  readonly label: string;
  /** 目标列宽：列数 = floor((容器宽 + 间距) / (目标列宽 + 间距)) */
  readonly column: number;
  /** 最少列数：只按列宽算列数在手机宽度上三档会落到同样的列数，看不出变化 */
  readonly minColumns: number;
  readonly gap: number;

  constructor(name: string, label: string, column: number, minColumns: number, gap: number) {
    this.name = name;
    this.label = label;
    this.column = column;
    this.minColumns = minColumns;
    this.gap = gap;
  }

  static readonly compact: GalleryDensity = new GalleryDensity('compact', '紧凑', 150, 3, 3);
  static readonly standard: GalleryDensity = new GalleryDensity('standard', '标准', 230, 2, 6);
  static readonly loose: GalleryDensity = new GalleryDensity('loose', '宽松', 340, 1, 10);
  static readonly all: GalleryDensity[] =
    [GalleryDensity.compact, GalleryDensity.standard, GalleryDensity.loose];

  static of(name: string): GalleryDensity {
    for (const density of GalleryDensity.all) {
      if (density.name === name) {
        return density;
      }
    }
    return GalleryDensity.standard;
  }

  columns(width: number): number {
    return Math.max(this.minColumns, Math.floor((width + this.gap) / (this.column + this.gap)));
  }
}

/** 看图的浏览偏好（只是本机的便利设置；先记在进程里，同 iOS `GalleryPrefs`） */
export class GalleryPrefs {
  /** 跨库页面（「我的收藏」）的图床开关 */
  static galleryMode: boolean = false;
  static grouped: boolean = true;
  static densityName: string = 'standard';
  /** 单库各自的图床开关（key = libraryId，未设置 = 海报墙；单库与库内合集共用，同 iOS libraryModes） */
  private static libraryModes: Map<number, boolean> = new Map<number, boolean>();

  static galleryModeFor(libraryId: number): boolean {
    return GalleryPrefs.libraryModes.get(libraryId) === true;
  }

  static setGalleryModeFor(libraryId: number, enabled: boolean): void {
    GalleryPrefs.libraryModes.set(libraryId, enabled);
  }
}

/** 铺平后的一张图（墙与灯箱共用同一列表、同一下标） */
class GalleryTile {
  readonly flatIndex: number;
  readonly groupIndex: number;
  readonly imageIndex: number;
  /** 墙上瓦片地址（gallery-tile 派生档） */
  readonly url: string;
  /** 灯箱大图地址（原图直连） */
  readonly screenUrl: string;
  /** 夹紧后的宽高比 */
  readonly aspect: number;
  x: number = 0;
  y: number = 0;
  width: number = 0;
  height: number = 0;

  constructor(flatIndex: number, groupIndex: number, imageIndex: number,
    url: string, screenUrl: string, aspect: number) {
    this.flatIndex = flatIndex;
    this.groupIndex = groupIndex;
    this.imageIndex = imageIndex;
    this.url = url;
    this.screenUrl = screenUrl;
    this.aspect = aspect;
  }
}

/** 瓦片在一条带子里的落位（跨带的瓦片两条里各画一次，拼起来是完整的一张） */
class GalleryBandTile {
  readonly tile: GalleryTile;
  readonly localY: number;

  constructor(tile: GalleryTile, localY: number) {
    this.tile = tile;
    this.localY = localY;
  }
}

/** 墙上的一段：组标题、一条定高的带子，或加载更多的转圈脚 */
class GallerySection {
  readonly key: string;
  /** 组标题对应的分组下标；-1 = 不是标题段 */
  readonly headerGroupIndex: number;
  readonly height: number;
  readonly tiles: GalleryBandTile[];
  readonly isFooter: boolean;

  constructor(key: string, headerGroupIndex: number, height: number,
    tiles: GalleryBandTile[], isFooter: boolean) {
    this.key = key;
    this.headerGroupIndex = headerGroupIndex;
    this.height = height;
    this.tiles = tiles;
    this.isFooter = isFooter;
  }
}

/** 瀑布流排版（纯函数，比例渲染前已知、零抖动） */
class GalleryLayout {
  /** 带子高度：List 的一个 ListItem 一条，LazyForEach 才能按需建 */
  static readonly BAND_HEIGHT: number = 420;
  /** 夹紧比例：全景图与长截图不能撑爆一列 */
  static readonly MIN_ASPECT: number = 0.5;
  static readonly MAX_ASPECT: number = 2;

  static clampAspect(raw: number): number {
    return Math.min(GalleryLayout.MAX_ASPECT,
      Math.max(GalleryLayout.MIN_ASPECT, raw > 0 ? raw : 1));
  }

  /** 最短列放置；张数少于列数时退化成一行等高（同 Web layoutSparseRow）。返回墙高。 */
  static layout(tiles: GalleryTile[], width: number, density: GalleryDensity): number {
    if (tiles.length === 0 || width <= 0) {
      return 0;
    }
    const columns: number = density.columns(width);
    if (tiles.length < columns) {
      return GalleryLayout.sparseRow(tiles, width, density);
    }
    const columnWidth: number = (width - density.gap * (columns - 1)) / columns;
    const heights: number[] = [];
    for (let i: number = 0; i < columns; i++) {
      heights.push(0);
    }
    for (const tile of tiles) {
      const height: number = columnWidth / tile.aspect;
      let target: number = 0;
      for (let i: number = 1; i < columns; i++) {
        if (heights[i] < heights[target] - 0.5) {
          target = i;
        }
      }
      tile.x = target * (columnWidth + density.gap);
      tile.y = heights[target];
      tile.width = columnWidth;
      tile.height = height;
      heights[target] += height + density.gap;
    }
    let maxHeight: number = heights[0];
    for (let i: number = 1; i < columns; i++) {
      if (heights[i] > maxHeight) {
        maxHeight = heights[i];
      }
    }
    return maxHeight - density.gap;
  }

  /** 稀疏段：一行等高，高度取「填满整行所需」与「目标列宽 × 1.2」的较小者 */
  private static sparseRow(tiles: GalleryTile[], width: number, density: GalleryDensity): number {
    let sum: number = 0;
    for (const tile of tiles) {
      sum += tile.aspect;
    }
    const fit: number = (width - density.gap * (tiles.length - 1)) / Math.max(sum, 0.01);
    const height: number = Math.min(density.column * 1.2, fit);
    let x: number = 0;
    for (const tile of tiles) {
      tile.width = tile.aspect * height;
      tile.height = height;
      tile.x = x;
      tile.y = 0;
      x += tile.width + density.gap;
    }
    return height;
  }

  /** 把一面墙横切成定高带子；跨带边界的瓦片两条里各出现一次、各裁掉出界的部分 */
  static pushBands(out: GallerySection[], tiles: GalleryTile[], height: number, keyPrefix: string): void {
    if (height <= 0 || tiles.length === 0) {
      return;
    }
    const bandHeight: number = GalleryLayout.BAND_HEIGHT;
    const count: number = Math.max(1, Math.ceil(height / bandHeight));
    const buckets: GalleryBandTile[][] = [];
    for (let i: number = 0; i < count; i++) {
      buckets.push([]);
    }
    for (const tile of tiles) {
      const first: number = Math.min(count - 1, Math.floor(tile.y / bandHeight));
      const last: number = Math.min(count - 1,
        Math.floor(Math.max(tile.y, tile.y + tile.height - 0.5) / bandHeight));
      for (let band: number = first; band <= last; band++) {
        buckets[band].push(new GalleryBandTile(tile, tile.y - band * bandHeight));
      }
    }
    for (let band: number = 0; band < count; band++) {
      out.push(new GallerySection(`${keyPrefix}-${band}`, -1,
        Math.min(bandHeight, height - band * bandHeight), buckets[band], false));
    }
  }
}

/** 墙的数据源（List + LazyForEach 按段懒建） */
class GallerySectionSource implements IDataSource {
  private sections: GallerySection[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.sections.length;
  }

  getData(index: number): GallerySection {
    return this.sections[index];
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

  reload(sections: GallerySection[]): void {
    this.sections = sections;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  changeAt(index: number): void {
    for (const listener of this.listeners) {
      listener.onDataChange(index);
    }
  }
}

/** 灯箱的数据源（Swiper + LazyForEach 只建当前页附近的页） */
class GalleryTileSource implements IDataSource {
  private tiles: GalleryTile[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.tiles.length;
  }

  getData(index: number): GalleryTile {
    return this.tiles[index];
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

  reload(tiles: GalleryTile[]): void {
    this.tiles = tiles;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@ComponentV2
export struct GalleryWall {
  /** 取数：一页作品分组（单库 / 合集 / 收藏三个来源都经它注入） */
  @Require @Param fetch: (offset: number, limit: number) => Promise<LibraryGalleryGroupView[]>;
  /** 取数口径变化（换排序）→ 从头重载 */
  @Param reloadKey: string = '';
  /** 窗口起点（「回到上次位置」跳过来后不为 0） */
  @Param startOffset: number = 0;
  /** 是否按作品分组（关掉是整份一条瀑布流） */
  @Param grouped: boolean = true;
  @Param densityName: string = 'standard';
  /** 点作品段标题（一般 push 到条目详情） */
  @Param onOpenItem: (group: LibraryGalleryGroupView) => void =
    (group: LibraryGalleryGroupView): void => {
    };
  /** 视口里第一部作品的位置（整份排序里的 offset） */
  @Param onFirstVisible: (offset: number) => void = (offset: number): void => {
  };

  /** 一页的作品数：一部作品十来张图，24 部约一屏半（同 Web GALLERY_PAGE_SIZE） */
  private static readonly PAGE_SIZE: number = 24;

  private groups: LibraryGalleryGroupView[] = [];
  private flatTiles: GalleryTile[] = [];
  private sections: GallerySection[] = [];
  private sectionSource: GallerySectionSource = new GallerySectionSource();
  private slideSource: GalleryTileSource = new GalleryTileSource();
  /** 窗口在整份排序里的起点 */
  private start: number = 0;
  /** 服务端口径的已取条数（含被去重掉的空组）：下一页的 offset */
  private loaded: number = 0;
  private hasMore: boolean = false;
  private loadingMore: boolean = false;
  /** 重载代次：换口径后晚回来的旧页直接丢弃 */
  private generation: number = 0;
  /** 灯箱收起后再做的跳转（播放 / 进详情）：必须等全屏层收起，否则弹不出来 */
  private pendingNav: (() => void) | null = null;

  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private wallWidth: number = 0;
  @Local private lightboxOpen: boolean = false;
  @Local private lightboxCurrent: number = 0;
  /** 本会话里翻过的收藏（先翻本地再落库；key = media_item_id） */
  @Local private favorites: Map<number, boolean> = new Map<number, boolean>();

  aboutToAppear(): void {
    this.reload(this.startOffset);
  }

  @Monitor('reloadKey')
  onReloadKeyChange(): void {
    this.reload(this.startOffset);
  }

  @Monitor('startOffset')
  onStartOffsetChange(): void {
    this.reload(this.startOffset);
  }

  @Monitor('grouped', 'densityName')
  onLayoutPrefChange(): void {
    this.relayout();
  }

  // MARK: 取数

  private async reload(from: number): Promise<void> {
    this.generation++;
    const current: number = this.generation;
    // 换窗口起点：旧窗口作废，先显示转圈
    this.loading = this.groups.length === 0 || from !== this.start;
    this.failed = false;
    try {
      const page: LibraryGalleryGroupView[] = await this.fetch(from, GalleryWall.PAGE_SIZE);
      if (current !== this.generation) {
        return;
      }
      this.groups = GalleryWall.dedupe(page);
      this.start = from;
      this.loaded = from + page.length;
      this.hasMore = page.length >= GalleryWall.PAGE_SIZE;
      this.relayout();
      this.loading = false;
    } catch (error) {
      if (current !== this.generation) {
        return;
      }
      if (this.groups.length === 0) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
      this.loading = false;
      this.hasMore = false;
    }
  }

  /** 追加下一页。某一页全是空组时接着要，免得墙停在原地不动（同 Web） */
  private async loadMore(): Promise<void> {
    if (!this.hasMore || this.loadingMore || this.loading || this.failed) {
      return;
    }
    this.loadingMore = true;
    const current: number = this.generation;
    try {
      let attempts: number = 0;
      while (this.hasMore && attempts < 5) {
        attempts++;
        const page: LibraryGalleryGroupView[] = await this.fetch(this.loaded, GalleryWall.PAGE_SIZE);
        if (current !== this.generation) {
          return;
        }
        this.loaded += page.length;
        this.hasMore = page.length >= GalleryWall.PAGE_SIZE;
        const before: number = this.flatTiles.length;
        this.groups = GalleryWall.dedupe(this.groups.concat(page));
        this.relayout();
        if (this.flatTiles.length > before) {
          return;
        }
      }
    } catch (error) {
      this.hasMore = false;
    } finally {
      this.loadingMore = false;
    }
  }

  /** 上墙前的统一口径：没图的作品不占位，同一部作品只留最前面那一组 */
  private static dedupe(groups: LibraryGalleryGroupView[]): LibraryGalleryGroupView[] {
    const seen: Set<number> = new Set<number>();
    const out: LibraryGalleryGroupView[] = [];
    for (const group of groups) {
      if (group.images.length === 0 || seen.has(group.media_item_id)) {
        continue;
      }
      seen.add(group.media_item_id);
      out.push(group);
    }
    return out;
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 排版

  /** 铺平 → 排版 → 切带：墙与灯箱共用同一份铺平列表（同一下标） */
  private relayout(): void {
    const density: GalleryDensity = GalleryDensity.of(this.densityName);
    const width: number = this.wallWidth;
    const tiles: GalleryTile[] = [];
    for (let g: number = 0; g < this.groups.length; g++) {
      const images: LibraryGalleryImageView[] = this.groups[g].images;
      for (let i: number = 0; i < images.length; i++) {
        const image: LibraryGalleryImageView = images[i];
        tiles.push(new GalleryTile(tiles.length, g, i,
          ImageUrls.resolve(AppModel.origin(), image.url, ImageVariant.galleryTile) ?? '',
          ImageUrls.resolve(AppModel.origin(), image.url, null) ?? '',
          GalleryLayout.clampAspect(image.aspect)));
      }
    }
    const sections: GallerySection[] = [];
    if (this.grouped) {
      let base: number = 0;
      for (let g: number = 0; g < this.groups.length; g++) {
        const slice: GalleryTile[] = tiles.slice(base, base + this.groups[g].images.length);
        sections.push(new GallerySection(`h-${this.groups[g].media_item_id}`, g, 0, [], false));
        const height: number = GalleryLayout.layout(slice, width, density);
        GalleryLayout.pushBands(sections, slice, height, `b-${this.groups[g].media_item_id}`);
        base += slice.length;
      }
    } else {
      const height: number = GalleryLayout.layout(tiles, width, density);
      GalleryLayout.pushBands(sections, tiles, height, 'all');
    }
    if (this.hasMore) {
      sections.push(new GallerySection('footer', -1, 64, [], true));
    }
    this.flatTiles = tiles;
    this.sections = sections;
    this.sectionSource.reload(sections);
    this.slideSource.reload(tiles);
  }

  /** 一段里第一部作品的分组下标（onFirstVisible 的回报口径） */
  private firstGroupOf(section: GallerySection): number {
    if (section.headerGroupIndex >= 0) {
      return section.headerGroupIndex;
    }
    if (section.tiles.length > 0) {
      return section.tiles[0].tile.groupIndex;
    }
    return -1;
  }

  private groupTitle(groupIndex: number): string {
    const group: LibraryGalleryGroupView = this.groups[groupIndex];
    const year: number | null = group.year ?? null;
    return year !== null ? `${group.title} (${year})` : group.title;
  }

  /** 这部作品现在收没收：本会话翻过的优先，其次服务端口径 */
  private isFavorite(groupIndex: number): boolean {
    const override: boolean | undefined = this.favorites.get(this.groups[groupIndex].media_item_id);
    return override === undefined ? this.groups[groupIndex].is_favorite : override;
  }

  // MARK: 灯箱

  private currentTile(): GalleryTile | null {
    if (this.lightboxCurrent < 0 || this.lightboxCurrent >= this.flatTiles.length) {
      return null;
    }
    return this.flatTiles[this.lightboxCurrent];
  }

  private lightboxTitle(): string {
    const tile: GalleryTile | null = this.currentTile();
    if (tile === null) {
      return '';
    }
    const image: LibraryGalleryImageView = this.groups[tile.groupIndex].images[tile.imageIndex];
    return `${this.groupTitle(tile.groupIndex)} · ${image.label}`;
  }

  private currentPlayLabel(): string {
    const tile: GalleryTile | null = this.currentTile();
    if (tile === null) {
      return '播放';
    }
    const image: LibraryGalleryImageView = this.groups[tile.groupIndex].images[tile.imageIndex];
    return image.t_seconds !== null && image.t_seconds !== undefined ? '从此处播放' : '播放';
  }

  /** 灯箱收起后再做跳转（播放器 / 详情页弹不出来就得等全屏层收起） */
  private leaveLightbox(action: () => void): void {
    this.pendingNav = action;
    this.lightboxOpen = false;
  }

  private runPendingNav(): void {
    const nav: (() => void) | null = this.pendingNav;
    this.pendingNav = null;
    if (nav !== null) {
      nav();
    }
  }

  /** 章节图从那一帧起播，分集剧照播那一集，海报 / 剧照从头（或续播） */
  private playFromLightbox(): void {
    const tile: GalleryTile | null = this.currentTile();
    if (tile === null) {
      return;
    }
    const group: LibraryGalleryGroupView = this.groups[tile.groupIndex];
    const image: LibraryGalleryImageView = group.images[tile.imageIndex];
    const startSeconds: number = image.t_seconds ?? 0;
    const params: PlayerParams = new PlayerParams(group.media_item_id, 0,
      image.season ?? 0, image.episode ?? 0, Math.round(startSeconds * 1000));
    this.leaveLightbox((): void => {
      const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
      if (stack !== null) {
        stack.pushPathByName('player', params);
      }
    });
  }

  /** 收藏的是整部作品（与详情页那颗心同一落点），不是这张图或这一集 */
  private toggleCurrentFavorite(): void {
    const tile: GalleryTile | null = this.currentTile();
    if (tile === null) {
      return;
    }
    const group: LibraryGalleryGroupView = this.groups[tile.groupIndex];
    const next: boolean = !this.isFavorite(tile.groupIndex);
    this.favorites = new Map<number, boolean>(this.favorites)
      .set(group.media_item_id, next);
    this.refreshSectionsOfGroup(tile.groupIndex);
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    api.playbackMarksSet({ media_item_id: group.media_item_id, favorite: next })
      .then((marks: PlaybackMarksView): void => {
        this.favorites = new Map<number, boolean>(this.favorites)
          .set(group.media_item_id, marks.is_favorite);
        this.refreshSectionsOfGroup(tile.groupIndex);
      })
      .catch((): void => {
        // 落库失败：心翻回去（墙与灯箱同时）
        this.favorites = new Map<number, boolean>(this.favorites)
          .set(group.media_item_id, !next);
        this.refreshSectionsOfGroup(tile.groupIndex);
      });
  }

  /** 墙上那几段的瓦片重画（LazyForEach 的段不随父组件刷新，按段通知） */
  private refreshSectionsOfGroup(groupIndex: number): void {
    for (let i: number = 0; i < this.sections.length; i++) {
      const section: GallerySection = this.sections[i];
      if (section.headerGroupIndex === groupIndex) {
        this.sectionSource.changeAt(i);
        continue;
      }
      for (const bandTile of section.tiles) {
        if (bandTile.tile.groupIndex === groupIndex) {
          this.sectionSource.changeAt(i);
          break;
        }
      }
    }
  }

  /** 分集剧照 / 剧集章节图带季集号，详情页直接落到那一集；落点库取分组自带的 */
  private openDetailFromLightbox(): void {
    const tile: GalleryTile | null = this.currentTile();
    if (tile === null) {
      return;
    }
    const group: LibraryGalleryGroupView = this.groups[tile.groupIndex];
    const image: LibraryGalleryImageView = group.images[tile.imageIndex];
    let season: number | null = null;
    let episode: number | null = null;
    if (image.season !== null && image.season !== undefined
      && image.episode !== null && image.episode !== undefined) {
      season = image.season;
      episode = image.episode;
    }
    const params: ItemRouteParams = new ItemRouteParams(group.library_id, group.media_item_id,
      season, episode);
    this.leaveLightbox((): void => {
      const stack: NavPathStack | null = NavStacks.of(NavStacks.currentKey);
      if (stack !== null) {
        stack.pushPathByName('libraryItem', params);
      }
    });
  }

  // MARK: 视图

  build() {
    Column() {
      // 宽度探针：瀑布流排版要在渲染前知道列宽（List 自己有左右页边距，探针在外）
      Row()
        .width('100%')
        .height(0)
        .onAreaChange((_old: Area, area: Area) => {
          const w: Length = area.width;
          if (typeof w === 'number' && w > 0 && Math.abs(w - this.wallWidth) > 0.5) {
            this.wallWidth = w - Theme.pagePadding * 2;
            this.relayout();
          }
        })
      if (this.failed) {
        Column({ space: 12 }) {
          Text('图床加载失败')
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
              this.reload(this.startOffset);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .padding(24)
        .justifyContent(FlexAlign.Center)
      } else if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(26)
            .height(26)
            .color(Theme.textMuted)
          Text('正在加载图片…')
            .fontSize(14)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.groups.length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.rectangle_stack'))
            .fontSize(30)
            .fontColor([Theme.textFaint])
          Text('暂无图片')
            .fontSize(16)
            .fontWeight(600)
            .fontColor(Theme.text)
          Text('作品刮削出海报、剧照或章节图后，会出现在这里。')
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          LazyForEach(this.sectionSource, (section: GallerySection) => {
            ListItem() {
              this.SectionView(section)
            }
          }, (section: GallerySection) => section.key)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        // 嵌在外层页面 List 里（单库/合集页的图床浏览占满一屏）时，自己滚到边要交还外层：
        // 否则满屏的图廊会把用户锁在里面，滚不回页头
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .cachedCount(3)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: Theme.tabBarInset })
        .onReachEnd(() => {
          this.loadMore();
        })
        .onScrollIndex((first: number) => {
          if (first >= 0 && first < this.sections.length) {
            const g: number = this.firstGroupOf(this.sections[first]);
            if (g >= 0) {
              this.onFirstVisible(this.start + g);
            }
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .bindContentCover($$this.lightboxOpen, this.LightboxCover(), {
      modalTransition: ModalTransition.DEFAULT,
      backgroundColor: '#000000',
      onDisappear: (): void => {
        this.runPendingNav();
      }
    })
  }

  @Builder
  SectionView(section: GallerySection) {
    if (section.isFooter) {
      Column() {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(Theme.textMuted)
      }
      .width('100%')
      .height(section.height)
      .justifyContent(FlexAlign.Center)
    } else {
      Column() {
        if (section.headerGroupIndex >= 0) {
          this.GroupHeader(section.headerGroupIndex)
        }
        if (section.tiles.length > 0) {
          Stack({ alignContent: Alignment.TopStart }) {
            ForEach(section.tiles, (bandTile: GalleryBandTile) => {
              this.TileView(bandTile)
            }, (bandTile: GalleryBandTile) => `${bandTile.tile.flatIndex}-${bandTile.localY}`)
          }
          .width('100%')
          .height(section.height)
          .clip(true)
        }
      }
      .width('100%')
    }
  }

  /** 组标题：点开这部作品的详情 */
  @Builder
  GroupHeader(groupIndex: number) {
    Row({ space: 10 }) {
      Text(this.groupTitle(groupIndex))
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${this.groups[groupIndex].images.length} 张`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .padding({ top: 24, bottom: 12 })
    .alignItems(VerticalAlign.Bottom)
    .onClick(() => {
      this.onOpenItem(this.groups[groupIndex]);
    })
  }

  /** 一张瓦片：图 + 收藏角标（唯一的常驻角标：状态不是分类） */
  @Builder
  TileView(bandTile: GalleryBandTile) {
    Stack({ alignContent: Alignment.TopEnd }) {
      RemoteImage({ url: bandTile.tile.url })
      if (this.isFavorite(bandTile.tile.groupIndex)) {
        SymbolGlyph($r('sys.symbol.heart_fill'))
          .fontSize(13)
          .fontColor([Theme.danger])
          .padding(6)
          .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetY: 1 })
      }
    }
    .width(bandTile.tile.width)
    .height(bandTile.tile.height)
    .position({ x: bandTile.tile.x, y: bandTile.localY })
    .borderRadius(12)
    .clip(true)
    .onClick(() => {
      this.lightboxCurrent = bandTile.tile.flatIndex;
      this.lightboxOpen = true;
    })
  }

  /** 灯箱（对应 Web VideoGalleryLightbox）：全屏翻图，底栏「播放 / 收藏 / 详情」 */
  @Builder
  LightboxCover() {
    Column() {
      Row({ space: 12 }) {
        Text(this.lightboxTitle())
          .fontSize(13)
          .fontColor('rgba(243,245,249,0.75)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(17)
          .fontColor([Theme.textMuted])
          .padding(6)
          .onClick(() => {
            this.lightboxOpen = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 14, top: 18, bottom: 6 })

      Swiper() {
        LazyForEach(this.slideSource, (tile: GalleryTile) => {
          Stack({ alignContent: Alignment.Center }) {
            RemoteImage({ url: tile.screenUrl, fit: true, placeholderSymbol: $r('sys.symbol.film') })
          }
          .width('100%')
          .height('100%')
        }, (tile: GalleryTile) => `${tile.flatIndex}`)
      }
      .index(this.lightboxCurrent)
      .loop(false)
      .indicator(false)
      .cachedCount(1)
      .layoutWeight(1)
      .onChange((index: number) => {
        this.lightboxCurrent = index;
        if (index >= this.flatTiles.length - 4) {
          this.loadMore();
        }
      })

      Row({ space: 30 }) {
        Column({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(20)
            .fontColor([Theme.text])
          Text(this.currentPlayLabel())
            .fontSize(11)
            .fontColor(Theme.textMuted)
        }
        .onClick(() => {
          this.playFromLightbox();
        })

        Column({ space: 5 }) {
          SymbolGlyph(this.isCurrentFavorite() ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
            .fontSize(20)
            .fontColor([this.isCurrentFavorite() ? Theme.danger : Theme.text])
          Text(this.isCurrentFavorite() ? '取消收藏' : '收藏')
            .fontSize(11)
            .fontColor(Theme.textMuted)
        }
        .onClick(() => {
          this.toggleCurrentFavorite();
        })

        Column({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.arrow_up_right'))
            .fontSize(20)
            .fontColor([Theme.text])
          Text('前往详情')
            .fontSize(11)
            .fontColor(Theme.textMuted)
        }
        .onClick(() => {
          this.openDetailFromLightbox();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 14, bottom: 26 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }

  private isCurrentFavorite(): boolean {
    const tile: GalleryTile | null = this.currentTile();
    return tile === null ? false : this.isFavorite(tile.groupIndex);
  }
}
