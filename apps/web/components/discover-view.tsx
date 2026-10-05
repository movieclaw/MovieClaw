"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import type { Route } from "next";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";

import {
  CheckIcon,
  ChevronDownIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  FilmIcon,
  GlobeIcon,
  PlusIcon,
  StarIcon,
  TvIcon,
} from "@/components/icons";
import { MediaRow } from "@/components/media-row";
import { DiscoverRegionFooter } from "@/components/discover-region-footer";
import {
  DISCOVER_MENU_ITEM_CLASS,
  DiscoveryFilterControl,
  DiscoveryFilterMenu,
} from "@/components/discovery-filter-dialog";
import { FilteredDiscoveryView } from "@/components/filtered-discovery-view";
import {
  DESKTOP_CARD_FRAME,
  DESKTOP_IMMERSIVE_FRAME,
  HeroAmbientBackdrop,
  HeroBleed,
  IMMERSIVE_INSET,
  ImmersiveHero,
  useHeroScrollVar,
  useHeroWindowBackdrop,
  useUpgradedBackdrop,
} from "@/components/immersive-hero";
import { PosterImage } from "@/components/poster-image";
import { useResolvedTheme } from "@/themes/registry";
import { useSubscribeEntry } from "@/components/subscribe-entry";
import {
  browseDiscoveryCollection,
  collectionHref,
  collectionToRow,
  fetchDiscoveryPage,
  type DiscoveryPageData,
  type DiscoveryPageSection,
} from "@/lib/api/discover";
import { HttpError } from "@/lib/http";
import {
  discoveryFilterCount,
  discoveryFiltersKey,
  type DiscoveryFilters,
} from "@/lib/discovery-filters";
import { useHeroAmbientColor } from "@/lib/hero-ambient-color";
import { useMediaDetail } from "@/lib/media-detail";
import { TOP_BAR_LARGE_TITLE_CLASS, usePageChrome } from "@/lib/page-chrome";
import { usePermissions } from "@/lib/permissions";
import { useTheme } from "@/lib/ui-prefs";
import { useScrollRestoration } from "@/lib/use-scroll-restoration";
import { useIsMobile } from "@/lib/use-media-query";
import { IMAGE_ASPECT } from "@/lib/image-proxy";
import { useElementCoverWidth } from "@/lib/image-resolution";
import { useTapGuard } from "@/lib/use-tap-guard";
import type {
  MediaItem,
  MediaRowData,
  MediaSource,
  MediaType,
} from "@/lib/media-types";

/**
 * 发现页（发现电影 / 发现剧集）：Netflix 式「Hero 大横幅 + 分类横滚行」。
 *
 * 页面纵向结构：
 *   1. HeroBanner —— 精选影片轮播大横幅（宽幅剧照 + 渐变蒙版 + 标题区 + 操作按钮）
 *   2. 若干 MediaRow —— 「今日热榜（排名变体）/ 热门 / 高分 / …」横滚海报行
 *
 * 渐进加载：先读取 Web 展示清单，再把每个 collectionRef 原样交给领域接口。
 * 页面只知道一个片单应画成 Hero、排名行还是普通行，不再拼装 provider 专属
 * 端点。展示清单与片单预览都做模块级内存缓存，视角切换后可以即时恢复。
 */
const pageCache = new Map<string, DiscoveryPageData>();
const collectionCache = new Map<string, MediaRowData>();

/** 加载失败信息：除文案外带上后端错误码与引导提示，驱动引导式错误态。 */
interface DiscoverErrorInfo {
  message: string;
  /** 后端统一错误码（如 UPSTREAM_UNREACHABLE = 网络级不可达） */
  code?: string;
  /** 后端给的下一步操作提示（如去网络设置配代理） */
  hint?: string;
}

/** 从任意异常提取结构化错误信息（HttpError 携带后端信封的 code/details）。 */
function toErrorInfo(err: unknown): DiscoverErrorInfo {
  if (err instanceof HttpError) {
    const payload = err.details as
      | { code?: string; details?: { service?: string; hint?: string }[] }
      | undefined;
    return {
      message: err.message,
      code: payload?.code,
      hint: payload?.details?.[0]?.hint,
    };
  }
  return { message: (err as Error)?.message || "加载失败，请稍后重试" };
}

/**
 * 筛选条件的本地状态 + 地址栏同步。
 *
 * 条件改动要**立刻**反映在菜单勾选与结果页胶囊上（选中即生效），不能等 router.replace
 * 把新 searchParams 从服务端绕一圈回来，所以本地先存一份、再把地址同步过去；页面不再
 * 按条件整棵重建（page.tsx 的 key 只含类型与数据源），结果页按 filters 原地重查。
 *
 * 地址回流（新的 urlFilters）分两种：
 *   - 自己写出去的回声：按写出顺序记在 pendingKeys 里，回来一个就划掉它及更早的，
 *     不采纳——快速连改两次时，先回来的旧回声不能把本地状态拨回去；
 *   - 外部导航（前进 / 后退、站内别处带条件的链接）：不在 pendingKeys 里，采纳。
 *
 * 银玻璃用 replace（逐项改条件不该堆出一串历史）；Netflix 维持原来「查看结果」一次 push。
 */
function useUrlSyncedFilters(urlFilters: DiscoveryFilters, mediaType: MediaType, push: boolean) {
  const router = useRouter();
  const [filters, setFilters] = useState(urlFilters);
  const pendingKeysRef = useRef<string[]>([]);
  const urlKey = discoveryFiltersKey(urlFilters);

  useEffect(() => {
    const pending = pendingKeysRef.current;
    const echo = pending.indexOf(urlKey);
    if (echo >= 0) {
      pending.splice(0, echo + 1);
      return;
    }
    setFilters((current) => (discoveryFiltersKey(current) === urlKey ? current : urlFilters));
  }, [urlFilters, urlKey]);

  const changeFilters = useCallback(
    (next: DiscoveryFilters) => {
      const query = discoveryFiltersKey(next);
      if (query === discoveryFiltersKey(filters)) return;
      setFilters(next);
      pendingKeysRef.current.push(query);
      const href = `/discover/${mediaType}${query ? `?${query}` : ""}` as Route;
      if (push) router.push(href);
      else router.replace(href, { scroll: false });
    },
    [filters, mediaType, push, router],
  );
  return { filters, changeFilters };
}

