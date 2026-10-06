"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Route } from "next";
import { usePathname, useRouter } from "next/navigation";

/** 侧栏折叠态的本地持久化 key（设备级偏好，不进后端 ui.preferences） */
const SIDEBAR_COLLAPSED_KEY = "movieclaw.sidebar-collapsed";
/** 进设置前所在的工作台地址（含查询串），设置页「返回工作台」按原样回跳 */
const SETTINGS_RETURN_KEY = "movieclaw.settings-return";

import { FeedbackProvider } from "@/components/feedback";
import { ChevronLeftIcon } from "@/components/icons";
import { PAGE_NAV_BUTTON_CLASS } from "@/components/page-nav";
import { SearchCommand, type SearchSubmitOptions } from "@/components/search-command";
import { Sidebar } from "@/components/sidebar";
import { SubscribeEntryProvider } from "@/components/subscribe-entry";
import { MovieclawMark } from "@/components/brand";
import { AgentConversationsProvider } from "@/lib/agent-conversations";
import { useAppNavigationTracking, useBackNavigation } from "@/lib/back-navigation";
import { BackdropProvider } from "@/lib/backdrop";
import type { SearchScope, SearchVertical } from "@/lib/categories";
import {
  PageChromeProvider,
  TOP_BAR_LARGE_TITLE_CLASS,
  isHomeRoute,
  type TopBarTitleOptions,
} from "@/lib/page-chrome";
import { SearchPrefsProvider } from "@/lib/search-prefs";
import { buildSearchPath } from "@/lib/search-url";
import { UiPrefsProvider, useTheme } from "@/lib/ui-prefs";
import { useResolvedTheme } from "@/themes/registry";
import { useIsMobile } from "@/lib/use-media-query";
import { settingsSectionGroupsFor, settingsSections } from "@/lib/mock-data";
import { useSearchAccess } from "@/lib/search-access";
import { useSession } from "@/lib/session";

/**
 * 应用外壳：全站骨架布局，所有导航态由 URL 驱动。
 *
 * 每个页面都是真实路由——刷新保留、可分享、前进后退可用：
 *   /                    银玻璃=新任务氛围页；Netflix 无首页（replace 到 /library，
 *                        原内容首页 Billboard 已并入媒体库页，2026-09 修订）
 *   /library             媒体库（内容的一等入口；Netflix 主题顶部带 Billboard）
 *   /new                 AI 新任务（Netflix 顶栏「＋ 新任务」与银玻璃手机「更多 → 新会话」的落点）
 *   /discover/movie|tv   发现电影 / 剧集
 *   /subscriptions       我的订阅
 *   /activity            活动（观看 / 任务）
 *   /media/[type]/[id]   影片详情
 *   /search?q=…          跨站搜索结果（范围/快照都在查询参数里）
 *   /sessions/[id]       AI 会话
 *   /settings/[section]  设置各分区
 *
 * 外壳按主题分两副骨架（docs/design/web-themes.md）：
 *   - 银玻璃（默认）：左栏玻璃侧栏 + 右区（对齐 Codex / Claude Code 的两栏结构）
 *   - Netflix（结构级主题）：桌面 = 顶栏 + 全宽内容；移动 = 底部标签栏 + 全宽内容
 *
 * 主题值读自 UiPrefsProvider（ui.preferences.theme），因此 Provider 必须挂在
 * 壳层之外——本文件即按「AppShell 挂 Provider、AppShellBody 消费主题」拆分。
 */
