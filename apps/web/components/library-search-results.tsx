"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import type { Route } from "next";

import { HScroller } from "@/components/h-scroller";
import { PosterCardVisual, type PosterVisualItem } from "@/components/poster-card";
import { PosterImage } from "@/components/poster-image";
import {
  searchLibrary,
  type LibrarySearchHit,
  type LibrarySearchPerson,
} from "@/lib/api/search";
import { imageUrl } from "@/lib/image-proxy";
import { useTheme } from "@/lib/ui-prefs";
import { useIsMobile } from "@/lib/use-media-query";
import { useScrollRestoration } from "@/lib/use-scroll-restoration";
import { useTapGuard } from "@/lib/use-tap-guard";

/**
 * 搜索结果页「媒体库」垂直：跨全部可见媒体库搜索已入库条目。
 *
 * 与影视（MediaSearchResults）、站点资源（SearchResults）并列挂在 /search
 * 页的选项卡下，回答的问题是「这部片我有没有」。数据源与 iPhone、Apple TV 是同一个
 * 相关度接口（GET /search/library）：
 *
 * - **按相关度平铺，不按库分组**：准确片名/首字母排最前，人物带出的作品排在后面。
 *   旧版按库分组再按拼音重排，搜「ST」时演员 Stephen Lang 带出的「阿凡达」会压过
 *   首字母正中的「三体」——分组本身就丢掉了相关度，所以整个去掉。
 * - **命中原因**：不是直接按片名命中的结果，格下注明原因（如「演员：史蒂芬·朗」），
 *   用户能看懂为什么它会出现。
 * - **人物入口**：命中的演员/导演单独一行，点头像进库内影人页（/people/{TMDB 影人 id}），
 *   与条目详情「演职员」同一个入口、同一个页面，三端一致。
 * - **分页**：服务端游标分页，滚到底自动续页。
 *
 * 空态的出口指向「影视」垂直：库里没有 ≈ 想要但还没入手，下一步自然是
 * 去影视条目搜索并订阅/下载。
 */
