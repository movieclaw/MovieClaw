import { display } from '@kit.ArkUI';
import { Theme } from '../theme/AppTheme';
import { GlassButtonModifier, GlassTone } from '../common/GlassControls';
import { AppModel } from '../common/AppModel';
import { AppFooter } from '../common/AppFooter';
import { RemoteImage } from '../common/RemoteImage';
import { ImageUrls, ImageVariant } from '../common/ImageUrls';
import { ApiError } from '../api/ApiClient';
import { MovieClawApi } from '../api/Endpoints';
import {
  MemberView,
  MediaActivityTarget,
  PlaybackStatsClientRow,
  PlaybackStatsDayRow,
  PlaybackStatsMemberRow,
  PlaybackStatsTierRow,
  PlaybackStatsTitleRow,
  PlaybackStatsTotals,
  PlaybackWatchStatsView
} from '../api/Models';
import { ActivityFormat, WatchFormat } from './ActivityFormat';
import { ItemRouteParams } from '../library/LibraryItemDetailPage';

/** 路由表注册用（router_map.json 的 buildFunction） */
@Builder
export function ActivityStatsBuilder() {
  ActivityStatsPage()
}

/** 四个指标（对齐 iOS `WatchMetric`）：点指标卡，主图跟着换指标 */
enum StatMetric {
  Watched,
  Plays,
  Completion,
  Members
}

/** 星期标签（周一为 0 行，同服务端 by_hour） */
const WEEKDAY_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];
/** 24 个小时槽（横轴刻度用） */
const HOUR_SLOTS: number[] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23
];
/** 热力图缺行时的兜底 */
const ZERO_HOURS: number[] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
];
/** 上期图例的虚线段 */
const DASH_SEGMENTS: number[] = [0, 1, 2];

/** 趋势图的一个槽：本期值 + 上期同槽值（上期画虚线） */
class TrendPoint {
  readonly index: number;
  readonly firstDate: string;
  readonly label: string;
  readonly previousLabel: string;
  readonly current: number;
  readonly previous: number;
  readonly hasPrevious: boolean;
  readonly dayCount: number;

  constructor(index: number, firstDate: string, label: string, previousLabel: string,
    current: number, previous: number, hasPrevious: boolean, dayCount: number) {
    this.index = index;
    this.firstDate = firstDate;
    this.label = label;
    this.previousLabel = previousLabel;
    this.current = current;
    this.previous = previous;
    this.hasPrevious = hasPrevious;
    this.dayCount = dayCount;
  }
}

/** 较上一周期的变化（对齐 iOS `DeltaChip`）：direction -1 跌 / 0 平 / 1 涨 */
class DeltaModel {
  readonly has: boolean;
  readonly text: string;
  readonly direction: number;

  constructor(has: boolean, text: string, direction: number) {
    this.has = has;
    this.text = text;
    this.direction = direction;
  }
}

/** 分解面板的一行（对齐 iOS `BreakdownRow`） */
class BreakdownItem {
  readonly key: string;
  readonly label: string;
  readonly value: number;
  readonly valueLabel: string;
  readonly secondary: string;
  readonly share: number;
  readonly selected: boolean;
  readonly muted: boolean;
  readonly media: MediaActivityTarget | null;
  /** 可钻取的成员行：成员 id；不可钻取为 -1 */
  readonly memberId: number;

  constructor(key: string, label: string, value: number, valueLabel: string, secondary: string,
    share: number, selected: boolean, muted: boolean, media: MediaActivityTarget | null,
    memberId: number) {
    this.key = key;
    this.label = label;
    this.value = value;
    this.valueLabel = valueLabel;
    this.secondary = secondary;
    this.share = share;
    this.selected = selected;
    this.muted = muted;
    this.media = media;
    this.memberId = memberId;
  }
}

/** TOP3 与上期的名次对照（蝉联 / 上期第 n / 新上榜） */
class RankChange {
  readonly text: string;
  readonly color: string;

  constructor(text: string, color: string) {
    this.text = text;
    this.color = color;
  }
}

/**
 * 观看统计二级页（对齐 iOS `ActivityPages.ActivityWatchPage` + `WatchStatsPanel`）。
 *
 * 骨架照 iOS 仪表盘：**指标卡 → TOP 3 → 主图 → 一组同构的分解面板 → 时段热力图**。
 * - 四张指标卡可点：点哪张，主图就切到哪个指标（观看时长 / 场次 / 看完率 / 活跃成员）；
 * - 主图把本周期柱子与上一周期虚线画在同一坐标系，按可用宽度决定按天还是按周折桶，
 *   点柱子看当天（当周）读数；
 * - 分解面板同一个模板（名称 · 值 · 占比条），默认五行，多出来的合成「其他 N 个」，
 *   「看得最多」留「展开全部」；成员行可点即钻取；
 * - 星期 × 小时热力图回答「家里什么时候有人在看」。
 */
@ComponentV2
export struct ActivityStatsPage {
  private navStack: NavPathStack = new NavPathStack();
  /** 周期默认 30 天（同 iOS ActivityWatchPage） */
  @Local private days: number = 30;
  @Local private memberId: number = -1;
  @Local private scope: string = 'visible';
  @Local private members: MemberView[] = [];
  @Local private stats: PlaybackWatchStatsView | null = null;
  @Local private loading: boolean = true;
  @Local private errorMessage: string = '';
  /** 主图当前指标（点指标卡切换） */
  @Local private metric: StatMetric = StatMetric.Watched;
  /** 主图点中的槽；-1 = 没点 */
  @Local private selectedBucket: number = -1;
  /** 主图实测宽度（上期虚线的坐标要用） */
  @Local private chartWidth: number = 0;
  /** 「看得最多」默认收起，点开展开全部（对应 iOS fold=.expand） */
  @Local private titlesExpanded: boolean = false;
  /** TOP3 卡片内容高度（模糊铺底要按它定高，见 FavoritesCard） */
  @Local private podiumHeight: number = 0;
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
      this.selectedBucket = -1;
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

  /** 点指标卡：切换主图指标，并清掉上一次点中的柱子 */
  private pickMetric(metric: StatMetric): void {
    if (this.metric === metric) {
      return;
    }
    this.metric = metric;
    this.selectedBucket = -1;
  }

  /** 打开条目详情（有落点库且在可浏览范围内才可跳） */
  private openMedia(target: MediaActivityTarget | null): void {
    if (target === null || !WatchFormat.canOpenDetail(target)) {
      return;
    }
    const libraryId: number | null = target.library_id ?? null;
    this.navStack.pushPathByName('libraryItem',
      new ItemRouteParams(libraryId ?? 0, target.media_item_id));
  }

  // MARK: 指标（对齐 iOS WatchMetric）

