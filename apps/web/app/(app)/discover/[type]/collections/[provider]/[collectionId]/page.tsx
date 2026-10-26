import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";

import { CollectionGridView } from "@/components/collection-grid-view";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("media.discovery.collectionTitle") };
}

/** 通用片单落地页：路由参数只负责恢复服务端签发的稳定片单引用。 */
export default async function DiscoveryCollectionPage({
  params,
}: {
  params: Promise<{ type: string; provider: string; collectionId: string }>;
}) {
  const { type, provider, collectionId } = await params;
  if (
    (type !== "movie" && type !== "tv") ||
    (provider !== "tmdb" && provider !== "douban") ||
    !collectionId
  ) {
    notFound();
  }
  const collectionRef = `${provider}:${type}:${collectionId}`;
  return (
    <div className="flex h-full flex-col">
      <CollectionGridView collectionRef={collectionRef} />
    </div>
  );
}
