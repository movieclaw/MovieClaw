import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { DiscoverView } from "@/components/discover-view";
import { parseDiscoveryFilters } from "@/lib/discovery-filters";
import type { MediaSource } from "@/lib/media-types";

export const metadata: Metadata = { title: "发现" };

/** 发现页（/discover/movie | /discover/tv）：Hero 精选 + 分类横滚行。 */
export default async function DiscoverPage({
  params,
  searchParams,
}: {
  params: Promise<{ type: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { type } = await params;
  const query = await searchParams;
  if (type !== "movie" && type !== "tv") notFound();
  // URL 是发现视角的唯一状态源；未知值安全回退到默认 TMDB 视角。
  const source: MediaSource = query.source === "douban" ? "douban" : "tmdb";
  const filters = parseDiscoveryFilters(query);
  return (
    <div className="flex h-full flex-col">
      {/* key 只含类型与数据源：筛选条件在页内就地改（地址用 router.replace 同步），
          不能随条件整棵重建——结果页头部的条件胶囊会跟着重来、横滑位置归零 */}
      <DiscoverView
        key={`${type}:${source}`}
        mediaType={type}
        source={source}
        filters={filters}
        currentYear={new Date().getFullYear()}
      />
    </div>
  );
}
