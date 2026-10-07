/**
 * 订阅首页（流媒体式版式）的纯展示逻辑：把订阅清单、整周预告、刚刚入库与下载快照
 * 压成页面四块要说的话——Hero「下一部到手的」、「刚刚入库」、「日程」、剧集 / 电影两排海报。
 *
 * 口径一比一移植自原生 App：apps/apple/MovieClaw/Features/Subscriptions/SubscriptionsHomeModel.swift
 * （单测对照 MovieClawTests/SubscriptionsHomeModelTests.swift → test/subscriptions-home.test.mjs）。
 *
 * 版式按时间与意图拆，而不是按数据类型拆（2026-09-26 订阅页改版）：
 *   1. 什么刚到、现在就能看（Hero 的「刚刚入库」、刚刚入库行）——订阅的回报时刻；
 *   2. 下一个什么时候到（Hero 的倒计时、日程）——期待感；
 *   3. 我在追哪些（剧集 / 电影海报行）——清单本身，最不急，放在最后。
 * 视图层只负责排版；判定口径全部收在这里，两端改口径时对着 Swift 同步改。
 *
 * 本文件只做纯计算（node --test 直接跑），运行时依赖一律走相对 .ts 路径。
 */
import type { DownloadTask } from "@/lib/api/downloaders";
import type {
  RecentSubscriptionArrival,
  Subscription,
  SubscriptionMedia,
  TodaySubscriptionArrival,
} from "@/lib/api/subscriptions";

import {
  groupTodayArrivals,
  subscriptionCollectionMeta,
  subscriptionFullyCollected,
  todayArrivalPresentation,
  type TodayArrivalPresentation,
} from "./subscription-ui.ts";

// —— 语气（状态色） ——

/**
 * 订阅首页的状态语气。颜色只落在小圆点与少量文字上，底子一律是中性的玻璃与暗色：
 * 一屏里亮起来的只有「此刻真有进展」的那几处。
 * - live 下载中：蓝，呼吸
 * - ok 整理中 / 刚刚入库 / 新一集：绿
 * - today 今天更新：淡紫
 * - warn 等待资源 / 找资源中 / 缺集：琥珀
 * - upgrade 洗版中：青
 * - calm 明天 / 未上映 / 已暂停 / 追踪中：中性白
 */
export type SubsHomeTone = "live" | "ok" | "today" | "warn" | "upgrade" | "calm";

/** 语气 → CSS 颜色（信号色走全站 token；淡紫与洗版青目前没有 token，同 iOS 取值） */
export const SUBS_HOME_TONE_COLOR: Record<SubsHomeTone, string> = {
  live: "var(--info)",
  ok: "var(--ok)",
  today: "rgb(222 214 255)",
  warn: "var(--warn)",
  upgrade: "#2dd4bf",
  calm: "rgba(255, 255, 255, 0.62)",
};

/** 呼吸 / 发光只给「正在发生」的两档 */
export function toneGlows(tone: SubsHomeTone): boolean {
  return tone === "live" || tone === "ok";
}

/** 海报左上角的状态小签：一张海报最多一个，讲它此刻最要紧的一件事 */
export interface SubsHomeChip {
  text: string;
  tone: SubsHomeTone;
  pulse?: boolean;
}

// —— Hero ——

export type SubsHomeHeroStage =
  | "downloading"
  | "organizing"
  | "arrived"
  | "today"
  | "upcoming"
  | "resting";

/** 起播请求：电影不带季集 */
export interface SubsHomePlayRequest {
  mediaItemId: number;
  season?: number;
  episode?: number;
}

/**
 * Hero 的一张：一部作品「下一次能看到新东西」的那件事。
 *
 * 两种讲法：讲时间的（下载中 / 整理中 / 今天 / 即将）用「小字说明 + 大号细体时刻」，
 * 不讲时间的（刚刚入库 / 追踪中）用「主说明 + 补充」。刚刚入库的主按钮是播放。
 */
export interface SubsHomeHeroSlide {
  subscriptionId: number;
  media: SubscriptionMedia;
  stage: SubsHomeHeroStage;
  /** 这一张的状态：Hero 里只画成信息行开头的一颗小圆点（颜色取语气），文字给读屏用 */
  eyebrow: SubsHomeChip;
  /** 大号时刻上方的小字（「S03E05 · 预计可看」）；null = 这一张不讲时间 */
  clockLabel: string | null;
  /** 大号细体时刻 / 词（「22:40」「周四」「马上就好」） */
  clock: string | null;
  /** 不讲时间时的主说明（「S04E01 · 命运之爱」） */
  detail: string | null;
  /** 补充说明（「2 小时前入库 · 共 3 集新内容」） */
  footnote: string | null;
  /** 下载进度 0~1（只有下载中有） */
  progress: number | null;
  /** 有值 = 主按钮是「播放」 */
  play: SubsHomePlayRequest | null;
  /** 播放入口看了一半（1~99）：主按钮写「继续播放」 */
  resumePercent: number | null;
}