export function LibrarySearchResults({
  keyword,
  onSwitchToMedia,
}: {
  keyword: string;
  /** 切到「影视」垂直（空态时的出口：库里没有 → 去找来） */
  onSwitchToMedia?: () => void;
}) {
  const scrollRef = useScrollRestoration(`search:library:${keyword}`);
  // 银玻璃手机端不重复关键词大标题：结果页顶栏的关键词胶囊已写着（同原生 App）；
  // 页头留空作与垂直选项卡之间的间距
  const isNf = useTheme().structural;
  const hideKeyword = useIsMobile() && !isNf;
  // null = 加载中；[] = 无结果；error 非空 = 请求失败
  const [hits, setHits] = useState<LibrarySearchHit[] | null>(null);
  const [people, setPeople] = useState<LibrarySearchPerson[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 请求代次：关键词切换后，旧请求（含翻页）的响应一律丢弃
  const generation = useRef(0);

  useEffect(() => {
    const current = ++generation.current;
    setHits(null);
    setPeople([]);
    setCursor(null);
    setError(null);
    setLoadingMore(false);
    searchLibrary({ q: keyword })
      .then((page) => {
        if (generation.current !== current) return;
        setHits(page.items);
        setPeople(page.people);
        setCursor(page.next_cursor);
      })
      .catch((reason: Error) => {
        if (generation.current === current) {
          setError(reason.message || "媒体库搜索失败，请稍后重试");
        }
      });
  }, [keyword]);

  const loadMore = useCallback(() => {
    if (!cursor || loadingMore) return;
    const current = generation.current;
    setLoadingMore(true);
    searchLibrary({ q: keyword, cursor })
      .then((page) => {
        if (generation.current !== current) return;
        // 翻页按作品去重：同一轮浏览不会重复，但防御性去重不花什么
        setHits((previous) => {
          const seen = new Set((previous ?? []).map((hit) => hit.item.media_item_id));
          return [
            ...(previous ?? []),
            ...page.items.filter((hit) => !seen.has(hit.item.media_item_id)),
          ];
        });
        setCursor(page.next_cursor);
      })
      .catch((reason: Error) => {
        if (generation.current === current) {
          setError(reason.message || "媒体库搜索失败，请稍后重试");
        }
      })
      .finally(() => {
        if (generation.current === current) setLoadingMore(false);
      });
  }, [cursor, keyword, loadingMore]);

  // 滚到底自动续页：哨兵进入视口（提前 600px）就取下一页
  const sentinelRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const node = sentinelRef.current;
    if (!node || !cursor) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) loadMore();
      },
      { rootMargin: "600px 0px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [cursor, loadMore]);

  const empty = hits !== null && hits.length === 0 && people.length === 0;

  return (
    <div className="relative flex h-full flex-col">
      {/* 状态行：与另外两个垂直的头部同构（关键词） */}
      <header className={`shrink-0 pb-3 pt-4 page-inset max-md:pt-3`}>
        {!hideKeyword && (
          <h1 className="text-on-image text-title-lg font-semibold tracking-[-0.01em] text-white">
            “{keyword}”
          </h1>
        )}
      </header>

      <div
        ref={scrollRef}
        className={`scroll-thin scroll-safe relative min-h-0 flex-1 overflow-y-auto pb-6 page-inset`}
      >
        {hits === null && !error && <LibrarySearchSkeleton />}
        {(error || empty) && (
          <div className="flex flex-col items-center pt-24 text-center">
            <p className="text-on-image text-body-lg font-semibold text-white">
              {error ? "媒体库搜索出错" : "媒体库中没有找到相关影片"}
            </p>
            <p className="text-on-image mt-1.5 text-sub text-[rgba(243,245,249,0.7)]">
              {error ?? "支持片名、别名、拼音首字母和人物姓名；库里还没有的片子，去影视条目里找。"}
            </p>
            {onSwitchToMedia && (
              <button
                type="button"
                onClick={onSwitchToMedia}
                className="btn-accent mt-5 rounded-full px-4 py-1.5 text-sub font-semibold"
              >
                搜索影视条目
              </button>
            )}
          </div>
        )}
        {!error && people.length > 0 && (
          <section className="mb-6" data-testid="library-search-people">
            <h2 className="text-on-image mb-3 text-body-lg font-semibold text-white">人物</h2>
            <HScroller className="-mx-1 gap-3 px-1 pb-1">
              {people.map((candidate) => (
                <PersonChip key={candidate.id} person={candidate} />
              ))}
            </HScroller>
          </section>
        )}
        {!error && hits !== null && hits.length > 0 && (
          <section data-testid="library-search-items">
            {people.length > 0 && (
              <h2 className="text-on-image mb-3 text-body-lg font-semibold text-white">影片</h2>
            )}
            <div className="grid gap-x-4 gap-y-7 pt-1 [grid-template-columns:repeat(auto-fill,minmax(148px,1fr))]">
              {hits.map((hit) => (
                <LibraryResultCell key={hit.item.media_item_id} hit={hit} />
              ))}
            </div>
            {cursor && (
              <div ref={sentinelRef} className="flex justify-center pt-6">
                <button
                  type="button"
                  onClick={loadMore}
                  disabled={loadingMore}
                  className="rounded-full bg-white/10 px-4 py-1.5 text-sub text-white backdrop-blur-sm hover:bg-white/15 disabled:opacity-60"
                >
                  {loadingMore ? "正在加载…" : "更多结果"}
                </button>
              </div>
            )}
          </section>
        )}
      </div>
    </div>
  );
}

/**
 * 命中原因：直接按片名的文字命中不必解释（用户输入的就是片名），
 * 别名/原名/拼音/人物带出的结果写明原因，例如「演员：史蒂芬·朗」。
 */
function matchHint(hit: LibrarySearchHit): string | null {
  const { match } = hit;
  if (match.person_id == null && match.source_field === "title" && match.type.startsWith("text")) {
    return null;
  }
  return match.label;
}

