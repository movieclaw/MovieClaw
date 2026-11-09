"use client";

import { useTranslations } from "next-intl";

import { HeartIcon, StarIcon } from "@/components/icons";
import {
  detailAirStatus,
  hasAnyBadge,
  hasTopBadges,
  posterBadges,
  type PosterBadgeSet,
  type PosterBadgeSource,
} from "@/lib/poster-badges";
import { useUiPrefs } from "@/lib/ui-prefs";

/**
 * 当前观看者开着的角标作用在这一格上的结果（偏好变了即时重算，墙不用重拉）。
 * 一枚都不亮时返回 null：卡片完全走改版前的渲染路径，默认观感逐像素不变。
 */
export function usePosterBadges(source: PosterBadgeSource | undefined): PosterBadgeSet | null {
  const { prefs } = useUiPrefs();
  if (!source) return null;
  const set = posterBadges(source, prefs.poster_badges);
  return hasAnyBadge(set) ? set : null;
}

/** 角标的读屏文案：卡片本身是一个带 aria-label 的链接，角标要并进那句话里才读得到。 */
export function usePosterBadgeDescriptions(set: PosterBadgeSet | null): string[] {
  const t = useTranslations();
  if (!set) return [];
  return [
    set.rating != null ? t("library.posterBadges.rating", { rating: set.rating.toFixed(1) }) : null,
    set.status ? t(`library.posterBadges.${set.status}`) : null,
    set.resolution,
    ...set.formats,
    set.chineseSubtitle ? t("library.posterBadges.chineseSubtitle") : null,
    set.unwatched
      ? t("library.posterBadges.unwatched", { count: Number.parseInt(set.unwatched, 10) })
      : null,
    set.progress != null ? t("library.posterBadges.progress", { percent: set.progress }) : null,
  ].filter((text): text is string => Boolean(text));
}

/** 角标的底色与字号：与发现页清晰度 / 评分徽章同一套（实底不模糊，海报墙 GPU 约束见 poster-card） */
const CHIP = "rounded-md bg-black/70 px-1.5 py-0.5 text-micro font-bold leading-[14px] tracking-wide";
/** 「仅悬停」模式下顶部角标的显隐：与 hover 信息层同一组触发（悬停 / 键盘聚焦 / 触屏首点展开） */
const REVEAL =
  "opacity-0 transition-opacity duration-200 group-hover/card:opacity-100 group-focus-visible/card:opacity-100 group-data-[revealed=true]/card:opacity-100";
/** 底部标记在 hover 信息层升起时让位（两层叠在一起谁都读不清），与订阅墙底栏同一手法 */
const YIELD =
  "transition-opacity duration-200 group-hover/card:opacity-0 group-focus-visible/card:opacity-0 group-data-[revealed=true]/card:opacity-0";

/**
 * 库存海报上的角标层（绝对定位在海报框里，不接收指针事件）。
 *
 *   顶部一排：左 评分 · 年份；右 完结/更新中 · 分辨率 · HDR/DV · Atmos · 收藏的心
 *   左下「中」（中文字幕）· 右下未看集数 · 底边进度条
 *
 * 收藏的心原本独占右上角，这里把它收进右侧那一排的末尾（常驻，不受「仅悬停」影响），
 * 右侧换行向下排，窄格子（手机两列 126~140px）也不会溢出或压到左侧评分。
 * 库存卡没有选择框与斜标；hover 信息层从底部升起时底部标记让位，进度条贴底常驻。
 */
