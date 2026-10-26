"use client";

/**
 * 集数下限（issue #640）：TMDB 少录集数时让订阅继续追。
 *
 * - EpisodeFloorDialog：「更多 → 调整集数」入口。每季一行，填「这一季共几集」，
 *   超出 TMDB 的部分先占位追踪，TMDB 补全后自动对上；填回 TMDB 的集数或留空
 *   即恢复以 TMDB 为准。
 * - EpisodeHintBanner：站点出现了超出 TMDB 的集、或豆瓣集数更多时，详情页
 *   顶部提示「可能还没收齐」，一键按建议集数继续追，或忽略。
 *
 * 判定全在服务端（episode_hints / episode_seasons），这里只渲染与提交。
 */

import { useLocale, useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useState } from "react";

import { useToast } from "@/components/feedback";
import { Modal } from "@/components/modal";
import { SheetNotice, SheetRow, SheetScaffold, SheetSection, useSheetForm } from "@/components/sheet-scaffold";
import {
  dismissSubscriptionEpisodeHint,
  updateSubscription,
  type EpisodeHint,
  type SubscriptionDetail,
} from "@/lib/api/subscriptions";

/** 服务端上限，同 episode_floor.FLOOR_MAX */
const FLOOR_MAX = 2000;

/** 当前已设的下限 {季号: 集数}（提交时整体替换，未改的季原样带回）。 */
function currentFloors(detail: SubscriptionDetail): Record<number, number> {
  const floors: Record<number, number> = {};
  for (const s of detail.episode_seasons ?? []) {
    if (s.floor) floors[s.season_number] = s.floor;
  }
  return floors;
}

export function EpisodeFloorDialog({
  detail,
  onClose,
  onSaved,
}: {
  detail: SubscriptionDetail;
  onClose: () => void;
  onSaved: () => void;
}) {
  const t = useTranslations();
  const toast = useToast();
  const sheetForm = useSheetForm();
  const seasons = detail.episode_seasons ?? [];
  // 输入框的文本态：显示的是「这一季共几集」，没设下限时就是 TMDB 的集数
  const [values, setValues] = useState<Record<number, string>>(() =>
    Object.fromEntries(seasons.map((s) => [s.season_number, String(s.floor ?? s.tmdb_count)])),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useMessageState();

  const parsed = seasons.map((s) => {
    const text = (values[s.season_number] ?? "").trim();
    const n = text === "" ? s.tmdb_count : Number(text);
    return { season: s, count: n, valid: Number.isInteger(n) && n >= 0 && n <= FLOOR_MAX };
  });
  const invalid = parsed.some((p) => !p.valid);
  // 不超过 TMDB 集数 = 不设下限（服务端同口径丢弃）
  const nextFloors: Record<number, number> = {};
  for (const p of parsed) {
    if (p.valid && p.count > p.season.tmdb_count) nextFloors[p.season.season_number] = p.count;
  }
  const dirty = JSON.stringify(nextFloors) !== JSON.stringify(currentFloors(detail));

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      await updateSubscription(detail.id, { episode_floors: nextFloors });
      toast.success(Object.keys(nextFloors).length ? t("subscription.episodeFloor.saved") : t("subscription.episodeFloor.reset"));
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.episodeFloor.saveFailed" });
      setBusy(false);
    }
  };

  const intro = t("subscription.episodeFloor.intro");
  const input = (seasonNumber: number, tmdbCount: number) => (
    <input
      type="number"
      inputMode="numeric"
      min={0}
      max={FLOOR_MAX}
      aria-label={t("subscription.episodeFloor.inputLabel", { season: seasonNumber })}
      value={values[seasonNumber] ?? ""}
      placeholder={String(tmdbCount)}
      onChange={(e) => setValues((prev) => ({ ...prev, [seasonNumber]: e.target.value }))}
      className="w-20 shrink-0 rounded-lg border border-white/[0.1] bg-white/[0.05] px-2.5 py-1.5 text-right text-ui tabular-nums text-white/90 outline-none focus:border-white/30"
    />
  );
  const seasonDetail = (tmdbCount: number, floor: number | null) =>
    floor ? t("subscription.episodeFloor.currentCounts", { tmdb: tmdbCount, count: floor }) : t("subscription.episodeFloor.tmdbCount", { count: tmdbCount });

  if (sheetForm) {
    return (
      <SheetScaffold
        onClose={onClose}
        title={t("subscription.episodeFloor.title")}
        subtitle={<>{t("subscription.episodeFloor.subtitle", { title: detail.media.title, intro })}</>}
        confirm={{ label: t("common.save"), enabled: dirty && !invalid && !busy, busy, onConfirm: () => void save() }}
      >
        {error && <SheetNotice tone="error">{error}</SheetNotice>}
        <SheetSection footer={t("subscription.episodeFloor.resetHint")}>
          {seasons.map((s) => (
            <SheetRow
              key={s.season_number}
              label={t("media.season.title", { number: s.season_number })}
              trailing={input(s.season_number, s.tmdb_count)}
            >
              <span className="mt-0.5 block text-caption text-[var(--text-muted)]">
                {seasonDetail(s.tmdb_count, s.floor)}
              </span>
            </SheetRow>
          ))}
        </SheetSection>
      </SheetScaffold>
    );
  }

  return (
    <Modal open onClose={onClose} label={t("subscription.episodeFloor.title")} width="md">
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
        <h2 className="text-title font-bold text-white">{t("subscription.episodeFloor.title")}</h2>
        <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
          {t("subscription.episodeFloor.subtitle", { title: detail.media.title, intro })}
        </p>
      </div>
      <div className="space-y-1.5 p-6 max-md:p-5">
        {error && (
          <p className="mb-3 rounded-lg border border-red-400/25 bg-red-500/10 px-3.5 py-2.5 text-sub leading-6 text-red-200">
            {error}
          </p>
        )}
        {seasons.map((s) => (
          <label
            key={s.season_number}
            className="flex items-center gap-3 rounded-xl bg-white/[0.03] px-4 py-3"
          >
            <span className="min-w-0 flex-1">
              <span className="block text-ui font-medium text-white/90">{t("media.season.title", { number: s.season_number })}</span>
              <span className="mt-0.5 block text-caption text-[var(--text-muted)]">
                {seasonDetail(s.tmdb_count, s.floor)}
              </span>
            </span>
            {input(s.season_number, s.tmdb_count)}
            <span className="text-sub text-[var(--text-muted)]">{t("subscription.episodeFloor.episodeUnit")}</span>
          </label>
        ))}
        <p className="pt-1 text-caption text-[var(--text-faint)]">{t("subscription.episodeFloor.resetHint")}</p>
      </div>
      <div className="flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4 max-md:px-5">
        <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
          {t("common.cancel")}
        </button>
        <button
          type="button"
          disabled={!dirty || invalid || busy}
          onClick={() => void save()}
          className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
        >
          {busy ? t("subscription.episodeFloor.saving") : t("common.save")}
        </button>
      </div>
    </Modal>
  );
}

