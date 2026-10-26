import { request } from "@/lib/http";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse） */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

async function unwrap<T>(promise: Promise<ApiEnvelope<T>>): Promise<T> {
  return (await promise).data;
}

// ---------------------------------------------------------------------------
// 使用提示：每个人的提示状态（见 movieclaw_api.api.routes.tips、docs/design/tips.md）
// 提示本身写在前端（lib/tips），服务端只存事件计数与展示/作废记录。
// ---------------------------------------------------------------------------

/** 一种行为事件的累计情况 */
export interface TipEventState {
  event_id: string;
  count: number;
  first_at: string;
  last_at: string;
}

/** 一条提示的展示与作废情况 */
export interface TipRecordState {
  tip_id: string;
  display_count: number;
  first_displayed_at: string | null;
  last_displayed_at: string | null;
  invalidated_at: string | null;
  /** action_performed / closed / 其他客户端自定义原因 */
  invalidated_reason: string | null;
}

export interface TipStateResponse {
  events: TipEventState[];
  tips: TipRecordState[];
}

export async function fetchTipState(): Promise<TipStateResponse> {
  return unwrap(request<ApiEnvelope<TipStateResponse>>("/tips/state"));
}

export async function donateTipEvent(eventId: string): Promise<TipEventState> {
  return unwrap(
    request<ApiEnvelope<TipEventState>>(`/tips/events/${encodeURIComponent(eventId)}`, {
      method: "POST",
    }),
  );
}

export async function recordTipDisplay(tipId: string): Promise<TipRecordState> {
  return unwrap(
    request<ApiEnvelope<TipRecordState>>(`/tips/${encodeURIComponent(tipId)}/displays`, {
      method: "POST",
    }),
  );
}

export async function invalidateTip(tipId: string, reason: string): Promise<TipRecordState> {
  return unwrap(
    request<ApiEnvelope<TipRecordState>>(`/tips/${encodeURIComponent(tipId)}/invalidate`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    }),
  );
}

export async function resetTipState(): Promise<void> {
  await request<ApiEnvelope<null>>("/tips/state", { method: "DELETE" });
}