export function PosterBadgeOverlay({
  set,
  favorite,
  yieldBottom,
}: {
  set: PosterBadgeSet;
  favorite: boolean;
  /** 这张卡有 hover 信息层：底部标记要给它让位 */
  yieldBottom: boolean;
}) {
  const t = useTranslations();
  const { prefs } = useUiPrefs();
  const reveal = prefs.poster_badges.hover_only ? REVEAL : "";
  const showTop = hasTopBadges(set) || favorite;
  return (
    <>
      {showTop && (
        <div
          aria-hidden="true"
          data-testid="poster-badges-top"
          className="pointer-events-none absolute inset-x-2 top-2 z-10 flex items-start justify-between gap-1"
        >
          <div className="flex shrink-0 flex-col items-start gap-1">
            {set.rating != null && (
              <span
                data-badge="rating"
                className={`tnum flex items-center gap-0.5 ${CHIP} text-white ${reveal}`}
              >
                <StarIcon className="size-2.5 text-[var(--warn)]" />
                {set.rating.toFixed(1)}
              </span>
            )}
            {set.year && (
              <span data-badge="year" className={`tnum ${CHIP} font-semibold text-white/80 ${reveal}`}>
                {set.year}
              </span>
            )}
          </div>
          <div className="flex min-w-0 flex-wrap items-center justify-end gap-1">
            {set.status && (
              <span
                data-badge="status"
                className={`${CHIP} ${set.status === "ended" ? "text-[var(--ok)]" : "text-[var(--info)]"} ${reveal}`}
              >
                {t(`library.posterBadges.${set.status}`)}
              </span>
            )}
            {set.resolution && (
              <span
                data-badge="resolution"
                className={`${CHIP} ${set.resolution === "4K" || set.resolution === "8K" ? "text-[var(--accent)]" : "text-white"} ${reveal}`}
              >
                {set.resolution}
              </span>
            )}
            {set.formats.map((label) => (
              <span key={label} data-badge="format" className={`${CHIP} text-white ${reveal}`}>
                {label}
              </span>
            ))}
            {favorite && (
              <span className="flex items-center rounded-md bg-black/70 px-1 py-0.5 text-[var(--danger)]">
                <HeartIcon className="size-3.5" fill="currentColor" />
              </span>
            )}
          </div>
        </div>
      )}
      {set.chineseSubtitle && (
        <span
          aria-hidden="true"
          data-badge="chinese-subtitle"
          className={`pointer-events-none absolute bottom-2 left-2 z-10 grid h-5 min-w-5 place-items-center rounded-md border border-[var(--accent)]/60 bg-black/70 px-1 text-micro font-bold text-[var(--accent)] ${yieldBottom ? YIELD : ""}`}
        >
          {t("library.posterBadges.chineseSubtitleMark")}
        </span>
      )}
      {set.unwatched && (
        <span
          aria-hidden="true"
          data-badge="unwatched"
          className={`tnum pointer-events-none absolute bottom-2 right-2 z-10 grid h-5 min-w-5 place-items-center rounded-full bg-[var(--accent)] px-1.5 text-micro font-bold text-black shadow-[0_1px_5px_rgba(0,0,0,0.45)] ${yieldBottom ? YIELD : ""}`}
        >
          {set.unwatched}
        </span>
      )}
      {set.progress != null && (
        <span
          aria-hidden="true"
          data-badge="progress"
          className="pointer-events-none absolute inset-x-0 bottom-0 z-20 h-[3px] bg-white/20"
        >
          <span
            className="block h-full bg-[var(--accent)]"
            style={{ width: `${Math.max(2, set.progress)}%` }}
          />
        </span>
      )}
    </>
  );
}

/** 详情页标题旁的「更新中 / 完结」。打开了任一状态角标才显示（见 detailAirStatus）。 */
export function DetailAirStatusLabel({
  kind,
  airStatus,
}: {
  kind: string;
  airStatus: "airing" | "ended" | null | undefined;
}) {
  const t = useTranslations();
  const { prefs } = useUiPrefs();
  const status = detailAirStatus(kind, airStatus, prefs.poster_badges);
  if (!status) return null;
  const label = t(`library.posterBadges.${status}`);
  return (
    <span
      data-testid="detail-air-status"
      aria-label={t("library.posterBadges.detailStatus", { status: label })}
      className={`ml-3 inline-flex shrink-0 items-center rounded-md border px-2 py-0.5 align-middle text-caption font-semibold tracking-wide ${
        status === "ended"
          ? "border-[var(--ok)]/50 bg-[var(--ok)]/10 text-[var(--ok)]"
          : "border-[var(--info)]/50 bg-[var(--info)]/10 text-[var(--info)]"
      }`}
    >
      {label}
    </span>
  );
}
