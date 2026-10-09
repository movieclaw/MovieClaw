import { request } from "@/lib/http";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse） */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

// ---------------------------------------------------------------------------
// 插件诊断（设置 → 插件 → 内置；docs/design/plugin-kernel.md §10）
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
  /** inline：主进程里运行；process：独立进程。旧服务端没有这个字段 */
  runtime?: "inline" | "process";
  /** 内置插件的功能分组（设置 → 插件 → 内置）；本地 / 第三方插件为 null，旧服务端没有这个字段 */
  group?: string | null;
}

export interface PluginHealth {
  key: string;
  ok: boolean;
  message: string;
  action_href: string | null;
  since: string;
}

/** 插件安全模式（docs/design/plugin-phase3.md §5）：上次带着插件没能稳定运行，本次跳过了它们 */
export interface PluginSafeMode {
  active: boolean;
  reason: string;
  /** 进入时间（Unix 秒） */
  since: number | null;
  skipped: string[];
  /** env / file：手动强制（env 只能改环境变量退出）；null：自动进入或未进入 */
  forced: string | null;
}

export interface PluginsOverview {
  plugins: PluginInfo[];
  /** 旧服务端没有这个字段 */
  safe_mode?: PluginSafeMode;
  /** 内置插件分组的展示顺序；旧服务端没有这个字段 */
  groups?: string[];
}

export async function listPlugins(): Promise<PluginsOverview> {
  return (await request<ApiEnvelope<PluginsOverview>>("/app/plugins")).data;
}

/** 退出安全模式：当场重新加载被跳过的插件，返回「插件 → 加载后的状态」 */
export async function exitSafeMode(): Promise<Record<string, string>> {
  return (
    await request<ApiEnvelope<{ mounted: Record<string, string> }>>(
      "/app/plugins/safe-mode/exit",
      { method: "POST" },
    )
  ).data.mounted;
}

// ---------------------------------------------------------------------------
// 插件包（设置 → 插件 → 已安装；docs/design/plugin-phase3.md §3）
// ---------------------------------------------------------------------------

export interface PathGrant {
  /** library / library:<id> / staging / plugin / 绝对路径 */
  path: string;
  mode: "read" | "rw" | string;
}

export interface OperationDetail {
  id: string;
  /** 这个操作做什么（中文） */
  summary: string;
  /** 危险操作（删除、改配置等）：批准页标红 */
  dangerous: boolean;
}

export interface PackageRequest {
  id: string;
  title: string;
  version: string;
  description: string;
  /** process：独立进程；inline：主进程里运行（须单独确认） */
  runtime: string;
  operations: string[];
  /** 相比当前已安装版本新增的申请 */
  new_operations: string[];
  operation_details: OperationDetail[];
  paths: PathGrant[];
  new_paths: PathGrant[];
  requires: Record<string, string>;
  installed_version: string | null;
  /** 与随带的内置插件同 id：安装即替换它，卸载后随带版本回来；旧服务端没有这个字段 */
  replaces_builtin?: boolean;
}

export interface InstalledPackage {
  id: string;
  title: string;
  version: string;
  runtime: string;
  operations: string[];
  operation_details: OperationDetail[];
  paths: PathGrant[];
  previous_version: string | null;
  /** 激活失败过、已自动回滚的版本 */
  bad_versions: string[];
  state: PluginState | "unloaded";
  error: string | null;
  /** 还在安装后的宽限期观察中（这段时间崩溃会自动回滚） */
  watching: boolean;
  /** 替换了随带的内置插件；旧服务端没有这个字段 */
  replaces_builtin?: boolean;
}

export interface PackagesOverview {
  installed: InstalledPackage[];
  pending: PackageRequest[];
}

export interface PackageResult {
  /** active / rolled_back / … */
  status: string;
  version: string | null;
  state: string;
  error: string | null;
}

export async function listPackages(): Promise<PackagesOverview> {
  return (await request<ApiEnvelope<PackagesOverview>>("/app/plugins/packages")).data;
}

export async function uploadPackage(file: File): Promise<PackageRequest> {
  const form = new FormData();
  form.append("file", file, file.name);
  return (
    await request<ApiEnvelope<PackageRequest>>("/app/plugins/packages", {
      method: "POST",
      body: form,
    })
  ).data;
}

/** 批准：宿主操作与路径须与插件申请的完全一致（显式同意），进程内运行须 allowInline */
export async function approvePackage(
  pending: PackageRequest,
  allowInline: boolean,
): Promise<PackageResult> {
  return (
    await request<ApiEnvelope<PackageResult>>(
      `/app/plugins/packages/${encodeURIComponent(pending.id)}/approve`,
      {
        method: "POST",
        body: JSON.stringify({
          version: pending.version,
          operations: pending.operations,
          paths: pending.paths,
          allow_inline: allowInline,
        }),
      },
    )
  ).data;
}

export async function discardPackage(id: string): Promise<void> {
  await request<ApiEnvelope<null>>(
    `/app/plugins/packages/${encodeURIComponent(id)}/pending`,
    { method: "DELETE" },
  );
}

export async function rollbackPackage(id: string): Promise<PackageResult> {
  return (
    await request<ApiEnvelope<PackageResult>>(
      `/app/plugins/packages/${encodeURIComponent(id)}/rollback`,
      { method: "POST" },
    )
  ).data;
}

export async function uninstallPackage(id: string, purgeData: boolean): Promise<number> {
  return (
    await request<ApiEnvelope<{ purged_rows: number }>>(
      `/app/plugins/packages/${encodeURIComponent(id)}?purge_data=${purgeData}`,
      { method: "DELETE" },
    )
  ).data.purged_rows;
}
