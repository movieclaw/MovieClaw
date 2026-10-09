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
// IM 通道（见 api/routes/channels.py；通道来自通道插件，设置页按绑定方式通用渲染）
// ---------------------------------------------------------------------------

export interface ChannelField {
  key: string;
  label: string;
  /** 凭据类字段：输入框打码 */
  secret: boolean;
  placeholder: string;
  help: string;
  required: boolean;
}

/** 一个可用的通道（注册表里有它的驱动）。 */
export interface ChannelInfo {
  id: string;
  title: string;
  description: string;
  /** 提供这个通道的插件 */
  entry_id: string;
  /** 能收消息（能对话 AI 助手）；false 表示只能推送 */
  receive: boolean;
  photo: boolean;
  binding: {
    /** form：填表单；flow：插件驱动的交互式流程（如扫码） */
    kind: "form" | "flow";
    fields: ChannelField[];
    /** code：提交后私聊 bot 发 6 位配对码；none：提交即完成 */
    pairing: "code" | "none";
    hint: string;
  };
}

export interface ChannelAccount {
  channel_id: string;
  account_id: string;
  display_name: string;
  /** 白名单用户（同时是推送目标）；群机器人为空 */
  bound_user_id: string | null;
  /** active=正常；stale=凭据失效需重新绑定 */
  status: "active" | "stale";
  running: boolean;
  /** 提供这个通道的插件没启用（关闭 / 卸载）：账号保留，重新启用后自动恢复 */
  channel_available: boolean;
  last_error: string | null;
  bound_at: string;
}

export type ChannelBindingStatus =
  | "pending"
  | "scanned"
  | "need_input"
  | "confirmed"
  | "already_bound"
  | "expired"
  | "failed";

/** 绑定状态（发起返回与轮询同一结构）。 */
export interface ChannelBinding {
  binding_id: string;
  channel_id: string;
  /** pairing：等用户发配对码；flow：交互式；done：已完成 */
  kind: "pairing" | "flow" | "done";
  status: ChannelBindingStatus;
  message: string;
  pair_code: string;
  /** 要扫的二维码（SVG data URL），会中途刷新 */
  qr_image: string;
  /** 二维码内容（原生 App 本地画码用）；旧服务端没有这个字段 */
  qr?: string;
  input_label: string | null;
  account: ChannelAccount | null;
}

export function listChannels(init?: RequestInit): Promise<{
  channels: ChannelInfo[];
  accounts: ChannelAccount[];
}> {
  return unwrap(request<ApiEnvelope<{ channels: ChannelInfo[]; accounts: ChannelAccount[] }>>("/channels", init));
}

export function startChannelBinding(
  channelId: string,
  fields: Record<string, string> = {},
): Promise<ChannelBinding> {
  return unwrap(
    request<ApiEnvelope<ChannelBinding>>(`/channels/bindings`, {
      method: "POST",
      body: JSON.stringify({ channel_id: channelId, fields }),
    }),
  );
}

export function getChannelBinding(bindingId: string): Promise<ChannelBinding> {
  return unwrap(
    request<ApiEnvelope<ChannelBinding>>(`/channels/bindings/${encodeURIComponent(bindingId)}`),
  );
}

export function submitChannelBindingInput(
  bindingId: string,
  value: string,
): Promise<ChannelBinding> {
  return unwrap(
    request<ApiEnvelope<ChannelBinding>>(
      `/channels/bindings/${encodeURIComponent(bindingId)}/input`,
      { method: "POST", body: JSON.stringify({ value }) },
    ),
  );
}

export function unbindChannelAccount(
  channelId: string,
  accountId: string,
): Promise<Record<string, never>> {
  return unwrap(
    request<ApiEnvelope<Record<string, never>>>(
      `/channels/${encodeURIComponent(channelId)}/accounts/${encodeURIComponent(accountId)}`,
      { method: "DELETE" },
    ),
  );
}

export function sendChannelPushTest(text?: string): Promise<{ sent: number }> {
  return unwrap(
    request<ApiEnvelope<{ sent: number }>>(`/channels/im/push-test`, {
      method: "POST",
      body: JSON.stringify({ text: text ?? "" }),
    }),
  );
}

/** 推送内容开关（哪些系统事件会推送到已绑定通道）。 */
export interface ChannelPushConfig {
  /** 订阅命中并投递下载时推送 */
  push_dispatch: boolean;
  /** 下载完成整理入库时推送 */
  push_imported: boolean;
}

export function getChannelPushConfig(): Promise<ChannelPushConfig> {
  return unwrap(request<ApiEnvelope<ChannelPushConfig>>(`/channels/im/push-config`));
}

export function updateChannelPushConfig(config: ChannelPushConfig): Promise<ChannelPushConfig> {
  return unwrap(
    request<ApiEnvelope<ChannelPushConfig>>(`/channels/im/push-config`, {
      method: "PUT",
      body: JSON.stringify(config),
    }),
  );
}