export function DiscoverView({
  mediaType,
  source,
  filters: urlFilters,
  currentYear,
}: {
  mediaType: MediaType;
  source: MediaSource;
  /** 地址栏里的筛选条件（页面按 searchParams 解析） */
  filters: DiscoveryFilters;
  /** 服务端确定年份，避免跨年瞬间 SSR 与浏览器水合生成不同选项。 */
  currentYear: number;
}) {
  const router = useRouter();
  const isNf = useTheme().structural;
  const cacheKey = `${mediaType}:${source}`;
  const { filters, changeFilters } = useUrlSyncedFilters(urlFilters, mediaType, isNf);
  const filtering = source === "tmdb" && discoveryFilterCount(filters) > 0;
  // 滚动位置按「首页 / 结果页」两档记：条件在结果页里就地改，不该每改一次就跳去另一份位置
  const scrollRef = useScrollRestoration(`discover:${cacheKey}:${filtering ? "filtered" : "home"}`);
  // 银玻璃 Hero 的滚动联动：滚动距离写成页面根上的 --hero-scroll（视差、文字淡出、氛围底退淡都读它）
  const scrollRootRef = useRef<HTMLDivElement | null>(null);
  const pageScrollRef = useCallback(
    (node: HTMLDivElement | null) => {
      scrollRootRef.current = node;
      scrollRef(node);
    },
    [scrollRef],
  );
  const heroRootRef = useRef<HTMLDivElement>(null);
  const [heroIndex, setHeroIndex] = useState(0);
  const [page, setPage] = useState<DiscoveryPageData | null>(() => pageCache.get(cacheKey) ?? null);
  // Hero 三态：undefined=加载中（出骨架）、[]=无或失败（收起）、有值=轮播
  const [hero, setHero] = useState<MediaItem[] | undefined>();
  // 每行三态：undefined=加载中（出骨架）、"error"=失败（收起）、有值=渲染
  const [rowsByRef, setRowsByRef] = useState<Record<string, MediaRowData | "error">>({});
  const [error, setError] = useState<DiscoverErrorInfo | null>(null);
  // 重试计数器：点「重试」时 +1，触发 effect 重新拉取
  const [reloadKey, setReloadKey] = useState(0);

  // 页脚切换院线地区后：清掉片单缓存并重拉——「正在热映/即将上映」的内容
  // 随地区而变，留着旧缓存用户会以为切换没生效
  const reloadAfterRegionChange = useCallback(() => {
    pageCache.clear();
    collectionCache.clear();
    setRowsByRef({});
    setHero(undefined);
    setReloadKey((k) => k + 1);
  }, []);

  useEffect(() => {
    if (filtering) return;
    const controller = new AbortController();
    setError(null);
    setHero(undefined);

    const cacheKeyFor = (section: DiscoveryPageSection) =>
      `${section.collectionRef}:${section.previewLimit}`;

    // 已缓存的片单直接进入初始状态，未缓存的保持 undefined（骨架）等待逐项到达。
    const seedRows = (sections: DiscoveryPageSection[]) => {
      const seeded: Record<string, MediaRowData | "error"> = {};
      for (const section of sections) {
        const cached = collectionCache.get(cacheKeyFor(section));
        if (cached) seeded[section.collectionRef] = cached;
      }
      setRowsByRef(seeded);
      return seeded;
    };

    // 展示清单就绪后逐个读取片单：先到先渲染；Hero 失败只收起自身，普通
    // 分区全部失败且没有缓存时，整页进入带网络引导的错误态。
    const loadPage = (pageData: DiscoveryPageData) => {
      const heroSection = pageData.sections.find((section) => section.presentation === "hero");
      const rowSections = pageData.sections.filter((section) => section.presentation !== "hero");
      const seeded = seedRows(rowSections);

      if (heroSection) {
        const cached = collectionCache.get(cacheKeyFor(heroSection));
        if (cached) {
          setHero(cached.items);
        } else {
          browseDiscoveryCollection(heroSection.collectionRef, heroSection.previewLimit, {
            signal: controller.signal,
          })
            .then((collection) => {
              const row = collectionToRow(collection);
              collectionCache.set(cacheKeyFor(heroSection), row);
              if (!controller.signal.aborted) setHero(row.items);
            })
            .catch(() => {
              if (!controller.signal.aborted) setHero([]);
            });
        }
      } else {
        setHero([]);
      }

      const pending = rowSections.filter((section) => !seeded[section.collectionRef]);
      let failed = 0;
      let firstError: DiscoverErrorInfo | null = null;
      for (const section of pending) {
        browseDiscoveryCollection(section.collectionRef, section.previewLimit, {
          signal: controller.signal,
        })
          .then((collection) => {
            const row = collectionToRow(collection);
            collectionCache.set(cacheKeyFor(section), row);
            if (!controller.signal.aborted) {
              setRowsByRef((prev) => ({ ...prev, [section.collectionRef]: row }));
            }
          })
          .catch((err: unknown) => {
            if (controller.signal.aborted) return;
            firstError ??= toErrorInfo(err);
            failed += 1;
            setRowsByRef((prev) => ({ ...prev, [section.collectionRef]: "error" }));
            if (failed === pending.length && pending.length === rowSections.length) {
              setError(firstError);
            }
          });
      }
    };

    const cachedPage = pageCache.get(cacheKey);
    setPage(cachedPage ?? null);
    if (cachedPage) {
      loadPage(cachedPage);
    } else {
      fetchDiscoveryPage(mediaType, source, { signal: controller.signal })
        .then((data) => {
          pageCache.set(cacheKey, data);
          if (controller.signal.aborted) return;
          setPage(data);
          loadPage(data);
        })
        .catch((err: unknown) => {
          if (!controller.signal.aborted) setError(toErrorInfo(err));
        });
    }
    return () => controller.abort();
  }, [cacheKey, filtering, mediaType, reloadKey, source]);

  const switchSource = useCallback(
    (nextSource: MediaSource) => {
      if (nextSource === source) return;
      router.push(`/discover/${mediaType}?source=${nextSource}` as Route);
    },
    [mediaType, router, source],
  );

  // 电影/剧集切换（只在移动端：Netflix 是顶栏右上角的分段，银玻璃在左上角标题菜单里；
  // 桌面端顶栏导航已有「电影 / 剧集」两个链接，不再重复放）。切换保留当前
  // 数据源视角。
  const chrome = usePageChrome();
  const isMobile = useIsMobile();
  // Netflix 主题（isNf，见上）：工具栏悬浮在 Hero 上（不自占一条）、Hero 全出血（§5.3 构图）
  const PageActions = useResolvedTheme().slots.pageActions;
  const switchMediaType = useCallback(
    (next: MediaType) => {
      if (next === mediaType) return;
      router.push(`/discover/${next}?source=${source}` as Route);
    },
    [mediaType, router, source],
  );

  // 桌面工具栏（两个主题）与 Netflix 手机顶栏的控件组。
  const controls = useMemo(
    () => (
      <div className="flex items-center gap-2">
        {isMobile && <MediaTypeSwitcher value={mediaType} onChange={switchMediaType} />}
        <SourceSwitcher value={source} onChange={switchSource} compact={isMobile} />
        {/* 筛选仅 TMDB 源支持：豆瓣视角下不再整体隐藏（隐藏会让顶栏右栏
            跳动重排），改为禁用置灰原地保留，规则由禁用态自己表达。
            位置按方案 C 排在两颗胶囊之后、紧邻搜索键，不再夹在中间。
            银玻璃桌面用与手机同一套下拉菜单；Netflix 维持组合筛选弹窗。 */}
        {isNf ? (
          <DiscoveryFilterControl
            mediaType={mediaType}
            filters={filters}
            currentYear={currentYear}
            onApply={changeFilters}
            compact={isMobile}
            disabled={source !== "tmdb"}
          />
        ) : (
          <DiscoveryFilterMenu
            mediaType={mediaType}
            filters={filters}
            currentYear={currentYear}
            onChange={changeFilters}
            disabled={source !== "tmdb"}
          />
        )}
      </div>
    ),
    [changeFilters, currentYear, filters, isMobile, isNf, mediaType, source, switchMediaType, switchSource],
  );

  // 发现页是侧栏一级入口，没有 PageNav，页面控件若自己吸一条顶栏，窄屏上
  // 就会摞在全局顶栏底下变成两排 header。移动端改为挂进全局顶栏那一行，
  // 桌面端维持原来的吸顶工具栏不变。Netflix 手机端维持把三组控件都挂顶栏右侧。
  //
  // 银玻璃手机（2026-09-27 对齐原生 App，DiscoverView.swift 的 toolbarContent）：
  //   - 左上角是标题菜单：大字「电影 / 剧集」+ 小字数据源 + ⌄，点开切类型与数据源；
  //   - 右上角只剩筛选键（仅 TMDB），最右是外壳挂的搜索。
  // 原先挂在液态玻璃底栏「底部附件」位的电影 / 剧集分段与顶栏的数据源胶囊一并退役。
  const silverMobile = isMobile && !isNf;
  const titleMenu = useMemo(
    () =>
      silverMobile ? (
        <DiscoverTitleMenu
          mediaType={mediaType}
          source={source}
          onMediaTypeChange={switchMediaType}
          onSourceChange={switchSource}
        />
      ) : null,
    [mediaType, silverMobile, source, switchMediaType, switchSource],
  );
  const silverFilterMenu = useMemo(
    () =>
      silverMobile && source === "tmdb" ? (
        <DiscoveryFilterMenu
          mediaType={mediaType}
          filters={filters}
          currentYear={currentYear}
          onChange={changeFilters}
          compact
        />
      ) : null,
    [changeFilters, currentYear, filters, mediaType, silverMobile, source],
  );
  const setTopBarActions = chrome?.setTopBarActions;
  useEffect(() => {
    if (!isMobile || !setTopBarActions) return;
    return setTopBarActions(silverMobile ? silverFilterMenu : controls);
  }, [controls, isMobile, setTopBarActions, silverFilterMenu, silverMobile]);
  const setTopBarLeading = chrome?.setTopBarLeading;
  useEffect(() => {
    if (!titleMenu || !setTopBarLeading) return;
    return setTopBarLeading(titleMenu);
  }, [setTopBarLeading, titleMenu]);

  // 银玻璃手机的沉浸式 Hero：只在本页**真的会画 Hero** 时才把页面提到顶栏底下
  // ——展示清单声明了 Hero 且数据不是「无/失败」（undefined = 还在加载、骨架占位）。
  // 豆瓣视角的清单没有 Hero，若照样上提，第一行海报就钻进顶栏雾层里
  // （2026-09-23 用户截图）；这种页面按普通页排，顶部留呼吸位。
  const immersiveHero =
    !isNf &&
    Boolean(page?.sections.some((section) => section.presentation === "hero")) &&
    (hero === undefined || hero.length > 0);
  // 氛围底（银玻璃有 Hero 时，桌面与手机同订阅首页）：取当前那张剧照的主色
  const ambient = immersiveHero;
  const currentHero = hero && hero.length > 0 ? hero[Math.min(heroIndex, hero.length - 1)] : null;
  const tint = useHeroAmbientColor(ambient && currentHero ? heroBackdropOf(currentHero) : null);
  // 桌面沉浸：窗口背景换成当前这张剧照（同订阅首页，见 useHeroWindowBackdrop）；筛选结果页没有 Hero
  useHeroWindowBackdrop(
    ambient && !isMobile && !filtering && currentHero ? heroBackdropOf(currentHero) : null,
  );
  useHeroScrollVar(scrollRootRef, heroRootRef, `${Boolean(page)}:${filtering}:${Boolean(error)}`);

  // 桌面工具栏（手机的控件在全局顶栏里）
  const pageTitle = mediaType === "movie" ? "发现电影" : "发现剧集";
  const toolbar = isMobile ? null : isNf ? (
    // Netflix：fixed 悬浮在视口右上（顶栏下方），不随页面滚动移位——发现页
    // 一滚数屏，筛选/数据源入口跟着内容滚走后想换源就得滚回顶部。
    // 页面悬浮操作簇走主题坑位（与详情页 ⋯ 菜单同一规格）而不是手写一份
    // 同款 fixed 类：手写副本会与组件规格漂移（此前 z-20 vs z-30），改一处漏
    // 一处。唯一差异是层级 20→30：与返回键同层，仍在 z-40 顶栏之下。
    PageActions ? <PageActions>{controls}</PageActions> : null
  ) : (
    // 银玻璃桌面：与订阅首页同一形态——页内标题在左、控件在右；有 Hero 时叠在大图顶部的
    // 压暗上（随页面滚走），没有 Hero（豆瓣、筛选结果）时是普通的页头行
    <div
      className={`z-20 flex items-center justify-between gap-3 px-6 ${
        // 叠在大图上时是绝对定位（不吃滚动区的让位内边距），自己补上侧栏让位
        immersiveHero && !filtering
          ? "pointer-events-none absolute inset-x-0 top-0 pl-[calc(var(--immersive-inset,0px)+1.5rem)] pt-5"
          : "sticky top-0 pb-3 pt-7"
      }`}
    >
      <h2 className="text-on-image text-[26px] font-bold leading-tight tracking-[-0.02em] text-white">
        {pageTitle}
      </h2>
      <div className="pointer-events-auto flex items-center gap-2">{controls}</div>
    </div>
  );

  /**
   * 银玻璃的页面外框，与订阅首页同一形态：
   *   - 页面根承载 --hero-scroll（视差、文字淡出、氛围底退淡都读它）与氛围底：
   *     底色跟着当前剧照的主色走，自带纯黑实底盖住全站半透明蒙版；
   *   - 手机有 Hero 时整页上提到屏幕物理顶边（抵掉主区为顶栏预留的内边距）；没有 Hero
   *     （豆瓣视角）时按普通页排、不铺氛围底，仍是全站蒙版；
   *   - 桌面：有 Hero 时是沉浸外框（顶到窗口上右下沿、不画边框，窗口背景换成同一张剧照），
   *     没有 Hero 时是一张深色圆角卡片（见 immersive-hero.tsx 的两种外框）。
   */
  const silverFrame = (children: React.ReactNode, immersive = immersiveHero) => (
    <div
      ref={heroRootRef}
      className={`relative isolate flex min-h-0 flex-1 flex-col ${
        immersive
          ? `max-md:-mt-[calc(var(--safe-top)+var(--mobile-topbar-h))] ${DESKTOP_IMMERSIVE_FRAME}`
          : DESKTOP_CARD_FRAME
      }`}
    >
      {(immersive || !isMobile) && (
        <HeroAmbientBackdrop
          color={ambient ? tint : null}
          windowed={immersive}
          className="-z-10 max-md:bottom-[calc(-1*var(--vp-overshoot,0px))]"
        />
      )}
      {children}
    </div>
  );

  // 筛选结果与错误态没有 Hero：银玻璃桌面仍放在同一张卡片里，与首页来回切换时整页形态不跳
  if (filtering) {
    const results = (
      <div
        ref={scrollRef}
        data-scroll-root
        className="scroll-thin scroll-safe flex-1 overflow-y-auto pb-10 max-md:pt-4"
      >
        {toolbar}
        <FilteredDiscoveryView
          mediaType={mediaType}
          filters={filters}
          currentYear={currentYear}
          onChange={changeFilters}
        />
      </div>
    );
    return isNf ? results : silverFrame(results, false);
  }

  if (error) {
    const failure = (
      <div className={`flex flex-1 flex-col ${isNf ? "relative" : "max-md:pt-4"}`}>
        {toolbar}
        <DiscoverError error={error} onRetry={() => setReloadKey((k) => k + 1)} />
      </div>
    );
    return isNf ? failure : silverFrame(failure, false);
  }
  if (!page) {
    // 银玻璃：与下方正式页面同一副外框（手机顶到屏幕物理顶边、桌面同一张卡片），
    // 骨架 Hero 与真实 Hero 原位替换、不跳版；Netflix 维持原样
    return isNf ? (
      <div className="relative flex flex-1 flex-col">
        {toolbar}
        <DiscoverSkeleton fullBleed />
      </div>
    ) : (
      silverFrame(
        <div className={`relative flex flex-1 flex-col ${IMMERSIVE_INSET}`}>
          {toolbar}
          <DiscoverSkeleton />
        </div>,
        true,
      )
    );
  }
  const scrollBody = (
    <div
      ref={pageScrollRef}
      className={`scroll-thin scroll-safe relative flex-1 overflow-y-auto pb-10 ${IMMERSIVE_INSET} ${
        // 银玻璃手机：Hero 是沉浸式通栏大图，要从屏幕物理顶边开始、从状态栏与
        // 顶栏雾层底下穿过——上提由外层页面根承担（见下方 silver 分支）；没有 Hero
        // 的页面顶部留 16px 呼吸位。Netflix 主题（两端）一律不动。
        immersiveHero || isNf ? "" : "max-md:pt-4"
      }`}
    >
      {toolbar}
      {/* Hero 区：展示清单声明 Hero 时先占位，数据到达后换成轮播（两个主题都铺满页面宽度） */}
      {page.sections.some((section) => section.presentation === "hero") && hero === undefined && (
        <HeroBleed>
          <HeroSkeleton fullBleed={isNf} />
        </HeroBleed>
      )}
      {hero && hero.length > 0 &&
        (isNf ? (
          <HeroBanner items={hero} />
        ) : (
          <HeroBleed>
            <SilverDiscoverHero items={hero} index={heroIndex} onIndexChange={setHeroIndex} />
          </HeroBleed>
        ))}
      {/* 银玻璃手机：有 Hero 时图已向下渐隐，常规行紧跟着接上（首行标题落在渐隐带里）；
          没有 Hero（豆瓣清单）时容器自带的 max-md:pt-4 就是顶栏下的全部留白，行区不再
          叠 mt-8——与媒体库页头「顶栏下 16px」同一档，否则首行标题离顶栏 48px 空得发虚 */}
      {/* 银玻璃手机行间距 28px（同原生 App 发现页），Netflix 与桌面维持 32px */}
      <div
        className={`mt-8 space-y-8 ${
          immersiveHero ? "max-md:mt-3 max-md:space-y-7" : isNf ? "" : "max-md:mt-0 max-md:space-y-7"
        }`}
      >
        {page.sections.filter((section) => section.presentation !== "hero").map((section) => {
          const row = rowsByRef[section.collectionRef];
          // 失败或条目太少（空 items）的行整行收起
          if (row === "error") return null;
          if (row && row.items.length === 0) return null;
          if (!row) return <RowSkeleton key={section.collectionRef} stub={section} />;
          const href = section.supportsFullListing
            ? collectionHref(section.collectionRef)
            : undefined;
          const moreHref = href as Route | undefined;
          return (
            <MediaRow
              key={row.id}
              row={moreHref ? { ...row, items: row.items.slice(0, 10) } : row}
              moreHref={moreHref}
            />
          );
        })}
      </div>
      {/* 院线地区就地设置：只在有院线榜单的电影 TMDB 视角出现 */}
      {mediaType === "movie" && source === "tmdb" && (
        <DiscoverRegionFooter onChanged={reloadAfterRegionChange} />
      )}
    </div>
  );
  if (isNf) return scrollBody;
  return silverFrame(scrollBody);
}

