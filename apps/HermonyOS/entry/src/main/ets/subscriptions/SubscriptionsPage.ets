import { Theme } from '../theme/AppTheme';
import { SubscriptionParams } from './SubscriptionDetailPage';
import { AppModel } from '../common/AppModel';
import { ShellChrome } from '../common/ShellChrome';
import { Permissions } from '../common/Permissions';
import { Formatters } from '../common/Formatters';
import { RemoteImage } from '../common/RemoteImage';
import { ImmersiveHeroBackdrop } from '../common/ImmersiveHero';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  DownloadTaskListView,
  RecentArrivalView,
  SeasonOverview,
  SubscriptionView,
  TodayArrivalView
} from '../api/Models';
import { AppFooter } from '../common/AppFooter';
import { HeroSkeleton, SkeletonRow } from '../common/SkeletonBlock';
import { PlayerParams } from '../player/PlayerPage';
import { DiscoverDetailParams } from '../discover/DiscoverDetailPage';
import { CollectionMeta, ShelfSplit, ShelfStanding, SubsHome, ArrivalPresentation, arrivalPresentation, arrivalClockText } from './SubscriptionsHomeModel';
import {
  HeroGroup,
  HeroSlide,
  buildHeroSlides,
  heroGroups
} from './SubscriptionsHomeModel';
import { SubsPosterCard } from './SubsPosterCard';
import { SubscriptionWallParams } from './SubscriptionWallPage';

/**
 * 订阅页（对应 iOS 端 Features/Subscriptions/SubscriptionsView.swift 的「我的订阅」）。
 *
 * 版式按 iOS 的意图拆：**今天到达 → 最近入库 → 剧集订阅 / 电影订阅**（横滑海报，
 * 在追的在前）。iOS 那一版还有沉浸 Hero 轮播（366 行）与日程条，本轮先不做。
 *
 * 数据：`subscriptionsList` 拿清单，`subscriptionsListTodayArrivals` /
 * `subscriptionsListRecentArrivals` 拿到达；老版本服务端没有这两个接口时对应版块自动不出现
 * （和 iOS 一样，失败就静默收起，不打扰）。
 *
 * 轮询节奏照 iOS：整周预告 10 秒、刚刚入库 20 秒；退到后台不暂停这点两边一致（鸿蒙暂未接
 * 生命周期，见 docs/harmonyos-port.md 的待办）。
 */
/** 日程条的一天：相对站点日历「今天」的偏移 + 星期/日号 + 当天到达条数（同 iOS `SubsHomeScheduleDay`） */
class ScheduleDay {
  readonly daysAhead: number;
  readonly weekday: string;
  readonly dayNumber: number;
  readonly count: number;

  constructor(daysAhead: number, count: number, siteTodayMs: number) {
    this.daysAhead = daysAhead;
    this.count = count;
    // 站点日历口径：按 UTC 日切，不做本地时区换算（同 iOS `scheduleDays` 的 UTC calendar）
    const d: Date = new Date(siteTodayMs + daysAhead * 86400000);
    const names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    this.weekday = names[d.getUTCDay()];
    this.dayNumber = d.getUTCDate();
  }
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 集号 → 区间文案（同 iOS `TodayArrivals.episodeRanges`）：`E148–E150、E152` */
function episodeRanges(episodes: number[]): string {
  const unique: number[] = [];
  for (const episode of episodes) {
    if (unique.indexOf(episode) < 0) {
      unique.push(episode);
    }
  }
  unique.sort((a: number, b: number): number => a - b);
  const ranges: number[][] = [];
  for (const episode of unique) {
    if (ranges.length > 0 && episode === ranges[ranges.length - 1][1] + 1) {
      ranges[ranges.length - 1][1] = episode;
    } else {
      ranges.push([episode, episode]);
    }
  }
  return ranges.map((range: number[]): string => range[0] === range[1]
    ? `E${pad2(range[0])}` : `E${pad2(range[0])}–E${pad2(range[1])}`).join('、');
}

/** 当天议程的一项：同一部剧的多集并成一条（对应 iOS `ArrivalGroup`，按「订阅 + 日期」分组） */
class DayGroup {
  readonly subscriptionId: number;
  readonly title: string;
  readonly kind: string;
  /** 季号（出现顺序） */
  readonly seasons: number[] = [];
  /** 每个季对应的集号列表 */
  readonly episodes: number[][] = [];
  /** 组内原始到货行（用来算「最卡的那一步」的状态与时刻） */
  readonly arrivals: TodayArrivalView[] = [];
  count: number = 0;

  constructor(subscriptionId: number, title: string, kind: string) {
    this.subscriptionId = subscriptionId;
    this.title = title;
    this.kind = kind;
  }

  add(item: TodayArrivalView): void {
    this.arrivals.push(item);
    let at: number = this.seasons.indexOf(item.season_number);
    if (at < 0) {
      this.seasons.push(item.season_number);
      this.episodes.push([]);
      at = this.seasons.length - 1;
    }
    this.episodes[at].push(item.episode_number);
    this.count++;
  }

