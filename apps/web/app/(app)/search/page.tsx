"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import type { Route } from "next";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import { CheckIcon, ChevronDownIcon, SearchIcon } from "@/components/icons";
import { LibrarySearchResults } from "@/components/library-search-results";
import { MediaSearchResults } from "@/components/media-search-results";
import { openSearchPalette } from "@/components/search-command";
import { SearchResults, type SearchQuery } from "@/components/search-results";
import {
  SCOPE_ALL,
  scopeEquals,
  scopeOfTab,
  tabKeyOf,
  tabLabel,
  type SearchScope,
  type SearchTab,
  type SearchVertical,
} from "@/lib/categories";
import { usePageChrome } from "@/lib/page-chrome";
import { useSearchPrefs } from "@/lib/search-prefs";
import { useSearchAccess } from "@/lib/search-access";
import { buildSearchPath, parseSearchQuery } from "@/lib/search-url";
import { useTheme } from "@/lib/ui-prefs";
import { useIsMobile } from "@/lib/use-media-query";
import { usePageTitle } from "@/lib/use-page-title";

/**
 * 搜索结果页（/search?q=…）：查询全部输入都在 URL 里，可刷新 / 分享 / 前进后退。
 * q 缺失或为空时（如手改地址删掉 q）重定向回首页，不渲染空结果。
 *
 * Google 式垂直选项卡：顶部「影视 | 站点资源 | 媒体库」，关键词跟着选项卡走
 * （URL 的 tab 参数，见 lib/search-url）。各垂直惰性挂载 + 切换保活：
 *   - 惰性：站点资源的跨站搜索是秒级重操作，只有用户真正切到该选项卡才发起，
 *     媒体优先的默认落地不会打扰任何 PT 站点；
 *   - 保活：切走的垂直用 display 隐藏而非卸载，PT 流式搜索照常进行、
 *     已出的结果保留，切回来不重新搜索。
 * tab 参数被刻意排除在种子搜索的身份（torrentKey）之外——切换选项卡只改
 * tab，torrent query 引用不变，SearchResults 的搜索 effect 不会重新触发。
 *
 * 银玻璃手机端顶栏对齐原生 App（apps/apple/.../SearchResultsView.swift）：左侧是写着关键词的
 * 玻璃胶囊，点它带着关键词 / 垂直 / 范围重新打开搜索面板改词重搜；站点资源垂直时右上角是
 * 范围菜单（取代手机上会折成多行的分类胶囊）；各垂直不再重复关键词大标题。
 */
