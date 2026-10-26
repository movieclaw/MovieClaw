"use client";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator, type AppMessageKey } from "@/lib/i18n/translate";
import { requestLocale, type AppLocale } from "@/lib/i18n/negotiate";
import { formatDate, formatNumber } from "@/lib/i18n/format";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

import { ActivityIcon, LockIcon, StarIcon } from "@/components/icons";
import { PosterImage } from "@/components/poster-image";
import {
  EmptyAction,
  EmptyState,
  HiddenCountRow,
  Skeleton,
  TitleText,
  formatWatched,
} from "@/components/playback-stats-section";
import {
  fetchPlaybackWatchStats,
  type MediaActivityScope,
  type PlaybackStatsDayRow,
  type PlaybackStatsTitleRow,
  type PlaybackWatchStats,
} from "@/lib/api/playback";
import { imageUrl } from "@/lib/image-proxy";

/**
 * 观看统计（docs/design/activity.md「观看统计」）。
 *
 * 骨架照仪表盘的通行做法：**指标卡 → 一张主图 → 一组同构的分解面板**，每一层都能
 * 点进下一层。指标卡只有数字与较上一周期的变化——走势交给主图画，卡片里再画一遍
 * 迷你图是没有标注的重复信息，容易误读；点哪张主图就切到哪个指标。主图
 * 把当前周期与上一周期画在同一坐标系里；分解面板同一个模板，成员行可点即钻取；
 * 最后一张星期 × 小时的热力图回答「家里什么时候有人在看」——决定扫描、整理这类
 * 重活该排在什么时候。图全部是内联 SVG：只有一种图型，不值得引图表库，且能严格
 * 按现有设计令牌配色。
 */

type MetricKey = "watched_ms" | "plays" | "completion" | "active_members";

interface MetricDef {
  key: MetricKey;
  label: string;
  /**
   * 从一段连续日期的数据里取值（看完率为 0~1 的比例）。传一天就是当天的值，
   * 传一周就是这周的值——主图在柱子摆不下时会按周折桶。
   */
  ofDays: (rows: PlaybackStatsDayRow[]) => number;
  /** 汇总值 */
  ofTotals: (t: PlaybackWatchStats["current"]) => number;
  /** 汇总值的展示 */
  format: (value: number) => string;
  /** 指标卡上的大数字：[数值, 单位]，单位单独排小字 */
  parts: (value: number) => [string, string];
  /** 坐标轴刻度的紧凑展示 */
  axis: (value: number) => string;
  /** 变化用百分点而不是百分比（看完率本身就是比例） */
  deltaInPoints?: boolean;
  /** 折桶后的值不是求和而是日均，提示里要说清 */
  bucketNote?: string;
}

const sum = (rows: PlaybackStatsDayRow[], pick: (d: PlaybackStatsDayRow) => number) =>
  rows.reduce((acc, d) => acc + pick(d), 0);

/** 小时数：一位小数，过百取整。 */
const hours = (ms: number, locale: AppLocale) => {
  const digits = ms >= 360_000_000 ? 0 : 1;
  return formatNumber(Number((ms / 3_600_000).toFixed(digits)), { minimumFractionDigits: digits, maximumFractionDigits: digits, useGrouping: false }, locale);
};

function watchMetrics(locale: AppLocale = requestLocale() ?? "zh-Hans"): readonly MetricDef[] {
  const t = appTranslator(locale);
  return [
  {
    key: "watched_ms",
    label: t("activity.watchStats.watched"),
    ofDays: (rows) => sum(rows, (d) => d.watched_ms),
    ofTotals: (t) => t.watched_ms,
    // 「45 小时 28 分钟」在指标卡上占不下一行，满一小时就按「45.5 小时」
    format: (v) => (v >= 3_600_000 ? t("activity.watchStats.hoursValue", { value: hours(v, locale), count: Number(hours(v, locale)) }) : formatWatched(v, locale)),
    parts: (v) =>
      v >= 3_600_000
        ? [hours(v, locale), t("activity.watchStats.hoursUnit")]
        : [formatNumber(Math.max(v > 0 ? 1 : 0, Math.round(v / 60_000)), { useGrouping: false }, locale), t("activity.watchStats.minutesUnit")],
    axis: (v) => `${(v / 3_600_000).toFixed(v >= 36_000_000 ? 0 : 1)}h`,
  },
  {
    key: "plays",
    label: t("activity.watchStats.plays"),
    ofDays: (rows) => sum(rows, (d) => d.plays),
    ofTotals: (t) => t.plays,
    format: (v) => t("activity.watchStats.playsValue", { count: v }),
    parts: (v) => [formatNumber(v, { useGrouping: false }, locale), t("activity.watchStats.playsUnit", { count: v })],
    axis: (v) => `${Math.round(v)}`,
  },
  {
    key: "completion",
    label: t("activity.watchStats.completion"),
    ofDays: (rows) => {
      const plays = sum(rows, (d) => d.plays);
      return plays > 0 ? sum(rows, (d) => d.completed) / plays : 0;
    },
    ofTotals: (t) => (t.plays > 0 ? t.completed / t.plays : 0),
    format: (v) => `${Math.round(v * 100)}%`,
    parts: (v) => [`${Math.round(v * 100)}`, "%"],
    axis: (v) => `${Math.round(v * 100)}%`,
    deltaInPoints: true,
  },
  {
    key: "active_members",
    label: t("activity.watchStats.members"),
    // 按天是当天的去重人数；折成一周没法从日数据里去重，退而取日均
    ofDays: (rows) => (rows.length > 0 ? sum(rows, (d) => d.members) / rows.length : 0),
    ofTotals: (t) => t.active_members,
    format: (v) => t("activity.watchStats.membersValue", { count: Math.round(v * 10) / 10 }),
    parts: (v) => [formatNumber(Math.round(v * 10) / 10, { useGrouping: false }, locale), t("activity.watchStats.membersUnit", { count: Math.round(v * 10) / 10 })],
    axis: (v) => `${Math.round(v)}`,
    bucketNote: t("activity.watchStats.dailyAverage"),
  },
] as const;
}

