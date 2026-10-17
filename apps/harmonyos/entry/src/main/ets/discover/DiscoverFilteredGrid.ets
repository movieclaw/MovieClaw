import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { AppFooter } from '../common/AppFooter';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  DiscoveredTitleView,
  DiscoverySort,
  DiscoveryTitlePageView,
  MediaKind
} from '../api/Models';
import { DiscoverDetailParams } from './DiscoverDetailPage';
import { DiscoverFilterSheet, DiscoverGenreCatalog, DiscoveryFilters } from './DiscoverFilter';

/**
 * 组合筛选结果网格（对应 iOS `DiscoverFilteredGrid`）：TMDB discover 原生分页，
 * 滚到底自动加载下一页（失败给「重试」），头部是条件摘要胶囊、「调整条件」与「清空条件」。
 *
 * 条件就在弹层里被改（`DiscoverFilterSheet` 直接改共享单例），网格不随条件重建：
 * `@Monitor` 盯住六个 `@Trace` 字段，**原地重查**——先等 300ms 防抖（连勾几个
 * 类型只查最后一次），期间再改就取消重来；请求带回代次守卫，旧条件的响应整页丢弃。
 */

/** 两列一行的海报块（LazyForEach 用，同 DiscoverCollectionPage 的切块方式） */
class FilteredRowsSource implements IDataSource {
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

@ComponentV2
export struct DiscoverFilteredGrid {
  @Require @Param navStack: NavPathStack;
  @Require @Param mediaType: string;
  /** 共享单例：弹层改它、这里盯着它重查（同 iOS 的 `@Binding var filters`） */
  @Require @Param filters: DiscoveryFilters;

  @Local private items: DiscoveredTitleView[] = [];
  @Local private totalResults: number = 0;
  @Local private hasMore: boolean = true;
  @Local private loading: boolean = false;
  @Local private error: string = '';
  @Local private showSheet: boolean = false;
  /** id → 类型名（摘要胶囊显示类型名而不是计数） */
  @Local private genreNames: Map<number, string> = new Map<number, string>();

  private nextPage: number = 1;
  /** 重查代次：防抖期间或请求在途时条件又变，旧请求的响应整页丢弃（同 iOS `requested == filters`） */
  private generation: number = 0;
  private debounceTimer: number = -1;
  private rowsSource: FilteredRowsSource = new FilteredRowsSource();

  aboutToAppear(): void {
    this.loadGenres();
    this.reset();
  }

  aboutToDisappear(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  /** 条件变了：防抖 300ms 后清空重查（连改几项只查最后一次，同 iOS） */
  @Monitor('filters.genreIds', 'filters.originCountry', 'filters.year',
    'filters.ratingGte', 'filters.runtimeLte', 'filters.sort')
  onFiltersChanged(): void {
    this.scheduleReload();
  }

  /** 类型变了（电影 ⇄ 剧集是两套类型 ID）：同样重查 */
  @Monitor('mediaType')
  onMediaTypeChanged(): void {
    this.loadGenres();
    this.scheduleReload();
  }

  private scheduleReload(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout((): void => {
      this.debounceTimer = -1;
      this.reset();
    }, 300);
  }

  /** 清空重查（首次进入不走防抖） */
  private reset(): void {
    this.items = [];
    this.nextPage = 1;
    this.totalResults = 0;
    this.hasMore = true;
    this.error = '';
    this.syncRows();
    this.loadPage();
  }

  private loadGenres(): void {
    const mediaType: string = this.mediaType;
    this.genreNames = DiscoverGenreCatalog.names(mediaType);
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    DiscoverGenreCatalog.load(api, mediaType).then((): void => {
      if (mediaType === this.mediaType) {
        this.genreNames = DiscoverGenreCatalog.names(mediaType);
      }
    });
  }

  /** 拉一页（首页与续页共用）；代次守卫丢弃过期响应 */
  private async loadPage(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null || this.loading || !this.hasMore) {
      return;
    }
    this.generation += 1;
    const gen: number = this.generation;
    this.loading = true;
    this.error = '';
    const filters: DiscoveryFilters = this.filters;
    const page: number = this.nextPage;
    try {
      const view: DiscoveryTitlePageView = await api.discoverFilterTitles(
        this.mediaType as MediaKind,
        filters.genreIds.length > 0 ? filters.genreIds : undefined,
        filters.originCountry ?? undefined,
        filters.year ?? undefined,
        filters.ratingGte ?? undefined,
        filters.runtimeLte ?? undefined,
        filters.sort === 'popular' ? undefined : filters.sort as DiscoverySort,
        page);
      if (gen !== this.generation) {
        return;
      }
      const known: Set<string> = new Set<string>();
      for (const item of this.items) {
        known.add(item.title_ref);
      }
      const merged: DiscoveredTitleView[] = this.items.slice();
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
      if (gen === this.generation) {
        this.error = this.messageOf(error);
      }
    } finally {
      if (gen === this.generation) {
        this.loading = false;
      }
    }
  }

