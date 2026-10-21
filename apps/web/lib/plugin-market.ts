/**
 * 插件市场的展示口径（设置 → 插件 → 插件市场）。纯逻辑，单独成文件好用测试锁住
 * （test/plugin-market.test.mjs）：分类与筛选、一张卡片该给什么按钮、版本的标记、权限翻成人话。
 * 这里的措辞直接上屏。
 *
 * 推荐哪一版、有没有更新、能不能装由服务端算（MarketPlugin.recommended / update / blocked、
 * MarketVersion.compatible），这里只负责怎么说。
 */

import type { MarketPlugin, MarketVersion, PluginState } from "./api/plugins";
import type { Tone } from "./cloud-push-display";
import { formatBytes } from "./format.ts";
import { pluginStateLabel, pluginStateTone } from "./plugins-display.ts";

export const CATEGORY_LABELS: Record<string, string> = {
  storage: "网盘",
  downloader: "下载器",
  messaging: "消息通道",
  sites: "站点",
  library: "媒体库",
  tools: "工具",
};

export function categoryLabel(category: string): string {
  return CATEGORY_LABELS[category] ?? "其他";
}

/** 筛选条：只列有插件的分类（固定顺序），只有一个分类时不出筛选条 */
export function marketCategories(plugins: MarketPlugin[]): { id: string; label: string }[] {
  const present = new Set(plugins.map((p) => p.category));
  const known = Object.keys(CATEGORY_LABELS).filter((id) => present.has(id));
  const other = [...present].filter((id) => !(id in CATEGORY_LABELS)).sort();
  const all = [...known, ...other];
  if (all.length < 2) return [];
  return [{ id: "all", label: "全部" }, ...all.map((id) => ({ id, label: categoryLabel(id) }))];
}

export function filterMarket(
  plugins: MarketPlugin[],
  { category, query }: { category: string; query: string },
): MarketPlugin[] {
  const q = query.trim().toLowerCase();
  return plugins.filter((p) => {
    if (category !== "all" && p.category !== category) return false;
    if (!q) return true;
    return [p.name, p.id, p.summary, p.author.name].some((text) => text.toLowerCase().includes(q));
  });
}

export type MarketActionKind =
  | "install"
  | "update"
  | "installed"
  | "bundled"
  | "blocked"
  | "incompatible"
  | "unavailable";

export interface MarketAction {
  kind: MarketActionKind;
  /** 按钮上的字（install / update 才有按钮） */
  label: string;
  /** 点了要装的版本 */
  version: string | null;
  /** 没有按钮时的说明 */
  note: string | null;
}

/** 卡片 / 详情上的主操作 */
export function marketAction(plugin: MarketPlugin): MarketAction {
  if (plugin.blocked) {
    return { kind: "blocked", label: "", version: null, note: plugin.blocked };
  }
  if (plugin.installed) {
    if (plugin.update) {
      return { kind: "update", label: "更新", version: plugin.update, note: null };
    }
    if (plugin.installed.source === "bundled") {
      return { kind: "bundled", label: "", version: null, note: "随应用提供" };
    }
    return { kind: "installed", label: "", version: null, note: "已安装" };
  }
  if (plugin.recommended) {
    return { kind: "install", label: "安装", version: plugin.recommended, note: null };
  }
  const reason = plugin.versions.find((v) => !v.compatible)?.incompatible_reason;
  if (plugin.versions.length > 0 && plugin.versions.every((v) => !v.compatible)) {
    return { kind: "incompatible", label: "", version: null, note: reason ?? "本机装不了" };
  }
  return { kind: "unavailable", label: "", version: null, note: "没有可安装的版本" };
}

/** 卡片上显示的版本：推荐的那一版，没有就是最新一版 */
export function shownVersion(plugin: MarketPlugin): MarketVersion | null {
  const wanted = plugin.update ?? plugin.recommended ?? plugin.latest;
  return plugin.versions.find((v) => v.version === wanted) ?? plugin.versions[0] ?? null;
}

export interface VersionBadge {
  label: string;
  tone: "ok" | "warn" | "danger" | "neutral" | "info";
}

/** 版本行的标记：测试版、当前安装、已撤回、装不了 */
export function versionBadges(version: MarketVersion, plugin: MarketPlugin): VersionBadge[] {
  const badges: VersionBadge[] = [];
  if (plugin.installed?.version === version.version) badges.push({ label: "当前安装", tone: "info" });
  if (version.prerelease) badges.push({ label: "测试版", tone: "warn" });
  if (version.yanked) badges.push({ label: "已撤回", tone: "danger" });
  if (!version.compatible) badges.push({ label: "装不了", tone: "neutral" });
  return badges;
}

