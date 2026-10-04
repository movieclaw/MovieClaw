"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

import type { Route } from "next";

import { GenreArtwork } from "@/components/genre-tile";
import { WallLoadMore } from "@/components/wall-chrome";
import { WallSortControl } from "@/components/library-filter-bar";
import { PosterWall } from "@/components/poster-wall";
import { PageNav } from "@/components/page-nav";
import {
  type HomeMediaKind,
  type LibraryItem,
  type LibraryItemSort,
  getKindSummary,
  listKindItems,
} from "@/lib/api/libraries";
import { GENRE_TONES } from "@/lib/genre-palette";
import { MEDIA_KIND_LABELS } from "@/lib/home-rows";
import type { LibraryFilter } from "@/lib/library-filter";
import {
  PREF_TO_SORT,
  SORT_DIRECTIONS,
  SORT_PREF_LABELS,
  orderParam,
  useWallSortPref,
  type WallSortPref,
} from "@/lib/wall-sort";
import { usePageTitle } from "@/lib/use-page-title";
import { useScrollRestoration } from "@/lib/use-scroll-restoration";

/** 每次向服务端要的格数，与单库海报墙同一页长。 */
const PAGE_SIZE = 60;

/**
 * 排序档位：默认档是「最近添加」——这面墙从首页的「全部电影 · 最近添加」点进来，
 * 进来之后顺序不该变。其余档与单库墙同一套（服务端也是同一份实现）；其他视频
 * 没有评分与上映时间，列出来只会排出一面按 id 的墙，按类型裁掉。
 */
function sortOptions(kind: HomeMediaKind): readonly (readonly [WallSortPref, string])[] {
  const skip = new Set<string>(
    kind === "video" ? ["added_at", "rating", "release_date"] : ["added_at"],
  );
  return [
    ["default", "最近添加"],
    ...(Object.entries(SORT_PREF_LABELS) as [WallSortPref, string][]).filter(
      ([key]) => !skip.has(key),
    ),
  ];
}

/**
 * 离开再返回时的会话快照（与「全部收藏」页同一件事）：这面墙与作品详情页是两个
 * 路由，切走时组件会卸载；返回时若只补第一页，容器矮到装不下离开时的滚动位置，
 * 人会被甩回墙首。按类型各存一份，只活在当前浏览会话里。
 */
interface KindWallSnapshot {
  items: LibraryItem[];
  total: number;
  libraryCount: number;
  /** 这份窗口是按哪个排序取的；返回时偏好变了就不能接着用 */
  sortKey: string;
}

/** 键 = 类型 + 预设的 genre（`movie` / `movie:878`）：同一类型不同 genre 的墙各存一份。 */
const snapshots = new Map<string, KindWallSnapshot>();

/**
 * 按类型的跨库海报墙（/library/kind/{类型}）：首页「全部电影」那一行点「查看全部」
 * 进来的地方（docs/design/library-home-perspective.md §8）。
 *
 * 成员 = 当前身份可见、没被管理员排除出首页的同类型库，同一部片在 4K 库和普通库
 * 里各有一份时只出现一格；每格点进它自己的落点库。口径全部在服务端
 * （`/libraries/kinds/{kind}`），这里只管翻页与排序。
 *
 * 刻意比单库页薄：没有筛选条（facet 统计按单库算，跨库版本留到下一期）、没有
 * 索引条与图床浏览，只有排序。
 *
 * 带 `genre`（`?g=878`）时是首页「按类型找电影」色块的落点：墙按这个 TMDB 类型筛好，
 * 页头换成与色块同一块网格渐变，标题是类型名。
 */
