import { appTranslator, type AppMessageKey } from "./i18n/translate.ts";
import { requestLocale, type AppLocale } from "./i18n/negotiate.ts";
import { formatList } from "./i18n/format.ts";

/**
 * 「设置 → 插件」的展示口径（docs/design/plugin-kernel.md §10.2、plugin-page-tiers.md）。
 *
 * 概念：「插件」是总称。MovieClaw 自带的功能都是内置插件，插件页只展示官方插件（随应用提供、可用插件包
 * 替换）；其余是系统模块（应用运行所需，平时不展示，出问题才浮出）。
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

const STATE_LABEL: Record<PluginState, AppMessageKey> = {
  active: "settings.pluginDisplay.active",
  failed: "settings.pluginDisplay.failed",
  pending: "settings.pluginDisplay.pending",
  disabled: "settings.pluginDisplay.disabled",
  incompatible: "settings.pluginDisplay.incompatible",
  loading: "settings.pluginDisplay.loading",
  unloading: "settings.pluginDisplay.unloading",
  disposed: "settings.pluginDisplay.disposed",
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

export function pluginStateLabel(state: PluginState, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const key = STATE_LABEL[state];
  return key ? t(key) : state;
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

function disabledByText(source: string | null, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  if (!source) return t("settings.pluginDisplay.disabled");
  if (source === "switch") return t("settings.pluginDisplay.switchedOff");
  if (source.startsWith("feature:")) return t("settings.pluginDisplay.featureDisabled");
  if (source === "patch") return t("settings.pluginDisplay.patchDisabled");
  if (source.startsWith("env:")) return t("settings.pluginDisplay.envDisabled", { name: source.slice(4) });
  return t("settings.pluginDisplay.disabled");
}

/** 行内说明：没起来的写原因，起来的写启动耗时 */
export function pluginDetail(plugin: PluginInfo, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  switch (plugin.state) {
    case "failed":
      return plugin.error ?? t("settings.pluginDisplay.failedUnknown");
    case "incompatible":
      return plugin.incompatible ?? t("settings.pluginDisplay.versionMismatch");
    case "pending": {
      if (offWithDependency(plugin)) {
        return t("settings.pluginDisplay.dependencyDisabled", { names: formatList(plugin.blocked_by.map((b) => b.provider ?? b.key), locale) });
      }
      if (plugin.blocked_by.length === 0) return t("settings.pluginDisplay.waitingDependencies");
      return plugin.blocked_by.map((b) => t("settings.pluginDisplay.missingDependency", { name: b.key, reason: b.reason })).join(t("settings.pluginDisplay.reasonSeparator"));
    }
    case "disabled":
      return disabledByText(plugin.disabled_by, locale);
    case "active": {
      const degraded = degradedHealth(plugin);
      if (degraded.length > 0) return t("settings.pluginDisplay.degraded", { reasons: degraded.join(t("settings.pluginDisplay.reasonSeparator")) });
      const parts: string[] = [];
      if (plugin.apply_ms !== null) parts.push(t("settings.pluginDisplay.startTime", { time: formatMs(plugin.apply_ms, locale) }));
      if (plugin.stats.tasks > 0) parts.push(t("settings.pluginDisplay.backgroundTasks", { count: plugin.stats.tasks }));
      if (plugin.stats.failures + plugin.stats.timeouts > 0) {
        parts.push(t("settings.pluginDisplay.runtimeErrors", { count: plugin.stats.failures + plugin.stats.timeouts }));
      }
      return parts.join(" · ");
    }
    default:
      return pluginStateLabel(plugin.state, locale);
  }
}