/**
 * 把按天的序列折成若干桶：从末尾往前每 size 天一桶，最新的桶一定是满的，
 * 首桶可能不满（提示里会标出天数）。size=1 即不折。
 */
function bucketize(rows: PlaybackStatsDayRow[], size: number): PlaybackStatsDayRow[][] {
  const out: PlaybackStatsDayRow[][] = [];
  for (let end = rows.length; end > 0; end -= size) {
    out.unshift(rows.slice(Math.max(0, end - size), end));
  }
  return out;
}

function bucketLabel(rows: PlaybackStatsDayRow[], locale: AppLocale): string {
  if (rows.length === 1) return dayLabel(rows[0].date, locale);
  return `${dayLabel(rows[0].date, locale)} – ${dayLabel(rows[rows.length - 1].date, locale)}`;
}

/** 顶部圆角的柱子：圆角只在数据端，底边贴着基线。 */
function barPath(x: number, y: number, w: number, h: number): string {
  const r = Math.min(3, w / 2, h);
  if (h <= 0) return "";
  return [
    `M${x.toFixed(1)},${(y + h).toFixed(1)}`,
    `V${(y + r).toFixed(1)}`,
    `Q${x.toFixed(1)},${y.toFixed(1)} ${(x + r).toFixed(1)},${y.toFixed(1)}`,
    `H${(x + w - r).toFixed(1)}`,
    `Q${(x + w).toFixed(1)},${y.toFixed(1)} ${(x + w).toFixed(1)},${(y + r).toFixed(1)}`,
    `V${(y + h).toFixed(1)} Z`,
  ].join(" ");
}

const SERIES_COLOR = "var(--info)";
const PREVIOUS_COLOR = "rgba(255,255,255,0.32)";
function weekday(day: number, locale: AppLocale, narrow: boolean) {
  return formatDate(new Date(2026, 9, 19 + day), { weekday: narrow && locale === "zh-Hans" ? "narrow" : "short" }, locale);
}

function dayLabel(date: string, locale: AppLocale): string {
  const [year, month, day] = date.split("-").map(Number);
  return formatDate(new Date(year, month - 1, day), { month: "short", day: "numeric" }, locale);
}

function niceMax(max: number): number {
  if (max <= 0) return 1;
  const exponent = Math.floor(Math.log10(max));
  const base = Math.pow(10, exponent);
  for (const step of [1, 2, 5, 10]) {
    if (max <= step * base) return step * base;
  }
  return 10 * base;
}

/** 容器宽度：图按真实像素画，坐标轴文字才不会被拉伸。 */
function useElementWidth<T extends HTMLElement>(): [React.RefObject<T | null>, number] {
  const ref = useRef<T | null>(null);
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    setWidth(el.clientWidth);
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  return [ref, width];
}

// ---------------------------------------------------------------------------
// 指标卡
// ---------------------------------------------------------------------------

/** 较上一周期的变化，做成一枚小标签：涨绿、跌红、持平灰；没有上期就不出。 */
function DeltaChip({
  current,
  previous,
  available,
  inPoints,
  title,
}: {
  current: number;
  previous: number;
  available: boolean;
  inPoints?: boolean;
  title: string;
}) {
  const t = useTranslations();
  const locale = useLocale();

  if (!available) return null;
  let text: string;
  let direction: 1 | 0 | -1;
  if (inPoints) {
    const points = Math.round((current - previous) * 100);
    direction = points > 0 ? 1 : points < 0 ? -1 : 0;
    text = t("activity.watchStats.points", { count: Math.abs(points) });
  } else if (previous <= 0) {
    // 两期都是 0，没什么可比的，不出标签
    if (current <= 0) return null;
    direction = 1;
    text = t("activity.watchStats.new");
  } else {
    const ratio = (current - previous) / previous;
    direction = ratio > 0 ? 1 : ratio < 0 ? -1 : 0;
    text = direction === 0 ? t("activity.watchStats.flat") : `${Math.round(Math.abs(ratio) * 100)}%`;
  }
  const tone =
    direction > 0
      ? "bg-[var(--ok)]/15 text-[var(--ok)]"
      : direction < 0
        ? "bg-[var(--danger)]/15 text-[var(--danger)]"
        : "bg-white/[0.08] text-white/55";
  const arrow = direction > 0 ? "▲" : direction < 0 ? "▼" : "";
  return (
    <span
      title={title}
      className={`tnum inline-flex ${locale === "en" ? "min-w-0 max-w-full shrink-0" : "shrink-0"} items-center gap-0.5 rounded-md px-1.5 py-0.5 text-[11px] font-semibold leading-4 ${tone}`}
    >
      {arrow && <span className="text-[9px]">{arrow}</span>}
      {locale === "en" ? <span className="min-w-0 whitespace-normal">{text}</span> : text}
    </span>
  );
}

