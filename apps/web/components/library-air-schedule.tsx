"use client";

/**
 * 剧集详情页的播出日历（issue #547）：分集区里的「季进度条」入口卡 + 按天的日程弹层。
 *
 * 只在本季还有今天或以后的播出日期时出现（服务端不给 air_schedule 就整块不画）。
 * 进度条一集一格：已入库 / 缺集（只算订阅范围内的）/ 今天 / 待播；日程按播出日
 * 分组，已播部分折叠成一行汇总，停更的日子画一条虚线分隔，节奏看得出来。
 */
import dayjs from "dayjs";
import { useLocale } from "next-intl";
import { useMemo, useState } from "react";

import { useToast } from "@/components/feedback";
import { CheckIcon, ChevronRightIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  type AirDay,
  type AirGap,
  type AirTone,
  type ArrivalState,
  type Cadence,
  airCounts,
  airDays,
  airSegments,
  arrivalState,
  cadenceOf,
  daysBetween,
  episodeSpan,
  formatAirDay,
  formatWeekday,
  gapBetween,
  nextAirDay,
} from "@/lib/air-schedule";
import type { LibraryEpisode, SeasonAirSchedule } from "@/lib/api/libraries";
import { searchMissingSubscriptionResources } from "@/lib/api/subscriptions";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { appTranslator } from "@/lib/i18n/translate";
import { formatClockTime } from "@/lib/time";

type Translate = ReturnType<typeof appTranslator>;

const TONE_CLASS: Record<AirTone, string> = {
  owned: "bg-[#c3cad6]",
  missing: "bg-[#f59e0b]",
  today: "bg-[#3b82f6]",
  todayFree: "bg-[#7c8494]",
  upcoming: "bg-white/[0.14]",
  absent: "bg-white/[0.14]",
};

function CalendarGlyph({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden className={className}>
      <rect x="3.5" y="5" width="17" height="15.5" rx="3" />
      <path d="M3.5 10h17M8 3v4M16 3v4" />
    </svg>
  );
}

function rangeLabel(episodes: LibraryEpisode[], t: Translate): string {
  const { from, to } = episodeSpan(episodes);
  return from === to
    ? t("library.item.episode", { episode: from })
    : t("library.item.airEpisodeRange", { from, to });
}

function dayLabel(day: string, schedule: SeasonAirSchedule, locale: AppLocale, t: Translate): string {
  const date = t("library.item.airDateWeekday", { date: formatAirDay(day, locale), weekday: formatWeekday(day, locale) });
  return schedule.region ? t("library.item.airDateRegion", { date, region: regionName(schedule.region, locale) }) : date;
}

function regionName(code: string, locale: AppLocale): string {
  try {
    return new Intl.DisplayNames(locale, { type: "region" }).of(code) ?? code;
  } catch {
    return code;
  }
}

function cadenceText(cadence: Cadence | null, t: Translate): string | null {
  if (!cadence) return null;
  switch (cadence.kind) {
    case "daily":
      return t("library.item.airCadenceDaily");
    case "weekly":
      return t("library.item.airCadenceWeekly", { day: cadence.day });
    case "range":
      return t("library.item.airCadenceRange", { from: cadence.from, to: cadence.to });
    case "list":
      return t("library.item.airCadenceList", { days: cadence.days });
  }
}

function finaleText(schedule: SeasonAirSchedule, locale: AppLocale, t: Translate): string | null {
  if (!schedule.last_air_date) return null;
  return daysBetween(schedule.today, schedule.last_air_date) === 0
    ? t("library.item.airFinaleToday")
    : t("library.item.airFinale", { date: formatAirDay(schedule.last_air_date, locale) });
}

function gapText(gap: AirGap, t: Translate): string {
  switch (gap.kind) {
    case "day":
      return t("library.item.airNoUpdateDay", { day: gap.day });
    case "range":
      return t("library.item.airNoUpdateRange", { from: gap.from, to: gap.to });
    case "break":
      return t("library.item.airBreak", { count: gap.count });
  }
}

/** 预计入库时刻：今天只给时分，跨天带上日期 */
function expectedTime(at: string, locale: AppLocale): string {
  const clock = formatClockTime(at, locale);
  if (dayjs(at).isSame(dayjs(), "day")) return clock;
  return `${formatAirDay(dayjs(at).format("YYYY-MM-DD"), locale)} ${clock}`;
}

