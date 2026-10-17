import { MediaBrief, RecentArrivalView, SeasonOverview, SubscriptionView, TodayArrivalView } from '../api/Models';
import { Theme } from '../theme/AppTheme';
import { Formatters } from '../common/Formatters';
import { ReleaseForecast } from './WantedModel';

/** 今日到货的一行呈现（对应 iOS `TodayArrivalPresentation`）：状态词 + 一个入库时间 */
export class ArrivalPresentation {
  readonly statusLabel: string;
  readonly timeLabel: string;
  /** 预计时刻（epoch ms）；0 = 没有 */
  readonly estimatedAt: number;

  constructor(statusLabel: string, timeLabel: string, estimatedAt: number) {
    this.statusLabel = statusLabel;
    this.timeLabel = timeLabel;
    this.estimatedAt = estimatedAt;
  }

  /** 阶段排序：下载中 1、整理中 2、其余 0（越大越「卡在后段」） */
  stageOrder(): number {
    if (this.statusLabel === '下载中') {
      return 1;
    }
    if (this.statusLabel === '整理中') {
      return 2;
    }
    return 0;
  }

  /** 正在发生的两档（圆点点亮） */
  glows(): boolean {
    return this.statusLabel === '下载中' || this.statusLabel === '整理中';
  }

  toneColor(): string {
    if (this.statusLabel === '下载中') {
      return Theme.info;
    }
    if (this.statusLabel === '整理中') {
      return Theme.ok;
    }
    if (this.statusLabel === '等待资源') {
      return Theme.warn;
    }
    return Theme.textFaint;
  }
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** HH:mm */
function clockText(ms: number): string {
  const d: Date = new Date(ms);
  return `${d.getHours() < 10 ? '0' : ''}${d.getHours()}:${d.getMinutes() < 10 ? '0' : ''}${d.getMinutes()}`;
}

/** 供日程议程行取的紧凑时刻（HH:mm） */
export function arrivalClockText(ms: number): string {
  return clockText(ms);
}

function sameLocalDay(a: number, b: number): boolean {
  const da: Date = new Date(a);
  const db: Date = new Date(b);
  return da.getFullYear() === db.getFullYear() && da.getMonth() === db.getMonth() && da.getDate() === db.getDate();
}

/** 首页只展示一个结果时间：同日写时刻，跨到次日写「明日」，再远写「M月D日 HH:mm」 */
function formatEstimated(ms: number, nowMs: number): string {
  const clock: string = clockText(ms);
  if (sameLocalDay(ms, nowMs)) {
    return `约 ${clock}`;
  }
  const tomorrow: Date = new Date(nowMs);
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (sameLocalDay(ms, tomorrow.getTime())) {
    return `明日 ${clock}`;
  }
  const d: Date = new Date(ms);
  return `${d.getMonth() + 1}月${d.getDate()}日 ${clock}`;
}

/** 站点日历日 `YYYY-MM-DD` → 「M月D日」（按字段切分，不做时区换算） */
function formatCalendarDay(day: string): string {
  const parts: string[] = day.split('-');
  if (parts.length !== 3) {
    return '';
  }
  return `${Number(parts[1])}月${Number(parts[2])}日`;
}

function pendingTimeLabel(arrival: TodayArrivalView): string {
  if (arrival.days_ahead > 0) {
    const day: string = formatCalendarDay(arrival.expected_day);
    if (day.length > 0) {
      return `${day} 播出`;
    }
  }
  const probe: number | null = Formatters.date(arrival.next_probe_at ?? null);
  if (probe !== null) {
    return `${clockText(probe)} 探测`;
  }
  return '时间待更新';
}

function estimatedWantedArrival(arrival: TodayArrivalView, predictedAt: number, nowMs: number): number {
  const delay: number = arrival.estimated_release_to_import_minutes * 60 * 1000;
  const initial: number = predictedAt + delay;
  if (initial >= nowMs) {
    return initial;
  }
  const nextProbe: number | null = Formatters.date(arrival.next_probe_at ?? null);
  if (nextProbe === null) {
    return 0;
  }
  return Math.max(nextProbe, nowMs) + delay;
}

/**
 * 后台阶段 + 出种预测 + 下载器 ETA → 「状态 + 一个入库时间」（同 iOS `TodayArrivals.presentation`）。
 * `etaSeconds` 来自下载器任务快照（没有就传 null）。
 */
export function arrivalPresentation(arrival: TodayArrivalView, etaSeconds: number | null, nowMs: number): ArrivalPresentation {
  if (arrival.status === 'downloaded') {
    return new ArrivalPresentation('整理中', '即将完成', nowMs);
  }
  if (arrival.status === 'grabbed') {
    let estimated: number = 0;
    if (etaSeconds !== null && etaSeconds >= 0) {
      estimated = nowMs + (etaSeconds + arrival.estimated_download_to_import_minutes * 60) * 1000;
    }
    return new ArrivalPresentation('下载中', estimated > 0 ? formatEstimated(estimated, nowMs) : '时间待更新', estimated);
  }
  const forecast: ReleaseForecast | null = ReleaseForecast.of(arrival.release_forecast ?? null);
  const predictedAt: number | null = forecast === null ? null : Formatters.date(forecast.predictedAt);
  const usable: boolean = forecast !== null && forecast.confidence !== 'volatile';
  let estimated: number = 0;
  if (predictedAt !== null && usable) {
    estimated = estimatedWantedArrival(arrival, predictedAt, nowMs);
  }
  const statusLabel: string = predictedAt !== null && predictedAt <= nowMs ? '等待资源' : '预计入库';
  return new ArrivalPresentation(statusLabel, estimated > 0 ? formatEstimated(estimated, nowMs) : pendingTimeLabel(arrival), estimated);
}

/**
 * 订阅首页的判定逻辑（对应 iOS `SubscriptionsHomeModel.swift` 的 `shelf` / `standing` / `meta` /
 * `collectionMeta` / `seasonProgress` / `missingAired` / `released` / `countSummary`）。
 *
 * 首页横滑行与海报墙页共用同一份结果，保证两处顺序与状态签一致。
 */

/** 海报行里一部订阅的位置与小签（phase = active / paused / done） */
export class ShelfStanding {
  readonly phase: string;
  readonly rank: number;
  readonly chipText: string;
  readonly chipColor: string;

