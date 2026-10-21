/**
 * 主题外框组件的运行时加载（docs/design/theme-plugins.md §4.3、§5.4）。
 *
 * 主题包里的 `theme/index.js` 是标准 ES 模块（default export 主题定义），它 import 的
 * react / react-dom / react/jsx-runtime / next/link / next/navigation / @movieclaw/theme-sdk
 * 经根布局的 import map 指到 public/_theme-runtime/ 下的垫片，垫片再从这里挂的
 * `globalThis.__mcThemeRuntime.modules` 取主程序的同一份模块实例——主题与主程序共用 React、
 * 路由与全部上下文。
 *
 * 用浏览器原生 `import()`（webpackIgnore / turbopackIgnore），与打包器无关。
 * 状态：idle → loading → ready / failed；失败（404、语法错、超时、形状不对）只影响这个主题：
 * 外壳整体回落默认主题并提示，不让站点打不开。
 */
import * as React from "react";
import * as ReactDOM from "react-dom";
import * as JsxRuntime from "react/jsx-runtime";
import Link, { useLinkStatus } from "next/link";
import * as Navigation from "next/navigation";

import type { ThemeDefinition } from "@/themes/types";

export type ThemeLoadStatus = "idle" | "loading" | "ready" | "failed";

/** 加载超时：超过就按失败处理，外壳回落默认主题，不让人一直对着加载动画 */
export const THEME_LOAD_TIMEOUT_MS = 8000;

/** 主题定义里认得的坑位与整页名（与 themes/types.ts 的 ThemeSlots / ThemePages 同步） */
const SLOT_NAMES = new Set([
  "desktopTopNav",
  "mobileTabBar",
  "mobileSettingsNav",
  "settingsNav",
  "detailNav",
  "pageActions",
  "libraryHero",
]);
const PAGE_NAMES = new Set(["my", "settingsIndex", "subscriptions"]);

interface Entry {
  status: ThemeLoadStatus;
  url?: string;
  definition?: ThemeDefinition;
  error?: string;
}

/** 渲染时报过错的坑位：主题 id → 坑位名（错误边界上报，外壳据此提示一次） */
const slotErrors = new Map<string, Set<string>>();

const entries = new Map<string, Entry>();
const listeners = new Set<() => void>();
let version = 0;

function emit() {
  version += 1;
  for (const listener of listeners) listener();
}

/**
 * 把主程序的模块实例挂给垫片。幂等；必须在第一次 import 主题模块之前完成。
 *
 * SDK 用动态 import 取：它牵出大半个前端（组件、数据层），本模块又被 ui-prefs 引用、几乎
 * 每页都在启动时加载——静态引入会形成循环依赖，图标等模块还没初始化完就被读（实测整站白屏）。
 * 只有真要加载主题时才取 SDK，那时主程序早已初始化完毕。
 */
let installing: Promise<void> | null = null;
function installRuntime(): Promise<void> {
  installing ??= import("@movieclaw/theme-sdk").then((Sdk) => {
    const scope = globalThis as { __mcThemeRuntime?: { modules: Record<string, unknown> } };
    scope.__mcThemeRuntime = {
      modules: {
        react: React,
        "react-dom": ReactDOM,
        "react/jsx-runtime": JsxRuntime,
        "next/link": { default: Link, useLinkStatus },
        "next/navigation": Navigation,
        "@movieclaw/theme-sdk": Sdk,
      },
    };
  });
  return installing;
}

function isComponent(value: unknown): boolean {
  // 函数组件，或 memo / forwardRef / lazy 这类带 $$typeof 的对象
  return typeof value === "function" || (typeof value === "object" && value !== null && "$$typeof" in value);
}

/** 校验主题模块的形状：坑位与整页名必须认得、值必须是组件。返回不合规的原因。 */
export function checkDefinition(value: unknown): string | null {
  if (!value || typeof value !== "object") return "模块没有 default export 主题定义";
  const def = value as Record<string, unknown>;
  for (const [group, names] of [
    ["slots", SLOT_NAMES],
    ["pages", PAGE_NAMES],
  ] as const) {
    const part = def[group];
    if (part === undefined) continue;
    if (!part || typeof part !== "object") return `${group} 必须是对象`;
    for (const [name, component] of Object.entries(part)) {
      if (!names.has(name)) return `不认得的${group === "slots" ? "坑位" : "整页"}「${name}」`;
      if (component !== undefined && !isComponent(component)) return `「${name}」不是组件`;
    }
  }
  return null;
}

/**
 * 加载一个主题的外框组件。同一地址只加载一次；已失败的不自动重试（换了地址——主题升级——才重来）。
 * 返回是否就绪。
 */
export function loadTheme(id: string, url: string): Promise<boolean> {
  const current = entries.get(id);
  if (current && current.url === url) {
    if (current.status === "ready") return Promise.resolve(true);
    if (current.status === "failed") return Promise.resolve(false);
    if (current.status === "loading") return pending.get(id) ?? Promise.resolve(false);
  }
  // 换了地址（主题升级）重新加载期间沿用旧定义，外壳不必卸下重来
  entries.set(id, { status: "loading", url, definition: current?.definition });
  emit();
  const task = (async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await installRuntime();
      const timeout = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("加载超时")), THEME_LOAD_TIMEOUT_MS);
      });
      const mod = (await Promise.race([
        import(/* webpackIgnore: true */ /* turbopackIgnore: true */ url),
        timeout,
      ])) as { default?: unknown };
      const problem = checkDefinition(mod.default);
      if (problem) throw new Error(problem);
      entries.set(id, { status: "ready", url, definition: mod.default as ThemeDefinition });
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[themes] 主题「${id}」的外框组件加载失败：${message}`);
      entries.set(id, { status: "failed", url, error: message });
      return false;
    } finally {
      clearTimeout(timer);
      pending.delete(id);
      emit();
    }
  })();
  pending.set(id, task);
  return task;
}

const pending = new Map<string, Promise<boolean>>();

export function themeLoadStatus(id: string): ThemeLoadStatus {
  return entries.get(id)?.status ?? "idle";
}

/** 可用的主题定义：加载好的；升级重载期间是上一版的；失败了没有 */
export function loadedDefinition(id: string): ThemeDefinition | undefined {
  const entry = entries.get(id);
  return entry?.status === "failed" ? undefined : entry?.definition;
}

export function themeLoadError(id: string): string | undefined {
  return entries.get(id)?.error;
}

export function subscribeThemeRuntime(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** 变更计数：给 useSyncExternalStore 当快照（加载状态变了就换值） */
export function themeRuntimeVersion(): number {
  return version;
}

/** 坑位渲染出错（错误边界上报）：该坑位已回落基础实现，这里记下来让外壳提示一次。 */
export function reportSlotError(themeId: string, slot: string, error: unknown): void {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`[themes] 主题「${themeId}」的「${slot}」渲染出错，已回落基础实现：${message}`);
  const slots = slotErrors.get(themeId) ?? new Set<string>();
  if (slots.has(slot)) return;
  slots.add(slot);
  slotErrors.set(themeId, slots);
  emit();
}

export function themeSlotErrors(themeId: string): string[] {
  return [...(slotErrors.get(themeId) ?? [])];
}