  private metricLabel(metric: StatMetric): string {
    if (metric === StatMetric.Watched) {
      return '观看时长';
    }
    if (metric === StatMetric.Plays) {
      return '播放场次';
    }
    if (metric === StatMetric.Completion) {
      return '看完率';
    }
    return '活跃成员';
  }

  /** 汇总数里的指标值（看完率是 0~1 的比例） */
  private totalsValue(metric: StatMetric, totals: PlaybackStatsTotals): number {
    if (metric === StatMetric.Watched) {
      return totals.watched_ms;
    }
    if (metric === StatMetric.Plays) {
      return totals.plays;
    }
    if (metric === StatMetric.Completion) {
      return totals.plays > 0 ? totals.completed / totals.plays : 0;
    }
    return totals.active_members;
  }

  /** 一段日期的指标值（按周折桶时求这一段；活跃成员取日均） */
  private rowsValue(metric: StatMetric, rows: PlaybackStatsDayRow[]): number {
    let watchedMs: number = 0;
    let plays: number = 0;
    let completed: number = 0;
    let members: number = 0;
    for (const row of rows) {
      watchedMs += row.watched_ms;
      plays += row.plays;
      completed += row.completed;
      members += row.members;
    }
    if (metric === StatMetric.Watched) {
      return watchedMs;
    }
    if (metric === StatMetric.Plays) {
      return plays;
    }
    if (metric === StatMetric.Completion) {
      return plays > 0 ? completed / plays : 0;
    }
    return rows.length === 0 ? 0 : members / rows.length;
  }

  /** 指标卡大数字：[数值, 单位]（对齐 iOS WatchMetric.parts） */
  private metricParts(metric: StatMetric, value: number): string[] {
    if (metric === StatMetric.Watched) {
      if (value >= 3600000) {
        return [this.hoursText(value), '小时'];
      }
      const minutes: number = Math.round(value / 60000);
      return [value > 0 && minutes < 1 ? '1' : `${minutes}`, '分钟'];
    }
    if (metric === StatMetric.Plays) {
      return [`${Math.round(value)}`, '场'];
    }
    if (metric === StatMetric.Completion) {
      return [`${Math.round(value * 100)}`, '%'];
    }
    return [this.trim1(value), '人'];
  }

  /** 指标的一行文案（DELTA 旁的「上期 X」、读数、提示都用它） */
  private metricFormat(metric: StatMetric, value: number): string {
    if (metric === StatMetric.Watched) {
      return value >= 3600000 ? `${this.hoursText(value)} 小时` : ActivityFormat.watched(Math.round(value));
    }
    if (metric === StatMetric.Plays) {
      return `${Math.round(value)} 场`;
    }
    if (metric === StatMetric.Completion) {
      return `${Math.round(value * 100)}%`;
    }
    return `${this.trim1(value)} 人`;
  }

  /** 纵轴刻度文案 */
  private metricAxis(metric: StatMetric, value: number): string {
    if (metric === StatMetric.Watched) {
      const hours: number = value / 3600000;
      return value >= 36000000 ? `${Math.round(hours)}h` : `${hours.toFixed(1)}h`;
    }
    if (metric === StatMetric.Completion) {
      return `${Math.round(value * 100)}%`;
    }
    return `${Math.round(value)}`;
  }

  /** 小时数：≥100 小时不带小数，否则一位小数（同 iOS String(format:)） */
  private hoursText(ms: number): string {
    const hours: number = ms / 3600000;
    return ms >= 360000000 ? `${Math.round(hours)}` : hours.toFixed(1);
  }

  private trim1(value: number): string {
    return value === Math.round(value) ? `${Math.round(value)}` : value.toFixed(1);
  }

  /**
   * 较上一周期的变化（对齐 iOS DeltaChip）：
   * 无上期 → 不出；看完率按「个百分点」；上期为 0 → 「新增」；其余按百分比，持平也显式说。
   */
  private deltaFor(metric: StatMetric, current: number, previous: number): DeltaModel {
    if (!this.previousAvailable()) {
      return new DeltaModel(false, '', 0);
    }
    if (metric === StatMetric.Completion) {
      const points: number = Math.round((current - previous) * 100);
      return new DeltaModel(true, `${Math.abs(points)} 个百分点`,
        points > 0 ? 1 : points < 0 ? -1 : 0);
    }
    if (previous <= 0) {
      return current > 0 ? new DeltaModel(true, '新增', 1) : new DeltaModel(false, '', 0);
    }
    const ratio: number = (current - previous) / previous;
    const direction: number = ratio > 0 ? 1 : ratio < 0 ? -1 : 0;
    if (direction === 0) {
      return new DeltaModel(true, '持平', 0);
    }
    return new DeltaModel(true, `${Math.round(Math.abs(ratio) * 100)}%`, direction);
  }

  private deltaColor(direction: number): string {
    if (direction > 0) {
      return Theme.ok;
    }
    if (direction < 0) {
      return Theme.danger;
    }
    return Theme.textMuted;
  }

  /** 变化胶囊的底：持平用白 8%，涨跌用同色 15%（颜色是 6 位 hex） */
  private deltaBackground(direction: number): string {
    if (direction === 0) {
      return 'rgba(255, 255, 255, 0.08)';
    }
    return direction > 0 ? `${Theme.ok}26` : `${Theme.danger}26`;
  }

