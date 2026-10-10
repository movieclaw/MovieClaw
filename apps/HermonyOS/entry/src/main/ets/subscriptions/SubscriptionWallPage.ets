import { Theme } from '../theme/AppTheme';
import { display } from '@kit.ArkUI';
import { PageTopBar } from '../common/PageTopBar';
import { AppModel } from '../common/AppModel';
import { Permissions } from '../common/Permissions';
import { AppFooter } from '../common/AppFooter';
import { MovieClawApi } from '../api/Endpoints';
import { LibraryView, RecentArrivalView, RuleSetView, SubscriptionView, TodayArrivalView } from '../api/Models';
import { SubscriptionParams } from './SubscriptionDetailPage';
import { DiscoverDetailParams } from '../discover/DiscoverDetailPage';
import { SubsHome } from './SubscriptionsHomeModel';
import { SubsPosterCard } from './SubsPosterCard';

/** 海报墙页的路由参数（路由参数会被序列化，不要用 instanceof） */
export class SubscriptionWallParams {
  readonly kind: string;

  constructor(kind: string) {
    this.kind = kind;
  }

  static of(param: Object | undefined | null): SubscriptionWallParams | null {
    if (param === undefined || param === null) {
      return null;
    }
    const raw: SubscriptionWallParams = param as SubscriptionWallParams;
    const kind: string = raw.kind === 'movie' ? 'movie' : 'tv';
    return new SubscriptionWallParams(kind);
  }
}

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function SubscriptionWallBuilder() {
  SubscriptionWallPage()
}

/**
 * 订阅海报墙（对应 iOS `SubscriptionWallView`）：首页「剧集订阅 ›」「电影订阅 ›」或一排末尾的
 * 「查看全部」压栈进来的二级页。与首页那一排是同一份排好的结果（`SubsHome`），分三段——
 * 进行中 / 已暂停 / 已收齐（电影叫已入库）；墙上多一行「规则组 → 媒体库」流向。
 */
@ComponentV2
export struct SubscriptionWallPage {
  private navStack: NavPathStack = new NavPathStack();
  private started: boolean = false;
  private kind: string = 'tv';