/** 数据源视角切换：两个视角分别缓存，来回切换不会重复请求。compact 档给
 *  移动端顶栏用：字号、内边距、底板配方与类型胶囊完全同档（text-sub +
 *  py-1.5 px-2.5 + 标准玻璃底），全行控件一套规格一套配方；宽排布顺序
 *  （类型在前、来源在后）表达先选内容、再选来源的动线。宽度预算：375px
 *  视口下 ≈364px 放得下，容器横向滚动仅作更窄设备的兜底。 */
function SourceSwitcher({
  value,
  onChange,
  compact = false,
}: {
  value: MediaSource;
  onChange: (source: MediaSource) => void;
  compact?: boolean;
}) {
  return (
    // 胶囊底材与订阅页 MediaTypeSwitcher 逐类一致（不加 solid-popover 浮层钩子）：
    // 2026-09-20 用户拍板——切换胶囊全站一套材质，Netflix 主题下保持玻璃底，
    // 不随浮层换实底；选中态白系语言原样。
    <div className="flex shrink-0 rounded-full border border-white/10 bg-black/35 p-1 backdrop-blur-xl">
      {(["tmdb", "douban"] as const).map((source) => (
        <button
          key={source}
          type="button"
          aria-pressed={value === source}
          onClick={() => onChange(source)}
          className={`rounded-full font-semibold transition ${
            compact ? "px-2.5 py-1.5 text-sub" : "py-1.5 px-4 text-sub"
          } ${
            value === source
              ? "bg-white/15 text-white shadow-sm"
              : "text-[var(--text-muted)] hover:text-white"
          }`}
        >
          {source === "tmdb" ? "TMDB" : "豆瓣"}
        </button>
      ))}
    </div>
  );
}

