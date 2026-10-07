"use client";

import { useState } from "react";
import { changeSmartWait, type SubscriptionDetail, type WantedItem } from "@/lib/api/subscriptions";
import { smartWantedPresentation } from "@/lib/subscription-ui";

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

/** 常规状态由原有分集列表表达，这里只报告智能执行的全局异常。 */
export function SmartSubscriptionStatus({ detail }: { detail: SubscriptionDetail }) {
  if (detail.selection_mode !== "smart" || !detail.smart_status || detail.smart_status === "active") return null;
  return <p role="status" className="rounded-xl border border-[var(--warn)]/25 p-4 text-sub">{detail.smart_status === "invalid_policy" ? "智能设置无法读取，自动选择已暂停。" : detail.smart_status === "shadow" ? "当前仅记录选择结果，尚未开启自动下载。" : "智能自动选择已关闭。已有下载和入库继续完成。"}</p>;
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
    try { await changeSmartWait(detail.id, id, version, action); onChanged(); }
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
    {canManage && row.status === "wanted" && detail.status === "active" && detail.smart_status === "active" && <div className="mt-3 flex flex-wrap gap-2">
      {state.candidate_key && <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { candidate_key: state.candidate_key! })} className="btn-accent rounded-full px-3 py-2 text-sub">{busy === row.id ? "正在处理…" : "立即下载当前候选"}</button>}
      <button type="button" disabled={busy !== null} onClick={() => void change(row.id, row.selection_version ?? 0, { extend_seconds: detail.media.kind === "movie" ? 86400 : 7200 })} className="btn-glass px-3 py-2 text-sub">{detail.media.kind === "movie" ? "延长 1 天" : "延长 2 小时"}</button>
    </div>}
  </div>;
}
