import { request } from "@/lib/http";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse） */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

// ---------------------------------------------------------------------------
// 运行模块（设置 → 更新与维护 → 模块；docs/design/plugin-kernel.md §10）
// 后端每个子系统都是插件内核上的一个内置插件；这里只读地看它们的状态。
// ---------------------------------------------------------------------------

export type PluginState =
  | "disabled"
  | "incompatible"
  | "pending"
  | "loading"
  | "active"
  | "failed"
  | "unloading"
  | "disposed";

export interface PluginBlockedBy {
  /** 缺的服务键 */
  key: string;
  /** 为什么缺：没有插件提供 / 提供方某状态 */
  reason: string;
}

export interface PluginStats {
  events: number;
  failures: number;
  timeouts: number;
  dropped: number;
  handler_max_ms: number;
  handler_avg_ms: number;
  last_error: string | null;
  tasks: number;
  listeners: number;
  breaker: string;
}

export interface PluginInfo {
  id: string;
  plugin: string;
  title: string;
  state: PluginState;
  critical: boolean;
  disableable: boolean;
  reloadable: boolean;
  source: string;
  parent: string | null;
  provides: string[];
  inject: string[];
  blocked_by: PluginBlockedBy[];
  incompatible: string | null;
  /** 谁禁用的：patch（data/plugins.yaml）/ env:XXX（环境变量） */
  disabled_by: string | null;
  error: string | null;
  apply_ms: number | null;
  dispose_ms: number | null;
  unsettled: boolean;
  stats: PluginStats;
  /** 插件自己报告的运行状况（PLUGIN_HEALTH）；旧服务端没有这个字段 */
  health?: PluginHealth[];
  /** 插件数据行数（PLUGIN_DATA） */
  data_rows?: number;
}

export interface PluginHealth {
  key: string;
  ok: boolean;
  message: string;
  action_href: string | null;
  since: string;
}

export interface PluginsOverview {
  plugins: PluginInfo[];
}

export async function listPlugins(): Promise<PluginsOverview> {
  return (await request<ApiEnvelope<PluginsOverview>>("/app/plugins")).data;
}
