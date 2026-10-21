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
 * 新增主题的步骤：
 *   - 这里注册一份 ThemeMeta；
 *   - globals.css 加对应该 id 的变量覆盖组（纯换肤主题只需第 1 层）；
 *   - 设置 → 外观的「主题」卡片自动出现（消费方遍历 THEMES 渲染）。
 */
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

const THEME_ID_SET = new Set(THEMES.map((theme) => theme.id));

/**
 * 未知值兜底为默认主题：偏好可能来自老后端（不认识该字段）、手改的
 * localStorage 缓存或未来被下线的主题 id，消费方拿到的必须是注册表里的
 * 合法 id，绝不能把垃圾值写到 <html> 的 data-theme 上。
 */
export function normalizeThemeId(value: unknown): string {
  return typeof value === "string" && THEME_ID_SET.has(value) ? value : DEFAULT_THEME_ID;
}

/** 是否为注册表里的合法主题 id：按端主题的覆盖字段用——非法值按「未设置」处理
 *  （回落通用主题），而不是像 normalizeThemeId 那样兜成默认主题。 */
export function isValidThemeId(value: unknown): value is string {
  return typeof value === "string" && THEME_ID_SET.has(value);
}

/** 按 id 取主题元数据；未知 id（理论上传入前已 normalize）回落默认主题。 */
export function themeMeta(id: string): ThemeMeta {
  return THEMES.find((theme) => theme.id === id) ?? THEMES[0];
}
