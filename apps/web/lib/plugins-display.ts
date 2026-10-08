/**
 * 「模块」页签的展示口径（docs/design/plugin-kernel.md §10.2）。
 *
 * 纯逻辑，单独成文件好用测试锁住（test/plugins-display.test.mjs）：状态 → 文案与颜色、
 * 「为什么没起来」的一句话、哪些需要留意、列表排序。这里的措辞直接上屏。
 */

import type { PluginInfo, PluginState } from "@/lib/api/plugins";
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

/** 需要管理员留意的状态：失败、不兼容、等待依赖（关闭是有意为之，不算） */
export function needsAttention(plugin: PluginInfo): boolean {
  return plugin.state === "failed" || plugin.state === "incompatible" || plugin.state === "pending";
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
      if (plugin.blocked_by.length === 0) return "等待所依赖的模块就绪";
      return plugin.blocked_by.map((b) => `缺少 ${b.key}：${b.reason}`).join("；");
    }
    case "disabled":
      return disabledByText(plugin.disabled_by);
    case "active": {
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

/** 用户在 plugins.yaml 里开启的本地受信插件（进程内运行，权限与主程序相同） */
export function isLocalPlugin(plugin: PluginInfo): boolean {
  return plugin.source === "local";
}

/** 分区副标题：一共几个、几个在运行、几个出问题、几个是本地插件 */
export function pluginsSummary(plugins: PluginInfo[]): string {
  const active = plugins.filter((p) => p.state === "active").length;
  const problems = plugins.filter(needsAttention).length;
  const disabled = plugins.filter((p) => p.state === "disabled").length;
  const local = plugins.filter(isLocalPlugin).length;
  const parts = [`${plugins.length} 个模块`, `${active} 个运行中`];
  if (problems > 0) parts.push(`${problems} 个需要留意`);
  if (disabled > 0) parts.push(`${disabled} 个已关闭`);
  if (local > 0) parts.push(`其中 ${local} 个是本地插件`);
  return parts.join(" · ");
}

/** 启动最慢的几个（排查「启动为什么慢」用） */
export function slowestStarts(plugins: PluginInfo[], limit = 3): PluginInfo[] {
  return plugins
    .filter((p) => p.apply_ms !== null && p.apply_ms >= 100)
    .sort((a, b) => (b.apply_ms ?? 0) - (a.apply_ms ?? 0))
    .slice(0, limit);
}
