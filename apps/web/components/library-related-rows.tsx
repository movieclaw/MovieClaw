"use client";

import { useEffect, useMemo, useState } from "react";

import type { Route } from "next";

import { HScroller } from "@/components/h-scroller";
import { MissingPartCell } from "@/components/library-collection-detail-view";
import { libraryItemKey, libraryItemToMediaItem } from "@/components/library-view";
import { MediaRow } from "@/components/media-row";
import { PosterCard, PosterCardVisual } from "@/components/poster-card";
import { useSubscribeEntry } from "@/components/subscribe-entry";
import { type CollectionSeries, type SeriesPart, getCollectionSeries } from "@/lib/api/collections";
import { type LibraryItem, listSimilarItems } from "@/lib/api/libraries";
import { imageUrl } from "@/lib/image-proxy";
import type { MediaItem } from "@/lib/media-types";

/**
 * 媒体库条目详情页的「相似推荐」与「作品系列」两行（iPhone / Apple TV / Mac 同一套规则，见 Apple 端 `ItemRelated`）。
 *
 * 顺序是演职员 → 相似推荐 → 系列（2026-10-12 用户定）。电影有系列一行时，相似推荐排除同系列的片——
 * 系列那一行已经按上映顺序列全了，相似推荐留给系列之外的片。系列一行只在拉得到上游档案、且不止一部时才出
 * （本地 NFO 定的系列没有上游档案），两个请求并行发，系列一行最后没出来时再拉一次不排除的，否则续集哪儿都看不到。
 *
 * 推荐是锦上添花：失败、旧服务端没有这个接口，都是整行不出，不打扰详情页。
 */
export function LibraryRelatedRows({
  libraryId,
  mediaItemId,
  seriesCollectionId,
}: {
  libraryId: number;
  mediaItemId: number;
  /** 电影所属系列合集；剧集与没有系列的电影为 null */
  seriesCollectionId: number | null;
}) {
  const [items, setItems] = useState<LibraryItem[]>([]);
  const [series, setSeries] = useState<CollectionSeries | null>(null);

  useEffect(() => {
    let cancelled = false;
    setItems([]);
    setSeries(null);
    const similar = (excludeSeries: boolean) =>
      listSimilarItems(libraryId, mediaItemId, { excludeSeries }).catch(() => [] as LibraryItem[]);
    const seriesRow =
      seriesCollectionId == null
        ? Promise.resolve(null)
        : getCollectionSeries(seriesCollectionId)
            .then((s) => (s.available && s.parts.length > 1 ? s : null))
            .catch(() => null);
    void Promise.all([seriesRow, similar(seriesCollectionId != null)]).then(async ([s, rows]) => {
      const finalRows = seriesCollectionId != null && !s ? await similar(false) : rows;
      if (cancelled) return;
      setSeries(s);
      setItems(finalRows);
    });
    return () => {
      cancelled = true;
    };
  }, [libraryId, mediaItemId, seriesCollectionId]);

  const hrefs = useMemo(
    () =>
      new Map(
        items.map((it) => [
          libraryItemKey(it),
          `/library/${it.library_id ?? libraryId}/item/${it.media_item_id}` as Route,
        ]),
      ),
    [items, libraryId],
  );

  return (
    <>
      {items.length > 0 && (
        <MediaRow
          row={{
            id: `similar-${mediaItemId}`,
            title: "相似推荐",
            items: items.map(libraryItemToMediaItem),
          }}
          cardAction="none"
          cardHref={(m: MediaItem) => hrefs.get(m.id)}
          cardRevealInfoOnTouch
          // 详情页正文容器已带 content-inset，行自己不再加留白
          insetClassName=""
        />
      )}
      {series && <SeriesRow series={series} libraryId={libraryId} mediaItemId={mediaItemId} />}
    </>
  );
}

/**
 * 电影的作品系列一行：整个系列按上映顺序，标题旁写「已有 7 / 共 8」。这一部标「本片」；
 * 库里有的点进库内详情；缺的那部与系列合集页同一张缺片卡（压暗，点进 TMDB 详情、悬停订阅）。
 */
function SeriesRow({
  series,
  libraryId,
  mediaItemId,
}: {
  series: CollectionSeries;
  libraryId: number;
  mediaItemId: number;
}) {
  const { subscriptionOf } = useSubscribeEntry();
  return (
    <section data-testid="library-series-row">
      <div className="mb-3 flex items-baseline gap-3 max-md:mb-2">
        <h3 className="text-on-image text-body-lg font-semibold tracking-[-0.01em] text-[var(--text)]">
          {series.series_name ?? "系列"}
        </h3>
        <span className="text-sub text-[var(--text-muted)]">
          已有 {series.owned_count} / 共 {series.total}
        </span>
      </div>
      <HScroller className="m-row gap-4 pb-1 pt-2 max-md:gap-3">
        {series.parts.map((part) => (
          <div key={part.tmdb_id} className="w-[152px] shrink-0 max-md:w-[126px] xl:w-[164px]">
            {part.media_item_id == null ? (
              <MissingPartCell
                part={part}
                tracked={
                  part.subscribed ||
                  Boolean(subscriptionOf({ id: String(part.tmdb_id), type: "movie" }))
                }
              />
            ) : part.media_item_id === mediaItemId ? (
              <PosterCardVisual item={ownedPart(part, "本片")} action="none" />
            ) : (
              <PosterCard
                item={ownedPart(part, "")}
                action="none"
                href={`/library/${libraryId}/item/${part.media_item_id}` as Route}
              />
            )}
          </div>
        ))}
      </HScroller>
    </section>
  );
}

function ownedPart(part: SeriesPart, extent: string): MediaItem {
  return {
    id: String(part.tmdb_id),
    source: "tmdb",
    type: "movie",
    title: part.title,
    originalTitle: "",
    // 0 = 上映日待定：卡片对假值年份不渲染
    year: part.release_date ? Number(part.release_date.slice(0, 4)) : 0,
    rating: 0,
    genres: [],
    extent,
    badges: [],
    overview: "",
    // 宽度由 PosterCard 按卡宽生成 srcset
    posterUrl: imageUrl(part.poster_url),
  };
}
