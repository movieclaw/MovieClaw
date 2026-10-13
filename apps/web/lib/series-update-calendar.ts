/**
 * 剧集详情页「更新日历」的纯展示逻辑。
 *
 * 数据全部来自既有订阅详情：wanted 工单的 air_date / release_forecast / status，
 * 再叠上媒体库在位文件（owned）。不新造排期源——与订阅首页「日程」同源，
 * 只是收成「这一部剧」的视角：按播出日列出接下来每天更新几集、哪几集、
 * 哪些已经入库。完结或窗口内没有排期时返回 null，页面不占位。
 *
 * 站点日历日口径：Asia/Shanghai（与后端 publish_calendar_date 一致）；
 * 「今天」与 daysAhead 都按该时区算，前端不复制别的时区规则。
 */
import type { WantedItem, WantedStatus } from "@/lib/api/subscriptions";

/** 更新日历覆盖的天数：与订阅首页一周日程同一窗口 */
export const SERIES_UPDATE_CALENDAR_DAYS = 7;

export type SeriesUpdateEpisodeTone = "ok" | "live" | "warn" | "calm";

/** 某一天里的一集 */
export interface SeriesUpdateEpisode {
  seasonNumber: number;
  episodeNumber: number;
  /** 「E06」；跨季同天更新时用「S02E01」 */
  label: string;
  owned: boolean;
  status: WantedStatus;
  /** 「已入库」「下载中」「预计入库」「等待资源」「待播出」 */
  statusLabel: string;
  tone: SeriesUpdateEpisodeTone;
  /** 左列时刻「22:40」；给不出可信时间时为 null */
  time: string | null;
  airDate: string;
}

/** 日期条上的一天 */
export interface SeriesUpdateDay {
  daysAhead: number;
  /** YYYY-MM-DD（站点日历） */
  date: string;
  weekday: string;
  dayNumber: string;
  dateLabel: string;
  episodes: SeriesUpdateEpisode[];
}

/** 一块更新日历；null = 整块不渲染 */
export interface SeriesUpdateCalendar {
  days: SeriesUpdateDay[];
  /** 「10月2日 · 第 6 / 17 集」一类摘要，给区块标题旁 */
  caption: string;
  /** 「已入库至第 6 集」；还没有任何入库时为 null */
  progressNote: string | null;
}

export interface OwnedUnit {
  seasonNumber: number;
  episodeNumber: number;
}

const WEEKDAY_NAMES = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

/** 站点日历「今天」：Asia/Shanghai 的 YYYY-MM-DD */
export function siteCalendarToday(now: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

/** 站点日历日 → UTC 零点时间戳（按日历日本身算，不经时区换算） */
function calendarDayMs(day: string): number | null {
  const [year, month, date] = day.split("-").map(Number);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(date)) return null;
  return Date.UTC(year, month - 1, date);
}

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

function clockOf(timestamp: number): string {
  const value = new Date(timestamp);
  // 预测快照是带偏移的 ISO（UTC）；展示用本地时分会在非东八区机器上漂。
  // 订阅首页同款：浏览器本地。详情页与首页一致即可。
  return `${pad(value.getHours())}:${pad(value.getMinutes())}`;
}

function parsedTime(value: string | null | undefined): number | null {
  if (!value) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}

/** 剧集 TMDB status → 是否还会出新集（与后端 derive_air_status 同词表） */
export function seriesStillAiring(status: string | null | undefined): boolean {
  if (!status) return true; // 未知时宁可展示，由「有无排期」再决定是否隐藏
  if (status === "Ended" || status === "Canceled") return false;
  return true;
}

function unitKey(season: number, episode: number): string {
  return `${season}:${episode}`;
}

function episodeLabel(
  seasonNumber: number,
  episodeNumber: number,
  multiSeason: boolean,
): string {
  return multiSeason
    ? `S${pad(seasonNumber)}E${pad(episodeNumber)}`
    : `E${pad(episodeNumber)}`;
}

function episodePresentation(
  wanted: WantedItem,
  owned: boolean,
  now: Date,
): Pick<SeriesUpdateEpisode, "statusLabel" | "tone" | "time"> {
  if (owned || wanted.status === "imported") {
    return { statusLabel: "已入库", tone: "ok", time: null };
  }
  if (wanted.status === "downloaded") {
    return { statusLabel: "整理中", tone: "ok", time: "即将" };
  }
  if (wanted.status === "grabbed") {
    return { statusLabel: "下载中", tone: "live", time: "稍后" };
  }
  const forecast = wanted.release_forecast;
  const predictedAt =
    forecast &&
    forecast.confidence !== "volatile" &&
    forecast.target_air_date === wanted.air_date
      ? parsedTime(forecast.predicted_at)
      : null;
  if (predictedAt != null) {
    if (predictedAt <= now.getTime()) {
      return { statusLabel: "等待资源", tone: "warn", time: null };
    }
    return { statusLabel: "预计入库", tone: "calm", time: clockOf(predictedAt) };
  }
  const airMs = wanted.air_date ? calendarDayMs(wanted.air_date) : null;
  const todayMs = calendarDayMs(siteCalendarToday(now));
  if (airMs != null && todayMs != null && airMs > todayMs) {
    return { statusLabel: "待播出", tone: "calm", time: null };
  }
  return { statusLabel: "等待资源", tone: "warn", time: null };
}