/** 一格结果：海报卡链到库内条目详情，格下标注库存概况与命中原因。 */
function LibraryResultCell({ hit }: { hit: LibrarySearchHit }) {
  const { item } = hit;
  const visual: PosterVisualItem = {
    id: item.tmdb_id != null ? String(item.tmdb_id) : `local:${item.media_item_id}`,
    source: "tmdb",
    type: item.kind === "video" || item.kind === "photo" ? undefined : item.kind,
    title: item.title,
    year: item.year ?? undefined,
    rating: 0,
    aspect: item.primary_aspect,
    posterUrl: imageUrl(item.poster_url),
  };
  const parts: string[] = [];
  if (item.kind === "tv" && item.seasons.length > 0) {
    parts.push(
      item.seasons.length === 1
        ? `第 ${item.seasons[0]} 季 · ${item.episode_count} 集`
        : `${item.seasons.length} 季 · ${item.episode_count} 集`,
    );
  }
  if (item.resolutions.length > 0) parts.push(item.resolutions.join("/"));
  const hint = matchHint(hit);
  // 落点库：服务端给的详情落点库优先，其次取所在库里的第一个
  const libraryId = item.library_id ?? hit.library_ids[0];
  return (
    <div className="min-w-0">
      <PosterCardVisual
        item={visual}
        href={`/library/${libraryId}/item/${item.media_item_id}` as Route}
        // 不带「自动续订 / 补齐缺集」：带订阅类操作的卡片触屏首点只展开信息层，要点两下才进详情；
        // 搜索结果就是为了找到片子点进去，一下直达（订阅操作在详情页里）
        action="none"
      />
      {parts.length > 0 && (
        <p className="text-on-image mt-1.5 truncate text-caption text-[var(--text-muted)]">
          {parts.join(" · ")}
        </p>
      )}
      {hint && (
        <p
          className={`text-on-image truncate text-caption text-[var(--text-faint)] ${parts.length > 0 ? "" : "mt-1.5"}`}
        >
          {hint}
        </p>
      )}
    </div>
  );
}

/**
 * 一个命中的人物：圆形头像 + 姓名 + 库内作品数；点击进库内影人页，
 * 与条目详情「演职员」（CastRow）同一个页面。旧服务端不返回 TMDB 影人 id 时不可点。
 */
function PersonChip({ person }: { person: LibrarySearchPerson }) {
  // tapGuard：人物卡在横滚行里，滑动/刹车手势派发的 click 拦下不跳转（同 CastRow）
  const tapGuard = useTapGuard();
  const body = (
    <>
      <div className="size-[72px] overflow-hidden rounded-full bg-[var(--poster-placeholder)] ring-1 ring-white/[0.08] transition group-hover/person:ring-white/30">
        <PosterImage
          src={imageUrl(person.avatar_url) ?? ""}
          width={72}
          alt={person.name}
          className="size-full object-cover"
          fallback={
            <div
              aria-hidden="true"
              className="grid size-full place-items-center bg-gradient-to-b from-white/[0.07] to-white/[0.02] text-[22px] font-semibold text-white/35"
            >
              {person.name.trim().slice(0, 1) || "?"}
            </div>
          }
        />
      </div>
      <p className="mt-1.5 w-full truncate text-sub font-medium text-white">{person.name}</p>
      <p className="w-full truncate text-caption text-[var(--text-faint)]">
        库内 {person.item_count} 部
      </p>
    </>
  );
  const className =
    "group/person flex w-[96px] shrink-0 flex-col items-center rounded-xl text-center outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-ring)]";
  if (person.tmdb_person_id == null) {
    return <div className={className}>{body}</div>;
  }
  return (
    <Link
      href={`/people/${person.tmdb_person_id}` as Route}
      {...tapGuard}
      aria-label={`查看 ${person.name} 的影人页`}
      className={className}
    >
      {body}
    </Link>
  );
}

function LibrarySearchSkeleton() {
  return (
    <div className="grid gap-x-4 gap-y-7 pt-1 [grid-template-columns:repeat(auto-fill,minmax(148px,1fr))]">
      {Array.from({ length: 7 }, (_, index) => (
        <div key={index} className="aspect-[2/3] animate-pulse rounded-2xl bg-white/[0.05]" />
      ))}
    </div>
  );
}