  private syncRows(): void {
    this.rowsSource.setTitles(this.items);
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '筛选结果加载失败，请稍后重试';
  }

  private countLine(): string {
    if (this.totalResults > 0) {
      return `找到 ${this.totalResults} 部，已加载 ${this.items.length} 部`;
    }
    return `已启用 ${this.filters.activeCount()} 项筛选`;
  }

  /** 条件摘要（头部胶囊）：类型名由清单补齐 */
  private summaryLabels(): string[] {
    return this.filters.labels(this.genreNames);
  }

  private openTitle(item: DiscoveredTitleView): void {
    this.navStack.pushPathByName('discoverDetail', new DiscoverDetailParams(item.title_ref));
  }

  // MARK: 视图

  build() {
    Column() {
      List() {
        ListItem() {
          this.Header()
        }
        if (this.items.length === 0 && this.error.length > 0) {
          ListItem() {
            Column({ space: 12 }) {
              Text(this.error)
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
                  this.reset();
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 48 })
          }
        } else if (this.items.length === 0 && this.loading) {
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
        } else if (this.items.length === 0) {
          ListItem() {
            Text('没有符合条件的影片')
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
          if (this.loading) {
            ListItem() {
              LoadingProgress()
                .width(22)
                .height(22)
                .color(Theme.textMuted)
                .margin({ top: 12, bottom: 12 })
            }
          }
          if (this.error.length > 0) {
            ListItem() {
              Row({ space: 12 }) {
                Text(this.error)
                  .fontSize(13)
                  .fontColor(Theme.textMuted)
                  .layoutWeight(1)
                Text('重试')
                  .fontSize(13)
                  .fontWeight(600)
                  .fontColor(Theme.accentStrong)
                  .onClick(() => {
                    this.loadPage();
                  })
              }
              .width('100%')
              .padding(12)
              .backgroundColor(Theme.surface)
              .borderRadius(Theme.cardRadius)
            }
          }
          if (!this.hasMore) {
            ListItem() {
              Text(`已加载全部 ${this.items.length} 部影片`)
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 4, bottom: 8 })
            }
          }
        }
        ListItem() {
          AppFooter({ topSpace: 24 })
        }
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(2)
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      .onReachEnd(() => {
        this.loadPage();
      })
      .padding({ bottom: Theme.tabBarInset })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
    .bindSheet($$this.showSheet, this.SheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg
    })
  }

  @Builder
  SheetContent() {
    DiscoverFilterSheet({
      mediaType: this.mediaType,
      filters: this.filters,
      onClose: (): void => {
        this.showSheet = false;
      }
    })
  }

  /** 页头：眉行 → 标题 → 计数行 + 「调整条件」；条件摘要胶囊与「清空」 */
  @Builder
  Header() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 4 }) {
          Text('TMDB DISCOVER')
            .fontSize(13)
            .fontWeight(600)
            .letterSpacing(2)
            .fontColor(Theme.accent2)
          Text('筛选结果')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.text)
          Text(this.countLine())
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
            .fontSize(14)
            .fontColor([Theme.textMuted])
          Text('调整条件')
            .fontSize(13)
            .fontColor(Theme.textMuted)
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(Theme.glassFill)
        .borderRadius(18)
        .border({ width: 1, color: Theme.line })
        .onClick(() => {
          this.showSheet = true;
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      if (this.summaryLabels().length > 0 || this.filters.activeCount() > 0) {
        Scroll() {
          Row({ space: 8 }) {
            if (this.filters.activeCount() > 0) {
              Text('✕ 清空')
                .fontSize(12)
                .fontColor(Theme.danger)
                .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                .backgroundColor(Theme.glassFill)
                .borderRadius(14)
                .onClick(() => {
                  this.filters.clear();
                })
            }
            ForEach(this.summaryLabels(), (label: string) => {
              this.SummaryChip(label)
            }, (label: string) => label)
          }
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8 })
  }

  /** 条件摘要胶囊（只读；改条件走「调整条件」弹层） */
  @Builder
  SummaryChip(label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.text)
      .padding({ left: 11, right: 11, top: 6, bottom: 6 })
      .backgroundColor(Theme.glassFillHover)
      .borderRadius(14)
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