// —— 日程 ——

/** 日期条上的一天。日期与「今天」都由后端 expected_day / days_ahead 给出，客户端不复制时区规则 */
export interface SubsHomeScheduleDay {
  daysAhead: number;
  /** 「今天」「周日」 */
  weekday: string;
  /** 「27」 */
  dayNumber: string;
  /** 「9月27日」（读屏与日程说明用） */
  dateLabel: string;
  entries: SubsHomeScheduleEntry[];
}

/** 日程里的一行：一部作品当天的更新（同一部剧当天多集合成一行） */
export interface SubsHomeScheduleEntry {
  subscriptionId: number;
  title: string;
  /** 「S03E05」「S02E01–E02」「电影」 */
  episodeLabel: string;
  /** 左列时刻「22:40」；给不出可信时间时为 null（显示「待定」） */
  time: string | null;
  /** 「下载中 62%」「整理中」「预计入库」「等待资源」 */
  status: string;
  tone: SubsHomeTone;
  progress: number | null;
  /** 画面取订阅条目的剧照 / 海报（预告接口本身不带图） */
  media: SubscriptionMedia | null;
}

// —— 海报行 ——

/**
 * 一部订阅在海报行 / 海报墙里的位置。剧集与电影同一套口径（2026-09-26 用户拍板）：
 * 进行中、没完成的排在前面（连没上映的也算进行中），已暂停、已完成的排在分隔线后面。
 */
export type SubsHomePhase = "active" | "paused" | "done";

export interface SubsHomeStanding {
  phase: SubsHomePhase;
  /** 进行中内部的排位，越小越靠前；暂停 / 完成时不参与 */
  rank: number;
  chip: SubsHomeChip | null;
}

/** 剧集 / 电影海报行（以及海报墙）的一张 */
export interface SubsHomeShelfItem {
  sub: Subscription;
  phase: SubsHomePhase;
  chip: SubsHomeChip | null;
  /** 海报下第二行：「第 3 季 · 4 / 8」「已收齐 · 全 5 季」「2026」 */
  meta: string;
  /** 已暂停 / 已完成：压暗，排在分隔线后面 */
  resting: boolean;
}

/** 一排海报：进行中在前；已暂停、已完成压暗排在分隔线后（海报墙分成三段展示同一份结果） */
export interface SubsHomeShelf {
  active: SubsHomeShelfItem[];
  paused: SubsHomeShelfItem[];
  done: SubsHomeShelfItem[];
  /** 分隔线上的竖排小字：已收齐 / 已入库 / 已暂停 / 暂停·收齐 */
  restingLabel: string;
}

export function shelfResting(shelf: SubsHomeShelf): SubsHomeShelfItem[] {
  return [...shelf.paused, ...shelf.done];
}

export function shelfAll(shelf: SubsHomeShelf): SubsHomeShelfItem[] {
  return [...shelf.active, ...shelf.paused, ...shelf.done];
}

/** 订阅首页一次算好的全部结果：Hero、日程、两排海报（海报墙直接复用同一份） */
export interface SubsHomeState {
  groups: SubsHomeArrivalGroup[];
  slides: SubsHomeHeroSlide[];
  days: SubsHomeScheduleDay[];
  tv: SubsHomeShelf;
  movie: SubsHomeShelf;
}

// —— 组装 ——

/** Hero 最多几张：再多用户也记不住，轮一圈要四十秒 */
export const MAX_HERO_SLIDES = 5;
/** 「刚刚入库」进 Hero 抢前排的时限：更早的仍在刚刚入库行里，Hero 只排在今天的预告之后 */
export const FRESH_ARRIVAL_WINDOW_MS = 48 * 3600 * 1000;
/** 横滑最多几张（约七屏）；其余在海报墙里 */
export const SHELF_ROW_LIMIT = 20;

/** 一部作品某一天的预告（同一部剧同一天多集合成一组） */
export interface SubsHomeArrivalGroup {
  subscriptionId: number;
  title: string;
  kind: "movie" | "tv";
  daysAhead: number;
  expectedDay: string;
  /** 「S01E07–E08」「电影」 */
  episodeLabel: string;
  /** 整组以完成最慢的一集为准（与 Web 今日时间轨道同一聚合口径） */
  presentation: TodayArrivalPresentation;
  /** 组内下载中单元的平均进度 0~1 */
  progress: number | null;
  /** 整理中：下载完成时刻 + 本订阅历史「下载完成 → 入库」中位耗时（组内取最晚，毫秒时间戳） */
  readyAt: number | null;
}

/** 预告阶段的先后：整理中 > 下载中 > 其余（与 subscription-ui 的 arrivalStageOrder 同值） */
function stageOrder(presentation: TodayArrivalPresentation): number {
  if (presentation.statusLabel === "整理中") return 2;
  if (presentation.statusLabel === "下载中") return 1;
  return 0;
}

