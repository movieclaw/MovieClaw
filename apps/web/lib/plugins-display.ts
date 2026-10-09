/**
 * 「设置 → 插件」的展示口径（docs/design/plugin-kernel.md §10.2、plugin-page-tiers.md）。
 *
 * 概念：「插件」是总称。MovieClaw 自带的功能都是内置插件，按用户能做什么分三层：功能（用户能感知的
 * 可选功能）、官方插件（随应用提供、可用插件包替换）、系统模块（应用运行所需，平时不展示，出问题才浮出）。
 * 第三方插件由插件包（.mcplugin）安装；本地插件是你在 data/plugins.yaml 里开启的自己的代码。
 *
 * 纯逻辑，单独成文件好用测试锁住（test/plugins-display.test.mjs）：状态 → 文案与颜色、
 * 「为什么没起来」的一句话、哪些需要留意、分层与功能状态汇总。这里的措辞直接上屏。
 */

import type {
  InstalledPackage,
  PathGrant,
  PluginFeature,
  PluginInfo,
  PluginState,
  PluginTier,
} from "@/lib/api/plugins";
import type { Tone } from "@/lib/cloud-push-display";

const STATE_LABEL: Record<PluginState, string> = {
  active: "运行中",
  failed: "启动失败",
  pending: "等待依赖",
  disabled: "已关闭",
  incompatible: "版本不兼容",
  loading: "启动中",
  unloading: "停止中",
  disposed: "已停止",
};

const STATE_TONE: Record<PluginState, Tone> = {
  active: "ok",
  failed: "danger",
  pending: "warn",
  disabled: "neutral",
  incompatible: "danger",
  loading: "info",
  unloading: "info",
  disposed: "neutral",
};

export function pluginStateLabel(state: PluginState): string {
  return STATE_LABEL[state] ?? state;
}

export function pluginStateTone(state: PluginState): Tone {
  return STATE_TONE[state] ?? "neutral";
}

/** 插件自己报告的降级（令牌过期、外部系统连不上……） */
export function degradedHealth(plugin: PluginInfo): string[] {
  return (plugin.health ?? []).filter((h) => !h.ok).map((h) => h.message);
}

/** 等依赖、但依赖是被有意关掉的（环境变量、plugins.yaml）：跟着关闭，不是故障 */
export function offWithDependency(plugin: PluginInfo): boolean {
  return (
    plugin.state === "pending" &&
    plugin.blocked_by.length > 0 &&
    plugin.blocked_by.every((b) => b.provider_state === "disabled")
  );
}

/** 展示用的状态：跟着依赖关闭的算「已关闭」 */
export function displayState(plugin: PluginInfo): PluginState {
  return offWithDependency(plugin) ? "disabled" : plugin.state;
}

/** 需要管理员留意的状态：失败、不兼容、等待依赖、运行中报告降级（关闭是有意为之，不算；跟着依赖关闭的也不算） */
export function needsAttention(plugin: PluginInfo): boolean {
  return (
    plugin.state === "failed" ||
    plugin.state === "incompatible" ||
    (plugin.state === "pending" && !offWithDependency(plugin)) ||
    (plugin.state === "active" && degradedHealth(plugin).length > 0)
  );
}

function disabledByText(source: string | null): string {
  if (!source) return "已关闭";
  if (source === "patch") return "已在插件补丁（data/plugins.yaml）中关闭";
  if (source.startsWith("env:")) return `已按环境变量 ${source.slice(4)} 关闭`;
  return "已关闭";
}

/** 行内说明：没起来的写原因，起来的写启动耗时 */
export function pluginDetail(plugin: PluginInfo): string {
  switch (plugin.state) {
    case "failed":
      return plugin.error ?? "启动失败，原因未知";
    case "incompatible":
      return plugin.incompatible ?? "与当前版本不兼容";
    case "pending": {
      if (offWithDependency(plugin)) {
        return `依赖的 ${plugin.blocked_by.map((b) => b.provider ?? b.key).join("、")} 已关闭，跟着停用`;
      }
      if (plugin.blocked_by.length === 0) return "等待所依赖的插件就绪";
      return plugin.blocked_by.map((b) => `缺少 ${b.key}：${b.reason}`).join("；");
    }
    case "disabled":
      return disabledByText(plugin.disabled_by);
    case "active": {
      const degraded = degradedHealth(plugin);
      if (degraded.length > 0) return `运行异常：${degraded.join("；")}`;
      const parts: string[] = [];
      if (plugin.apply_ms !== null) parts.push(`启动 ${formatMs(plugin.apply_ms)}`);
      if (plugin.stats.tasks > 0) parts.push(`${plugin.stats.tasks} 个后台任务`);
      if (plugin.stats.failures + plugin.stats.timeouts > 0) {
        parts.push(`运行中出错 ${plugin.stats.failures + plugin.stats.timeouts} 次`);
      }
      return parts.join(" · ");
    }
    default:
      return pluginStateLabel(plugin.state);
  }
}