/**
 * 银玻璃手机发现页左上角的标题菜单（对应 iOS DiscoverView.swift 的 titleMenu）：
 * 大字「电影 / 剧集」+ 小字数据源 + ⌄，点开两组单选——类型、数据源。切换沿用
 * switchMediaType / switchSource（切类型保留数据源、切数据源保留类型，都清空筛选）。
 * 取代了原先底栏附件里的电影 / 剧集分段与顶栏的 TMDB / 豆瓣 胶囊。
 */
function DiscoverTitleMenu({
  mediaType,
  source,
  onMediaTypeChange,
  onSourceChange,
}: {
  mediaType: MediaType;
  source: MediaSource;
  onMediaTypeChange: (type: MediaType) => void;
  onSourceChange: (source: MediaSource) => void;
}) {
  const typeLabel = mediaType === "tv" ? "剧集" : "电影";
  const sourceLabel = source === "douban" ? "豆瓣" : "TMDB";
  const groupLabel = "px-3 pb-1 pt-1.5 text-caption text-[var(--text-faint)]";
  const check = (
    <DropdownMenu.ItemIndicator className="ml-auto">
      <CheckIcon className="size-3.5 text-[var(--info)]" />
    </DropdownMenu.ItemIndicator>
  );
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          aria-label={`正在看${typeLabel}，数据源${sourceLabel}；切换类型或数据源`}
          className="flex min-w-0 items-baseline gap-1.5 rounded-lg outline-none transition-opacity active:opacity-60 focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)]"
        >
          {/* 30px：比其他标签根页的大标题（28px）略大一档，同 App 的 30pt 标题菜单 */}
          <span className={`${TOP_BAR_LARGE_TITLE_CLASS} !text-[30px]`}>{typeLabel}</span>
          <span className="shrink-0 text-caption font-semibold text-[var(--text-muted)]">
            {sourceLabel}
          </span>
          <ChevronDownIcon className="size-3.5 shrink-0 self-center text-[var(--text-muted)]" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="start"
          sideOffset={8}
          collisionPadding={12}
          className="menu-surface z-50 min-w-[12rem] p-1"
        >
          <DropdownMenu.Label className={groupLabel}>类型</DropdownMenu.Label>
          <DropdownMenu.RadioGroup
            value={mediaType}
            onValueChange={(value) => onMediaTypeChange(value as MediaType)}
          >
            <DropdownMenu.RadioItem value="movie" className={DISCOVER_MENU_ITEM_CLASS}>
              <FilmIcon className="size-4 shrink-0 text-white/55" />
              电影
              {check}
            </DropdownMenu.RadioItem>
            <DropdownMenu.RadioItem value="tv" className={DISCOVER_MENU_ITEM_CLASS}>
              <TvIcon className="size-4 shrink-0 text-white/55" />
              剧集
              {check}
            </DropdownMenu.RadioItem>
          </DropdownMenu.RadioGroup>
          <DropdownMenu.Separator className="my-1 h-px bg-white/[0.07]" />
          <DropdownMenu.Label className={groupLabel}>数据源</DropdownMenu.Label>
          <DropdownMenu.RadioGroup
            value={source}
            onValueChange={(value) => onSourceChange(value as MediaSource)}
          >
            <DropdownMenu.RadioItem value="tmdb" className={DISCOVER_MENU_ITEM_CLASS}>
              TMDB
              {check}
            </DropdownMenu.RadioItem>
            <DropdownMenu.RadioItem value="douban" className={DISCOVER_MENU_ITEM_CLASS}>
              豆瓣
              {check}
            </DropdownMenu.RadioItem>
          </DropdownMenu.RadioGroup>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** 电影/剧集切换（移动端顶栏右上角）：与订阅页的类型切换同一位置同一形态，
    走路由切换（/discover/movie ↔ /discover/tv），各视角独立缓存。
    只在移动端渲染。控件规格与 subscriptions-view 的 SubscriptionTypeSwitcher
    完全同构（同容器、text-sub 字号档、py-1.5 px-2.5、激活态 bg-white/15），
    保持全站切换胶囊一套语言；宽度预算：375px 视口下字标 + 三控件 + 搜索键
    ≈351px 放得下，容器横向滚动仅作更窄设备的兜底。 */
function MediaTypeSwitcher({
  value,
  onChange,
}: {
  value: MediaType;
  onChange: (type: MediaType) => void;
}) {
  const labels: Record<MediaType, string> = { movie: "电影", tv: "剧集" };
  return (
    <div
      className="flex shrink-0 rounded-full border border-white/10 bg-black/35 p-1 backdrop-blur-xl"
      aria-label="内容类型"
    >
      {(["movie", "tv"] as const).map((type) => (
        <button
          key={type}
          type="button"
          aria-pressed={value === type}
          onClick={() => onChange(type)}
          className={`rounded-full px-2.5 py-1.5 text-sub font-semibold transition ${
            value === type
              ? "bg-white/15 text-white shadow-sm"
              : "text-[var(--text-muted)] hover:text-white"
          }`}
        >
          {labels[type]}
        </button>
      ))}
    </div>
  );
}

/** 布局到达前的整页骨架（Hero 大块 + 两行海报）；布局是毫秒级的，一闪而过。 */
function DiscoverSkeleton({ fullBleed = false }: { fullBleed?: boolean }) {
  return (
    <div className="flex-1 overflow-hidden pb-10" aria-busy="true" aria-label="发现页加载中">
      <HeroBleed>
        <HeroSkeleton fullBleed={fullBleed} />
      </HeroBleed>
      {[0, 1].map((row) => (
        <div key={row} className={`mt-10 ${fullBleed ? "" : "px-6 max-md:px-4"}`}>
          <div className="h-4 w-28 animate-pulse rounded bg-white/[0.08]" />
          <div className="mt-4 flex gap-4 overflow-hidden">
            <RowItemsSkeleton />
          </div>
        </div>
      ))}
    </div>
  );
}

/** Netflix 主题手机端的横幅高度（银玻璃的高度见 SILVER_DISCOVER_HERO_HEIGHT） */
const HERO_MOBILE_SIZE_NF = "max-md:h-[38vh] max-md:min-h-[230px]";

/** Hero 大横幅的占位块（与真实 Hero 同尺寸，数据到达后原位替换不跳版）。 */
function HeroSkeleton({ fullBleed = false }: { fullBleed?: boolean }) {
  return (
    <div
      className={`animate-pulse bg-white/[0.05] ${
        fullBleed ? `h-[46vh] min-h-[320px] ${HERO_MOBILE_SIZE_NF}` : SILVER_DISCOVER_HERO_HEIGHT
      }`}
    />
  );
}

/**
 * 单行加载骨架：行标题实显（来自布局），海报区闪烁占位。
 * 标题栏与横滚区的留白复刻 MediaRow 的布局，数据到达后原位替换不跳版；
 * 这一行行「亮着名字等数据」的骨架就是页面的分区加载进度。
 */
function RowSkeleton({ stub }: { stub: { title: string } }) {
  const inset = "page-inset";
  return (
    <section aria-busy="true" aria-label={`「${stub.title}」加载中`}>
      <div className={`mb-3 max-md:mb-2 ${inset}`}>
        <h3 className="text-on-image text-body-lg font-semibold tracking-[-0.01em] text-[var(--text)]">
          {stub.title}
        </h3>
      </div>
      <div className={`flex gap-4 overflow-hidden pb-1 pt-1 max-md:gap-3 ${inset}`}>
        <RowItemsSkeleton />
      </div>
    </section>
  );
}

/** 一排海报占位卡，与真实海报行同一规格。 */
function RowItemsSkeleton() {
  return (
    <>
      {Array.from({ length: 8 }, (_, i) => (
        <div
          key={i}
          // m-row-skel：Netflix 主题下真实行卡宽走 .m-row 的 clamp(100px,30vw,156px)
          // 公式（globals.css），骨架卡挂同一钩子避免数据到达时整行跳宽
          className="m-row-skel aspect-[2/3] w-[152px] shrink-0 animate-pulse rounded-2xl bg-white/[0.05] max-md:w-[126px] xl:w-[164px]"
        />
      ))}
    </>
  );
}

/** 加载失败态：展示后端的中文错误信息（如未配置 TMDB Key 的引导）并提供重试。
 *
 * 网络级不可达（UPSTREAM_UNREACHABLE，含熔断快速失败）渲染引导式错误：
 * 说明原因 + 后端 hint + 「前往网络设置」按钮，替代干等骨架屏。
 */
function DiscoverError({ error, onRetry }: { error: DiscoverErrorInfo; onRetry: () => void }) {
  const unreachable = error.code === "UPSTREAM_UNREACHABLE";
  // 网络设置是超管页面：成员只给「重试」
  const { isAdmin } = usePermissions();
  return (
    <div className="flex flex-1 items-center justify-center px-6">
      {/* solid-card：空态卡挂卡片材质钩子（银玻璃零变化） */}
      <div className="solid-card max-w-md rounded-2xl border border-white/[0.07] bg-[rgba(14,16,22,0.45)] p-8 text-center backdrop-blur-xl">
        {unreachable && (
          <span className="icon-chip mx-auto mb-4 flex size-11 !rounded-2xl">
            <GlobeIcon className="size-5" />
          </span>
        )}
        <p className="text-body-lg font-semibold text-[var(--text)]">
          {unreachable ? "无法连接数据源" : "发现页加载失败"}
        </p>
        <p className="mt-2 break-all text-ui leading-6 text-[var(--text-muted)]">{error.message}</p>
        {unreachable && error.hint && (
          <p className="mt-2 text-sub leading-6 text-[var(--text-faint)]">{error.hint}</p>
        )}
        <div className="mt-5 flex items-center justify-center gap-3">
          {unreachable && isAdmin && (
            <Link
              href={"/settings/network" as Route}
              className="btn-accent flex h-9 items-center rounded-full px-5 text-ui font-semibold"
            >
              前往网络设置
            </Link>
          )}
          <button
            type="button"
            onClick={onRetry}
            className={`${unreachable && isAdmin ? "btn-glass" : "btn-accent"} h-9 rounded-full px-5 text-ui font-semibold`}
          >
            重试
          </button>
        </div>
      </div>
    </div>
  );
}

/** Hero 轮播间隔（毫秒） */
const HERO_INTERVAL = 8000;

/**
 * Hero 大横幅：精选影片自动轮播。
 * 所有帧常驻 DOM 叠放，靠 opacity 交叉淡入淡出（避免切换时图片重新加载闪白）；
 * 文字区跟随当前帧一起淡入。手动切换（桌面悬停浮现的两侧箭头 / 触屏横向
 * 滑动 / 右下角圆点）都会重置自动轮播计时。
 * 图片按需装载：帧壳常驻，但 w1280 大图只有轮到（当前帧/下一帧）才写入 src，
 * 首屏不必一次下载解码全部 6 张；已展示过的帧保持已加载，交叉淡出不闪白。
 */
function HeroBanner({ items }: { items: MediaItem[] }) {
  const [index, setIndex] = useState(0);
  // 触屏滑动切换的起点（无悬停设备不显示箭头，滑动是唯一的大面积切换手势）
  const touchStart = useRef<{ x: number; y: number } | null>(null);

  const switchSlide = (offset: number) => {
    setIndex((current) => (current + offset + items.length) % items.length);
  };

  useEffect(() => {
    if (items.length <= 1) return;
    const timer = setInterval(() => {
      // 后台标签页不推进轮播：推进了也没人看，白白解码下一张大图并重渲染
      if (document.hidden) return;
      setIndex((i) => (i + 1) % items.length);
    }, HERO_INTERVAL);
    return () => clearInterval(timer);
    // index 作为依赖：手动切换后重置轮播计时，避免刚点完就被自动切走
  }, [items.length, index]);

  const next = (index + 1) % items.length;
  return (
    <div
      className={`group relative h-[46vh] min-h-[320px] w-full overflow-hidden ${HERO_MOBILE_SIZE_NF}`}
      onTouchStart={(e) => {
        const t = e.touches[0];
        touchStart.current = { x: t.clientX, y: t.clientY };
      }}
      onTouchEnd={(e) => {
        const start = touchStart.current;
        touchStart.current = null;
        if (!start || items.length <= 1) return;
        const t = e.changedTouches[0];
        const dx = t.clientX - start.x;
        const dy = t.clientY - start.y;
        // 水平位移够大且明显横向才算切换手势：纵向滚动起手、普通点按
        // （tapGuard 负责进详情）都不受影响
        if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.5) {
          switchSlide(dx < 0 ? 1 : -1);
        }
      }}
    >
      {items.map((item, i) => (
        <HeroSlide
          key={item.id}
          item={item}
          active={i === index}
          preload={i === index || i === next}
        />
      ))}

      {/* 手动切换按钮：桌面悬停浮现。无悬停设备直接不渲染出来——常显会压住
          标题文字（截图实锤），"点一下再浮现"又与整块点击进详情冲突，触屏
          的切换交给横向滑动与右下圆点。 */}
      {items.length > 1 && (
        <>
          <button
            type="button"
            aria-label="切换到上一部"
            onClick={() => switchSlide(-1)}
            className="absolute left-3 top-1/2 z-10 flex size-11 -translate-y-1/2 items-center justify-center rounded-full bg-black/35 text-white/80 opacity-0 ring-1 ring-white/15 backdrop-blur-sm transition hover:bg-black/55 hover:text-white group-hover:opacity-100 focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/80 [@media(hover:none)]:hidden"
          >
            <ChevronLeftIcon className="size-6" />
          </button>
          <button
            type="button"
            aria-label="切换到下一部"
            onClick={() => switchSlide(1)}
            className="absolute right-3 top-1/2 z-10 flex size-11 -translate-y-1/2 items-center justify-center rounded-full bg-black/35 text-white/80 opacity-0 ring-1 ring-white/15 backdrop-blur-sm transition hover:bg-black/55 hover:text-white group-hover:opacity-100 focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/80 [@media(hover:none)]:hidden"
          >
            <ChevronRightIcon className="size-6" />
          </button>
        </>
      )}

      {/* 轮播指示点 */}
      {items.length > 1 && (
        <div className="absolute bottom-4 right-5 z-10 flex gap-1.5">
          {items.map((item, i) => (
            <button
              key={item.id}
              type="button"
              aria-label={`切换到《${item.title}》`}
              onClick={() => setIndex(i)}
              className={`h-1.5 rounded-full transition-all duration-300 ${
                i === index ? "w-5 bg-white/85" : "w-1.5 bg-white/30 hover:bg-white/55"
              }`}
            />
          ))}
        </div>
      )}
    </div>
  );
}