function parsedTime(value: string | null | undefined): number | null {
  if (!value) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}

/**
 * 预告行 → 按（订阅, 日期）分组，并套上下载器的实时进度 / ETA。
 * 季集范围与「整组以最慢一集为准」直接复用 groupTodayArrivals（与 Netflix 预告行同一份口径）。
 */
export function arrivalGroups(
  arrivals: TodaySubscriptionArrival[],
  tasks: DownloadTask[],
  now: Date,
): SubsHomeArrivalGroup[] {
  const taskByHash = new Map<string, DownloadTask>();
  for (const task of tasks) {
    const key = task.info_hash.toLowerCase();
    if (!taskByHash.has(key)) taskByHash.set(key, task);
  }
  const rows = new Map<
    string,
    Array<{ arrival: TodaySubscriptionArrival; presentation: TodayArrivalPresentation; task?: DownloadTask }>
  >();
  for (const arrival of arrivals) {
    const task = arrival.info_hash ? taskByHash.get(arrival.info_hash.toLowerCase()) : undefined;
    const key = `${arrival.subscription_id}:${arrival.days_ahead}`;
    const list = rows.get(key) ?? [];
    list.push({ arrival, presentation: todayArrivalPresentation(arrival, task, now), task });
    rows.set(key, list);
  }
  return [...rows.values()].map((group) => {
    const [summary] = groupTodayArrivals(group);
    const first = group[0].arrival;
    const downloading = group
      .filter((row) => row.arrival.status === "grabbed" && row.task?.progress != null)
      .map((row) => Math.min(Math.max(row.task?.progress ?? 0, 0), 1));
    const ready = group
      .filter((row) => row.arrival.status === "downloaded")
      .map((row) => {
        const done = parsedTime(row.arrival.downloaded_at);
        return done == null ? null : done + row.arrival.estimated_download_to_import_minutes * 60_000;
      })
      .filter((value): value is number => value != null);
    return {
      subscriptionId: first.subscription_id,
      title: first.media_title,
      kind: first.media_kind,
      daysAhead: first.days_ahead,
      expectedDay: first.expected_day,
      episodeLabel: summary.episodeLabel,
      presentation: summary.presentation,
      progress: downloading.length
        ? downloading.reduce((sum, value) => sum + value, 0) / downloading.length
        : null,
      readyAt: ready.length ? Math.max(...ready) : null,
    };
  });
}

// —— Hero ——

function importedAtOf(card: RecentSubscriptionArrival): number | null {
  return parsedTime(card.imported_at);
}

/**
 * Hero 的几张：先讲正在发生的，再讲刚到的，再讲今天和最近一次的预告；一部作品只占一张。
 * 什么都没发生时退回「正在追踪」的几部，页面不至于只剩一排排海报。
 */
export function heroSlides(
  subscriptions: Subscription[],
  groups: SubsHomeArrivalGroup[],
  recent: RecentSubscriptionArrival[],
  now: Date,
): SubsHomeHeroSlide[] {
  const subsById = new Map(subscriptions.map((sub) => [sub.id, sub]));
  const nowMs = now.getTime();
  const future = Number.MAX_SAFE_INTEGER;

  const pipeline = groups
    .filter((group) => stageOrder(group.presentation) > 0)
    .toSorted((left, right) => {
      // 整理中比下载中更快落地；同阶段按预计时间
      const stage = stageOrder(right.presentation) - stageOrder(left.presentation);
      if (stage !== 0) return stage;
      return (left.presentation.estimatedAt ?? future) - (right.presentation.estimatedAt ?? future);
    });
  const arrived = recent.toSorted(
    (left, right) => (importedAtOf(right) ?? 0) - (importedAtOf(left) ?? 0),
  );
  const fresh = arrived.filter((card) => nowMs - (importedAtOf(card) ?? 0) <= FRESH_ARRIVAL_WINDOW_MS);
  const older = arrived.filter((card) => nowMs - (importedAtOf(card) ?? 0) > FRESH_ARRIVAL_WINDOW_MS);
  const today = groups
    .filter((group) => group.daysAhead === 0 && stageOrder(group.presentation) === 0)
    .toSorted(
      (left, right) =>
        (left.presentation.estimatedAt ?? future) - (right.presentation.estimatedAt ?? future),
    );
  const aheads = groups.filter((group) => group.daysAhead > 0).map((group) => group.daysAhead);
  const nearest = aheads.length ? Math.min(...aheads) : null;
  const upcoming = groups.filter(
    (group) => group.daysAhead === nearest && stageOrder(group.presentation) === 0,
  );

  const slides: SubsHomeHeroSlide[] = [];
  const seen = new Set<number>();
  const append = (slide: SubsHomeHeroSlide | null) => {
    if (!slide || slides.length >= MAX_HERO_SLIDES || seen.has(slide.subscriptionId)) return;
    seen.add(slide.subscriptionId);
    slides.push(slide);
  };
  for (const group of pipeline) append(groupSlide(group, subsById.get(group.subscriptionId)?.media, now));
  for (const card of fresh) append(arrivedSlide(card, now));
  for (const group of today) append(groupSlide(group, subsById.get(group.subscriptionId)?.media, now));
  for (const card of older) append(arrivedSlide(card, now));
  for (const group of upcoming) append(groupSlide(group, subsById.get(group.subscriptionId)?.media, now));

  if (slides.length === 0) {
    // 退路：在追的优先，其次最近动过的；讲它处在什么状态，不编时间
    const ranked = subscriptions.toSorted((left, right) => {
      const l = left.status === "active" ? 0 : 1;
      const r = right.status === "active" ? 0 : 1;
      if (l !== r) return l - r;
      return (parsedTime(right.updated_at) ?? 0) - (parsedTime(left.updated_at) ?? 0);
    });
    for (const sub of ranked.slice(0, 3)) append(restingSlide(sub));
  }
  return slides;
}

