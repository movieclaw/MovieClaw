import { Theme } from '../theme/AppTheme';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import { MemberView, MediaActivityTarget, PlaybackStatsDayRow, PlaybackStatsTitleRow, PlaybackWatchStatsView } from '../api/Models';

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function ActivityStatsBuilder() {
  ActivityStatsPage()
}

/** 趋势图里的一根柱：当前周期值 + 上周期同位置的值（虚线对比用） */
class TrendBucket {
  readonly label: string;
  readonly currentMs: number;
  readonly previousMs: number;

  constructor(label: string, currentMs: number, previousMs: number) {
    this.label = label;
    this.currentMs = currentMs;
    this.previousMs = previousMs;
  }
}

/**
 * 观看统计二级页（对齐 iOS `ActivityPages.ActivityWatchPage` + `WatchStatsPanel`）。
 *
 * 自上而下：周期/成员/范围筛选 → 四张指标卡（较上期变化）→ 最受欢迎 TOP3 →
 * 趋势图（本期实心柱 + 上期对照）→ 四个分解面板（按成员/按客户端/看得最多/按播放方式）→
 * 时段热力图（7×24）。数据 `GET /playback/stats/watch`，当前周期与上一周期成对返回。
 */
@ComponentV2
export struct ActivityStatsPage {
  private navStack: NavPathStack = new NavPathStack();
  @Local private days: number = 7;
  @Local private memberId: number = -1;
  @Local private scope: string = 'visible';
  @Local private members: MemberView[] = [];
  @Local private stats: PlaybackWatchStatsView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  /** 「看得最多」默认收起，点开展开全部（对应 iOS fold=.expand） */
  @Local private titlesExpanded: boolean = false;
  private started: boolean = false;

  private api(): MovieClawApi | null {
    return AppModel.shared.api;
  }

  // MARK: 取数

  private async loadMembers(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    try {
      this.members = await api.membersList();
    } catch (error) {
      this.members = [];
    }
  }

  private async load(): Promise<void> {
    const api: MovieClawApi | null = this.api();
    if (api === null) {
      return;
    }
    this.loading = this.stats === null;
    this.errorMessage = '';
    try {
      // tz_offset：本地时区相对 UTC 的分钟数（东八区 480），getTimezoneOffset 是反号
      const tzOffset: number = -new Date().getTimezoneOffset();
      this.stats = await api.playbackStatsWatch(this.days, tzOffset,
        this.memberId >= 0 ? this.memberId : undefined, this.scope);
    } catch (error) {
      this.stats = null;
      this.errorMessage = this.messageOf(error);
    } finally {
      this.loading = false;
    }
  }

  private messageOf(error: Object): string {
    if (error instanceof ApiError) {
      return error.message.length > 0 ? error.message : `请求失败（${error.status}）`;
    }
    const text: string = `${error}`;
    return text.length > 0 ? text : '统计加载失败';
  }

  // MARK: 文案与派生

  /** 毫秒 → 「X 小时 Y 分」/「Y 分钟」 */
  private durationText(ms: number): string {
    const minutes: number = Math.round(ms / 60000);
    if (minutes <= 0) {
      return '0 分钟';
    }
    const h: number = Math.floor(minutes / 60);
    const m: number = minutes % 60;
    if (h === 0) {
      return `${m} 分钟`;
    }
    return m > 0 ? `${h} 小时 ${m} 分` : `${h} 小时`;
  }

  /** 时长大数字 + 单位（指标卡用）：返回 [数字, 单位] */
  private durationParts(ms: number): string[] {
    const minutes: number = Math.round(ms / 60000);
    const h: number = Math.floor(minutes / 60);
    const m: number = minutes % 60;
    if (h === 0) {
      return [`${m}`, '分钟'];
    }
    return [`${h}`, m > 0 ? `小时 ${m} 分` : '小时'];
  }