export default function SearchPage() {
  const router = useRouter();
  const params = useSearchParams();
  // useSearchParams 返回的对象每次渲染同引用变化，这里以序列化串为依赖稳定 query
  const key = params.toString();
  const tabParam = params.get("tab");
  const vertical: SearchVertical =
    tabParam === "media" ? "media" : tabParam === "library" ? "library" : "torrent";
  // 种子搜索的身份串：剥掉 tab，切换选项卡时保持不变
  const torrentKey = useMemo(() => {
    const p = new URLSearchParams(key);
    p.delete("tab");
    return p.toString();
  }, [key]);
  const query = useMemo(
    () => parseSearchQuery(new URLSearchParams(torrentKey)),
    [torrentKey],
  );
  // 手动选种模式（订阅详情页「手动选种」跳入）：for_sub = 目标订阅 id
  const forSubRaw = params.get("for_sub");
  const grabForSubscriptionId =
    forSubRaw != null && /^\d+$/.test(forSubRaw) ? Number(forSubRaw) : null;
  // 浏览模式（无关键词）的标题按范围来：「浏览电影」/「浏览站点资源」
  usePageTitle(
    query
      ? query.keyword
        ? `搜索“${query.keyword}”`
        : `浏览${query.scope.label ?? "站点资源"}`
      : null,
  );

  if (!query) {
    if (typeof window !== "undefined") router.replace("/");
    return null;
  }

  /** 切换垂直：只改 tab 参数，范围/排序原样保留，切回时状态不丢；snapshot 例外——
   *  快照属于打开它的那个垂直（媒体/种子快照是两套数据），切到另一边一律实时搜索。
   *  读 window.location.search 而非 useSearchParams——排序/图览是用原生
   *  replaceState 写回地址栏的（不触发路由），只有前者能拿到它们的最新值。 */
  const switchVertical = (target: SearchVertical) => {
    const p = new URLSearchParams(window.location.search);
    if (target === "torrent") p.delete("tab");
    else p.set("tab", target);
    p.delete("snapshot");
    router.push(`/search?${p.toString()}` as Route);
  };

  // 快照提示条的「重新搜索」：切回实时搜索（丢掉 snapshot 参数）
  const handleResearch = (keyword: string, scope: SearchScope) => {
    router.push(buildSearchPath({ keyword, scope }) as Route);
  };

  /**
   * 站点资源页切换搜索分类：关键词不变，按目标分类生成一条新的实时搜索 URL。
   * buildSearchPath 会带上预设的站点、图览和无痕设置，并自然移除旧快照；
   * 手动选种模式（for_sub）要留着——从收窄的分类放宽到「全部」不能丢了投递目标。
   */
  const switchScope = (scope: SearchScope) => {
    const path = buildSearchPath({ keyword: query.keyword, scope });
    const forSub = grabForSubscriptionId != null ? `&for_sub=${grabForSubscriptionId}` : "";
    router.push(`${path}${forSub}` as Route);
  };

  return (
    // key = 种子搜索身份串：换关键词/范围即整体重挂载，重置两个垂直的访问状态；
    // 只切 tab 时身份不变，保活生效
    <SearchVerticals
      key={torrentKey}
      query={query}
      // 浏览模式没有关键词，影视/媒体库两个垂直无从谈起，强制落在站点资源上
      vertical={query.keyword ? vertical : "torrent"}
      grabForSubscriptionId={grabForSubscriptionId}
      onSwitch={switchVertical}
      onScopeSwitch={switchScope}
      onResearch={handleResearch}
    />
  );
}

const VERTICAL_TABS: { id: SearchVertical; label: string }[] = [
  { id: "media", label: "影视" },
  { id: "torrent", label: "站点资源" },
  { id: "library", label: "媒体库" },
];