/** Netflix 主题发现页横幅的一帧（全出血，文字区左右边距对齐全站 4vw 左基线） */
function HeroSlide({
  item,
  active,
  preload,
}: {
  item: MediaItem;
  active: boolean;
  /** 是否该装载大图（当前帧或下一帧）；一旦装载过就保持，淡出时不闪白 */
  preload: boolean;
}) {
  const { open } = useMediaDetail();
  // 首帧挂载时就带着 active=true，推镜 <img> 一出生就是终态 scale-[1.06]，
  // 没有「1.0 → 1.06」的变化过程，transition 不起播——推镜在首个驻留期缺席
  // （表现为「切了图才开始推」）。挂载完成后再认推镜标记，首帧也经历一次
  // 从 scale-100 起步的缓推。
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  const push = active && mounted;
  // 「粘性」装载：轮到过一次就永久保留 src（浏览器已缓存，重复挂载无成本）
  const [revealed, setRevealed] = useState(preload);
  useEffect(() => {
    if (preload) setRevealed(true);
  }, [preload]);
  // 按横幅实测尺寸 × 推镜 1.06 算取图宽度；reveal 后列表档（w1280）先显示，
  // 需要更大时 original 派生图解码就位后无感替换（不闪）
  const [frameEl, setFrameEl] = useState<HTMLDivElement | null>(null);
  const backdropWidth = useElementCoverWidth(frameEl, IMAGE_ASPECT.backdrop, 1.06);
  const backdropSrc = useUpgradedBackdrop(revealed, item.backdropUrl, backdropWidth);
  // 整块 Hero 就是进详情的入口（与海报卡片「点海报进详情」一致，不再另设「更多信息」键）。
  // Hero 占满首屏，手机上「向下滑看海报墙」几乎必然从这块起手，所以点击要过一遍误触判定。
  const tapGuard = useTapGuard(() => open(item));
  return (
    <div
      ref={setFrameEl}
      aria-hidden={!active}
      // 非当前帧虽然透明但仍占满同一块区域，必须关掉命中测试，否则点击可能落到它身上
      role={active ? "button" : undefined}
      tabIndex={active ? 0 : -1}
      aria-label={`查看《${item.title}》详情`}
      {...tapGuard}
      onKeyDown={(e) => {
        // 只认落在 Hero 自身上的回车/空格；内部订阅键的按键由它自己处理，
        // 否则一次回车会同时触发订阅弹层和详情页
        if (e.target !== e.currentTarget) return;
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          open(item);
        }
      }}
      className={`absolute inset-0 transition-opacity duration-700 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)] ${
        active ? "z-[1] cursor-pointer opacity-100" : "pointer-events-none z-0 opacity-0"
      }`}
    >
      {/* 宽幅剧照 + 双层渐变蒙版：左侧压暗保文字可读，底部渐隐融入页面 */}
      <PosterImage
        src={backdropSrc}
        alt={`${item.title} 剧照`}
        className={`absolute inset-0 size-full object-cover object-top transition-transform duration-[9000ms] ease-linear ${
          push ? "scale-[1.06]" : "scale-100"
        }`}
      />
      <div className="absolute inset-0 bg-gradient-to-r from-[rgba(7,9,14,0.88)] via-[rgba(7,9,14,0.42)] to-transparent" />
      <div className="absolute inset-x-0 bottom-0 h-1/2 bg-gradient-to-t from-[rgba(7,9,14,0.72)] to-transparent max-md:h-3/4 max-md:from-[rgba(7,9,14,0.9)]" />

      {/* 文字与操作区：随当前帧轻微上移淡入；左右边距走 4vw 左基线与顶栏字标对齐 */}
      <div
        className={`page-inset absolute inset-0 flex max-w-xl flex-col justify-end py-7 transition-all delay-150 duration-500 ease-out max-md:py-4 sm:py-9 ${
          active ? "translate-y-0 opacity-100" : "translate-y-3 opacity-0"
        }`}
      >
        <HeroCopy item={item} fullBleed />
      </div>
    </div>
  );
}