export function formatMs(ms: number): string {
  if (ms >= 1000) return `${(ms / 1000).toFixed(ms >= 10_000 ? 0 : 1)} 秒`;
  return `${Math.max(0, Math.round(ms))} 毫秒`;
}

/** 列表顺序：需要留意的在前，其余保持服务器给的顺序（即启动顺序） */
export function sortPlugins(plugins: PluginInfo[]): PluginInfo[] {
  const attention = plugins.filter(needsAttention);
  const rest = plugins.filter((p) => !needsAttention(p));
  return [...attention, ...rest];
}

/** MovieClaw 自带的内置插件 */
export function isBuiltinPlugin(plugin: PluginInfo): boolean {
  return plugin.source === "builtin";
}

/** 插件页分层；旧服务端没有分层时内置插件一律当系统模块 */
export function pluginTier(plugin: PluginInfo): PluginTier | null {
  if (plugin.tier) return plugin.tier;
  return isBuiltinPlugin(plugin) ? "system" : null;
}

/** 系统模块：应用运行所需，平时不展示 */
export function systemModules(plugins: PluginInfo[]): PluginInfo[] {
  return plugins.filter((p) => pluginTier(p) === "system");
}

/** 官方插件：随应用提供、可用插件包替换的（含替换它们的插件包）；通道中枢只在出问题时露面 */
export function officialPlugins(plugins: PluginInfo[]): PluginInfo[] {
  return plugins.filter(
    (p) => pluginTier(p) === "official" && (p.provides.length === 0 || needsAttention(p)),
  );
}

/** 官方插件这一行的来源说明 */
export function officialSourceText(plugin: PluginInfo): string {
  return isBuiltinPlugin(plugin) ? "内置版本，可用插件包替换" : "已被插件包替换，在「第三方插件」里管理";
}

export interface FeatureStatus {
  label: string;
  tone: Tone;
  /** 不正常时写清是哪个组成部分、为什么；正常时为 null */
  detail: string | null;
}

/** 功能的状态：由组成它的内置插件汇总（任一出问题即异常，全部关闭才算关闭） */
export function featureStatus(feature: PluginFeature, plugins: PluginInfo[]): FeatureStatus {
  const members = plugins.filter(
    (p) => feature.entries.includes(p.id) || (p.parent !== null && feature.entries.includes(p.parent)),
  );
  if (members.length === 0) return { label: "未加载", tone: "neutral", detail: null };
  const problem = members.find(needsAttention);
  if (problem) {
    const label = problem.state === "active" ? "运行异常" : pluginStateLabel(problem.state);
    const tone = problem.state === "pending" || problem.state === "active" ? "warn" : "danger";
    return { label, tone, detail: `${problem.title}：${pluginDetail(problem)}` };
  }
  if (members.every((p) => displayState(p) === "disabled")) {
    return { label: "已关闭", tone: "neutral", detail: pluginDetail(members[0]) };
  }
  const off = members.find((p) => displayState(p) === "disabled");
  if (off) return { label: "部分关闭", tone: "neutral", detail: `${off.title}：${pluginDetail(off)}` };
  const busy = members.find((p) => p.state !== "active");
  if (busy) return { label: pluginStateLabel(busy.state), tone: pluginStateTone(busy.state), detail: null };
  return { label: "运行中", tone: "ok", detail: null };
}

/** 页面底部系统模块入口那一行：一共几个、是否都正常 */
export function systemModulesLine(modules: PluginInfo[]): { text: string; tone: Tone } {
  const problems = modules.filter(needsAttention).length;
  if (problems > 0) {
    return { text: `另有 ${modules.length} 个系统模块，其中 ${problems} 个需要留意`, tone: "warn" };
  }
  return { text: `另有 ${modules.length} 个系统模块，运行正常`, tone: "ok" };
}