/** 垂直选项卡 + 两个结果视图的挂载/显隐调度（惰性挂载、切换保活，见页头注释）。 */
function SearchVerticals({
  query,
  vertical,
  grabForSubscriptionId,
  onSwitch,
  onScopeSwitch,
  onResearch,
}: {
  query: SearchQuery;
  vertical: SearchVertical;
  grabForSubscriptionId: number | null;
  onSwitch: (target: SearchVertical) => void;
  onScopeSwitch: (scope: SearchScope) => void;
  onResearch: (keyword: string, scope: SearchScope) => void;
}) {
  const { visibleTabs } = useSearchPrefs();
  const searchAccess = useSearchAccess();
  // 浏览模式：无关键词，只逛站点资源的分类列表页
  const browsing = !query.keyword;
  // 银玻璃手机端：关键词胶囊 + 范围菜单挂进外壳顶栏（Netflix 主题与桌面维持原样）
  const chrome = usePageChrome();
  const isNf = useTheme().structural;
  const silverMobile = useIsMobile() && !isNf;
  // 各垂直是否已被访问过：访问过才挂载、之后保活
  const [visited, setVisited] = useState<Record<SearchVertical, boolean>>(() => ({
    media: vertical === "media",
    torrent: vertical === "torrent",
    library: vertical === "library",
  }));
  useEffect(() => {
    setVisited((prev) => (prev[vertical] ? prev : { ...prev, [vertical]: true }));
  }, [vertical]);
  useEffect(() => {
    // 浏览模式不做垂直兜底：没有关键词时切到影视/媒体库只会得到一个空搜索，
    // 无权用站点资源的成员由下面的空态提示接住
    if (browsing || !searchAccess.ready || searchAccess.available.length === 0) return;
    if (!searchAccess.available.includes(vertical) && searchAccess.firstAvailable) {
      onSwitch(searchAccess.firstAvailable);
    }
  }, [
    browsing,
    onSwitch,
    searchAccess.available,
    searchAccess.firstAvailable,
    searchAccess.ready,
    vertical,
  ]);

  const visibleVerticalTabs = VERTICAL_TABS.filter(
    (tab) =>
      searchAccess.available.includes(tab.id) && (!browsing || tab.id === "torrent"),
  );

  // 顶栏左侧的关键词胶囊：点它重新打开外壳顶栏那份搜索面板，关键词、垂直、范围都填好
  // （同 iOS keywordCapsule → Router.editSearch）；范围只在站点资源垂直带上
  const setTopBarLeading = chrome?.setTopBarLeading;
  const keywordCapsule = useMemo(
    () =>
      silverMobile ? (
        <KeywordCapsule
          keyword={query.keyword}
          onClick={() =>
            openSearchPalette({
              keyword: query.keyword,
              mode: vertical,
              scope: vertical === "torrent" ? query.scope : undefined,
            })
          }
        />
      ) : null,
    [query, silverMobile, vertical],
  );
  useEffect(() => {
    if (!keywordCapsule || !setTopBarLeading) return;
    return setTopBarLeading(keywordCapsule);
  }, [keywordCapsule, setTopBarLeading]);

  // 顶栏右上角的范围菜单（站点资源垂直才有）。onScopeSwitch 每次渲染都是新函数，
  // 经 ref 转一道，挂进顶栏的节点才不会每次渲染都重建、反复写外壳状态
  const scopeSwitchRef = useRef(onScopeSwitch);
  useEffect(() => {
    scopeSwitchRef.current = onScopeSwitch;
  });
  const switchScope = useCallback((scope: SearchScope) => scopeSwitchRef.current(scope), []);
  const setTopBarActions = chrome?.setTopBarActions;
  const showsScopeMenu =
    silverMobile && vertical === "torrent" && visibleVerticalTabs.some((t) => t.id === "torrent");
  const scopeMenu = useMemo(
    () =>
      showsScopeMenu ? (
        <ScopeMenu scope={query.scope} tabs={visibleTabs} onSwitch={switchScope} />
      ) : null,
    [query.scope, showsScopeMenu, switchScope, visibleTabs],
  );
  useEffect(() => {
    if (!scopeMenu || !setTopBarActions) return;
    return setTopBarActions(scopeMenu);
  }, [scopeMenu, setTopBarActions]);

  if (searchAccess.ready && visibleVerticalTabs.length === 0) {
    // 两种空：真的没有任何分区（找管理员），或者只是没带关键词——不带关键词的浏览
    // 只有站点资源分区有，只能搜影视 / 媒体库的成员停在这里，该做的是输入关键词
    const noAccess = searchAccess.available.length === 0;
    return (
      <div className="flex h-full items-center justify-center px-6 text-center">
        <p className="text-on-image text-body text-[rgba(243,245,249,0.72)]">
          {noAccess
            ? "当前账号没有可用的搜索入口，请联系管理员调整成员权限。"
            : "输入片名或关键词开始搜索。"}
        </p>
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col">
      {/* 垂直选项卡（Google 式「综合/图片」）：深色胶囊分段，压在背景大图上 */}
      <div className="shrink-0 px-6 pt-7 max-md:px-4 max-md:pt-4">
        <div className="flex flex-wrap items-center gap-2">
          <div
            role="tablist"
            aria-label="搜索垂直类别"
            className="inline-flex gap-1 rounded-full bg-black/25 p-1 backdrop-blur-sm"
          >
            {visibleVerticalTabs.map((tab) => {
              const active = tab.id === vertical;
              return (
                <button
                  key={tab.id}
                  type="button"
                  role="tab"
                  aria-selected={active}
                  onClick={() => !active && onSwitch(tab.id)}
                  className={`rounded-full px-3.5 py-1 text-sub font-medium transition-colors ${
                    active
                      ? "bg-white/[0.16] text-white"
                      : "text-[rgba(243,245,249,0.72)] hover:bg-white/[0.08] hover:text-white"
                  }`}
                >
                  {tab.label}
                </button>
              );
            })}
          </div>

          {/* 分类是真实搜索范围而非结果筛选：点击后更新 URL，并按该配置重新请求站点。 */}
          {vertical === "torrent" && !silverMobile && (
            <div
              role="radiogroup"
              aria-label="站点资源搜索分类"
              className="flex flex-wrap items-center gap-1"
            >
              <ScopeChip
                label="全部"
                active={scopeEquals(query.scope, SCOPE_ALL)}
                onClick={() => onScopeSwitch(SCOPE_ALL)}
              />
              {visibleTabs.map((tab) => {
                const scope = scopeOfTab(tab);
                return (
                  <ScopeChip
                    key={tabKeyOf(tab)}
                    label={tabLabel(tab)}
                    active={scopeEquals(query.scope, scope)}
                    onClick={() => onScopeSwitch(scope)}
                  />
                );
              })}
            </div>
          )}
        </div>
      </div>

      {searchAccess.canMedia && visited.media && (
        <div className={vertical === "media" ? "min-h-0 flex-1" : "hidden"}>
          <MediaSearchResults
            keyword={query.keyword}
            snapshotId={query.snapshotId}
            // 媒体快照的「重新搜索」= 留在媒体垂直、丢掉 snapshot 参数：
            // onSwitch 本身会剥离 snapshot，目标还是 media 时即为原地重搜
            onResearch={() => onSwitch("media")}
            onSwitchToTorrent={searchAccess.canTorrent ? () => onSwitch("torrent") : undefined}
          />
        </div>
      )}
      {searchAccess.canTorrent && visited.torrent && (
        <div className={vertical === "torrent" ? "min-h-0 flex-1" : "hidden"}>
          <SearchResults
            query={query}
            onResearch={onResearch}
            grabForSubscriptionId={grabForSubscriptionId}
          />
        </div>
      )}
      {searchAccess.canLibrary && visited.library && (
        <div className={vertical === "library" ? "min-h-0 flex-1" : "hidden"}>
          <LibrarySearchResults
            keyword={query.keyword}
            onSwitchToMedia={searchAccess.canMedia ? () => onSwitch("media") : undefined}
          />
        </div>
      )}
    </div>
  );
}

/** 站点资源分类 chip；视觉与全局搜索弹窗里的分类选择保持一致。 */
function ScopeChip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={active}
      onClick={() => !active && onClick()}
      className={`rounded-full px-2.5 py-1 text-sub transition-colors ${
        active
          ? "bg-white/[0.16] font-medium text-white"
          : "text-[rgba(243,245,249,0.68)] hover:bg-white/[0.08] hover:text-white"
      }`}
    >
      {label}
    </button>
  );
}

