import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { LibraryManageView } from "@/components/library-manage-view";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("library.manage.pageTitle") };
}

/** 媒体库管理（/library/manage）：一库一行的管理列表；首页只做浏览入口。 */
export default function LibraryManagePage() {
  return (
    <div className="flex h-full flex-col">
      <LibraryManageView />
    </div>
  );
}