function emptySlide(
  subscriptionId: number,
  media: SubscriptionMedia,
  stage: SubsHomeHeroStage,
  eyebrow: SubsHomeChip,
): SubsHomeHeroSlide {
  return {
    subscriptionId,
    media,
    stage,
    eyebrow,
    clockLabel: null,
    clock: null,
    detail: null,
    footnote: null,
    progress: null,
    play: null,
    resumePercent: null,
  };
}

function groupSlide(
  group: SubsHomeArrivalGroup,
  media: SubscriptionMedia | undefined,
  now: Date,
): SubsHomeHeroSlide | null {
  if (!media) return null;
  const pres = group.presentation;
  const label = group.episodeLabel;
  const isMovie = group.kind === "movie";
  const slide = emptySlide(group.subscriptionId, media, "today", { text: "今天更新", tone: "today" });
  if (pres.statusLabel === "下载中") {
    slide.stage = "downloading";
    const percent = group.progress != null ? ` · ${Math.round(group.progress * 100)}%` : "";
    slide.eyebrow = { text: `下载中${percent}`, tone: "live", pulse: true };
    slide.progress = group.progress;
    if (pres.estimatedAt != null) {
      slide.clockLabel = isMovie ? "预计可看" : `${label} · 预计可看`;
      slide.clock = clockText(pres.estimatedAt, now);
    } else {
      // 给不出预计时间时，信息行得自己把「在下载」说出来（状态只剩一颗蓝点，不写就看不出在干什么）
      slide.detail = isMovie ? "正在下载" : `${label} · 正在下载`;
      slide.footnote = "下载完成后自动整理入库";
    }
  } else if (pres.statusLabel === "整理中") {
    slide.stage = "organizing";
    slide.eyebrow = { text: "整理中", tone: "ok", pulse: true };
    // 已下载完、正在整理入库：有历史耗时就给出预计能看的时刻，超时了只说「马上就好」
    if (group.readyAt != null && group.readyAt > now.getTime()) {
      slide.clockLabel = isMovie ? "下载完成 · 预计可看" : `${label} · 预计可看`;
      slide.clock = clockText(group.readyAt, now);
    } else {
      slide.clockLabel = isMovie ? "下载完成" : `${label} · 下载完成`;
      slide.clock = "马上就好";
    }
  } else if (group.daysAhead > 0) {
    slide.stage = "upcoming";
    slide.eyebrow = { text: "即将更新", tone: "calm" };
    slide.clockLabel = [label, formatCalendarDay(group.expectedDay)].filter(Boolean).join(" · ");
    slide.clock =
      group.daysAhead === 1 ? "明天" : (weekdayOf(group.expectedDay) ?? `${group.daysAhead} 天后`);
  } else {
    slide.stage = "today";
    if (pres.statusLabel === "等待资源") slide.eyebrow = { text: "等待资源", tone: "warn" };
    if (pres.estimatedAt != null) {
      slide.clockLabel = `${label} · 预计入库`;
      slide.clock = clockText(pres.estimatedAt, now);
    } else {
      slide.detail = label;
      slide.footnote = pres.timeLabel;
    }
  }
  return slide;
}

function arrivedSlide(card: RecentSubscriptionArrival, now: Date): SubsHomeHeroSlide {
  const isTV = card.media.kind === "tv";
  const imported = importedAtOf(card);
  const fresh = imported != null && now.getTime() - imported <= 24 * 3600 * 1000;
  let footnote = imported != null ? `${fromNow(imported, now)}入库` : "已入库";
  if (card.units.length > 1) footnote += ` · 共 ${card.units.length} 集新内容`;
  const slide = emptySlide(card.subscription_id, card.media, "arrived", {
    text: fresh ? "刚刚入库" : isTV ? "新一集" : "新入库",
    tone: "ok",
  });
  slide.detail = recentDetail(card);
  slide.footnote = footnote;
  slide.play = playRequest(card);
  slide.resumePercent = card.progress_percent;
  return slide;
}