/**
 * 顶栏左侧的关键词胶囊（银玻璃手机端，同 iOS SearchResultsView.keywordCapsule）：
 * 放大镜 + 关键词，浏览模式写「最新资源」；点它回搜索面板改词重搜。
 * 玻璃材质与顶栏圆钮同一套（border-white/[0.09] + bg-black/30 + 模糊）。
 */
function KeywordCapsule({ keyword, onClick }: { keyword: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={keyword ? `搜索词：${keyword}，点按修改` : "最新资源，点按重新搜索"}
      className="flex h-9 min-w-0 max-w-[240px] items-center gap-1.5 rounded-full border border-white/[0.09] bg-black/30 px-4 text-white/85 backdrop-blur-md transition active:scale-[0.97] pointer-coarse:h-11"
    >
      <SearchIcon className="size-4 shrink-0 text-[var(--text-muted)]" />
      <span className="truncate text-body font-semibold text-[var(--text)]">
        {keyword || "最新资源"}
      </span>
    </button>
  );
}

/**
 * 站点资源的范围菜单（银玻璃手机端顶栏右上角，同 iOS SearchResultsView.scopeMenu）：
 * 胶囊写当前范围（默认「全部」），菜单列全部分类 / 内置分类 / 自定义分类，当前项打勾，
 * 选中即按新范围重新搜索。历史回放进来的范围可能不在当前可见分类里（已隐藏的分类、
 * 改过名的预设），单列一项「当前」，否则菜单里没有打勾项、看不出正在搜什么。
 */
