import type { CloudState } from "@/lib/api/cloud";
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

/* —— App 推送（管理员，docs/design/cloud-push.md §7.2） —— */

/** inactive = 官方通道没连云或已停用；warning = 限额用完、版本将不受支持、最近失败过；error = 连不上、令牌无效、版本不受支持 */
export type PushChannelState = "inactive" | "ok" | "warning" | "error";

/** 中继 /v1/info 声明的鉴权方式；null = 还没拉到过 /v1/info */
export type RelayAuthMode = "issuer" | "static" | "none";

/**
 * 中继最近一次返回的当日额度。官方通道还没推送过时只有云端给的每日上限
 * （used 为 null）；不限额的中继没有 limit。
 */
export interface PushQuota {
  limit: number | null;
  used: number | null;
  remaining: number | null;
  reset_at: string | null;
}

export interface PushChannelView {
  /** 官方通道固定为 official，自建中继是它自己的 id */
  id: string;
  kind: "official" | "custom";
  name: string;
  enabled: boolean;
  state: PushChannelState;
  /** 给人看的一句话状态 */
  status_text: string;
  url: string | null;
  auth_mode: RelayAuthMode | null;
  /** 自建中继令牌的打码形式（mcpush_a1b2…） */
  token_hint: string | null;
  software: string | null;
  /** 能推送的基础 Bundle ID */
  topics: string[];
  quota: PushQuota | null;
  last_success_at: string | null;
  last_error: string | null;
  /** 走这个通道的设备数（设备明细在「设备」页） */
  device_count: number;
}

/** 登记了推送、但没有任何可用通道的一类 App（多半是自己打包的版本） */
export interface PushUncoveredApp {
  topic: string;
  device_count: number;
}

export interface PushChannelsView {
  cloud_state: CloudState;
  channels: PushChannelView[];
  /** 空 = 没有缺口，页面不提示 */
  uncovered: PushUncoveredApp[];
}

/** 检测中继（读它的 /v1/info）的结果，决定添加表单要不要填令牌 */
export interface RelayProbeView {
  url: string;
  reachable: boolean;
  /** 连不上的原因；连上了但加不了（协议不兼容、要签发方令牌）也写在这里 */
  error: string | null;
  software: string | null;
  protocol: number | null;
  auth_mode: RelayAuthMode | null;
  topics: string[];
  types: string[];
  /** 本地有多少台已登记设备的 Bundle ID 在它的 topics 里 */
  matched_devices: number;
  /** 只提示不拦：http 走公网、无鉴权在公网、目前没有设备会用到它等 */
  warnings: string[];
}

export function getPushChannels(): Promise<PushChannelsView> {
  return unwrap(request<ApiEnvelope<PushChannelsView>>("/push/channels"));
}

export function setOfficialChannelEnabled(enabled: boolean): Promise<PushChannelsView> {
  return unwrap(
    request<ApiEnvelope<PushChannelsView>>("/push/channels/official", {
      method: "PUT",
      body: JSON.stringify({ enabled }),
    }),
  );
}

export function probeRelay(url: string): Promise<RelayProbeView> {
  return unwrap(
    request<ApiEnvelope<RelayProbeView>>("/push/relays/probe", {
      method: "POST",
      body: JSON.stringify({ url }),
    }),
  );
}

/** 添加自建中继：服务端会再检测一次；static 模式必须带令牌。 */
export function addRelay(payload: {
  name: string;
  url: string;
  token?: string;
}): Promise<PushChannelsView> {
  return unwrap(
    request<ApiEnvelope<PushChannelsView>>("/push/relays", {
      method: "POST",
      body: JSON.stringify(payload),
    }),
  );
}

/** 修改自建中继：只传要改的字段；改了地址服务端会重新检测。 */
export function updateRelay(
  relayId: string,
  patch: { name?: string; url?: string; token?: string; enabled?: boolean },
): Promise<PushChannelsView> {
  return unwrap(
    request<ApiEnvelope<PushChannelsView>>(`/push/relays/${encodeURIComponent(relayId)}`, {
      method: "PATCH",
      body: JSON.stringify(patch),
    }),
  );
}

export function deleteRelay(relayId: string): Promise<PushChannelsView> {
  return unwrap(
    request<ApiEnvelope<PushChannelsView>>(`/push/relays/${encodeURIComponent(relayId)}`, {
      method: "DELETE",
    }),
  );
}

/** 重新拉取中继的 /v1/info */
export function refreshRelay(relayId: string): Promise<PushChannelsView> {
  return unwrap(
    request<ApiEnvelope<PushChannelsView>>(
      `/push/relays/${encodeURIComponent(relayId)}/refresh`,
      { method: "POST" },
    ),
  );
}

/* —— 我的通知（所有登录的人，§7.3） —— */

export type MyDeviceStatus =
  | "ok"
  | "no_channel"
  | "permission_denied"
  | "bad_token"
  | "not_registered";

export interface MyPushEvent {
  key: string;
  title: string;
  description: string;
  /** 分组标题（我的订阅、账号安全、管理员通知……），按出现顺序分组 */
  group: string;
  enabled: boolean;
  default: boolean;
}

/** App 类设备的推送状态，挂在「设备」列表的每台设备上（GET /auth/devices 的 push） */
export interface DevicePushState {
  status: MyDeviceStatus;
  status_text: string;
}

/** 我收不到通知、需要处理的一台设备 */
export interface MyPushAttention {
  device_id: string;
  device_name: string;
  status: MyDeviceStatus;
  status_text: string;
}

/** 我能看到的一个媒体库（「媒体库有新片」选库用） */
export interface MyPushLibrary {
  id: number;
  name: string;
  kind: string;
}

export interface MyPushView {
  /** 服务器有没有任何可用通道 */
  instance_ready: boolean;
  is_admin: boolean;
  events: MyPushEvent[];
  /** 我能收到通知的设备数 */
  ready_devices: number;
  /** 只有 permission_denied / no_channel / bad_token；空 = 没问题，页面不提示 */
  attention: MyPushAttention[];
  /** 我能看到的媒体库 */
  libraries: MyPushLibrary[];
  /** 「媒体库有新片」关心的库；null = 能看到的全部（含以后新建的） */
  library_ids: number[] | null;
}

export interface PushTestResult {
  sent: number;
  results: { device_id: string; device_name: string; result: string; message: string | null }[];
}

export function getMyPush(): Promise<MyPushView> {
  return unwrap(request<ApiEnvelope<MyPushView>>("/push/me"));
}

/**
 * 改通知偏好：只传要改的部分。library_ids 不传 = 不改，null = 全部（含以后新建的库）。
 */
export function updateMyPushPreferences(patch: {
  events?: Record<string, boolean>;
  library_ids?: number[] | null;
}): Promise<MyPushView> {
  return unwrap(
    request<ApiEnvelope<MyPushView>>("/push/me/preferences", {
      method: "PUT",
      body: JSON.stringify(patch),
    }),
  );
}

/** 给自己的设备发一条测试通知；10 秒内只能发一次（后端拒绝时带可读的 message）。 */
export function sendMyPushTest(): Promise<PushTestResult> {
  return unwrap(request<ApiEnvelope<PushTestResult>>("/push/me/test", { method: "POST" }));
}