  /** 「S05E148–E150 · S06E01」；电影直接写「电影」（同 iOS `ArrivalGroup.episodeLabel`） */
  label(): string {
    if (this.kind === 'movie') {
      return '电影';
    }
    const order: number[] = [];
    for (let i = 0; i < this.seasons.length; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number): number => this.seasons[a] - this.seasons[b]);
    const parts: string[] = [];
    for (const i of order) {
      parts.push(`S${pad2(this.seasons[i])}${episodeRanges(this.episodes[i])}`);
    }
    return parts.join(' · ');
  }
}

@ComponentV2
export struct SubscriptionsPage {
  @Require @Param navStack: NavPathStack;

  @Local private subscriptions: SubscriptionView[] | null = null;
  @Local private failed: boolean = false;
  @Local private errorMessage: string = '';
  @Local private today: TodayArrivalView[] = [];
  @Local private recent: RecentArrivalView[] = [];
  @Local private refreshing: boolean = false;
  /** 日程条当前选中的偏移天数（0 = 今天） */
  @Local private selectedDay: number = 0;
  /** Hero 高度：iOS 固定 500（比发现页的 520 略低，好露出下一块的标题），这里按屏高封顶 */
  /** 与条目详情同款高度（iOS 两处都是 min(屏宽×1.15, 屏高×0.62)） */
  private heroHeight: number = Theme.heroHeight;

  /** Hero 轮播（iOS 的订阅 Hero 是**居中**版式：片名 Logo 居中、大号时刻、指示器居中） */
  @Local heroIndex: number = 0;
  @Local heroFill: number = 0;
  private heroController: SwiperController = new SwiperController();
  private heroTimer: number = -1;
  private arrivalsTimer: number = -1;
  private recentTimer: number = -1;
  private tasksTimer: number = -1;
  private started: boolean = false;
  /** info_hash(小写) → 下载器 ETA 秒数（日程左列「预计时间」用；同 iOS 的 tasks 轮询） */
  @Local private taskEtas: Record<string, number> = {};

  aboutToAppear(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.reload();
    // 轮询节奏与 iOS 一致
    this.arrivalsTimer = setInterval((): void => {
      this.loadToday();
    }, 10000);
    this.recentTimer = setInterval((): void => {
      this.loadRecent();
    }, 20000);
    this.tasksTimer = setInterval((): void => {
      this.loadTasks();
    }, 10000);
    this.loadTasks();
    this.startHeroRotation();
  }

  /** Hero 轮播：8 秒一页，指示器当前格在这 8 秒里填满（与发现页同一套节奏） */
  private startHeroRotation(): void {
    if (this.heroTimer >= 0) {
      return;
    }
    this.heroTimer = setInterval((): void => {
      const count: number = this.heroSlides().length;
      if (count <= 1) {
        return;
      }
      this.heroFill += 0.0125;
      if (this.heroFill >= 1) {
        this.heroFill = 0;
        this.heroIndex = (this.heroIndex + 1) % count;
        this.heroController.changeIndex(this.heroIndex);
      }
    }, 100);
  }

  aboutToDisappear(): void {
    if (this.heroTimer >= 0) {
      clearInterval(this.heroTimer);
      this.heroTimer = -1;
    }
    if (this.arrivalsTimer >= 0) {
      clearInterval(this.arrivalsTimer);
      this.arrivalsTimer = -1;
    }
    if (this.recentTimer >= 0) {
      clearInterval(this.recentTimer);
      this.recentTimer = -1;
    }
    if (this.tasksTimer >= 0) {
      clearInterval(this.tasksTimer);
      this.tasksTimer = -1;
    }
  }

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  private canSubscribe(): boolean {
    return Permissions.fromSession(AppModel.shared.session).canSubscribe;
  }

  // MARK: 取数

  private async reload(): Promise<void> {
    await this.loadSubscriptions();
    if (this.subscriptions === null || this.subscriptions.length === 0) {
      return;
    }
    await this.loadToday();
    await this.loadRecent();
  }