export function KindWallView({ kind, genre }: { kind: HomeMediaKind; genre?: number }) {
  const genreName = genre === undefined ? null : (GENRE_TONES[genre]?.name ?? `类型 ${genre}`);
  const label = genreName ?? `全部${MEDIA_KIND_LABELS[kind]}`;
  usePageTitle(genreName ? `${genreName} · ${MEDIA_KIND_LABELS[kind]}` : label);
  const wallKey = genre === undefined ? kind : `${kind}:${genre}`;
  const filter: LibraryFilter | undefined = genre === undefined ? undefined : { genres: [genre] };
  // ref 版：load / reload 回调里读，不必为它重建回调链（genre 变了组件会整个重挂，见 page.tsx）
  const filterRef = useRef(filter);
  const initialSnapshot = snapshots.get(wallKey) ?? null;
  const [{ pref: sortPref, reversed: sortReversed }, setSortPref, toggleSortReversed, sortReady] =
    useWallSortPref(`movieclaw.library.kind-wall-sort.${kind}`);
  const effectiveSort: LibraryItemSort =
    sortPref === "default" ? "added_at" : PREF_TO_SORT[sortPref];
  const sortAscending = SORT_DIRECTIONS[effectiveSort].naturalAsc !== sortReversed;
  const sortKey = `${effectiveSort}${sortReversed ? ":rev" : ""}`;
  // ref 版：翻页回调每轮读最新值，不必为换排序重建回调链
  const sortRef = useRef({ sort: effectiveSort, order: orderParam(effectiveSort, sortReversed) });
  sortRef.current = { sort: effectiveSort, order: orderParam(effectiveSort, sortReversed) };

  const restoreScrollRef = useScrollRestoration(`library:kind:${wallKey}`, {
    anchorAttribute: "data-library-item-id",
    restore: initialSnapshot !== null,
  });
  const [items, setItems] = useState<LibraryItem[] | null>(initialSnapshot?.items ?? null);
  const [total, setTotal] = useState(initialSnapshot?.total ?? 0);
  const [libraryCount, setLibraryCount] = useState(initialSnapshot?.libraryCount ?? 0);
  const [failed, setFailed] = useState(false);
  // 翻页请求进行中：哨兵重新观察时不重复发同一页
  const loading = useRef(false);
  // 进这一屏时快照里有多少格（挂载后本组件自己就会改写快照，得先定格）
  const restoredCount = useRef(initialSnapshot?.items.length ?? 0);

  /** 墙尾追加一页；offset 为 0 时整面墙重来（首次进入、换了排序）。 */
  const load = useCallback(
    async (offset: number) => {
      if (loading.current) return;
      loading.current = true;
      try {
        // 总数只在墙首取一次：往下翻页时数量不变，不必每页多打一个请求
        const [summary, page] = await Promise.all([
          offset === 0 ? getKindSummary(kind, filterRef.current) : null,
          listKindItems(kind, {
            ...sortRef.current,
            limit: PAGE_SIZE,
            offset,
            filter: filterRef.current,
          }),
        ]);
        if (summary) {
          setTotal(summary.item_count);
          setLibraryCount(summary.library_ids.length);
        }
        setItems((prev) => {
          if (!prev || offset === 0) return page;
          const seen = new Set(prev.map((i) => i.media_item_id));
          return [...prev, ...page.filter((i) => !seen.has(i.media_item_id))];
        });
        setFailed(false);
      } catch {
        setFailed(true);
      } finally {
        loading.current = false;
      }
    },
    [kind],
  );

  /**
   * 从详情页返回：按已加载的页数整窗重拉、整体替换（在详情页删掉的片要跟着消失），
   * 不缩窗口、不动滚动位置；失败就留着旧窗口。
   */
  const reload = useCallback(
    async (loadedCount: number) => {
      if (loading.current) return;
      loading.current = true;
      try {
        const [summary, ...pages] = await Promise.all([
          getKindSummary(kind, filterRef.current),
          ...Array.from({ length: Math.ceil(loadedCount / PAGE_SIZE) }, (_, page) =>
            listKindItems(kind, {
              ...sortRef.current,
              limit: PAGE_SIZE,
              offset: page * PAGE_SIZE,
              filter: filterRef.current,
            }),
          ),
        ]);
        setTotal(summary.item_count);
        setLibraryCount(summary.library_ids.length);
        setItems((pages as LibraryItem[][]).flat());
        setFailed(false);
      } catch {
        setFailed(true);
      } finally {
        loading.current = false;
      }
    },
    [kind],
  );

  // 排序偏好读出来之前按兵不动（否则先按默认序拉一遍再重拉，人会被甩回墙首）；
  // 返回且排序没变：整窗对账；首次或换了排序：从墙首重来
  const windowSort = useRef<string | null>(initialSnapshot?.sortKey ?? null);
  useEffect(() => {
    if (!sortReady) return;
    const previous = windowSort.current;
    windowSort.current = sortKey;
    if (previous === sortKey && restoredCount.current > 0) void reload(restoredCount.current);
    else void load(0);
  }, [sortReady, sortKey, load, reload]);

  // 布局提交后就更新快照：新路由的首次 render 可能早于被动 effect 的 cleanup
  useLayoutEffect(() => {
    if (items === null) return;
    snapshots.set(wallKey, {
      items,
      total,
      libraryCount,
      sortKey: windowSort.current ?? sortKey,
    });
  }, [wallKey, items, total, libraryCount, sortKey]);

  const loaded = items?.length ?? 0;
  const hasMore = items !== null && loaded < total;
  const loadMore = useCallback(() => void load(loaded), [load, loaded]);
  /** 跨库的一面墙，每一格落回它自己的库（服务端给的落点） */
  const ownerLibraryOf = useCallback((item: LibraryItem) => item.library_id ?? 0, []);
  const empty = items !== null && items.length === 0;

  return (
    <div ref={restoreScrollRef} className="scroll-thin scroll-safe flex-1 overflow-y-auto pb-10">
      <PageNav title={label} fallback={{ label: "媒体库", href: "/library" as Route }} />
      <div className="page-inset">
        {genre !== undefined ? (
          // 色块的落点：页头就是那块色块放大，进来的人一眼知道自己在哪
          <div className="relative isolate flex h-[148px] flex-col justify-end overflow-hidden rounded-[22px] px-6 pb-5 shadow-[inset_0_1px_0_rgba(255,255,255,0.22),inset_0_0_0_0.5px_rgba(255,255,255,0.1)] max-md:h-[116px] max-md:rounded-[18px] max-md:px-4 max-md:pb-4">
            <GenreArtwork genreId={genre} />
            <h2 className="truncate text-[30px] font-semibold leading-tight tracking-[0.04em] text-white max-md:text-[24px]">
              {label}
            </h2>
            <p className="mt-1 truncate text-ui tabular-nums text-white/75 max-md:text-sub">
              {items === null
                ? "正在读取…"
                : `${total} 部${MEDIA_KIND_LABELS[kind]} · 来自 ${libraryCount} 个库`}
            </p>
          </div>
        ) : (
          <>
            <h2 className="text-on-image truncate text-[26px] font-bold leading-tight tracking-[-0.02em] text-white max-md:text-[20px]">
              {label}
            </h2>
            <p className="text-on-image mt-1.5 truncate text-ui text-[var(--text-muted)] max-md:text-sub">
              {items === null
                ? "正在读取…"
                : libraryCount === 0
                  ? `还没有可浏览的${MEDIA_KIND_LABELS[kind]}库`
                  : `${total} 部作品 · 来自 ${libraryCount} 个库，同一部片只算一次`}
            </p>
          </>
        )}
        {!empty && items !== null && (
          <div className="mt-3 flex items-center">
            <WallSortControl
              value={sortPref}
              options={sortOptions(kind)}
              onChange={setSortPref}
              disabled={!sortReady}
              direction={{
                ascending: sortAscending,
                label: SORT_DIRECTIONS[effectiveSort][sortAscending ? "asc" : "desc"],
                onToggle: toggleSortReversed,
              }}
            />
          </div>
        )}

        {failed && items === null && (
          <div className="mt-16 flex flex-col items-center gap-3 text-center">
            <p className="text-ui text-[var(--text-muted)]">加载失败</p>
            <button
              type="button"
              onClick={() => void load(0)}
              className="btn-glass px-4 py-2 text-ui font-medium text-[var(--text)]"
            >
              重试
            </button>
          </div>
        )}

        {items !== null && items.length > 0 && (
          <>
            <div className="mt-6">
              <PosterWall
                items={items}
                libraryIdOf={ownerLibraryOf}
                // 其他视频是 16:9 抓帧，走宽列；影视按 2:3 钉死框比例——跨库的一面墙
                // 里偶有没刮到海报的本地条目，钉死后每格等高、片名落在一条线上
                wide={kind === "video"}
                frameAspect={kind === "video" ? undefined : 2 / 3}
                showRating={effectiveSort === "rating"}
              />
            </div>
            <WallLoadMore
              hasMore={hasMore}
              loaded={loaded}
              start={0}
              total={total}
              onReach={loadMore}
            />
          </>
        )}
      </div>
    </div>
  );
}
