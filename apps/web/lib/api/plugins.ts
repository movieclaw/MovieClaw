import { request } from "@/lib/http";
import { refreshThemeCatalog } from "@/lib/theme-catalog-sync";

/**
 * 插件装卸 / 停用 / 恢复之后，主题目录可能变了（主题是插件，docs/design/theme-plugins.md §4.3）：
 * 改动成功就顺手重拉，外观设置的主题卡与可用性跟着服务端走。重拉失败不影响这次操作的结果。
 */
async function thenRefreshThemes<T>(result: Promise<T>): Promise<T> {
  const value = await result;
  void refreshThemeCatalog().catch(() => {});
  return value;
}

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
  /** 谁禁用的：switch（插件页停用）/ feature:XXX（功能开关）/ patch（data/plugins.yaml）/ env:XXX（环境变量） */
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
  /** 能在插件页停用 / 启用（官方插件与插件包）；旧服务端没有这个字段 */
  switchable?: boolean;
  /** 官方插件，能在插件页卸载（随时能恢复） */
  removable?: boolean;
  /** 被 data/plugins.yaml / 环境变量关掉的原因：停用开关锁住 */
  locked_by?: string | null;
}

/** 在插件页卸载了的官方插件（可恢复） */
export interface RemovedPlugin {
  id: string;
  title: string;
  description: string;
  removed_at: string;
  removed_by: string | null;
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
  /** 卸载了的官方插件；旧服务端没有这个字段 */
  removed?: RemovedPlugin[];
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

export interface PluginNotification {
  event: string;
  /** 标题模板：{字段} 换成事件里的值 */
  title: string;
  body: string;
  audience: string;
  audience_label: string;
  reaches_members: boolean;
  default: boolean;
}

export interface PackageDependency {
  name: string;
  version: string;
  /** 这台服务器要下载的轮子大小（字节）；没有适用的轮子时为空 */
  size: number | null;
  /** 含本机代码（不是纯 Python） */
  native: boolean;
  /** 有适用于这台服务器平台的轮子 */
  available: boolean;
  /** 相比已安装版本：added 新增 / changed 换了版本 / null = 不变 */
  change: "added" | "changed" | null;
  previous_version: string | null;
}

export interface PackageDependencies {
  /** 锁文件内容哈希：批准时原样交回表示同意这一份依赖 */
  lock_digest: string;
  packages: PackageDependency[];
  total_size: number;
  native: string[];
  unavailable: string[];
  removed: string[];
  index: string;
  index_label: string;
  /** 锁文件与已批准的不同（或首次安装） */
  needs_consent: boolean;
}

export interface DependencyProgress {
  /** installing 正在安装 / failed 安装失败（可重试） */
  phase: "installing" | "failed";
  done: number;
  total: number;
  error: string | null;
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
  /** 插件会发出的事件（别的插件、Webhook 能订）；旧服务端没有这些字段 */
  events?: { name: string; title: string }[];
  /** 插件会发的通知：发给谁、写什么 */
  notifications?: PluginNotification[];
  /** 要订阅的敏感事件（谁在什么时候看了什么） */
  sensitive_events?: string[];
  /** 会给普通成员发通知：批准时须单独确认 */
  notifies_members?: boolean;
  requires: Record<string, string>;
  installed_version: string | null;
  /** 与随带的内置插件同 id：安装即替换它，卸载后随带版本回来；旧服务端没有这个字段 */
  replaces_builtin?: boolean;
  /** 要下载安装的第三方包；没有依赖或旧服务端为空 */
  dependencies?: PackageDependencies | null;
  /** 批准后正在安装依赖时的进度 */
  dependency_progress?: DependencyProgress | null;
  /** 带网页：侧边栏入口预览（图标是内嵌的 SVG）；批准时须单独同意授信运行。旧服务端没有这个字段 */
  web?: PendingWebPage | null;
  /** 入口模块；空串 = 没有后端代码（只带网页 / 主题）。旧服务端没有这个字段 */
  entry?: string;
  /** 网页主题：外观选择卡预览；带外框组件（has_code）的批准时须单独同意。旧服务端没有这个字段 */
  theme?: PendingTheme | null;
}

/** 待批准的网页主题（docs/design/theme-plugins.md §4.6） */
export interface PendingTheme {
  label: string;
  description: string;
  preview: { bg: string; accent: string };
  layout: string;
  glass: boolean;
  /** 带外框组件（JS）：代码以使用者的身份在每个页面里运行 */
  has_code: boolean;
}

/** 插件网页的一项侧边栏入口（与 lib/plugin-apps.ts 的 PluginAppEntry 同形） */
export interface WebPageEntry {
  label: string;
  path: string;
  icon: string | null;
  monochrome: boolean;
}

export interface PendingWebPage {
  id: string;
  name: string;
  base: string;
  entries: WebPageEntry[];
}

/** 一个带网页的插件（插件包或本地插件），不论是否已同意 */
export interface WebPage {
  id: string;
  name: string;
  /** package：插件包；local：本地插件 */
  source: string;
  /** 已同意授信运行；没同意的不托管、不进侧边栏 */
  approved: boolean;
  nav: boolean;
  members: boolean;
  base: string;
  entries: WebPageEntry[];
}

export interface WebConsent {
  /** 加到侧边栏 */
  nav: boolean;
  /** 成员也能看到 */
  members: boolean;
}

/** 带网页的插件；旧服务端没有这个接口时返回空列表 */
export async function listWebPages(): Promise<WebPage[]> {
  try {
    return (await request<ApiEnvelope<WebPage[]>>("/app/plugins/pages")).data;
  } catch {
    return [];
  }
}

/** 同意插件网页授信运行，或改它加不加侧边栏、成员能不能看到（只能由人在网页里操作） */
export async function setWebConsent(id: string, consent: WebConsent): Promise<WebPage> {
  return (
    await request<ApiEnvelope<WebPage>>(`/app/plugins/${encodeURIComponent(id)}/web`, {
      method: "PUT",
      body: JSON.stringify(consent),
    })
  ).data;
}

/** 撤销插件网页的同意：不再托管、从侧边栏撤下 */
export async function revokeWebConsent(id: string): Promise<void> {
  await request<ApiEnvelope<null>>(`/app/plugins/${encodeURIComponent(id)}/web`, {
    method: "DELETE",
  });
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
  /** 批准安装的第三方依赖；progress 在安装中或安装失败时才有 */
  dependencies?: { packages: string[]; progress: DependencyProgress | null } | null;
  /** 插件网页的同意；不带网页、没同意或旧服务端为空 */
  web?: WebConsent | null;
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

/** 批准：宿主操作与路径须与插件申请的完全一致（显式同意），进程内运行须 allowInline，
 * 会给普通成员发通知的须 allowMemberNotifications，带网页的须给 web（同意授信运行），
 * 带外框组件的主题须 allowTheme；
 * 批准页列出了依赖，批准即同意那一份锁文件 */
export async function approvePackage(
  pending: PackageRequest,
  allowInline: boolean,
  allowMemberNotifications = false,
  web: WebConsent | null = null,
  allowTheme = false,
): Promise<PackageResult> {
  return thenRefreshThemes(
    (async () => {
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
              allow_member_notifications: allowMemberNotifications,
              dependencies: pending.dependencies?.lock_digest ?? null,
              ...(web ? { allow_web: true, web_nav: web.nav, web_members: web.members } : {}),
              ...(allowTheme ? { allow_theme: true } : {}),
            }),
          },
        )
      ).data;
    })(),
  );
}

