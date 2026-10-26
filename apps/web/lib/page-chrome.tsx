"use client";

import type { Route } from "next";
import { createContext, useContext, type ReactNode } from "react";

import type { SearchSubmitOptions } from "@/components/search-command";
import type { SearchScope } from "@/lib/categories";

/** 提交搜索的回调，签名与 AppShell 的 handleSearch 一致。 */
export type PageSearchHandler = (
  keyword: string,
  scope: SearchScope,
  options?: SearchSubmitOptions,
) => void;

/**
 * 页面顶栏的归属协商 —— 解决移动端「两条顶栏叠在一起」的问题。
 *
 * 移动端外壳自带一条全局顶栏（汉堡 + 字标 + 搜索），而详情类页面又各自带一条
 * PageNav（返回 + 标题 + 页面操作）。两者都吸在顶部，窄屏上就摞成了两层，
 * 白白吃掉两倍高度，右上角还并排出现两颗互不相干的图标。
 *
 * 收口办法：让页面顶栏「认领」这一行——PageNav 挂载即向外壳登记，外壳在移动端
 * 据此撤掉自己那条，并把全局顶栏上那两个无处安放的入口（抽屉、搜索）交给
 * PageNav 一并呈现：☰ 与返回并排在左，搜索与页面操作并排在右。于是无论哪种
 * 页面，窄屏上永远只有一条顶栏，而导航能力一个不少。
 *
 * 为什么用「组件自登记」而不是在外壳里列一张路由表：全站的移动端让位逻辑
 * （见 globals.css 的 .app-shell > main）一贯是「新增路由自动继承、无需登记」，
 * 路由表会随着页面增加而漏。谁渲染了 PageNav，谁就自动接管顶栏。
 *
 * 桌面端不受影响：外壳的全局顶栏本来就只在 < 768px 渲染，PageNav 那颗搜索键
 * 也只在移动端渲染（SearchCommand 自带全局 ⌘K 监听，多挂一份会让一次快捷键
 * 把面板开了又关，因此必须条件渲染而不是 CSS 隐藏）。
 */
export interface PageChromeValue {
  /**
   * 登记「本页自带顶栏」。在 effect 里调用，返回注销函数。
   * 用计数而非布尔：路由切换时新旧页面会短暂共存，计数才不会被先卸载的那个清零。
   */
  registerPageNav: () => () => void;
  /** 全局搜索入口：移动端由 PageNav 代为呈现（外壳那条已经撤掉） */
  onSearch: PageSearchHandler;
  /**
   * 把页面级控件挂进移动端全局顶栏那一行，返回撤销函数。
   *
   * 给的是**没有 PageNav 的顶层页面**（发现页那种侧栏一级入口）：它们不该有返回键，
   * 却又有一两个页面级控件（如发现页的 TMDB / 豆瓣 数据源切换）。若让这些控件
   * 自己吸一条顶栏，窄屏上同样会出现两排 header——而全局顶栏「字标与搜索之间」
   * 本来就空着一大段，正好安置。
   *
   * 在 effect 里调用并返回它的清理函数；节点要用稳定依赖构造，别在渲染期直接调。
   */
  setTopBarActions: (node: ReactNode) => () => void;
  /**
   * 把页面标题挂进移动端全局顶栏、顶替品牌字标的位置，返回撤销函数。
   *
   * 给沉浸类顶层页面（如 Agent 会话）：窄屏上字标传达不了任何新信息（用户
   * 就在应用里），这一格让给「我在看哪个会话」远比品牌曝光有用。字标只在
   * 没有页面认领标题时兜底显示。同样在 effect 里调用。
   *
   * ``backHref``：认领标题的页面通常是从别处进来的深层页（会话页），顶栏在
   * 标题左侧给一颗返回键——能回就按浏览历史回、回不了就落到这里给的地址
   * （lib/back-navigation.ts）。手机上底栏在这类页面是收起的，没有它就出不去。
   */
  setTopBarTitle: (title: string, options?: TopBarTitleOptions) => () => void;
  /**
   * 把任意节点挂到移动端全局顶栏的左侧（标题位），返回撤销函数。
   *
   * 给标题本身就是控件的顶层页（银玻璃发现页：大字「电影 / 剧集」+ 数据源小字 + ⌄，
   * 点开是类型 / 数据源菜单，对齐原生 App 的标题菜单）。与 setTopBarTitle 同时存在时
   * 以本节点为准。同样在 effect 里调用、节点用稳定依赖构造。
   */
  setTopBarLeading: (node: ReactNode) => () => void;
}

/** setTopBarTitle 的附加选项 */
export interface TopBarTitleOptions {
  /** 标题页的返回落点（见 setTopBarTitle 注释） */
  backHref?: Route;
  /**
   * 大字标题（银玻璃手机）：标签根页（媒体库 / 订阅 / 活动）按 iOS 标签根页规范，
   * 左上角一行粗体大字，与原生 App 的 `.toolbarTitleDisplayMode(.inlineLarge)` 同形态；
   * 缺省是深层页（会话页）用的正文字号小标题。
   */
  large?: boolean;
  /**
   * 不显示右上角的全局搜索键：AI 会话页右上角只放会话菜单（同原生 App），
   * 新会话页右上角什么都不放。
   */
  hideSearch?: boolean;
}

/** 顶栏大字标题的字形（银玻璃手机），发现页的标题菜单与各页大标题共用一份 */
export const TOP_BAR_LARGE_TITLE_CLASS =
  "min-w-0 truncate text-[28px] font-bold leading-none tracking-[-0.02em] text-[var(--text)]";

const PageChromeContext = createContext<PageChromeValue | null>(null);

export const PageChromeProvider = PageChromeContext.Provider;

/**
 * 「全出血（isHome / 氛围页）路由」判定：这些路由的主区不为顶栏让位
 * （外壳按它决定加不加 .topnav-offset、渲染不渲染全局蒙版），大图从顶栏
 * 底下穿过。抽出为纯函数供外壳与 page-nav 共用，两处判定必须同源。
 *
 * 为什么 PageNav 也要吃这份判定（防遮挡硬约束）：Netflix 桌面的全出血页若
 * 渲染 PageNav（sticky z-30），会被 fixed z-40 的 Netflix 顶栏整个盖住——
 * 返回键看得见却永远点不到。因此 PageNav 在渲染入口按本判定短路，改为由
 * 页面自身的 NetflixBackButton 承担返回（netflix/back-button.tsx）。
 * 「新增路由自动继承、无需登记」的全站让位原则由此获得代码保证，不再只靠
 * 各页人工规避。
 */
export function isHomeRoute(pathname: string, hasFullBleedLibraryHero: boolean): boolean {
  return (
    pathname === "/" ||
    // 主题自带全出血媒体库 Hero（Netflix 的 Billboard，坑位 libraryHero）时，
    // /library 是大图直出的氛围页
    (hasFullBleedLibraryHero && pathname === "/library") ||
    /^\/library\/\d+\/item\/\d+/.test(pathname) ||
    pathname.startsWith("/media/")
  );
}

/** 读取顶栏协商上下文；不在 AppShell 内（如独立的 /login、/setup）时返回 null。 */
export function usePageChrome(): PageChromeValue | null {
  return useContext(PageChromeContext);
}