/** 版本行能不能点「装这一版」：能装、没撤回、不是当前装着的 */
export function canInstallVersion(version: MarketVersion, plugin: MarketPlugin): boolean {
  if (plugin.blocked || !version.compatible || version.yanked) return false;
  return !(plugin.installed?.source === "package" && plugin.installed.version === version.version);
}

/** 装某一版是升级、降级还是安装（按钮上的字） */
export function installVerb(version: string, plugin: MarketPlugin): string {
  const current = plugin.installed?.version;
  if (!current) return "安装";
  const index = (v: string) => plugin.versions.findIndex((item) => item.version === v);
  const a = index(version);
  const b = index(current);
  // versions 已按新到旧排好；当前装的版本不在索引里时按升级说
  if (b === -1 || a < b) return "升级到这一版";
  return "换回这一版";
}

export interface PermissionLine {
  title: string;
  detail: string;
  tone: "neutral" | "warn" | "danger";
}

/** 详情「权限」页：这一版要什么，按风险从高到低 */
export function permissionLines(version: MarketVersion): PermissionLine[] {
  const lines: PermissionLine[] = [];
  const p = version.permissions;
  if (version.runtime === "inline") {
    lines.push({
      title: "在主进程里运行",
      detail: "拥有与主程序相同的系统权限，崩溃会影响整个应用。安装时须单独确认。",
      tone: "danger",
    });
  } else if (version.runtime === "exec") {
    lines.push({
      title: "运行自带的可执行文件",
      detail: "在独立进程里以低权限用户运行，只能用下面列出的权限。",
      tone: "neutral",
    });
  } else {
    lines.push({
      title: "在独立进程里运行",
      detail: "和主程序隔离，以低权限用户运行，崩溃只影响它自己。",
      tone: "neutral",
    });
  }
  if (p.events.length > 0) {
    lines.push({
      title: "知道谁在什么时候看了什么",
      detail: `订阅敏感事件：${p.events.join("、")}`,
      tone: "warn",
    });
  }
  if (version.web) {
    lines.push({
      title: "带网页",
      detail: "网页以正在使用它的人的身份运行（管理员打开时拥有管理员的权限），安装时须单独确认。",
      tone: "warn",
    });
  }
  if (p.callbacks.length > 0) {
    lines.push({
      title: "开放回调地址",
      detail: `外部平台不用登录就能调进来：${p.callbacks.join("、")}`,
      tone: "warn",
    });
  }
  if (p.operations.length > 0) {
    lines.push({
      title: `调用 ${p.operations.length} 项宿主操作`,
      detail: p.operations.join("、"),
      tone: "neutral",
    });
  }
  for (const grant of p.paths) {
    lines.push({
      title: grant.mode === "rw" ? "读写目录" : "只读目录",
      detail: grant.path,
      tone: grant.mode === "rw" ? "warn" : "neutral",
    });
  }
  if (p.network) {
    lines.push({
      title: "访问互联网",
      detail: "请求走「网络与代理」里的出口，代理与限速对它生效。",
      tone: "neutral",
    });
  }
  if (version.dependencies.length > 0) {
    const native = version.dependencies.filter((d) => d.native).map((d) => d.name);
    lines.push({
      title: `安装时下载 ${version.dependencies.length} 个第三方包`,
      detail:
        "从 PyPI 镜像下载，版本与哈希钉死在锁文件里。" +
        (native.length ? `含本机代码：${native.join("、")}` : ""),
      tone: native.length ? "warn" : "neutral",
    });
  }
  if (lines.length === 1 && version.runtime !== "inline") {
    lines.push({ title: "不申请其他权限", detail: "只用它接入的接口本身提供的能力。", tone: "neutral" });
  }
  return lines;
}

/** 卡片底部的一行：版本 · 大小 */
export function versionMeta(version: MarketVersion | null): string {
  if (!version) return "";
  const parts = [`v${version.version}`];
  if (version.size) parts.push(formatBytes(version.size));
  return parts.join(" · ");
}

/** 「可更新」一节：装着、有更新的插件 */
export function pendingUpdates(plugins: MarketPlugin[]): MarketPlugin[] {
  return plugins.filter((p) => p.installed && p.update);
}

/** 装着的插件现在的状态（「unloaded」= 有安装记录但没加载，例如依赖还没装好） */
export function installedStatus(state: string): { label: string; tone: Tone } {
  if (state === "unloaded") return { label: "未加载", tone: "neutral" };
  return {
    label: pluginStateLabel(state as PluginState),
    tone: pluginStateTone(state as PluginState),
  };
}
