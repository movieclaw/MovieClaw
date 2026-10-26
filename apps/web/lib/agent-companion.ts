import type { AppMessageKey } from "./i18n/translate";
import type { AgentTurn } from "./agent-conversations";

export type CompanionState = "idle" | "attentive" | "departing" | "working" | "complete" | "failed";

// 与 iPhone 共用 4 × 6 图集的行顺序。
export const COMPANION_POSES: CompanionState[] = ["idle", "attentive", "departing", "working", "complete", "failed"];

export const COMPANION_LABELS: Record<CompanionState, AppMessageKey> = {
  idle: "agent.companion.idle",
  attentive: "agent.companion.attentive",
  departing: "agent.companion.departing",
  working: "agent.companion.working",
  complete: "agent.companion.complete",
  failed: "agent.companion.failed",
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
