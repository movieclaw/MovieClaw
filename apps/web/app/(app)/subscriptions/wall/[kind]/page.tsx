import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";

import { SubscriptionWallView } from "@/components/subscription-wall-view";

/** 标签页标题跟着类型走：「剧集订阅」「电影订阅」 */
export async function generateMetadata({
  params,
}: {
  params: Promise<{ kind: string }>;
}): Promise<Metadata> {
  const { kind } = await params;
  const t = await getTranslations();
  return { title: t(kind === "movie" ? "subscription.wall.moviePageTitle" : "subscription.wall.tvPageTitle") };
}

/**
 * 订阅海报墙（/subscriptions/wall/tv | /subscriptions/wall/movie）：订阅首页一排的「全部」。
 * 静态段 wall 优先于同级的 [id]，不会被当成订阅详情解析。
 */
export default async function SubscriptionWallPage({
  params,
}: {
  params: Promise<{ kind: string }>;
}) {
  const { kind } = await params;
  if (kind !== "tv" && kind !== "movie") notFound();
  return (
    <div className="flex h-full flex-col">
      <SubscriptionWallView kind={kind} />
    </div>
  );
}
