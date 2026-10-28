"use client";

/**
 * 订阅窗口：一季上千集时先订阅一部分（docs/design/subscription-episode-cap.md §3）。
 *
 * - SeasonCapLine：订阅弹层 / 调整订阅里，可截断的一季多出的一行。完结季是
 *   「先订阅前 20 集」或「从第 120 集起」（老剧中途上车，issue #950），在播季是
 *   「先订阅最新 20 集」（之后播出的照常进来）。订阅弹层只对超长季出现，调整订阅
 *   对每一季都给（lib/subscription-episode-cap.ts），一步能改回「全部」。
 * - EpisodeWindowBanner：订阅详情页，被截断的季的继续入口——「前 N 集」继续订阅
 *   往后加，「最新 N 集」「从第 N 集起」往前再订往回补。
 *
 * 判定全在服务端（episode_windows / episode_seasons），这里只渲染与提交。
 */

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { useToast } from "@/components/feedback";
import {
  updateSubscription,
  type EpisodeWindow,
  type SeasonOverview,
  type SubscriptionDetail,
} from "@/lib/api/subscriptions";
import {
  EPISODE_CAP_BATCH,
  currentWindows,
  partWindow,
  seasonTotal,
  windowKind,
  windowKindOf,
  windowsAfter,
  type CapWindow,
} from "@/lib/subscription-episode-cap";

const LINK_BUTTON =
  "shrink-0 text-[var(--accent)] transition hover:opacity-80 disabled:opacity-40";

// 选中态的底色取 CSS 变量，不加 transition：Chromium 会把过渡卡在旧值上不更新
const MODE_BUTTON =
  "h-7 rounded-full px-3 text-caption aria-pressed:bg-[var(--accent)] aria-pressed:font-semibold aria-pressed:text-black";

/**
 * 一季的「先订阅一部分」一行。win 为 null 表示订阅整季；改动经 onChange 交还给
 * 调用方保存在草稿里（订阅弹层随创建提交，调整弹层随保存提交）。
 * 文案按窗口的读法（windowKind）：前 N 集 / 最新 N 集（在播季）/ 从第 N 集起
 * （完结季）。完结季可以在「前 N 集」和「从第 N 集起」之间切换。
 */