export function AppShell({ children }: { children: React.ReactNode }) {
  return (
    // BackdropProvider 提供全站唯一的背景图数据源（CSS 大图 + 玻璃折射纹理），
    // 让「外观」设置里上传的图能同步作用到 body::before 与所有玻璃面板。
    // Netflix 主题下 body::before 由 CSS 不渲染，Provider 照常工作、仅闲置。
    <BackdropProvider>
    {/* FeedbackProvider：Toast 回执与确认/输入弹窗的全站唯一挂载点
      （见 components/feedback.tsx），取代原生 alert/confirm/prompt。 */}
    <FeedbackProvider>
    {/* SearchPrefsProvider / UiPrefsProvider：搜索偏好与界面样式的全站唯一数据源，
      应用启动各拉取一次、Context 共享，设置页的改动即时同步到所有消费页面。 */}
    <SearchPrefsProvider>
    <UiPrefsProvider>
    {/* AgentConversationsProvider：AI 会话的全站状态（侧栏最近会话 +
      /sessions/[id] 会话页共用），刷新后按会话编号自动回放未完成任务。 */}
    <AgentConversationsProvider>
    {/* SubscribeEntryProvider：海报卡片「订阅影片」按钮的全站入口，
      订阅弹层只在这里挂一份（见 components/subscribe-entry.tsx）。 */}
    <SubscribeEntryProvider>
    <AppShellBody>{children}</AppShellBody>
    </SubscribeEntryProvider>
    </AgentConversationsProvider>
    </UiPrefsProvider>
    </SearchPrefsProvider>
    </FeedbackProvider>
    </BackdropProvider>
  );
}

