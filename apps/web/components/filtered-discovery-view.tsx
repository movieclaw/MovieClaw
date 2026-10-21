"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { DiscoveryFilterChips, useDiscoveryGenres } from "@/components/discovery-filter-dialog";
import { PosterCard } from "@/components/poster-card";
import { fetchFilteredDiscovery } from "@/lib/api/discover";
import { useLayout } from "@/lib/ui-prefs";
import {
  discoveryFilterCount,
  discoveryFilterLabels,
  EMPTY_DISCOVERY_FILTERS,
  type DiscoveryFilters,
} from "@/lib/discovery-filters";
import type { MediaItem, MediaType } from "@/lib/media-types";

/** 条件变化后的防抖：连勾几个类型只查最后一次（同 iOS DiscoverFilteredGrid 的 0.3 秒） */
const REQUERY_DEBOUNCE_MS = 300;

/**
 * 组合筛选结果网格：TMDB discover 原生分页，滚到底自动加载下一页（失败给「重试」）。
 *
 * 条件就在本页头部被改（银玻璃的条件胶囊，对应 iOS DiscoverFilter.swift 的
 * DiscoverFilteredGrid），所以网格**不随条件重建**——重建会让头部胶囊跟着重来、横滑
 * 位置归零——而是按 filters 原地重查：先等 300ms 防抖，期间再改就取消重来；
 * 旧条件的请求一律中止，中止不及的响应按控制器比对丢弃，不会把旧结果拼进新网格。
 *
 * Netflix 主题的头部维持原样（静态条件标签 +「清除全部」），只共用重查逻辑。
 */