export async function discardPackage(id: string): Promise<void> {
  await request<ApiEnvelope<null>>(
    `/app/plugins/packages/${encodeURIComponent(id)}/pending`,
    { method: "DELETE" },
  );
}

export async function rollbackPackage(id: string): Promise<PackageResult> {
  return thenRefreshThemes(
    (async () => {
      return (
        await request<ApiEnvelope<PackageResult>>(
          `/app/plugins/packages/${encodeURIComponent(id)}/rollback`,
          { method: "POST" },
        )
      ).data;
    })(),
  );
}

/** 依赖没装好（启动时补装失败）：按已批准的锁文件再装一次，装好即加载 */
export async function retryPackageDependencies(id: string): Promise<PackageResult> {
  return (
    await request<ApiEnvelope<PackageResult>>(
      `/app/plugins/packages/${encodeURIComponent(id)}/dependencies/retry`,
      { method: "POST" },
    )
  ).data;
}

export async function uninstallPackage(id: string, purgeData: boolean): Promise<number> {
  return thenRefreshThemes(
    (async () => {
      return (
        await request<ApiEnvelope<{ purged_rows: number }>>(
          `/app/plugins/packages/${encodeURIComponent(id)}?purge_data=${purgeData}`,
          { method: "DELETE" },
        )
      ).data.purged_rows;
    })(),
  );
}

/* —— 插件详情（设置 → 插件 → 点一个插件） —— */

/** 装了这个插件，系统多了什么（已翻成人话） */
/** 停用 / 启用插件（官方插件与插件包）：运行中生效，重启后保持；停用会取消它的后台任务 */
export async function setPluginEnabled(id: string, enabled: boolean): Promise<void> {
  return thenRefreshThemes(
    (async () => {
      await request(`/app/plugins/${encodeURIComponent(id)}/enabled`, {
        method: "PUT",
        body: JSON.stringify({ enabled }),
      });
    })(),
  );
}

/** 卸载官方插件（代码随应用携带，随时能恢复）；返回删除的数据行数 */
export async function uninstallBundled(id: string, purgeData: boolean): Promise<number> {
  return thenRefreshThemes(
    (async () => {
      return (
        await request<ApiEnvelope<{ cancelled_jobs: number; purged_rows: number }>>(
          `/app/plugins/${encodeURIComponent(id)}/bundled?purge_data=${purgeData}`,
          { method: "DELETE" },
        )
      ).data.purged_rows;
    })(),
  );
}

