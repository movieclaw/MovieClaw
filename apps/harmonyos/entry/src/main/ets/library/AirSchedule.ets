/**
 * 剧集详情页播出日历（issue #547）的纯计算：季进度条分段、下次更新、更新规律、
 * 按天的日程。日期一律是 YYYY-MM-DD 的日历日，按字段比较与换算（UTC 零点），
 * 不经设备时区——「今天」由服务端按站点日历给出。
 *
 * 口径与 Web 端 `apps/web/lib/air-schedule.ts` 逐一对应；文案是简体中文（本应用中文优先）。
 */
import { EpisodeArrivalView, EpisodeView, SeasonAirScheduleView } from '../api/Models';

/** 一集在播出日历里的状态 */
export enum AirTone {
  /** 已入库 */
  Owned = 'owned',
  /** 订阅范围内已播出、还没入库 */
  Missing = 'missing',
  /** 今天播出，订阅在追 */
  Today = 'today',
  /** 今天播出，没订阅 */
  TodayFree = 'todayFree',
  /** 还没播（含没定日期的） */
  Upcoming = 'upcoming',
  /** 已播出、库里没有，但不算缺（没订阅 / 订阅起始集之前） */
  Absent = 'absent'
}

/** 季进度条的一段：同状态的连续集合并（超过 40 集才合并，一集一格太细） */
export class AirSegment {
  readonly tone: AirTone;
  /** 合并的集数；不合并时恒为 1 */
  readonly count: number;

  constructor(tone: AirTone, count: number) {
    this.tone = tone;
    this.count = count;
  }
}

/** 一个播出日：同日播出的集 + 相对今天的旗标 */
export class AirDay {
  readonly date: string;
  readonly episodes: EpisodeView[];
  readonly past: boolean;
  readonly today: boolean;
  readonly finale: boolean;

  constructor(date: string, episodes: EpisodeView[], past: boolean, today: boolean, finale: boolean) {
    this.date = date;
    this.episodes = episodes;
    this.past = past;
    this.today = today;
    this.finale = finale;
  }
}

/** 「今天/下次更新」右侧的入库预告走到哪了 */
export enum ArrivalKind {
  InLibrary,
  NotSubscribed,
  Downloading,
  Organizing,
  Expected,
  Waiting
}

export class ArrivalState {
  readonly kind: ArrivalKind;
  /** 预计入库时刻（带时区 ISO）；只有 Expected 用 */
  readonly expectedAt: string | null;

  constructor(kind: ArrivalKind, expectedAt: string | null = null) {
    this.kind = kind;
    this.expectedAt = expectedAt;
  }
}

/** 季进度条的图例统计 */
export class AirCounts {
  readonly owned: number;
  readonly missing: number;
  readonly upcoming: number;

  constructor(owned: number, missing: number, upcoming: number) {
    this.owned = owned;
    this.missing = missing;
    this.upcoming = upcoming;
  }
}

/** 两个播出日之间的停更说明 */
export class AirGap {
  /** 停更一周以上（真停更，周更剧也画） */
  readonly isBreak: boolean;
  readonly text: string;

  constructor(isBreak: boolean, text: string) {
    this.isBreak = isBreak;
    this.text = text;
  }
}

const DAY_MS: number = 86400000;
/** 超过这么多集就把同状态的连续集合并成色段 */
const MERGE_ABOVE: number = 40;
/** 星期名（0=周一…6=周日） */
const WEEKDAY_NAMES: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** YYYY-MM-DD → UTC 零点毫秒（纯日历日，不做时区换算） */
export function dayTime(day: string): number {
  const parts: string[] = day.slice(0, 10).split('-');
  if (parts.length !== 3) {
    return 0;
  }
  const year: number = Number(parts[0]);
  const month: number = Number(parts[1]);
  const date: number = Number(parts[2]);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(date)) {
    return 0;
  }
  return Date.UTC(year, month - 1, date);
}

export function daysBetween(from: string, to: string): number {
  return Math.round((dayTime(to) - dayTime(from)) / DAY_MS);
}

/** 「10月28日」 */
export function formatAirDay(day: string): string {
  const parts: string[] = day.slice(0, 10).split('-');
  if (parts.length !== 3) {
    return day;
  }
  return `${Number(parts[1])}月${Number(parts[2])}日`;
}