function arrivalView(state: ArrivalState | null, locale: AppLocale, t: Translate): { text: string; className: string } | null {
  if (!state) return null;
  switch (state.kind) {
    case "inLibrary":
      return { text: t("library.item.airInLibrary"), className: "text-[var(--ok)]" };
    case "notSubscribed":
      return { text: t("library.item.airNotSubscribed"), className: "text-[var(--text-muted)]" };
    case "downloading":
      return { text: t("library.item.airDownloading"), className: "text-[var(--info)]" };
    case "organizing":
      return { text: t("library.item.airOrganizing"), className: "text-[var(--info)]" };
    case "expected":
      return { text: t("library.item.airExpected", { time: expectedTime(state.at, locale) }), className: "text-[var(--info)]" };
    case "waiting":
      return { text: t("library.item.airWaiting"), className: "text-[var(--text-muted)]" };
  }
}

function statsText(counts: ReturnType<typeof airCounts>, schedule: SeasonAirSchedule, t: Translate) {
  return {
    owned: t("library.item.airStatOwned", { count: counts.owned }),
    missing:
      counts.missing === 0
        ? null
        : counts.missing === 1
          ? t("library.item.airStatMissingOne", { episode: schedule.missing_episodes[0] })
          : t("library.item.airStatMissing", { count: counts.missing }),
    upcoming: counts.upcoming > 0 ? t("library.item.airStatUpcoming", { count: counts.upcoming }) : null,
  };
}

function SeasonBar({ episodes, schedule, className }: { episodes: LibraryEpisode[]; schedule: SeasonAirSchedule; className: string }) {
  const t = appTranslator(useLocale() as AppLocale);
  const segments = airSegments(episodes, schedule);
  const counts = airCounts(episodes, schedule);
  return (
    <span
      role="img"
      aria-label={t("library.item.airProgress", { owned: counts.owned, missing: counts.missing, upcoming: counts.upcoming })}
      className={`flex gap-[2px] ${className}`}
    >
      {segments.map((segment, i) => (
        <span
          key={i}
          className={`min-w-[3px] rounded-[2px] ${TONE_CLASS[segment.tone]}`}
          style={{ flexGrow: segment.count, flexBasis: 0 }}
        />
      ))}
    </span>
  );
}

/** 分集区里的入口卡：更新规律、季进度条、下次更新与入库状态、汇总 */
export function AirScheduleCard({
  episodes,
  schedule,
  onOpen,
}: {
  episodes: LibraryEpisode[];
  schedule: SeasonAirSchedule;
  onOpen: () => void;
}) {
  const locale = useLocale() as AppLocale;
  const t = appTranslator(locale);
  const days = useMemo(() => airDays(episodes, schedule), [episodes, schedule]);
  const next = nextAirDay(days);
  const counts = airCounts(episodes, schedule);
  const stats = statsText(counts, schedule, t);
  const meta = [cadenceText(cadenceOf(schedule.weekdays, locale), t), finaleText(schedule, locale, t)].filter(Boolean).join(" · ");
  let headline: string | null = null;
  let note: { text: string; className: string } | null = null;
  if (next) {
    const range = rangeLabel(next.episodes, t);
    if (next.today) {
      headline = next.finale
        ? t("library.item.airTodayFinale", { range })
        : t("library.item.airTodayEpisodes", { range });
      note = arrivalView(arrivalState(next.episodes, schedule), locale, t);
    } else {
      headline = t("library.item.airNextEpisodes", { date: dayLabel(next.date, schedule, locale, t), range });
      const offset = daysBetween(schedule.today, next.date);
      note = {
        text: offset === 1 ? t("library.item.airTomorrow") : t("library.item.airInDays", { count: offset }),
        className: "text-[var(--text-muted)]",
      };
    }
  }
  return (
    <button
      type="button"
      onClick={onOpen}
      data-testid="air-schedule-card"
      className="mb-3 flex w-full flex-col gap-2.5 rounded-2xl border border-white/[0.08] bg-[rgba(30,33,43,0.74)] px-3.5 pb-3 pt-3.5 text-left transition hover:border-white/20"
    >
      <span className="flex w-full items-center gap-2">
        <CalendarGlyph className="size-4 shrink-0 text-[var(--accent-strong)]" />
        <span className="text-sub font-semibold text-[var(--text)]">{t("library.item.airCalendar")}</span>
        <span className="min-w-0 flex-1 truncate text-right text-caption text-[var(--text-muted)]">{meta}</span>
        <ChevronRightIcon className="size-3.5 shrink-0 text-[var(--text-faint)]" />
      </span>
      <SeasonBar episodes={episodes} schedule={schedule} className="h-2 w-full" />
      {headline && (
        <span className="flex w-full flex-wrap items-baseline gap-x-2">
          <span className="tnum text-body font-semibold text-[var(--text)]">{headline}</span>
          {note && <span className={`ml-auto text-caption ${note.className}`}>{note.text}</span>}
        </span>
      )}
      <span className="tnum flex flex-wrap gap-x-2.5 text-caption text-[var(--text-muted)]">
        <span>{stats.owned}</span>
        {stats.missing && <span className="text-[var(--warn)]">{stats.missing}</span>}
        {stats.upcoming && <span>{stats.upcoming}</span>}
      </span>
    </button>
  );
}