/** 证据来源的一句话：站点优先（更直接），豆瓣次之。 */
function hintReason(hint: EpisodeHint, locale: AppLocale): string {
  const t = appTranslator(locale);
  if (hint.site_episode && hint.site_episode >= (hint.douban_count ?? 0)) {
    return t("subscription.episodeFloor.siteEvidence", { episode: hint.site_episode, tmdb: hint.tmdb_count });
  }
  return t("subscription.episodeFloor.doubanEvidence", { count: hint.douban_count ?? 0, tmdb: hint.tmdb_count });
}

export function EpisodeHintBanner({
  detail,
  canTune,
  onChanged,
}: {
  detail: SubscriptionDetail;
  /** 只关注的成员只看提示，不给操作 */
  canTune: boolean;
  onChanged: () => void;
}) {
  const locale = useLocale();
  const t = useTranslations();
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const hints = detail.episode_hints ?? [];
  if (hints.length === 0) return null;

  const accept = async (hint: EpisodeHint) => {
    setBusy(true);
    try {
      await updateSubscription(detail.id, {
        episode_floors: { ...currentFloors(detail), [hint.season_number]: hint.suggested },
      });
      toast.success(t("subscription.episodeFloor.accepted", { count: hint.suggested, season: hint.season_number }));
      onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t("subscription.episodeFloor.saveFailed"));
    } finally {
      setBusy(false);
    }
  };

  const dismiss = async (hint: EpisodeHint) => {
    setBusy(true);
    try {
      await dismissSubscriptionEpisodeHint(detail.id, hint.season_number);
      toast.success(t("subscription.episodeFloor.dismissed"));
      onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t("subscription.episodeFloor.actionFailed"));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-2">
      {hints.map((hint) => (
        <section
          key={hint.season_number}
          className="flex flex-wrap items-center gap-x-4 gap-y-3 rounded-xl border border-amber-400/25 bg-amber-500/[0.08] px-4 py-3"
        >
          <div className="min-w-0 flex-1 basis-64">
            <p className="text-ui font-semibold text-amber-100">
              {t("subscription.episodeFloor.possiblyMissing", { season: hint.season_number })}
            </p>
            <p className="mt-0.5 text-sub leading-6 text-amber-100/75">{hintReason(hint, locale)}</p>
            {hint.site_title && hint.site_episode && hint.site_episode >= (hint.douban_count ?? 0) && (
              <p className="truncate text-caption text-amber-100/50" title={hint.site_title}>
                {hint.site_title}
              </p>
            )}
          </div>
          {canTune && (
            <div className={locale === "en" ? "flex min-w-0 flex-wrap gap-2" : "flex shrink-0 gap-2"}>
              <button
                type="button"
                disabled={busy}
                onClick={() => void dismiss(hint)}
                className="btn-glass h-9 px-4 text-sub font-medium disabled:opacity-40"
              >
                {t("subscription.episodeFloor.ignore")}
              </button>
              <button
                type="button"
                disabled={busy}
                onClick={() => void accept(hint)}
                className="btn-accent h-9 rounded-full px-4 text-sub font-semibold disabled:opacity-40"
              >
                {t("subscription.episodeFloor.continue", { count: hint.suggested })}
              </button>
            </div>
          )}
        </section>
      ))}
    </div>
  );
}