/** 「查看日志」：系统日志页按条目 id 预填筛选 */
export function pluginLogsHref(plugin: PluginInfo): string {
  return `/settings/logs?q=${encodeURIComponent(plugin.id)}`;
}

export interface PluginGroup {
  label: string;
  plugins: PluginInfo[];
}

/**
 * 内置插件按功能分组：组序与归属由服务器给（groups / group）；没有归属的（旧服务端，
 * 或新插件漏了归组）收进末尾的「其他」。组内需要留意的在前。
 */
export function groupBuiltins(plugins: PluginInfo[], groups: string[] = []): PluginGroup[] {
  const builtins = plugins.filter(isBuiltinPlugin);
  const known = new Set(groups);
  const result = groups.map((label) => ({
    label,
    plugins: sortPlugins(builtins.filter((p) => p.group === label)),
  }));
  const other = builtins.filter((p) => !p.group || !known.has(p.group));
  if (other.length > 0) result.push({ label: "其他", plugins: sortPlugins(other) });
  return result.filter((group) => group.plugins.length > 0);
}

/** 用户在 plugins.yaml 里开启的本地受信插件（进程内运行，权限与主程序相同） */
export function isLocalPlugin(plugin: PluginInfo): boolean {
  return plugin.source === "local";
}

/** 本地插件里有几个在主进程里运行（与主程序同权限）、几个在独立进程里运行 */
export function localPluginRuntimes(plugins: PluginInfo[]): { inline: number; process: number } {
  const locals = plugins.filter(isLocalPlugin);
  const process = locals.filter((p) => p.runtime === "process").length;
  return { inline: locals.length - process, process };
}

/** 系统模块清单的概况：一共几个、几个在运行、几个出问题、几个已关闭 */
export function pluginsSummary(plugins: PluginInfo[]): string {
  const active = plugins.filter((p) => p.state === "active").length;
  const problems = plugins.filter(needsAttention).length;
  const disabled = plugins.filter((p) => p.state === "disabled").length;
  const parts = [`${plugins.length} 个系统模块`, `${active} 个运行中`];
  if (problems > 0) parts.push(`${problems} 个需要留意`);
  if (disabled > 0) parts.push(`${disabled} 个已关闭`);
  return parts.join(" · ");
}

/** 启动最慢的几个（排查「启动为什么慢」用） */
export function slowestStarts(plugins: PluginInfo[], limit = 3): PluginInfo[] {
  return plugins
    .filter((p) => p.apply_ms !== null && p.apply_ms >= 100)
    .sort((a, b) => (b.apply_ms ?? 0) - (a.apply_ms ?? 0))
    .slice(0, limit);
}

// ---------------------------------------------------------------- 插件包（管理页）

/** 路径授权 → 给人看的说明（别名见 docs/design/plugin-phase3.md §6.2） */
export function pathGrantLabel(grant: PathGrant): string {
  const mode = grant.mode === "rw" ? "读写" : "只读";
  const path = grant.path;
  let where: string;
  if (path === "library") where = "全部媒体库";
  else if (path.startsWith("library:")) where = `媒体库 #${path.slice("library:".length)}`;
  else if (path === "staging") where = "导入规则的自定义目录";
  else if (path === "plugin") where = "插件自己的目录";
  else where = path;
  return `${where}（${mode}）`;
}

/** 运行方式：独立进程是默认且安全的；主进程运行与主程序同权限 */
export function runtimeLabel(runtime: string | undefined): string {
  return runtime === "inline" ? "主进程（与主程序同权限）" : "独立进程";
}

/** 升级时新增的申请：批准页高亮 */
export function isNewGrant(item: PathGrant, added: PathGrant[]): boolean {
  return added.some((p) => p.path === item.path && p.mode === item.mode);
}

/** 已安装插件包的行内说明：版本、运行方式、权限规模、坏版本、宽限期 */
export function packageDetail(item: InstalledPackage): string {
  const parts = [`v${item.version}`, runtimeLabel(item.runtime)];
  if (item.replaces_builtin) parts.push("替换了内置版本，卸载即恢复");
  if (item.operations.length) parts.push(`${item.operations.length} 个宿主操作`);
  if (item.paths.length) parts.push(`${item.paths.length} 个目录授权`);
  if (item.watching) parts.push("刚安装，观察中");
  if (item.bad_versions.length) parts.push(`已拦下的坏版本：${item.bad_versions.join("、")}`);
  return parts.join(" · ");
}