/** 日程弹层：进度条 + 图例，已播折叠汇总，之后每个播出日一行 */
export function AirScheduleDialog({
  title,
  seasonLabel,
  episodes,
  schedule,
  canSubscribe,
  onSubscribe,
  onClose,
}: {
  title: string;
  seasonLabel: string;
  episodes: LibraryEpisode[];
  schedule: SeasonAirSchedule;
  canSubscribe: boolean;
  /** 未订阅时底部「订阅追更」；不传不显示 */
  onSubscribe?: () => void;
  onClose: () => void;
}) {
  const locale = useLocale() as AppLocale;
  const t = appTranslator(locale);
  const toast = useToast();
  const [pastOpen, setPastOpen] = useState(false);
  const [searching, setSearching] = useState(false);
  const days = useMemo(() => airDays(episodes, schedule), [episodes, schedule]);
  const counts = airCounts(episodes, schedule);
  const past = days.filter((day) => day.past);
  const coming = days.filter((day) => !day.past);
  const missing = new Set(schedule.missing_episodes);
  const canFind = canSubscribe && schedule.subscription_id != null && missing.size > 0;
  const cadence = cadenceText(cadenceOf(schedule.weekdays, locale), t);
  const finale = finaleText(schedule, locale, t);

  const findMissing = async () => {
    if (schedule.subscription_id == null || searching) return;
    setSearching(true);
    try {
      const { reset_count } = await searchMissingSubscriptionResources(schedule.subscription_id);
      toast.success(t("subscription.inspector.requeued", { count: reset_count }));
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t("subscription.inspector.searchFailed"));
    } finally {
      setSearching(false);
    }
  };

  const findLabel =
    missing.size === 1
      ? t("library.item.airFindOne", { episode: schedule.missing_episodes[0] })
      : t("library.item.airFindMany", { count: missing.size });

  // 周更剧每周都隔六天，头部已经写了「每周四更新」，再每行画一条分隔是噪音；只留真停更
  const weekly = new Set(schedule.weekdays).size === 1;
  const rows = (list: AirDay[]) =>
    list.flatMap((day, i) => {
      const found = i > 0 ? gapBetween(list[i - 1].date, day.date, locale) : null;
      const gap = weekly && found?.kind !== "break" ? null : found;
      return [
        gap && (
          <div key={`gap-${day.date}`} className="flex items-center gap-2.5 px-3 py-0.5">
            <span className="flex-1 border-t border-dashed border-white/20" />
            <span className="text-micro text-[var(--text-muted)]">{gapText(gap, t)}</span>
            <span className="flex-1 border-t border-dashed border-white/20" />
          </div>
        ),
        <DayRow key={day.date} day={day} schedule={schedule} missing={missing} canFind={canFind} searching={searching} onFind={findMissing} />,
      ];
    });

  const pastMissing = past.flatMap((day) => day.episodes).filter((e) => missing.has(e.episode_number)).length;
  const pastEpisodes = past.flatMap((day) => day.episodes);
  const pastSummary = [
    t("library.item.airStatEpisodes", { count: pastEpisodes.length }),
    t("library.item.airStatOwned", { count: pastEpisodes.filter((e) => e.owned).length }),
  ];

  return (
    <Modal open onClose={onClose} label={t("library.item.airCalendar")} width="lg" panelClassName="flex max-h-[85vh] flex-col">
      <div className="flex items-start gap-3 px-5 pb-1 pt-4">
        <div className="min-w-0 flex-1">
          <h2 className="text-body-lg font-semibold text-[var(--text)]">{t("library.item.airCalendar")}</h2>
          <p className="truncate text-caption text-[var(--text-muted)]">
            {[title, seasonLabel, cadence].filter(Boolean).join(" · ")}
          </p>
        </div>
        <button type="button" onClick={onClose} className="text-sub text-[var(--text-muted)] transition hover:text-white">
          {t("common.done")}
        </button>
      </div>
      <div className="px-5 pt-3">
        <SeasonBar episodes={episodes} schedule={schedule} className="h-2.5 w-full" />
        <div className="tnum mt-2 flex flex-wrap items-center gap-x-3.5 gap-y-1 text-micro text-[var(--text-muted)]">
          <Legend tone="owned" label={`${t("library.item.airLegendOwned")} ${counts.owned}`} />
          {counts.missing > 0 && <Legend tone="missing" label={`${t("library.item.airLegendMissing")} ${counts.missing}`} />}
          {coming[0]?.today && (
            <Legend
              tone={schedule.subscription_id != null ? "today" : "todayFree"}
              label={`${t("library.item.airLegendToday")} ${coming[0].episodes.filter((e) => !e.owned).length}`}
            />
          )}
          <Legend tone="upcoming" label={`${t("library.item.airLegendUpcoming")} ${counts.upcoming}`} />
          {finale && <span className="ml-auto">{finale}</span>}
        </div>
      </div>
      <div className="mt-3.5 border-t border-white/[0.08]" />
      <div className="flex min-h-0 flex-1 flex-col gap-1.5 overflow-y-auto scroll-thin px-3 pb-5 pt-3">
        {past.length > 0 && (
          <div className="flex items-center gap-2 rounded-xl bg-white/[0.04] py-1.5 pl-3 pr-2.5">
            <button
              type="button"
              aria-expanded={pastOpen}
              onClick={() => setPastOpen((open) => !open)}
              className="flex min-h-11 min-w-0 flex-1 items-center gap-2.5 text-left"
            >
              <ChevronRightIcon className={`size-3.5 shrink-0 text-[var(--text-muted)] transition ${pastOpen ? "rotate-90" : ""}`} />
              <span className="min-w-0">
                <span className="block text-sub font-semibold text-[var(--text)]">
                  {past.length === 1
                    ? t("library.item.airAiredDay", { date: formatAirDay(past[0].date, locale) })
                    : t("library.item.airAiredRange", { from: formatAirDay(past[0].date, locale), to: formatAirDay(past.at(-1)!.date, locale) })}
                </span>
                <span className="tnum block text-caption text-[var(--text-muted)]">
                  {pastSummary.join(" · ")}
                  {pastMissing > 0 && (
                    <>
                      {" · "}
                      <span className="text-[var(--warn)]">
                        {pastMissing === 1
                          ? t("library.item.airStatMissingOne", { episode: schedule.missing_episodes[0] })
                          : t("library.item.airStatMissing", { count: pastMissing })}
                      </span>
                    </>
                  )}
                </span>
              </span>
            </button>
            {canFind && (
              <button
                type="button"
                disabled={searching}
                onClick={findMissing}
                className="h-8 shrink-0 rounded-full border border-[#f5c451]/55 bg-[#f5c451]/10 px-3 text-caption font-semibold text-[var(--warn)] transition hover:bg-[#f5c451]/20 disabled:opacity-60"
              >
                {findLabel}
              </button>
            )}
          </div>
        )}
        {pastOpen && rows(past)}
        {rows(coming)}
        {schedule.region && (
          <p className="mx-1 mt-2 text-micro text-[var(--text-muted)]">
            {t("library.item.airRegionNote", { region: regionName(schedule.region, locale) })}
          </p>
        )}
        {schedule.subscription_id != null && (
          <p className="mx-1 mt-1 text-micro text-[var(--text-muted)]">{t("library.item.airSource")}</p>
        )}
      </div>
      {schedule.subscription_id == null && onSubscribe && (
        <div className="flex flex-col gap-2 border-t border-white/[0.08] px-5 pb-5 pt-3">
          <button
            type="button"
            onClick={onSubscribe}
            className="h-11 rounded-full bg-white text-body font-semibold text-black transition hover:bg-white/90"
          >
            {t("library.item.airSubscribe")}
          </button>
          <span className="text-center text-caption text-[var(--text-muted)]">{t("library.item.airSubscribeHint")}</span>
        </div>
      )}
    </Modal>
  );
}

