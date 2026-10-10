import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { SettingsPanel } from "@/components/settings-view";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ section: string; item: string }>;
}): Promise<Metadata> {
  const { item } = await params;
  return { title: `${decodeURIComponent(item)} · 插件 · 设置` };
}

/** 设置分区的子页面：现在只有插件详情（/settings/plugins/<条目 id>）。 */
export default async function SettingsItemPage({
  params,
}: {
  params: Promise<{ section: string; item: string }>;
}) {
  const { section, item } = await params;
  if (section !== "plugins") notFound();
  return <SettingsPanel active={section} item={decodeURIComponent(item)} />;
}
