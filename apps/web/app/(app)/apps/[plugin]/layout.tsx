import type { Metadata } from "next";

import { PluginAppFrame } from "@/components/plugin-app-frame";

/** 兜底标题；插件名在客户端拿到后由 usePageTitle 覆盖。 */
export const metadata: Metadata = { title: "插件页面" };

/**
 * 插件网页（/apps/<插件 id>/<子路径>，docs/design/plugin-web-pages.md）。
 * 外框挂在 layout 而不是 page：插件内部换页只改子路径，layout 不重建，iframe 也就不会被重新加载。
 */
export default async function PluginAppLayout({
  params,
  children,
}: {
  params: Promise<{ plugin: string }>;
  children: React.ReactNode;
}) {
  const { plugin } = await params;
  return (
    <>
      <PluginAppFrame appId={decodeURIComponent(plugin)} />
      {children}
    </>
  );
}