/**
 * Hero 的文字与操作区（今日精选 · 类型 / 片名 / 原名 / 元信息 / 简介 / 订阅键）：
 * 发现页是编辑推荐，所以左对齐、讲这部片是什么；两个主题共用，外框各自排——
 * Netflix 的横幅是 HeroSlide，银玻璃是通用沉浸 Hero（SilverDiscoverHero）。
 */
function HeroCopy({ item, fullBleed }: { item: MediaItem; fullBleed: boolean }) {
  const { canSubscribe, open: openSubscribe, subscriptionOf } = useSubscribeEntry();
  // 该影片是否已有订阅（数据来自 SubscribeEntryProvider 的全站订阅列表，Hero 自身不发请求）
  const existingSub = subscriptionOf(item);
  const subscribeTapGuard = useTapGuard(() => void openSubscribe(item));
  return (
    <>
      <p className="text-caption font-semibold uppercase tracking-[0.22em] text-[var(--accent-2)]">
        今日精选 · {item.type === "movie" ? "电影" : "剧集"}
      </p>
      <h2
        className={`text-on-image mt-2 text-[34px] font-bold leading-[1.1] tracking-[-0.02em] text-white max-md:mt-1 sm:text-[40px] ${
          fullBleed ? "max-md:text-[23px]" : "max-md:text-[30px]"
        }`}
      >
        {item.title}
      </h2>
      <p className="text-on-image mt-1 truncate text-ui text-white/55 max-md:text-caption">{item.originalTitle}</p>

      {/* 元信息行：评分 / 年份 / 类型 / 规模 / 质量徽章（空字段不占位） */}
      <div className="tnum mt-3 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sub text-white/80">
        {item.rating > 0 && (
          <span className="flex items-center gap-1 font-semibold text-white">
            <StarIcon className="size-3.5 text-[var(--warn)]" />
            {item.rating.toFixed(1)}
          </span>
        )}
        <span>{item.year}</span>
        {item.genres.length > 0 && <span>{item.genres.join(" / ")}</span>}
        {item.extent && <span>{item.extent}</span>}
        {item.libraryStatus && (
          <span className="flex items-center gap-1.5 text-emerald-300/90">
            <span className="size-1.5 rounded-full bg-[var(--ok)]" />
            在库
          </span>
        )}
        {item.badges.length > 0 && (
          <span className="flex gap-1.5">
            {item.badges.map((b) => (
              <span
                key={b}
                className="rounded border border-white/25 px-1.5 py-px text-micro font-semibold tracking-wide text-white/85"
              >
                {b}
              </span>
            ))}
          </span>
        )}
      </div>

      <p className="text-on-image mt-3 line-clamp-2 max-w-lg text-ui leading-6 text-white/75 max-md:mt-2 max-md:text-sub max-md:leading-5 sm:line-clamp-3">
        {item.overview}
      </p>

      {/* 订阅入口：文案/图标/行为与海报卡片完全一致（已订阅则切成状态键，点击进订阅管理）。
          它嵌在「整块进详情」的点击区里，所以点击必须 stopPropagation，
          否则订阅弹层弹出的同时详情页也会被打开。 */}
      <div className="mt-5 flex flex-wrap items-center gap-3 max-md:mt-3.5 max-md:gap-2">
        {canSubscribe && <button
          type="button"
          aria-label={existingSub ? `管理《${item.title}》的订阅` : `订阅影片《${item.title}》`}
          onPointerDown={subscribeTapGuard.onPointerDown}
          onPointerUp={subscribeTapGuard.onPointerUp}
          onPointerCancel={subscribeTapGuard.onPointerCancel}
          onClick={(e) => {
            e.stopPropagation();
            subscribeTapGuard.onClick(e);
          }}
          className={`${
            existingSub
              ? "flex h-10 items-center gap-2 rounded-full bg-white/[0.18] px-5 text-ui font-semibold text-white/90 backdrop-blur-md transition-colors hover:bg-white/[0.26]"
              : "btn-accent flex h-10 items-center gap-2 rounded-full px-5 text-ui font-semibold"
          } ${
            // 银玻璃手机：操作键统一 34px 高、最小宽 120px（同原生 App 的 HeroActionButton：
            // 系统 regular 档高度，单颗主键给最小宽度，轮播换片时键宽不跳）
            fullBleed ? "" : "max-md:h-[34px] max-md:min-w-[120px] max-md:justify-center max-md:px-4"
          }`}
        >
          {existingSub ? (
            <>
              <CheckIcon className="size-4 text-[var(--ok)]" />
              已订阅
            </>
            ) : (
              <>
                <PlusIcon className="size-4" />
                订阅影片
              </>
            )}
          </button>}
        </div>
    </>
  );
}

