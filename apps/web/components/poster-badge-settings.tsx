"use client";

import { useTranslations } from "next-intl";
import { useRef, useState } from "react";

import { SheetToggleRow } from "@/components/sheet-scaffold";
import {
  POSTER_BADGE_TOGGLES,
  type PosterBadgePrefs,
} from "@/lib/poster-badges";
import { useUiPrefs } from "@/lib/ui-prefs";

/** 开关键 → 文案键（文案键段内不能带下划线） */
const TOGGLE_LABELS = {
  rating: "library.posterBadges.toggleRating",
  year: "library.posterBadges.toggleYear",
  resolution: "library.posterBadges.toggleResolution",
  format: "library.posterBadges.toggleFormat",
  ended: "library.posterBadges.toggleEnded",
  airing: "library.posterBadges.toggleAiring",
  chinese_subtitle: "library.posterBadges.toggleChineseSubtitle",
  unwatched: "library.posterBadges.toggleUnwatched",
  progress: "library.posterBadges.toggleProgress",
} as const satisfies Record<(typeof POSTER_BADGE_TOGGLES)[number], string>;

/** 最低评分的几档：滑杆在这里只会让人纠结 6.3 还是 6.4，下拉给几个常用门槛就够 */
const MIN_RATING_STEPS = [0, 5, 6, 6.5, 7, 7.5, 8, 8.5];

/**
 * 「自定义首页」里的海报角标设置：一个开关一枚角标，外加顶部角标的显示方式与最低评分。
 *
 * 与本页其余设置同一约定：没有保存键，每次改动即时落库（界面偏好整体 PUT，乐观更新），
 * 只影响自己（成员各存各的，跨设备同步）。偏好一变，全站海报墙立即按新开关重画——
 * 墙上的数据早就随列表接口到了，打开开关不会多发请求。
 */
export function PosterBadgeSettings() {
  const t = useTranslations();
  const { prefs, savePrefs } = useUiPrefs();
  const [error, setError] = useState<string | null>(null);
  // 连点几个开关时 savePrefs 闭包里的 prefs 会过期：PUT 的是整份界面偏好，必须基于最新值
  const prefsRef = useRef(prefs);
  prefsRef.current = prefs;
  const badges = prefs.poster_badges;

  const update = (patch: Partial<PosterBadgePrefs>) => {
    setError(null);
    const current = prefsRef.current;
    const next = { ...current, poster_badges: { ...current.poster_badges, ...patch } };
    prefsRef.current = next;
    savePrefs(next).catch((err: unknown) => {
      setError(err instanceof Error ? err.message : t("library.customize.saveFailed"));
    });
  };

  return (
    <section className="mt-8" aria-labelledby="poster-badges-title" data-testid="poster-badge-settings">
      <h3
        id="poster-badges-title"
        className="text-on-image text-body-lg font-semibold tracking-[-0.01em] text-[var(--text)]"
      >
        {t("library.posterBadges.title")}
      </h3>
      <p className="text-on-image mt-1 text-sub text-[var(--text-muted)]">
        {t("library.posterBadges.hint")}
      </p>
      {error && (
        <p className="mt-3 text-sub text-[var(--danger)]" role="alert">
          {error}
        </p>
      )}
      <div className="mt-3 divide-y divide-white/[0.07] rounded-2xl border border-white/[0.09] bg-white/[0.03]">
        {POSTER_BADGE_TOGGLES.map((key) => (
          <SheetToggleRow
            key={key}
            label={t(TOGGLE_LABELS[key])}
            checked={badges[key]}
            onChange={(value) => update({ [key]: value })}
          />
        ))}
      </div>
      <div className="mt-3 divide-y divide-white/[0.07] rounded-2xl border border-white/[0.09] bg-white/[0.03]">
        <div
          role="radiogroup"
          aria-labelledby="poster-badges-mode"
          className="flex min-h-11 flex-wrap items-center gap-3 px-4 py-2.5 text-ui"
        >
          <span id="poster-badges-mode" className="min-w-0 flex-1 text-white/90">
            {t("library.posterBadges.displayMode")}
          </span>
          <div className="flex rounded-full border border-white/15 p-0.5">
            {([false, true] as const).map((hoverOnly) => (
              <button
                key={String(hoverOnly)}
                type="button"
                role="radio"
                aria-checked={badges.hover_only === hoverOnly}
                onClick={() => update({ hover_only: hoverOnly })}
                className={`rounded-full px-3 py-1 text-sub transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)] ${
                  badges.hover_only === hoverOnly
                    ? "bg-white/[0.16] font-semibold text-[var(--text)]"
                    : "text-[var(--text-muted)] hover:text-[var(--text)]"
                }`}
              >
                {t(hoverOnly ? "library.posterBadges.modeHover" : "library.posterBadges.modeAlways")}
              </button>
            ))}
          </div>
        </div>
        <label className="flex min-h-11 flex-wrap items-center gap-3 px-4 py-2.5 text-ui">
          <span className="min-w-0 flex-1">
            <span className="block leading-6 text-white/90">{t("library.posterBadges.minRating")}</span>
            <span className="block text-caption leading-5 text-[var(--text-muted)]">
              {t("library.posterBadges.minRatingHint")}
            </span>
          </span>
          <select
            value={String(badges.min_rating)}
            disabled={!badges.rating}
            onChange={(e) => update({ min_rating: Number(e.target.value) })}
            className="h-8 rounded-lg border border-white/15 bg-black/30 px-2 text-sub text-[var(--text)] disabled:opacity-45"
          >
            {/* 存过的值不在档位里（别的客户端写的）也照实显示，不悄悄改掉 */}
            {[...new Set([...MIN_RATING_STEPS, badges.min_rating])]
              .sort((a, b) => a - b)
              .map((step) => (
                <option key={step} value={String(step)}>
                  {step === 0 ? t("library.posterBadges.minRatingAny") : step.toFixed(1)}
                </option>
              ))}
          </select>
        </label>
      </div>
    </section>
  );
}
