"use client";

/**
 * 剧集详情页的播出日历（issue #547）：分集标题下的两行摘要入口 + 按周分组的日程弹层。
 *
 * 只在本季还有今天或以后的播出日期时出现（服务端不给 air_schedule 就整块不画）。
 * 摘要左边写今天 / 下次更新哪一集和本季节奏，右边写入库时刻或还有几天；日程按播出日
 * 分行、分本周 / 下周 / 之后，已播部分折叠成一行汇总，停更的日子画一条虚线分隔，节奏看得出来。
 */
import dayjs from "dayjs";
import { useLocale } from "next-intl";
import { Fragment, type ReactNode, useMemo, useState } from "react";

import { useToast } from "@/components/feedback";
import { CheckIcon, ChevronRightIcon, XIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  type AirDay,
  type AirGap,
  type ArrivalState,
  type Cadence,
  airCounts,
  airDays,
  arrivalState,
  breaksCadence,
  cadenceOf,
  daysBetween,
  episodeSpan,
  formatAirDay,
  formatWeekday,
  gapBetween,
  nextAirDay,
  weekOffset,
} from "@/lib/air-schedule";
import type { LibraryEpisode, SeasonAirSchedule } from "@/lib/api/libraries";
import { searchMissingSubscriptionResources } from "@/lib/api/subscriptions";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { appTranslator } from "@/lib/i18n/translate";
import { formatClockTime } from "@/lib/time";

type Translate = ReturnType<typeof appTranslator>;

