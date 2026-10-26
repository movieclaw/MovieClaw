"use client";

import { formatDate } from "@/lib/i18n/format";

import { useLocale, useTranslations } from "next-intl";
import { appTranslator } from "@/lib/i18n/translate";
import type { AppLocale } from "@/lib/i18n/negotiate";
import { useMessageState } from "@/lib/i18n/use-message-state";

import { useEffect, useState } from "react";
import { changeSmartWait, getSmartMemory, updateSmartMemory, type SubscriptionDetail, type WantedItem } from "@/lib/api/subscriptions";
import { usePermissions } from "@/lib/permissions";
import { smartWantedPresentation } from "@/lib/subscription-ui";

const RAW_REQUESTED = "movieclaw:smart-raw-requested";
const AWAITING = ["awaiting_subtitles", "deadline_awaiting_subtitles"];

function localTime(value: string, locale: AppLocale) {
  return formatDate(new Date(/Z$|[+-]\d{2}:\d{2}$/.test(value) ? value : `${value}Z`), { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }, locale);
}

function seriesLabel(key: string, locale: AppLocale) {
  const t = appTranslator(locale);
  const [group, resolution, source] = key.split("|");
  const sources: Record<string, string> = { "1": t("subscription.smartStatus.sourceTv"), "2": t("subscription.smartStatus.sourceEncode"), "3": "WEB-DL", "4": t("subscription.smartStatus.sourceBluray"), "5": "Remux", "6": t("subscription.smartStatus.sourceDisc") };
  return [group, resolution, sources[source] ?? t("subscription.smartStatus.sourceUnknown")].join(" · ");
}

export interface SmartSelectionContext {
  detail: SubscriptionDetail;
  canManage: boolean;
  onChanged: () => void;
}

/** 常规状态由原有分集列表表达，这里只报告智能执行的全局异常，以及「这次先下原版」后的追问。 */
export function SmartSubscriptionStatus({ detail }: { detail: SubscriptionDetail }) {
  const t = useTranslations();
  return <>
    <UnderstoodFollowUp detail={detail} />
    {detail.selection_mode === "smart" && detail.smart_status && detail.smart_status !== "active" && <p role="status" className="rounded-xl border border-[var(--warn)]/25 p-4 text-sub">{detail.smart_status === "invalid_policy" ? t("subscription.smartStatus.invalidPolicy") : detail.smart_status === "shadow" ? t("subscription.smartStatus.shadow") : t("subscription.smartStatus.disabled")}</p>}
  </>;
}

/** 选了先下原版，就顺便问一句是不是看得懂这种语言：第一次答错的人在这里改过来。 */
function UnderstoodFollowUp({ detail }: { detail: SubscriptionDetail }) {
  const t = useTranslations();
  const { isAdmin } = usePermissions();
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useMessageState();
  useEffect(() => {
    const listener = (event: Event) => { if ((event as CustomEvent<number>).detail === detail.id) setAsking(true); };
    window.addEventListener(RAW_REQUESTED, listener);
    return () => window.removeEventListener(RAW_REQUESTED, listener);
  }, [detail.id]);
  const subtitle = detail.smart_subtitle;
  if (!asking || !isAdmin || !subtitle || subtitle.understood) return null;
  const understood = async () => {
    setBusy(true);
    setError(null);
    try {
      const memory = await getSmartMemory();
      await updateSmartMemory({ revision: memory.revision, language: subtitle.language, understood: true });
      setAsking(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : { key: "subscription.smartStatus.saveFailed" });
    } finally { setBusy(false); }
  };
  return <section role="group" aria-label={t("subscription.smartStatus.understoodGroup")} className="rounded-xl border border-[var(--line-strong)] p-4 text-sub">
    <p className="font-medium text-[var(--text)]">{t("subscription.smartStatus.understoodQuestion", { language: subtitle.language_label })}</p>
    <p className="mt-1 text-[var(--text-muted)]">{t("subscription.smartStatus.understoodHint", { language: subtitle.language_label })}</p>
    {error && <p role="alert" className="mt-2 text-red-400">{error}</p>}
    <div className="mt-3 flex justify-end gap-2">
      <button type="button" disabled={busy} onClick={() => setAsking(false)} className="btn-glass px-4 py-2 text-sub">{t("subscription.smartStatus.onlyOnce")}</button>
      <button type="button" disabled={busy} onClick={() => void understood()} className="btn-accent rounded-full px-4 py-2 text-sub font-semibold">{t("subscription.smartStatus.understood")}</button>
    </div>
  </section>;
}