/**
 * 银玻璃发现页 Hero：与订阅首页同一套沉浸大图（components/immersive-hero.tsx——原图升清、
 * 12 秒推近、上滑视差、底部渐隐进页面氛围色、顶部压暗、8 秒填满的指示器、手动切换重新计时），
 * 文字按发现页自己的版式排：左对齐的编辑推荐（HeroCopy）。同 iOS 两页共用 ImmersiveHero、
 * 各排各的文字（DiscoverView.swift 的 DiscoverHero 与 SubscriptionsHomeHero.swift）。
 *
 * 框按标准比例随宽度走（写死高度时比例随机型漂，桌面宽窗只剩 2.6:1、剧照纵向裁掉三成）：
 * 手机是从屏幕物理顶边算起的 3:4 通栏大图（矮屏按视口收，下一行标题从底栏上方露出来）；
 * 桌面 21:9 铺满主区顶边（高屏封顶 70vh，整页是一张随剧照变色的圆角卡片，同订阅首页）。
 * 点剧照（订阅键以外）进详情。
 */
const SILVER_DISCOVER_HERO_HEIGHT =
  "aspect-[21/9] max-h-[70vh] min-h-[380px] max-md:aspect-[3/4] max-md:max-h-[74svh] max-md:min-h-[440px]";

