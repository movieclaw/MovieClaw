import { request } from "@/lib/http";
import type { ConfigSchema } from "@/lib/api/plugins";

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
// 网盘（见 api/routes/drives.py；网盘来自存储插件，设置页按插件声明的登录方式通用渲染）
// docs/design/cloud-storage.md §11
// ---------------------------------------------------------------------------

export interface DriveLoginChoice {
  value: string;
  label: string;
  /** 选项的补充说明（如「会与浏览器互踢」） */
  help: string;
}

export interface DriveLoginOption {
  key: string;
  label: string;
  default: string;
  help: string;
  choices: DriveLoginChoice[];
}

/** 一种可用的网盘（有插件提供后端）。 */
export interface DriveBackend {
  type: string;
  title: string;
  description: string;
  /** 图标主题色；空 = 默认色 */
  accent_color: string;
  capabilities: {
    writable: boolean;
    rapid_upload_hashes: string[];
    list_hashes: boolean;
    change_feed: boolean;
    original_link: boolean;
    recycle_bin: boolean;
    default_qps: number;
    default_daily_budget: number;
    default_read_slots: number;
  };
  login: {
    scan: boolean;
    /** 支持用浏览器扩展导入 / 粘贴 Cookie */
    cookie: boolean;
    cookie_domains: string[];
    /** 填表登录的字段（开放平台的 Client ID / 密钥等，同插件设置的 Schema）；null = 不支持 */
    form?: ConfigSchema | null;
    options: DriveLoginOption[];
    hint: string;
  };
}

export type DriveAccountStatus = "ok" | "auth_expired" | "rate_limited" | "api_broken" | "disabled";

export interface DriveAccount {
  id: number;
  backend: string;
  /** 网盘名；插件不在时就是类型值 */
  backend_title: string;
  /** 提供这种网盘的插件在运行 */
  backend_available: boolean;
  accent_color: string;
  name: string;
  login_method: "scan" | "cookie" | "form";
  /** 登录细节（如扫码选的登录端、「网页端」） */
  login_detail: string | null;
  status: DriveAccountStatus;
  status_message: string | null;
  /** 限流的恢复时间 */
  status_until: string | null;
  /** 生效值（用户没改过就是插件默认值） */
  qps: number;
  daily_budget: number;
  read_slots: number;
  qps_custom: boolean;
  daily_budget_custom: boolean;
  read_slots_custom: boolean;
  /** 今天已用的接口调用次数 */
  used_today: number;
  vip: string | null;
  quota_total: number | null;
  quota_used: number | null;
  profile_at: string | null;
  created_at: string;
}

export type DriveLoginStatus = "pending" | "scanned" | "confirmed" | "expired" | "failed";

export interface DriveLogin {
  login_id: string;
  backend: string;
  status: DriveLoginStatus;
  message: string;
  /** 二维码图片（data URL）；结束后为空 */
  qr_image: string;
  account: DriveAccount | null;
  /** confirmed 时：新账号（否则是重新登录了已有账号） */
  created: boolean;
}

/** 网盘功能醒没醒着（cloud-storage.md §11.8）：没有插件提供后端时休眠，各处网盘入口据此出不出现 */
export interface DriveStatus {
  active: boolean;
  /** 网盘账号数：插件卸载后账号还在，设置页要能看到并提示装插件 */
  accounts: number;
}

export const getDriveStatus = () => unwrap(request<ApiEnvelope<DriveStatus>>("/drives/status"));

export const listDriveBackends = () =>
  unwrap(request<ApiEnvelope<DriveBackend[]>>("/drives/backends"));

export const listDriveAccounts = () =>
  unwrap(request<ApiEnvelope<DriveAccount[]>>("/drives/accounts"));

/** ``relogin``：从某个账号卡片上重新登录时传它的 id，登进来的必须是同一个网盘用户 */
export const startDriveLogin = (
  backend: string,
  options: Record<string, string>,
  relogin?: number,
) =>
  unwrap(
    request<ApiEnvelope<DriveLogin>>("/drives/logins", {
      method: "POST",
      body: JSON.stringify({ backend, options, relogin }),
    }),
  );

export const getDriveLogin = (loginId: string) =>
  unwrap(request<ApiEnvelope<DriveLogin>>(`/drives/logins/${encodeURIComponent(loginId)}`));

export const cancelDriveLogin = (loginId: string) =>
  unwrap(
    request<ApiEnvelope<{ cancelled: boolean }>>(
      `/drives/logins/${encodeURIComponent(loginId)}`,
      { method: "DELETE" },
    ),
  );

export const importDriveCookie = (backend: string, cookie: string, relogin?: number) =>
  unwrap(
    request<ApiEnvelope<DriveLogin>>("/drives/accounts/cookie", {
      method: "POST",
      body: JSON.stringify({ backend, cookie, relogin }),
    }),
  );

export const loginDriveWithForm = (
  backend: string,
  values: Record<string, unknown>,
  relogin?: number,
) =>
  unwrap(
    request<ApiEnvelope<DriveLogin>>("/drives/accounts/form", {
      method: "POST",
      body: JSON.stringify({ backend, values, relogin }),
    }),
  );

export interface DriveAccountUpdate {
  name?: string;
  qps?: number;
  daily_budget?: number;
  read_slots?: number;
  /** 回到插件默认值的字段 */
  reset?: ("qps" | "daily_budget" | "read_slots")[];
}

export const updateDriveAccount = (id: number, payload: DriveAccountUpdate) =>
  unwrap(
    request<ApiEnvelope<DriveAccount>>(`/drives/accounts/${id}`, {
      method: "PATCH",
      body: JSON.stringify(payload),
    }),
  );

export const refreshDriveAccount = (id: number) =>
  unwrap(request<ApiEnvelope<DriveAccount>>(`/drives/accounts/${id}/refresh`, { method: "POST" }));

export const deleteDriveAccount = (id: number) =>
  unwrap(request<ApiEnvelope<{ removed: boolean }>>(`/drives/accounts/${id}`, { method: "DELETE" }));

/** 目录选择器里的一个子目录 */
export interface DriveDir {
  id: string;
  name: string;
  /** 网盘上的完整路径（如「影视/电影」） */
  path: string;
  has_children: boolean | null;
  /** 视频文件数（网盘目录信息直接给的）；不知道为 null */
  video_count: number | null;
  /** 这个目录（或它的上层、下层）已经挂在哪个媒体库上 */
  library_id: number | null;
  library_name: string | null;
}

export const listDriveDirs = (accountId: number, parentId = "", path = "") =>
  unwrap(
    request<ApiEnvelope<DriveDir[]>>(
      `/drives/accounts/${accountId}/dirs?${new URLSearchParams({ parent_id: parentId, path })}`,
    ),
  );

/** 网盘的全局选项 */
export interface DriveSettings {
  /** 本地腾空后删除对应的下载任务（H&R、非 MovieClaw 投递的种子保留） */
  remove_download_tasks: boolean;
}

export const getDriveSettings = () =>
  unwrap(request<ApiEnvelope<DriveSettings>>("/drives/settings"));

export const updateDriveSettings = (payload: Partial<DriveSettings>) =>
  unwrap(
    request<ApiEnvelope<DriveSettings>>("/drives/settings", {
      method: "PUT",
      body: JSON.stringify(payload),
    }),
  );
