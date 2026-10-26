import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { LibraryPageBody } from "@/components/library-page";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("nav.main.library") };
}

/**
 * 媒体库（/library）：内容的一等入口。Netflix 主题把原「内容首页」的
 * Billboard 并入本页顶部（2026-09 修订，/ 在该主题下重定向到这里）。
 */
export default function LibraryPage() {
  return <LibraryPageBody />;
}