  constructor(phase: string, rank: number, chipText: string, chipColor: string) {
    this.phase = phase;
    this.rank = rank;
    this.chipText = chipText;
    this.chipColor = chipColor;
  }
}

/** 一排海报拆成「进行中 / 歇着（暂停 + 已收齐）」 */
export class ShelfSplit {
  readonly active: SubscriptionView[];
  /** 暂停 + 已收齐（横滑里排在分隔线后面） */
  readonly resting: SubscriptionView[];
  /** 暂停（海报墙单独一段） */
  readonly paused: SubscriptionView[];
  /** 已收齐 / 已入库（海报墙单独一段） */
  readonly done: SubscriptionView[];

  constructor(active: SubscriptionView[], paused: SubscriptionView[], done: SubscriptionView[]) {
    this.active = active;
    this.paused = paused;
    this.done = done;
    this.resting = paused.concat(done);
  }

  all(): SubscriptionView[] {
    return this.active.concat(this.resting);
  }
}

/** 按季收录摘要（对应 iOS `SubscriptionCollectionMeta`） */
export class CollectionMeta {
  readonly label: string;
  readonly value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

export class SubsHome {
  private subs: SubscriptionView[];
  private today: TodayArrivalView[];
  private recent: RecentArrivalView[];

  constructor(subs: SubscriptionView[], today: TodayArrivalView[], recent: RecentArrivalView[]) {
    this.subs = subs;
    this.today = today;
    this.recent = recent;
  }

  private static readonly TONE_LIVE: string = Theme.info;
  private static readonly TONE_OK: string = Theme.ok;
  private static readonly TONE_TODAY: string = '#a78bfa';
  private static readonly TONE_WARN: string = Theme.warn;
  private static readonly TONE_UPGRADE: string = '#5eead4';
  private static readonly TONE_CALM: string = Theme.textFaint;

  recentOf(subId: number): RecentArrivalView | null {
    for (const item of this.recent) {
      if (item.subscription_id === subId) {
        return item;
      }
    }
    return null;
  }

  /** 全部到手：电影二元（入库即到手）；剧集要 completed 且有入库 */
  fullyCollected(sub: SubscriptionView): boolean {
    if (sub.media.kind === 'movie') {
      return sub.progress.imported > 0;
    }
    return sub.status === 'completed' && sub.progress.imported > 0;
  }

  /** 电影是否已上映（缺失按已上映处理——宁可说「找资源中」也不误报「未上映」） */
  released(sub: SubscriptionView): boolean {
    const status: string | null = sub.media.status ?? null;
    return status === null || status.length === 0 || status === 'Released';
  }

  private nearestArrivalDays(subId: number): number {
    let best: number = -1;
    for (const item of this.today) {
      if (item.subscription_id === subId && (best < 0 || item.days_ahead < best)) {
        best = item.days_ahead;
      }
    }
    return best;
  }

