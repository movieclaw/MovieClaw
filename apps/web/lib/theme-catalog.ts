/**
 * 已安装主题的目录（docs/design/theme-plugins.md §4.3）——服务端 `GET /ui/themes` 的前端副本。
 *
 * 纯模块（不 import React），供 lib/themes.ts、加载器与防闪烁脚本共用：
 * - 首次拉取前先用 localStorage 里上次的快照，首帧就认得已装主题（选择卡、版式、玻璃、状态栏色）；
 * - 拉回来后整表替换并重写快照；登录主体变了（切换账号）由调用方重拉。
 * 快照不可信：只当首帧的提示，最终以服务端为准。
 */

export interface CatalogTheme {
  id: string;
  label: string;
  description: string;
  preview: { bg: string; accent: string };
  theme_color: string;
  layout: "panel" | "cinema";
  glass: boolean;
  version: string;
  source: "bundled" | "package";
  /** ok / incompatible（主题契约不兼容，需要更新插件；不托管文件） */
  status: string;
  reason?: string | null;
  css: string | null;
  /** 外框组件模块地址；纯换肤主题与不兼容时为空 */
  script: string | null;
}

/** 首帧快照的 localStorage 键：layout.tsx 的防闪烁脚本按它写 data-glass / theme-color / modulepreload */
export const THEME_CATALOG_CACHE_KEY = "movieclaw.themes";

let themes: CatalogTheme[] | null = readSnapshot();
/** 本次页面生命周期里是否已从服务端拉到过（快照不算） */
let fresh = false;
const listeners = new Set<() => void>();
let version = 0;

function readSnapshot(): CatalogTheme[] | null {
  try {
    // 按 window 判断而不是 localStorage：Node 26 服务端也挂了 localStorage，一访问就打告警
    if (typeof window === "undefined") return null;
    const raw = JSON.parse(localStorage.getItem(THEME_CATALOG_CACHE_KEY) ?? "null");
    return Array.isArray(raw) ? raw.filter(isCatalogTheme) : null;
  } catch {
    return null;
  }
}

function isCatalogTheme(value: unknown): value is CatalogTheme {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return typeof v.id === "string" && typeof v.label === "string" && typeof v.layout === "string";
}

function emit() {
  version += 1;
  for (const listener of listeners) listener();
}

/** 用服务端的整表替换目录并写快照 */
export function setThemeCatalog(next: CatalogTheme[]): void {
  themes = next.filter(isCatalogTheme);
  fresh = true;
  try {
    if (typeof window !== "undefined") localStorage.setItem(THEME_CATALOG_CACHE_KEY, JSON.stringify(themes));
  } catch {
    // 隐私模式等写不进去：只影响下次首帧
  }
  emit();
}

/** 当前目录；从没拉到过且没有快照时为 null */
export function themeCatalog(): CatalogTheme[] | null {
  return themes;
}

/** 本次页面生命周期里是否已从服务端拉到过 */
export function themeCatalogFresh(): boolean {
  return fresh;
}

export function catalogTheme(id: string): CatalogTheme | undefined {
  return themes?.find((theme) => theme.id === id && theme.status === "ok");
}

export function subscribeThemeCatalog(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** 变更计数：给 useSyncExternalStore 当快照（目录换了就换值） */
export function themeCatalogVersion(): number {
  return version;
}
