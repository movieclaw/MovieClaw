"use client";

import { useTranslations } from "next-intl";
import { useState } from "react";

import { StarIcon } from "@/components/icons";
import {
  STAR_COUNT,
  canRateTarget,
  formatStarRating,
  formatStarShort,
  nextRatingOnClick,
  starFillState,
} from "@/lib/user-rating";

/**
 * 5 星半星个人评分控件（docs/design/user-rating.md §5）。
 *
 * - 每颗星分为左半（半星）与右半（整星）两个可点击 / 可聚焦热区，悬停实时预览；
 * - 再次点击当前分值或点击旁边的「清除」即可取消评分（提交 0）；
 * - 视觉上使用主题色实心星，与元信息行的 TMDB 评分明确区分；
 * - 第一期仅开放电影与整剧：带季号 / 集号或非 movie / tv 时不渲染。
 */
export function StarRating({
  value,
  onChange,
  kind = "movie",
  seasonNumber = null,
  episodeNumber = null,
  disabled = false,
  targetLabel,
}: {
  /** 当前个人评分（1–10 整数）；null = 未评分 */
  value: number | null;
  /** 设置或清除评分：1–10 = 设置，0 = 清除 */
  onChange: (next: number) => void;
  kind?: string;
  seasonNumber?: number | null;
  episodeNumber?: number | null;
  disabled?: boolean;
  /** 评分对象称呼（「这部电影」/「这部剧」），用于读屏标签 */
  targetLabel?: string;
}) {
  const t = useTranslations();
  const [hoverValue, setHoverValue] = useState<number | null>(null);

  if (!canRateTarget({ kind, seasonNumber, episodeNumber })) {
    return null;
  }

  const activeValue = !disabled && hoverValue != null ? hoverValue : value;
  const groupLabel = targetLabel
    ? t("library.item.rateTitle", { title: targetLabel })
    : t("library.item.myRating");

  return (
    <div
      role="group"
      aria-label={groupLabel}
      data-testid="star-rating"
      data-value={value ?? ""}
      onMouseLeave={() => setHoverValue(null)}
      onBlur={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) {
          setHoverValue(null);
        }
      }}
      className={`page-nav-btn inline-flex h-12 shrink-0 items-center gap-2 rounded-full border border-white/[0.12] bg-white/[0.08] px-3.5 text-white/85 backdrop-blur-md transition duration-200 max-md:h-11 max-md:px-3 ${
        disabled ? "pointer-events-none opacity-60" : ""
      }`}
    >
      <div className="flex items-center gap-0.5">
        {Array.from({ length: STAR_COUNT }, (_, idx) => {
          const starIndex = idx + 1;
          const leftValue = starIndex * 2 - 1;
          const rightValue = starIndex * 2;
          const fill = starFillState(starIndex, activeValue);
          return (
            <span
              key={starIndex}
              data-star={starIndex}
              data-star-fill={fill}
              className="relative inline-flex size-5 shrink-0 items-center justify-center"
            >
              <StarIcon className="pointer-events-none size-5 text-white/25" />
              {fill === "full" && (
                <StarIcon className="pointer-events-none absolute inset-0 size-5 text-[var(--accent)]" />
              )}
              {fill === "half" && (
                <span className="pointer-events-none absolute inset-y-0 left-0 w-1/2 overflow-hidden">
                  <StarIcon className="size-5 max-w-none text-[var(--accent)]" />
                </span>
              )}
              <button
                type="button"
                disabled={disabled}
                data-rating-value={leftValue}
                aria-label={t("library.item.rateStars", { stars: formatStarShort(leftValue) })}
                aria-pressed={value === leftValue}
                onMouseEnter={() => setHoverValue(leftValue)}
                onFocus={() => setHoverValue(leftValue)}
                onClick={() => onChange(nextRatingOnClick(value, leftValue))}
                className="absolute inset-y-0 left-0 w-1/2 cursor-pointer rounded-l-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-[var(--accent-ring)] disabled:cursor-default"
              />
              <button
                type="button"
                disabled={disabled}
                data-rating-value={rightValue}
                aria-label={t("library.item.rateStars", { stars: formatStarShort(rightValue) })}
                aria-pressed={value === rightValue}
                onMouseEnter={() => setHoverValue(rightValue)}
                onFocus={() => setHoverValue(rightValue)}
                onClick={() => onChange(nextRatingOnClick(value, rightValue))}
                className="absolute inset-y-0 right-0 w-1/2 cursor-pointer rounded-r-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-[var(--accent-ring)] disabled:cursor-default"
              />
            </span>
          );
        })}
      </div>
      {activeValue != null ? (
        <span
          data-testid="star-rating-value"
          className="tnum min-w-[2.2em] text-center text-caption font-semibold text-[var(--accent)]"
        >
          {formatStarRating(activeValue)}
        </span>
      ) : (
        <span className="text-caption text-white/55">{t("library.item.rate")}</span>
      )}
      {value != null && !disabled && (
        <button
          type="button"
          data-testid="star-rating-clear"
          aria-label={t("library.item.clearRating")}
          title={t("library.item.clearRating")}
          onMouseEnter={() => setHoverValue(null)}
          onClick={() => {
            setHoverValue(null);
            onChange(0);
          }}
          className="rounded-full px-1.5 py-0.5 text-caption text-white/55 transition hover:bg-white/[0.12] hover:text-white focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-[var(--accent-ring)]"
        >
          {t("library.item.clear")}
        </button>
      )}
    </div>
  );
}