function AppShellBody({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  // PageNav 用这份会话标记在 Safari 判断「真实上一页是否仍在站内」；Chromium
  // 会直接读取 Navigation API，不依赖该兼容层。
  useAppNavigationTracking(pathname);
  // 移动端（< 768px）走另一套骨架：单栏 + 顶栏 + 底部标签栏，见文件末尾的分支渲染
  const isMobile = useIsMobile();
  // 结构层主题：解析自主题注册表（换外壳 = 提供桌面顶栏 / 底部标签栏等坑位）。
  // isNetflix 局部名沿用，语义 = 当前主题是结构级主题
  const theme = useTheme();
  const isNetflix = theme.structural;
  const { slots } = useResolvedTheme();
  const SettingsNav = slots.settingsNav;
  const MobileSettingsNav = slots.mobileSettingsNav;
  // 本页是否自带顶栏（详情类页面的 PageNav 会自登记，见 lib/page-chrome.tsx）。
  // 计数而非布尔：路由切换时新旧页面短暂共存，先卸载的那个不能把状态清零。
  const [pageNavCount, setPageNavCount] = useState(0);
  const registerPageNav = useCallback(() => {
    setPageNavCount((n) => n + 1);
    return () => setPageNavCount((n) => n - 1);
  }, []);
  // 顶层页面挂进全局顶栏的页面级控件（如发现页的数据源切换），同样是为了
  // 不让它们自己吸一条顶栏、在窄屏上摞成两排。撤销时先比对身份，避免路由
  // 切换期间旧页面的清理把新页面刚挂上的控件顺手抹掉。
  const [topBarActions, setTopBarActionsState] = useState<React.ReactNode>(null);
  const setTopBarActions = useCallback((node: React.ReactNode) => {
    setTopBarActionsState(node);
    return () => setTopBarActionsState((current) => (current === node ? null : current));
  }, []);
  // 页面标题顶替顶栏字标（如会话页），见 lib/page-chrome.tsx 的 setTopBarTitle。
  // 存 token 对象而非裸字符串：撤销时按引用比对，新旧页面短暂共存且标题恰好
  // 相同时，先卸载那个的清理不会误清新页面刚挂上的标题。
  const [topBarTitle, setTopBarTitleState] = useState<
    ({ text: string } & TopBarTitleOptions) | null
  >(null);
  const setTopBarTitle = useCallback((text: string, options?: TopBarTitleOptions) => {
    const token = { text, ...options };
    setTopBarTitleState(token);
    return () => setTopBarTitleState((current) => (current === token ? null : current));
  }, []);
  // 顶栏左侧的自定义节点（发现页的标题菜单），同一套按引用撤销的写法
  const [topBarLeading, setTopBarLeadingState] = useState<React.ReactNode>(null);
  const setTopBarLeading = useCallback((node: React.ReactNode) => {
    setTopBarLeadingState(node);
    return () => setTopBarLeadingState((current) => (current === node ? null : current));
  }, []);

  const isSettings = pathname.startsWith("/settings");
  // 设置分区选择是独立路由页（Netflix 移动端）：/settings 列表 → /settings/[section]
  const isSettingsIndex = pathname === "/settings";
  const activeNav = navIdFromPath(pathname);
  // 设置分区从路径推导：/settings/appearance → appearance；/settings 兜底到首个分区
  const activeSettings = isSettings
    ? (pathname.split("/")[2] ?? settingsSections[0].id)
    : settingsSections[0].id;

  // 侧栏折叠态：收起后只留图标窄栏，主区铺开、更沉浸。存 localStorage 记住设备偏好；
  // AuthGate 确认登录后才在客户端渲染本组件，故初始化时可直接读取、无 SSR 水合问题。
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => {
    try {
      return localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === "1";
    } catch {
      return false; // localStorage 不可用（隐私模式等）时仅失去记忆，功能不受影响
    }
  });

  const toggleSidebar = () => {
    setSidebarCollapsed((v) => {
      const next = !v;
      try {
        localStorage.setItem(SIDEBAR_COLLAPSED_KEY, next ? "1" : "0");
      } catch {
        // 忽略写入失败
      }
      return next;
    });
  };

  /** 选中侧栏导航项：跳对应路由（离开搜索结果/详情页由路由切换自然完成）。 */
  const handleSelect = (id: string) => {
    router.push(pathOfNavId(id));
  };

  /**
   * 提交搜索：关键词 + 范围（标签换算而来）编码进 /search 的查询参数。
   * options.vertical 决定落地垂直（媒体/站点资源，见 URL 的 tab 参数）；
   * options.snapshotId 非空 = 预览某条历史的结果快照（结果页顶部有提示条与「重新搜索」）。
   */
  // useCallback：这个回调要放进 PageChrome 上下文，身份不稳定会让每次外壳
  // 重渲染都把上下文当作新值推给消费者
  const handleSearch = useCallback(
    (keyword: string, scope: SearchScope, options?: SearchSubmitOptions) => {
      router.push(
        buildSearchPath(
          { keyword, scope, snapshotId: options?.snapshotId },
          options?.vertical,
        ) as Route,
      );
    },
    [router],
  );

  /** 从用户菜单进入设置：记下当前工作台地址（含查询串），返回时原样回跳 */
  // 设置入口的默认分区按角色取可见清单的第一项：管理员落「概览」，
  // 成员的清单里没有概览，落「个人信息」——避免把成员送进一个 403 分区
  const { session } = useSession();
  const defaultSettingsSection =
    settingsSectionGroupsFor(session.role)[0]?.items[0]?.id ?? settingsSections[0].id;
  const openSettings = (sectionId: string = defaultSettingsSection) => {
    try {
      sessionStorage.setItem(
        SETTINGS_RETURN_KEY,
        window.location.pathname + window.location.search,
      );
    } catch {
      // 记不住就退回首页，不影响进入设置
    }
    router.push(`/settings/${sectionId}` as Route);
  };

  const backToWorkspace = () => {
    let target = "/";
    try {
      target = sessionStorage.getItem(SETTINGS_RETURN_KEY) || "/";
    } catch {
      // 读取失败回首页
    }
    // 这是退出设置模式而不是打开一个新页面；replace 避免浏览器后退后又回到设置。
    router.replace(target as Route);
  };

  // 全站布局规范：默认所有页面都铺一层模糊蒙版（.page-scrim）压住背景大图、
  // 突出页面主题内容；例外是「氛围页」——「新任务」首页（路由 /）与两个影片
  // 详情页（媒体库条目 /library/x/item/y 与发现页条目 /media/...）。两类详情都用
  // 页面内部的有限高度剧照，并由自身渐变保证内容可读。新增路由无需登记，
  // 自动继承蒙版。Netflix 主题是纯色平铺设计，蒙版整体不渲染（§3.5）。
  // Netflix 主题的 /library 顶部是原内容首页并入的全出血 Billboard
  // （themes/netflix/components/library-hero.tsx），同为大图直出的氛围页：
  // 不加顶栏让位，让画面从透明顶栏底下穿过（银玻璃的 /library 不在此列）。
  // 判定本体抽在 lib/page-chrome.tsx 的 isHomeRoute：PageNav 的渲染入口要用
  // 同一份判定短路（Netflix 桌面全出血页渲染 PageNav 会被 z-40 顶栏盖住），
  // 两处必须同源，改动路由清单时只动一处。
  const isHome = isHomeRoute(pathname, slots.libraryHero != null);
  // Agent 对话页走沉浸模式：蒙版换成完全不透明的 .page-solid，整页盖掉
  // 背景大图（密集文本页不允许透图）；侧栏切换为实色形态。
  // 银玻璃手机上 /new 同样沉浸：新会话是一张「还没有消息的会话页」（顶栏标题
  // + 返回、空白正文、贴底输入条，见 components/new-task.tsx），发出第一条后
  // 原地变成 /sessions/[id]，两页外观必须同构才不会跳变。
  const isImmersive =
    pathname.startsWith("/sessions/") || (isMobile && !isNetflix && pathname === "/new");

  // 沉浸路由标记：强刷时由 layout.tsx 的内联脚本在首帧绘制前打上（避免闪出
  // 背景大图），这里负责客户端路由切换时的双向同步——进入 /sessions/[id] 关掉背景
  // 大图伪元素，离开时恢复其他页面的大图。
  useEffect(() => {
    document.documentElement.classList.toggle("immersive-route", isImmersive);
  }, [isImmersive]);

  // 移动端顶栏归属：详情类页面自带 PageNav（返回 + 标题 + 页面操作），
  // 全局顶栏再叠一条就成了两层顶栏，于是把这一行让给页面自己（见 lib/page-chrome.tsx）。
  const showMobileTopBar = isMobile && pageNavCount === 0;
  // 银玻璃移动端的液态玻璃底栏：Agent 会话页（沉浸路由）不显示——页底是会话
  // 输入行，底栏压上去就挡住了；iOS 信息的会话页同样收起标签栏。
  const showGlassTabBar = isMobile && !isNetflix && !isImmersive;
  const pageChrome = useMemo(
    () => ({
      registerPageNav,
      onSearch: handleSearch,
      setTopBarActions,
      setTopBarTitle,
      setTopBarLeading,
    }),
    [
      registerPageNav,
      handleSearch,
      setTopBarActions,
      setTopBarTitle,
      setTopBarLeading,
    ],
  );

  // 移动端主区内容：设置路由挂「返回 + 标题」条（/settings 是分区列表页，
  // /settings/[x] 是分区内容页，返回链固定 /settings/[x] → /settings → /my），
  // 其余路由原样。两个主题的移动端共用这一段（设置返回条与列表页是基础实现）。
  const mobileMainContent =
    isSettings && MobileSettingsNav ? (
      <div className="flex h-full flex-col">
        <MobileSettingsNav
          title={
            isSettingsIndex
              ? "设置"
              : (settingsSections.find((s) => s.id === activeSettings)?.label ?? "设置")
          }
          // 设置从「更多」页进（银玻璃是底栏头像页签、Netflix 是「我的」页签）：列表页的
          // 返回在银玻璃下按历史回（多半就是 /my），无历史时两个主题都落「更多 / 我的」页
          // 银玻璃的「个人信息」从「我的」页头像卡进（设置列表里不再单列，同原生 App），
          // 返回直接回「我的」，不垫一层设置列表
          backHref={
            (isSettingsIndex || (!isNetflix && activeSettings === "profile")
              ? "/my"
              : "/settings") as Route
          }
          historyBack={isSettingsIndex && !isNetflix}
        />
        <div className="min-h-0 flex-1">{children}</div>
      </div>
    ) : (
      children
    );

  // 侧栏本体：只在桌面版式渲染（移动端导航在底部标签栏）。
  // 必须只渲染一份——面板是真实 WebGL 液态玻璃，多一份就多吃一个 WebGL 上下文。
  // （Netflix 主题下玻璃已停用，但侧栏仍只在设置模式出现，同样单实例。）
  const sidebarNode = isSettings ? (
    // 设置分区菜单走主题坑位：Netflix = 黑底文字菜单
    // （themes/netflix/chrome/settings-sidebar），银玻璃 = 玻璃面板 + 胶囊行
    // 的 SaaS 菜单；两者分区/选中语义同源，由注册表按主题解析
    <SettingsNav
      active={activeSettings}
      onSelect={(id) => router.push(`/settings/${id}` as Route)}
      onBack={backToWorkspace}
    />
  ) : (
    <Sidebar
      activeNav={activeNav}
      onSelect={handleSelect}
      onSearch={handleSearch}
      onOpenSettings={openSettings}
      collapsed={sidebarCollapsed}
      onToggleCollapse={toggleSidebar}
      flat={isImmersive}
    />
  );

  // ============ Netflix 主题的结构层分支（§3.3 第 3 层） ============
  if (isNetflix) {
    return (
      <PageChromeProvider value={pageChrome}>
        {isMobile ? (
          /* —— Netflix 移动端：底部标签栏（发现/媒体库/订阅/我的，全是路由）——
             详情页 PageNav（返回键 + 吸顶雾）保留（App 详情页同样有返回）；
             无 PageNav 的页面继续用原雾层顶栏承载字标、页面级控件与搜索；
             字标与「我的」/my 页签直达内容入口，顶栏不再需要 ☰。 */
          <div
            className="app-shell viewport-app-height relative z-10 w-full"
            data-topbar={showMobileTopBar}
          >
            {showMobileTopBar && (
              <MobileTopBar
                onSearch={handleSearch}
                actions={topBarActions}
                title={topBarTitle?.text}
              />
            )}
            <main className="absolute inset-0">{mobileMainContent}</main>
            <slots.mobileTabBar />
          </div>
        ) : (
          /* —— Netflix 桌面：顶栏 + 全宽内容 ——
             氛围页（首页 billboard / 详情 hero）全出血、内容从透明顶栏底下穿过；
             其余页面由 .nf-nav-offset 为顶栏让位。设置模式保留「分区菜单 + 内容」
             的信息架构（§0 决策 2：控制台页只换皮肤、不重排）。 */
          <div className="app-shell viewport-app-height relative z-10 w-full">
            {slots.desktopTopNav && (
              <slots.desktopTopNav onSearch={handleSearch} onOpenSettings={openSettings} />
            )}
            {isSettings ? (
              <div className="nf-nav-offset absolute inset-0 flex">
                {/* 分区菜单贴全站 4vw 左基线（与顶栏字标同一条线），内容区随后左锚定 */}
                <aside className="h-full w-[300px] shrink-0 pl-[var(--page-inset)]">
                  {sidebarNode}
                </aside>
                <main className="h-full min-w-0 flex-1">{children}</main>
              </div>
            ) : (
              <main className={`absolute inset-0 ${isHome ? "" : "nf-nav-offset"}`}>
                {children}
              </main>
            )}
          </div>
        )}
      </PageChromeProvider>
    );
  }

  // ============ 银玻璃（默认）主题：侧栏 + 抽屉的既有骨架 ============
  return (
    <PageChromeProvider value={pageChrome}>
    {/* 全屏背景蒙版（.page-scrim）：作为 .app-shell 的兄弟节点、
      z 介于 body::before(0) 与 app-shell(10) 之间：压住背景大图、托住内容。
      全站统一一档，模糊度/暗度由「设置 → 外观 → 界面质感」的滑杆驱动
      （--scrim-blur / --scrim-dark，见 lib/ui-prefs.tsx）；唯一例外是
      「新任务」首页——大图直出的氛围页门面，不铺蒙版（见 isHome）。 */}
    {!isHome && (
      <div className={isImmersive ? "page-solid" : "page-scrim"} aria-hidden="true" />
    )}
    {isMobile ? (
      /* —— 移动端骨架：单栏 + 顶栏 + 液态玻璃底栏（docs/design/web-themes-mobile/04） ——
         高度用 100dvh 而非 100vh：移动浏览器的地址栏会收放，100vh 取的是
         「地址栏收起后」的大视口，底部输入区会被推到屏幕外；dvh 跟随实际
         可视高度，是移动端唯一正确的满屏单位。
         再减 --keyboard-inset：dvh 不认软键盘（iOS 弹键盘不改布局视口），
         外壳得自己按键盘占高收缩，否则贴底的输入行落在键盘底下
         （见 components/viewport-keyboard.tsx）。无键盘时该值为 0。 */
      /* data-topbar：主区要不要为全局顶栏空出那 52px，取决于这一行有没有被
         页面自己的 PageNav 认领（对应 globals.css 的 .app-shell[data-topbar] 规则）。
         data-tabbar：底栏在场时各页 .scroll-safe 的末尾空白加高到底栏之上
         （globals.css 的 .glass-tabbar 组；主区本身不整体让位，内容从底栏下穿过）。 */
      <div
        className="app-shell viewport-app-height relative z-10 w-full"
        data-topbar={showMobileTopBar}
        data-tabbar={showGlassTabBar}
      >
        {showMobileTopBar && (
          <MobileTopBar
            onSearch={handleSearch}
            actions={topBarActions}
            leading={topBarLeading}
            title={topBarTitle?.text}
            titleOptions={topBarTitle ?? undefined}
          />
        )}
        {/* 主区铺满外壳（absolute 而非 flex 子项）：全站页面清一色是
            「外层 h-full + 内层 overflow-y-auto」，h-full 要能解析就必须有一个
            确定的父高度——absolute inset-0 给的是确定值，flex-1 得来的高度在
            百分比解析上是灰色地带。让位顶栏与安全区的内边距由 globals.css
            的 .app-shell > main 统一提供。 */}
        <main className="absolute inset-0">{mobileMainContent}</main>
      </div>
    ) : (
      /* 浮起圆角卡片布局（对齐参考站 liquid-glass-oss）：外层留 padding、两栏留间隙，
        背景大图在卡片四周与中缝透出，面板作为浮于图上的玻璃卡片。
        app-shell 类名是给命令面板的「主界面后推」纵深效果用的锚点（见 globals.css 的
        body.cmdk-open .app-shell）：面板打开时整个外壳轻微缩放后退，浮层则漂在其上。
        高度同样减 --keyboard-inset：iPad 竖屏走的就是这一支布局，弹起软键盘时
        一样要把外壳收缩到键盘之上（桌面端该值恒为 0）。 */
      <div
        className="app-shell viewport-app-height relative z-10 flex w-full gap-3.5 p-3.5"
        // 侧栏当前宽度：沉浸页（发现 / 订阅首页有 Hero 时）的大图从侧栏底下铺到窗口左沿，
        // 文字与海报行按它让出侧栏（components/immersive-hero.tsx 的 DESKTOP_IMMERSIVE_FRAME）
        style={{ "--sidebar-w": !isSettings && sidebarCollapsed ? "68px" : "300px" } as React.CSSProperties}
      >
        {/* —— 左栏：浮起的玻璃侧栏卡片 ——
          宽度随折叠态动画（仅工作台可折叠；设置模式的分区菜单始终全宽）。 */}
        {/* relative z-20：沉浸页的大图从侧栏底下穿过，侧栏要压在主区之上 */}
        <aside
          className={`relative z-20 h-full shrink-0 transition-[width] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] ${
            !isSettings && sidebarCollapsed ? "w-[68px]" : "w-[300px]"
          }`}
        >
          {sidebarNode}
        </aside>

        {/* —— 右区：当前路由页面 —— */}
        <main className="h-full min-w-0 flex-1">{children}</main>
      </div>
    )}

    {/* —— 移动端底栏 ——
      作为 .app-shell 的兄弟节点固定定位：外壳在命令面板打开时有缩放变换，
      fixed 元素挂在里面会被一起缩放、定位基准也会变（原抽屉同理挂在这里）。 */}
    {showGlassTabBar && <slots.mobileTabBar />}
    </PageChromeProvider>
  );
}

