import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { LibraryCollectionDetailView } from "@/components/library-collection-detail-view";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("library.collections.pageTitle") };
}

/**
 * 跨库合集详情（/library/c/{cid}）。
 *
 * 与 /library/{id}/c/{cid} 是同一个组件，差别只在 libraryId：跨库合集没有
 * 所属库，每一格按自己的 library_id 落回它自己那个库的详情页。
 */
export default async function CrossLibraryCollectionPage({
  params,
}: {
  params: Promise<{ cid: string }>;
}) {
  const { cid } = await params;
  return (
    <div className="flex h-full flex-col">
      <LibraryCollectionDetailView libraryId={null} collectionId={Number(cid)} />
    </div>
  );
}
