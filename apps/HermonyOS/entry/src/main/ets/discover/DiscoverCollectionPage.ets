import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { PageTopBar } from '../common/PageTopBar';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { DiscoveredTitleView, DiscoveryCollectionTitlesView } from '../api/Models';
import { DiscoverDetailParams } from './DiscoverDetailPage';

/**
 * 榜单全列表页（对齐 iOS `DiscoverCollectionView`）：`discoverBrowseCollection` 翻页拉全量。
 *
 * - TMDB 片单每页 20 条，滚到底自动续页（失败给「重试下一页」）；豆瓣片单一次取完（limit 500）；
 * - 顶部可按片名搜索、按类型筛选**已加载**的条目（纯本地过滤，不触发请求；过滤期间不自动续页）。
 */

/** 路由参数：片单 ref（`tmdb:movie:xxx` / `douban:movie:xxx`）+ 行标题（兜底名，接口回来后替换） */
export class DiscoverCollectionParams {
  readonly collectionRef: string;
  readonly title: string;

  constructor(collectionRef: string, title: string) {
    this.collectionRef = collectionRef;
    this.title = title;
  }

  static of(param: Object | undefined | null): DiscoverCollectionParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: DiscoverCollectionParams = param as DiscoverCollectionParams;
    const ref: string = raw.collectionRef;
    if (ref === undefined || ref === null || ref.length === 0) {
      return null;
    }
    const title: string = raw.title;
    return new DiscoverCollectionParams(ref, title === undefined || title === null ? '' : title);
  }
}

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function DiscoverCollectionBuilder() {
  DiscoverCollectionPage()
}

/** 两列一行的海报块（LazyForEach 用，同搜索结果页 TitleRowsSource 的切块方式） */
class CollectionRowsSource implements IDataSource {
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

/** 类型筛选档：类型名 + 在已加载条目里的出现次数 */
class GenreCount {
  readonly name: string;
  readonly count: number;

  constructor(name: string, count: number) {
    this.name = name;
    this.count = count;
  }
}

@ComponentV2
export struct DiscoverCollectionPage {
  private navStack: NavPathStack = new NavPathStack();
  private collectionRef: string = '';
  @Local collectionTitle: string = '';
  private isTMDB: boolean = true;
  /** null = 还在读取 */
  @Local items: DiscoveredTitleView[] | null = null;
  @Local nextPage: number = 2;
  @Local totalResults: number = 0;
  @Local hasMore: boolean = false;
  @Local loadingMore: boolean = false;
  /** 首屏加载错误 */
  @Local firstError: string = '';
  /** 续页错误 */
  @Local moreError: string = '';
  /** 本地片名过滤（只过滤已加载条目，不触发请求） */
  @Local query: string = '';
  /** 本地类型筛选（多选 = 或） */
  @Local selectedGenres: string[] = [];
  private rowsSource: CollectionRowsSource = new CollectionRowsSource();

  // MARK: 取数

  private async loadFirstPage(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.firstError = '';
    try {
      const view: DiscoveryCollectionTitlesView = await api.discoverBrowseCollection(
        this.collectionRef, this.isTMDB ? 20 : 500, 1);
      this.items = view.titles;
      this.collectionTitle = view.collection.name;
      this.totalResults = view.total_results;
      this.hasMore = this.isTMDB && view.has_more;
      this.nextPage = view.page + 1;
      this.syncRows();
    } catch (error) {
      this.firstError = this.messageOf(error);
    }
  }

  private async loadNextPage(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || !this.isTMDB || !this.hasMore || this.loadingMore || this.items === null) {
      return;
    }
    this.loadingMore = true;
    this.moreError = '';
    try {
      const view: DiscoveryCollectionTitlesView = await api.discoverBrowseCollection(
        this.collectionRef, 20, this.nextPage);
      const known: Set<string> = new Set<string>();
      const all: DiscoveredTitleView[] = this.items;
      for (const item of all) {
        known.add(item.title_ref);
      }
      const merged: DiscoveredTitleView[] = all.slice();
      for (const item of view.titles) {
        if (!known.has(item.title_ref)) {
          merged.push(item);
        }
      }
      this.items = merged;
      this.totalResults = view.total_results;
      this.hasMore = view.has_more;
      this.nextPage = view.page + 1;
      this.syncRows();
    } catch (error) {
      this.moreError = this.messageOf(error);
    } finally {
      this.loadingMore = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '榜单加载失败，请稍后重试';
  }

  // MARK: 本地过滤

  /** 正在过滤（过滤期间不自动续页，同 iOS filteringLoaded） */
  private filteringActive(): boolean {
    return this.query.trim().length > 0 || this.selectedGenres.length > 0;
  }

  /** 命中当前过滤条件的条目（纯本地，不触发请求） */
  private filtered(): DiscoveredTitleView[] {
    const all: DiscoveredTitleView[] | null = this.items;
    if (all === null) {
      return [];
    }
    const keyword: string = this.query.trim().toLowerCase();
    const picked: DiscoveredTitleView[] = [];
    for (const item of all) {
      const genreOk: boolean = this.selectedGenres.length === 0 || this.genreMatched(item);
      const keywordOk: boolean = keyword.length === 0
        || item.title.toLowerCase().includes(keyword)
        || item.original_title.toLowerCase().includes(keyword);
      if (genreOk && keywordOk) {
        picked.push(item);
      }
    }
    return picked;
  }

