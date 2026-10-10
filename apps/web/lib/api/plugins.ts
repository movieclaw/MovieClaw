import { request } from "@/lib/http";

/** 后端统一响应信封（见 movieclaw_api.schemas.response.ApiResponse） */
interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

// ---------------------------------------------------------------------------
// 插件诊断（设置 → 插件；docs/design/plugin-kernel.md §10、plugin-page-tiers.md）
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
  /** 提供这个服务的插件与它的状态；没有插件提供为 null，旧服务端没有这两个字段 */
  provider?: string | null;
  provider_state?: PluginState | null;
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
  /** 插件声明需要的宿主操作；旧服务端没有这个字段 */
  permissions?: string[];
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
  /** 内置插件的领域分组（系统模块清单内部的分组）；本地 / 第三方插件为 null，旧服务端没有这个字段 */
  group?: string | null;
  /**
   * 插件页分层（docs/design/plugin-page-tiers.md）：official 官方插件（可被插件包替换，替换它的插件包
   * 也算）/ system 系统模块；其余第三方与本地插件为 null，旧服务端没有这个字段
   */
  tier?: PluginTier | null;
}

export type PluginTier = "official" | "system";

/** 功能目录里的一项（功能开关用；插件页不展示）：由一个或多个内置插件组成（docs/design/plugin-page-tiers.md） */
export interface PluginFeature {
  key: string;
  title: string;
  description: string;
  /** 组成这个功能的内置插件条目 id */
  entries: string[];
  /** 去哪里设置它（站内路径） */
  settings_href: string | null;
  /** 能不能停用（服务端 / 接口可切换，网页不出开关）；旧服务端没有开关相关字段 */
  switchable?: boolean;
  /** 当前是否开启（被停用或被管理员硬覆盖关掉都算关） */
  enabled?: boolean;
  /** 被 data/plugins.yaml / 环境变量关掉的原因：开关锁住 */
  locked_by?: string | null;
  /** 停用时间与停用人；开启着为 null */
  changed_at?: string | null;
  changed_by?: string | null;
}

/** 功能目录与开关状态（成员也能读：停用的功能各端不出入口） */
export async function listFeatures(): Promise<PluginFeature[]> {
  return (await request<ApiEnvelope<PluginFeature[]>>("/app/features")).data;
}

