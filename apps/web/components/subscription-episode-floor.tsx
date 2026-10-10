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
  const toast = useToast();
  const sheetForm = useSheetForm();
  const seasons = detail.episode_seasons ?? [];
  // 输入框的文本态：显示的是「这一季共几集」，没设下限时就是 TMDB 的集数
  const [values, setValues] = useState<Record<number, string>>(() =>
    Object.fromEntries(seasons.map((s) => [s.season_number, String(s.floor ?? s.tmdb_count)])),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

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
      toast.success(Object.keys(nextFloors).length ? "已按新的集数继续追踪" : "已改回以 TMDB 集数为准");
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : "保存失败，请稍后重试");
      setBusy(false);
    }
  };

  const intro = "TMDB 对部分剧集只录了一部分集数。在这里填这一季实际共几集，超出 TMDB 的集会先占位追踪，TMDB 补全后自动对上。";
  const input = (seasonNumber: number, tmdbCount: number) => (
    <input
      type="number"
      inputMode="numeric"
      min={0}
      max={FLOOR_MAX}
      aria-label={`第 ${seasonNumber} 季集数`}
      value={values[seasonNumber] ?? ""}
      placeholder={String(tmdbCount)}
      onChange={(e) => setValues((prev) => ({ ...prev, [seasonNumber]: e.target.value }))}
      className="w-20 shrink-0 rounded-lg border border-white/[0.1] bg-white/[0.05] px-2.5 py-1.5 text-right text-ui tabular-nums text-white/90 outline-none focus:border-white/30"
    />
  );
  const seasonDetail = (tmdbCount: number, floor: number | null) =>
    floor ? `TMDB 录了 ${tmdbCount} 集 · 当前按 ${floor} 集追` : `TMDB 录了 ${tmdbCount} 集`;

  if (sheetForm) {
    return (
      <SheetScaffold
        onClose={onClose}
        title="调整集数"
        subtitle={<>《{detail.media.title}》——{intro}</>}
        confirm={{ label: "保存", enabled: dirty && !invalid && !busy, busy, onConfirm: () => void save() }}
      >
        {error && <SheetNotice tone="error">{error}</SheetNotice>}
        <SheetSection footer="填回 TMDB 的集数即恢复以 TMDB 为准">
          {seasons.map((s) => (
            <SheetRow
              key={s.season_number}
              label={`第 ${s.season_number} 季`}
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
    <Modal open onClose={onClose} label="调整集数" width="md">
      <div className="border-b border-white/[0.07] px-6 pb-4 pt-6 max-md:px-5">
        <h2 className="text-title font-bold text-white">调整集数</h2>
        <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
          《{detail.media.title}》——{intro}
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
              <span className="block text-ui font-medium text-white/90">第 {s.season_number} 季</span>
              <span className="mt-0.5 block text-caption text-[var(--text-muted)]">
                {seasonDetail(s.tmdb_count, s.floor)}
              </span>
            </span>
            {input(s.season_number, s.tmdb_count)}
            <span className="text-sub text-[var(--text-muted)]">集</span>
          </label>
        ))}
        <p className="pt-1 text-caption text-[var(--text-faint)]">填回 TMDB 的集数即恢复以 TMDB 为准</p>
      </div>
      <div className="flex justify-end gap-3 border-t border-white/[0.07] px-6 py-4 max-md:px-5">
        <button type="button" onClick={onClose} className="btn-glass h-9 px-4 text-ui font-medium">
          取消
        </button>
        <button
          type="button"
          disabled={!dirty || invalid || busy}
          onClick={() => void save()}
          className="btn-accent h-9 rounded-full px-5 text-ui font-semibold disabled:opacity-40"
        >
          {busy ? "保存中…" : "保存"}
        </button>
      </div>
    </Modal>
  );
}

/** 证据来源的一句话：站点优先（更直接），豆瓣次之。 */
function hintReason(hint: EpisodeHint): string {
  const tmdb = `TMDB 只录了 ${hint.tmdb_count} 集`;
  if (hint.site_episode && hint.site_episode >= (hint.douban_count ?? 0)) {
    return `站点上已出现第 ${hint.site_episode} 集的资源，${tmdb}`;
  }
  return `豆瓣显示共 ${hint.douban_count} 集，${tmdb}`;
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
      toast.success(`已按 ${hint.suggested} 集继续追踪第 ${hint.season_number} 季`);
      onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "保存失败，请稍后重试");
    } finally {
      setBusy(false);
    }
  };

  const dismiss = async (hint: EpisodeHint) => {
    setBusy(true);
    try {
      await dismissSubscriptionEpisodeHint(detail.id, hint.season_number);
      toast.success("已忽略，继续以 TMDB 集数为准");
      onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "操作失败，请稍后重试");
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
              第 {hint.season_number} 季可能还没收齐
            </p>
            <p className="mt-0.5 text-sub leading-6 text-amber-100/75">{hintReason(hint)}</p>
            {hint.site_title && hint.site_episode && hint.site_episode >= (hint.douban_count ?? 0) && (
              <p className="truncate text-caption text-amber-100/50" title={hint.site_title}>
                {hint.site_title}
              </p>
            )}
          </div>
          {canTune && (
            <div className="flex shrink-0 gap-2">
              <button
                type="button"
                disabled={busy}
                onClick={() => void dismiss(hint)}
                className="btn-glass h-9 px-4 text-sub font-medium disabled:opacity-40"
              >
                忽略
              </button>
              <button
                type="button"
                disabled={busy}
                onClick={() => void accept(hint)}
                className="btn-accent h-9 rounded-full px-4 text-sub font-semibold disabled:opacity-40"
              >
                按 {hint.suggested} 集继续追
              </button>
            </div>
          )}
        </section>
      ))}
    </div>
  );
}
