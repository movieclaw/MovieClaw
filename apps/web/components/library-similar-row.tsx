"use client";

import { useEffect, useMemo, useState } from "react";

import type { Route } from "next";

import { libraryItemKey, libraryItemToMediaItem } from "@/components/library-view";
import { MediaRow } from "@/components/media-row";
import { type LibraryItem, listSimilarItems } from "@/lib/api/libraries";
import type { MediaItem } from "@/lib/media-types";

/**
 * 媒体库条目详情页的「相似推荐」行：只推观看者自己库里有的片，点进去是库内详情。
 * 卡片与首页库行同一张海报卡；没有相似的片（或接口失败）整行不出，不占位。
 */
export function LibrarySimilarRow({
  libraryId,
  mediaItemId,
}: {
  libraryId: number;
  mediaItemId: number;
}) {
  const [items, setItems] = useState<LibraryItem[]>([]);

  useEffect(() => {
    let cancelled = false;
    setItems([]);
    listSimilarItems(libraryId, mediaItemId)
      .then((rows) => {
        if (!cancelled) setItems(rows);
      })
      .catch(() => {
        // 推荐是锦上添花：失败就不出这一行，不打扰详情页
      });
    return () => {
      cancelled = true;
    };
  }, [libraryId, mediaItemId]);

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

  if (items.length === 0) return null;
  return (
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
  );
}
