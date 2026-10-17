import { Theme } from '../theme/AppTheme';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ShellChrome } from '../common/ShellChrome';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { DiscoveredPersonDetailsView, DiscoveredTitleView, SubscriptionView } from '../api/Models';
import { PersonParams, PersonHeaderCard } from './PersonDetailPage';
import { DiscoverDetailParams } from './DiscoverDetailPage';

/** 路由表注册用（router_map.json 的 buildMethod） */
@Builder
export function DiscoveredPersonBuilder() {
  DiscoveredPersonPage()
}

/** 加载失败的原因（对应 iOS `PersonDetailView.Failure`，两个影人页共用口径） */
class DiscoveredFailure {
  static readonly none: string = '';
  static readonly missing: string = 'missing';
  static readonly error: string = 'error';
}

/**
 * TMDB 影人页（对应 iOS 端 Features/Discover/DiscoveredPersonView.swift）。
 *
 * `GET /discover/people/{id}`，参演与幕后合并去重的完整 TMDB 影视履历。
 * 海报自带「已入库」绿斜标，未入库但已订阅的打「已订阅」蓝斜标；点海报进发现详情。
 */
@Component
export struct DiscoveredPersonPage {
  private navStack: NavPathStack = new NavPathStack();
  private tmdbId: number = 0;
  private started: boolean = false;
  /** 已订阅的 TMDB/豆瓣条目键（订阅列表加载后填充；加载失败置空 = 不打蓝标） */
  private subscribedTmdb: Set<number> = new Set<number>();
  private subscribedDouban: Set<string> = new Set<string>();

  @State private person: DiscoveredPersonDetailsView | null = null;
  @State private failure: string = DiscoveredFailure.none;
  @State private refreshing: boolean = false;