function restingSlide(sub: Subscription): SubsHomeHeroSlide {
  const eyebrow: SubsHomeChip =
    sub.status === "paused"
      ? { text: "已暂停", tone: "calm" }
      : sub.status === "completed"
        ? { text: sub.media.kind === "movie" ? "已入库" : "已收齐", tone: "ok" }
        : { text: "追踪中", tone: "calm" };
  const slide = emptySlide(sub.id, sub.media, "resting", eyebrow);
  const year = sub.media.year != null ? String(sub.media.year) : null;
  if (sub.media.kind === "movie") {
    slide.detail = [year, "电影"].filter(Boolean).join(" · ");
    slide.footnote =
      sub.progress.imported > 0
        ? "已在媒体库里"
        : released(sub)
          ? "找到合适的资源就会自动下载"
          : "上映后开始找资源";
  } else {
    const meta = subscriptionCollectionMeta(sub);
    slide.detail = meta ? `${meta.label} · ${meta.value}` : (year ?? "剧集");
    slide.footnote = sub.status === "active" ? "有新一集会自动下载入库" : null;
  }
  return slide;
}

function pad(value: number): string {
  return String(value).padStart(2, "0");
}

/** 刚刚入库卡的说明：剧集「S04E01 · 集名」，电影「2025 · 电影」 */
export function recentDetail(card: RecentSubscriptionArrival): string {
  if (card.media.kind !== "tv") {
    return [card.media.year != null ? String(card.media.year) : null, "电影"].filter(Boolean).join(" · ");
  }
  const code = `S${pad(card.season_number)}E${pad(card.episode_number)}`;
  return card.episode_name ? `${code} · ${card.episode_name}` : code;
}

/** 刚刚入库卡的第三行：什么时候到的、这一批还有几集、看到哪了 */
export function recentNote(card: RecentSubscriptionArrival, now: Date): string {
  const parts: string[] = [];
  const imported = importedAtOf(card);
  if (imported != null) parts.push(`${fromNow(imported, now)}入库`);
  if (card.units.length > 1) parts.push(`共 ${card.units.length} 集新内容`);
  if (card.progress_percent != null) parts.push(`看到 ${card.progress_percent}%`);
  return parts.join(" · ");
}

/** 刚刚入库 → 起播请求（入口就是这一批里第一个没看完的单元） */
export function playRequest(card: RecentSubscriptionArrival): SubsHomePlayRequest {
  if (card.media.kind !== "tv") return { mediaItemId: card.media.media_item_id };
  return {
    mediaItemId: card.media.media_item_id,
    season: card.season_number,
    episode: card.episode_number,
  };
}

// —— 时间与日期格式 ——

function localDayKey(value: Date): string {
  return `${value.getFullYear()}-${value.getMonth()}-${value.getDate()}`;
}

/** 本地 24 小时制「HH:mm」 */
export function clockOf(timestamp: number): string {
  const value = new Date(timestamp);
  return `${pad(value.getHours())}:${pad(value.getMinutes())}`;
}

/** 大号时刻：同一天只写时刻，跨天写「明天 08:10」「10/1 08:10」 */
export function clockText(timestamp: number, now: Date): string {
  const value = new Date(timestamp);
  const clock = clockOf(timestamp);
  if (localDayKey(value) === localDayKey(now)) return clock;
  const tomorrow = new Date(now);
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (localDayKey(value) === localDayKey(tomorrow)) return `明天 ${clock}`;
  return `${value.getMonth() + 1}/${value.getDate()} ${clock}`;
}

/**
 * 「2 小时前」这类相对时间，阈值同 dayjs relativeTime（与全站 formatRelativeTime、
 * iOS Formatters.fromNow 同一口径）。这里自带一份是为了让本文件保持纯函数、可在 node 下单测。
 */
export function fromNow(timestamp: number, now: Date): string {
  const delta = now.getTime() - timestamp;
  const seconds = Math.abs(delta) / 1000;
  const r = Math.round;
  let text: string;
  if (r(seconds) <= 44) text = "几秒";
  else if (r(seconds) <= 89) text = "1 分钟";
  else if (r(seconds / 60) <= 44) text = `${Math.max(1, r(seconds / 60))} 分钟`;
  else if (r(seconds / 60) <= 89) text = "1 小时";
  else if (r(seconds / 3600) <= 21) text = `${Math.max(1, r(seconds / 3600))} 小时`;
  else if (r(seconds / 3600) <= 35) text = "1 天";
  else if (r(seconds / 86400) <= 25) text = `${Math.max(1, r(seconds / 86400))} 天`;
  else if (r(seconds / 86400) <= 45) text = "1 个月";
  else {
    // 刚刚入库只回看 30 天以内，走不到月以上；按平均月长近似即可
    const months = seconds / 86400 / 30.44;
    text = r(months) <= 10 ? `${Math.max(1, r(months))} 个月` : r(months) <= 17 ? "1 年" : `${Math.max(1, r(months / 12))} 年`;
  }
  return delta >= 0 ? `${text}前` : `${text}内`;
}

