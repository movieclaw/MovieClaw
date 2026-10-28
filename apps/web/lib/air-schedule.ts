/**
 * 剧集详情页播出日历（issue #547）的纯计算：季进度条分段、下次更新、更新规律、
 * 按天的日程。日期一律是 YYYY-MM-DD 的日历日，按字段比较与换算（UTC 零点），
 * 不经浏览器时区——「今天」由服务端按站点日历给出。
 */
import type { EpisodeArrival, LibraryEpisode, SeasonAirSchedule } from "@/lib/api/libraries";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { formatDate } from "./i18n/format.ts";

/** 进度条/分集卡的一集状态 */
export type AirTone =
  | "owned" // 已入库
  | "missing" // 订阅范围内已播出、还没入库
  | "today" // 今天播出，订阅在追
  | "todayFree" // 今天播出，没订阅
  | "upcoming" // 还没播（含没定日期的）
  | "absent"; // 已播出、库里没有，但不算缺（没订阅 / 订阅起始集之前）

export interface AirSegment {
  tone: AirTone;
  /** 合并的集数；不合并时恒为 1 */
  count: number;
}

export interface AirDay {
  date: string;
  episodes: LibraryEpisode[];
  past: boolean;
  today: boolean;
  finale: boolean;
}

/** 超过这么多集就把同状态的连续集合并成色段，一集一格太细 */
const MERGE_ABOVE = 40;

const DAY_MS = 86_400_000;

export function dayTime(day: string): number {
  const [y, m, d] = day.slice(0, 10).split("-").map(Number);
  return Date.UTC(y, m - 1, d);
}

export function daysBetween(from: string, to: string): number {
  return Math.round((dayTime(to) - dayTime(from)) / DAY_MS);
}

function shiftDay(day: string, offset: number): Date {
  return new Date(dayTime(day) + offset * DAY_MS);
}

export function formatAirDay(day: string, locale: AppLocale): string {
  return formatDate(new Date(dayTime(day)), { month: "short", day: "numeric", timeZone: "UTC" }, locale);
}

export function formatWeekday(value: Date | string, locale: AppLocale, long = false): string {
  const date = typeof value === "string" ? new Date(dayTime(value)) : value;
  return formatDate(date, { weekday: long ? "long" : "short", timeZone: "UTC" }, locale);
}

/** 0=周一…6=周日 → 星期名（2026-01-05 是周一） */
function weekdayName(index: number, locale: AppLocale, long: boolean): string {
  return formatWeekday(new Date(Date.UTC(2026, 0, 5 + index)), locale, long);
}

export function episodeTone(episode: LibraryEpisode, schedule: SeasonAirSchedule): AirTone {
  if (episode.owned) return "owned";
  if (schedule.missing_episodes.includes(episode.episode_number)) return "missing";
  if (!episode.air_date) return "upcoming";
  const offset = daysBetween(schedule.today, episode.air_date);
  if (offset > 0) return "upcoming";
  if (offset === 0) return schedule.subscription_id != null ? "today" : "todayFree";
  return "absent";
}

export function airSegments(episodes: LibraryEpisode[], schedule: SeasonAirSchedule): AirSegment[] {
  const tones = episodes.map((e) => episodeTone(e, schedule));
  if (tones.length <= MERGE_ABOVE) return tones.map((tone) => ({ tone, count: 1 }));
  const runs: AirSegment[] = [];
  for (const tone of tones) {
    const last = runs.at(-1);
    if (last?.tone === tone) last.count += 1;
    else runs.push({ tone, count: 1 });
  }
  return runs;
}

export function airCounts(episodes: LibraryEpisode[], schedule: SeasonAirSchedule) {
  const tones = episodes.map((e) => episodeTone(e, schedule));
  return {
    owned: tones.filter((tone) => tone === "owned").length,
    missing: schedule.missing_episodes.length,
    upcoming: episodes.filter((e) => !e.owned && (!e.air_date || daysBetween(schedule.today, e.air_date) > 0)).length,
  };
}