  private async loadSubscriptions(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.subscriptions = await api.subscriptionsList();
      this.failed = false;
      this.errorMessage = '';
    } catch (error) {
      if (this.subscriptions === null) {
        this.failed = true;
        this.errorMessage = this.messageOf(error);
      }
    }
  }

  /** 今天（含未来一周）的到达预告；接口不存在或出错就静默收起 */
  private async loadToday(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const list: TodayArrivalView[] = await api.subscriptionsListTodayArrivals('week');
      this.today = list;
    } catch (error) {
      // 老服务端没有这个接口：保持空，版块自动不出现（同 iOS）
    }
  }

  /** 刚刚入库：看完即消失的那一条，取最近 7 天 */
  private async loadRecent(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      const list: RecentArrivalView[] = await api.subscriptionsListRecentArrivals(7, 20);
      this.recent = list;
    } catch (error) {
      // 同上
    }
  }

  /** 下载器任务快照：取每个在途种子的 ETA，供日程左列算「预计入库时刻」（同 iOS 的 tasks 轮询，仅管理员） */
  private async loadTasks(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null || !Permissions.fromSession(AppModel.shared.session).isAdmin) {
      return;
    }
    try {
      const view: DownloadTaskListView = await api.dlTasks();
      const map: Record<string, number> = {};
      for (const task of view.items) {
        const eta: number | null = task.eta_seconds ?? null;
        if (eta !== null) {
          map[task.info_hash.toLowerCase()] = eta;
        }
      }
      this.taskEtas = map;
    } catch (error) {
      // 拿不到就退回「时间待更新」
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '加载失败';
  }

  // MARK: 派生

  /** 首页判定逻辑（对应 iOS `SubscriptionsHomeModel`）：横滑行与海报墙页共用同一份结果 */
  private home(): SubsHome {
    return new SubsHome(this.subscriptions ?? [], this.today, this.recent);
  }

  private hasAny(): boolean {
    return this.subscriptions !== null && this.subscriptions.length > 0;
  }

  // MARK: 动作

  private openDetail(item: SubscriptionView): void {
    this.navStack.pushPathByName('subscriptionDetail', new SubscriptionParams(item.id));
  }

  /** 压栈到完整海报墙（标题「›」与「查看全部」共用，同 iOS `AppRoute.subscriptionWall`） */
  private openWall(kind: string): void {
    this.navStack.pushPathByName('subscriptionWall', new SubscriptionWallParams(kind));
  }

  /** 查看影片详情（长按菜单，同 iOS `.mediaDetail(titleRef:)`） */
  private openMedia(kind: string, tmdbId: number): void {
    this.navStack.pushPathByName('discoverDetail', new DiscoverDetailParams(`tmdb:${kind}:${tmdbId}`));
  }

  /** 没有订阅时引导去发现页找片（同 iOS：切到发现页签） */
  private goDiscover(): void {
    ShellChrome.openTab('discover');
  }

  // MARK: 视图

  build() {
    // 根是普通容器（不再是 NavDestination）：订阅首页由 SubscriptionsNavHost 直接
    // 铺在页签里（沉浸式头图要钻进状态栏，不能被 Navigation 的避让 padding 裹住），
    // 二级页才走 Navigation。本页只借 navStack 往外 push，不需要 NavDestination 的能力。
    Column() {
      if (this.failed) {
        this.ErrorState()
      } else if (this.subscriptions === null) {
        this.LoadingState()
      } else if (!this.hasAny()) {
        this.EmptyState()
      } else {
        this.Content()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }

  @Builder
  LoadingState() {
    // 加载骨架（逐值照 iOS `loadingSkeleton`）：Hero 骨架 + 「刚刚入库」「剧集订阅」两行
    Column({ space: 28 }) {
      HeroSkeleton({ blockHeight: this.heroHeight })
      SkeletonRow({ title: '刚刚入库' })
      SkeletonRow({ title: '剧集订阅' })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 0, bottom: Theme.tabBarInset })
  }

  @Builder
  ErrorState() {
    Column({ space: 12 }) {
      Text('订阅列表加载失败')
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
          this.subscriptions = null;
          this.reload();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyState() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.bookmark'))
        .fontSize(34)
        .fontColor([Theme.textFaint])
      Text('从一部想看的作品开始')
        .fontSize(17)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text(this.canSubscribe()
        ? '去发现页挑选一部剧集或电影，打开详情并点击「订阅追踪」，有合适资源时会自动下载入库。'
        : '当前账号暂未开启订阅权限，请联系管理员为你开启。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      if (this.canSubscribe()) {
        Text('去发现剧集')
          .fontSize(14)
          .fontWeight(600)
          .fontColor('#0b0d12')
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor(Theme.accent)
          .borderRadius(20)
          .margin({ top: 6 })
          .onClick(() => {
            this.goDiscover();
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  Content() {
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: 36 }) {
          if (this.heroSlides().length > 0) {
            this.Hero()
          }
          if (this.recent.length > 0) {
            this.RecentRow()
          }
          if (this.today.length > 0) {
            this.ScheduleRow()
          }
          if (this.home().shelfSplit('tv').active.length + this.home().shelfSplit('tv').resting.length > 0) {
            this.ShelfRow('剧集订阅', 'tv')
          }
          if (this.home().shelfSplit('movie').active.length + this.home().shelfSplit('movie').resting.length > 0) {
            this.ShelfRow('电影订阅', 'movie')
          }
          AppFooter()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 4, bottom: Theme.tabBarInset })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.None)
    }
    .onRefreshing(() => {
      this.reload().then((): void => {
        this.refreshing = false;
      });
    })
    .width('100%')
    .height('100%')
  }

  /**
   * Hero 的几张：照 iOS `SubscriptionsHome.heroSlides` ——
   * 正在发生的（整理中优先于下载中）→ 刚到（≤48h）→ 今天更新 → 更早的入库 → 最近的预告；
   * 一部作品只占一张、上限 5；全空时退回「在追的前 3 部」。
   */
  private heroSlides(): HeroSlide[] {
    const subs: SubscriptionView[] = this.subscriptions ?? [];
    const groups: HeroGroup[] = heroGroups(this.today, subs, this.taskEtas, Date.now());
    return buildHeroSlides(subs, groups, this.recent, Date.now());
  }

  /**
   * 沉浸 Hero（对应 iOS `SubsHomeHero`）。
   *
   * **和发现页的 Hero 是两种版式**（iOS 源码注释里明确区分）：发现页是「编辑推荐」——
   * 文字左对齐、指示器靠右下；订阅页是「时间驱动」——**片名 Logo 居中、大号细体时刻、
   * 指示器居中**。高度也略低（500 对 520），好让首屏底部露出下一块的标题。
   */
  @Builder
  Hero() {
    Stack({ alignContent: Alignment.Bottom }) {
      Swiper(this.heroController) {
        ForEach(this.heroSlides(), (slide: HeroSlide) => {
          Stack({ alignContent: Alignment.Bottom }) {
            // 与条目详情**共用同一份底图实现**（common/ImmersiveHero.ets）
            ImmersiveHeroBackdrop(this.heroImage(slide), this.heroHeight)
            this.HeroSlideContent(slide)
          }
          .width('100%')
          .height('100%')
                    .onClick(() => {
            this.openDetailById(slide.subscriptionId);
          })
        }, (slide: HeroSlide) => `${slide.subscriptionId}`)
      }
      .autoPlay(false)
      .loop(true)
      .indicator(false)
            .width('100%')
      .height('100%')
      .onChange((index: number): void => {
        this.heroIndex = index;
        this.heroFill = 0;
      })

      if (this.heroSlides().length > 1) {
        this.HeroIndicator()
      }
    }
    .width('100%')
    .height(this.heroHeight)
      }

  /** Hero 一页的内容：居中 Logo（没有就写片名）+ 状态行 + 大号时刻 */
  @Builder
  HeroSlideContent(slide: HeroSlide) {
    Column({ space: 0 }) {
      Blank()
      if (this.logoUrl(slide).length > 0) {
        /*
         * 片名 Logo 的尺寸。
         *
         * **用写死的宽高，不用 `constraintSize`**：`constraintSize` 加在自定义组件上不生效
         * （实测：给了 maxWidth 240，Logo 仍然撑满整行内容宽 ≈282vp，看着偏大）。
         * 尺寸按 iOS 的比例定：iOS 是 `maxWidth 240 / maxHeight 88`（pt），
         * 占 393pt 屏宽的 61%；本机 330vp 宽 → 200vp。
         * `fit: true`（Contain）保住 Logo 自身比例，竖版 Logo 自然缩窄。
         */
        RemoteImage({ url: this.logoUrl(slide), fit: true })
          .width(200)
          .height(72)
      } else {
        Text(slide.media.title)
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text)
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // 有时刻：小字（保留结尾）+ 大号细体时刻；没时刻：说明 + 补充行（同 iOS `content`）
      if (slide.clock.length > 0) {
        this.HeroStatusLine(slide, slide.clockLabel)
        Text(slide.clock)
          .fontSize(this.heroClockIsNumeric(slide) ? 48 : 36)
          .fontWeight(this.heroClockIsNumeric(slide) ? FontWeight.Lighter : FontWeight.Normal)
          .fontColor(Theme.text)
          .maxLines(1)
          .margin({ top: 2 })
      } else {
        this.HeroStatusLine(slide, slide.detail)
        if (slide.footnote.length > 0) {
          Text(slide.footnote)
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.6)')
            .maxLines(2)
            .textAlign(TextAlign.Center)
            .margin({ top: 6 })
        }
      }
      // 下载中的细进度线（同 iOS `SubsHomeProgressLine(value:tint: live)`，宽 168）
      if (slide.progress > 0) {
        Row() {
          Row()
            .width(`${Math.round(slide.progress * 100)}%`)
            .height('100%')
            .backgroundColor('#7fb0ff')
        }
        .width(168)
        .height(2.5)
        .backgroundColor('rgba(255,255,255,0.2)')
        .borderRadius(2)
        .clip(true)
        .margin({ top: 12 })
      }
      // 主按钮（同 iOS `primaryButton`）：有刚入库的可播，否则「查看订阅」
      if (slide.playable) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.play_fill'))
            .fontSize(13)
            .fontColor(['#0b0d12'])
          Text(slide.resumePercent > 0 ? '继续播放' : '播放')
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#0b0d12')
        }
        .padding({ left: 20, right: 20, top: 9, bottom: 9 })
        .backgroundColor('#ffffff')
        .borderRadius(20)
        .margin({ top: 20 })
        .onClick(() => {
          this.playHero(slide);
        })
      } else {
        Text('查看订阅')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .backgroundColor('rgba(255,255,255,0.16)')
          .borderRadius(20)
          .border({ width: 1, color: 'rgba(255,255,255,0.2)' })
          .margin({ top: 20 })
          .onClick(() => {
            this.openDetailById(slide.subscriptionId);
          })
      }
      Blank()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24, bottom: 56 })
      }

  /** Hero 状态行：状态点（eyebrow.tone）+ 一句说明（同 iOS `statusLine`） */
  @Builder
  HeroStatusLine(slide: HeroSlide, text: string) {
    Row({ space: 7 }) {
      if (slide.eyebrowTone.length > 0) {
        Circle()
          .width(7)
          .height(7)
          .fill(slide.eyebrowTone)
      }
      if (text.length > 0) {
        Text(text)
          .fontSize(15)
          .fontWeight(600)
          .fontColor('rgba(255,255,255,0.9)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .margin({ top: 16 })
  }

  /** Hero 居中指示器（与发现页的右下角不同） */
  @Builder
  HeroIndicator() {
    Row({ space: 6 }) {
      ForEach(this.heroSlides(), (slide: HeroSlide, index: number) => {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(255,255,255,0.3)')
            .borderRadius(2)
          if (index === this.heroIndex) {
            Row()
              .width(`${Math.round(this.heroFill * 100)}%`)
              .height('100%')
              .backgroundColor(Theme.text)
              .borderRadius(2)
          }
        }
        .width(index === this.heroIndex ? 24 : 12)
        .height(4)
      }, (slide: HeroSlide) => `${slide.subscriptionId}`)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .margin({ bottom: 16 })
  }

  private heroImage(slide: HeroSlide): string {
    const raw: string | null = slide.media.backdrop_url
      ?? slide.media.poster_url ?? null;
    // **不传派生变体**：iOS 这边取的是原图（`originalTMDBImageURL(backdropUrl) ?? api.image(posterUrl)`），
    // 传 `landscapeCard` 会让后端把竖版海报按横版裁切，取景就和条目详情页不一致了
    return ImageUrls.resolve(AppModel.origin(), raw, null) ?? '';
  }

  /**
   * 片名 Logo 的地址。
   *
   * **不传变体**：`landscapeCard` 这类派生会按横版裁切/加底，而片名 Logo 常见**竖版**
   * （例如《仙逆》是 161×270）且靠透明通道叠在剧照上。传了变体就会渲染成一块**不透明的深色方块**
   * 糊在 hero 正中——实测踩过。iOS 那边也是不带变体取的（`api.image(logo)`）。
   */
  private logoUrl(slide: HeroSlide): string {
    const raw: string | null = slide.media.logo_url ?? null;
    return ImageUrls.resolve(AppModel.origin(), raw, null) ?? '';
  }

  /** 状态行文案：电影说「已入库」等，剧集说「第 N 季 · 下一集 SxxExx」 */
  /** 时刻里有没有数字（有 = 48 thin，纯中文词 = 36 light，同 iOS） */
  private heroClockIsNumeric(slide: HeroSlide): boolean {
    for (let i = 0; i < slide.clock.length; i++) {
      const code: number = slide.clock.charCodeAt(i);
      if (code >= 48 && code <= 57) {
        return true;
      }
    }
    return false;
  }

  /** 播放：入口是这一批里第一个没看完的单元（同 iOS `playRequest`） */
  private playHero(slide: HeroSlide): void {
    const recent: RecentArrivalView | null = this.home().recentOf(slide.subscriptionId);
    if (recent === null) {
      this.openDetailById(slide.subscriptionId);
      return;
    }
    const isTV: boolean = slide.media.kind === 'tv';
    this.navStack.pushPathByName('player', new PlayerParams(
      recent.media.media_item_id, 0, isTV ? recent.season_number : 0, isTV ? recent.episode_number : 0));
  }


  /** 当天议程：按订阅合并——同一部剧的多集并成一条，保留首次出现顺序（同 iOS `arrivalGroups` 的分组口径） */
  private dayGroups(daysAhead: number): DayGroup[] {
    const out: DayGroup[] = [];
    const ids: number[] = [];
    for (const item of this.today) {
      if (item.days_ahead !== daysAhead) {
        continue;
      }
      let at: number = ids.indexOf(item.subscription_id);
      if (at < 0) {
        ids.push(item.subscription_id);
        out.push(new DayGroup(item.subscription_id, item.media_title, item.media_kind));
        at = out.length - 1;
      }
      out[at].add(item);
    }
    // 排序同 iOS：正在发生的（下载中 / 整理中）在前，其余按预计时刻从早到晚
    out.sort((a: DayGroup, b: DayGroup): number => {
      const pa: ArrivalPresentation = this.groupPresentation(a);
      const pb: ArrivalPresentation = this.groupPresentation(b);
      if (pa.glows() !== pb.glows()) {
        return pa.glows() ? -1 : 1;
      }
      const ta: number = pa.estimatedAt > 0 ? pa.estimatedAt : Number.MAX_SAFE_INTEGER;
      const tb: number = pb.estimatedAt > 0 ? pb.estimatedAt : Number.MAX_SAFE_INTEGER;
      return ta - tb;
    });
    return out;
  }

  /** 组内「最卡的那一步」的状态与时刻（同 iOS 取 blocking presentation） */
  private groupPresentation(group: DayGroup): ArrivalPresentation {
    const now: number = Date.now();
    let blocking: ArrivalPresentation | null = null;
    for (const item of group.arrivals) {
      const pres: ArrivalPresentation = arrivalPresentation(item, this.etaFor(item), now);
      if (blocking === null) {
        blocking = pres;
      } else if (pres.stageOrder() !== blocking.stageOrder()) {
        blocking = pres.stageOrder() > blocking.stageOrder() ? pres : blocking;
      } else if (pres.estimatedAt > blocking.estimatedAt) {
        blocking = pres;
      }
    }
    return blocking === null ? new ArrivalPresentation('预计入库', '', 0) : blocking;
  }

  private etaFor(item: TodayArrivalView): number | null {
    const hash: string | null = item.info_hash ?? null;
    if (hash === null || hash.length === 0) {
      return null;
    }
    const value: number | undefined = this.taskEtas[hash.toLowerCase()];
    return value === undefined ? null : value;
  }

  /** 议程行左侧的紧凑时刻：整理中→「即将」、下载中无 ETA→「稍后」、有预计→HH:mm、否则「待定」 */
  private groupTime(group: DayGroup): string {
    const pres: ArrivalPresentation = this.groupPresentation(group);
    if (pres.statusLabel === '整理中') {
      return '即将';
    }
    if (pres.statusLabel === '下载中' && pres.estimatedAt <= 0) {
      return '稍后';
    }
    return pres.estimatedAt > 0 ? arrivalClockText(pres.estimatedAt) : '待定';
  }

  /** 站点日历的「今天」00:00（UTC）：由任一到达的 expected_day 减 days_ahead 反推（同 iOS `scheduleDays`） */
  private siteTodayMs(): number {
    const first: TodayArrivalView | null = this.today.length > 0 ? this.today[0] : null;
    if (first === null) {
      return 0;
    }
    const anchor: number | null = Formatters.date(first.expected_day);
    if (anchor === null) {
      return 0;
    }
    return anchor - first.days_ahead * 86400000;
  }

  /** 日程条的一天：条数按「合并后的条数」算（同 iOS `day.entries.count`） */
  private scheduleDays(): ScheduleDay[] {
    const out: ScheduleDay[] = [];
    const today: number = this.siteTodayMs();
    for (let d = 0; d < 7; d++) {
      out.push(new ScheduleDay(d, this.dayGroups(d).length, today));
    }
    return out;
  }

  /** 某订阅的横版缩略图（日程议程用；回查订阅清单里的媒体） */
  private arrivalThumbById(subscriptionId: number): string {
    const list: SubscriptionView[] = this.subscriptions ?? [];
    for (const sub of list) {
      if (sub.id === subscriptionId) {
        const raw: string | null = sub.media.backdrop_url ?? sub.media.poster_url ?? null;
        return ImageUrls.resolve(AppModel.origin(), raw, ImageVariant.landscapeCard) ?? '';
      }
    }
    return '';
  }

  private openDetailById(id: number): void {
    this.navStack.pushPathByName('subscriptionDetail', new SubscriptionParams(id));
  }

  @Builder
  ScheduleRow() {
    Column({ space: 12 }) {
      this.SectionTitle('日程', this.dayGroups(this.selectedDay).length > 0
        ? `${this.dayGroups(this.selectedDay).length} 部` : '')
      // 日期条
      Scroll() {
        Row({ space: 10 }) {
          ForEach(this.scheduleDays(), (day: ScheduleDay) => {
            Column({ space: 5 }) {
              Text(day.daysAhead === 0 ? '今天' : day.weekday)
                .fontSize(11)
                .fontColor(day.daysAhead === this.selectedDay ? 'rgba(0,0,0,0.6)' : Theme.textFaint)
              Text(`${day.dayNumber}`)
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(day.daysAhead === this.selectedDay ? '#0b0d12' : Theme.text)
              Row({ space: 3 }) {
                if (day.count === 0) {
                  Circle().width(4).height(4).fill('rgba(255,255,255,0.15)')
                } else {
                  Circle().width(4).height(4)
                    .fill(day.daysAhead === this.selectedDay ? '#0b0d12' : Theme.accent2)
                }
              }
              .height(4)
            }
            .width(52)
            .padding({ top: 8, bottom: 8 })
            .backgroundColor(day.daysAhead === this.selectedDay ? Theme.text : 'rgba(255,255,255,0.06)')
            .borderRadius(Theme.cardRadius)
            .onClick(() => {
              this.selectedDay = day.daysAhead;
            })
          }, (day: ScheduleDay) => `${day.daysAhead}`)
        }
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // 当天议程（同一部剧的多集并成一条）
      // 横向留白加在区块级（卡片自身不带 margin）：卡片内的行用 width('100%')，
      // 若同时挂 margin，百分比会按屏幕宽解析、顶出右缘（见 subscription-refactor-plan.md §3.1）
      Column() {
        Column({ space: 0 }) {
          if (this.dayGroups(this.selectedDay).length === 0) {
            Text('这一天没有排定的到达')
              .fontSize(13)
              .fontColor(Theme.textFaint)
              .padding({ left: 16, right: 16, top: 16, bottom: 16 })
              .width('100%')
          }
          ForEach(this.dayGroups(this.selectedDay), (group: DayGroup, idx: number) => {
            Row({ space: 12 }) {
              // 左列：预计时刻（大号）+ 状态点与状态词（对齐 iOS `SubsHomeAgendaRow`）
              Column({ space: 3 }) {
                Text(this.groupTime(group))
                  .fontSize(20)
                  .fontWeight(this.groupPresentation(group).estimatedAt > 0
                    || this.groupPresentation(group).statusLabel === '整理中'
                    || this.groupPresentation(group).statusLabel === '下载中'
                    ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.groupTime(group) === '待定' ? Theme.textFaint : Theme.text)
                  .maxLines(1)
                Row({ space: 4 }) {
                  Circle()
                    .width(5)
                    .height(5)
                    .fill(this.groupPresentation(group).toneColor())
                  Text(this.groupPresentation(group).statusLabel)
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.groupPresentation(group).toneColor())
                    .maxLines(1)
                }
              }
              .width(62)
              .alignItems(HorizontalAlign.Start)
              RemoteImage({ url: this.arrivalThumbById(group.subscriptionId) })
                .width(92)
                .aspectRatio(16 / 9)
                .backgroundColor(Theme.surface)
                .borderRadius(8)
                .clip(true)
              Column({ space: 3 }) {
                Text(group.title)
                  .fontSize(15)
                  .fontWeight(600)
                  .fontColor(Theme.text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(group.label())
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(12)
                .fontColor([Theme.textFaint])
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.openDetailById(group.subscriptionId);
            })
            if (idx < this.dayGroups(this.selectedDay).length - 1) {
              Divider().color(Theme.line).margin({ left: 86 })
            }
          }, (item: TodayArrivalView) => `${item.subscription_id}-${item.wanted_id}`)
        }
        .width('100%')
        .backgroundColor(Theme.surface)
        .borderRadius(Theme.cardRadius)
        .border({ width: 1, color: Theme.line })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** 刚刚入库：16:9 剧照横滑，点了进媒体库的条目页 */
  @Builder
  RecentRow() {
    Column({ space: 10 }) {
      this.SectionTitle('刚刚入库', this.recent.length > 1 ? `${this.recent.length} 部` : '')
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.recent, (item: RecentArrivalView) => {
            Column({ space: 6 }) {
              Stack({ alignContent: Alignment.BottomEnd }) {
                RemoteImage({
                  url: ImageUrls.resolve(AppModel.origin(), item.still_url ?? item.media.poster_url,
                    ImageVariant.landscapeCard) ?? ''
                })
                  .width('100%')
                  .height('100%')
                // 左下角片名 Logo（没有就不画，片名在卡片下面）
                if (this.recentLogo(item).length > 0) {
                  Stack({ alignContent: Alignment.BottomStart }) {
                    RemoteImage({ url: this.recentLogo(item), fit: true })
                      .width('62%')
                      .height(34)
                  }
                  .width('100%')
                  .height('100%')
                  .padding({ left: 12, bottom: 12 })
                }
                // 左上角「新 N 集」chip（整批多于 1 集）
                if (item.units.length > 1) {
                  Stack({ alignContent: Alignment.TopStart }) {
                    Text(`新 ${item.units.length} 集`)
                      .fontSize(10)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.ok)
                      .padding({ left: 7, right: 7, top: 4, bottom: 4 })
                      .backgroundColor('rgba(0,0,0,0.42)')
                      .borderRadius(10)
                  }
                  .width('100%')
                  .height('100%')
                  .padding(9)
                }
                // 右下角播放角标
                Stack({ alignContent: Alignment.BottomEnd }) {
                  SymbolGlyph($r('sys.symbol.play_fill'))
                    .fontSize(13)
                    .fontColor([Theme.text])
                    .width(32)
                    .height(32)
                    .backgroundColor('rgba(0,0,0,0.42)')
                    .borderRadius(16)
                }
                .width('100%')
                .height('100%')
                .padding(10)
                // 底部续播进度（看了一半才有）
                if ((item.progress_percent ?? 0) > 0) {
                  Stack({ alignContent: Alignment.Bottom }) {
                    Row() {
                      Row()
                        .width(`${item.progress_percent ?? 0}%`)
                        .height('100%')
                        .backgroundColor(Theme.ok)
                    }
                    .width('100%')
                    .height(3)
                    .backgroundColor('rgba(255,255,255,0.22)')
                  }
                  .width('100%')
                  .height('100%')
                }
              }
              .width('100%')
              .aspectRatio(16 / 9)
              .backgroundColor(Theme.surface)
              .borderRadius(Theme.cardRadius)
              .clip(true)
              .onClick(() => {
                this.playRecent(item);
              })
              .bindContextMenu(this.RecentMenu(item), ResponseType.LongPress)

              Text(item.media.title)
                .fontSize(15)
                .fontWeight(600)
                .fontColor(Theme.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.recentLabel(item))
                .fontSize(13)
                .fontColor(Theme.textFaint)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.recentNote(item).length > 0) {
                Text(this.recentNote(item))
                  .fontSize(12)
                  .fontColor(Theme.textFaint)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .width(180)
            .alignItems(HorizontalAlign.Start)
          }, (item: RecentArrivalView) => `${item.subscription_id}-${item.media.media_item_id}-${item.season_number}-${item.episode_number}`)
        }
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 卡片左下角的片名 Logo 地址（没有就返回空，回退到卡片下方文字片名） */
  private recentLogo(item: RecentArrivalView): string {
    const raw: string | null = item.media.logo_url ?? null;
    return ImageUrls.resolve(AppModel.origin(), raw, null) ?? '';
  }

  /** 点「刚刚入库」直接起播（入口是这一批里第一个没看完的单元，同 iOS `playRequest`） */
  private playRecent(item: RecentArrivalView): void {
    const isTV: boolean = item.media.kind === 'tv';
    this.navStack.pushPathByName('player', new PlayerParams(
      item.media.media_item_id, 0, isTV ? item.season_number : 0, isTV ? item.episode_number : 0));
  }

  /** 「刚刚入库」卡的长按菜单（同 iOS `contextMenu`）：播放 / 查看订阅详情 / 查看影片详情 */
  @Builder
  RecentMenu(item: RecentArrivalView) {
    Menu() {
      MenuItem({ content: '播放', startIcon: $r('sys.symbol.play_fill') })
        .onClick(() => {
          this.playRecent(item);
        })
      MenuItem({ content: '查看订阅详情', startIcon: $r('sys.symbol.rectangle_stack') })
        .onClick(() => {
          this.openDetailById(item.subscription_id);
        })
      MenuItem({ content: '查看影片详情', startIcon: $r('sys.symbol.film') })
        .onClick(() => {
          this.openMedia(item.media.kind, item.media.tmdb_id);
        })
    }
  }

  private recentLabel(item: RecentArrivalView): string {
    if (item.media.kind !== 'tv') {
      const year: number | null = item.media.year ?? null;
      return year !== null && year > 0 ? `${year}  ·  电影` : '电影';
    }
    const name: string = item.episode_name ?? '';
    const code: string = `S${this.pad(item.season_number)}E${this.pad(item.episode_number)}`;
    return name.length > 0 ? `${code}  ·  ${name}` : code;
  }

  /** 「刚刚入库」第三行（对应 iOS `SubsHomeRecentCard.note`）：什么时候到的、这一批还有几集、看到哪了 */
  private recentNote(item: RecentArrivalView): string {
    const parts: string[] = [];
    const importedMs: number | null = Formatters.date(item.imported_at);
    if (importedMs !== null) {
      parts.push(`${Formatters.fromNow(importedMs)}入库`);
    }
    if (item.units.length > 1) {
      parts.push(`共 ${item.units.length} 集新内容`);
    }
    const percent: number | null = item.progress_percent ?? null;
    if (percent !== null && percent > 0) {
      parts.push(`看到 ${percent}%`);
    }
    return parts.join('  ·  ');
  }

  /** 海报行（对应 iOS `SubsHomeShelfRow`）：进行中在前，暂停/已收齐压暗排在竖排小字分隔线后面 */
  @Builder
  ShelfRow(title: string, kind: string) {
    Column({ space: 10 }) {
      // 标题可点：「›」压栈到完整海报墙（同 iOS）
      Row({ space: 5 }) {
        Text(title)
          .fontSize(20)
          .fontWeight(700)
          .fontColor(Theme.text)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor([Theme.textFaint])
        Blank()
        Text(this.home().countSummary(kind))
          .fontSize(13)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      .onClick(() => {
        this.openWall(kind);
      })
      Scroll() {
        Row({ space: 12 }) {
          ForEach(this.rowActive(kind), (item: SubscriptionView) => {
            SubsPosterCard({
              home: this.home(), item: item, onOpen: (sub: SubscriptionView): void => {
                this.openDetail(sub);
              }, onOpenMedia: (sub: SubscriptionView): void => {
                this.openMedia(sub.media.kind, sub.media.tmdb_id);
              }
            })
          }, (item: SubscriptionView) => `${item.id}`)
          if (this.rowResting(kind).length > 0) {
            this.RestingDivider(this.home().restingLabel(kind))
            ForEach(this.rowResting(kind), (item: SubscriptionView) => {
              SubsPosterCard({
                home: this.home(), item: item, onOpen: (sub: SubscriptionView): void => {
                  this.openDetail(sub);
                }, onOpenMedia: (sub: SubscriptionView): void => {
                  this.openMedia(sub.media.kind, sub.media.tmdb_id);
                }
              })
            }, (item: SubscriptionView) => `${item.id}`)
          }
          if (this.rowHidden(kind) > 0) {
            this.SeeAllCard(kind)
          }
        }
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
        .alignItems(VerticalAlign.Top)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 横滑最多 20 张（同 iOS `limit`）：一排是浏览亮点的地方，其余在墙里 */
  private rowActive(kind: string): SubscriptionView[] {
    return this.home().shelfSplit(kind).active.slice(0, 20);
  }

  private rowResting(kind: string): SubscriptionView[] {
    const shown: number = this.rowActive(kind).length;
    const room: number = shown >= 20 ? 0 : 20 - shown;
    return this.home().shelfSplit(kind).resting.slice(0, room);
  }

  private rowHidden(kind: string): number {
    const all: number = this.home().shelfSplit(kind).all().length;
    return all - this.rowActive(kind).length - this.rowResting(kind).length;
  }

  /** 横滑末尾的「查看全部」：与海报同宽，点了进海报墙（同 iOS `SubsHomeSeeAllCard`） */
  @Builder
  SeeAllCard(kind: string) {
    Column({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(22)
        .fontColor([Theme.textMuted])
      Text('查看全部')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
      Text(`${this.home().shelfSplit(kind).all().length} 部`)
        .fontSize(11)
        .fontColor(Theme.textFaint)
    }
    .width(110)
    .aspectRatio(Theme.posterAspect)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(255,255,255,0.045)')
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .onClick(() => {
      this.openWall(kind);
    })
  }

  /** 在追与歇着之间的分隔：竖排小字（中文竖排天然成立，不用旋转） */
  @Builder
  RestingDivider(label: string) {
    Column({ space: 8 }) {
      Divider().vertical(true).height(40).color(Theme.line)
      Text(label.split('').join('\n'))
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
        .lineHeight(11)
      Divider().vertical(true).height(40).color(Theme.line)
    }
    .width(18)
    .height(165)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  SectionTitle(title: string, trailing: string) {
    Row() {
      Text(title)
        .fontSize(19)
        .fontWeight(600)
        .fontColor(Theme.text)
      Blank()
      Text(trailing)
        .fontSize(12)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
  }
}
