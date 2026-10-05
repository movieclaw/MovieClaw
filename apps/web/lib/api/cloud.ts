import { HttpError, request } from "@/lib/http";

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

/*
 * 「MovieClaw Cloud」分区的接口（docs/design/cloud-push.md §7.1），全部只给管理员。
 * 读和写都返回同一个 CloudStatusView：界面拿响应直接整页重画，不做局部合并。
 */

export type CloudState = "disconnected" | "pairing" | "connected";

/** 只在 connected 时有：unreachable = 续签失败但令牌还有效；expired = 令牌过期、官方通道停用；unsupported = 版本不受支持 */
export type CloudHealth = "ok" | "unreachable" | "expired" | "unsupported";

export type CloudPairingStatus = "pending" | "denied" | "expired" | "error";

/** 进行中的配对（RFC 8628）。device_code 只在服务端内存里，这里拿不到也不需要。 */
export interface CloudPairingView {
  /** XXXX-XXXX 形式的配对码，要和官网批准页上的核对 */
  user_code: string;
  verification_uri: string;
  /** 带配对码的批准页地址，新标签页打开即是批准页 */
  verification_uri_complete: string;
  /** verification_uri_complete 的二维码（SVG data URL），<img> 直接显示 */
  qrcode_image: string;
  expires_at: string;
  status: CloudPairingStatus;
  /** 拒绝 / 过期 / 出错时给人看的一句话 */
  message: string | null;
  instance_name: string;
}

/** 云端给这台服务器的默认限额，只用于展示（负数 = 不限）；实际额度以中继每次推送的答复为准 */
export interface CloudLimits {
  /** 每天最多推送多少条 */
  day?: number;
  /** 每台设备每天最多多少条 */
  device_day?: number;
}

export interface CloudConnectionView {
  instance_id: string;
  instance_name: string;
  /** 打了掩码的账号标识，如 y•••@gmail.com；可能为空串 */
  account_display: string | null;
  connected_at: string | null;
  last_renew_at: string | null;
  token_expires_at: string | null;
  /** 已授予这台服务器的权限，本期只有 push */
  scopes: string[];
  /** 云端当前提供的能力；不在 scopes 里的就是还没开放给这台服务器的 */
  capabilities: string[];
  limits: CloudLimits | null;
}

/** 上次被动断开（在官网解绑、账号删除）的原因；重新连接后清空 */
export interface CloudDisconnectView {
  reason: string;
  message: string | null;
  at: string | null;
}

/** 云端发来的服务通知：只在这一页显示，关掉后同一 id 不再出现 */
export interface CloudNotice {
  id: string;
  level: "info" | "warning" | string;
  message: string;
}

export interface CloudStatusView {
  state: CloudState;
  health: CloudHealth | null;
  health_message: string | null;
  cloud_url: string;
  /** 设置了 MOVIECLAW_CLOUD_URL（开发者指向自己的云端） */
  custom_cloud_url: boolean;
  /** 连接时默认的服务器名称 */
  server_name: string;
  pairing: CloudPairingView | null;
  connection: CloudConnectionView | null;
  last_disconnect: CloudDisconnectView | null;
  report_stats: boolean;
  /** 最近一次上报的原文，原样展示 */
  last_report: Record<string, unknown> | null;
  last_report_at: string | null;
  notices: CloudNotice[];
}

export function getCloudStatus(): Promise<CloudStatusView> {
  return unwrap(request<ApiEnvelope<CloudStatusView>>("/cloud"));
}

/** 开始连接：服务端去云端申请配对码，之后在后台轮询。已连接时 409。 */
export function startCloudPairing(instanceName?: string): Promise<CloudStatusView> {
  return unwrap(
    request<ApiEnvelope<CloudStatusView>>("/cloud/pairing", {
      method: "POST",
      body: JSON.stringify(instanceName ? { instance_name: instanceName } : {}),
    }),
  );
}

/** 放弃当前配对码。关掉配对弹窗不等于取消，只有这里才会作废。 */
export function cancelCloudPairing(): Promise<CloudStatusView> {
  return unwrap(request<ApiEnvelope<CloudStatusView>>("/cloud/pairing", { method: "DELETE" }));
}

/** 立即同步（续签）一次，结果反映在 health 上。 */
export function renewCloud(): Promise<CloudStatusView> {
  return unwrap(request<ApiEnvelope<CloudStatusView>>("/cloud/renew", { method: "POST" }));
}

/**
 * 断开连接。云端连不上且没带 force 时返回 409 CLOUD_UNREACHABLE（见 isCloudUnreachable）：
 * 由管理员确认后带 force 只删本地凭证。
 */
export function disconnectCloud(force = false): Promise<CloudStatusView> {
  return unwrap(
    request<ApiEnvelope<CloudStatusView>>("/cloud/disconnect", {
      method: "POST",
      body: JSON.stringify(force ? { force: true } : {}),
    }),
  );
}

export function updateCloudSettings(reportStats: boolean): Promise<CloudStatusView> {
  return unwrap(
    request<ApiEnvelope<CloudStatusView>>("/cloud/settings", {
      method: "PUT",
      body: JSON.stringify({ report_stats: reportStats }),
    }),
  );
}

export function dismissCloudNotice(noticeId: string): Promise<CloudStatusView> {
  return unwrap(
    request<ApiEnvelope<CloudStatusView>>(
      `/cloud/notices/${encodeURIComponent(noticeId)}/dismiss`,
      { method: "POST" },
    ),
  );
}

/** 断开时云端连不上（409 CLOUD_UNREACHABLE）：要再问一次管理员是否只删本地凭证。 */
export function isCloudUnreachable(err: unknown): boolean {
  if (!(err instanceof HttpError)) return false;
  const payload = err.details as { code?: unknown } | null | undefined;
  return payload?.code === "CLOUD_UNREACHABLE";
}