function MetricCard({
  metric,
  stats,
  selected,
  onSelect,
}: {
  metric: MetricDef;
  stats: PlaybackWatchStats;
  selected: boolean;
  onSelect: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const current = metric.ofTotals(stats.current);
  const previous = metric.ofTotals(stats.previous);
  const [value, unit] = metric.parts(current);
  return (
    <button
      type="button"
      aria-pressed={selected}
      onClick={onSelect}
      className={`rounded-2xl border px-4 py-3.5 text-left transition max-md:px-3.5 ${
        selected
          ? "border-[var(--info)]/60 bg-[var(--info)]/[0.07]"
          : "border-white/[0.08] bg-white/[0.03] hover:border-white/[0.14] hover:bg-white/[0.05]"
      }`}
    >
      <p className="truncate text-caption font-medium text-white/55">{metric.label}</p>
      <p className="mt-2 whitespace-nowrap leading-none">
        <span className="tnum text-[26px] font-bold tracking-tight text-white">{value}</span>
        <span className="ml-1 text-sub font-medium text-white/45">{unit}</span>
      </p>
      <div className={`mt-2.5 flex min-w-0 items-center gap-2 ${locale === "en" ? "max-md:flex-col max-md:items-start max-md:gap-1" : ""}`}>
        <DeltaChip
          current={current}
          previous={previous}
          available={stats.previous_available}
          inPoints={metric.deltaInPoints}
          title={t("activity.watchStats.versusPrevious")}
        />
        <span className={`tnum truncate text-[11px] text-white/35 ${locale === "en" ? "max-md:max-w-full" : ""}`}>
          {stats.previous_available ? t("activity.watchStats.previousValue", { value: metric.format(previous) }) : t("activity.watchStats.noPrevious")}
        </span>
      </div>
    </button>
  );
}

// ---------------------------------------------------------------------------
// 主图：当前周期的柱子 + 上一周期的虚线，同一坐标系
// ---------------------------------------------------------------------------

const CHART_HEIGHT = 220;
const PAD = { top: 14, right: 12, bottom: 26, left: 46 };
/** 一根柱子（含间隙）至少占这么宽，摆不下就按周折桶 */
const MIN_SLOT = 6;

function TrendChart({ stats, metric }: { stats: PlaybackWatchStats; metric: MetricDef }) {
  const t = useTranslations();
  const locale = useLocale();

  const [ref, width] = useElementWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const innerWidth = Math.max(0, width - PAD.left - PAD.right);
  const innerHeight = CHART_HEIGHT - PAD.top - PAD.bottom;
  // 按天合计是离散量，柱子比折线诚实：零值日就是空位，有观看的日子一眼可数。
  // 90 天在手机上每根不到 4px，这时按周折桶（最新一桶一定是完整的一周）。
  const weekly = stats.by_day.length > 0 && innerWidth / stats.by_day.length < MIN_SLOT;
  const buckets = bucketize(stats.by_day, weekly ? 7 : 1);
  const prevBuckets = bucketize(stats.previous_by_day, weekly ? 7 : 1);
  const current = buckets.map(metric.ofDays);
  const previous = prevBuckets.map(metric.ofDays);
  const showPrevious = stats.previous_available && previous.length === current.length;
  const count = current.length;
  const yMax = niceMax(Math.max(...current, ...(showPrevious ? previous : [0])));
  const slot = count > 0 ? innerWidth / count : 0;
  const gap = Math.min(6, Math.max(1, slot * 0.3));
  const barWidth = Math.max(1, slot - gap);
  const cx = (i: number) => PAD.left + slot * i + slot / 2;
  const y = (v: number) => PAD.top + innerHeight - (v / yMax) * innerHeight;
  const baseline = PAD.top + innerHeight;
  const previousLine = previous
    .map((v, i) => `${i === 0 ? "M" : "L"}${cx(i).toFixed(1)},${y(v).toFixed(1)}`)
    .join(" ");
  const gridSteps = 4;
  // x 轴刻度：按宽度定个数（一个「8月12日」约 60px），落在柱子中心
  const tickTarget = Math.max(2, Math.min(6, Math.floor(innerWidth / 70)));
  const tickEvery = Math.max(1, Math.round(count / tickTarget));
  const ticks = buckets.map((_, i) => i).filter((i) => i % tickEvery === 0 || i === count - 1);
  const bucketNote = weekly && metric.bucketNote ? `${metric.bucketNote} ` : "";

  const onMove = (event: React.MouseEvent<SVGSVGElement>) => {
    if (slot <= 0) return;
    const rect = event.currentTarget.getBoundingClientRect();
    const px = event.clientX - rect.left - PAD.left;
    setHover(Math.max(0, Math.min(count - 1, Math.floor(px / slot))));
  };

  return (
    <div ref={ref} className="relative">
      <p className="mb-1 px-1 text-caption font-semibold text-white/55">
        {metric.label}
        <span className="ml-1.5 font-normal text-white/35">{weekly ? t("activity.watchStats.weekly") : t("activity.watchStats.daily")}</span>
      </p>
      {width > 0 && (
        <svg
          width={width}
          height={CHART_HEIGHT}
          role="img"
          aria-label={t("activity.watchStats.trendAria", { metric: metric.label })}
          onMouseMove={onMove}
          onMouseLeave={() => setHover(null)}
        >
          {Array.from({ length: gridSteps + 1 }, (_, i) => {
            const v = (yMax / gridSteps) * i;
            const yy = y(v);
            return (
              <g key={i}>
                <line
                  x1={PAD.left}
                  x2={width - PAD.right}
                  y1={yy}
                  y2={yy}
                  stroke={i === 0 ? "rgba(255,255,255,0.16)" : "rgba(255,255,255,0.07)"}
                />
                <text
                  x={PAD.left - 8}
                  y={yy + 3.5}
                  textAnchor="end"
                  fontSize={10}
                  fill="rgba(255,255,255,0.4)"
                  className="tnum"
                >
                  {metric.axis(v)}
                </text>
              </g>
            );
          })}
          {ticks.map((i) => (
            <text
              key={i}
              x={cx(i)}
              y={CHART_HEIGHT - 8}
              textAnchor={i === 0 ? "start" : i === count - 1 ? "end" : "middle"}
              fontSize={10}
              fill="rgba(255,255,255,0.4)"
            >
              {dayLabel(buckets[i][0].date, locale)}
            </text>
          ))}
          {current.map((v, i) =>
            v > 0 ? (
              <path
                key={i}
                d={barPath(cx(i) - barWidth / 2, y(v), barWidth, baseline - y(v))}
                fill={SERIES_COLOR}
                opacity={hover === null || hover === i ? 0.95 : 0.55}
              />
            ) : null,
          )}
          {showPrevious && (
            <path
              d={previousLine}
              fill="none"
              stroke={PREVIOUS_COLOR}
              strokeWidth={1.5}
              strokeDasharray="4 4"
              strokeLinejoin="round"
            />
          )}
          {hover !== null && (
            <g>
              <rect
                x={cx(hover) - slot / 2}
                y={PAD.top}
                width={slot}
                height={innerHeight}
                fill="rgba(255,255,255,0.05)"
              />
              {showPrevious && (
                <circle
                  cx={cx(hover)}
                  cy={y(previous[hover])}
                  r={3.5}
                  fill={PREVIOUS_COLOR}
                  stroke="rgba(10,12,18,0.9)"
                  strokeWidth={1.5}
                />
              )}
            </g>
          )}
        </svg>
      )}
      {width > 0 && current.every((v) => v <= 0) && (
        <p className="pointer-events-none absolute inset-x-0 top-[44px] text-center">
          <span className="rounded-full bg-[#0b0d13]/85 px-3 py-1 text-caption text-white/50 ring-1 ring-white/[0.08]">
            {t("activity.watchStats.noChartPlays", { showPrevious: showPrevious ? "yes" : "no" })}
          </span>
        </p>
      )}
      {hover !== null && width > 0 && (
        // menu-surface 自带 position: relative，定位交给外层
        <div
          className="pointer-events-none absolute z-10"
          style={{
            left: Math.min(Math.max(cx(hover) - 80, 0), width - 170),
            top: 24,
          }}
        >
          <div className="menu-surface min-w-[10rem] px-3 py-2 text-caption">
            <p className="font-semibold text-white/85">
              {bucketLabel(buckets[hover], locale)}
              {weekly && buckets[hover].length < 7 && (
                <span className="ml-1 font-normal text-white/35">{t("activity.watchStats.dayCount", { count: buckets[hover].length })}</span>
              )}
            </p>
            <p className="tnum mt-1 flex items-center gap-1.5 text-white/80">
              <span
                className="inline-block size-2 rounded-[2px]"
                style={{ background: SERIES_COLOR }}
              />
              {t("activity.watchStats.currentPeriod")}{bucketNote}
              {metric.format(current[hover])}
            </p>
            {showPrevious && (
              <p className="tnum mt-0.5 flex items-center gap-1.5 text-white/55">
                <span
                  className="inline-block h-0 w-2 border-t border-dashed"
                  style={{ borderColor: PREVIOUS_COLOR }}
                />
                {t("activity.watchStats.previousPeriod")}{bucketNote}
                {metric.format(previous[hover])}
                <span className="text-white/35">{bucketLabel(prevBuckets[hover], locale)}</span>
              </p>
            )}
          </div>
        </div>
      )}
      <div className="mt-1 flex items-center gap-4 text-caption text-white/45">
        <span className="flex items-center gap-1.5">
          <span
            className="inline-block size-2.5 rounded-[3px]"
            style={{ background: SERIES_COLOR }}
          />
          {t("activity.watchStats.currentPeriod")}</span>
        {showPrevious && (
          <span className="flex items-center gap-1.5">
            <span
              className="inline-block h-0 w-4 border-t-2 border-dashed"
              style={{ borderColor: PREVIOUS_COLOR }}
            />
            {t("activity.watchStats.previousPeriod")}</span>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// 分解面板：同一个模板
// ---------------------------------------------------------------------------

interface BreakdownRow {
  key: string;
  label: React.ReactNode;
  value: number;
  valueLabel: string;
  secondary?: string;
  leading?: React.ReactNode;
  onSelect?: () => void;
  selected?: boolean;
  /** 「其他」这类合成行：字色与条色都压暗，不可点 */
  muted?: boolean;
}

/**
 * 分解面板：同一个模板（名称 · 值 · 占比条）。
 *
 * 行数**封顶**：成员三五个、客户端两三个、作品榜十个、播放方式最多五档，不封顶四块
 * 面板高矮参差。默认五行，多出来的按 fold 处理——`other` 把余下的合成一行「其他 N 个」
 * （占比仍合计 100%，高度钉死在六行内，Stripe / GA 的做法）；`expand` 留一个「展开
 * 全部」，作品不适合合并成「其他」，再长是用户自己点开的。面板撑满网格行高，同一行
 * 两块底边对齐，留白在卡片里而不是卡片外。
 */
function BreakdownPanel({
  title,
  note,
  rows,
  total,
  footer,
  emptyText,
  kind,
  formatValue,
  fold = "other",
  limit = 5,
}: {
  title: string;
  note?: string;
  rows: BreakdownRow[];
  total: number;
  footer?: React.ReactNode;
  /** 没有行时的说明；传 null 表示由 footer（如范围外折叠行）自己解释 */
  emptyText?: string | null;
  /** 行的量词：「个成员」「部」，用在「其他 3 个成员」「展开全部 10 部」 */
  kind: "members" | "clients" | "titles" | "tiers";
  /** 合成「其他」行时给值配文案 */
  formatValue: (value: number) => string;
  fold?: "other" | "expand";
  limit?: number;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const resolvedEmptyText = emptyText === undefined ? t("activity.watchStats.noData") : emptyText;
  const [expanded, setExpanded] = useState(false);
  let visible = rows;
  let tail: React.ReactNode = null;
  if (rows.length > limit) {
    if (fold === "expand") {
      visible = expanded ? rows : rows.slice(0, limit);
      tail = (
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          className="w-full px-4 py-2.5 text-left text-caption font-medium text-[var(--info)] transition hover:text-white max-md:px-3.5"
        >
          {expanded ? t("activity.watchStats.collapse") : t("activity.watchStats.expandAll", { count: rows.length, kind })}
        </button>
      );
    } else {
      const rest = rows.slice(limit);
      const value = rest.reduce((acc, r) => acc + r.value, 0);
      visible = [
        ...rows.slice(0, limit),
        {
          key: "__other",
          label: t("activity.watchStats.otherCount", { count: rest.length, kind }),
          value,
          valueLabel: formatValue(value),
          muted: true,
        },
      ];
    }
  }
  return (
    <section aria-label={title} className="flex h-full flex-col">
      <div className="mb-1.5 flex items-baseline gap-2">
        <p className="text-caption font-semibold text-white/55">{title}</p>
        {note && <p className="text-[11px] text-white/30">{note}</p>}
      </div>
      <div className="flex flex-1 flex-col divide-y divide-white/[0.06] rounded-2xl border border-white/[0.08] bg-white/[0.02]">
        {rows.length === 0 && resolvedEmptyText && (
          <p className="px-4 py-3 text-caption text-white/40">{resolvedEmptyText}</p>
        )}
        {visible.map((row) => {
          const share = total > 0 ? Math.round((row.value / total) * 100) : 0;
          const body = (
            <>
              {row.leading}
              <div className="min-w-0 flex-1">
                <div className={`flex items-baseline justify-between gap-3 ${locale === "en" ? "max-md:flex-col max-md:items-start max-md:gap-1" : ""}`}>
                  {/* 附注跟在名称后面而不是另起一行：四块面板的行高才一致，
                      同一行两块面板的高矮只由行数决定 */}
                  <div className={`flex min-w-0 items-baseline gap-2 ${locale === "en" ? "max-md:flex-col max-md:items-start max-md:gap-0.5" : ""}`}>
                    <div
                      className={`min-w-0 text-ui font-medium ${row.muted ? "text-white/50" : "text-white/85"}`}
                    >
                      {row.label}
                    </div>
                    {row.secondary && (
                      <span className="tnum shrink-0 text-[11px] text-white/35">
                        {row.secondary}
                      </span>
                    )}
                  </div>
                  <div className="tnum shrink-0 text-caption text-white/70">
                    {row.valueLabel}
                    <span className="ml-1.5 text-white/35">{share}%</span>
                  </div>
                </div>
                {/* 条的长度就是份额：与右边的百分比、与总量三者自洽，几根条加起来
                    正好填满一行；不按第一名满格来缩放，那样条与数字会打架 */}
                <div className="mt-1.5 h-[3px] rounded-full bg-white/[0.06]">
                  <div
                    className="h-full rounded-full"
                    style={{
                      width: `${Math.max(1, share)}%`,
                      background: row.selected
                        ? "var(--ok)"
                        : row.muted
                          ? "rgba(255,255,255,0.22)"
                          : SERIES_COLOR,
                      opacity: row.selected || row.muted ? 1 : 0.9,
                    }}
                  />
                </div>
              </div>
            </>
          );
          const className = "flex items-center gap-3 px-4 py-2.5 max-md:px-3.5";
          return row.onSelect ? (
            <button
              key={row.key}
              type="button"
              aria-pressed={row.selected}
              onClick={row.onSelect}
              className={`${className} w-full text-left transition hover:bg-white/[0.04]`}
            >
              {body}
            </button>
          ) : (
            <div key={row.key} className={className}>
              {body}
            </div>
          );
        })}
        {tail}
        {footer}
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// 时段热力图：星期 × 小时
// ---------------------------------------------------------------------------

function HourHeatmap({ matrix }: { matrix: number[][] }) {
  const t = useTranslations();
  const locale = useLocale();

  const max = Math.max(1e-9, ...matrix.flat());
  const total = matrix.flat().reduce((a, b) => a + b, 0);
  return (
    <section aria-label={t("activity.watchStats.heatmap")}>
      <div className="mb-1.5 flex items-baseline gap-2">
        <p className="text-caption font-semibold text-white/55">{t("activity.watchStats.heatmap")}</p>
        <p className="text-[11px] text-white/30">{t("activity.watchStats.heatmapHint")}</p>
      </div>
      <div className="overflow-x-auto rounded-2xl border border-white/[0.08] bg-white/[0.02] px-4 py-3">
        {/* 没数据也把 7×24 的格子画出来：空格子本身就在说明这里会是什么 */}
        {total === 0 && (
          <p className="mb-2 text-caption text-white/40">
            {t("activity.watchStats.noHeatmap")}</p>
        )}
        {
          <div className="min-w-[520px]">
            <div className="ml-6 grid grid-cols-24 gap-[2px] text-[10px] text-white/35">
              {Array.from({ length: 24 }, (_, h) => (
                <span key={h} className="tnum text-center">
                  {h % 6 === 0 ? h : ""}
                </span>
              ))}
            </div>
            {matrix.map((row, day) => (
              <div key={day} className="mt-[2px] flex items-center gap-[2px]">
                <span className="w-6 shrink-0 text-[10px] text-white/40">{weekday(day, locale, true)}</span>
                <div className="grid flex-1 grid-cols-24 gap-[2px]">
                  {row.map((v, h) => (
                    <div
                      key={h}
                      title={t("activity.watchStats.heatmapCell", { weekday: weekday(day, locale, false), hour: String(h).padStart(2, "0"), duration: formatWatched(v, locale) })}
                      className="h-4 rounded-[3px]"
                      style={{
                        background:
                          v > 0
                            ? `rgba(127,176,255,${(0.18 + (v / max) * 0.82).toFixed(2)})`
                            : "rgba(255,255,255,0.04)",
                      }}
                    />
                  ))}
                </div>
              </div>
            ))}
          </div>
        }
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// 最受欢迎：Netflix「TOP 10」式的前三，整页唯一允许「隆重」的地方
// ---------------------------------------------------------------------------

/** 与上一周期前三的对照：同名次「蝉联」，换了名次「上期第 n」，上期不在榜「新上榜」。 */
function rankChange(
  row: PlaybackStatsTitleRow,
  rank: number,
  previous: PlaybackStatsTitleRow[],
  locale: AppLocale = requestLocale() ?? "zh-Hans",
): { text: string; tone: string } | null {
  const t = appTranslator(locale);
  if (previous.length === 0) return null;
  const was = previous.findIndex((p) => p.media.media_item_id === row.media.media_item_id);
  if (was === rank) return { text: t("activity.watchStats.sameRank"), tone: "bg-[var(--ok)]/15 text-[var(--ok)]" };
  if (was === -1) return { text: t("activity.watchStats.newRank"), tone: "bg-[var(--info)]/15 text-[var(--info)]" };
  return {
    text: t("activity.watchStats.previousRank", { arrow: was > rank ? "▲" : "▼", rank: was + 1 }),
    tone: was > rank ? "bg-[var(--ok)]/15 text-[var(--ok)]" : "bg-white/[0.08] text-white/55",
  };
}

const KIND_LABELS: Partial<Record<string, AppMessageKey>> = { movie: "media.kind.movie", tv: "media.kind.tv" };

/**
 * 一个名次：巨大的描边数字压在海报左后方，海报盖住数字的右侧——Netflix 的 TOP 10
 * 就是这套语法，数字本身就是装饰，不再需要徽标。第一名的数字与海报都更大。
 */
function TopEntry({
  row,
  rank,
  hero,
  drilled,
  previous,
}: {
  row: PlaybackStatsTitleRow;
  rank: number;
  hero: boolean;
  drilled: boolean;
  previous: PlaybackStatsTitleRow[];
}) {
  const t = useTranslations();
  const locale = useLocale();

  const change = rankChange(row, rank, previous, locale);
  const kindKey = Object.hasOwn(KIND_LABELS, row.media.kind) ? KIND_LABELS[row.media.kind] : undefined;
  const kind = kindKey ? t(kindKey) : undefined;
  const facts = [row.media.year, kind].filter(Boolean).join(" · ");
  const watched = formatWatched(row.watched_ms, locale);
  const plays = t("activity.watchStats.playsValue", { count: row.plays });
  const audience = drilled ? null : t("activity.watchStats.audience", { count: row.members });
  // 文字栏窄：人数与场次并一行、时长单独一行，别让「· 7 场」孤零零折到下一行
  const meta = [[audience, plays].filter(Boolean).join(" · "), watched];
  return (
    <div className="flex min-w-0 items-end">
      {/* 数字盒子定宽（按 em）、靠左排，「1」「2」「3」宽窄不一也只让海报盖住右侧一角 */}
      <span
        aria-hidden="true"
        className={`relative inline-block shrink-0 select-none text-left font-black leading-[0.78] tracking-[-0.06em] text-transparent [-webkit-text-stroke:2px_rgba(255,255,255,0.62)] ${
          hero ? `-mr-[0.12em] w-[0.6em] text-[128px] ${locale === "en" ? "max-md:text-[96px]" : ""}` : "-mr-[0.12em] w-[0.6em] text-[96px]"
        }`}
      >
        {rank + 1}
      </span>
      <PosterImage
        src={row.media.poster_url ? imageUrl(row.media.poster_url) : null}
        // 冠军 120×180、亚季军 80×120
        width={hero ? 120 : 80}
        alt={row.media.title}
        className={`relative z-10 shrink-0 rounded-lg object-cover shadow-[0_18px_40px_rgba(0,0,0,0.6)] ring-1 ring-white/15 ${
          hero ? `h-[180px] w-[120px] ${locale === "en" ? "max-md:h-[120px] max-md:w-[80px]" : ""}` : "h-[120px] w-[80px]"
        }`}
      />
      <div className="relative z-10 ml-3 min-w-0 flex-1 self-center">
        <p className="mb-1 text-[10px] font-bold tracking-[0.2em] text-white/40">
          {[t("activity.watchStats.first"), t("activity.watchStats.second"), t("activity.watchStats.third")][rank]}
        </p>
        <TitleText media={row.media} episode={false} large={hero} />
        {facts && <p className="tnum mt-0.5 text-caption text-white/45">{facts}</p>}
        {meta.map((line) => (
          <p key={line} className="tnum mt-1 text-caption leading-5 text-white/60">
            {line}
          </p>
        ))}
        {change && (
          <p className="mt-2">
            <span
              className={`tnum rounded-md px-1.5 py-0.5 text-[11px] font-semibold ${change.tone}`}
            >
              {change.text}
            </span>
          </p>
        )}
      </div>
    </div>
  );
}

/**
 * 本期最受欢迎前三：看过的成员最多，并列取时长长的。与「看得最多」（按时长）是
 * 两个问题，同一部片同时占两头也是信息——既有人看又看得久。背景是第一名海报
 * 放大模糊后的环境光，整块随作品换色；钻取到单个成员时人数没有意义，退成
 * 「本期看得最多」。
 */
function FavoritePodium({
  favorites,
  previous,
  memberId,
  hiddenCount,
  onShowAll,
}: {
  favorites: PlaybackStatsTitleRow[];
  previous: PlaybackStatsTitleRow[];
  memberId: number | null;
  /** 作品榜里不在浏览范围内的条数：前三全被折掉时要说明去向 */
  hiddenCount: number;
  onShowAll: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  if (favorites.length === 0) {
    // 有播放却没有上榜作品：要么都在范围外，要么条目已被删除；说清去向，不留空白
    return (
      <div className="rounded-2xl border border-white/[0.08] bg-white/[0.02]">
        <EmptyState
          compact
          icon={
            hiddenCount > 0 ? <LockIcon className="size-3.5" /> : <StarIcon className="size-3.5" />
          }
          title={
            hiddenCount > 0 ? t("activity.watchStats.popularOutside") : t("activity.watchStats.noRankedTitles")
          }
          description={
            hiddenCount > 0
              ? t("activity.watchStats.hiddenTitles", { count: hiddenCount })
              : t("activity.watchStats.deletedNoRanking")
          }
          actions={
            hiddenCount > 0 ? <EmptyAction onClick={onShowAll}>{t("activity.watchStats.showAll")}</EmptyAction> : undefined
          }
        />
      </div>
    );
  }
  const drilled = memberId != null;
  const [first, ...rest] = favorites;
  // 氛围底是放大 1.5 倍再重模糊的海报，小图就够；与冠军卡同一宽度（120），地址一致只取一次
  const ambient = first.media.poster_url ? imageUrl(first.media.poster_url) : null;
  // 不足三部时列数跟着少，别留空位
  const columns = ["1.5fr", ...rest.map(() => "1fr")].join(" ");
  return (
    <section
      aria-label={drilled ? t("activity.watchStats.mostWatchedThis") : t("activity.watchStats.mostPopularThis")}
      className="relative overflow-hidden rounded-2xl border border-white/[0.08] bg-white/[0.02]"
    >
      {ambient && (
        <div aria-hidden="true" className="pointer-events-none absolute inset-0">
          <PosterImage
            src={ambient}
            width={120}
            alt=""
            className="h-full w-full scale-150 object-cover opacity-45 blur-3xl saturate-150"
          />
          <div className="absolute inset-0 bg-[linear-gradient(90deg,rgba(11,13,19,0.88),rgba(11,13,19,0.72)_45%,rgba(11,13,19,0.9))]" />
        </div>
      )}
      <div className="relative p-4 md:p-5">
        <div className={`flex items-center gap-2.5 ${locale === "en" ? "max-md:flex-wrap" : ""}`}>
          <span className="rounded-[3px] bg-[var(--info)] px-1.5 py-[3px] text-[10px] font-black leading-none tracking-[0.12em] text-[#0b0d13]">
            TOP 3
          </span>
          <p className="text-ui font-semibold text-white/90">
            {drilled ? t("activity.watchStats.mostWatchedThis") : t("activity.watchStats.mostPopularThis")}
          </p>
          <p className={`text-caption text-white/35 ${locale === "en" ? "max-md:basis-full" : ""}`}>
            {drilled ? t("activity.watchStats.byWatchTime") : t("activity.watchStats.byAudience")}
          </p>
        </div>
        <div
          className="mt-5 grid items-end gap-x-5 gap-y-6 md:[grid-template-columns:var(--podium-cols)]"
          style={{ "--podium-cols": columns } as React.CSSProperties}
        >
          <TopEntry row={first} rank={0} hero drilled={drilled} previous={previous} />
          {rest.map((row, i) => (
            <TopEntry
              key={row.media.media_item_id}
              row={row}
              rank={i + 1}
              hero={false}
              drilled={drilled}
              previous={previous}
            />
          ))}
        </div>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// 面板
// ---------------------------------------------------------------------------

/** 读取中的骨架：与真实布局同形（指标卡、主图、TOP 3、四块分解），内容到达时不跳动。 */
function StatsSkeleton() {
  const t = useTranslations();

  return (
    <div aria-busy="true" aria-label={t("activity.watchStats.reading")} className="space-y-4">
      <div className="grid grid-cols-4 gap-2.5 max-md:grid-cols-2">
        {Array.from({ length: 4 }, (_, i) => (
          <div
            key={i}
            className="rounded-2xl border border-white/[0.08] bg-white/[0.03] px-4 py-3.5"
          >
            <Skeleton className="h-3 w-14" />
            <Skeleton className="mt-3 h-7 w-24" />
            <Skeleton className="mt-3 h-3 w-28" />
          </div>
        ))}
      </div>
      <div className="rounded-2xl border border-white/[0.08] bg-white/[0.02] p-5">
        <Skeleton className="h-4 w-32" />
        <div className="mt-5 flex items-end gap-6 max-md:flex-col max-md:items-stretch">
          <Skeleton className="h-[180px] w-full md:w-[38%]" />
          <Skeleton className="h-[120px] w-full md:w-[26%]" />
          <Skeleton className="h-[120px] w-full md:w-[26%]" />
        </div>
      </div>
      <div className="rounded-2xl border border-white/[0.08] bg-white/[0.02] p-3">
        <Skeleton className="h-3 w-20" />
        <Skeleton className="mt-3 h-[220px] w-full" />
      </div>
      <div className="grid grid-cols-2 gap-4 max-md:grid-cols-1">
        {Array.from({ length: 4 }, (_, i) => (
          <Skeleton key={i} className="h-40 w-full rounded-2xl" />
        ))}
      </div>
    </div>
  );
}

export function WatchStatsPanel({
  scope,
  days,
  memberId,
  memberLabel,
  onMemberSelect,
  onDaysChange,
  onShowAll,
}: {
  scope: MediaActivityScope;
  days: number;
  /** 钻取到某个成员；null = 全部 */
  memberId: number | null;
  /** 钻取中成员的显示名，空状态里点名用 */
  memberLabel: string | null;
  onMemberSelect: (memberId: number | null) => void;
  onDaysChange: (days: number) => void;
  onShowAll: () => void;
}) {
  const t = useTranslations();
  const locale = useLocale();

  const [stats, setStats] = useState<PlaybackWatchStats | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [metricKey, setMetricKey] = useState<MetricKey>("watched_ms");
  const metrics = useMemo(() => watchMetrics(locale), [locale]);
  const metric = metrics.find((m) => m.key === metricKey) ?? metrics[0];

  useEffect(() => {
    let cancelled = false;
    void fetchPlaybackWatchStats(days, scope, memberId)
      .then((next) => {
        if (cancelled) return;
        setStats(next);
        setError(null);
      })
      .catch((caught) => {
        if (!cancelled) setError((caught as Error).message || t("activity.watchStats.loadFailed"));
      });
    return () => {
      cancelled = true;
    };
  }, [days, scope, memberId, t]);

  if (error) {
    return (
      <p className="rounded-xl border border-amber-400/25 bg-amber-500/10 px-4 py-3 text-sub leading-6 text-amber-100">
        {error}
      </p>
    );
  }
  if (!stats) {
    return <StatsSkeleton />;
  }

  // 空状态里能做的事：清掉成员钻取、把周期拉到最长——两者都是「换个口径再看」
  const widenActions = (
    <>
      {memberId != null && (
        <EmptyAction onClick={() => onMemberSelect(null)}>{t("activity.watchStats.allMembers")}</EmptyAction>
      )}
      {days < 90 && <EmptyAction onClick={() => onDaysChange(90)}>{t("activity.watchStats.last90")}</EmptyAction>}
    </>
  );
  const who = memberId != null ? (memberLabel ?? t("activity.watchStats.memberFallback")) : null;

  if (stats.current.plays === 0 && !stats.previous_available) {
    // 两个周期都没有日志：整块用一个空状态承接，不摆一排 0
    return (
      <EmptyState
        icon={<ActivityIcon className="size-5" />}
        title={t("activity.watchStats.noRecent", { hasMember: who ? "yes" : "no", name: who ?? "", days })}
        description={t("activity.watchStats.emptyHint")}
        actions={widenActions}
      />
    );
  }

  const totalWatched = stats.current.watched_ms;
  const tierTotal = stats.by_tier.reduce((sum, r) => sum + r.plays, 0);
  const cards = (
    <div className="grid grid-cols-4 gap-2.5 max-md:grid-cols-2">
      {metrics.map((m) => (
        <MetricCard
          key={m.key}
          metric={m}
          stats={stats}
          selected={m.key === metricKey}
          onSelect={() => setMetricKey(m.key)}
        />
      ))}
    </div>
  );
  const chart = (
    <div className="rounded-2xl border border-white/[0.08] bg-white/[0.02] px-3 pb-3 pt-3">
      <TrendChart stats={stats} metric={metric} />
    </div>
  );

  if (stats.current.plays === 0) {
    // 本期一场都没有、上期有：指标卡与主图仍有对照价值，其余分解没有内容，
    // 用一个空状态代替五块各自写「没有数据」
    return (
      <div className="space-y-4">
        {cards}
        {chart}
        <EmptyState
          icon={<ActivityIcon className="size-5" />}
          title={who ? t("activity.watchStats.noMemberCurrent", { name: who }) : t("activity.watchStats.noCurrent")}
          description={t("activity.watchStats.onlyPrevious", { count: stats.previous.plays })}
          actions={widenActions}
        />
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {cards}

      {/* TOP 3 紧跟指标卡：先给结论（谁在被看），走势与分解在后 */}
      <FavoritePodium
        favorites={stats.favorites}
        previous={stats.previous_favorites}
        memberId={memberId}
        hiddenCount={stats.hidden_title_count}
        onShowAll={onShowAll}
      />

      {chart}

      <div className="grid grid-cols-2 gap-4 max-md:grid-cols-1">
        <BreakdownPanel
          title={t("activity.watchStats.byMember")}
          note={memberId != null ? t("activity.watchStats.memberSelected") : t("activity.watchStats.memberDrill")}
          total={totalWatched}
          kind="members"
          formatValue={(value) => formatWatched(value, locale)}
          rows={stats.by_member.map((row) => ({
            key: String(row.member_id),
            label: row.member_name,
            value: row.watched_ms,
            valueLabel: formatWatched(row.watched_ms, locale),
            secondary: t("activity.watchStats.playsCompleted", { count: row.plays, completed: row.completed }),
            selected: memberId === row.member_id,
            onSelect: () => onMemberSelect(memberId === row.member_id ? null : row.member_id),
          }))}
        />
        <BreakdownPanel
          title={t("activity.watchStats.byClient")}
          total={totalWatched}
          kind="clients"
          formatValue={formatWatched}
          rows={stats.by_client.map((row) => ({
            key: row.client,
            label: row.client,
            value: row.watched_ms,
            valueLabel: formatWatched(row.watched_ms, locale),
            secondary: t("activity.watchStats.playsValue", { count: row.plays }),
          }))}
        />
        <BreakdownPanel
          title={t("activity.watchStats.mostWatched")}
          total={totalWatched}
          kind="titles"
          formatValue={formatWatched}
          fold="expand"
          rows={stats.top_titles.map((row, index) => ({
            key: `${row.media.media_item_id}-${index}`,
            label: <TitleText media={row.media} />,
            value: row.watched_ms,
            valueLabel: formatWatched(row.watched_ms, locale),
            secondary: t("activity.watchStats.playsValue", { count: row.plays }),
            leading: (
              <PosterImage
                src={row.media.poster_url ? imageUrl(row.media.poster_url) : null}
                width={24}
                alt={row.media.title}
                className="h-9 w-6 shrink-0 rounded-md object-cover ring-1 ring-white/10"
              />
            ),
          }))}
          footer={
            <HiddenCountRow count={stats.hidden_title_count} kind="items" onShowAll={onShowAll} />
          }
          emptyText={stats.hidden_title_count > 0 ? null : t("activity.watchStats.deletedItems")}
        />
        <BreakdownPanel
          title={t("activity.watchStats.byDelivery")}
          note={t("activity.watchStats.deliveryHint")}
          total={tierTotal}
          kind="tiers"
          formatValue={(v) => t("activity.watchStats.playsValue", { count: v })}
          emptyText={t("activity.watchStats.noDelivery")}
          rows={stats.by_tier.map((row) => ({
            key: String(row.tier),
            label: row.label,
            value: row.plays,
            valueLabel: t("activity.watchStats.playsValue", { count: row.plays }),
          }))}
        />
      </div>

      <HourHeatmap matrix={stats.by_hour} />
    </div>
  );
}