export function SeasonCapLine({
  season,
  win,
  airing,
  onChange,
  showName,
  className = "",
}: {
  season: SeasonOverview;
  win: CapWindow | null;
  /** 这一行点「先订阅一部分」时按哪一类的默认预填（完结季前一批 / 在播季最新一批） */
  airing: boolean;
  onChange: (next: CapWindow | null) => void;
  /** 勾了多季时行首带上季名，免得分不清是哪一季 */
  showName: boolean;
  className?: string;
}) {
  const t = useTranslations();
  const seasonName = (n: number) =>
    n === 0 ? t("media.season.specials") : t("media.season.title", { number: n });
  const prefix = showName ? `${seasonName(season.season_number)} · ` : "";
  const total = seasonTotal(season);
  // 「前 N 集」的输入是订阅到第几集，锚定本季总集数；「最新 N 集」的输入是订阅最新
  // 几集，锚定**已播**集数（TMDB 宣称的集数可能还没播到），提交时换算回窗口的
  // start，新集播出后窗口不跟着滑；「从第 N 集起」的输入就是 start
  const kind = win === null ? null : windowKind(win, airing);
  const aired = season.aired_count;
  const count =
    win === null ? null : kind === "latest" ? aired - win.start + 1 : kind === "from" ? win.start : win.end;
  const [text, setText] = useState(count === null ? "" : String(count));
  useEffect(() => {
    setText(count === null ? "" : String(count));
  }, [count]);

  // 输入框里的字在失焦 / 回车时才生效：边打边改会让 "2" → "20" 的中间态也被当成窗口
  const commit = () => {
    const value = Number(text);
    if (!Number.isInteger(value) || value < 1 || (kind === "from" && value > total)) {
      setText(count === null ? "" : String(count));
      return;
    }
    if (kind === "latest") {
      onChange(value >= aired ? null : { start: Math.max(1, aired - value + 1), end: null });
    } else if (kind === "from") {
      onChange(value <= 1 ? null : { start: value, end: null });
    } else {
      onChange(value >= total ? null : { start: 1, end: value });
    }
  };

  // 完结季在两种读法间切换时沿用输入框里的数：前 20 集 ⇄ 从第 20 集起
  const switchTo = (next: "first" | "from") => {
    if (count === null || next === kind) return;
    onChange(
      next === "from"
        ? { start: Math.min(Math.max(count, 2), total), end: null }
        : { start: 1, end: Math.min(count, total - 1) },
    );
  };
  const labels = {
    first: [t("subscription.cap.firstLabel", { prefix }), t("subscription.cap.suffixTotal", { count: total })],
    latest: [t("subscription.cap.latestLabel", { prefix }), t("subscription.cap.suffixAired", { count: aired })],
    from: [t("subscription.cap.fromLabel", { prefix }), t("subscription.cap.suffixFrom", { count: total })],
  };

  return (
    <div
      className={`flex flex-wrap items-center gap-x-2 gap-y-1.5 text-sub text-[var(--text-muted)] ${className}`}
    >
      {win === null ? (
        <>
          <span>{t("subscription.cap.wholeSeason", { prefix, count: total })}</span>
          <button
            type="button"
            className={LINK_BUTTON}
            onClick={() => onChange(partWindow(season, airing))}
          >
            {t("subscription.cap.subscribePart")}
          </button>
        </>
      ) : (
        <>
          {!airing && (
            <div
              role="group"
              aria-label={t("subscription.cap.modeAria", { season: season.season_number })}
              className="flex shrink-0 rounded-full border border-white/[0.08] bg-white/[0.05] p-0.5"
            >
              <button
                type="button"
                aria-pressed={kind === "first"}
                className={MODE_BUTTON}
                onClick={() => switchTo("first")}
              >
                {t("subscription.cap.modeFirst")}
              </button>
              <button
                type="button"
                aria-pressed={kind === "from"}
                className={MODE_BUTTON}
                onClick={() => switchTo("from")}
              >
                {t("subscription.cap.modeFrom")}
              </button>
            </div>
          )}
          <span>{labels[kind ?? "first"][0]}</span>
          <input
            type="number"
            inputMode="numeric"
            min={kind === "from" ? 2 : 1}
            max={kind === "from" ? total : kind === "latest" ? aired - 1 : total - 1}
            aria-label={t("subscription.cap.inputAria", { season: season.season_number })}
            value={text}
            onChange={(event) => setText(event.target.value)}
            onBlur={commit}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                commit();
              }
            }}
            className="w-16 shrink-0 rounded-lg border border-white/[0.1] bg-white/[0.05] px-2 py-1 text-right text-ui tabular-nums text-white/90 outline-none focus:border-white/30"
          />
          <span>{labels[kind ?? "first"][1]}</span>
          <button type="button" className={LINK_BUTTON} onClick={() => onChange(null)}>
            {t("subscription.cap.all")}
          </button>
          {kind === "from" && win !== null && (
            <p className="basis-full text-caption leading-relaxed text-[var(--text-faint)]">
              {t("subscription.cap.fromSummary", { start: win.start, total, before: win.start - 1 })}
            </p>
          )}
        </>
      )}
    </div>
  );
}

/** 「已订阅最新 N 集」的 N：锚定**已播**集数（宣称集数可能还没播到），拿不到再退回窗口的总集数。 */
function airedCount(detail: SubscriptionDetail, win: EpisodeWindow): number {
  return (
    detail.season_collection.find((s) => s.season_number === win.season_number)?.aired_count ??
    win.total
  );
}

/**
 * 订阅详情页：被窗口截断的季。完结季告诉用户只订阅了前面一部分，主按钮再订阅
 * 一批；在播季告诉用户订阅了最新的几集、新集会自动进来，想补老集用「往前再订」。
 * 剩下不足一批时一次订完；「订阅全部」清掉窗口。
 * 只关注的成员只看提示，不给操作（与集数提示同一规矩）。
 */
