import type { DevicePushState } from "@/lib/api/push";
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

/** 写操作的回执：界面直接用后端的 message 做提示（「已注销「XX」」这类带名字的实话）。 */
async function messageOf(promise: Promise<ApiEnvelope<unknown>>): Promise<string> {
  return (await promise).message;
}

/** 配对流里的客户端形态。worker 只能转码，cli 无形态上限。 */
export type DeviceClientType = "worker" | "cli" | string;

/**
 * 一条待批准的接入请求（见 schemas.auth.DeviceRequestView），按配对码取得。
 *
 * 这是用户做批准决定的全部依据：谁在请求、从哪来、码是多少。所以字段都要
 * 原样展示，不做省略。
 *
 * 真正的安全控制是 user_code——它要和设备屏幕上显示的那串对上。source_ip 是
 * 辅助线索，而且**可能为空串**：容器桥接网络会把源地址 NAT 成网桥网关，
 * 那时它认不出任何设备，服务端会如实返回空（见 api/client_address.py），
 * 界面必须说「无法确定」而不是补一个占位地址。
 */
export interface DeviceRequestView {
  user_code: string;
  client_type: DeviceClientType;
  client_name: string;
  /** 可能为空串：容器网络改写了源地址，认不出是哪台机器。 */
  source_ip: string;
  expires_in: number;
  /** 客户端自报的系统与架构，如「macOS 26.0 · arm64」 */
  platform: string | null;
  client_version: string | null;
  /** 只有管理员能批准（转码器）；成员看到时界面要说明原因、禁用批准 */
  requires_admin: boolean;
}

/**
 * 「我的设备」里的一台设备（见 schemas.auth.LoginDeviceView）：登录设备或
 * Jellyfin 播放器（docs/design/login-devices.md）。
 *
 * - id：登录设备为 `ld-<n>`，Jellyfin 播放器为 `jf-<n>`；
 * - kind：web / ios / tvos / macos / android / cli / worker / manual / jellyfin；
 * - family：login = 用密码登录的（改密即下线）；paired = 配对或手工创建的
 *   （改密默认保留）；
 * - scope：full = 与主人相同的权限；transcode = 只能转码。
 */
export interface LoginDeviceView {
  id: string;
  kind: string;
  /** 给人看的类型名：浏览器、iOS App、命令行、Infuse…… */
  kind_label: string;
  family: "login" | "paired" | string;
  name: string;
  scope: "full" | "transcode" | string;
  platform: string | null;
  client_version: string | null;
  created_at: string;
  last_seen_at: string | null;
  last_seen_ip: string | null;
  /** 只有网页会话有过期时间，其余长期有效 */
  expires_at: string | null;
  /** 是不是发起本次请求的这台（即当前这个浏览器） */
  current: boolean;
  /**
   * 此刻有没有一条活着的转码控制连接。只有转码器有长连接：它只在握手时验一次
   * 凭证、之后靠心跳在线，所以在不在线以它为准，而不是 last_seen_at。
   */
  connected: boolean;
  /** Jellyfin 播放器的名字由它自己上报，不能改名 */
  renamable: boolean;
  /** 主人：成员 id；0 = 超管 */
  owner_id: number;
  owner_username: string;
  owner_nickname: string;
  /** App 类设备（ios / tvos / android）的推送状态，其他设备为 null（docs/design/cloud-push.md §7.3） */
  push: DevicePushState | null;
}

/**
 * 刚创建出来的手工令牌：唯一一次能读到明文的地方。
 *
 * 服务端不保存明文（只存哈希），这个响应之后再也拿不到——界面必须让用户
 * 当场存走，不能做成「以后再来复制」。
 */
export interface ManualTokenCreatedView {
  id: string;
  name: string;
  scope: "full" | "transcode" | string;
  created_at: string;
  token: string;
}

/**
 * 手工创建一枚令牌，给没法在浏览器里按下批准的环境用（NAS 定时任务、CI、
 * 无界面容器、命令行模式的转码器）。scope=transcode 的令牌只能转码。
 *
 * 这个入口只认人在网页或 App 里的超管会话（服务端挂 require_admin_session），
 * 令牌自己调不动——否则一枚泄漏的令牌就能给自己造备份，注销也止不住损
 * （docs/design/login-devices.md「签发权」）。
 */
export function createDeviceToken(
  name: string,
  scope: "full" | "transcode",
): Promise<ManualTokenCreatedView> {
  return unwrap(
    request<ApiEnvelope<ManualTokenCreatedView>>("/auth/tokens", {
      method: "POST",
      body: JSON.stringify({ name, scope }),
    }),
  );
}

/**
 * 按配对码取一条待批准的请求。
 *
 * 服务端刻意不提供「列出全部待批准请求」：批准页只显示用户手里这个码对应的
 * 那一条，成员之间看不到彼此的请求，管理员也不会误批成员的命令行。
 * 不存在返回 404，已处理 / 已过期返回 400，错误文案可直接展示。
 */
export function getDeviceRequest(userCode: string): Promise<DeviceRequestView> {
  return unwrap(
    request<ApiEnvelope<DeviceRequestView>>(
      `/auth/devices/requests/${encodeURIComponent(userCode)}`,
    ),
  );
}

/** 批准一台设备接入：服务端此刻才签发令牌，令牌归属批准者本人。返回后端提示语。 */
export function approveDeviceRequest(userCode: string): Promise<string> {
  return messageOf(
    request<ApiEnvelope<null>>(
      `/auth/devices/requests/${encodeURIComponent(userCode)}/approve`,
      { method: "POST" },
    ),
  );
}

/** 拒绝一台设备接入：不生成任何令牌。返回后端提示语。 */
export function denyDeviceRequest(userCode: string): Promise<string> {
  return messageOf(
    request<ApiEnvelope<null>>(
      `/auth/devices/requests/${encodeURIComponent(userCode)}/deny`,
      { method: "POST" },
    ),
  );
}

/**
 * 我的设备：登录着我账号的浏览器、App、命令行、转码器与播放器（当前设备排第一）。
 * all=true 仅超管可用：列出全部成员的设备，每台带主人。
 */
export function listLoginDevices(all = false): Promise<LoginDeviceView[]> {
  return unwrap(
    request<ApiEnvelope<LoginDeviceView[]>>(`/auth/devices?all=${all ? "true" : "false"}`),
  );
}

/** 给设备改名（Jellyfin 播放器不可改名，服务端返回 400）。 */
export function renameLoginDevice(deviceId: string, name: string): Promise<LoginDeviceView> {
  return unwrap(
    request<ApiEnvelope<LoginDeviceView>>(`/auth/devices/${encodeURIComponent(deviceId)}`, {
      method: "PATCH",
      body: JSON.stringify({ name }),
    }),
  );
}

/**
 * 注销一台设备：凭证立即失效，它正在播的流、转码连接一并断开。返回后端提示语。
 *
 * 注意：当前这个浏览器自己不要走这里——注销完 Cookie 里还揣着一枚作废的令牌，
 * 账号袋也不会切到下一个账号。当前设备请走退出登录（lib/api/auth.ts 的 logout），
 * 服务端同样会作废这枚令牌。
 */
export function revokeLoginDevice(deviceId: string): Promise<string> {
  return messageOf(
    request<ApiEnvelope<null>>(`/auth/devices/${encodeURIComponent(deviceId)}`, {
      method: "DELETE",
    }),
  );
}