export function FilteredDiscoveryView({
  mediaType,
  filters,
  currentYear,
  onChange,
}: {
  mediaType: MediaType;
  filters: DiscoveryFilters;
  currentYear: number;
  onChange: (filters: DiscoveryFilters) => void;
}) {
  const [items, setItems] = useState<MediaItem[]>([]);
  const [nextPage, setNextPage] = useState(1);
  const [totalResults, setTotalResults] = useState(0);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const loadingRef = useRef(false);
  const loadMoreRef = useRef<HTMLDivElement>(null);
  const controllerRef = useRef<AbortController | null>(null);
  const firstQueryRef = useRef(true);
  // 页面左右留白随主题走栅格：Netflix 主题放弃居中栏、与发现页内容行同走全幅
  // 4vw 左基线；银玻璃维持居中 1500px 栏 + px-6
  const cinema = useLayout() === "cinema";
  // 类型清单：银玻璃的胶囊菜单要列全部类型；Netflix 只在选了类型时拿来翻译名字
  const genres = useDiscoveryGenres(mediaType, !cinema || filters.genreIds.length > 0);

  const loadPage = useCallback(async (page: number) => {
    if (loadingRef.current) return;
    loadingRef.current = true;
    setLoading(true);
    setError(null);
    const controller = new AbortController();
    controllerRef.current = controller;
    try {
      const result = await fetchFilteredDiscovery(mediaType, filters, page, {
        signal: controller.signal,
      });
      // 条件已变：这页属于旧条件，丢掉（新条件的查询已另起）
      if (controller.signal.aborted) return;
      setItems((current) => {
        const known = new Set(current.map((item) => item.titleRef ?? `${item.source}:${item.id}`));
        return [
          ...current,
          ...result.items.filter((item) => !known.has(item.titleRef ?? `${item.source}:${item.id}`)),
        ];
      });
      setTotalResults(result.totalResults);
      setHasMore(result.hasMore);
      setNextPage(result.page + 1);
    } catch (reason) {
      if (!controller.signal.aborted) {
        setError((reason as Error).message || "筛选结果加载失败，请稍后重试");
      }
    } finally {
      // 只有仍是当前那次请求才收尾：被新条件顶掉的旧请求不能把新请求的加载态清掉
      if (controllerRef.current === controller) {
        setLoading(false);
        loadingRef.current = false;
      }
    }
  }, [filters, mediaType]);

  // 条件变化（loadPage 随 filters 换新）：清空重查。首次进入不必等防抖
  useEffect(() => {
    controllerRef.current?.abort();
    controllerRef.current = null;
    loadingRef.current = false;
    setItems([]);
    setNextPage(1);
    setTotalResults(0);
    setHasMore(true);
    setError(null);
    setLoading(true);
    const delay = firstQueryRef.current ? 0 : REQUERY_DEBOUNCE_MS;
    firstQueryRef.current = false;
    const timer = window.setTimeout(() => void loadPage(1), delay);
    return () => {
      window.clearTimeout(timer);
      controllerRef.current?.abort();
    };
  }, [loadPage]);

  useEffect(() => {
    const target = loadMoreRef.current;
    if (!target || !hasMore || loading || error) return;
    const scrollRoot = target.closest<HTMLElement>("[data-scroll-root]");
    if (!scrollRoot) return;
    const preloadDistance = Math.max(800, Math.round(scrollRoot.clientHeight * 1.25));
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) void loadPage(nextPage);
      },
      {
        root: scrollRoot,
        rootMargin: `${preloadDistance}px 0px`,
      },
    );
    observer.observe(target);
    return () => observer.disconnect();
  }, [error, hasMore, loadPage, loading, nextPage]);

  const activeCount = discoveryFilterCount(filters);
  const genreNames = useMemo(
    () => new Map((genres ?? []).map((genre): [number, string] => [genre.id, genre.name])),
    [genres],
  );
  const filterLabels = useMemo(
    () => discoveryFilterLabels(filters, genreNames),
    [filters, genreNames],
  );
  const clearAll = () => onChange(EMPTY_DISCOVERY_FILTERS);
  const allLoaded = !hasMore && items.length > 0;
  return (
    <main
      className={
        cinema ? "w-full page-inset pb-12" : "mx-auto w-full max-w-[1500px] page-inset pb-12"
      }
    >
      <header className="mb-7 max-md:mb-5">
        <div className="flex items-end justify-between gap-4">
          <div>
            <p className="text-sub font-semibold tracking-[0.16em] text-[var(--accent-2)]">
              TMDB DISCOVER
            </p>
            <h1 className="mt-1 text-3xl font-bold tracking-[-0.03em] text-[var(--text)] max-md:text-2xl">
              筛选结果
            </h1>
            <p className="mt-2 text-body text-[var(--text-muted)]">
              {totalResults > 0
                ? `找到 ${totalResults.toLocaleString("zh-CN")} 部，已加载 ${items.length} 部`
                : `已启用 ${activeCount} 项筛选`}
            </p>
            {cinema && (
              <div className="mt-3 flex flex-wrap gap-2" aria-label="当前筛选条件">
                {filterLabels.map((label) => (
                  <span
                    key={label}
                    className="rounded-full border border-white/[0.08] bg-white/[0.05] px-2.5 py-1 text-sub font-semibold text-[var(--text-muted)]"
                  >
                    {label}
                  </span>
                ))}
              </div>
            )}
          </div>
          {cinema ? (
            <button
              type="button"
              onClick={clearAll}
              className="shrink-0 text-ui font-semibold text-[var(--accent-2)] transition hover:text-white"
            >
              清除全部
            </button>
          ) : (
            <button
              type="button"
              onClick={clearAll}
              className="btn-glass h-9 shrink-0 px-4 text-sub font-semibold"
            >
              清空条件
            </button>
          )}
        </div>
        {/* 银玻璃：六颗可点的条件胶囊，就地改条件、本页原地重查 */}
        {!cinema && (
          <div className="mt-4">
            <DiscoveryFilterChips
              mediaType={mediaType}
              currentYear={currentYear}
              genres={genres}
              filters={filters}
              onChange={onChange}
            />
          </div>
        )}
      </header>

      {items.length > 0 && (
        <div className="grid grid-cols-2 gap-x-4 gap-y-7 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 2xl:grid-cols-8">
          {items.map((item) => (
            <PosterCard key={item.titleRef ?? `${item.source}:${item.id}`} item={item} />
          ))}
        </div>
      )}

      {loading && items.length === 0 && <FilteredSkeleton />}
      {!loading && !error && items.length === 0 && (
        <div className="py-24 text-center text-body text-[var(--text-muted)]">没有符合条件的影片</div>
      )}
      {error && (
        <div className="mt-12 rounded-2xl border border-white/10 bg-black/25 p-8 text-center">
          <p className="text-body text-[var(--text-muted)]">{error}</p>
          <button type="button" onClick={() => void loadPage(nextPage)} className="btn-accent mt-4 h-9 rounded-full px-5 text-ui font-semibold">
            重试
          </button>
        </div>
      )}
      <div ref={loadMoreRef} className="h-px" aria-hidden="true" />
      {/* 加载进度的读屏播报；银玻璃把「已加载全部」做成可见页脚（同 iOS），告诉用户到底了 */}
      <p
        className={allLoaded && !cinema ? "mt-8 text-center text-caption text-[var(--text-faint)]" : "sr-only"}
        role="status"
      >
        {loading && items.length > 0
          ? "正在加载更多影片"
          : allLoaded
            ? `已加载全部 ${items.length} 部影片`
            : ""}
      </p>
    </main>
  );
}

function FilteredSkeleton() {
  return (
    <div className="grid grid-cols-2 gap-x-4 gap-y-7 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 2xl:grid-cols-8" aria-busy="true">
      {Array.from({ length: 16 }, (_, index) => (
        <div key={index} className="aspect-[2/3] animate-pulse rounded-2xl bg-white/[0.05] ring-1 ring-white/10" />
      ))}
    </div>
  );
}