export function EpisodeWindowBanner({
  detail,
  canTune,
  onChanged,
}: {
  detail: SubscriptionDetail;
  canTune: boolean;
  onChanged: () => void;
}) {
  const t = useTranslations();
  const seasonName = (n: number) =>
    n === 0 ? t("media.season.specials") : t("media.season.title", { number: n });
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const windows = detail.episode_windows ?? [];
  if (windows.length === 0) return null;

  const setWindow = async (win: EpisodeWindow, next: CapWindow | null, done: string) => {
    setBusy(true);
    try {
      await updateSubscription(detail.id, {
        episode_caps: windowsAfter(
          currentWindows(detail.episode_seasons),
          next,
          win.season_number,
          win.total,
        ),
      });
      toast.success(done);
      onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t("subscription.cap.saveFailed"));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-2">
      {windows.map((win) => {
        const season = seasonName(win.season_number);
        // 不设上界的窗口按这一季在不在播（服务端标的 airing）分读法：在播「最新 N 集」，
        // 完结「从第 N 集起」；两者的按钮都是往前再订
        const kind = windowKindOf(win);
        const openEnded = win.end === null;
        const count = openEnded ? Math.max(1, airedCount(detail, win) - win.start + 1) : win.end ?? 0;
        // 主按钮这一步：「前 N 集」往后加一批，不设上界的往前挪一批；剩下不足一批就一次
        // 订完整季（窗口清掉）——两侧同构，只是方向相反
        const next: CapWindow | null = openEnded
          ? win.start - EPISODE_CAP_BATCH > 1
            ? { start: win.start - EPISODE_CAP_BATCH, end: null }
            : null
          : (win.end ?? 0) + EPISODE_CAP_BATCH < win.total
            ? { start: win.start, end: (win.end ?? 0) + EPISODE_CAP_BATCH }
            : null;
        const remaining = openEnded ? win.start - 1 : win.total - (win.end ?? 0);
        const stepLabel = openEnded
          ? remaining > EPISODE_CAP_BATCH
            ? t("subscription.cap.stepEarlier", { count: EPISODE_CAP_BATCH })
            : t("subscription.cap.stepEarlierRest", { count: remaining })
          : remaining > EPISODE_CAP_BATCH
            ? t("subscription.cap.stepContinue", { count: EPISODE_CAP_BATCH })
            : t("subscription.cap.stepRest", { count: remaining });
        const doneAll = t("subscription.cap.doneAll", { season, count: win.total });
        const stepDone = next
          ? openEnded
            ? t("subscription.cap.doneEarlier", { episode: next.start })
            : t("subscription.cap.doneContinue", { episode: next.end ?? 0 })
          : doneAll;
        return (
          <section
            key={win.season_number}
            className="flex flex-wrap items-center gap-x-4 gap-y-3 rounded-xl border border-white/[0.08] bg-white/[0.04] px-4 py-3"
          >
            <div className="min-w-0 flex-1 basis-64">
              <p className="text-ui font-semibold text-white/90">
                {kind === "latest"
                  ? t("subscription.cap.bannerLatest", { count })
                  : kind === "from"
                    ? t("subscription.cap.bannerFrom", { start: win.start })
                    : t("subscription.cap.bannerUntil", { episode: win.end ?? 0 })}
              </p>
              <p className="mt-0.5 text-sub leading-6 text-[var(--text-muted)]">
                {kind === "latest"
                  ? t("subscription.cap.bannerLatestBody", { season, start: win.start })
                  : kind === "from"
                    ? t("subscription.cap.bannerFromBody", {
                        season,
                        total: win.total,
                        start: win.start,
                        before: win.start - 1,
                      })
                    : t("subscription.cap.bannerUntilBody", { season, total: win.total, count: win.end ?? 0 })}
              </p>
            </div>
            {canTune && (
              <div className="flex shrink-0 gap-2">
                {next !== null && (
                  <button
                    type="button"
                    disabled={busy}
                    onClick={() => void setWindow(win, null, doneAll)}
                    className="btn-glass h-9 px-4 text-sub font-medium disabled:opacity-40"
                  >
                    {t("subscription.cap.subscribeAll")}
                  </button>
                )}
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void setWindow(win, next, stepDone)}
                  className="btn-accent h-9 rounded-full px-4 text-sub font-semibold disabled:opacity-40"
                >
                  {stepLabel}
                </button>
              </div>
            )}
          </section>
        );
      })}
    </div>
  );
}