function ScopeMenu({
  scope,
  tabs,
  onSwitch,
}: {
  scope: SearchScope;
  tabs: SearchTab[];
  onSwitch: (scope: SearchScope) => void;
}) {
  const isAll = scopeEquals(scope, SCOPE_ALL);
  const current = isAll ? null : tabs.find((tab) => scopeEquals(scopeOfTab(tab), scope));
  const value = isAll ? "all" : current ? tabKeyOf(current) : "current";
  const categories = tabs.filter((tab) => tab.type === "category");
  const presets = tabs.filter((tab) => tab.type === "preset");
  const itemCls =
    "glass-row nav-item flex cursor-pointer items-center justify-between gap-4 px-3 py-2 text-sub outline-none data-[highlighted]:!bg-[var(--glass-fill-hover)]";
  const item = (key: string, label: string, note?: string) => (
    <DropdownMenu.RadioItem key={key} value={key} className={itemCls}>
      <span className="min-w-0 truncate">
        {label}
        {note && <span className="ml-1.5 text-caption text-[var(--text-faint)]">{note}</span>}
      </span>
      <DropdownMenu.ItemIndicator>
        <CheckIcon className="size-3.5 text-[var(--info)]" />
      </DropdownMenu.ItemIndicator>
    </DropdownMenu.RadioItem>
  );
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          aria-label={`搜索范围：${scope.label ?? "全部分类"}`}
          className="flex h-9 max-w-[8.5rem] shrink-0 items-center gap-1 rounded-full border border-white/[0.09] bg-black/30 px-3.5 text-sub font-semibold text-white/85 backdrop-blur-md transition active:scale-[0.97] data-[state=open]:bg-black/50 pointer-coarse:h-11"
        >
          <span className="truncate">{scope.label ?? "全部"}</span>
          <ChevronDownIcon className="size-3 shrink-0 opacity-60" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          collisionPadding={12}
          className="menu-surface z-50 max-h-[var(--radix-dropdown-menu-content-available-height)] min-w-[11rem] overflow-y-auto p-1"
        >
          <DropdownMenu.RadioGroup
            value={value}
            onValueChange={(next) => {
              if (next === value || next === "current") return;
              if (next === "all") {
                onSwitch(SCOPE_ALL);
                return;
              }
              const tab = tabs.find((t) => tabKeyOf(t) === next);
              if (tab) onSwitch(scopeOfTab(tab));
            }}
          >
            {item("all", "全部分类")}
            {value === "current" && item("current", scope.label ?? "当前范围", "当前")}
            {categories.length > 0 && <DropdownMenu.Separator className="my-1 h-px bg-white/[0.08]" />}
            {categories.map((tab) => item(tabKeyOf(tab), tabLabel(tab)))}
            {presets.length > 0 && (
              <DropdownMenu.Label className="px-3 pb-1 pt-2 text-micro text-[var(--text-faint)]">
                自定义分类
              </DropdownMenu.Label>
            )}
            {presets.map((tab) => item(tabKeyOf(tab), tabLabel(tab)))}
          </DropdownMenu.RadioGroup>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