/** 恢复卸载了的官方插件：当场加载 */
export async function restoreBundled(id: string): Promise<void> {
  return thenRefreshThemes(
    (async () => {
      await request(`/app/plugins/${encodeURIComponent(id)}/bundled/restore`, { method: "POST" });
    })(),
  );
}

export interface PluginAdded {
  /** channel / task / ingest / job / site / command / trigger / decision / event / notification */
  kind: string;
  title: string;
  detail: string;
  /** 去哪里看 / 调整（站内路径） */
  href: string | null;
}

export interface PluginDurableConsumer {
  consumer_id: string;
  /** 订阅的事件（一个消费者可订阅多个，按产生顺序投递） */
  events: string[];
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

// ---------------------------------------------------------------------------
// 插件市场（设置 → 插件 → 插件市场；services/plugin_market.py）
// 数据来自 movieclaw-plugins 仓库的签名索引；安装 = 服务器下载核对后放进待批准，批准沿用上面那套。
// ---------------------------------------------------------------------------

export type MarketCategory = "storage" | "downloader" | "messaging" | "sites" | "library" | "tools";

export interface MarketPermissions {
  operations: string[];
  paths: PathGrant[];
  network: boolean;
  callbacks: string[];
  /** 要订阅的敏感事件（谁在什么时候看了什么） */
  events: string[];
}

export interface MarketVersion {
  version: string;
  prerelease: boolean;
  released_at: string | null;
  /** 已撤回：原因 */
  yanked: string | null;
  /** 这一版的更新说明（markdown） */
  notes: string;
  changelog_url: string | null;
  source_url: string | null;
  runtime: string;
  requires: Record<string, string>;
  permissions: MarketPermissions;
  web: boolean;
  dependencies: { name: string; version: string; native: boolean }[];
  /** 这台服务器要下载的插件包字节数 */
  size: number | null;
  compatible: boolean;
  incompatible_reason: string | null;
}

export interface MarketInstalled {
  version: string;
  /** package：插件包；bundled：随应用提供 */
  source: "package" | "bundled";
  state: string;
  previous_version: string | null;
  yanked: string | null;
}

export interface MarketPlugin {
  id: string;
  name: string;
  summary: string;
  description: string;
  category: MarketCategory | string;
  author: { name: string; url: string | null };
  homepage: string | null;
  repository: string | null;
  /** 反馈问题的地址；索引没写时为空 */
  feedback_url: string | null;
  /** 累计下载次数；索引没写时为空 */
  downloads: number | null;
  /** 经本服务器代理的截图；没有时为空列表 */
  screenshots: string[];
  license: string;
  icon_url: string | null;
  deprecated: { reason: string; replaced_by: string | null } | null;
  latest: string | null;
  /** 该装的那一版（能装、没撤回的最新正式版；装着测试版或没有正式版时含测试版） */
  recommended: string | null;
  installed: MarketInstalled | null;
  /** 有更新时是要升到的版本 */
  update: string | null;
  /** 不能安装的原因 */
  blocked: string | null;
  versions: MarketVersion[];
}

export interface MarketPluginDetail extends MarketPlugin {
  selected: string | null;
  readme: string | null;
  readme_error: string | null;
  dependencies: PackageDependencies | null;
}

export interface MarketSource {
  url: string;
  repository: string | null;
  generated_at: string | null;
  signed: boolean;
  checked_at: string;
  /** 最近一次检查失败：用的是旧索引 */
  error: string | null;
}

export interface MarketOverview {
  source: MarketSource;
  plugins: MarketPlugin[];
  updates: number;
}

export async function listMarket(): Promise<MarketOverview> {
  return (await request<ApiEnvelope<MarketOverview>>("/app/plugins/market")).data;
}

/** 立即重新获取索引（检查更新）；GitHub 连不上时报错 */
export async function refreshMarket(): Promise<MarketOverview> {
  return (
    await request<ApiEnvelope<MarketOverview>>("/app/plugins/market/refresh", { method: "POST" })
  ).data;
}

export async function getMarketPlugin(id: string, version?: string): Promise<MarketPluginDetail> {
  const query = version ? `?version=${encodeURIComponent(version)}` : "";
  return (
    await request<ApiEnvelope<MarketPluginDetail>>(
      `/app/plugins/market/${encodeURIComponent(id)}${query}`,
    )
  ).data;
}

/** 服务器下载并核对这一版，放进待批准；返回值直接交给批准抽屉 */
export async function installFromMarket(id: string, version: string): Promise<PackageRequest> {
  return (
    await request<ApiEnvelope<PackageRequest>>(
      `/app/plugins/market/${encodeURIComponent(id)}/install`,
      { method: "POST", body: JSON.stringify({ version }) },
    )
  ).data;
}