  private genreMatched(item: DiscoveredTitleView): boolean {
    for (const genre of item.genres) {
      if (this.selectedGenres.indexOf(genre) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 类型档：按已加载条目统计，次数降序、同次数按名称升序（同 iOS genres） */
  private genreCounts(): GenreCount[] {
    const all: DiscoveredTitleView[] | null = this.items;
    if (all === null) {
      return [];
    }
    const counts: Map<string, number> = new Map<string, number>();
    for (const item of all) {
      for (const genre of item.genres) {
        counts.set(genre, (counts.get(genre) ?? 0) + 1);
      }
    }
    const out: GenreCount[] = [];
    counts.forEach((count: number, name: string): void => {
      out.push(new GenreCount(name, count));
    });
    out.sort((a: GenreCount, b: GenreCount): number => {
      if (a.count !== b.count) {
        return b.count - a.count;
      }
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
    });
    return out;
  }

  private toggleGenre(name: string): void {
    const at: number = this.selectedGenres.indexOf(name);
    const next: string[] = this.selectedGenres.slice();
    if (at < 0) {
      next.push(name);
    } else {
      next.splice(at, 1);
    }
    this.selectedGenres = next;
    this.syncRows();
  }

  private clearFilters(): void {
    this.query = '';
    this.selectedGenres = [];
    this.syncRows();
  }

  /** 把过滤后的条目喂给懒加载数据源（加载完成/筛选变化时调） */
  private syncRows(): void {
    this.rowsSource.setTitles(this.filtered());
  }

  private countLine(): string {
    const all: DiscoveredTitleView[] | null = this.items;
    if (all === null) {
      return '正在读取完整榜单…';
    }
    return this.isTMDB
      ? `已加载 ${all.length} / ${this.totalResults} 部影片`
      : `完整收录 ${all.length} 部影片`;
  }

  private openTitle(item: DiscoveredTitleView): void {
    this.navStack.pushPathByName('discoverDetail', new DiscoverDetailParams(item.title_ref));
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        PageTopBar({ title: this.collectionTitle, onBack: (): void => {
          this.navStack.pop();
        }})
        List() {
          ListItem() {
            this.Header()
          }
          if (this.items === null && this.firstError.length > 0) {
            ListItem() {
              Column({ space: 12 }) {
                Text(this.firstError)
                  .fontSize(14)
                  .fontColor(Theme.textMuted)
                  .textAlign(TextAlign.Center)
                Text('重试')
                  .fontSize(15)
                  .fontWeight(600)
                  .fontColor(Theme.accentStrong)
                  .padding({ left: 22, right: 22, top: 10, bottom: 10 })
                  .backgroundColor(Theme.glassFill)
                  .borderRadius(20)
                  .border({ width: 1, color: Theme.lineStrong })
                  .onClick(() => {
                    this.loadFirstPage();
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 48, left: 24, right: 24 })
            }
          } else if (this.items === null) {
            // 骨架：两列六格
            ListItem() {
              Column({ space: 28 }) {
                ForEach([0, 1, 2], (rowIndex: number) => {
                  Row({ space: 12 }) {
                    Column()
                      .layoutWeight(1)
                      .aspectRatio(Theme.posterAspect)
                      .backgroundColor(Theme.surface)
                      .borderRadius(Theme.cardRadius)
                    Column()
                      .layoutWeight(1)
                      .aspectRatio(Theme.posterAspect)
                      .backgroundColor(Theme.surface)
                      .borderRadius(Theme.cardRadius)
                  }
                  .width('100%')
                }, (rowIndex: number) => `${rowIndex}`)
              }
              .width('100%')
              .padding({ top: 16 })
            }
          } else {
            if (this.filtered().length === 0) {
              ListItem() {
                Text('没有找到匹配的影片')
                  .fontSize(15)
                  .fontColor(Theme.textMuted)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 60, bottom: 60 })
              }
            } else {
              LazyForEach(this.rowsSource, (row: DiscoveredTitleView[]) => {
                ListItem() {
                  Row({ space: 12 }) {
                    ForEach(row, (item: DiscoveredTitleView) => {
                      this.PosterCard(item)
                    }, (item: DiscoveredTitleView) => item.title_ref)
                  }
                  .width('100%')
                }
              }, (row: DiscoveredTitleView[], index: number) => `${row.map((item: DiscoveredTitleView): string => item.title_ref).join('-')}-${index}`)
            }
            if (this.loadingMore) {
              ListItem() {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color(Theme.textMuted)
                  .margin({ top: 12, bottom: 12 })
              }
            }
            if (this.moreError.length > 0) {
              ListItem() {
                Row({ space: 12 }) {
                  Text(this.moreError)
                    .fontSize(13)
                    .fontColor(Theme.textMuted)
                    .layoutWeight(1)
                  if (this.hasMore) {
                    Text('重试下一页')
                      .fontSize(13)
                      .fontWeight(600)
                      .fontColor(Theme.accentStrong)
                      .onClick(() => {
                        this.loadNextPage();
                      })
                  }
                }
                .width('100%')
                .padding(12)
                .backgroundColor(Theme.surface)
                .borderRadius(Theme.cardRadius)
              }
            }
            if (!this.hasMore && !this.filteringActive() && (this.filtered().length > 0)) {
              ListItem() {
                Text(`已加载全部 ${(this.items ?? []).length} 部影片`)
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 4, bottom: 8 })
              }
            }
            ListItem() {
              AppFooter({ topSpace: 24 })
            }
          }
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
        .onReachEnd(() => {
          // 过滤期间不自动续页（同 iOS：只翻「未过滤」的完整榜单）
          if (!this.filteringActive()) {
            this.loadNextPage();
          }
        })
        .padding({ bottom: Theme.tabBarInset })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: DiscoverCollectionParams | null
        = DiscoverCollectionParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && this.collectionRef.length === 0) {
        this.collectionRef = params.collectionRef;
        this.collectionTitle = params.title;
        this.isTMDB = !params.collectionRef.startsWith('douban:');
        this.loadFirstPage();
      }
    })
  }

  /** 页头：来源眉行 → 片单名 → 计数行 → 搜索框 → 类型胶囊（同 iOS header） */
  @Builder
  Header() {
    Column({ space: 6 }) {
      Text(`${this.isTMDB ? 'TMDB' : 'DOUBAN'} COLLECTION`)
        .fontSize(13)
        .fontWeight(600)
        .letterSpacing(2)
        .fontColor(Theme.accent2)
      Text(this.collectionTitle)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.text)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.countLine())
        .fontSize(13)
        .fontColor(Theme.textMuted)
      TextInput({ text: this.query, placeholder: this.isTMDB ? '搜索已加载片名' : '搜索片名' })
        .fontSize(14)
        .fontColor(Theme.text)
        .placeholderColor(Theme.textFaint)
        .placeholderFont({ size: 14 })
        .height(40)
        .backgroundColor(Theme.glassFill)
        .borderRadius(20)
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.query = value;
          this.syncRows();
        })
        .margin({ top: 6 })
      if (this.genreCounts().length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            Text(this.isTMDB ? '已加载类型' : '类型')
              .fontSize(13)
              .fontWeight(600)
              .fontColor(Theme.textMuted)
            this.GenreChip('全部', this.selectedGenres.length === 0, '', (): void => {
              this.selectedGenres = [];
              this.syncRows();
            })
            ForEach(this.genreCounts(), (genre: GenreCount) => {
              this.GenreChip(genre.name, this.selectedGenres.indexOf(genre.name) >= 0,
                `${genre.count}`, (): void => {
                  this.toggleGenre(genre.name);
                })
            }, (genre: GenreCount) => genre.name)
            if (this.selectedGenres.length > 0) {
              Text(`清除筛选（${this.selectedGenres.length}）`)
                .fontSize(13)
                .fontColor(Theme.accentStrong)
                .onClick(() => {
                  this.clearFilters();
                })
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8 })
  }

  /** 类型胶囊：选中高亮，带可选计数 */
  @Builder
  GenreChip(label: string, active: boolean, count: string, onTap: () => void) {
    Row({ space: 5 }) {
      Text(label)
        .fontSize(12)
        .fontColor(active ? '#ffffff' : 'rgba(255, 255, 255, 0.7)')
      if (count.length > 0) {
        Text(count)
          .fontSize(12)
          .fontColor('rgba(255, 255, 255, 0.4)')
      }
    }
    .padding({ left: 10, right: 10 })
    .height(28)
    .backgroundColor(active ? 'rgba(255, 255, 255, 0.16)' : 'rgba(255, 255, 255, 0.05)')
    .borderRadius(14)
    .onClick(() => {
      onTap();
    })
  }

  /** 海报卡：海报 + 片名 + 年份/评分 + 已入库角标（同发现页行卡） */
  @Builder
  PosterCard(item: DiscoveredTitleView) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        RemoteImage({
          url: ImageUrls.resolve(AppModel.origin(), item.poster_url, ImageVariant.posterCard) ?? ''
        })
          .width('100%')
          .height('100%')
        if (this.inLibrary(item)) {
          Text('已入库')
            .fontSize(11)
            .fontColor('#0b0d12')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(Theme.accent)
            .borderRadius(6)
            .margin({ top: 6, right: 6 })
        }
      }
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
      Text(this.cardSubtitle(item))
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

  private cardSubtitle(item: DiscoveredTitleView): string {
    const parts: string[] = [];
    const year: number | null = item.release_year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    if ((item.provider_rating ?? 0) > 0) {
      parts.push(`★ ${item.provider_rating.toFixed(1)}`);
    }
    return parts.join('  ·  ');
  }

  private inLibrary(item: DiscoveredTitleView): boolean {
    const status = item.library_status;
    return status !== null && status !== undefined && (status.library_count ?? 0) > 0;
  }
}