function Legend({ tone, label }: { tone: AirTone; label: string }) {
  return (
    <span className="flex items-center gap-1.5">
      <span className={`size-2 rounded-[2px] ${TONE_CLASS[tone]}`} />
      {label}
    </span>
  );
}

function DayRow({
  day,
  schedule,
  missing,
  canFind,
  searching,
  onFind,
}: {
  day: AirDay;
  schedule: SeasonAirSchedule;
  missing: Set<number>;
  canFind: boolean;
  searching: boolean;
  onFind: () => void;
}) {
  const locale = useLocale() as AppLocale;
  const t = appTranslator(locale);
  const dayMissing = day.episodes.filter((e) => missing.has(e.episode_number));
  const allOwned = day.episodes.every((e) => e.owned);
  const status = day.today ? arrivalView(arrivalState(day.episodes, schedule), locale, t) : null;
  return (
    <div
      data-air-day={day.date}
      className={`flex min-h-[60px] items-center gap-2.5 rounded-xl py-2 pl-1 pr-3 ${
        day.today ? "border border-[#3b82f6]/50 bg-[#3b82f6]/[0.12]" : "bg-white/[0.04]"
      }`}
    >
      <div className="flex w-[72px] shrink-0 flex-col items-center whitespace-nowrap">
        <span className={`text-micro ${day.today ? "font-bold text-[var(--info-text)]" : "text-[var(--text-muted)]"}`}>
          {day.today ? t("library.item.airToday") : formatWeekday(day.date, locale)}
        </span>
        <span className="tnum text-body font-bold text-[var(--text)]">{formatAirDay(day.date, locale)}</span>
      </div>
      <div className="min-w-0 flex-1">
        <span className="flex items-center gap-1.5">
          <span className="tnum text-body font-semibold text-[var(--text)]">{rangeLabel(day.episodes, t)}</span>
          {day.finale && (
            <span className="rounded-full bg-white/[0.14] px-1.5 py-px text-micro font-bold text-[var(--text)]">
              {t("library.item.airFinaleTag")}
            </span>
          )}
        </span>
        {day.past && dayMissing.length > 0 && (
          <span className="block text-caption text-[var(--warn)]">
            {dayMissing.length === 1
              ? t("library.item.airStatMissingOne", { episode: dayMissing[0].episode_number })
              : t("library.item.airStatMissing", { count: dayMissing.length })}
          </span>
        )}
      </div>
      {day.past && allOwned && (
        <span className="flex shrink-0 items-center gap-1 text-caption text-[var(--ok)]">
          <CheckIcon className="size-3 stroke-[3]" />
          {t("library.item.airLegendOwned")}
        </span>
      )}
      {day.past && !allOwned && dayMissing.length === 0 && (
        <span className="shrink-0 text-caption text-[var(--text-muted)]">{t("library.item.airAbsent")}</span>
      )}
      {day.past && dayMissing.length > 0 && canFind && (
        <button
          type="button"
          disabled={searching}
          onClick={onFind}
          className="h-8 shrink-0 rounded-full border border-[#f5c451]/55 px-2.5 text-caption font-semibold text-[var(--warn)] transition hover:bg-[#f5c451]/10 disabled:opacity-60"
        >
          {t("library.item.airFindEpisode")}
        </button>
      )}
      {status && <span className={`shrink-0 text-caption font-semibold ${status.className}`}>{status.text}</span>}
    </div>
  );
}