  private start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.load();
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.loadSubscriptions(api);
    try {
      const person: DiscoveredPersonDetailsView = await api.discoverGetPersonDetails(this.tmdbId);
      this.person = person;
      this.failure = DiscoveredFailure.none;
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) {
        this.failure = DiscoveredFailure.missing;
      } else {
        this.failure = DiscoveredFailure.error;
      }
    }
  }

  /** 订阅索引（对应 iOS `SubscriptionIndex.shared`，这里按页拉取；无订阅权限或失败都不打蓝标） */
  private async loadSubscriptions(api: MovieClawApi): Promise<void> {
    if (!Permissions.fromSession(AppModel.shared.session).canSubscribe) {
      return;
    }
    try {
      const list: SubscriptionView[] = await api.subscriptionsList();
      const tmdb: Set<number> = new Set<number>();
      const douban: Set<string> = new Set<string>();
      for (const sub of list) {
        tmdb.add(sub.media.tmdb_id);
        const doubanId: string | null = sub.media.douban_id ?? null;
        if (doubanId !== null && doubanId.length > 0) {
          douban.add(doubanId);
        }
      }
      this.subscribedTmdb = tmdb;
      this.subscribedDouban = douban;
    } catch (error) {
      // 蓝标是锦上添花：订阅列表拉不到就当作都不在订阅中（同 iOS 容错）
    }
  }

  // MARK: 派生

  private title(): string {
    const person: DiscoveredPersonDetailsView | null = this.person;
    return person !== null ? person.name : '';
  }

  private inLibrary(item: DiscoveredTitleView): boolean {
    const status = item.library_status;
    return status !== null && status !== undefined && (status.library_count ?? 0) > 0;
  }

  private isSubscribed(item: DiscoveredTitleView): boolean {
    if (item.provider === 'douban') {
      return this.subscribedDouban.has(item.external_id);
    }
    const id: number = Number(item.external_id);
    return Number.isFinite(id) && this.subscribedTmdb.has(id);
  }

  /** 手机三列（同 iOS DiscoverGrid.columns），按行切块渲染 */
  private rowsOf(titles: DiscoveredTitleView[]): DiscoveredTitleView[][] {
    const rows: DiscoveredTitleView[][] = [];
    for (let i: number = 0; i < titles.length; i += 3) {
      const end: number = Math.min(i + 3, titles.length);
      const row: DiscoveredTitleView[] = [];
      for (let j: number = i; j < end; j++) {
        row.push(titles[j]);
      }
      rows.push(row);
    }
    return rows;
  }

  private fillers(count: number): number[] {
    const out: number[] = [];
    for (let i: number = 0; i < 3 - count; i++) {
      out.push(i);
    }
    return out;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        PageTopBar({ title: this.title(), onBack: (): void => {
          this.navStack.pop();
        }})
        if (this.failure !== DiscoveredFailure.none) {
          this.FallbackState()
        } else if (this.person === null) {
          this.LoadingState()
        } else {
          this.Content(this.person as DiscoveredPersonDetailsView)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: PersonParams | null = PersonParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null) {
        this.tmdbId = params.tmdbId;
        this.start();
      }
    })
  }

  @Builder
  LoadingState() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(28)
        .height(28)
        .color(Theme.textMuted)
      Text('正在读取 TMDB 影人作品…')
        .fontSize(15)
        .fontColor(Theme.textMuted)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FallbackState() {
    Column({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.person'))
        .fontSize(34)
        .fontColor([Theme.textMuted])
      if (this.failure === DiscoveredFailure.missing) {
        Text('TMDB 中没有这位影人')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text('这条影人记录可能已被 TMDB 合并或移除。')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
      } else {
        Text('未能加载影人作品')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text('请稍后重试；若持续失败，请检查 TMDB 网络连接。')
          .fontSize(14)
          .fontColor(Theme.textMuted)
          .textAlign(TextAlign.Center)
      }
      Row({ space: 12 }) {
        if (this.failure === DiscoveredFailure.error) {
          Text('重试')
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#0b0d12')
            .padding({ left: 22, right: 22, top: 10, bottom: 10 })
            .backgroundColor(Theme.accent)
            .borderRadius(20)
            .onClick(() => {
              this.load();
            })
        }
        Text('返回发现页')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .padding({ left: 22, right: 22, top: 10, bottom: 10 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(20)
          .border({ width: 1, color: Theme.lineStrong })
          .onClick(() => {
            ShellChrome.openTab('discover');
          })
      }
      .margin({ top: 4 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }

  @Builder
  Content(person: DiscoveredPersonDetailsView) {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: 24 }) {
          PersonHeaderCard({
            name: person.name,
            avatarUrl: ImageUrls.resolve(AppModel.origin(), person.avatar_url ?? null,
              ImageVariant.photoTile) ?? '',
            eyebrow: 'TMDB 影人',
            subtitle: '',
            summary: `共 ${person.titles.length} 部影视作品`
          })
          if (person.titles.length === 0) {
            Text('TMDB 暂未收录这位影人的影视作品')
              .fontSize(14)
              .fontColor(Theme.textMuted)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 32, bottom: 32 })
              .backgroundColor(Theme.surface)
              .borderRadius(12)
          } else {
            Column({ space: 12 }) {
              Row({ space: 8 }) {
                Text('全部作品')
                  .fontSize(20)
                  .fontWeight(600)
                  .fontColor(Theme.text)
                Text(`${person.titles.length}`)
                  .fontSize(15)
                  .fontColor(Theme.textFaint)
              }
              .alignItems(VerticalAlign.Bottom)
              ForEach(this.rowsOf(person.titles), (row: DiscoveredTitleView[]) => {
                Row({ space: 12 }) {
                  ForEach(row, (item: DiscoveredTitleView) => {
                    PersonPosterCard({
                      item: item,
                      owned: this.inLibrary(item),
                      subscribed: this.isSubscribed(item),
                      onOpen: (): void => {
                        this.navStack.pushPathByName('discoverDetail',
                          new DiscoverDetailParams(item.title_ref));
                      }
                    })
                  }, (item: DiscoveredTitleView) => item.title_ref)
                  if (row.length < 3) {
                    ForEach(this.fillers(row.length), (key: number) => {
                      Column()
                        .layoutWeight(1)
                    }, (key: number) => `${key}`)
                  }
                }
                .width('100%')
              }, (row: DiscoveredTitleView[], index: number) => `${index}-${row.length}`)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 40 })
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .height('100%')
    }
    .onRefreshing(() => {
      this.load().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
  }
}

/**
 * 影人作品海报卡（对应 iOS `DiscoverPosterCard`，action = .none 的形态：
 * 单击直达详情，无展开信息层）。角标：左上「已入库」绿斜标 / 「已订阅」蓝斜标，
 * 右上评分徽章（评分为 0 不显示）。
 */
@Component
struct PersonPosterCard {
  item: DiscoveredTitleView = {} as DiscoveredTitleView;
  owned: boolean = false;
  subscribed: boolean = false;
  onOpen: () => void = (): void => {
  };
  @State private cardWidth: number = 0;

  build() {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        RemoteImage({
          url: ImageUrls.resolve(AppModel.origin(), this.item.poster_url,
            ImageVariant.posterCard) ?? ''
        })
          .width('100%')
          .height('100%')

        // 右上：评分徽章（黑底 + 黄星 + 一位小数）
        if ((this.item.provider_rating ?? 0) > 0) {
          Row({ space: 3 }) {
            SymbolGlyph($r('sys.symbol.star_fill'))
              .fontSize(9)
              .fontColor([Theme.warning])
            Text(this.item.provider_rating.toFixed(1))
              .fontSize(11)
              .fontWeight(600)
              .fontColor('#ffffff')
          }
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .backgroundColor('rgba(0,0,0,0.70)')
          .borderRadius(6)
          .position({ x: this.cardWidth - 52, y: 6 })
        }

        // 左上：斜标（同 Web：带宽 62%、左移 13%、距顶 15，绕中心逆时针 45°）
        if (this.owned || this.subscribed) {
          Text(this.owned ? '已入库' : '已订阅')
            .fontSize(9)
            .fontWeight(700)
            .fontColor('#ffffff')
            .letterSpacing(0.8)
            .textAlign(TextAlign.Center)
            .width(this.cardWidth * 0.62)
            .padding({ top: 2, bottom: 2 })
            .linearGradient(this.owned
              ? { angle: 90, colors: [['#0FBA82', 0], ['#0FB8A6', 1]] }
              : { angle: 90, colors: [['#0DA6E8', 0], ['#6366F2', 1]] })
            .rotate({ angle: -45 })
            .position({ x: this.cardWidth * 0.13 - this.cardWidth * 0.31, y: 7 })
        }
      }
      .width('100%')
      .aspectRatio(Theme.posterAspect)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .clip(true)
      .border({ width: 0.5, color: 'rgba(255,255,255,0.08)' })
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.35)', offsetY: 6 })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.cardWidth = newArea.width as number;
      })

      Text(this.item.title)
        .fontSize(14)
        .fontWeight(600)
        .fontColor(Theme.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ top: 6 })
      // 年份 · 规模（片长/季数）；始终保留一行，避免缺年份的卡片高低跳动（同 iOS metaLine）
      Text(this.metaLine())
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
    .onClick(() => {
      this.onOpen();
    })
  }

  private metaLine(): string {
    const parts: string[] = [];
    const year: number | null = this.item.release_year ?? null;
    if (year !== null && year > 0) {
      parts.push(`${year}`);
    }
    const extent: string = this.item.extent_label ?? '';
    if (extent.length > 0) {
      parts.push(extent);
    }
    if (parts.length === 0) {
      return ' ';
    }
    return parts.join(' · ');
  }
}