/** pathname → 侧栏选中项 id（找不到对应项时返回空串，侧栏无高亮） */
function navIdFromPath(pathname: string): string {
  if (pathname === "/" || pathname === "/new") return "new";
  if (pathname.startsWith("/library")) return "library";
  if (pathname.startsWith("/subscriptions")) return "subscriptions";
  if (pathname.startsWith("/activity")) return "tasks";
  if (pathname.startsWith("/discover/")) return "discover";
  const session = /^\/sessions\/([^/]+)$/.exec(pathname);
  return session ? session[1] : "";
}

/** 侧栏项 id → 路由地址（与 navIdFromPath 互逆） */
function pathOfNavId(id: string): Route {
  switch (id) {
    case "new":
      return "/";
    case "library":
      return "/library" as Route;
    case "subscriptions":
      return "/subscriptions";
    case "tasks":
      return "/activity" as Route;
    case "discover":
      return "/discover/movie" as Route;
    default:
      return `/sessions/${id}` as Route;
  }
}

/**
 * 移动端顶栏：左侧标题位 + 页面级控件 + 右上角搜索。
 *
 * 左侧（银玻璃，2026-09-27 对齐原生 App）：
 *   - 标签根页（媒体库 / 订阅 / 活动 / 我的）挂大字标题（setTopBarTitle 的 large），
 *     即 iOS 标签根页的 `.inlineLarge`：一行粗体大字就在顶栏这 52px 里，不另占一行；
 *   - 发现页挂的是标题菜单节点（setTopBarLeading：大字「电影 / 剧集」+ 数据源小字 + ⌄）；
 *   - 深层页（会话页）挂正文字号的小标题，左侧带返回键。
 * Netflix 手机顶栏形态不动：没有标题时是 M 标回媒体库。
 *
 * 右侧：页面注入的控件 → 搜索（最右）。原先管理员在搜索左边还有一颗「+」新会话，
 * 随原生 App 一起去掉（用户拍板），新会话入口在「我的 → 最近会话」首行。
 * 搜索按所在标签预选模式（同 App 的 AppTopBar）：发现 / 订阅 → 影视，媒体库 → 媒体库，
 * 活动 → 资源；只作用于这一次打开，不改写面板记住的上次模式。
 *
 * 为什么是「浮在内容之上」而不是「占一行把内容推下去」：全站有一半页面是
 * 大图氛围页与 Hero 大剧照，顶栏若占位会在画面顶端切出一条硬边。这里做成
 * absolute 的渐隐雾层（同 PageNav 的处理）。内容的让位收口在 globals.css 的
 * 一条 `.app-shell > main` 规则里（安全区 + --mobile-topbar-h），
 * 各页面不必各写各的 padding，新增路由自动继承。
 */