/**
 * 从订阅工单 + 在位文件拼出更新日历。
 *
 * - 只看有 air_date 的剧集工单；
 * - 窗口 = 站点今天起连续 7 天（与订阅首页日程同长）；
 * - 窗口内没有任何一集 → 返回 null（整块隐藏）；
 * - 剧集已标完结且窗口内也没有待播 → 返回 null。
 */
export function buildSeriesUpdateCalendar(
  wanted: WantedItem[],
  ownedUnits: Iterable<OwnedUnit>,
  options: {
    now?: Date;
    /** 订阅关联媒体的 TMDB status；Ended/Canceled 且无排期时隐藏 */
    mediaStatus?: string | null;
    /** 最新一季的已入库 / 官方集数，用于摘要；缺省只写下一集 */
    seasonProgress?: { owned: number; total: number; seasonNumber: number } | null;
  } = {},
): SeriesUpdateCalendar | null {
  const now = options.now ?? new Date();
  const today = siteCalendarToday(now);
  const todayMs = calendarDayMs(today);
  if (todayMs == null) return null;

  const owned = new Set(
    [...ownedUnits].map((unit) => unitKey(unit.seasonNumber, unit.episodeNumber)),
  );
  const horizonMs = todayMs + (SERIES_UPDATE_CALENDAR_DAYS - 1) * 86_400_000;

  // 完结剧不占位置（与 issue #547「剧集完结时不显示」一致）
  if (!seriesStillAiring(options.mediaStatus)) return null;

  const inWindow = wanted.filter((row) => {
    if (!row.air_date || row.season_number <= 0) return false;
    const dayMs = calendarDayMs(row.air_date);
    return dayMs != null && dayMs >= todayMs && dayMs <= horizonMs;
  });

  if (inWindow.length === 0) return null;

  const seasons = new Set(inWindow.map((row) => row.season_number));
  const multiSeason = seasons.size > 1;
  const byDay = new Map<string, WantedItem[]>();
  for (const row of inWindow) {
    const list = byDay.get(row.air_date!) ?? [];
    list.push(row);
    byDay.set(row.air_date!, list);
  }

  const days: SeriesUpdateDay[] = [];
  for (let offset = 0; offset < SERIES_UPDATE_CALENDAR_DAYS; offset += 1) {
    const date = new Date(todayMs + offset * 86_400_000);
    const key = `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`;
    const rows = (byDay.get(key) ?? []).toSorted(
      (left, right) =>
        left.season_number - right.season_number ||
        left.episode_number - right.episode_number,
    );
    const episodes = rows.map((row) => {
      const isOwned = owned.has(unitKey(row.season_number, row.episode_number));
      const presentation = episodePresentation(row, isOwned, now);
      return {
        seasonNumber: row.season_number,
        episodeNumber: row.episode_number,
        label: episodeLabel(row.season_number, row.episode_number, multiSeason),
        owned: isOwned || row.status === "imported",
        status: row.status,
        statusLabel: presentation.statusLabel,
        tone: presentation.tone,
        time: presentation.time,
        airDate: row.air_date!,
      };
    });
    days.push({
      daysAhead: offset,
      date: key,
      weekday: offset === 0 ? "今天" : WEEKDAY_NAMES[date.getUTCDay()],
      dayNumber: String(date.getUTCDate()),
      dateLabel: `${date.getUTCMonth() + 1}月${date.getUTCDate()}日`,
      episodes,
    });
  }

  if (!days.some((day) => day.episodes.length > 0)) return null;

  const next = days.find((day) => day.episodes.length > 0)!;
  const nextLabels = next.episodes.map((episode) => episode.label).join("、");
  const progress = options.seasonProgress;
  const progressBit =
    progress && progress.total > 0
      ? `第 ${progress.owned} / ${progress.total} 集`
      : null;
  const caption = [next.dateLabel, nextLabels, progressBit].filter(Boolean).join(" · ");
  const progressNote =
    progress && progress.owned > 0 ? `已入库至第 ${progress.owned} 集` : null;

  return { days, caption, progressNote };
}

/**
 * 从媒体库在位文件列出已入库季集（缺文件 / 待回收不算）。
 */
export function ownedUnitsFromFiles(
  files: Iterable<{ season_number: number; episode_number: number; state?: string }>,
): OwnedUnit[] {
  const seen = new Set<string>();
  const units: OwnedUnit[] = [];
  for (const file of files) {
    if (file.state != null && file.state !== "in_place") continue;
    if (file.season_number <= 0) continue;
    const key = unitKey(file.season_number, file.episode_number);
    if (seen.has(key)) continue;
    seen.add(key);
    units.push({
      seasonNumber: file.season_number,
      episodeNumber: file.episode_number,
    });
  }
  return units;
}

/**
 * 订阅季收录 → 最新一季的进度（在播剧摘要用最新季，与海报 meta 同口径）。
 */
export function latestSeasonProgress(
  seasons: Iterable<{
    season_number: number;
    owned_count: number;
    episode_count: number | null;
    aired_count?: number;
  }>,
): { owned: number; total: number; seasonNumber: number } | null {
  let latest: {
    season_number: number;
    owned_count: number;
    episode_count: number | null;
    aired_count?: number;
  } | null = null;
  for (const season of seasons) {
    if (season.season_number <= 0) continue;
    if (!latest || season.season_number > latest.season_number) latest = season;
  }
  if (!latest) return null;
  const total = latest.episode_count ?? latest.aired_count ?? 0;
  return {
    seasonNumber: latest.season_number,
    owned: latest.owned_count,
    total,
  };
}