const WEEKDAY_NAMES = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

/** 站点日历日 YYYY-MM-DD → UTC 零点时间戳（按日历日本身算，不经时区换算） */
function calendarDay(day: string): number | null {
  const [year, month, date] = day.split("-").map(Number);
  if (!Number.isFinite(year) || !Number.isFinite(month) || !Number.isFinite(date)) return null;
  return Date.UTC(year, month - 1, date);
}

/** 站点日历日 →「周四」 */
export function weekdayOf(day: string): string | null {
  const time = calendarDay(day);
  return time == null ? null : WEEKDAY_NAMES[new Date(time).getUTCDay()];
}

/** 站点日历日 →「10月1日」 */
function formatCalendarDay(day: string): string | null {
  const time = calendarDay(day);
  if (time == null) return null;
  const value = new Date(time);
  return `${value.getUTCMonth() + 1}月${value.getUTCDate()}日`;
}

// —— 日程 ——

/**
 * 一周的日期条：今天起连续 7 天（窗口第 8 天有安排才补上），没有安排的日子照样占位但点不了——
 * 日历的节奏本身就是信息（「周二、周三都没有」）。一条预告都没有时整块不出现。
 */
export function scheduleDays(
  groups: SubsHomeArrivalGroup[],
  subscriptions: Subscription[],
  now: Date,
): SubsHomeScheduleDay[] {
  const anchor = groups[0];
  const anchorTime = anchor ? calendarDay(anchor.expectedDay) : null;
  if (!anchor || anchorTime == null) return [];
  const dayMs = 86_400_000;
  const siteToday = anchorTime - anchor.daysAhead * dayMs;
  const subsById = new Map(subscriptions.map((sub) => [sub.id, sub]));
  const byDay = new Map<number, SubsHomeArrivalGroup[]>();
  for (const group of groups) {
    const list = byDay.get(group.daysAhead) ?? [];
    list.push(group);
    byDay.set(group.daysAhead, list);
  }
  const lastDay = byDay.has(7) ? 7 : 6;
  const days: SubsHomeScheduleDay[] = [];
  for (let offset = 0; offset <= lastDay; offset += 1) {
    const date = new Date(siteToday + offset * dayMs);
    const entries = (byDay.get(offset) ?? [])
      .map((group) => scheduleEntry(group, subsById.get(group.subscriptionId)?.media ?? null, now))
      .toSorted((left, right) => {
        const glow = Number(toneGlows(right.tone)) - Number(toneGlows(left.tone));
        if (glow !== 0) return glow;
        const l = left.time ?? "99";
        const r = right.time ?? "99";
        return l < r ? -1 : l > r ? 1 : 0;
      });
    days.push({
      daysAhead: offset,
      weekday: offset === 0 ? "今天" : WEEKDAY_NAMES[date.getUTCDay()],
      dayNumber: String(date.getUTCDate()),
      dateLabel: `${date.getUTCMonth() + 1}月${date.getUTCDate()}日`,
      entries,
    });
  }
  return days;
}

function scheduleEntry(
  group: SubsHomeArrivalGroup,
  media: SubscriptionMedia | null,
  now: Date,
): SubsHomeScheduleEntry {
  const pres = group.presentation;
  const tone: SubsHomeTone =
    pres.statusLabel === "下载中"
      ? "live"
      : pres.statusLabel === "整理中"
        ? "ok"
        : pres.statusLabel === "等待资源"
          ? "warn"
          : "calm";
  let status: string = pres.statusLabel;
  if (pres.statusLabel === "下载中" && group.progress != null) {
    status += ` ${Math.round(group.progress * 100)}%`;
  }
  let time: string | null;
  if (pres.statusLabel === "整理中") {
    // 整理超时（过了预计时刻还没入库）不再报一个过去的时刻
    time = group.readyAt != null && group.readyAt > now.getTime() ? clockOf(group.readyAt) : "即将";
  } else if (pres.statusLabel === "下载中") {
    // 下载器给不出 ETA 时，已经在路上的东西说「稍后」，比「待定」更贴切
    time = pres.estimatedAt != null ? clockOf(pres.estimatedAt) : "稍后";
  } else {
    time = pres.estimatedAt != null ? clockOf(pres.estimatedAt) : null;
  }
  return {
    subscriptionId: group.subscriptionId,
    title: group.title,
    episodeLabel: group.episodeLabel,
    time,
    status,
    tone,
    progress: pres.statusLabel === "下载中" ? group.progress : null,
    media,
  };
}

// —— 整页 ——