function rangeLabel(episodes: LibraryEpisode[], t: Translate): string {
  const { from, to } = episodeSpan(episodes);
  return from === to
    ? t("library.item.episode", { episode: from })
    : t("library.item.airEpisodeRange", { from, to });
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

function missingText(numbers: number[], t: Translate): string | null {
  if (numbers.length === 0) return null;
  return numbers.length === 1
    ? t("library.item.airStatMissingOne", { episode: numbers[0] })
    : t("library.item.airStatMissing", { count: numbers.length });
}

function relativeDay(today: string, day: string, t: Translate): string {
  const offset = daysBetween(today, day);
  return offset === 1 ? t("library.item.airTomorrow") : t("library.item.airInDays", { count: offset });
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

/** 摘要右侧：今天的看入库进度（预计时刻放大），之后的看还有几天 */
function summarySide(
  day: AirDay,
  schedule: SeasonAirSchedule,
  locale: AppLocale,
  t: Translate,
): { value: string; caption: string | null; className: string; large: boolean } | null {
  if (!day.today) {
    const date = formatAirDay(day.date, locale);
    return {
      value: relativeDay(schedule.today, day.date, t),
      caption: schedule.region ? t("library.item.airDateRegion", { date, region: regionName(schedule.region, locale) }) : date,
      className: "text-[var(--text)]",
      large: false,
    };
  }
  const state = arrivalState(day.episodes, schedule);
  if (state?.kind === "expected") {
    const sameDay = dayjs(state.at).isSame(dayjs(), "day");
    return {
      value: expectedTime(state.at, locale),
      caption: t("library.item.airExpectedShort"),
      className: "text-[var(--info-text)]",
      large: sameDay,
    };
  }
  if (state?.kind === "inLibrary") {
    return { value: t("library.item.airLegendOwned"), caption: null, className: "text-[var(--ok)]", large: false };
  }
  const view = arrivalView(state, locale, t);
  return view ? { value: view.text, caption: null, className: view.className, large: false } : null;
}

/** 分集标题下的入口：左边今天 / 下次更新哪一集 + 本季节奏，右边入库时刻或还有几天 */
export function AirScheduleSummary({
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
  // 每一项整体不折行，窄屏只在项与项之间换行，别把「11月8日」折成两行
  const meta = [
    cadenceText(cadenceOf(schedule.weekdays, locale), t),
    counts.upcoming > 0 ? t("library.item.airRemaining", { count: counts.upcoming }) : null,
    finaleText(schedule, locale, t),
  ].filter((part): part is string => Boolean(part));
  const side = next ? summarySide(next, schedule, locale, t) : null;
  return (
    <button
      type="button"
      onClick={onOpen}
      data-testid="air-schedule-summary"
      className="group -mt-1 mb-3.5 flex w-full items-center gap-3.5 text-left"
    >
      <span className="flex min-w-0 flex-1 flex-col gap-1">
        {next && (
          <span className="flex min-w-0 items-center gap-2">
            <span
              className={`shrink-0 rounded-md px-[7px] py-0.5 text-micro font-bold ${
                next.today ? "bg-[var(--text)] text-[#111318]" : "bg-white/[0.14] text-[var(--text)]"
              }`}
            >
              {next.today ? t("library.item.airToday") : formatWeekday(next.date, locale)}
            </span>
            <span className="tnum truncate text-title-sm font-semibold text-[var(--text)] transition group-hover:text-white">
              {next.finale
                ? t("library.item.airEpisodesFinale", { range: rangeLabel(next.episodes, t) })
                : t("library.item.airEpisodesUpdate", { range: rangeLabel(next.episodes, t) })}
            </span>
          </span>
        )}
        <span className="tnum text-caption text-[var(--text-muted)]">
          {meta.map((part, i) => (
            <Fragment key={part}>
              {i > 0 && " · "}
              <span className="whitespace-nowrap">{part}</span>
            </Fragment>
          ))}
        </span>
      </span>
      {side && (
        <>
          <span aria-hidden className="h-[38px] w-px shrink-0 bg-white/[0.18]" />
          <span className="flex shrink-0 flex-col items-end">
            <span className={`tnum font-semibold ${side.large ? "text-title-lg tracking-[-0.01em]" : "text-body"} ${side.className}`}>
              {side.value}
            </span>
            {side.caption && <span className="text-micro text-[var(--text-muted)]">{side.caption}</span>}
          </span>
        </>
      )}
    </button>
  );
}

/** 日程弹层：还剩几集，已播折叠汇总，之后的播出日分本周 / 下周 / 之后 */
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

  const groupTitle = (group: number) =>
    t(group === 0 ? "library.item.airThisWeek" : group === 1 ? "library.item.airNextWeek" : "library.item.airLater");

  const rows = (list: AirDay[], grouped: boolean) => {
    const out: ReactNode[] = [];
    let current: number | null = null;
    list.forEach((day, i) => {
      // 本周 / 下周 / 之后：再往后按周分，周更剧就成了一行一个标题
      const group = Math.min(weekOffset(schedule.today, day.date), 2);
      if (grouped && group !== current) {
        current = group;
        out.push(
          <div key={`group-${group}`} className="px-3.5 pb-1 pt-4 text-caption font-semibold text-[var(--text-muted)] first:pt-1">
            {groupTitle(group)}
          </div>,
        );
      }
      // 头部已经写了「周五至周六更新」，按节奏空着的日子不再每行画分隔；只标真停更
      const gap =
        i > 0 && breaksCadence(list[i - 1].date, day.date, schedule.weekdays)
          ? gapBetween(list[i - 1].date, day.date, locale)
          : null;
      if (gap) {
        out.push(
          <div key={`gap-${day.date}`} className="flex items-center gap-2.5 px-3.5 py-0.5">
            <span className="flex-1 border-t border-dashed border-white/20" />
            <span className="text-micro text-[var(--text-muted)]">{gapText(gap, t)}</span>
            <span className="flex-1 border-t border-dashed border-white/20" />
          </div>,
        );
      }
      out.push(
        <DayRow key={day.date} day={day} schedule={schedule} missing={missing} canFind={canFind} searching={searching} onFind={findMissing} />,
      );
    });
    return out;
  };

  const pastEpisodes = past.flatMap((day) => day.episodes);
  const pastMissing = pastEpisodes.filter((e) => missing.has(e.episode_number)).map((e) => e.episode_number);
  const pastOwned = pastEpisodes.filter((e) => e.owned).length;
  const pastAllOwned = pastOwned === pastEpisodes.length;

  return (
    <Modal open onClose={onClose} label={t("library.item.airCalendar")} width="lg" panelClassName="flex max-h-[85vh] flex-col">
      <div className="flex items-center gap-3 pl-5 pr-4 pt-4">
        <h2 className="min-w-0 flex-1 text-title font-semibold text-[var(--text)]">{t("library.item.airCalendar")}</h2>
        <button
          type="button"
          onClick={onClose}
          aria-label={t("common.close")}
          className="grid size-9 shrink-0 place-items-center rounded-full border border-white/[0.16] bg-white/[0.12] text-[var(--text)] transition hover:bg-white/20"
        >
          <XIcon className="size-4" />
        </button>
      </div>
      <div className="px-5 pb-4 pt-1.5">
        <p className="truncate text-caption text-[var(--text-muted)]">{[title, seasonLabel, cadence].filter(Boolean).join(" · ")}</p>
        <p className="tnum mt-0.5 flex flex-wrap items-baseline gap-x-2.5">
          {counts.upcoming > 0 ? (
            <>
              <span className="text-title-lg font-bold tracking-[-0.01em] text-[var(--text)]">
                {t("library.item.airRemaining", { count: counts.upcoming })}
              </span>
              {finale && <span className="text-sub text-[var(--text-muted)]">{finale}</span>}
            </>
          ) : (
            finale && <span className="text-title-lg font-bold tracking-[-0.01em] text-[var(--text)]">{finale}</span>
          )}
        </p>
      </div>
      <div className="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto scroll-thin px-3 pb-5">
        {past.length > 0 && (
          <div className="mb-1 flex items-center gap-2 rounded-2xl bg-white/[0.06] py-1.5 pl-3.5 pr-2.5">
            <button
              type="button"
              aria-expanded={pastOpen}
              onClick={() => setPastOpen((open) => !open)}
              data-testid="air-schedule-past"
              className="flex min-h-11 min-w-0 flex-1 items-center gap-3 text-left"
            >
              {pastMissing.length > 0 ? (
                <span className="grid size-[26px] shrink-0 place-items-center rounded-full bg-[#fbbf24]/[0.18] text-sub font-bold text-[var(--warn)]">!</span>
              ) : (
                <span className="grid size-[26px] shrink-0 place-items-center rounded-full bg-[#4ade80]/[0.18] text-[var(--ok)]">
                  <CheckIcon className="size-3 stroke-[3]" />
                </span>
              )}
              <span className="min-w-0 flex-1">
                <span className="tnum block text-ui font-semibold text-[var(--text)]">{rangeLabel(pastEpisodes, t)}</span>
                <span className="tnum block truncate text-caption text-[var(--text-muted)]">
                  {past.length === 1
                    ? t("library.item.airAiredDay", { date: formatAirDay(past[0].date, locale) })
                    : t("library.item.airAiredRange", { from: formatAirDay(past[0].date, locale), to: formatAirDay(past.at(-1)!.date, locale) })}
                </span>
              </span>
              {pastMissing.length > 0 ? (
                // 能补集时右边的「补第 7 集」已经说了缺哪集，这里不再重复
                !canFind && <span className="shrink-0 text-caption text-[var(--warn)]">{missingText(pastMissing, t)}</span>
              ) : (
                <span className={`tnum shrink-0 text-caption ${pastAllOwned ? "text-[var(--ok)]" : "text-[var(--text-muted)]"}`}>
                  {pastAllOwned ? t("library.item.airLegendOwned") : t("library.item.airStatOwned", { count: pastOwned })}
                </span>
              )}
              <ChevronRightIcon className={`size-3.5 shrink-0 text-[var(--text-muted)] transition ${pastOpen ? "rotate-90" : ""}`} />
            </button>
            {canFind && (
              <button
                type="button"
                disabled={searching}
                onClick={findMissing}
                data-testid="air-schedule-find"
                className="h-8 shrink-0 rounded-full bg-[var(--warn)] px-3 text-caption font-semibold text-[#241a02] transition hover:brightness-110 disabled:opacity-60"
              >
                {findLabel}
              </button>
            )}
          </div>
        )}
        {pastOpen && rows(past, false)}
        {rows(coming, true)}
        {schedule.region && (
          <p className="mx-3.5 mt-3 text-micro text-[var(--text-muted)]">
            {t("library.item.airRegionNote", { region: regionName(schedule.region, locale) })}
          </p>
        )}
        {schedule.subscription_id != null && (
          <p className="mx-3.5 mt-2 text-micro text-[var(--text-muted)]">{t("library.item.airSource")}</p>
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
  const dayMissing = day.episodes.filter((e) => missing.has(e.episode_number)).map((e) => e.episode_number);
  const allOwned = day.episodes.every((e) => e.owned);
  const status = day.today ? arrivalView(arrivalState(day.episodes, schedule), locale, t) : null;
  const dot = day.today
    ? "bg-[var(--info)]"
    : day.finale
      ? "border-2 border-[var(--warn)]"
      : day.past && dayMissing.length > 0
        ? "bg-[var(--warn)]"
        : day.past && allOwned
          ? "bg-[var(--ok)]"
          : "border-[1.5px] border-white/50";
  return (
    <div
      data-air-day={day.date}
      className={`flex min-h-[60px] flex-col justify-center rounded-2xl px-3.5 py-2 ${day.today ? "bg-[#60a5fa]/[0.14]" : ""}`}
    >
      {/* 星期单独占一行；日期、圆点、集号、右侧状态同一行按基线对齐，集号不会落在两行日期的中间 */}
      <span className={`text-micro ${day.today ? "font-bold text-[var(--info-text)]" : "text-[var(--text-muted)]"}`}>
        {day.today ? t("library.item.airToday") : formatWeekday(day.date, locale)}
      </span>
      <div className="flex items-baseline gap-3">
        <span className="tnum w-[72px] shrink-0 whitespace-nowrap text-ui font-semibold text-[var(--text)]">
          {formatAirDay(day.date, locale)}
        </span>
        {/* 圆点没有基线，按底边落在基线上，圆心正好在集号字身中部 */}
        <span aria-hidden className={`size-2.5 shrink-0 rounded-full ${dot}`} />
        <span className="flex min-w-0 flex-1 items-baseline gap-2">
          <span className="tnum text-body-lg font-semibold text-[var(--text)]">{rangeLabel(day.episodes, t)}</span>
          {day.finale && (
            <span className="rounded-md bg-[var(--warn)] px-1.5 py-px text-micro font-bold text-[#241a02]">
              {t("library.item.airFinaleTag")}
            </span>
          )}
        </span>
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
        {!day.past && !day.today && (
          <span className="tnum shrink-0 text-caption text-[var(--text-muted)]">{relativeDay(schedule.today, day.date, t)}</span>
        )}
      </div>
      {day.past && dayMissing.length > 0 && (
        // 与集号左缘对齐：日期 72 + 间距 12 + 圆点 10 + 间距 12
        <span className="pl-[106px] text-caption text-[var(--warn)]">{missingText(dayMissing, t)}</span>
      )}
    </div>
  );
}