/** 有日期的集按播出日分组，升序 */
export function airDays(episodes: LibraryEpisode[], schedule: SeasonAirSchedule): AirDay[] {
  const byDate = new Map<string, LibraryEpisode[]>();
  for (const episode of episodes) {
    if (!episode.air_date) continue;
    const day = episode.air_date.slice(0, 10);
    byDate.set(day, [...(byDate.get(day) ?? []), episode]);
  }
  return [...byDate.keys()].sort().map((date) => {
    const offset = daysBetween(schedule.today, date);
    return {
      date,
      episodes: byDate.get(date)!,
      past: offset < 0,
      today: offset === 0,
      finale: schedule.last_air_date != null && date === schedule.last_air_date.slice(0, 10),
    };
  });
}

/** 今天或之后第一个有集播出的日子 */
export function nextAirDay(days: AirDay[]): AirDay | null {
  return days.find((day) => !day.past) ?? null;
}

/** 集号范围：连续的给首尾，单集给一个数 */
export function episodeSpan(episodes: LibraryEpisode[]): { from: number; to: number } {
  const numbers = episodes.map((e) => e.episode_number).sort((a, b) => a - b);
  return { from: numbers[0], to: numbers[numbers.length - 1] };
}

export type Cadence =
  | { kind: "daily" }
  | { kind: "weekly"; day: string }
  | { kind: "range"; from: string; to: string }
  | { kind: "list"; days: string };

/** 「每天 / 每周四 / 周一至周四 / 周二、周五」 */
export function cadenceOf(weekdays: number[], locale: AppLocale): Cadence | null {
  const days = [...new Set(weekdays)].sort((a, b) => a - b);
  const long = locale !== "zh-Hans";
  if (days.length === 0) return null;
  if (days.length === 7) return { kind: "daily" };
  if (days.length === 1) return { kind: "weekly", day: weekdayName(days[0], locale, long) };
  const contiguous = days.every((day, i) => i === 0 || day === days[i - 1] + 1);
  if (contiguous) {
    return { kind: "range", from: weekdayName(days[0], locale, long), to: weekdayName(days.at(-1)!, locale, long) };
  }
  const names = days.map((day) => weekdayName(day, locale, long));
  return { kind: "list", days: new Intl.ListFormat(locale, { style: "narrow", type: "unit" }).format(names) };
}

export type AirGap =
  | { kind: "day"; day: string }
  | { kind: "range"; from: string; to: string }
  | { kind: "break"; count: number };

/** 两个播出日之间的停更说明；相邻两天没有间隙返回 null */
export function gapBetween(previous: string, next: string, locale: AppLocale): AirGap | null {
  const skipped = daysBetween(previous, next) - 1;
  if (skipped <= 0) return null;
  if (skipped >= 7) return { kind: "break", count: skipped };
  const first = formatWeekday(shiftDay(previous, 1), locale);
  if (skipped === 1) return { kind: "day", day: first };
  return { kind: "range", from: first, to: formatWeekday(shiftDay(next, -1), locale) };
}

export type ArrivalState =
  | { kind: "inLibrary" }
  | { kind: "notSubscribed" }
  | { kind: "downloading" }
  | { kind: "organizing" }
  | { kind: "expected"; at: string }
  | { kind: "waiting" };

/** 一组同日播出的集在订阅里走到哪了（入口卡与日程「今天」行的右侧状态） */
export function arrivalState(episodes: LibraryEpisode[], schedule: SeasonAirSchedule): ArrivalState | null {
  const pending = episodes.filter((e) => !e.owned);
  if (pending.length === 0) return { kind: "inLibrary" };
  if (schedule.subscription_id == null) return { kind: "notSubscribed" };
  const numbers = new Set(pending.map((e) => e.episode_number));
  const arrivals = schedule.arrivals.filter((a: EpisodeArrival) => numbers.has(a.episode_number));
  if (arrivals.some((a) => a.stage === "organizing")) return { kind: "organizing" };
  if (arrivals.some((a) => a.stage === "downloading")) return { kind: "downloading" };
  const expected = arrivals
    .map((a) => a.expected_at)
    .filter((at): at is string => Boolean(at))
    .sort();
  if (expected.length > 0) return { kind: "expected", at: expected[0] };
  return arrivals.length > 0 ? { kind: "waiting" } : null;
}
