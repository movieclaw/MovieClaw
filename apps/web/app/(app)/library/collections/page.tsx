import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { AllCollectionsView } from "@/components/all-collections-view";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("library.home.collections") };
}

/** 跨库合集总览（/library/collections）：按库分组，跨库的单独一组。 */
export default function AllCollectionsPage() {
  return (
    <div className="flex h-full flex-col">
      <AllCollectionsView />
    </div>
  );
}
