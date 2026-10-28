import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";

import { ReelsView } from "@/components/reels-view";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations();
  return { title: t("library.reels.title") };
}

/** 片段：上下滑动看片库里的片段（docs/design/reels.md）；入口是手机媒体库首页的下拉二楼 */
export default function ReelsPage() {
  return <ReelsView />;
}
