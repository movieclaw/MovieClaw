/**
 * 主题注册表 —— 多主题 UI 框架的唯一事实源（docs/design/web-themes.md §3.2）。
 *
 * 主题是这个功能里唯一会「全局生效」的东西，注册表刻意保持**无组件依赖的
 * 纯数据**（不 import React / 不 import 组件），便于单测与后续扩展。
 *
 * 生效机制分三层（同文档 §3.3）：
 *   1. token 层：globals.css 里 `html[data-theme="<id>"]` 下的语义变量覆盖组；
 *   2. Tailwind v4 主题变量层：同一覆盖组里的 `--radius-*` 换档（全站圆角）；
 *   3. 结构层：内核按版式（ThemeLayout）排布页面，主题经坑位注册表替换外框组件。
 *
 * 主题来源两处：这里的内置注册表（默认主题）与已安装主题的目录（lib/theme-catalog.ts，
 * 服务端 GET /ui/themes——主题是插件，docs/design/theme-plugins.md）。消费方一律经
 * availableThemes / themeMeta / isKnownTheme 取，不直接遍历 THEMES。
 */
import { catalogTheme, themeCatalog, type CatalogTheme } from "./theme-catalog.ts";

/**
 * 版式：页面在什么样的外框里排布（docs/design/theme-plugins.md §4.2）。
 * 版式归内核，主题只声明用哪一种——内核组件按版式分叉，不认识具体主题。
 * - panel：侧栏 + 居中内容面板 + iOS 式移动端顶栏 / 悬浮底栏（银玻璃）；
 * - cinema：全局顶栏（主题的 desktopTopNav 坑位）+ 满出血内容 + 大图首屏 +
 *   实底移动顶栏 / 停靠底栏。
 * 外壳几何（移动顶栏让位高度、底栏高度）不在这里：由主题 CSS 以变量声明
 * （--mobile-topbar-h / --mobile-tabbar-h），首帧随 data-theme 一起生效。
 */
export type ThemeLayout = "panel" | "cinema";

export interface ThemeMeta {
  id: string;
  /** 设置页展示名 */
  label: string;
  /** 一句话描述 */
  description: string;
  /** 外观选择卡的预览缩略：两个主色即可拼出观感 */
  preview: { bg: string; accent: string };
  /**
   * 浏览器地址栏 / PWA 状态栏颜色。layout.tsx 的防闪烁脚本由注册表序列化出
   * 「主题 id → themeColor」映射，首帧绘制前随 data-theme 一起写入
   * <meta name="theme-color">——新增主题自动被脚本认识，无需改脚本。
   */
  themeColor: string;
  /** 版式（见上方 ThemeLayout）。纯换肤主题恒为 panel。 */
  layout: ThemeLayout;
  /**
   * 是否启用液态玻璃（WebGL 画布与玻璃材质）。纯色平铺主题 = false：外壳不建
   * WebGL 画布，<html> 带 data-glass="off"，玻璃材质规则（globals.css 里挂
   * html:not([data-glass="off"]) 的那些）不生效。首帧由防闪烁脚本写入。
   */
  glass: boolean;
}

export const THEMES: ThemeMeta[] = [
  {
    id: "silver",
    label: "银玻璃",
    description: "液态玻璃 · 冷银高光的控制台质感（默认）",
    preview: { bg: "#111113", accent: "#cdd6e6" },
    themeColor: "#000000",
    layout: "panel",
    glass: true,
  },
  {
    id: "netflix",
    label: "Netflix",
    description: "纯色平铺 · 品牌红 · 顶栏与横版卡片行的影院浏览形态",
    preview: { bg: "#141414", accent: "#e50914" },
    themeColor: "#000000",
    layout: "cinema",
    // 纯色平铺设计：整体停用液态玻璃
    glass: false,
  },
];

export const DEFAULT_THEME_ID = "silver";

/** 主题 id 的写法（= 插件 id 的规则，src/movieclaw_api/plugins/packages.py 的 _ID）。 */
const THEME_ID_PATTERN = /^[a-z][a-z0-9-]{1,38}[a-z0-9]$/;

/**
 * 偏好里存的主题 id 是否合法——**只看写法，不看装没装**。
 *
 * 偏好要原样保留没装（或暂时卸载、停用、加载失败）的主题 id：卸载后重装能自动回到原主题，
 * 用户在此期间改别的设置也不会把它覆盖成默认主题（docs/design/theme-plugins.md §7 第 6 条）。
 * 渲染时认不认得由 themeMeta / isKnownTheme 决定。
 */
export function isValidThemeId(value: unknown): value is string {
  return typeof value === "string" && THEME_ID_PATTERN.test(value);
}

/** 偏好的主题 id 兜底：写法不对（老后端、手改的缓存）才换成默认主题，没装的照样保留。 */
export function normalizeThemeId(value: unknown): string {
  return isValidThemeId(value) ? value : DEFAULT_THEME_ID;
}

function fromCatalog(theme: CatalogTheme): ThemeMeta {
  return {
    id: theme.id,
    label: theme.label,
    description: theme.description,
    preview: theme.preview,
    themeColor: theme.theme_color,
    layout: theme.layout,
    glass: theme.glass,
  };
}

/** 当前认得的主题：内置注册表 + 已安装主题目录（契约不兼容的不算）。 */
export function availableThemes(): ThemeMeta[] {
  const known = new Set(THEMES.map((theme) => theme.id));
  const installed = (themeCatalog() ?? [])
    .filter((theme) => theme.status === "ok" && !known.has(theme.id))
    .map(fromCatalog);
  return [...THEMES, ...installed];
}

/** 渲染层认不认得这个主题（内置或已安装且契约兼容） */
export function isKnownTheme(id: string): boolean {
  return THEMES.some((theme) => theme.id === id) || catalogTheme(id) !== undefined;
}

/** 按 id 取主题元数据；不认得的（没装、卸载了、契约不兼容）回落默认主题。 */
export function themeMeta(id: string): ThemeMeta {
  const builtin = THEMES.find((theme) => theme.id === id);
  if (builtin) return builtin;
  const installed = catalogTheme(id);
  return installed ? fromCatalog(installed) : THEMES[0];
}