export function formatMs(ms: number, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  if (ms >= 1000) return t("settings.pluginDisplay.seconds", { value: (ms / 1000).toFixed(ms >= 10_000 ? 0 : 1) });
  return t("settings.pluginDisplay.milliseconds", { value: Math.max(0, Math.round(ms)) });
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
export function officialSourceText(plugin: PluginInfo, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  return isBuiltinPlugin(plugin) ? t("settings.pluginDisplay.builtinSource") : t("settings.pluginDisplay.replacedSource");
}

/** 功能停用了（经功能开关接口，或管理员在 plugins.yaml / 环境变量里关掉） */
export function featureOff(feature: PluginFeature): boolean {
  return feature.enabled === false;
}

/** 停用的说明：被管理员硬覆盖关掉的写原因，开关停用的写是谁停的 */
export function featureOffText(feature: PluginFeature, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  if (feature.locked_by) return feature.locked_by;
  return feature.changed_by ? t("settings.pluginDisplay.disabledBy", { name: feature.changed_by }) : t("settings.pluginDisplay.switchedOff");
}

/** 页面底部系统模块入口那一行：一共几个、是否都正常 */
export function systemModulesLine(modules: PluginInfo[], locale: AppLocale = requestLocale() ?? "zh-Hans"): { text: string; tone: Tone } {
  const t = appTranslator(locale);
  const problems = modules.filter(needsAttention).length;
  if (problems > 0) {
    return { text: t("settings.pluginDisplay.systemProblems", { total: modules.length, problems }), tone: "warn" };
  }
  return { text: t("settings.pluginDisplay.systemsHealthy", { count: modules.length }), tone: "ok" };
}

/** 「查看日志」：系统日志页按条目 id 预填筛选 */
/** 插件详情页（设置 → 插件 → 点一个插件） */
export function pluginHref(id: string): string {
  return `/settings/plugins/${encodeURIComponent(id)}`;
}

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
export function groupBuiltins(plugins: PluginInfo[], groups: string[] = [], locale: AppLocale = requestLocale() ?? "zh-Hans"): PluginGroup[] {
  const t = appTranslator(locale);
  const builtins = plugins.filter(isBuiltinPlugin);
  const known = new Set(groups);
  const result = groups.map((label) => ({
    label,
    plugins: sortPlugins(builtins.filter((p) => p.group === label)),
  }));
  const other = builtins.filter((p) => !p.group || !known.has(p.group));
  if (other.length > 0) result.push({ label: t("settings.pluginDisplay.other"), plugins: sortPlugins(other) });
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
export function pluginsSummary(plugins: PluginInfo[], locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const active = plugins.filter((p) => p.state === "active").length;
  const problems = plugins.filter(needsAttention).length;
  const disabled = plugins.filter((p) => p.state === "disabled").length;
  const parts = [t("settings.pluginDisplay.systemCount", { count: plugins.length }), t("settings.pluginDisplay.activeCount", { count: active })];
  if (problems > 0) parts.push(t("settings.pluginDisplay.problemCount", { count: problems }));
  if (disabled > 0) parts.push(t("settings.pluginDisplay.disabledCount", { count: disabled }));
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
export function pathGrantLabel(grant: PathGrant, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const mode = grant.mode === "rw" ? t("settings.pluginDisplay.readWrite") : t("settings.pluginDisplay.readOnly");
  const path = grant.path;
  let where: string;
  if (path === "library") where = t("settings.pluginDisplay.allLibraries");
  else if (path.startsWith("library:")) where = t("settings.pluginDisplay.libraryNumber", { id: path.slice("library:".length) });
  else if (path === "staging") where = t("settings.pluginDisplay.stagingFolders");
  else if (path === "plugin") where = t("settings.pluginDisplay.pluginFolder");
  else where = path;
  return t("settings.pluginDisplay.pathGrant", { path: where, mode });
}

/** 运行方式：独立进程是默认且安全的；主进程运行与主程序同权限 */
export function runtimeLabel(runtime: string | undefined, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  return runtime === "inline" ? t("settings.pluginDisplay.inlineRuntime") : t("settings.pluginDisplay.processRuntime");
}

/** 升级时新增的申请：批准页高亮 */
export function isNewGrant(item: PathGrant, added: PathGrant[]): boolean {
  return added.some((p) => p.path === item.path && p.mode === item.mode);
}

/** 已安装插件包的行内说明：版本、运行方式、权限规模、坏版本、宽限期 */
export function packageDetail(item: InstalledPackage, locale: AppLocale = requestLocale() ?? "zh-Hans"): string {
  const t = appTranslator(locale);
  const parts = [`v${item.version}`, runtimeLabel(item.runtime, locale)];
  if (item.replaces_builtin) parts.push(t("settings.pluginDisplay.replacesBuiltin"));
  if (item.operations.length) parts.push(t("settings.pluginDisplay.operationCount", { count: item.operations.length }));
  if (item.paths.length) parts.push(t("settings.pluginDisplay.pathCount", { count: item.paths.length }));
  const deps = item.dependencies;
  if (deps?.progress?.phase === "installing") {
    parts.push(
      deps.progress.total
        ? t("settings.pluginDisplay.installingDependencies", { done: deps.progress.done, total: deps.progress.total })
        : t("settings.pluginDisplay.preparingDependencies"),
    );
  } else if (deps) {
    parts.push(t("settings.pluginDisplay.packageCount", { count: deps.packages.length }));
  }
  if (item.watching) parts.push(t("settings.pluginDisplay.watching"));
  if (item.bad_versions.length) parts.push(t("settings.pluginDisplay.badVersions", { versions: formatList(item.bad_versions, locale) }));
  return parts.join(" · ");
}