function MobileTopBar({
  onSearch,
  actions,
  leading,
  title,
  titleOptions,
}: {
  onSearch: (keyword: string, scope: SearchScope, options?: SearchSubmitOptions) => void;
  /** 当前页面挂上来的页面级控件（见 lib/page-chrome.tsx 的 setTopBarActions） */
  actions?: React.ReactNode;
  /** 当前页面挂上来的左侧节点（见 setTopBarLeading），优先于 title */
  leading?: React.ReactNode;
  /** 当前页面挂上来的标题：有则显示在左侧（见 setTopBarTitle） */
  title?: string;
  /** 标题的附加选项：返回落点、大字、隐藏搜索 */
  titleOptions?: TopBarTitleOptions;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const backHref = titleOptions?.backHref;
  const back = useBackNavigation(backHref ?? ("/" as Route));
  // 搜索入口按「任一搜索分区可用」露出（影视 / 资源 / 媒体库），不只看资源搜索开关
  const { canOpenSearch } = useSearchAccess();
  // 雾层色由 globals.css 的 html[data-theme="netflix"] .mobile-topbar 覆盖，组件里不用管。
  const isNetflix = useTheme().structural;
  const large = titleOptions?.large && !isNetflix;
  return (
    <header className="mobile-topbar pointer-events-none absolute inset-x-0 top-0 z-40">
      <div className="pointer-events-auto flex h-[52px] items-center gap-2 px-3">
        {leading && !isNetflix ? (
          <div className="flex min-w-0 shrink items-center pl-1">{leading}</div>
        ) : title ? (
          <>
            {/* 返回键（银玻璃）：会话页这类深层页在手机上底栏收起，
                顶栏是唯一能离开的地方；能回就按历史回，回不了落到页面给的地址。
                Netflix 主题的顶栏形态不动。 */}
            {backHref && !isNetflix && (
              <button
                type="button"
                onClick={back}
                aria-label="返回"
                className={`${PAGE_NAV_BUTTON_CLASS} shrink-0`}
              >
                <ChevronLeftIcon className="size-[22px]" />
              </button>
            )}
            {/* 页面标题：min-w-0 + truncate 让超长标题在左缘与右侧控件
                之间安全截断成省略号，绝不把搜索键挤出屏幕或撑破顶栏 */}
            <h1
              className={
                large
                  ? `${TOP_BAR_LARGE_TITLE_CLASS} flex-1 pl-1`
                  : "min-w-0 flex-1 truncate text-body font-semibold tracking-[-0.01em] text-[var(--text)]"
              }
            >
              {title}
            </h1>
          </>
        ) : isNetflix ? (
          /* 字标可点区拉到 44px 高（与图标键同标准）——红色内联 SVG 本身保持
             h-7 的视觉大小，命中区靠按钮撑起，否则 28px 高的字标在触屏上很难点中。
             Netflix 主题没有首页：字标回媒体库（原内容首页已并入）。 */
          <button
            type="button"
            onClick={() => router.push("/library")}
            aria-label="回到媒体库"
            className="flex h-11 shrink-0 items-center transition-opacity active:opacity-60"
          >
            {/* 全站统一用 M 标：M 标 24px 方正得下，全字标 ≈125px 宽会占掉近三分之一顶栏 */}
            <MovieclawMark className="size-6" />
          </button>
        ) : null}
        {/* 页面级控件塞在左侧与右侧搜索之间；min-w-0 让它在窄屏上自己收缩，
            而不是把搜索挤出屏幕。极窄视口退化为横向可滑。
            py + 等量负 my：overflow-x 容器的裁切口按 padding box 算，正
            padding 把上下裁切口往外扩出角标（-top-1）需要的余量，负 margin
            把布局占位原样收回——52px 顶栏的排版不变，角标不再被削顶。 */}
        <div className="ml-auto flex min-w-0 shrink items-center gap-2 overflow-x-auto scroll-none py-1.5 -my-1.5">
          {actions}
          {/* 搜索固定在最右（右上角）。SearchCommand 自带全局 ⌘K 监听，全站只能挂一份：
              详情页的 PageNav 认领顶栏时本组件不渲染，搜索键改由 PageNav 挂 */}
          {canOpenSearch && !(titleOptions?.hideSearch && !isNetflix) && (
            <div className="shrink-0">
              <SearchCommand
                onSearch={onSearch}
                triggerClassName={PAGE_NAV_BUTTON_CLASS}
                preferredMode={isNetflix ? undefined : searchModeForPath(pathname)}
              />
            </div>
          )}
        </div>
      </div>
    </header>
  );
}

/**
 * 顶栏搜索按所在标签预选的模式（同原生 App 的 AppTopBar）：
 * 发现 / 订阅 → 影视，媒体库 → 媒体库，活动 → 资源；其余页面沿用面板记住的上次模式。
 */
function searchModeForPath(pathname: string): SearchVertical | undefined {
  if (pathname.startsWith("/discover") || pathname.startsWith("/subscriptions")) return "media";
  if (pathname.startsWith("/library")) return "library";
  if (pathname.startsWith("/activity")) return "torrent";
  return undefined;
}
