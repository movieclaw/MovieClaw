"use client";

import { Fragment, useState } from "react";

import { SubsHomeDot } from "@/components/subscriptions-home-kit";
import {
  SUBS_HOME_TONE_COLOR,
  type SubsHomeTone,
} from "@/lib/subscriptions-home";
import type {
  SeriesUpdateCalendar as CalendarModel,
  SeriesUpdateDay,
  SeriesUpdateEpisode,
  SeriesUpdateEpisodeTone,
} from "@/lib/series-update-calendar";

/**
 * 媒体库剧集详情页的「更新日历」。
 *
 * 视觉对齐订阅首页「日程」：一周日期条 + 选中那天的集数列表；文案收成
 * 「这一部剧」的视角（集号、已入库 / 预计入库），不再重复片名。完结或
 * 无排期时父级不挂载本组件（buildSeriesUpdateCalendar 已返回 null）。
 */
export function SeriesUpdateCalendar({ calendar }: { calendar: CalendarModel }) {
  const [selected, setSelected] = useState<number | null>(null);
  const pick = selected ?? calendar.days.find((day) => day.episodes.length > 0)?.daysAhead;
  const current = calendar.days.find((day) => day.daysAhead === pick) ?? calendar.days[0];
  if (!current) return null;

  const trailing =
    current.episodes.length === 0
      ? current.dateLabel
      : `${current.dateLabel} · ${current.episodes.length} 集`;

  return (
    <section aria-labelledby="series-update-calendar-title">
      <div className="mb-3 flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h2
          id="series-update-calendar-title"
          className="text-on-image text-body-lg font-semibold tracking-[-0.01em] text-[var(--text)]"
        >
          更新日历
        </h2>
        <p className="tnum min-w-0 truncate text-sub text-[var(--text-muted)]">
          {trailing}
          {calendar.progressNote ? ` · ${calendar.progressNote}` : ""}
        </p>
      </div>

      <div className="md:max-w-[720px]">
        <div
          role="tablist"
          aria-label="更新日历"
          className="grid gap-1.5"
          style={{ gridTemplateColumns: `repeat(${calendar.days.length}, minmax(0, 1fr))` }}
        >
          {calendar.days.map((day) => (
            <DayChip
              key={day.date}
              day={day}
              on={day.daysAhead === current.daysAhead}
              onSelect={() => setSelected(day.daysAhead)}
            />
          ))}
        </div>

        {current.episodes.length > 0 && (
          <div
            key={current.date}
            role="tabpanel"
            className="mt-3 animate-[immersive-hero-ambient-in_0.3s_ease-out_both] rounded-[22px] bg-white/[0.045] py-1 ring-1 ring-inset ring-white/[0.07]"
          >
            {current.episodes.map((episode, offset) => (
              <Fragment key={`${episode.seasonNumber}-${episode.episodeNumber}`}>
                {offset > 0 && <div className="ml-[86px] h-px bg-white/[0.06]" />}
                <EpisodeRow episode={episode} />
              </Fragment>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}

function DayChip({
  day,
  on,
  onSelect,
}: {
  day: SeriesUpdateDay;
  on: boolean;
  onSelect: () => void;
}) {
  const empty = day.episodes.length === 0;
  const glowing = day.episodes.find(
    (episode) => episode.tone === "live" || episode.tone === "ok",
  );
  const ownedAll =
    day.episodes.length > 0 && day.episodes.every((episode) => episode.owned);
  const dotColor = on
    ? "rgba(0,0,0,0.4)"
    : glowing
      ? SUBS_HOME_TONE_COLOR[toSubsTone(glowing.tone)]
      : ownedAll
        ? SUBS_HOME_TONE_COLOR.ok
        : "rgba(255,255,255,0.45)";
  return (
    <button
      type="button"
      role="tab"
      aria-selected={on}
      disabled={empty}
      onClick={onSelect}
      aria-label={`${day.weekday}，${day.dateLabel}，${
        empty
          ? "没有更新"
          : `${day.episodes.length} 集：${day.episodes.map((episode) => episode.label).join("、")}`
      }`}
      className={`flex flex-col items-center gap-[3px] rounded-[15px] py-[9px] transition duration-300 active:scale-[0.92] disabled:opacity-[0.36] ${
        on ? "bg-white" : "bg-white/[0.05] ring-1 ring-inset ring-white/[0.07]"
      }`}
    >
      <span
        className={`text-[11px] font-semibold ${on ? "text-black/55" : "text-[var(--text-muted)]"}`}
      >
        {day.weekday}
      </span>
      <span
        className={`tnum text-[19px] leading-tight ${on ? "font-bold text-black" : "font-medium text-[var(--text)]"}`}
      >
        {day.dayNumber}
      </span>
      <span className="flex h-1 items-center gap-[3px]" aria-hidden="true">
        {day.episodes.slice(0, 3).map((episode) => (
          <span
            key={`${episode.seasonNumber}-${episode.episodeNumber}`}
            className="size-1 rounded-full"
            style={{ background: on ? "rgba(0,0,0,0.4)" : dotColor }}
          />
        ))}
      </span>
    </button>
  );
}

function EpisodeRow({ episode }: { episode: SeriesUpdateEpisode }) {
  const tone = toSubsTone(episode.tone);
  return (
    <div
      className="flex items-center gap-3 rounded-[18px] px-3 py-2.5"
      aria-label={`${episode.label}，${episode.statusLabel}${episode.time ? `，${episode.time}` : ""}`}
    >
      <div className="w-[62px] shrink-0">
        <p
          className={`tnum text-[20px] leading-tight ${
            episode.time ? "font-semibold text-[var(--text)]" : "text-[var(--text-faint)]"
          }`}
        >
          {episode.time ?? (episode.owned ? "在库" : "—")}
        </p>
        <p
          className="tnum mt-[3px] flex items-center gap-1 whitespace-nowrap text-[11px] font-semibold"
          style={{ color: SUBS_HOME_TONE_COLOR[tone] }}
        >
          <SubsHomeDot tone={tone} pulse={tone === "live"} size={5} />
          <span className="truncate">{episode.statusLabel}</span>
        </p>
      </div>
      <div className="min-w-0 flex-1">
        <p className="tnum truncate text-[15px] font-semibold text-[var(--text)]">
          {episode.label}
        </p>
        <p className="tnum mt-[3px] truncate text-[13px] text-[var(--text-muted)]">
          第 {episode.seasonNumber} 季 · 第 {episode.episodeNumber} 集
        </p>
      </div>
    </div>
  );
}

function toSubsTone(tone: SeriesUpdateEpisodeTone): SubsHomeTone {
  return tone;
}
