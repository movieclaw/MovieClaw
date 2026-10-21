import { GlassTabBar } from "@/components/glass-tab-bar";
import { MobileSettingsNav } from "@/components/mobile-settings-nav";
import { MorePage } from "@/components/more-page";
import { PageNav } from "@/components/page-nav";
import { SettingsIndex } from "@/components/settings-index";
import { SettingsSidebar } from "@/components/settings-view";
import { guardSlot } from "@/components/theme-slot-boundary";
import { loadedDefinition } from "@/lib/theme-runtime";
import { themeMeta } from "@/lib/themes";
import { useTheme } from "@/lib/ui-prefs";

import type {
  DetailNavProps,
  ResolvedSlots,
  ResolvedTheme,
  ThemePages,
  ThemeSlots,
} from "./types";

/**
 * 主题坑位注册表（docs/design/theme-framework/01–02、theme-plugins.md §4.3）。
 *
 * 主题知识在全站的唯一合法出口：业务组件消费 `useResolvedTheme()` 拿坑位与能力，
 * 不允许再出现 `theme.id === "<主题名>"` 的私下判断。依赖方向：
 *
 *   主题插件（theme/index.js）──运行时加载──▶ lib/theme-runtime ──▶ registry ──解析──▶ 业务组件
 *
 * 主题全部是插件，内核不 import 任何主题；默认主题（银玻璃）没有定义，用的就是基础实现。
 */

/**
 * 基础坑位缺省：银玻璃（默认主题）的实现就是「基础实现」本身。
 * 有基础实现的坑位才登记；没有基础实现的坑位（如 desktopTopNav）不在表里，
 * 解析结果为 undefined，消费方按「没有就不渲染」处理。
 *
 * 移动端三件套（底栏 / 设置返回条 / 设置分区列表页，见 BASE_PAGES）2026-09-23
 * 起有了基础实现：银玻璃移动端从「☰ 抽屉」改为 iOS 26 液态玻璃底栏
 * （docs/design/web-themes-mobile/04），Netflix 覆盖底栏、沿用后两者。
 */
const BASE_SLOTS: Partial<ThemeSlots> = {
  settingsNav: SettingsSidebar,
  detailNav: PageNavAdapter,
  mobileTabBar: GlassTabBar,
  mobileSettingsNav: MobileSettingsNav,
};

/** 基础整页：/my =「更多」页（底栏末位页签），/settings 移动端 = 分区列表页 */
const BASE_PAGES: ThemePages = {
  my: MorePage,
  settingsIndex: SettingsIndex,
};

/** 基础详情页返回导航：整条 PageNav 工具条（消费 title/fallback/actions/className，
 *  忽略 onBack/onPhoto 浮动键语义——PageNav 自己按 fallback 算返回）。
 *  actions 必须转发：媒体库条目页的「⋯」操作菜单就挂在这里，#437 漏转过一次，
 *  银玻璃两端的条目页右上角因此空了（2026-09-24 用户发现）。 */
function PageNavAdapter({ title, fallback, actions, className }: DetailNavProps) {
  return <PageNav title={title} fallback={fallback} actions={actions} className={className} />;
}

/**
 * 解析主题：capabilities / slots / pages 全部归并基础缺省。
 * - 传入的是生效主题 id（lib/ui-prefs.tsx 已把认不得、加载失败的换成默认主题）；
 * - 主题定义：运行时加载好的插件主题（lib/theme-runtime.ts）；默认主题没有定义；
 *   还没加载好的按纯基础实现渲染（外壳此时显示启动画面，见 ui-prefs 的 themePending）；
 * - 缺失坑位 / 整页 → BASE_SLOTS / BASE_PAGES 基础实现；主题的坑位与整页都套错误边界，
 *   渲染出错只让那一处回落基础实现。
 */
export function getResolvedTheme(id: string): ResolvedTheme {
  const def = loadedDefinition(id);
  const meta = themeMeta(id);
  return {
    meta,
    capabilities: { glass: meta.glass },
    slots: { ...BASE_SLOTS, ...guardAll(id, def?.slots, BASE_SLOTS) } as ResolvedSlots,
    pages: { ...BASE_PAGES, ...guardAll(id, def?.pages, BASE_PAGES) },
  };
}

function guardAll<T extends object>(themeId: string, own: T | undefined, base: Partial<T>): Partial<T> {
  if (!own) return {};
  const out: Record<string, unknown> = {};
  for (const [name, Slot] of Object.entries(own)) {
    if (!Slot) continue;
    const Fallback = (base as Record<string, unknown>)[name];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- 各坑位 props 不同，这里只做透传
    out[name] = guardSlot(themeId, name, Slot as any, Fallback as any);
  }
  return out as Partial<T>;
}

/** 便捷钩子：当前主题的解析结果（组件层统一从这里拿坑位与能力） */
export function useResolvedTheme(): ResolvedTheme {
  return getResolvedTheme(useTheme().id);
}