  /** 一部订阅的位置与小签（对应 iOS `standing`） */
  standing(sub: SubscriptionView): ShelfStanding {
    const isTV: boolean = sub.media.kind === 'tv';
    if (sub.status === 'paused') {
      return new ShelfStanding('paused', 0, '已暂停', SubsHome.TONE_CALM);
    }
    if (sub.progress.downloaded > 0) {
      return new ShelfStanding('active', 0, '整理中', SubsHome.TONE_OK);
    }
    if (sub.progress.grabbed > 0) {
      return new ShelfStanding('active', 0, '下载中', SubsHome.TONE_LIVE);
    }
    const upgrading: boolean = sub.progress.upgrading > 0;
    if (this.fullyCollected(sub) || sub.status === 'completed') {
      return upgrading
        ? new ShelfStanding('active', 4, '洗版中', SubsHome.TONE_UPGRADE)
        : new ShelfStanding('done', 0, '', '');
    }
    if (isTV) {
      const recent: RecentArrivalView | null = this.recentOf(sub.id);
      if (recent !== null) {
        const count: number = recent.units.length;
        return new ShelfStanding('active', 1, count > 1 ? `新 ${count} 集` : '新一集', SubsHome.TONE_OK);
      }
    }
    const days: number = this.nearestArrivalDays(sub.id);
    if (days >= 0) {
      if (days === 0) {
        return new ShelfStanding('active', 2, '今天更新', SubsHome.TONE_TODAY);
      }
      const when: string = days === 1 ? '明天' : `${days} 天后`;
      return new ShelfStanding('active', 3 + days / 100, `${when}更新`, SubsHome.TONE_CALM);
    }
    if (upgrading) {
      return new ShelfStanding('active', 4, '洗版中', SubsHome.TONE_UPGRADE);
    }
    if (isTV) {
      const missing: number = this.missingAired(sub);
      return missing > 0
        ? new ShelfStanding('active', 5, `缺 ${missing} 集`, SubsHome.TONE_WARN)
        : new ShelfStanding('active', 6, '', '');
    }
    return this.released(sub)
      ? new ShelfStanding('active', 5, '找资源中', SubsHome.TONE_WARN)
      : new ShelfStanding('active', 7, '未上映', SubsHome.TONE_CALM);
  }

  isResting(sub: SubscriptionView): boolean {
    return this.standing(sub).phase !== 'active';
  }

  /** 已播出但库里还没有的集数（缺集）：只看勾选的季；没勾季看最新一季 */
  private missingAired(sub: SubscriptionView): number {
    const seasons: SeasonOverview[] = this.positiveSeasons(sub.season_collection);
    if (seasons.length === 0) {
      return 0;
    }
    const selected: number[] = sub.selected_seasons.filter((s: number): boolean => s > 0);
    const scoped: SeasonOverview[] = selected.length > 0
      ? seasons.filter((s: SeasonOverview): boolean => selected.indexOf(s.season_number) >= 0)
      : [seasons[seasons.length - 1]];
    let total: number = 0;
    for (const season of scoped) {
      const missing: number = season.aired_count - season.owned_count;
      if (missing > 0) {
        total += missing;
      }
    }
    return total;
  }

  private positiveSeasons(list: SeasonOverview[]): SeasonOverview[] {
    const out: SeasonOverview[] = [];
    for (const season of list) {
      if (season.season_number > 0) {
        out.push(season);
      }
    }
    out.sort((a: SeasonOverview, b: SeasonOverview): number => a.season_number - b.season_number);
    return out;
  }

  private totalOf(season: SeasonOverview): number {
    const count: number = season.episode_count ?? 0;
    return Math.max(count, Math.max(season.aired_count, season.owned_count));
  }

  /** 海报下第二行（对应 iOS `meta`） */
  meta(sub: SubscriptionView, phase: string): string {
    const year: number | null = sub.media.year ?? null;
    const yearText: string = year !== null && year > 0 ? `${year}` : '';
    if (sub.media.kind === 'movie') {
      if (sub.progress.imported > 0) {
        return yearText.length > 0 ? `${yearText} · 已入库` : '已入库';
      }
      return yearText.length > 0 ? yearText : '电影';
    }
    const meta: CollectionMeta | null = this.collectionMeta(sub);
    if (meta === null) {
      return yearText.length > 0 ? yearText : '剧集';
    }
    if (phase === 'done') {
      return `已收齐 · ${meta.label}`;
    }
    return `${meta.label} · ${meta.value}`;
  }