/** 一次算好整页：Hero、日程、两排海报共用同一批分组，不各算各的 */
export function subscriptionsHomeState(
  subscriptions: Subscription[],
  week: TodaySubscriptionArrival[],
  recent: RecentSubscriptionArrival[],
  tasks: DownloadTask[],
  now: Date,
): SubsHomeState {
  const groups = arrivalGroups(week, tasks, now);
  return {
    groups,
    slides: heroSlides(subscriptions, groups, recent, now),
    days: scheduleDays(groups, subscriptions, now),
    tv: shelf("tv", subscriptions, groups, recent),
    movie: shelf("movie", subscriptions, groups, recent),
  };
}

// —— 海报行 ——

/**
 * 剧集 / 电影一排（海报墙同一份结果）：进行中按「此刻最要紧」排前面；
 * 已暂停（还能恢复）、已完成（最近完成的在前）压暗排在分隔线后面。
 */
export function shelf(
  kind: "movie" | "tv",
  subscriptions: Subscription[],
  groups: SubsHomeArrivalGroup[],
  recent: RecentSubscriptionArrival[],
): SubsHomeShelf {
  // 每部作品只看它最近的那一天
  const nearestGroup = new Map<number, SubsHomeArrivalGroup>();
  for (const group of groups) {
    const current = nearestGroup.get(group.subscriptionId);
    if (!current || group.daysAhead < current.daysAhead) nearestGroup.set(group.subscriptionId, group);
  }
  const recentBySub = new Map<number, RecentSubscriptionArrival>();
  for (const card of recent) {
    if (!recentBySub.has(card.subscription_id)) recentBySub.set(card.subscription_id, card);
  }

  const active: Array<{ rank: number; item: SubsHomeShelfItem }> = [];
  const paused: SubsHomeShelfItem[] = [];
  const done: SubsHomeShelfItem[] = [];
  for (const sub of subscriptions) {
    if (sub.media.kind !== kind) continue;
    const standing = subscriptionStanding(sub, nearestGroup.get(sub.id) ?? null, recentBySub.get(sub.id) ?? null);
    const item: SubsHomeShelfItem = {
      sub,
      phase: standing.phase,
      chip: standing.chip,
      meta: shelfMeta(sub, standing.phase),
      resting: standing.phase !== "active",
    };
    if (standing.phase === "active") active.push({ rank: standing.rank, item });
    else if (standing.phase === "paused") paused.push(item);
    else done.push(item);
  }
  const recentFirst = (left: SubsHomeShelfItem, right: SubsHomeShelfItem) => {
    const updated = (parsedTime(right.sub.updated_at) ?? 0) - (parsedTime(left.sub.updated_at) ?? 0);
    if (updated !== 0) return updated;
    const l = left.sub.media.title;
    const r = right.sub.media.title;
    return l < r ? -1 : l > r ? 1 : 0;
  };
  const doneLabel = kind === "movie" ? "已入库" : "已收齐";
  const restingLabel =
    paused.length > 0 && done.length > 0
      ? `暂停·${doneLabel.slice(1)}`
      : paused.length === 0
        ? doneLabel
        : "已暂停";
  return {
    active: active
      .toSorted((left, right) => left.rank - right.rank || recentFirst(left.item, right.item))
      .map((entry) => entry.item),
    paused: paused.toSorted(recentFirst),
    done: done.toSorted(recentFirst),
    restingLabel,
  };
}

/** 一排的计数：「5 部进行中 · 共 12 部」（全部进行中或一部都没有时只说总数）。首页与海报墙同一口径 */
export function shelfCountSummary(shelf: SubsHomeShelf): string {
  const total = shelf.active.length + shelf.paused.length + shelf.done.length;
  const active = shelf.active.length;
  if (active === 0 || active >= total) return `共 ${total} 部`;
  return `${active} 部进行中 · 共 ${total} 部`;
}

/** 海报墙页头：「共 12 部剧集 · 5 部进行中」 */
export function wallSummary(shelf: SubsHomeShelf, kind: "movie" | "tv"): string {
  const total = shelf.active.length + shelf.paused.length + shelf.done.length;
  const active = shelf.active.length;
  const noun = kind === "movie" ? "电影" : "剧集";
  if (active === 0 || active >= total) return `共 ${total} 部${noun}`;
  return `共 ${total} 部${noun} · ${active} 部进行中`;
}

/**
 * 一部订阅的位置与小签。剧集与电影同一套口径，进行中内部按此刻最要紧排：
 *
 *   下载中 / 整理中 → 有没看的新集（剧集）→ 今天更新 → 某天更新
 *   → 缺集 / 找资源中 → 追更中（剧集）→ 未上映（电影）→ 仅洗版
 *
 * 已完成的订阅不因「刚到了、还没看」被拉回前排——那是 Hero 与「刚刚入库」的职责；
 * 唯一的例外是洗版：内容虽已齐，但正在换更好的版本，事情还在进行。
 */