/** 周一…周日（0=周一…6=周日） */
export function weekdayName(index: number): string {
  const at: number = ((index % 7) + 7) % 7;
  return WEEKDAY_NAMES[at];
}

/** 「周三」（按日历日算，不经设备时区） */
export function formatWeekday(day: string): string {
  // 1970-01-01 是周四：折算成周一=0 的星期序号
  const dayIndex: number = Math.floor(dayTime(day) / DAY_MS);
  return weekdayName((dayIndex + 3) % 7);
}

/** 日历日平移：offset 天后/前的 YYYY-MM-DD */
function shiftDay(day: string, offset: number): string {
  const date: Date = new Date(dayTime(day) + offset * DAY_MS);
  return `${date.getUTCFullYear()}-${pad2(date.getUTCMonth() + 1)}-${pad2(date.getUTCDate())}`;
}

/** 预计入库时刻：「18:30」，跨天带「10月30日 18:30」（按设备时区显示） */
export function expectedClock(at: string): string {
  const date: Date = new Date(at);
  if (Number.isNaN(date.getTime())) {
    return '';
  }
  const now: Date = new Date();
  const sameDay: boolean = date.getFullYear() === now.getFullYear()
    && date.getMonth() === now.getMonth()
    && date.getDate() === now.getDate();
  const clock: string = `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
  if (sameDay) {
    return clock;
  }
  return `${date.getMonth() + 1}月${date.getDate()}日 ${clock}`;
}

/** 常见首播地区码 → 中文名；不认识的退回原码（同 Web 的 Intl.DisplayNames 回退） */
export function regionName(code: string): string {
  const names: Record<string, string> = {
    'US': '美国',
    'GB': '英国',
    'JP': '日本',
    'KR': '韩国',
    'CN': '中国大陆',
    'HK': '中国香港',
    'TW': '中国台湾',
    'CA': '加拿大',
    'AU': '澳大利亚',
    'FR': '法国',
    'DE': '德国',
    'ES': '西班牙',
    'IT': '意大利',
    'IN': '印度',
    'TH': '泰国',
    'RU': '俄罗斯',
    'MX': '墨西哥',
    'BR': '巴西',
    'SE': '瑞典',
    'NO': '挪威',
    'DK': '丹麦',
    'FI': '芬兰',
    'NL': '荷兰',
    'SG': '新加坡'
  };
  const name: string | undefined = names[code];
  return name ?? code;
}

/** 一集的状态：已入库 / 缺集 / 今天 / 待播 / 不算缺的缺失 */
export function episodeTone(episode: EpisodeView, schedule: SeasonAirScheduleView): AirTone {
  if (episode.owned) {
    return AirTone.Owned;
  }
  const missing: number[] = schedule.missing_episodes;
  for (let i = 0; i < missing.length; i++) {
    if (missing[i] === episode.episode_number) {
      return AirTone.Missing;
    }
  }
  const airDate: string = episode.air_date ?? '';
  if (airDate.length === 0) {
    return AirTone.Upcoming;
  }
  const offset: number = daysBetween(schedule.today, airDate);
  if (offset > 0) {
    return AirTone.Upcoming;
  }
  if (offset === 0) {
    return (schedule.subscription_id ?? null) !== null ? AirTone.Today : AirTone.TodayFree;
  }
  return AirTone.Absent;
}

/** 季进度条的段：≤40 集一集一格，>40 集合并同状态的连续集 */
export function airSegments(episodes: EpisodeView[], schedule: SeasonAirScheduleView): AirSegment[] {
  const out: AirSegment[] = [];
  const merge: boolean = episodes.length > MERGE_ABOVE;
  for (const episode of episodes) {
    const tone: AirTone = episodeTone(episode, schedule);
    const last: AirSegment | undefined = out.length > 0 ? out[out.length - 1] : undefined;
    if (merge && last !== undefined && last.tone === tone) {
      out[out.length - 1] = new AirSegment(tone, last.count + 1);
    } else {
      out.push(new AirSegment(tone, 1));
    }
  }
  return out;
}

/** 图例统计：已入库 / 缺集（按订阅口径）/ 待播 */
export function airCounts(episodes: EpisodeView[], schedule: SeasonAirScheduleView): AirCounts {
  let owned: number = 0;
  let upcoming: number = 0;
  for (const episode of episodes) {
    if (episode.owned) {
      owned += 1;
      continue;
    }
    const airDate: string = episode.air_date ?? '';
    if (airDate.length === 0 || daysBetween(schedule.today, airDate) > 0) {
      upcoming += 1;
    }
  }
  return new AirCounts(owned, schedule.missing_episodes.length, upcoming);
}

/** 有日期的集按播出日分组，升序 */
export function airDays(episodes: EpisodeView[], schedule: SeasonAirScheduleView): AirDay[] {
  const byDate: Map<string, EpisodeView[]> = new Map();
  const dates: string[] = [];
  for (const episode of episodes) {
    const airDate: string = episode.air_date ?? '';
    if (airDate.length === 0) {
      continue;
    }
    const day: string = airDate.slice(0, 10);
    const list: EpisodeView[] | undefined = byDate.get(day);
    if (list !== undefined) {
      list.push(episode);
    } else {
      byDate.set(day, [episode]);
      dates.push(day);
    }
  }
  dates.sort();
  const lastAir: string = schedule.last_air_date ?? '';
  const out: AirDay[] = [];
  for (const date of dates) {
    const episodesOfDay: EpisodeView[] = byDate.get(date) ?? [];
    const offset: number = daysBetween(schedule.today, date);
    const finale: boolean = lastAir.length > 0 && date === lastAir.slice(0, 10);
    out.push(new AirDay(date, episodesOfDay, offset < 0, offset === 0, finale));
  }
  return out;
}

/** 今天或之后第一个有集播出的日子 */
export function nextAirDay(days: AirDay[]): AirDay | null {
  for (const day of days) {
    if (!day.past) {
      return day;
    }
  }
  return null;
}

/** 集号范围：连续的给首尾，单集给一个数 */
export function rangeLabel(episodes: EpisodeView[]): string {
  if (episodes.length === 0) {
    return '';
  }
  let from: number = episodes[0].episode_number;
  let to: number = from;
  for (const episode of episodes) {
    if (episode.episode_number < from) {
      from = episode.episode_number;
    }
    if (episode.episode_number > to) {
      to = episode.episode_number;
    }
  }
  return from === to ? `第 ${from} 集` : `第 ${from}–${to} 集`;
}

/** 更新规律：「每天更新 / 每周三更新 / 周一至周四更新 / 周二、周五更新」 */
export function cadenceText(schedule: SeasonAirScheduleView): string | null {
  const days: number[] = [];
  for (const weekday of schedule.weekdays) {
    if (days.indexOf(weekday) < 0) {
      days.push(weekday);
    }
  }
  days.sort((a: number, b: number): number => a - b);
  if (days.length === 0) {
    return null;
  }
  if (days.length === 7) {
    return '每天更新';
  }
  if (days.length === 1) {
    return `每${weekdayName(days[0])}更新`;
  }
  let contiguous: boolean = true;
  for (let i = 1; i < days.length; i++) {
    if (days[i] !== days[i - 1] + 1) {
      contiguous = false;
      break;
    }
  }
  if (contiguous) {
    return `${weekdayName(days[0])}至${weekdayName(days[days.length - 1])}更新`;
  }
  const names: string[] = [];
  for (const weekday of days) {
    names.push(weekdayName(weekday));
  }
  return `${names.join('、')}更新`;
}

/** 完结日：「10月30日 完结 / 今天完结」 */
export function finaleText(schedule: SeasonAirScheduleView): string | null {
  const lastAir: string = schedule.last_air_date ?? '';
  if (lastAir.length === 0) {
    return null;
  }
  if (daysBetween(schedule.today, lastAir) === 0) {
    return '今天完结';
  }
  return `${formatAirDay(lastAir)} 完结`;
}

/**
 * 两个播出日之间的停更说明；相邻两天没有间隙返回 null。
 * 周更剧每周都隔六天，头部已写「每周四更新」，调用处把非停更的间隔吞掉（见 `AirScheduleSheet`）。
 */
export function gapBetween(previous: string, next: string): AirGap | null {
  const skipped: number = daysBetween(previous, next) - 1;
  if (skipped <= 0) {
    return null;
  }
  if (skipped >= 7) {
    return new AirGap(true, `停更 ${skipped} 天`);
  }
  const first: string = formatWeekday(shiftDay(previous, 1));
  if (skipped === 1) {
    return new AirGap(false, `${first}不更新`);
  }
  return new AirGap(false, `${first}至${formatWeekday(shiftDay(next, -1))}不更新`);
}

/** 一组同日播出的集在订阅里走到哪了（入口卡与日程「今天」行的右侧状态） */
export function arrivalState(episodes: EpisodeView[], schedule: SeasonAirScheduleView): ArrivalState | null {
  const pending: EpisodeView[] = [];
  for (const episode of episodes) {
    if (!episode.owned) {
      pending.push(episode);
    }
  }
  if (pending.length === 0) {
    return new ArrivalState(ArrivalKind.InLibrary);
  }
  if ((schedule.subscription_id ?? null) === null) {
    return new ArrivalState(ArrivalKind.NotSubscribed);
  }
  let waiting: boolean = false;
  const expected: string[] = [];
  for (const arrival of schedule.arrivals) {
    let matches: boolean = false;
    for (const episode of pending) {
      if (episode.episode_number === arrival.episode_number) {
        matches = true;
        break;
      }
    }
    if (!matches) {
      continue;
    }
    if (arrival.stage === 'organizing') {
      return new ArrivalState(ArrivalKind.Organizing);
    }
    if (arrival.stage === 'downloading') {
      return new ArrivalState(ArrivalKind.Downloading);
    }
    waiting = true;
    const at: string = arrival.expected_at ?? '';
    if (at.length > 0) {
      expected.push(at);
    }
  }
  expected.sort();
  if (expected.length > 0) {
    return new ArrivalState(ArrivalKind.Expected, expected[0]);
  }
  return waiting ? new ArrivalState(ArrivalKind.Waiting) : null;
}

/** 入库预告的文案（颜色由 UI 按 kind 配） */
export function arrivalText(state: ArrivalState): string {
  switch (state.kind) {
    case ArrivalKind.InLibrary:
      return '已入库，可以看了';
    case ArrivalKind.NotSubscribed:
      return '未订阅';
    case ArrivalKind.Downloading:
      return '下载中';
    case ArrivalKind.Organizing:
      return '整理中';
    case ArrivalKind.Expected:
      return `预计 ${expectedClock(state.expectedAt ?? '')} 入库`;
    case ArrivalKind.Waiting:
    default:
      return '等待资源';
  }
}

/**
 * 今天播出的那一集右侧的入库状态（分集行用，同 Web 的 UnairedStill 口径）：
 * 没订等候资源；有预告按下载中/整理中/预计时刻给。
 */
export function todayArrival(episode: EpisodeView, schedule: SeasonAirScheduleView): ArrivalState {
  if ((schedule.subscription_id ?? null) === null) {
    return new ArrivalState(ArrivalKind.NotSubscribed);
  }
  let arrival: EpisodeArrivalView | null = null;
  for (const item of schedule.arrivals) {
    if (item.episode_number === episode.episode_number) {
      arrival = item;
      break;
    }
  }
  if (arrival === null) {
    return new ArrivalState(ArrivalKind.Waiting);
  }
  if (arrival.stage === 'downloading') {
    return new ArrivalState(ArrivalKind.Downloading);
  }
  if (arrival.stage === 'organizing') {
    return new ArrivalState(ArrivalKind.Organizing);
  }
  const at: string = arrival.expected_at ?? '';
  if (at.length > 0) {
    return new ArrivalState(ArrivalKind.Expected, at);
  }
  return new ArrivalState(ArrivalKind.Waiting);
}

/** 未来播出的那集的状态行：「10月30日 周五 播出 · 3 天后」；没定日期「待定档」 */
export function futureAirText(episode: EpisodeView, schedule: SeasonAirScheduleView): string {
  const airDate: string = episode.air_date ?? '';
  if (airDate.length === 0) {
    return '待定档';
  }
  const base: string = `${formatAirDay(airDate)} ${formatWeekday(airDate)} 播出`;
  const offset: number = daysBetween(schedule.today, airDate);
  if (offset === 1) {
    return `${base} · 明天`;
  }
  if (offset > 1) {
    return `${base} · ${offset} 天后`;
  }
  return base;
}
