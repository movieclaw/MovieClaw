"use client";

import { SubscriptionsView } from "@/components/subscriptions-view";
import { useResolvedTheme } from "@/themes/registry";

/**
 * 订阅页入口：主题提供了专属订阅页（ThemePages.subscriptions）就用它，
 * 否则走基础实现——海报墙布局（subscriptions-view.tsx）。
 *
 * 两套布局各自带数据层（同源接口 + 共享轮询 hook），切主题即整体切换。
 */
export function SubscriptionsPage() {
  const ThemeSubscriptionsPage = useResolvedTheme().pages.subscriptions;
  return ThemeSubscriptionsPage ? <ThemeSubscriptionsPage /> : <SubscriptionsView />;
}
