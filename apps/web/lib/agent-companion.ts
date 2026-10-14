import type { AgentTurn } from "./agent-conversations";

export type CompanionState = "idle" | "attentive" | "departing" | "working" | "complete" | "failed";

// 与 iPhone 共用 4 × 6 图集的行顺序。
export const COMPANION_POSES: CompanionState[] = ["idle", "attentive", "departing", "working", "complete", "failed"];

export const COMPANION_LABELS: Record<CompanionState, string> = {
  idle: "小幕，安静陪伴",
  attentive: "小幕，正在听你说",
  departing: "小幕，出发了",
  working: "小幕，正在处理任务",
  complete: "小幕，任务已完成",
  failed: "小幕，任务遇到了问题",
};

export function resolveCompanionState(
  turn: Pick<AgentTurn, "status" | "stopped" | "interrupted"> | undefined,
  busy: boolean,
  unavailable = false,
): CompanionState {
  if (unavailable) return "idle";
  if (busy) return "working";
  if (!turn || turn.stopped) return "idle";
  if (turn.interrupted || turn.status === "error") return "failed";
  return turn.status === "done" ? "complete" : "idle";
}