export function subscriptionStanding(
  sub: Subscription,
  group: SubsHomeArrivalGroup | null,
  recent: RecentSubscriptionArrival | null,
): SubsHomeStanding {
  const isTV = sub.media.kind === "tv";
  const active = (rank: number, chip: SubsHomeChip | null): SubsHomeStanding => ({
    phase: "active",
    rank,
    chip,
  });
  if (sub.status === "paused") {
    return { phase: "paused", rank: 0, chip: { text: "已暂停", tone: "calm" } };
  }
  const missing = isTV ? missingAired(sub) : 0;
  const pending = missing > 0 || sub.progress.wanted + sub.progress.grabbed + sub.progress.downloaded > 0;
  // 旧集洗版不降低新集缺口的优先级；纯洗版即使有下载预告，也留在进行中末尾。
  if ((sub.progress.upgrading ?? 0) > 0 && !pending) {
    return active(8, { text: "洗版中", tone: "upgrade" });
  }
  // 正在下载 / 整理：有预告按预告，没有（老服务端 / 预告还没取到）按订阅进度判断
  const pipeline =
    group?.presentation.statusLabel ??
    (sub.progress.downloaded > 0 ? "整理中" : sub.progress.grabbed > 0 ? "下载中" : null);
  if (pipeline === "下载中") return active(0, { text: "下载中", tone: "live", pulse: true });
  if (pipeline === "整理中") return active(0, { text: "整理中", tone: "ok", pulse: true });

  if (!pending && (subscriptionFullyCollected(sub) || sub.status === "completed")) {
    return { phase: "done", rank: 0, chip: null };
  }
  if (isTV && recent) {
    const count = recent.units.length;
    return active(1, { text: count > 1 ? `新 ${count} 集` : "新一集", tone: "ok" });
  }
  if (group) {
    if (group.daysAhead === 0) return active(2, { text: "今天更新", tone: "today" });
    const when =
      group.daysAhead === 1 ? "明天" : (weekdayOf(group.expectedDay) ?? `${group.daysAhead} 天后`);
    return active(3 + group.daysAhead / 100, { text: `${when}更新`, tone: "calm" });
  }
  if (isTV) {
    return missing > 0 ? active(5, { text: `缺 ${missing} 集`, tone: "warn" }) : active(6, null);
  }
  return released(sub)
    ? active(5, { text: "找资源中", tone: "warn" })
    : active(7, { text: "未上映", tone: "calm" });
}

/**
 * 剧集订阅范围内「已经播出、库里还没有」的集数（缺集，正在找资源）。
 * 只看用户勾选的季；只追新集（没勾季）时看最新一季
 */
export function missingAired(sub: Subscription): number {
  const seasons = sub.season_collection.filter((season) => season.season_number > 0);
  const selected = new Set(sub.selected_seasons.filter((season) => season > 0));
  let scoped = seasons.filter((season) => selected.has(season.season_number));
  if (selected.size === 0) {
    const latest = seasons.reduce<(typeof seasons)[number] | null>(
      (best, season) => (!best || season.season_number > best.season_number ? season : best),
      null,
    );
    scoped = latest ? [latest] : [];
  }
  return scoped.reduce((sum, season) => sum + Math.max(0, season.aired_count - season.owned_count), 0);
}

/** 海报下第二行 */
export function shelfMeta(sub: Subscription, phase: SubsHomePhase): string {
  const year = sub.media.year != null ? String(sub.media.year) : null;
  if (sub.media.kind === "movie") {
    if (sub.progress.imported > 0) return [year, "已入库"].filter(Boolean).join(" · ");
    return year ?? "电影";
  }
  const meta = subscriptionCollectionMeta(sub);
  if (!meta) return year ?? "剧集";
  if (phase === "done") return `已收齐 · ${meta.label}`;
  return `${meta.label} · ${meta.value}`;
}

/** 电影是否已上映（TMDB status；缺失按已上映处理——宁可说「找资源中」也不误报「未上映」） */
export function released(sub: Subscription): boolean {
  const status = sub.media.status;
  if (!status) return true;
  return status === "Released";
}

// —— 信息行收短 ——

/**
 * 一行文字按「 · 」分段收短的候选（从长到短、去重），视图按顺序挑第一个放得下的：
 * - tail 保留开头、去掉结尾（说明 / 补充行：先舍集名，再舍后半句）
 * - head 保留结尾（时刻上方的小字：「预计可看」是大号时刻的注解，集号可以舍）
 * 最短的一条仍放不下时由视图省略号兜底。
 */
export function shortenCandidates(text: string, keep: "head" | "tail"): string[] {
  const parts = text.split(" · ");
  if (parts.length <= 1) return [text];
  const options = [text];
  for (let count = parts.length - 1; count >= 1; count -= 1) {
    options.push(
      (keep === "tail" ? parts.slice(0, count) : parts.slice(parts.length - count)).join(" · "),
    );
  }
  return [...new Set(options)];
}
