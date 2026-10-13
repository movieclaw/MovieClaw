"use client";

import { useEffect, useMemo, useState } from "react";

import { SeriesUpdateCalendar } from "@/components/series-update-calendar";
import { useSubscribeEntry } from "@/components/subscribe-entry";
import type { LibraryItemDetail } from "@/lib/api/libraries";
import {
  getSubscription,
  type SubscriptionDetail,
} from "@/lib/api/subscriptions";
import {
  buildSeriesUpdateCalendar,
  latestSeasonProgress,
  ownedUnitsFromFiles,
} from "@/lib/series-update-calendar";

/**
 * 媒体库剧集详情页的更新日历入口：找到该条目的订阅 → 拉详情工单 →
 * 叠上在位文件 → 拼出日历。没有订阅、完结、或一周内无排期时不渲染。
 */
export function LibrarySeriesUpdateCalendar({
  detail,
}: {
  detail: LibraryItemDetail;
}) {
  const { subscriptions } = useSubscribeEntry();
  const subscriptionId = useMemo(() => {
    if (detail.kind !== "tv") return null;
    const match = subscriptions?.find(
      (sub) => sub.media.media_item_id === detail.media_item_id,
    );
    return match?.id ?? null;
  }, [detail.kind, detail.media_item_id, subscriptions]);

  const [subscriptionDetail, setSubscriptionDetail] =
    useState<SubscriptionDetail | null>(null);

  useEffect(() => {
    if (subscriptionId == null) {
      setSubscriptionDetail(null);
      return;
    }
    let cancelled = false;
    void getSubscription(subscriptionId)
      .then((row) => {
        if (!cancelled) setSubscriptionDetail(row);
      })
      .catch(() => {
        if (!cancelled) setSubscriptionDetail(null);
      });
    return () => {
      cancelled = true;
    };
  }, [subscriptionId]);

  const calendar = useMemo(() => {
    if (!subscriptionDetail || subscriptionDetail.media.kind !== "tv") return null;
    if (subscriptionDetail.status === "completed") return null;
    return buildSeriesUpdateCalendar(
      subscriptionDetail.wanted,
      ownedUnitsFromFiles(detail.files),
      {
        mediaStatus: subscriptionDetail.media.status,
        seasonProgress: latestSeasonProgress(subscriptionDetail.season_collection),
      },
    );
  }, [detail.files, subscriptionDetail]);

  if (!calendar) return null;
  return <SeriesUpdateCalendar calendar={calendar} />;
}