  /** 把按季库存压成一行（对应 iOS `collectionMeta`） */
  private collectionMeta(sub: SubscriptionView): CollectionMeta | null {
    if (sub.media.kind !== 'tv') {
      return null;
    }
    const allSeasons: SeasonOverview[] = this.positiveSeasons(sub.season_collection);
    if (allSeasons.length === 0) {
      return null;
    }
    const selected: number[] = sub.selected_seasons.filter((s: number): boolean => s > 0);
    let scoped: SeasonOverview[] = selected.length === 0
      ? allSeasons
      : allSeasons.filter((s: SeasonOverview): boolean => selected.indexOf(s.season_number) >= 0);
    const mediaStatus: string = (sub.media.status ?? '').toLowerCase();
    const ended: boolean = sub.status === 'completed' || mediaStatus === 'ended' || mediaStatus === 'canceled';
    if (!ended && sub.follow_future) {
      const latest: SeasonOverview = allSeasons[allSeasons.length - 1];
      let has: boolean = false;
      for (const season of scoped) {
        if (season.season_number === latest.season_number) {
          has = true;
        }
      }
      if (!has) {
        scoped = scoped.concat([latest]);
        scoped.sort((a: SeasonOverview, b: SeasonOverview): number => a.season_number - b.season_number);
      }
    }
    if (scoped.length === 0) {
      return null;
    }
    if (!ended) {
      const latest: SeasonOverview = scoped[scoped.length - 1];
      const total: number = this.totalOf(latest);
      const value: string = latest.aired_count === 0 && latest.owned_count === 0
        ? '待播出' : `${latest.owned_count} / ${total}`;
      return new CollectionMeta(`第 ${latest.season_number} 季`, value);
    }
    let total: number = 0;
    let owned: number = 0;
    for (const season of scoped) {
      total += this.totalOf(season);
      owned += season.owned_count;
    }
    if (total <= 0) {
      return null;
    }
    const coversAll: boolean = scoped.length === allSeasons.length;
    const label: string = scoped.length === 1
      ? `第 ${scoped[0].season_number} 季`
      : `${coversAll ? '全' : '共'} ${scoped.length} 季`;
    const value: string = owned >= total ? `全 ${total} 集` : `${owned} / ${total}`;
    return new CollectionMeta(label, value);
  }

  /** 剧集当季收录比例（海报底部细线）；-1 = 不画 */
  seasonProgress(sub: SubscriptionView): number {
    if (sub.media.kind !== 'tv') {
      return -1;
    }
    const seasons: SeasonOverview[] = this.positiveSeasons(sub.season_collection);
    if (seasons.length === 0) {
      return -1;
    }
    const selected: number[] = sub.selected_seasons.filter((s: number): boolean => s > 0);
    const scoped: SeasonOverview[] = selected.length === 0
      ? seasons
      : seasons.filter((s: SeasonOverview): boolean => selected.indexOf(s.season_number) >= 0);
    let latest: SeasonOverview | null = sub.follow_future ? seasons[seasons.length - 1] : null;
    if (latest === null && scoped.length > 0) {
      latest = scoped[scoped.length - 1];
    }
    if (latest === null) {
      return -1;
    }
    const total: number = this.totalOf(latest);
    if (total <= 0) {
      return -1;
    }
    return Math.min(1, latest.owned_count / total);
  }

  /** 一排拆成「进行中 / 歇着」，进行中按此刻最要紧排前面（对应 iOS `shelf`） */
  shelfSplit(kind: string): ShelfSplit {
    const active: SubscriptionView[] = [];
    const paused: SubscriptionView[] = [];
    const done: SubscriptionView[] = [];
    for (const sub of this.subs) {
      if (sub.media.kind !== kind) {
        continue;
      }
      const phase: string = this.standing(sub).phase;
      if (phase === 'paused') {
        paused.push(sub);
      } else if (phase === 'done') {
        done.push(sub);
      } else {
        active.push(sub);
      }
    }
    active.sort((a: SubscriptionView, b: SubscriptionView): number => {
      const ra: number = this.standing(a).rank;
      const rb: number = this.standing(b).rank;
      return ra !== rb ? ra - rb : this.recentFirst(a, b);
    });
    paused.sort((a: SubscriptionView, b: SubscriptionView): number => this.recentFirst(a, b));
    done.sort((a: SubscriptionView, b: SubscriptionView): number => this.recentFirst(a, b));
    return new ShelfSplit(active, paused, done);
  }