  @Local private subs: SubscriptionView[] = [];
  @Local private today: TodayArrivalView[] = [];
  @Local private recent: RecentArrivalView[] = [];
  @Local private ruleSets: RuleSetView[] = [];
  @Local private libraries: LibraryView[] = [];
  @Local private loading: boolean = true;
  @Local private refreshing: boolean = false;
  @Local private failed: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private home(): SubsHome {
    return new SubsHome(this.subs, this.today, this.recent);
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.subs = await api.subscriptionsList();
      this.failed = false;
    } catch (error) {
      this.failed = true;
    }
    try {
      this.today = await api.subscriptionsListTodayArrivals('week');
    } catch (error) {
      this.today = [];
    }
    try {
      this.recent = await api.subscriptionsListRecentArrivals(7, 20);
    } catch (error) {
      this.recent = [];
    }
    this.loading = false;
  }

  private async loadNames(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.libraries = await api.libraryList(undefined, 'all');
    } catch (error) {
      this.libraries = [];
    }
    if (Permissions.fromSession(AppModel.shared.session).isAdmin) {
      try {
        this.ruleSets = await api.rulesList();
      } catch (error) {
        this.ruleSets = [];
      }
    }
  }

  /** 海报第三行：「规则组 → 媒体库」（未指定库时显示该类型默认库，同 iOS `flow`） */
  private flow(sub: SubscriptionView): string {
    const parts: string[] = [];
    for (const rule of this.ruleSets) {
      if (rule.id === sub.rule_set_id) {
        parts.push(rule.name);
      }
    }
    const libraryId: number | null = sub.library_id ?? null;
    let libraryName: string = '';
    if (libraryId !== null) {
      for (const library of this.libraries) {
        if (library.id === libraryId) {
          libraryName = library.name;
        }
      }
    } else {
      for (const library of this.libraries) {
        if (library.is_default && library.kind === sub.media.kind) {
          libraryName = library.name;
        }
      }
    }
    if (libraryName.length > 0) {
      parts.push(libraryName);
    }
    return parts.join(' → ');
  }

  /** 自适应列数（2~4，同 `Theme.posterColumns`）：卡片宽按列数算，保证一行正好放下 N 个 */
  private cardWidth(): number {
    const widthVp: number = px2vp(display.getDefaultDisplaySync().width);
    const columns: number = Theme.posterColumns();
    const usable: number = widthVp - Theme.pagePadding * 2;
    // 每个卡片右侧留 12 间距：N*(w+12) = usable
    return Math.max(96, Math.floor(usable / columns) - 12);
  }

  /** 「共 12 部剧集 · 5 部进行中」（与首页那一排同一口径，同 iOS `summary`） */
  private summary(): string {
    const split = this.home().shelfSplit(this.kind);
    const total: number = split.all().length;
    const active: number = split.active.length;
    const noun: string = this.kind === 'movie' ? '电影' : '剧集';
    if (active > 0 && active < total) {
      return `共 ${total} 部${noun} · ${active} 部进行中`;
    }
    return `共 ${total} 部${noun}`;
  }

  build() {
    NavDestination() {
      Column() {
        PageTopBar({
          title: this.kind === 'movie' ? '电影订阅' : '剧集订阅',
          onBack: (): void => {
            this.navStack.pop();
          }
        })
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
            Column({ space: 30 }) {
              if (this.loading) {
                Row({ space: 8 }) {
                  LoadingProgress().width(18).height(18).color(Theme.textMuted)
                  Text('正在加载…').fontSize(14).fontColor(Theme.textMuted)
                }
                .width('100%')
                .justifyContent(FlexAlign.Center)
                .padding({ top: 60 })
              } else if (this.failed && this.subs.length === 0) {
                Text('订阅列表加载失败')
                  .fontSize(15)
                  .fontColor(Theme.textMuted)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 60 })
              } else {
                Text(this.summary())
                  .fontSize(15)
                  .fontColor(Theme.textMuted)
                if (this.home().shelfSplit(this.kind).active.length > 0) {
                  this.Section('进行中', this.home().shelfSplit(this.kind).active)
                }
                if (this.home().shelfSplit(this.kind).paused.length > 0) {
                  this.Section('已暂停', this.home().shelfSplit(this.kind).paused)
                }
                if (this.home().shelfSplit(this.kind).done.length > 0) {
                  this.Section(this.kind === 'movie' ? '已入库' : '已收齐',
                    this.home().shelfSplit(this.kind).done)
                }
                AppFooter()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 4, bottom: Theme.tabBarInset })
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .edgeEffect(EdgeEffect.None)
        }
        .onRefreshing(() => {
          this.load().then((): void => {
            this.refreshing = false;
          });
        })
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      const params: SubscriptionWallParams | null = SubscriptionWallParams.of(ctx.pathInfo.param as Object | undefined);
      if (params !== null && !this.started) {
        this.started = true;
        this.kind = params.kind;
        this.load();
        this.loadNames();
      }
    })
  }

  @Builder
  Section(name: string, items: SubscriptionView[]) {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(name)
          .fontSize(20)
          .fontWeight(700)
          .fontColor(Theme.text)
        Text(`${items.length}`)
          .fontSize(15)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(items, (item: SubscriptionView) => {
          SubsPosterCard({
            home: this.home(),
            item: item,
            cardWidth: this.cardWidth(),
            flow: this.flow(item),
            dimsResting: false,
            onOpen: (sub: SubscriptionView): void => {
              this.navStack.pushPathByName('subscriptionDetail', new SubscriptionParams(sub.id));
            },
            onOpenMedia: (sub: SubscriptionView): void => {
              this.navStack.pushPathByName('discoverDetail',
                new DiscoverDetailParams(`tmdb:${sub.media.kind}:${sub.media.tmdb_id}`));
            }
          })
            .margin({ right: 12, bottom: 20 })
        }, (item: SubscriptionView) => `${item.id}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