function heroBackdropOf(item: MediaItem): string | undefined {
  return item.backdropUrl || item.posterUrl || undefined;
}

function SilverDiscoverHero({
  items,
  index,
  onIndexChange,
}: {
  items: MediaItem[];
  index: number;
  onIndexChange: (index: number) => void;
}) {
  const { open } = useMediaDetail();
  return (
    <ImmersiveHero
      slides={items}
      index={index}
      onIndexChange={onIndexChange}
      slideKey={(item) => item.id}
      imageOf={heroBackdropOf}
      onActivate={(item) => open(item)}
      activateLabel={(item) => `查看《${item.title}》详情`}
      indicatorLabel={(item) => `切换到《${item.title}》`}
      renderContent={(item) => (
        // 底部留出指示器那一行（居中、距底 16px）
        // 文字从内容区左缘起排：沉浸外框下大图伸到了侧栏底下，左边补上 --immersive-inset
        <div className="flex max-w-[calc(36rem+var(--immersive-inset,0px))] flex-col pb-12 pl-[calc(var(--immersive-inset,0px)+1.5rem)] pr-6 pt-9 max-md:p-4 max-md:pb-11">
          <HeroCopy item={item} fullBleed={false} />
        </div>
      )}
      className={SILVER_DISCOVER_HERO_HEIGHT}
    />
  );
}