  /** 较上期变化（对应 iOS DeltaChip：涨绿跌红） */
  private deltaText(current: number, previous: number, percent: boolean): string {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null || !view.previous_available) {
      return '';
    }
    if (previous <= 0) {
      return current > 0 ? '较上期新增' : '';
    }
    if (percent) {
      const pp: number = Math.round(current - previous);
      if (pp === 0) {
        return '与上期持平';
      }
      return pp > 0 ? `↑ ${pp} 点` : `↓ ${Math.abs(pp)} 点`;
    }
    const ratio: number = Math.round((current - previous) / previous * 100);
    if (ratio === 0) {
      return '与上期持平';
    }
    return ratio > 0 ? `↑ ${ratio}%` : `↓ ${Math.abs(ratio)}%`;
  }

  private deltaColor(text: string): string {
    if (text.length === 0 || text === '与上期持平') {
      return Theme.textMuted;
    }
    if (text.startsWith('↓')) {
      return Theme.danger;
    }
    return Theme.ok;
  }

  /** 看完率（百分比数） */
  private completionRate(plays: number, completed: number): number {
    if (plays <= 0) {
      return 0;
    }
    return Math.round(completed * 100 / plays);
  }

  /** TOP3：本期 favorites 与上期对照的排名徽标（蝉联 / 上期第 n / 新上榜） */
  private rankBadge(index: number, title: PlaybackStatsTitleRow): string {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null || !view.previous_available) {
      return '';
    }
    const previousIds: number[] = [];
    for (const favorite of view.previous_favorites) {
      previousIds.push(favorite.media.media_item_id);
    }
    const at: number = previousIds.indexOf(title.media.media_item_id);
    if (at < 0) {
      return '新上榜';
    }
    if (at === index) {
      return '蝉联';
    }
    return `上期第 ${at + 1}`;
  }

  private rankName(index: number): string {
    if (index === 0) {
      return '冠军';
    }
    if (index === 1) {
      return '亚军';
    }
    return '季军';
  }

  /** 趋势图分桶：周期 ≥60 天按周折桶（柱子太窄看不清，对应 iOS 的折桶规则） */
  private trendBuckets(): TrendBucket[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    const current: PlaybackStatsDayRow[] = view.by_day;
    const previous: PlaybackStatsDayRow[] = view.previous_by_day;
    const buckets: TrendBucket[] = [];
    if (this.days < 60) {
      for (let i: number = 0; i < current.length; i++) {
        const label: string = current[i].date.substring(5).replace('-', '/');
        const prevMs: number = i < previous.length ? previous[i].watched_ms : 0;
        buckets.push(new TrendBucket(label, current[i].watched_ms, prevMs));
      }
      return buckets;
    }
    // 按周折桶：每 7 天合成一根
    for (let start: number = 0; start < current.length; start += 7) {
      let curMs: number = 0;
      let prevMs: number = 0;
      const end: number = Math.min(start + 7, current.length);
      for (let i: number = start; i < end; i++) {
        curMs += current[i].watched_ms;
        if (i < previous.length) {
          prevMs += previous[i].watched_ms;
        }
      }
      buckets.push(new TrendBucket(current[start].date.substring(5).replace('-', '/'), curMs, prevMs));
    }
    return buckets;
  }

  /** 趋势图柱高的统一比例尺 */
  private trendMaxMs(): number {
    let max: number = 1;
    for (const bucket of this.trendBuckets()) {
      if (bucket.currentMs > max) {
        max = bucket.currentMs;
      }
      if (bucket.previousMs > max) {
        max = bucket.previousMs;
      }
    }
    return max;
  }

  private trendBarHeight(ms: number): number {
    if (ms <= 0) {
      return 0;
    }
    return Math.max(3, Math.round(96 * ms / this.trendMaxMs()));
  }

  /** 时段热力图的最大值（着色比例尺） */
  private heatMaxMs(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return 1;
    }
    let max: number = 1;
    for (const row of view.by_hour) {
      for (const cell of row) {
        if (cell > max) {
          max = cell;
        }
      }
    }
    return max;
  }

  private heatColor(ms: number): string {
    if (ms <= 0) {
      return Theme.surface;
    }
    const alpha: number = 0.15 + 0.85 * ms / this.heatMaxMs();
    return `rgba(127, 176, 255, ${Math.round(alpha * 100) / 100})`;
  }

  private weekdayName(index: number): string {
    const names: string[] = ['一', '二', '三', '四', '五', '六', '日'];
    return `周${names[index]}`;
  }

  /** 分解面板排序（服务端应已排好，这里兜底按时长降序） */
  private topTitles(): PlaybackStatsTitleRow[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    const rows: PlaybackStatsTitleRow[] = view.top_titles.slice();
    rows.sort((a: PlaybackStatsTitleRow, b: PlaybackStatsTitleRow): number => b.watched_ms - a.watched_ms);
    return rows;
  }

  /** 「看得最多」默认前 5，点开展开全部 */
  private visibleTitles(): PlaybackStatsTitleRow[] {
    const rows: PlaybackStatsTitleRow[] = this.topTitles();
    return this.titlesExpanded ? rows : rows.slice(0, 5);
  }

  /** 两个周期都没有播放 → 整页空态 */
  private isEmpty(): boolean {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return false;
    }
    return view.current.plays === 0 && (!view.previous_available || view.previous.plays === 0);
  }

  // MARK: 筛选

  private memberLabel(): string {
    if (this.memberId === -1) {
      return '全部成员';
    }
    if (this.memberId === 0) {
      return '超级管理员';
    }
    for (const member of this.members) {
      if (member.id === this.memberId) {
        return member.nickname.length > 0 ? member.nickname : member.username;
      }
    }
    return '成员';
  }

  private scopeLabel(): string {
    return this.scope === 'all' ? '全部含隐藏库' : '我的浏览范围';
  }

  private pickDays(days: number): void {
    if (this.days === days) {
      return;
    }
    this.days = days;
    this.load();
  }

  private pickMember(id: number): void {
    if (this.memberId === id) {
      return;
    }
    this.memberId = id;
    this.load();
  }

  private pickScope(scope: string): void {
    if (this.scope === scope) {
      return;
    }
    this.scope = scope;
    this.load();
  }

  // MARK: 视图

  build() {
    NavDestination() {
      Column() {
        this.TopBar()
        this.Body()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      if (!this.started) {
        this.started = true;
        this.load();
        this.loadMembers();
      }
    })
  }

  @Builder
  TopBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([Theme.text])
        .width(38)
        .height(38)
        .onClick(() => {
          this.navStack.pop();
        })
      Text('观看统计')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text)
        .maxLines(1)
      Blank()
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(16)
          .fontColor([Theme.textMuted])
        Text(`${this.memberLabel()} · ${this.scopeLabel()}`)
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
          .constraintSize({ maxWidth: 150 })
      }
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor(Theme.glassFill)
      .borderRadius(16)
      .border({ width: 1, color: Theme.line })
      .bindMenu(this.FilterMenu())
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: Theme.statusBarInset + 6, bottom: 6 })
  }

  @Builder
  FilterMenu() {
    Menu() {
      MenuItemGroup({ header: this.MenuHeader('成员') }) {
        MenuItem({ content: '全部成员' })
          .onClick(() => {
            this.pickMember(-1);
          })
        MenuItem({ content: '超级管理员' })
          .onClick(() => {
            this.pickMember(0);
          })
        ForEach(this.members, (member: MemberView) => {
          MenuItem({ content: member.nickname.length > 0 ? member.nickname : member.username })
            .onClick(() => {
              this.pickMember(member.id);
            })
        }, (member: MemberView) => `${member.id}`)
      }
      MenuItemGroup({ header: this.MenuHeader('浏览范围') }) {
        MenuItem({ content: '我的浏览范围' })
          .onClick(() => {
            this.pickScope('visible');
          })
        MenuItem({ content: '全部含隐藏库' })
          .onClick(() => {
            this.pickScope('all');
          })
      }
    }
  }

  @Builder
  MenuHeader(label: string) {
    Text(label)
      .fontSize(11)
      .fontColor(Theme.textFaint)
      .padding({ left: 16, top: 6, bottom: 2 })
  }

  @Builder
  Body() {
    if (this.loading && this.stats === null) {
      Column() {
        LoadingProgress()
          .width(26)
          .height(26)
          .color(Theme.textMuted)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.stats === null) {
      Column({ space: 10 }) {
        Text('统计加载失败')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(Theme.text)
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor(Theme.textMuted)
        Text('重试')
          .fontSize(14)
          .fontWeight(600)
          .fontColor(Theme.accentStrong)
          .padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .backgroundColor(Theme.glassFill)
          .borderRadius(18)
          .border({ width: 1, color: Theme.lineStrong })
          .onClick(() => {
            this.load();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column({ space: 20 }) {
          this.PeriodChips()
          if (this.isEmpty()) {
            this.EmptyCard()
          } else {
            this.MetricCards()
            this.FavoritesCard()
            this.TrendCard()
            this.BreakdownCards()
            this.HeatmapCard()
          }
          AppFooter({ topSpace: 8 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: Theme.tabBarInset })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')
    }
  }

  /** 周期切换（对应 iOS stats 才有的「周期」Picker：7 / 30 / 90 天） */
  @Builder
  PeriodChips() {
    Row({ space: 8 }) {
      ForEach([7, 30, 90], (days: number) => {
        Text(`最近 ${days} 天`)
          .fontSize(13)
          .fontColor(this.days === days ? '#0b0d12' : Theme.textMuted)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .backgroundColor(this.days === days ? Theme.accent : Theme.glassFill)
          .borderRadius(15)
          .border({ width: 1, color: this.days === days ? Theme.accent : Theme.line })
          .onClick(() => {
            this.pickDays(days);
          })
      }, (days: number) => `${days}`)
    }
    .width('100%')
  }

  /** 两周期都无播放（对应 iOS ActivityEmptyCard + 引导动作） */
  @Builder
  EmptyCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.waveform'))
        .fontSize(34)
        .fontColor([Theme.textFaint])
      Text('这段时间还没有播放')
        .fontSize(16)
        .fontWeight(600)
        .fontColor(Theme.text)
      Text('看完一部片子后，这里会给出时长、场次和时段的分布。')
        .fontSize(13)
        .fontColor(Theme.textMuted)
        .textAlign(TextAlign.Center)
      Row({ space: 10 }) {
        if (this.memberId !== -1) {
          Text('查看全部成员')
            .fontSize(13)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(15)
            .border({ width: 1, color: Theme.line })
            .onClick(() => {
              this.pickMember(-1);
            })
        }
        if (this.days !== 90) {
          Text('看最近 90 天')
            .fontSize(13)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(Theme.glassFill)
            .borderRadius(15)
            .border({ width: 1, color: Theme.line })
            .onClick(() => {
              this.pickDays(90);
            })
        }
      }
      .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 48, left: 24, right: 24 })
  }

  /** 四张指标卡（2×2，对应 iOS MetricCard）：点卡不做主图切换，先保内容对齐 */
  @Builder
  MetricCards() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.MetricCard('观看时长', this.durationParts(this.currentMs())[0],
          this.durationParts(this.currentMs())[1],
          this.deltaText(this.currentMs(), this.previousMs(), false))
        this.MetricCard('播放场次', `${this.currentPlays()}`, '场',
          this.deltaText(this.currentPlays(), this.previousPlays(), false))
      }
      Row({ space: 10 }) {
        this.MetricCard('看完率', `${this.completionRate(this.currentPlays(), this.currentCompleted())}`, '%',
          this.deltaText(this.completionRate(this.currentPlays(), this.currentCompleted()),
            this.completionRate(this.previousPlays(), this.previousCompleted()), true))
        this.MetricCard('活跃成员', `${this.currentMembers()}`, '人',
          this.deltaText(this.currentMembers(), this.previousMembers(), false))
      }
    }
    .width('100%')
  }

  private currentMs(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.current.watched_ms;
  }

  private previousMs(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.previous.watched_ms;
  }

  private currentPlays(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.current.plays;
  }

  private previousPlays(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.previous.plays;
  }

  private currentCompleted(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.current.completed;
  }

  private previousCompleted(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.previous.completed;
  }

  private currentMembers(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.current.active_members;
  }

  private previousMembers(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.previous.active_members;
  }

  @Builder
  MetricCard(label: string, value: string, unit: string, delta: string) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textMuted)
      Row({ space: 4 }) {
        Text(value)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.text)
        Text(unit)
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .alignItems(VerticalAlign.Bottom)
      if (delta.length > 0) {
        Text(delta)
          .fontSize(11)
          .fontWeight(600)
          .fontColor(this.deltaColor(delta))
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 最受欢迎 TOP3（对应 iOS FavoritePodium）：描边排名 + 海报 + 统计 + 排名变化 */
  @Builder
  FavoritesCard() {
    if (this.favorites().length > 0) {
      Column({ space: 14 }) {
        Text('最受欢迎')
          .fontSize(17)
          .fontWeight(600)
          .fontColor(Theme.text)
        ForEach(this.favorites(), (title: PlaybackStatsTitleRow, index: number) => {
          this.FavoriteRow(title, index)
        }, (title: PlaybackStatsTitleRow) => `${title.media.media_item_id}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  private favorites(): PlaybackStatsTitleRow[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? [] : view.favorites;
  }

  @Builder
  FavoriteRow(title: PlaybackStatsTitleRow, index: number) {
    Row({ space: 12 }) {
      // 大号排名数字（对应 iOS TopEntry 的 outlined number，鸿蒙用大号淡色数字）
      Text(`${index + 1}`)
        .fontSize(34)
        .fontWeight(FontWeight.Bolder)
        .fontColor('rgba(205,214,230,0.35)')
        .width(34)
        .textAlign(TextAlign.Center)
      RemoteImage({
        url: ImageUrls.resolve(AppModel.origin(), title.media.poster_url ?? null,
          ImageVariant.posterCard) ?? ''
      })
        .width(52)
        .height(78)
        .backgroundColor(Theme.surface)
        .borderRadius(8)
        .clip(true)
      Column({ space: 3 }) {
        Row({ space: 8 }) {
          Text(this.rankName(index))
            .fontSize(11)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor('rgba(205,214,230,0.12)')
            .borderRadius(8)
          if (this.rankBadge(index, title).length > 0) {
            Text(this.rankBadge(index, title))
              .fontSize(11)
              .fontColor(Theme.textFaint)
          }
        }
        Text(title.media.title)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${title.members} 人看过 · ${title.plays} 场 · ${this.durationText(title.watched_ms)}`)
          .fontSize(12)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
    .margin({ bottom: 8 })
  }

  /** 趋势图（对应 iOS TrendChart）：本期实心柱 + 上期对照浅柱，共用比例尺 */
  @Builder
  TrendCard() {
    Column({ space: 12 }) {
      Row() {
        Text(`每天看了多久（最近 ${this.days} 天）`)
          .fontSize(13)
          .fontWeight(600)
          .fontColor(Theme.textMuted)
        Blank()
        Row({ space: 10 }) {
          Row({ space: 4 }) {
            Circle().width(7).height(7).fill(Theme.info)
            Text('本期')
              .fontSize(10)
              .fontColor(Theme.textFaint)
          }
          if (this.previousAvailable()) {
            Row({ space: 4 }) {
              Circle().width(7).height(7).fill('rgba(127,176,255,0.3)')
              Text('上期')
                .fontSize(10)
                .fontColor(Theme.textFaint)
            }
          }
        }
      }
      .width('100%')
      // 柱区：每根一个槽，上期柱垫底、本期柱盖上
      Row() {
        ForEach(this.trendBuckets(), (bucket: TrendBucket, index: number) => {
          Column() {
            Stack({ alignContent: Alignment.Bottom }) {
              Column()
                .width('62%')
                .height(this.trendBarHeight(bucket.previousMs))
                .borderRadius(3)
                .backgroundColor('rgba(127,176,255,0.3)')
              Column()
                .width('62%')
                .height(this.trendBarHeight(bucket.currentMs))
                .borderRadius(3)
                .backgroundColor(Theme.info)
            }
            .width('100%')
            .height(100)
            if (this.bucketLabelVisible(index)) {
              Text(bucket.label)
                .fontSize(9)
                .fontColor(Theme.textFaint)
                .margin({ top: 4 })
            } else {
              Text(' ')
                .fontSize(9)
                .margin({ top: 4 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        }, (bucket: TrendBucket, index: number) => `${index}-${bucket.label}-${bucket.currentMs}`)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 10 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  private previousAvailable(): boolean {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view !== null && view.previous_available;
  }

  /** 柱子太密时抽稀横轴标签（≥16 根只标每 4 根） */
  private bucketLabelVisible(index: number): boolean {
    const total: number = this.trendBuckets().length;
    if (total <= 8) {
      return true;
    }
    const step: number = Math.ceil(total / 8);
    return index % step === 0;
  }

  /** 分解面板 ×4（对应 iOS BreakdownPanel：按成员 / 按客户端 / 看得最多 / 按播放方式） */
  @Builder
  BreakdownCards() {
    Column({ space: 10 }) {
      if (this.byMember().length > 0) {
        this.BreakdownCard('按成员', this.byMember().length, false)
      }
      if (this.byClient().length > 0) {
        this.BreakdownCard('按客户端', this.byClient().length, false)
      }
      if (this.topTitles().length > 0) {
        this.BreakdownCard('看得最多', this.topTitles().length, true)
      }
      if (this.byTier().length > 0) {
        this.BreakdownCard('按播放方式', this.byTier().length, false)
      }
    }
    .width('100%')
  }

  private byMember(): PlaybackStatsMemberBox[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    const rows: PlaybackStatsMemberBox[] = [];
    if (view === null) {
      return rows;
    }
    for (const row of view.by_member) {
      rows.push(new PlaybackStatsMemberBox(row.member_name, row.watched_ms, row.plays));
    }
    rows.sort((a: PlaybackStatsMemberBox, b: PlaybackStatsMemberBox): number => b.watchedMs - a.watchedMs);
    return rows;
  }

  private byClient(): PlaybackStatsMemberBox[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    const rows: PlaybackStatsMemberBox[] = [];
    if (view === null) {
      return rows;
    }
    for (const row of view.by_client) {
      rows.push(new PlaybackStatsMemberBox(row.client, row.watched_ms, row.plays));
    }
    rows.sort((a: PlaybackStatsMemberBox, b: PlaybackStatsMemberBox): number => b.watchedMs - a.watchedMs);
    return rows;
  }

  private byTier(): PlaybackStatsMemberBox[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    const rows: PlaybackStatsMemberBox[] = [];
    if (view === null) {
      return rows;
    }
    for (const row of view.by_tier) {
      rows.push(new PlaybackStatsMemberBox(row.label, row.plays * 60000, row.plays));
    }
    rows.sort((a: PlaybackStatsMemberBox, b: PlaybackStatsMemberBox): number => b.watchedMs - a.watchedMs);
    return rows;
  }

  @Builder
  BreakdownCard(title: string, total: number, withPoster: boolean) {
    Column({ space: 10 }) {
      Row() {
        Text(title)
          .fontSize(15)
          .fontWeight(600)
          .fontColor(Theme.text)
        Blank()
        Text(`共 ${total} 项`)
          .fontSize(11)
          .fontColor(Theme.textFaint)
      }
      .width('100%')
      if (withPoster) {
        ForEach(this.visibleTitles(), (title: PlaybackStatsTitleRow) => {
          this.TitleBreakdownRow(title)
        }, (title: PlaybackStatsTitleRow) => `${title.media.media_item_id}`)
        if (this.topTitles().length > 5) {
          Text(this.titlesExpanded ? '收起' : `展开全部 ${this.topTitles().length} 部`)
            .fontSize(12)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
            .padding({ top: 2, bottom: 2 })
            .onClick(() => {
              this.titlesExpanded = !this.titlesExpanded;
            })
        }
      } else if (title === '按成员') {
        ForEach(this.byMember(), (row: PlaybackStatsMemberBox) => {
          this.BreakdownRow(row.name, this.durationText(row.watchedMs), row.watchedMs,
            this.byMember()[0].watchedMs)
        }, (row: PlaybackStatsMemberBox) => row.name)
      } else if (title === '按客户端') {
        ForEach(this.byClient(), (row: PlaybackStatsMemberBox) => {
          this.BreakdownRow(row.name, this.durationText(row.watchedMs), row.watchedMs,
            this.byClient()[0].watchedMs)
        }, (row: PlaybackStatsMemberBox) => row.name)
      } else {
        ForEach(this.byTier(), (row: PlaybackStatsMemberBox) => {
          this.BreakdownRow(row.name, `${row.plays} 场`, row.watchedMs,
            this.byTier()[0].watchedMs)
        }, (row: PlaybackStatsMemberBox) => row.name)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 分解面板的一行：名称 · 值 · 占比条（对应 iOS BreakdownRow） */
  @Builder
  BreakdownRow(name: string, value: string, ms: number, maxMs: number) {
    Column({ space: 5 }) {
      Row() {
        Text(name)
          .fontSize(13)
          .fontColor(Theme.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(value)
          .fontSize(12)
          .fontColor(Theme.textMuted)
      }
      .width('100%')
      Column() {
        Column()
          .height(3)
          .width(maxMs > 0 ? `${Math.max(3, Math.round(ms * 100 / maxMs))}%` : '0%')
          .borderRadius(2)
          .backgroundColor(Theme.accent2)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  /** 「看得最多」一行：小海报 + 片名 + 场次/时长 */
  @Builder
  TitleBreakdownRow(title: PlaybackStatsTitleRow) {
    Row({ space: 10 }) {
      RemoteImage({
        url: ImageUrls.resolve(AppModel.origin(), title.media.poster_url ?? null,
          ImageVariant.posterCard) ?? ''
      })
        .width(30)
        .height(45)
        .backgroundColor(Theme.surface)
        .borderRadius(6)
        .clip(true)
      Column({ space: 3 }) {
        Row() {
          Text(title.media.title)
            .fontSize(13)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(`${title.plays} 场 · ${this.durationText(title.watched_ms)}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
        }
        .width('100%')
        Column() {
          Column()
            .height(3)
            .width(this.titleBarPercent(title))
              .borderRadius(2)
              .backgroundColor(Theme.accent2)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  private titleBarPercent(title: PlaybackStatsTitleRow): string {
    const rows: PlaybackStatsTitleRow[] = this.topTitles();
    const max: number = rows.length > 0 ? rows[0].watched_ms : 0;
    if (max <= 0) {
      return '0%';
    }
    return `${Math.max(3, Math.round(title.watched_ms * 100 / max))}%`;
  }

  /** 时段热力图（对应 iOS HourHeatmap）：星期 × 小时的观看时长矩阵 */
  @Builder
  HeatmapCard() {
    Column({ space: 10 }) {
      Text('什么时段在看')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(Theme.text)
      ForEach([0, 1, 2, 3, 4, 5, 6], (weekday: number) => {
        Row({ space: 2 }) {
          Text(this.weekdayName(weekday))
            .fontSize(10)
            .fontColor(Theme.textFaint)
            .width(30)
          ForEach(this.heatRow(weekday), (ms: number, hour: number) => {
            Column()
              .layoutWeight(1)
              .height(13)
              .borderRadius(2)
              .backgroundColor(this.heatColor(ms))
          }, (ms: number, hour: number) => `${weekday}-${hour}-${ms}`)
        }
        .width('100%')
      }, (weekday: number) => `${weekday}`)
      Row({ space: 2 }) {
        Text(' ')
          .fontSize(10)
          .width(30)
        ForEach([0, 6, 12, 18, 23], (hour: number) => {
          Text(`${hour}点`)
            .fontSize(9)
            .fontColor(Theme.textFaint)
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }, (hour: number) => `${hour}`)
      }
      .width('100%')
      Text('颜色越亮，那个时段看得越多（按本地时区）。')
        .fontSize(10)
        .fontColor(Theme.textFaint)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 一行的 24 个小时格子（服务端缺失时给 24 个 0） */
  private heatRow(weekday: number): number[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null || weekday >= view.by_hour.length) {
      return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    }
    return view.by_hour[weekday];
  }
}

/** 分解面板的行（成员 / 客户端 / 档位共用：名称 + 时长 + 场次） */
class PlaybackStatsMemberBox {
  readonly name: string;
  readonly watchedMs: number;
  readonly plays: number;

  constructor(name: string, watchedMs: number, plays: number) {
    this.name = name;
    this.watchedMs = watchedMs;
    this.plays = plays;
  }
}