/** 放在原有搜索节点内；未播出、无候选、下载和洗版沿用原有里程碑。 */
export function SmartWantedSelection({ row, detail, canManage, onChanged }: SmartSelectionContext & { row: WantedItem }) {
  const locale = useLocale();
  const t = useTranslations();
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useMessageState();
  const state = row.selection_state;
  if (!state || !smartWantedPresentation(row, locale)) return null;
  const change = async (id: number, version: number, action: { extend_seconds?: number; candidate_key?: string }) => {
    setBusy(id);
    setError(null);
    try {
      await changeSmartWait(detail.id, id, version, action);
      if (action.candidate_key && AWAITING.includes(state.reason)) {
        window.dispatchEvent(new CustomEvent(RAW_REQUESTED, { detail: detail.id }));
      }
      onChanged();
    }
    catch (e) { setError(e instanceof Error ? e.message : { key: "subscription.smartStatus.actionFailed" }); onChanged(); }
    finally { setBusy(null); }
  };
  if (state.reason === "identity_unconfirmed") return <div role="group" className="basis-full text-sub text-[var(--text-muted)]" aria-label={t("subscription.smartStatus.identityGroup")}>
    <p>{t("subscription.smartStatus.noAction")}</p>
    {state.identity_explanation && <details className="mt-2">
      <summary className="cursor-pointer">{t("subscription.smartStatus.details")}</summary>
      <p className="mt-2 whitespace-pre-line break-words">{state.identity_explanation}</p>
    </details>}
  </div>;
  const actionable = canManage && row.status === "wanted" && detail.status === "active" && detail.smart_status === "active";
  if (AWAITING.includes(state.reason)) return <div role="group" className="basis-full space-y-1 text-sub" aria-label={t("subscription.smartStatus.awaitingSubtitles")}>
    {error && <p role="alert" className="text-red-400">{error}</p>}
    {state.wait_explanation && <p className="text-[var(--text-muted)]">{state.wait_explanation}</p>}
    {detail.smart_subtitle && <p className="mt-1 text-[var(--text-muted)]">{detail.smart_subtitle.line}</p>}
    {state.reason === "awaiting_subtitles" && <p className="mt-1 font-medium">{t("subscription.smartStatus.deadline", { date: localTime(state.deadline, locale) })}</p>}
    {state.candidate_title && <p className="mt-1 break-words text-[var(--text-muted)]">{t("subscription.smartStatus.original", { title: state.candidate_title })}</p>}
    {actionable && state.candidate_key && <div className="mt-3 flex flex-wrap gap-2">
      <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { candidate_key: state.candidate_key! })} className="btn-glass px-3 py-2 text-sub">{busy === row.id ? t("subscription.smartStatus.processing") : t("subscription.smartStatus.downloadOriginal")}</button>
    </div>}
  </div>;
  return <div role="group" className="basis-full space-y-1 text-sub" aria-label={t("subscription.smartStatus.reasonGroup")}>
    {error && <p role="alert" className="text-red-400">{error}</p>}
    {state.following && <p className="text-[var(--text-muted)]">{t("subscription.smartStatus.following", { series: seriesLabel(state.following, locale) })}</p>}
    {state.wait_explanation && <p className="mt-1 text-[var(--text-muted)]">{state.wait_explanation}</p>}
    <p className="mt-1 text-[var(--text-muted)]">{t(state.anchor_source === "published_at" ? "subscription.smartStatus.publishedAnchor" : "subscription.smartStatus.seenAnchor", { date: localTime(state.anchor, locale) })}</p>
    {state.choice_explanation && <p className="mt-2 text-[var(--text-muted)]">{state.choice_explanation}</p>}
    <p className="mt-1 text-[var(--text-muted)]">{state.prediction ? t("subscription.smartStatus.prediction", { count: state.prediction.episodes.length, start: localTime(state.prediction.start, locale), end: localTime(state.prediction.end, locale) }) : t("subscription.smartStatus.noPrediction")}</p>
    <p className="mt-1 font-medium">{t("subscription.smartStatus.deadline", { date: localTime(state.deadline, locale) })}</p>
    {state.candidate_title && <p className="mt-1 break-words text-[var(--text-muted)]">{t("subscription.smartStatus.candidate", { title: state.candidate_title })}</p>}
    <p className="mt-1 text-[var(--text-muted)]">{t("subscription.smartStatus.observationEnd", { date: localTime(state.observation_end, locale) })}</p>
    {actionable && <div className="mt-3 flex flex-wrap gap-2">
      {state.candidate_key && <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { candidate_key: state.candidate_key! })} className="btn-accent rounded-full px-3 py-2 text-sub">{busy === row.id ? t("subscription.smartStatus.processing") : t("subscription.smartStatus.downloadCandidate")}</button>}
      <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { extend_seconds: detail.media.kind === "movie" ? 86400 : 7200 })} className="btn-glass px-3 py-2 text-sub">{detail.media.kind === "movie" ? t("subscription.smartStatus.extendDay") : t("subscription.smartStatus.extendHours")}</button>
    </div>}
  </div>;
}
