"use client";

import { useEffect, useState } from "react";
import { changeSmartWait, getSmartMemory, updateSmartMemory, type SubscriptionDetail, type WantedItem } from "@/lib/api/subscriptions";
import { usePermissions } from "@/lib/permissions";
import { smartWantedPresentation } from "@/lib/subscription-ui";

const RAW_REQUESTED = "movieclaw:smart-raw-requested";
const AWAITING = ["awaiting_subtitles", "deadline_awaiting_subtitles"];

function localTime(value: string) {
  return new Date(/Z$|[+-]\d{2}:\d{2}$/.test(value) ? value : `${value}Z`).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

function seriesLabel(key: string) {
  const [group, resolution, source] = key.split("|");
  const sources: Record<string, string> = { "1": "电视 / DVD", "2": "压制版", "3": "WEB-DL", "4": "蓝光", "5": "Remux", "6": "原盘" };
  return [group, resolution, sources[source] ?? "未知片源"].join(" · ");
}

export interface SmartSelectionContext {
  detail: SubscriptionDetail;
  canManage: boolean;
  onChanged: () => void;
}

/** 常规状态由原有分集列表表达，这里只报告智能执行的全局异常，以及「这次先下原版」后的追问。 */
export function SmartSubscriptionStatus({ detail }: { detail: SubscriptionDetail }) {
  return <>
    <UnderstoodFollowUp detail={detail} />
    {detail.selection_mode === "smart" && detail.smart_status && detail.smart_status !== "active" && <p role="status" className="rounded-xl border border-[var(--warn)]/25 p-4 text-sub">{detail.smart_status === "invalid_policy" ? "智能设置无法读取，自动选择已暂停。" : detail.smart_status === "shadow" ? "当前仅记录选择结果，尚未开启自动下载。" : "智能自动选择已关闭。已有下载和入库继续完成。"}</p>}
  </>;
}

/** 选了先下原版，就顺便问一句是不是看得懂这种语言：第一次答错的人在这里改过来。 */
function UnderstoodFollowUp({ detail }: { detail: SubscriptionDetail }) {
  const { isAdmin } = usePermissions();
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
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
      setError(e instanceof Error ? e.message : "保存失败，请重试");
    } finally { setBusy(false); }
  };
  return <section role="group" aria-label="看得懂这种语言吗" className="rounded-xl border border-[var(--line-strong)] p-4 text-sub">
    <p className="font-medium text-[var(--text)]">已开始下载原版。你看得懂{subtitle.language_label}吗？</p>
    <p className="mt-1 text-[var(--text-muted)]">选「看得懂」，以后的{subtitle.language_label}作品都直接下原版。</p>
    {error && <p role="alert" className="mt-2 text-red-400">{error}</p>}
    <div className="mt-3 flex justify-end gap-2">
      <button type="button" disabled={busy} onClick={() => setAsking(false)} className="btn-glass px-4 py-2 text-sub">只这次</button>
      <button type="button" disabled={busy} onClick={() => void understood()} className="btn-accent rounded-full px-4 py-2 text-sub font-semibold">看得懂</button>
    </div>
  </section>;
}

/** 放在原有搜索节点内；未播出、无候选、下载和洗版沿用原有里程碑。 */
export function SmartWantedSelection({ row, detail, canManage, onChanged }: SmartSelectionContext & { row: WantedItem }) {
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const state = row.selection_state;
  if (!state || !smartWantedPresentation(row)) return null;
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
    catch (e) { setError(e instanceof Error ? e.message : "操作失败，请重试"); onChanged(); }
    finally { setBusy(null); }
  };
  if (state.reason === "identity_unconfirmed") return <div role="group" className="basis-full text-sub text-[var(--text-muted)]" aria-label="资源身份说明">
    <p>订阅正常进行，无需你处理。</p>
    {state.identity_explanation && <details className="mt-2">
      <summary className="cursor-pointer">查看详情</summary>
      <p className="mt-2 whitespace-pre-line break-words">{state.identity_explanation}</p>
    </details>}
  </div>;
  const actionable = canManage && row.status === "wanted" && detail.status === "active" && detail.smart_status === "active";
  if (AWAITING.includes(state.reason)) return <div role="group" className="basis-full space-y-1 text-sub" aria-label="等待字幕版">
    {error && <p role="alert" className="text-red-400">{error}</p>}
    {state.wait_explanation && <p className="text-[var(--text-muted)]">{state.wait_explanation}</p>}
    {detail.smart_subtitle && <p className="mt-1 text-[var(--text-muted)]">{detail.smart_subtitle.line}</p>}
    {state.reason === "awaiting_subtitles" && <p className="mt-1 font-medium">最晚等待至 {localTime(state.deadline)}</p>}
    {state.candidate_title && <p className="mt-1 break-words text-[var(--text-muted)]">原版：{state.candidate_title}</p>}
    {actionable && state.candidate_key && <div className="mt-3 flex flex-wrap gap-2">
      <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { candidate_key: state.candidate_key! })} className="btn-glass px-3 py-2 text-sub">{busy === row.id ? "正在处理…" : "这次先下原版"}</button>
    </div>}
  </div>;
  return <div role="group" className="basis-full space-y-1 text-sub" aria-label="智能选择依据">
    {error && <p role="alert" className="text-red-400">{error}</p>}
    {state.following && <p className="text-[var(--text-muted)]">跟随版本：{seriesLabel(state.following)}</p>}
    {state.wait_explanation && <p className="mt-1 text-[var(--text-muted)]">{state.wait_explanation}</p>}
    <p className="mt-1 text-[var(--text-muted)]">{state.anchor_source === "published_at" ? "本集最早匹配资源的站点发布时间" : "本系统首次发现合格资源"}：{localTime(state.anchor)}</p>
    {state.choice_explanation && <p className="mt-2 text-[var(--text-muted)]">{state.choice_explanation}</p>}
    <p className="mt-1 text-[var(--text-muted)]">{state.prediction ? `根据此前 ${state.prediction.episodes.length} 集的独立发布记录，预计 ${localTime(state.prediction.start)} 至 ${localTime(state.prediction.end)} 到达。` : "暂无足够证据支持长时间等待；仅在资源刚发布或发布时间不明时短暂观察。"}</p>
    <p className="mt-1 font-medium">最晚等待至 {localTime(state.deadline)}</p>
    {state.candidate_title && <p className="mt-1 break-words text-[var(--text-muted)]">当前候选：{state.candidate_title}</p>}
    <p className="mt-1 text-[var(--text-muted)]">观察窗口于 {localTime(state.observation_end)} 结束，可能提前选择。下载完成时间取决于资源和网络。</p>
    {actionable && <div className="mt-3 flex flex-wrap gap-2">
      {state.candidate_key && <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { candidate_key: state.candidate_key! })} className="btn-accent rounded-full px-3 py-2 text-sub">{busy === row.id ? "正在处理…" : "立即下载当前候选"}</button>}
      <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { extend_seconds: detail.media.kind === "movie" ? 86400 : 7200 })} className="btn-glass px-3 py-2 text-sub">{detail.media.kind === "movie" ? "延长 1 天" : "延长 2 小时"}</button>
    </div>}
  </div>;
}