  private recentFirst(a: SubscriptionView, b: SubscriptionView): number {
    if (a.updated_at !== b.updated_at) {
      return a.updated_at > b.updated_at ? -1 : 1;
    }
    if (a.media.title === b.media.title) {
      return 0;
    }
    return a.media.title < b.media.title ? -1 : 1;
  }

  /** 一排的计数：「N 部进行中 · 共 M 部」（全在追或一部没有时只说总数） */
  countSummary(kind: string): string {
    const split: ShelfSplit = this.shelfSplit(kind);
    const total: number = split.active.length + split.resting.length;
    if (split.active.length > 0 && split.active.length < total) {
      return `${split.active.length} 部进行中 · 共 ${total} 部`;
    }
    return `共 ${total} 部`;
  }

  restingLabel(kind: string): string {
    const split: ShelfSplit = this.shelfSplit(kind);
    const doneLabel: string = kind === 'movie' ? '已入库' : '已收齐';
    if (split.paused.length > 0 && split.done.length > 0) {
      return `暂停·${doneLabel.substring(1)}`;
    }
    return split.paused.length > 0 ? '已暂停' : doneLabel;
  }
}

// MARK: - Hero 轮播（对应 iOS `SubscriptionsHome.heroSlides` + `SubsHomeHeroSlide`）

/** Hero 一页（同 iOS `SubsHomeHeroSlide`） */
export class HeroSlide {
  readonly subscriptionId: number;
  readonly media: MediaBrief;
  /** downloading / organizing / today / arrived / upcoming / resting */
  readonly stage: string;
  readonly eyebrowText: string;
  readonly eyebrowTone: string;
  readonly eyebrowPulse: boolean;
  /** 大号时刻上方的小字（保留结尾，同 iOS `keep: .head`） */
  readonly clockLabel: string;
  /** 大号细体时刻；'' = 没有，改走 detail/footnote 那支 */
  readonly clock: string;
  readonly detail: string;
  readonly footnote: string;
  /** 进行中进度 0~1；-1 = 不画 */
  readonly progress: number;
  readonly resumePercent: number;
  /** 可播（有刚入库的单元） */
  readonly playable: boolean;

  constructor(subscriptionId: number, media: MediaBrief, stage: string, eyebrowText: string, eyebrowTone: string,
    eyebrowPulse: boolean, clockLabel: string, clock: string, detail: string, footnote: string,
    progress: number, resumePercent: number, playable: boolean) {
    this.subscriptionId = subscriptionId;
    this.media = media;
    this.stage = stage;
    this.eyebrowText = eyebrowText;
    this.eyebrowTone = eyebrowTone;
    this.eyebrowPulse = eyebrowPulse;
    this.clockLabel = clockLabel;
    this.clock = clock;
    this.detail = detail;
    this.footnote = footnote;
    this.progress = progress;
    this.resumePercent = resumePercent;
    this.playable = playable;
  }
}

/** 同一（订阅 + 日期）的一组到货（对应 iOS `ArrivalGroup`） */
export class HeroGroup {
  readonly subscriptionId: number;
  readonly media: MediaBrief;
  readonly daysAhead: number;
  readonly expectedDay: string;
  readonly label: string;
  readonly presentation: ArrivalPresentation;
  /** 组内下载中单元的平均进度 0~1；-1 = 无 */
  readonly progress: number;
  /** 整理中：预计能看的时刻（组内取最晚）；0 = 无 */
  readonly readyAt: number;

