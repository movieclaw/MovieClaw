import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { KindWallView } from "@/components/kind-wall-view";
import type { HomeMediaKind } from "@/lib/api/libraries";

/** 兜底标题；视图内的 usePageTitle 会覆盖为「全部电影」等。 */
export const metadata: Metadata = { title: "媒体库" };

const KINDS: readonly HomeMediaKind[] = ["movie", "tv", "video"];

/**
 * 按类型的跨库海报墙（/library/kind/{movie|tv|video}）：首页「全部电影」行的
 * 「查看全部」落点。静态段 kind 优先于 /library/[id]，不会被当成库 id。
 *
 * `?g=<TMDB genre id>`：首页「电影类型 / 剧集类型」色块的落点，墙按该类型筛好。
 * 只认一个正整数 id，别的形状当没带。
 */
export default async function KindWallPage({
  params,
  searchParams,
}: {
  params: Promise<{ kind: string }>;
  searchParams: Promise<{ g?: string | string[] }>;
}) {
  const { kind } = await params;
  if (!KINDS.includes(kind as HomeMediaKind)) notFound();
  const { g } = await searchParams;
  const genre = typeof g === "string" && /^\d+$/.test(g) ? Number(g) : undefined;
  return (
    <div className="flex h-full flex-col">
      {/* key：从一个类型色块换到另一个时整面墙重来，不沿用上一面墙的状态 */}
      <KindWallView key={genre ?? "all"} kind={kind as HomeMediaKind} genre={genre} />
    </div>
  );
}