/** 停用 / 开启一个功能：运行中生效，重启后保持（管理员） */
export async function setFeatureEnabled(key: string, enabled: boolean): Promise<PluginFeature> {
  return (
    await request<ApiEnvelope<PluginFeature>>(`/app/features/${encodeURIComponent(key)}`, {
      method: "PUT",
      body: JSON.stringify({ enabled }),
    })
  ).data;
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
  /** 要开放的回调端点名：外部平台能不登录直接调进来的地址；旧服务端没有这个字段 */
  callbacks?: string[];
  new_callbacks?: string[];
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
  /** 开放的回调端点名；旧服务端没有这个字段 */
  callbacks?: string[];
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

/* —— 插件详情（设置 → 插件 → 点一个插件） —— */

/** 装了这个插件，系统多了什么（已翻成人话） */
export interface PluginAdded {
  /** channel / task / ingest / job / site / command / trigger / decision */
  kind: string;
  title: string;
  detail: string;
  /** 去哪里看 / 调整（站内路径） */
  href: string | null;
}

export interface PluginDurableConsumer {
  consumer_id: string;
  event: string;
  /** 事件的人话名字 */
  title: string;
  active: boolean;
  /** 尚未处理的事件数 */
  backlog: number;
  /** 当前事件已失败的次数（0 = 正常） */
  attempts: number;
  next_attempt_at: string | null;
  last_error: string | null;
}

export interface PluginDeadLetter {
  id: number;
  consumer_id: string;
  event: string;
  /** 事件的人话名字 */
  title: string;
  event_id: string;
  error: string;
  attempts: number;
  created_at: string;
}

export interface PluginCallbackKey {
  id: number;
  entry_id: string;
  endpoint: string;
  scope: string;
  /** 地址（密钥打码） */
  url: string;
  created_at: string;
  running: boolean;
  calls: number;
  /** 插件回 401 / 403 的次数（验证没通过） */
  failures: number;
  last_called_at: string | null;
  last_status: number | null;
}

export interface PluginDetail {
  plugin: PluginInfo;
  /** official：随应用提供；package：第三方插件包；local：本地插件；system：系统模块 */
  kind: "official" | "package" | "local" | "system";
  description: string;
  version: string | null;
  /** 是否声明了联网（插件包才有） */
  network: boolean | null;
  package: {
    version: string;
    /** 安装时间（Unix 秒） */
    installed_at: number | null;
    previous_version: string | null;
    bad_versions: string[];
    operations: OperationDetail[];
    paths: PathGrant[];
    callbacks: string[];
    replaces_builtin: boolean;
  } | null;
  adds: PluginAdded[];
  consumers: PluginDurableConsumer[];
  dead_letters: PluginDeadLetter[];
  callbacks: PluginCallbackKey[];
  data_rows: number;
  /** 插件私有目录占用（字节） */
  disk_bytes: number;
  /** 插件私有目录（旧服务端没有这个字段） */
  data_path?: string | null;
  children: string[];
  /** 源码在哪（旧服务端没有这个字段） */
  source?: {
    /** 应用源码按 src/… 显示（系统模块带行号），数据目录里的按 data/… */
    path: string;
    /** 入口名称：系统模块是函数名（如 downloads()），官方 / 本地插件是入口模块名 */
    entry: string | null;
  } | null;
}

export async function getPluginDetail(id: string): Promise<PluginDetail> {
  return (await request<ApiEnvelope<PluginDetail>>(`/app/plugins/${encodeURIComponent(id)}`)).data;
}

/** 换一个回调地址：旧地址立即失效，返回新地址全文（只出现这一次） */
export async function rotateCallback(keyId: number): Promise<{ url: string; absolute: boolean }> {
  return (
    await request<ApiEnvelope<{ url: string; absolute: boolean }>>(
      `/app/plugins/callbacks/${keyId}/rotate`,
      { method: "POST" },
    )
  ).data;
}

export async function revokeCallback(keyId: number): Promise<void> {
  await request(`/app/plugins/callbacks/${keyId}`, { method: "DELETE" });
}

/** 把搁置的事件再交给插件处理一次 */
export async function replayDeadLetter(id: number): Promise<void> {
  await request(`/app/plugins/dead-letters/${id}/replay`, { method: "POST" });
}

/** 忽略搁置的事件（不再处理） */
export async function dismissDeadLetter(id: number): Promise<void> {
  await request(`/app/plugins/dead-letters/${id}/dismiss`, { method: "POST" });
}

// ---------------------------------------------------------------------------
// 插件通用设置（docs/design/plugin-phase4.md §3）

/** JSON Schema 子集里的一个字段（movieclaw_sdk/config_schema.py） */
export interface SchemaField {
  type: string | string[];
  title?: string;
  description?: string;
  default?: unknown;
  enum?: string[];
  items?: { type: string };
  minimum?: number;
  maximum?: number;
  minLength?: number;
  maxLength?: number;
  format?: string;
  examples?: string[];
  writeOnly?: boolean;
  "x-multiline"?: boolean;
}

export interface ConfigSchema {
  type: "object";
  title?: string;
  properties: Record<string, SchemaField>;
  required?: string[];
}

export interface PluginSettings {
  /** 能否在界面上修改 */
  editable: boolean;
  /** 不能修改的原因（配置里有界面不支持的类型）；没有配置为 null */
  reason: string | null;
  schema: ConfigSchema | null;
  /** 当前值（不含敏感字段） */
  values: Record<string, unknown>;
  /** 已设置过的敏感字段 */
  secrets_set: string[];
}

export async function getPluginSettings(id: string): Promise<PluginSettings> {
  return (
    await request<ApiEnvelope<PluginSettings>>(
      `/app/plugins/${encodeURIComponent(id)}/settings`,
    )
  ).data;
}

/** 保存并重启插件；敏感字段留空表示不改。重启失败服务端会恢复原设置并报原因 */
export async function savePluginSettings(
  id: string,
  values: Record<string, unknown>,
): Promise<PluginSettings> {
  return (
    await request<ApiEnvelope<PluginSettings>>(
      `/app/plugins/${encodeURIComponent(id)}/settings`,
      {
        method: "PUT",
        body: JSON.stringify({ values }),
      },
    )
  ).data;
}