  constructor(subscriptionId: number, media: MediaBrief, daysAhead: number, expectedDay: string, label: string,
    presentation: ArrivalPresentation, progress: number, readyAt: number) {
    this.subscriptionId = subscriptionId;
    this.media = media;
    this.daysAhead = daysAhead;
    this.expectedDay = expectedDay;
    this.label = label;
    this.presentation = presentation;
    this.progress = progress;
    this.readyAt = readyAt;
  }
}

/** 入库时间（同 iOS `importedAt`） */
function importedAtMs(card: RecentArrivalView): number {
  return Formatters.date(card.imported_at) ?? 0;
}

/** 大号时刻：同日写时刻、明天写「明天 HH:mm」、否则「M月D日 HH:mm」（同 iOS `SubscriptionsHome.clockText`） */
export function heroClockText(ms: number, nowMs: number): string {
  const clock: string = clockText(ms);
  if (sameLocalDay(ms, nowMs)) {
    return clock;
  }
  const tomorrow: Date = new Date(nowMs);
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (sameLocalDay(ms, tomorrow.getTime())) {
    return `明天 ${clock}`;
  }
  const d: Date = new Date(ms);
  return `${d.getMonth() + 1}月${d.getDate()}日 ${clock}`;
}

/** 站点日历日 `YYYY-MM-DD` → 「周四」（按 UTC 日历日算，同 iOS `weekday(of:)`） */
export function heroWeekday(day: string): string {
  const ms: number | null = Formatters.date(day);
  if (ms === null) {
    return '';
  }
  const names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  return names[new Date(ms).getUTCDay()];
}

/** Hero 上限与「刚到」窗口（同 iOS `maxHeroSlides` / `freshArrivalWindow`） */
const MAX_HERO_SLIDES: number = 5;
const FRESH_ARRIVAL_WINDOW_MS: number = 48 * 3600 * 1000;

/** 预告行 → 按（订阅 + 日期）分组（同 iOS `arrivalGroups` 的分组口径；`etaByHash` = info_hash → ETA 秒） */
export function heroGroups(arrivals: TodayArrivalView[], subs: SubscriptionView[],
  etaByHash: Record<string, number>, nowMs: number): HeroGroup[] {
  const byId: Record<string, SubscriptionView> = {};
  for (const sub of subs) {
    byId[`${sub.id}`] = sub;
  }
  const order: string[] = [];
  const buckets: Record<string, TodayArrivalView[]> = {};
  for (const arrival of arrivals) {
    const key: string = `${arrival.subscription_id}-${arrival.days_ahead}`;
    if (buckets[key] === undefined) {
      order.push(key);
      buckets[key] = [];
    }
    buckets[key].push(arrival);
  }
  const out: HeroGroup[] = [];
  for (const key of order) {
    const rows: TodayArrivalView[] = buckets[key];
    const first: TodayArrivalView = rows[0];
    const sub: SubscriptionView | undefined = byId[`${first.subscription_id}`];
    if (sub === undefined) {
      continue;
    }
    // 组内「最卡的那一步」（同 iOS 取 blocking presentation）
    let blocking: ArrivalPresentation | null = null;
    const downloading: number[] = [];
    const ready: number[] = [];
    const seasons: number[] = [];
    const episodes: number[][] = [];
    for (const row of rows) {
      const etha: number | null = etaByHash[row.info_hash === null || row.info_hash === undefined
        ? '' : row.info_hash.toLowerCase()] ?? null;
      const pres: ArrivalPresentation = arrivalPresentation(row, etha, nowMs);
      if (blocking === null || pres.stageOrder() !== blocking.stageOrder()) {
        blocking = blocking === null || pres.stageOrder() > blocking.stageOrder() ? pres : blocking;
      } else if (pres.estimatedAt > blocking.estimatedAt) {
        blocking = pres;
      }
      if (row.status === 'grabbed' && etha !== null) {
        downloading.push(0);
      }
      if (row.status === 'downloaded') {
        const done: number | null = Formatters.date(row.downloaded_at ?? null);
        if (done !== null) {
          ready.push(done + row.estimated_download_to_import_minutes * 60 * 1000);
        }
      }
      let at: number = seasons.indexOf(row.season_number);
      if (at < 0) {
        seasons.push(row.season_number);
        episodes.push([]);
        at = seasons.length - 1;
      }
      episodes[at].push(row.episode_number);
    }
    // 组内标签（同 iOS `ArrivalGroup.episodeLabel`）
    let label: string = '电影';
    if (sub.media.kind !== 'movie') {
      const parts: string[] = [];
      for (let i = 0; i < seasons.length; i++) {
        parts.push(`S${pad2(seasons[i])}${rangeText(episodes[i])}`);
      }
      label = parts.join(' · ');
    }
    let readyAt: number = 0;
    for (const value of ready) {
      if (value > readyAt) {
        readyAt = value;
      }
    }
    out.push(new HeroGroup(first.subscription_id, sub.media, first.days_ahead, first.expected_day, label,
      blocking === null ? new ArrivalPresentation('预计入库', '', 0) : blocking, -1, readyAt));
  }
  return out;
}

function rangeText(episodes: number[]): string {
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

function slideFromGroup(group: HeroGroup, nowMs: number): HeroSlide {
  const pres: ArrivalPresentation = group.presentation;
  const label: string = group.label;
  const isMovie: boolean = group.media.kind === 'movie';
  let stage: string = 'today';
  let eyebrowText: string = '今天更新';
  let eyebrowTone: string = '#a78bfa';
  let eyebrowPulse: boolean = false;
  let clockLabel: string = '';
  let clock: string = '';
  let detail: string = '';
  let footnote: string = '';
  let progress: number = -1;

  if (pres.statusLabel === '下载中') {
    stage = 'downloading';
    const percent: string = group.progress >= 0 ? ` · ${Math.round(group.progress * 100)}%` : '';
    eyebrowText = `下载中${percent}`;
    eyebrowTone = Theme.info;
    eyebrowPulse = true;
    progress = group.progress;
    if (pres.estimatedAt > 0) {
      clockLabel = isMovie ? '预计可看' : `${label} · 预计可看`;
      clock = heroClockText(pres.estimatedAt, nowMs);
    } else {
      detail = isMovie ? '正在下载' : `${label} · 正在下载`;
      footnote = '下载完成后自动整理入库';
    }
  } else if (pres.statusLabel === '整理中') {
    stage = 'organizing';
    eyebrowText = '整理中';
    eyebrowTone = Theme.ok;
    eyebrowPulse = true;
    if (group.readyAt > nowMs) {
      clockLabel = isMovie ? '下载完成 · 预计可看' : `${label} · 预计可看`;
      clock = heroClockText(group.readyAt, nowMs);
    } else {
      clockLabel = isMovie ? '下载完成' : `${label} · 下载完成`;
      clock = '马上就好';
    }
  } else if (group.daysAhead > 0) {
    stage = 'upcoming';
    eyebrowText = '即将更新';
    eyebrowTone = Theme.textFaint;
    clockLabel = `${label} · ${formatCalendarDay(group.expectedDay)}`;
    const weekday: string = heroWeekday(group.expectedDay);
    clock = group.daysAhead === 1 ? '明天' : (weekday.length > 0 ? weekday : `${group.daysAhead} 天后`);
  } else {
    stage = 'today';
    if (pres.statusLabel === '等待资源') {
      eyebrowText = '等待资源';
      eyebrowTone = Theme.warn;
    }
    if (pres.estimatedAt > 0) {
      clockLabel = `${label} · 预计入库`;
      clock = heroClockText(pres.estimatedAt, nowMs);
    } else {
      detail = label;
      footnote = pres.timeLabel;
    }
  }
  return new HeroSlide(group.subscriptionId, group.media, stage, eyebrowText, eyebrowTone, eyebrowPulse,
    clockLabel, clock, detail, footnote, progress, -1, false);
}

function slideFromRecent(card: RecentArrivalView, nowMs: number): HeroSlide {
  const isTV: boolean = card.media.kind === 'tv';
  const imported: number = importedAtMs(card);
  const fresh: boolean = imported > 0 && nowMs - imported <= 24 * 3600 * 1000;
  let footnote: string = imported > 0 ? `${Formatters.fromNow(imported, nowMs)}入库` : '已入库';
  if (card.units.length > 1) {
    footnote += ` · 共 ${card.units.length} 集新内容`;
  }
  const percent: number | null = card.progress_percent ?? null;
  return new HeroSlide(card.subscription_id, card.media, 'arrived',
    fresh ? '刚刚入库' : (isTV ? '新一集' : '新入库'), Theme.ok, false,
    '', '', recentDetailOf(card), footnote, -1, percent === null ? -1 : percent, true);
}

/** 「S04E01 · 集名」/「2025 · 电影」（同 iOS `recentDetail`） */
function recentDetailOf(card: RecentArrivalView): string {
  if (card.media.kind !== 'tv') {
    const year: number | null = card.media.year ?? null;
    return year !== null && year > 0 ? `${year} · 电影` : '电影';
  }
  const code: string = `S${pad2(card.season_number)}E${pad2(card.episode_number)}`;
  const name: string = card.episode_name ?? '';
  return name.length > 0 ? `${code} · ${name}` : code;
}

function restingSlide(sub: SubscriptionView): HeroSlide {
  let eyebrowText: string = '追踪中';
  let eyebrowTone: string = Theme.textFaint;
  if (sub.status === 'paused') {
    eyebrowText = '已暂停';
  } else if (sub.status === 'completed') {
    eyebrowText = sub.media.kind === 'movie' ? '已入库' : '已收齐';
    eyebrowTone = Theme.ok;
  }
  const isMovie: boolean = sub.media.kind === 'movie';
  const year: number | null = sub.media.year ?? null;
  const yearText: string = year !== null && year > 0 ? `${year}` : '';
  let detail: string = '';
  let footnote: string = '';
  if (isMovie) {
    detail = yearText.length > 0 ? `${yearText} · 电影` : '电影';
    footnote = sub.progress.imported > 0
      ? '已在媒体库里'
      : (releasedOf(sub) ? '找到合适的资源就会自动下载' : '上映后开始找资源');
  } else {
    detail = yearText.length > 0 ? `${yearText} · 剧集` : '剧集';
    footnote = sub.status === 'active' ? '有新一集会自动下载入库' : '';
  }
  return new HeroSlide(sub.id, sub.media, 'resting', eyebrowText, eyebrowTone, false,
    '', '', detail, footnote, -1, -1, false);
}

function releasedOf(sub: SubscriptionView): boolean {
  const status: string | null = sub.media.status ?? null;
  return status === null || status.length === 0 || status === 'Released';
}

/** Hero 的几张（同 iOS `SubscriptionsHome.heroSlides`）：先讲正在发生的，再讲刚到的，再讲今天与最近的预告 */
export function buildHeroSlides(subs: SubscriptionView[], groups: HeroGroup[], recent: RecentArrivalView[],
  nowMs: number): HeroSlide[] {
  const pipeline: HeroGroup[] = groups
    .filter((group: HeroGroup): boolean => group.presentation.stageOrder() > 0)
    .sort((left: HeroGroup, right: HeroGroup): number => {
      if (left.presentation.stageOrder() !== right.presentation.stageOrder()) {
        return right.presentation.stageOrder() - left.presentation.stageOrder();
      }
      const le: number = left.presentation.estimatedAt > 0 ? left.presentation.estimatedAt : Number.MAX_SAFE_INTEGER;
      const re: number = right.presentation.estimatedAt > 0 ? right.presentation.estimatedAt : Number.MAX_SAFE_INTEGER;
      return le - re;
    });
  const arrived: RecentArrivalView[] = recent.slice()
    .sort((a: RecentArrivalView, b: RecentArrivalView): number => importedAtMs(b) - importedAtMs(a));
  const fresh: RecentArrivalView[] = arrived.filter(
    (card: RecentArrivalView): boolean => nowMs - importedAtMs(card) <= FRESH_ARRIVAL_WINDOW_MS);
  const older: RecentArrivalView[] = arrived.filter(
    (card: RecentArrivalView): boolean => nowMs - importedAtMs(card) > FRESH_ARRIVAL_WINDOW_MS);
  const today: HeroGroup[] = groups
    .filter((group: HeroGroup): boolean => group.daysAhead === 0 && group.presentation.stageOrder() === 0)
    .sort((a: HeroGroup, b: HeroGroup): number => {
      const ae: number = a.presentation.estimatedAt > 0 ? a.presentation.estimatedAt : Number.MAX_SAFE_INTEGER;
      const be: number = b.presentation.estimatedAt > 0 ? b.presentation.estimatedAt : Number.MAX_SAFE_INTEGER;
      return ae - be;
    });
  let nearest: number = -1;
  for (const group of groups) {
    if (group.daysAhead > 0 && (nearest < 0 || group.daysAhead < nearest)) {
      nearest = group.daysAhead;
    }
  }
  const upcoming: HeroGroup[] = groups.filter(
    (group: HeroGroup): boolean => group.daysAhead === nearest && group.presentation.stageOrder() === 0);

  const slides: HeroSlide[] = [];
  const seen: number[] = [];
  const append = (slide: HeroSlide | null): void => {
    if (slide === null || slides.length >= MAX_HERO_SLIDES || seen.indexOf(slide.subscriptionId) >= 0) {
      return;
    }
    seen.push(slide.subscriptionId);
    slides.push(slide);
  };
  for (const group of pipeline) {
    append(slideFromGroup(group, nowMs));
  }
  for (const card of fresh) {
    append(slideFromRecent(card, nowMs));
  }
  for (const group of today) {
    append(slideFromGroup(group, nowMs));
  }
  for (const card of older) {
    append(slideFromRecent(card, nowMs));
  }
  for (const group of upcoming) {
    append(slideFromGroup(group, nowMs));
  }
  if (slides.length === 0) {
    // 退路：在追的优先，其次最近动过的（同 iOS）
    const ranked: SubscriptionView[] = subs.slice().sort(
      (left: SubscriptionView, right: SubscriptionView): number => {
        const l: number = left.status === 'active' ? 0 : 1;
        const r: number = right.status === 'active' ? 0 : 1;
        if (l !== r) {
          return l - r;
        }
        if (left.updated_at !== right.updated_at) {
          return left.updated_at > right.updated_at ? -1 : 1;
        }
        return 0;
      });
    for (const sub of ranked.slice(0, 3)) {
      append(restingSlide(sub));
    }
  }
  return slides;
}