  private previousText(metric: StatMetric): string {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null || !view.previous_available) {
      return '暂无上一周期数据';
    }
    return `上期 ${this.metricFormat(metric, this.totalsValue(metric, view.previous))}`;
  }

  // MARK: 周期与空态

  private previousAvailable(): boolean {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view !== null && view.previous_available;
  }

  private currentPlays(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.current.plays;
  }

  private previousPlays(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.previous.plays;
  }

  /** 本周期没有播放、也没有上一周期可参照 → 整页空态（同 iOS） */
  private isEmptyAll(): boolean {
    return this.currentPlays() === 0 && !this.previousAvailable();
  }

  // MARK: 趋势图

  private dayRows(): PlaybackStatsDayRow[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? [] : view.by_day;
  }

  /** 图表区宽度：量到之前先按屏宽估一个（只看折桶，不影响比例尺） */
  private plotWidth(): number {
    if (this.chartWidth > 0) {
      return this.chartWidth;
    }
    const screen: number = px2vp(display.getDefaultDisplaySync().width);
    return Math.max(160, screen - Theme.pagePadding * 2 - 24 - 40);
  }

  /** 每根柱子分不到 6vp 就按周折桶（同 iOS：90 天在手机上折周，30 天按天） */
  private weekly(): boolean {
    const count: number = this.dayRows().length;
    return count > 0 && this.plotWidth() / count < 6;
  }

  /** 从末尾往前每 size 天一桶：最新一桶一定是满的 */
  private bucketize(rows: PlaybackStatsDayRow[], size: number): PlaybackStatsDayRow[][] {
    const out: PlaybackStatsDayRow[][] = [];
    let end: number = rows.length;
    while (end > 0) {
      const start: number = Math.max(0, end - size);
      out.unshift(rows.slice(start, end));
      end -= size;
    }
    return out;
  }

  /** "2026-09-26" → "9月26日" */
  private dayLabel(date: string): string {
    const parts: string[] = date.split('-');
    if (parts.length !== 3) {
      return date;
    }
    const month: number = Number(parts[1]);
    const day: number = Number(parts[2]);
    if (!Number.isFinite(month) || !Number.isFinite(day)) {
      return date;
    }
    return `${month}月${day}日`;
  }

  /** 一桶的标签：一天就是那天，一周写成「9月1日 – 9月7日」 */
  private bucketLabel(rows: PlaybackStatsDayRow[]): string {
    if (rows.length === 0) {
      return '';
    }
    const first: string = this.dayLabel(rows[0].date);
    if (rows.length === 1) {
      return first;
    }
    return `${first} – ${this.dayLabel(rows[rows.length - 1].date)}`;
  }

  private trendPoints(): TrendPoint[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    const size: number = this.weekly() ? 7 : 1;
    const current: PlaybackStatsDayRow[][] = this.bucketize(view.by_day, size);
    const previous: PlaybackStatsDayRow[][] = this.bucketize(view.previous_by_day, size);
    const showPrevious: boolean = view.previous_available && previous.length === current.length;
    const points: TrendPoint[] = [];
    for (let index: number = 0; index < current.length; index++) {
      const rows: PlaybackStatsDayRow[] = current[index];
      const previousRows: PlaybackStatsDayRow[] = showPrevious ? previous[index] : [];
      points.push(new TrendPoint(index, rows.length > 0 ? rows[0].date : '',
        this.bucketLabel(rows), showPrevious ? this.bucketLabel(previousRows) : '',
        this.rowsValue(this.metric, rows),
        showPrevious ? this.rowsValue(this.metric, previousRows) : 0,
        showPrevious, rows.length));
    }
    return points;
  }

  /** 坐标轴的整齐上限：1 / 2 / 5 × 10^n 里第一个不小于最大值的（同 iOS） */
  private niceMax(value: number): number {
    if (value <= 0) {
      return 1;
    }
    const base: number = Math.pow(10, Math.floor(Math.log(value) / Math.LN10));
    const steps: number[] = [1, 2, 5, 10];
    for (const step of steps) {
      if (value <= step * base) {
        return step * base;
      }
    }
    return 10 * base;
  }

  private trendYMax(): number {
    let max: number = 0;
    for (const point of this.trendPoints()) {
      if (point.current > max) {
        max = point.current;
      }
      if (point.hasPrevious && point.previous > max) {
        max = point.previous;
      }
    }
    return this.niceMax(max);
  }

  private trendBarHeight(value: number): number {
    if (value <= 0) {
      return 0;
    }
    return Math.max(2, Math.round(value / this.trendYMax() * 200));
  }

  private allCurrentZero(): boolean {
    const points: TrendPoint[] = this.trendPoints();
    if (points.length === 0) {
      return true;
    }
    for (const point of points) {
      if (point.current > 0) {
        return false;
      }
    }
    return true;
  }

  private showPreviousLine(): boolean {
    const points: TrendPoint[] = this.trendPoints();
    return points.length > 0 && points[0].hasPrevious;
  }

  /** 上期虚线的坐标（vp，与柱子共用同一个槽位与比例尺） */
  private previousPoints(): number[][] {
    const points: TrendPoint[] = this.trendPoints();
    if (this.chartWidth <= 0 || points.length === 0) {
      return [];
    }
    const slot: number = this.chartWidth / points.length;
    const yMax: number = this.trendYMax();
    const out: number[][] = [];
    for (const point of points) {
      if (!point.hasPrevious) {
        continue;
      }
      out.push([slot * (point.index + 0.5), 200 - point.previous / yMax * 200]);
    }
    return out;
  }

  /** 横轴标签抽稀：按宽度大约放 2~5 个（同 iOS tickEvery） */
  private tickEvery(): number {
    const slots: number = Math.max(2, Math.min(5, Math.floor(this.plotWidth() / 70)));
    return Math.max(1, Math.round(this.trendPoints().length / slots));
  }

  private tickVisible(index: number): boolean {
    return index % this.tickEvery() === 0 || index === this.trendPoints().length - 1;
  }

  /** 纵轴刻度：四等分 + 0（自上而下） */
  private axisLabels(): string[] {
    const yMax: number = this.trendYMax();
    return [
      this.metricAxis(this.metric, yMax),
      this.metricAxis(this.metric, yMax * 3 / 4),
      this.metricAxis(this.metric, yMax / 2),
      this.metricAxis(this.metric, yMax / 4),
      this.metricAxis(this.metric, 0)
    ];
  }

  /** 按周折桶时的读数提示：活跃成员是日均 */
  private bucketNote(): string {
    return this.weekly() && this.metric === StatMetric.Members ? '日均 ' : '';
  }

  private barOpacity(index: number): number {
    if (this.selectedBucket < 0 || this.selectedBucket === index) {
      return 0.95;
    }
    return 0.55;
  }

  // MARK: TOP 3

  private favorites(): PlaybackStatsTitleRow[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? [] : view.favorites;
  }

  private drilled(): boolean {
    return this.memberId !== -1;
  }

  private favoritePosterUrl(): string {
    const rows: PlaybackStatsTitleRow[] = this.favorites();
    if (rows.length === 0) {
      return '';
    }
    const url: string | null = ImageUrls.resolve(AppModel.origin(),
      rows[0].media.poster_url ?? null, ImageVariant.posterCard);
    return url !== null ? url : '';
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

  /** 「2024 · 剧集」 */
  private factsText(media: MediaActivityTarget): string {
    const parts: string[] = [];
    if (media.year !== null && media.year !== undefined) {
      parts.push(`${media.year}`);
    }
    if (media.kind === 'movie') {
      parts.push('电影');
    } else if (media.kind === 'tv') {
      parts.push('剧集');
    }
    return parts.join(' · ');
  }

  /** 与上一周期前三对照：同名次「蝉联」、换了名次「上期第 n」、上期不在榜「新上榜」 */
  private rankChange(row: PlaybackStatsTitleRow, rank: number): RankChange | null {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null || view.previous_favorites.length === 0) {
      return null;
    }
    let at: number = -1;
    for (let index: number = 0; index < view.previous_favorites.length; index++) {
      if (view.previous_favorites[index].media.media_item_id === row.media.media_item_id) {
        at = index;
        break;
      }
    }
    if (at < 0) {
      return new RankChange('新上榜', Theme.info);
    }
    if (at === rank) {
      return new RankChange('蝉联', Theme.ok);
    }
    return new RankChange(`${at > rank ? '▲' : '▼'} 上期第 ${at + 1}`,
      at > rank ? Theme.ok : Theme.textMuted);
  }

  private topStatsLine(row: PlaybackStatsTitleRow): string {
    const parts: string[] = [];
    if (!this.drilled()) {
      parts.push(`${row.members} 人看过`);
    }
    parts.push(`${row.plays} 场`);
    return parts.join(' · ');
  }

  // MARK: 分解面板

  private hiddenTitleCount(): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : view.hidden_title_count;
  }

  private shareOf(value: number, total: number): number {
    return total > 0 ? Math.round(value / total * 100) : 0;
  }

  /** 除前 5 行外合成「其他 N 个 X」；valueLabel 由各面板的格式函数给（时长 / 场次） */
  private foldOther(items: BreakdownItem[], unit: string, byPlays: boolean): BreakdownItem[] {
    if (items.length <= 5) {
      return items;
    }
    const head: BreakdownItem[] = items.slice(0, 5);
    let restValue: number = 0;
    let restShare: number = 0;
    for (let index: number = 5; index < items.length; index++) {
      restValue += items[index].value;
      restShare += items[index].share;
    }
    const count: number = items.length - 5;
    const valueLabel: string = byPlays ? `${Math.round(restValue)} 场`
      : ActivityFormat.watched(Math.round(restValue));
    head.push(new BreakdownItem('__other', `其他 ${count} ${unit}`, restValue, valueLabel, '',
      restShare, false, true, null, -1));
    return head;
  }

  private memberItems(): BreakdownItem[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    const rows = view.by_member.slice();
    rows.sort((a: PlaybackStatsMemberRow, b: PlaybackStatsMemberRow): number => b.watched_ms - a.watched_ms);
    const total: number = view.current.watched_ms;
    const items: BreakdownItem[] = [];
    for (const row of rows) {
      items.push(new BreakdownItem(`m-${row.member_id}`, row.member_name, row.watched_ms,
        ActivityFormat.watched(row.watched_ms), `${row.plays} 场 · 看完 ${row.completed}`,
        this.shareOf(row.watched_ms, total), this.memberId === row.member_id, false, null,
        row.member_id));
    }
    return items;
  }

  private clientItems(): BreakdownItem[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    const rows = view.by_client.slice();
    rows.sort((a: PlaybackStatsClientRow, b: PlaybackStatsClientRow): number => b.watched_ms - a.watched_ms);
    const total: number = view.current.watched_ms;
    const items: BreakdownItem[] = [];
    for (const row of rows) {
      items.push(new BreakdownItem(`c-${row.client}`, row.client, row.watched_ms,
        ActivityFormat.watched(row.watched_ms), `${row.plays} 场`,
        this.shareOf(row.watched_ms, total), false, false, null, -1));
    }
    return items;
  }

  private titleItems(): BreakdownItem[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    const rows = view.top_titles.slice();
    rows.sort((a: PlaybackStatsTitleRow, b: PlaybackStatsTitleRow): number => b.watched_ms - a.watched_ms);
    const total: number = view.current.watched_ms;
    const items: BreakdownItem[] = [];
    for (let index: number = 0; index < rows.length; index++) {
      const row: PlaybackStatsTitleRow = rows[index];
      items.push(new BreakdownItem(`${row.media.media_item_id}-${index}`, row.media.title,
        row.watched_ms, ActivityFormat.watched(row.watched_ms), `${row.plays} 场`,
        this.shareOf(row.watched_ms, total), false, false, row.media, -1));
    }
    return items;
  }

  private tierItems(): BreakdownItem[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null) {
      return [];
    }
    const rows = view.by_tier.slice();
    rows.sort((a: PlaybackStatsTierRow, b: PlaybackStatsTierRow): number => b.plays - a.plays);
    let total: number = 0;
    for (const row of rows) {
      total += row.plays;
    }
    const items: BreakdownItem[] = [];
    for (const row of rows) {
      items.push(new BreakdownItem(`t-${row.tier}`, row.label, row.plays, `${row.plays} 场`, '',
        this.shareOf(row.plays, total), false, false, null, -1));
    }
    return items;
  }

  private visibleTitleItems(): BreakdownItem[] {
    const items: BreakdownItem[] = this.titleItems();
    return this.titlesExpanded ? items : items.slice(0, 5);
  }

  /** 分解行的海报地址（media 为空时给空串，组件自己出占位） */
  private itemPosterUrl(item: BreakdownItem): string {
    const media: MediaActivityTarget | null = item.media;
    if (media === null) {
      return '';
    }
    const url: string | null = ImageUrls.resolve(AppModel.origin(), media.poster_url ?? null,
      ImageVariant.posterCard);
    return url !== null ? url : '';
  }

  /** 分解行标题：片名 SxxEyy 单集名 [仅管理]（统计行不带年份，同 iOS） */
  private itemTitle(item: BreakdownItem): string {
    const media: MediaActivityTarget | null = item.media;
    if (media === null) {
      return item.label;
    }
    const parts: string[] = [media.title.length === 0 ? '（条目已删除）' : media.title];
    const unit: string | null = WatchFormat.unitLabel(media);
    if (unit !== null) {
      parts.push(unit);
    }
    const episodeTitle: string = media.episode_title ?? '';
    if (episodeTitle.length > 0) {
      parts.push(episodeTitle);
    }
    if (!media.browsable && (media.library_id ?? null) !== null) {
      parts.push('仅管理');
    }
    return parts.join(' ');
  }

  private barWidth(share: number): string {
    return `${Math.max(1, Math.min(100, share))}%`;
  }

  private shareColor(item: BreakdownItem): string {
    if (item.selected) {
      return Theme.ok;
    }
    return item.muted ? 'rgba(255, 255, 255, 0.22)' : 'rgba(127, 176, 255, 0.9)';
  }

  // MARK: 热力图

  private heatRow(weekday: number): number[] {
    const view: PlaybackWatchStatsView | null = this.stats;
    if (view === null || weekday >= view.by_hour.length) {
      return ZERO_HOURS;
    }
    return view.by_hour[weekday];
  }

  private heatMaxMs(): number {
    let max: number = 1;
    for (let weekday: number = 0; weekday < 7; weekday++) {
      for (const cell of this.heatRow(weekday)) {
        if (cell > max) {
          max = cell;
        }
      }
    }
    return max;
  }

  private heatTotal(): number {
    let total: number = 0;
    for (let weekday: number = 0; weekday < 7; weekday++) {
      for (const cell of this.heatRow(weekday)) {
        total += cell;
      }
    }
    return total;
  }

  /** 越深越多（对齐 iOS：0.18 + 占比 × 0.82）；没有数据是白 4% */
  private heatColor(ms: number): string {
    if (ms <= 0) {
      return 'rgba(255, 255, 255, 0.04)';
    }
    const alpha: number = 0.18 + ms / this.heatMaxMs() * 0.82;
    return `rgba(127, 176, 255, ${Math.round(alpha * 100) / 100})`;
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
    .padding({ left: 12, right: 12, top: Theme.shellTopInset + 6, bottom: 6 })
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
        Button() {
          Text('重试')
            .fontSize(14)
            .fontWeight(600)
            .fontColor(Theme.accentStrong)
        }
        .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
        .padding({ left: 20, right: 20, top: 9, bottom: 9 })
        .borderRadius(18)
        .onClick(() => {
          this.load();
        })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column({ space: 16 }) {
          this.PeriodChips()
          if (this.isEmptyAll()) {
            this.EmptyCard(this.emptyTitle(true),
              '统计从播放日志来：从现在起每一场播放都会计入，看得越久这里越有得看。')
          } else {
            this.MetricCards()
            if (this.currentPlays() === 0) {
              // 本周期没有播放、上期有：主图留着当参照，分解面板没有可分解的数据（同 iOS）
              this.TrendCard()
              this.EmptyCard(this.emptyTitle(false),
                `上一周期有 ${this.previousPlays()} 场；本周期一场都没有，没有可以分解的数据。`)
            } else {
              this.FavoritesCard()
              this.TrendCard()
              this.BreakdownPanels()
              this.HeatmapCard()
            }
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

  /** 周期切换（7 / 30 / 90 天；默认 30，同 iOS） */
  @Builder
  PeriodChips() {
    Row({ space: 8 }) {
      ForEach([7, 30, 90], (days: number) => {
        Button() {
          Text(`最近 ${days} 天`)
            .fontSize(13)
            .fontColor(this.days === days ? '#0b0d12' : Theme.textMuted)
        }
        .attributeModifier(new GlassButtonModifier(this.days === days ? GlassTone.Primary : GlassTone.Secondary))
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(15)
        .onClick(() => {
          this.pickDays(days);
        })
      }, (days: number) => `${days}`)
    }
    .width('100%')
  }

  private emptyTitle(full: boolean): string {
    if (full) {
      return this.drilled() ? `${this.memberLabel()}最近 ${this.days} 天没有播放`
        : `最近 ${this.days} 天没有播放记录`;
    }
    return this.drilled() ? `${this.memberLabel()}本周期没有播放` : '本周期没有播放';
  }

  /** 空态卡（对齐 iOS ActivityEmptyCard）：图标 + 标题 + 说明 + 能做的两件事 */
  @Builder
  EmptyCard(title: string, message: string) {
    Column() {
      Column() {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(18)
          .fontColor([Theme.textMuted])
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(255, 255, 255, 0.04)')
      .borderRadius(24)
      .border({ width: 1, color: Theme.line })
      .margin({ bottom: 12 })
      Text(title)
        .fontSize(14)
        .fontWeight(600)
        .fontColor('rgba(243, 245, 249, 0.9)')
        .textAlign(TextAlign.Center)
      Text(message)
        .fontSize(12)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
        .lineHeight(18)
        .margin({ top: 6 })
      Row({ space: 8 }) {
        if (this.drilled()) {
          this.PillButton('查看全部成员', (): void => {
            this.pickMember(-1);
          })
        }
        if (this.days < 90) {
          this.PillButton('看最近 90 天', (): void => {
            this.pickDays(90);
          })
        }
      }
      .margin({ top: 14 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 16, right: 16, top: 32, bottom: 32 })
    .backgroundColor('rgba(255, 255, 255, 0.02)')
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.07)' })
  }

  @Builder
  PillButton(label: string, onTap: () => void) {
    Button() {
      Text(label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('rgba(243, 245, 249, 0.85)')
    }
    .attributeModifier(new GlassButtonModifier(GlassTone.Secondary))
    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
    .borderRadius(14)
    .onClick(() => {
      onTap();
    })
  }

  /** 四张指标卡（2×2，对齐 iOS MetricCard）：点哪张主图就切到哪个指标 */
  @Builder
  MetricCards() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.MetricCard(StatMetric.Watched)
        this.MetricCard(StatMetric.Plays)
      }
      .width('100%')
      Row({ space: 10 }) {
        this.MetricCard(StatMetric.Completion)
        this.MetricCard(StatMetric.Members)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  MetricCard(metric: StatMetric) {
    Button() {
      Column({ space: 8 }) {
        Text(this.metricLabel(metric))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textMuted)
        Row({ space: 3 }) {
          Text(this.metricParts(metric, this.metricCurrent(metric))[0])
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.text)
            .maxLines(1)
          Text(this.metricParts(metric, this.metricCurrent(metric))[1])
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textFaint)
        }
        .alignItems(VerticalAlign.Bottom)
        Row({ space: 6 }) {
          if (this.deltaFor(metric, this.metricCurrent(metric), this.metricPrevious(metric)).has) {
            this.DeltaChip(this.deltaFor(metric, this.metricCurrent(metric), this.metricPrevious(metric)))
          }
          Text(this.previousText(metric))
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        // 有没有变化胶囊都留同样的行高，同一行两张卡等高
        .constraintSize({ minHeight: 18 })
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    }
    .attributeModifier(new GlassButtonModifier(this.metric === metric ? GlassTone.Info : GlassTone.Secondary))
    .padding(0)
    .clip(true)
    .layoutWeight(1)
    .borderRadius(Theme.cardRadius)
    .onClick(() => {
      this.pickMetric(metric);
    })
  }

  private metricCurrent(metric: StatMetric): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : this.totalsValue(metric, view.current);
  }

  private metricPrevious(metric: StatMetric): number {
    const view: PlaybackWatchStatsView | null = this.stats;
    return view === null ? 0 : this.totalsValue(metric, view.previous);
  }

  /** 较上期变化的小胶囊：箭头 + 数值，涨绿跌红持平灰 */
  @Builder
  DeltaChip(model: DeltaModel) {
    Row({ space: 2 }) {
      if (model.direction !== 0) {
        Text(model.direction > 0 ? '▲' : '▼')
          .fontSize(8)
          .fontColor(this.deltaColor(model.direction))
      }
      Text(model.text)
        .fontSize(11)
        .fontWeight(600)
        .fontColor(this.deltaColor(model.direction))
    }
    .padding({ left: 5, right: 5, top: 2, bottom: 2 })
    .backgroundColor(this.deltaBackground(model.direction))
    .borderRadius(6)
  }

  // MARK: TOP 3

  /** 最受欢迎 TOP3（对齐 iOS FavoritePodium）：一整张卡，第一名海报模糊铺底 */
  @Builder
  FavoritesCard() {
    if (this.favorites().length === 0) {
      this.EmptyFavoritesCard()
    } else {
      Stack({ alignContent: Alignment.TopStart }) {
        /*
         * 放大模糊铺底（取一张小图就够，宽度和位置都被卡片裁掉）。
         * 高度必须给明确值：外层 Stack 的高度由内容撑开，百分比高度在自适应父容器里不生效，
         * 所以先用 onAreaChange 量出内容高度再铺底。
         */
        Stack({ alignContent: Alignment.Center }) {
          RemoteImage({ url: this.favoritePosterUrl(), placeholderSymbol: $r('sys.symbol.film') })
            .width('150%')
            .height('150%')
            .blur(40)
            .opacity(0.45)
            .hitTestBehavior(HitTestMode.None)
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 90,
              colors: [['#0b0d12', 0.88], ['#0b0d12', 0.75]]
            })
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height(this.podiumHeight)
        .clip(true)
        .hitTestBehavior(HitTestMode.None)
        Column({ space: 18 }) {
          Row({ space: 8 }) {
            Text('TOP 3')
              .fontSize(10)
              .fontWeight(FontWeight.Bolder)
              .letterSpacing(1.2)
              .fontColor(Theme.bg)
              .padding({ left: 6, right: 6, top: 3, bottom: 3 })
              .backgroundColor(Theme.info)
              .borderRadius(3)
            Text(this.drilled() ? '本期看得最多' : '本期最受欢迎')
              .fontSize(14)
              .fontWeight(600)
              .fontColor('rgba(243, 245, 249, 0.9)')
              .maxLines(1)
            Text(this.drilled() ? '按观看时长' : '按看过的人数，并列看时长')
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          ForEach(this.favorites().slice(0, 3), (title: PlaybackStatsTitleRow, index: number) => {
            this.TopEntry(title, index)
          }, (title: PlaybackStatsTitleRow) => `${title.media.media_item_id}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .onAreaChange((_old: Area, area: Area) => {
          this.podiumHeight = Number(area.height);
        })
      }
      .width('100%')
      .borderRadius(Theme.cardRadius)
      .clip(true)
      .border({ width: 1, color: Theme.line })
    }
  }

  /** 上不了榜：范围外 / 没有可上榜作品（对齐 iOS 的 compact 空卡） */
  @Builder
  EmptyFavoritesCard() {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph(this.hiddenTitleCount() > 0 ? $r('sys.symbol.lock_fill') : $r('sys.symbol.star_fill'))
          .fontSize(12)
          .fontColor([Theme.textFaint])
      }
      .width(28)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('rgba(255, 255, 255, 0.05)')
      .borderRadius(14)
      Column({ space: 2 }) {
        Text(this.hiddenTitleCount() > 0 ? '本期最受欢迎的作品都在你的浏览范围外' : '本期还没有可以上榜的作品')
          .fontSize(14)
          .fontColor(Theme.textMuted)
        Text(this.hiddenTitleCount() > 0 ? `${this.hiddenTitleCount()} 部作品来自你设为不可见的库`
          : '播放过的条目已被删除，不再进榜')
          .fontSize(12)
          .fontColor(Theme.textFaint)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.hiddenTitleCount() > 0) {
        this.PillButton('显示全部', (): void => {
          this.pickScope('all');
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(14)
    .backgroundColor('rgba(255, 255, 255, 0.02)')
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: 'rgba(255, 255, 255, 0.07)' })
  }

  /**
   * 一个名次（对齐 iOS TopEntry）：巨大的淡色数字压在左边、海报居中、右侧是事实与名次变化。
   * SwiftUI 的文字描边 / 渐变字在 ArkUI 没有等价物，这里用大号淡色数字代替。
   */
  @Builder
  TopEntry(title: PlaybackStatsTitleRow, rank: number) {
    Row({ space: 0 }) {
      Text(`${rank + 1}`)
        .fontSize(rank === 0 ? 112 : 84)
        .fontWeight(FontWeight.Bolder)
        .fontColor('rgba(255, 255, 255, 0.28)')
        .width(rank === 0 ? 68 : 52)
        .textAlign(TextAlign.Start)
        .maxLines(1)
        .offset({ x: 0, y: rank === 0 ? 14 : 10 })
      RemoteImage({
        url: ImageUrls.resolve(AppModel.origin(), title.media.poster_url ?? null,
          ImageVariant.posterCard) ?? ''
      })
        .width(rank === 0 ? 110 : 76)
        .height(rank === 0 ? 165 : 114)
        .backgroundColor(Theme.surface)
        .borderRadius(8)
        .clip(true)
        .shadow({ radius: 18, color: 'rgba(0, 0, 0, 0.6)', offsetX: 0, offsetY: 12 })
        .onClick(() => {
          this.openMedia(title.media);
        })
      Column({ space: 4 }) {
        Text(this.rankName(rank))
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .letterSpacing(2)
          .fontColor(Theme.textFaint)
        Text(title.media.title.length === 0 ? '（条目已删除）' : title.media.title)
          .fontSize(rank === 0 ? 17 : 14)
          .fontWeight(rank === 0 ? FontWeight.Bold : FontWeight.Medium)
          .fontColor('rgba(243, 245, 249, 0.9)')
          .maxLines(rank === 0 ? 2 : 1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick(() => {
            this.openMedia(title.media);
          })
        if (this.factsText(title.media).length > 0) {
          Text(this.factsText(title.media))
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .maxLines(1)
        }
        Text(this.topStatsLine(title))
          .fontSize(12)
          .fontColor(Theme.textMuted)
          .maxLines(1)
        Text(ActivityFormat.watched(title.watched_ms))
          .fontSize(12)
          .fontColor(Theme.textMuted)
        if (this.rankChange(title, rank) !== null) {
          Text(this.rankChangeText(title, rank))
            .fontSize(11)
            .fontWeight(600)
            .fontColor(this.rankChangeColor(title, rank))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.rankChangeBackground(title, rank))
            .borderRadius(6)
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
  }

  /** @Builder 里不便直接解构 null，拆成三个小取值（都建立在 rankChange 上） */
  private rankChangeText(row: PlaybackStatsTitleRow, rank: number): string {
    const change: RankChange | null = this.rankChange(row, rank);
    return change === null ? '' : change.text;
  }

  private rankChangeColor(row: PlaybackStatsTitleRow, rank: number): string {
    const change: RankChange | null = this.rankChange(row, rank);
    return change === null ? Theme.textFaint : change.color;
  }

  private rankChangeBackground(row: PlaybackStatsTitleRow, rank: number): string {
    const change: RankChange | null = this.rankChange(row, rank);
    if (change === null) {
      return 'rgba(255, 255, 255, 0.08)';
    }
    if (change.color === Theme.info) {
      return 'rgba(127, 176, 255, 0.15)';
    }
    if (change.color === Theme.ok) {
      return `${Theme.ok}26`;
    }
    return 'rgba(255, 255, 255, 0.08)';
  }

  // MARK: 主图

  /** 本周期柱子 + 上一周期虚线（对齐 iOS TrendChart），点柱子看当天读数 */
  @Builder
  TrendCard() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(this.metricLabel(this.metric))
          .fontSize(12)
          .fontWeight(600)
          .fontColor(Theme.textMuted)
        Text(this.weekly() ? '按周' : '按天')
          .fontSize(12)
          .fontColor(Theme.textFaint)
        Blank()
      }
      .width('100%')
      Row() {
        // 纵轴刻度：自上而下 yMax → 0
        Column() {
          ForEach(this.axisLabels(), (label: string, index: number) => {
            Text(label)
              .fontSize(10)
              .fontColor(Theme.textFaint)
              .width('100%')
              .textAlign(TextAlign.End)
              .padding({ right: 4 })
          }, (label: string, index: number) => `${index}-${label}`)
        }
        .width(40)
        .height(200)
        .justifyContent(FlexAlign.SpaceBetween)
        Stack({ alignContent: Alignment.TopStart }) {
          Row() {
            ForEach(this.trendPoints(), (point: TrendPoint, index: number) => {
              Column() {
                Column()
                  .width('62%')
                  .height(this.trendBarHeight(point.current))
                  .borderRadius(3)
                  .backgroundColor(Theme.info)
                  .opacity(this.barOpacity(index))
              }
              .layoutWeight(1)
              .height('100%')
              .justifyContent(FlexAlign.End)
              .onClick(() => {
                this.selectedBucket = this.selectedBucket === index ? -1 : index;
              })
            }, (point: TrendPoint) => `${point.index}-${point.firstDate}`)
          }
          .width('100%')
          .height('100%')
          .alignItems(VerticalAlign.Bottom)
          if (this.showPreviousLine()) {
            Polyline()
              .width('100%')
              .height('100%')
              .points(this.previousPoints())
              .stroke('rgba(255, 255, 255, 0.32)')
              .strokeWidth(1.5)
              .strokeDashArray([4, 4])
              .fillOpacity(0)
              .hitTestBehavior(HitTestMode.None)
          }
          if (this.allCurrentZero()) {
            Column() {
              Text(this.showPreviousLine() ? '本周期没有播放，虚线是上一周期' : '本周期没有播放')
                .fontSize(12)
                .fontColor(Theme.textMuted)
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                .backgroundColor('rgba(0, 0, 0, 0.85)')
                .borderRadius(12)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 30 })
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .layoutWeight(1)
        .height(200)
        .onAreaChange((_old: Area, area: Area) => {
          this.chartWidth = Number(area.width);
        })
      }
      .width('100%')
      // 横轴日期（抽稀；对齐到柱子槽位）
      Row() {
        Blank().width(40)
        Row() {
          ForEach(this.trendPoints(), (point: TrendPoint, index: number) => {
            Column() {
              Text(this.tickVisible(index) ? this.dayLabel(point.firstDate) : ' ')
                .fontSize(9)
                .fontColor(Theme.textFaint)
                .maxLines(1)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }, (point: TrendPoint) => `tick-${point.index}-${point.firstDate}`)
        }
        .layoutWeight(1)
      }
      .width('100%')
      if (this.selectedBucket >= 0 && this.selectedBucket < this.trendPoints().length) {
        this.TrendTooltip(this.trendPoints()[this.selectedBucket])
      }
      Row({ space: 16 }) {
        Row({ space: 6 }) {
          Column()
            .width(10)
            .height(10)
            .borderRadius(3)
            .backgroundColor(Theme.info)
          Text('本周期')
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
        if (this.showPreviousLine()) {
          Row({ space: 6 }) {
            Row({ space: 2 }) {
              ForEach(DASH_SEGMENTS, (segment: number) => {
                Column()
                  .width(4)
                  .height(1.5)
                  .backgroundColor('rgba(255, 255, 255, 0.32)')
              }, (segment: number) => `${segment}`)
            }
            Text('上一周期')
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.cardRadius)
    .border({ width: 1, color: Theme.line })
  }

  /** 点柱子后的读数（对齐 iOS tooltip） */
  @Builder
  TrendTooltip(point: TrendPoint) {
    Column({ space: 3 }) {
      Row({ space: 4 }) {
        Text(point.label)
          .fontSize(12)
          .fontWeight(600)
          .fontColor('rgba(243, 245, 249, 0.85)')
        if (this.weekly() && point.dayCount < 7) {
          Text(`${point.dayCount} 天`)
            .fontSize(12)
            .fontColor(Theme.textFaint)
        }
      }
      Row({ space: 6 }) {
        Column()
          .width(8)
          .height(8)
          .borderRadius(2)
          .backgroundColor(Theme.info)
        Text(`本周期 ${this.bucketNote()}${this.metricFormat(this.metric, point.current)}`)
          .fontSize(12)
          .fontColor('rgba(243, 245, 249, 0.8)')
      }
      if (point.hasPrevious) {
        Row({ space: 6 }) {
          Column()
            .width(8)
            .height(1)
            .backgroundColor('rgba(255, 255, 255, 0.32)')
          Text(`上一周期 ${this.bucketNote()}${this.metricFormat(this.metric, point.previous)}`)
            .fontSize(12)
            .fontColor(Theme.textMuted)
          if (point.previousLabel.length > 0) {
            Text(point.previousLabel)
              .fontSize(12)
              .fontColor(Theme.textFaint)
          }
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('rgba(255, 255, 255, 0.06)')
    .borderRadius(10)
  }

  // MARK: 分解面板

  @Builder
  BreakdownPanels() {
    Column({ space: 16 }) {
      this.MembersPanel()
      this.ClientsPanel()
      this.TitlesPanel()
      this.TiersPanel()
    }
    .width('100%')
  }

  /** 面板头：标题（caption 级）+ 可选说明 */
  @Builder
  PanelTitle(title: string, note: string) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(12)
        .fontWeight(600)
        .fontColor(Theme.textMuted)
      if (note.length > 0) {
        Text(note)
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  PanelEmpty(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(Theme.textFaint)
      .width('100%')
      .padding(14)
  }

  @Builder
  MembersPanel() {
    Column({ space: 6 }) {
      this.PanelTitle('按成员',
        this.drilled() ? '已钻取到一个成员，再点一次取消' : '点成员名钻取')
      Column() {
        if (this.foldOther(this.memberItems(), '个成员', false).length === 0) {
          this.PanelEmpty('本周期没有数据')
        } else {
          ForEach(this.foldOther(this.memberItems(), '个成员', false),
            (item: BreakdownItem, index: number) => {
              if (index > 0) {
                Divider().color('rgba(255, 255, 255, 0.06)')
              }
              this.BreakdownRow(item)
            }, (item: BreakdownItem) => item.key)
        }
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ClientsPanel() {
    Column({ space: 6 }) {
      this.PanelTitle('按客户端', '')
      Column() {
        if (this.foldOther(this.clientItems(), '个客户端', false).length === 0) {
          this.PanelEmpty('本周期没有数据')
        } else {
          ForEach(this.foldOther(this.clientItems(), '个客户端', false),
            (item: BreakdownItem, index: number) => {
              if (index > 0) {
                Divider().color('rgba(255, 255, 255, 0.06)')
              }
              this.BreakdownRow(item)
            }, (item: BreakdownItem) => item.key)
        }
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 看得最多：默认五行，可展开全部；范围外还有多少部放在页脚 */
  @Builder
  TitlesPanel() {
    Column({ space: 6 }) {
      this.PanelTitle('看得最多', '')
      Column() {
        if (this.titleItems().length === 0) {
          if (this.hiddenTitleCount() > 0) {
            this.HiddenTitlesFooter()
          } else {
            this.PanelEmpty('播放过的条目已被删除')
          }
        } else {
          ForEach(this.visibleTitleItems(), (item: BreakdownItem, index: number) => {
            if (index > 0) {
              Divider().color('rgba(255, 255, 255, 0.06)')
            }
            this.BreakdownRow(item)
          }, (item: BreakdownItem) => item.key)
          if (this.titleItems().length > 5) {
            Divider().color('rgba(255, 255, 255, 0.06)')
            Text(this.titlesExpanded ? '收起' : `展开全部 ${this.titleItems().length} 部`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.info)
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .onClick(() => {
                this.titlesExpanded = !this.titlesExpanded;
              })
          }
          if (this.hiddenTitleCount() > 0) {
            this.HiddenTitlesFooter()
          }
        }
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  TiersPanel() {
    Column({ space: 6 }) {
      this.PanelTitle('按播放方式', '仅 MovieClaw 网页与 App 播放；Jellyfin 客户端恒为直连')
      Column() {
        if (this.foldOther(this.tierItems(), '种', true).length === 0) {
          this.PanelEmpty('本周期没有 MovieClaw 网页与 App 播放；Jellyfin 客户端不经过转码，不在这里分解')
        } else {
          ForEach(this.foldOther(this.tierItems(), '种', true),
            (item: BreakdownItem, index: number) => {
              if (index > 0) {
                Divider().color('rgba(255, 255, 255, 0.06)')
              }
              this.BreakdownRow(item)
            }, (item: BreakdownItem) => item.key)
        }
      }
      .width('100%')
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 范围外折叠行：只报个数，不出片名；就地可切到「全部」 */
  @Builder
  HiddenTitlesFooter() {
    Row({ space: 6 }) {
      Text(`另有 ${this.hiddenTitleCount()} 部作品不在你的浏览范围内`)
        .fontSize(12)
        .fontColor(Theme.textFaint)
      Text('·')
        .fontSize(12)
        .fontColor('rgba(243, 245, 249, 0.18)')
      Text('显示全部')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.info)
        .onClick(() => {
          this.pickScope('all');
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
  }

  /** 分解面板的行：名称 · 值 · 占比条（对齐 iOS BreakdownRow） */
  @Builder
  BreakdownRow(item: BreakdownItem) {
    Button() {
      Row({ space: 12 }) {
        if (item.media !== null) {
          RemoteImage({
            url: this.itemPosterUrl(item)
          })
            .width(24)
            .height(36)
            .backgroundColor(Theme.glassFill)
            .borderRadius(5)
            .clip(true)
            .onClick(() => {
              this.openMedia(item.media);
            })
        }
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(this.itemTitle(item))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(item.muted ? Theme.textFaint : 'rgba(243, 245, 249, 0.85)')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .onClick(() => {
                this.openMedia(item.media);
              })
            if (item.secondary.length > 0) {
              Text(item.secondary)
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .maxLines(1)
            }
            Text(item.valueLabel)
              .fontSize(12)
              .fontColor('rgba(243, 245, 249, 0.7)')
              .maxLines(1)
            Text(`${item.share}%`)
              .fontSize(12)
              .fontColor(Theme.textFaint)
              .maxLines(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height(3)
              .borderRadius(2)
              .backgroundColor('rgba(255, 255, 255, 0.06)')
            Column()
              .width(this.barWidth(item.share))
              .height(3)
              .borderRadius(2)
              .backgroundColor(this.shareColor(item))
          }
          .width('100%')
          .height(3)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    }
    .attributeModifier(new GlassButtonModifier(item.selected ? GlassTone.Strong : GlassTone.Secondary))
    .padding(0)
    .clip(true)
    .onClick(() => {
      if (item.memberId >= 0) {
        this.pickMember(this.memberId === item.memberId ? -1 : item.memberId);
      }
    })
  }

  // MARK: 热力图

  /** 星期 × 小时热力图（对齐 iOS HourHeatmap）：小时刻度在上，越深越多 */
  @Builder
  HeatmapCard() {
    Column({ space: 6 }) {
      this.PanelTitle('观看时段', '星期 × 小时的观看时长，越深越多')
      Column({ space: 2 }) {
        if (this.heatTotal() === 0) {
          Text('本周期还没有累计到观看时长；有人看过之后这里会显示星期 × 小时的分布')
            .fontSize(12)
            .fontColor(Theme.textFaint)
            .margin({ bottom: 6 })
        }
        Row({ space: 2 }) {
          Blank().width(18).height(12)
          ForEach(HOUR_SLOTS, (hour: number) => {
            Column() {
              if (hour % 6 === 0) {
                Text(`${hour}`)
                  .fontSize(9)
                  .fontColor(Theme.textFaint)
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }, (hour: number) => `${hour}`)
        }
        .width('100%')
        ForEach(WEEKDAY_LABELS, (label: string, weekday: number) => {
          Row({ space: 2 }) {
            Text(label)
              .fontSize(10)
              .fontColor(Theme.textFaint)
              .width(18)
              .textAlign(TextAlign.Start)
            ForEach(this.heatRow(weekday), (ms: number, hour: number) => {
              Column()
                .layoutWeight(1)
                .height(14)
                .borderRadius(3)
                .backgroundColor(this.heatColor(ms))
            }, (ms: number, hour: number) => `${weekday}-${hour}`)
          }
          .width('100%')
        }, (label: string, weekday: number) => `${weekday}-${label}`)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.cardRadius)
      .border({ width: 1, color: Theme.line })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
